import ActivityKit
import AVFoundation
import CoreLocation
import Foundation
import UIKit

/// The phone recorder (commission 2026-11-07, "the capture layer"): record a
/// meeting with the screen locked, a minute at a time, and hand each minute
/// to `MeetingUploader`. Started and stopped by the App Intents in
/// `RecorderShared.swift` (Siri, the Action button, the Lock Screen /
/// Control Center control, the Live Activity's Stop button), never by opening
/// the app. The Live Activity is the only UI: "Recording · 00:14:32 ·
/// uploaded ✓".
///
/// Its own AVAudioEngine, never Conversation's: the live voice session and the
/// recorder never run together (each refuses while the other is on), so the
/// one-tap rule of Conversation.shared is untouched.
@MainActor
final class MeetingRecorder: ObservableObject {
    static let shared = MeetingRecorder()

    @Published private(set) var sid: String?
    @Published private(set) var startedAt: Date?
    @Published private(set) var uploadedMinutes = 0
    @Published private(set) var pendingMinutes = 0

    private var engine: AVAudioEngine?
    private var writer: ChunkWriter?
    private var activity: Activity<MeetingRecordingAttributes>?
    private var consent: String?
    private var progressObserver: NSObjectProtocol?
    private var sessionObservers: [NSObjectProtocol] = []

    var isRecording: Bool { sid != nil }

    private init() {
        progressObserver = NotificationCenter.default.addObserver(forName: .meetingUploadProgress, object: nil, queue: .main) { [weak self] n in
            let info = n.userInfo ?? [:]
            Task { @MainActor in self?.progress(info) }
        }
    }

    // MARK: start / stop

    func start(about: String?) async throws -> String {
        if let _ = sid { return "Already recording." }
        guard TokenStore.token != nil else { return "Scarlet isn't signed in on this phone yet. Open Talk once and unlock it." }
        if Conversation.shared.state != .idle { return "You're in a live conversation with Scarlet. End it first, then start the recording." }

        let session = AVAudioSession.sharedInstance()
        // Built-in mic on purpose (no Bluetooth input): the room, not an earbud.
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
        try session.setActive(true)
        if #available(iOS 17.0, *) {
            if AVAudioApplication.shared.recordPermission == .undetermined {
                _ = await AVAudioApplication.requestRecordPermission()
            }
            guard AVAudioApplication.shared.recordPermission == .granted else {
                return "Talk doesn't have the microphone. Allow it in Settings, Talk, Microphone."
            }
        }

        let now = Date()
        let id = MeetingAPI.newSessionID(at: now)
        consent = await ConsentRule.current()
        let meta = MeetingMeta(sid: id, startedAt: now, stoppedAt: nil, device: "iphone",
                               titleHint: about?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                               consent: consent, tz: TimeZone.current.identifier,
                               chunks: 0, started: false, finished: false)
        MeetingUploader.writeMeta(meta)

        let eng = AVAudioEngine()
        let input = eng.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            try? FileManager.default.removeItem(at: MeetingUploader.folder(id))
            return "The microphone isn't available right now."
        }
        let w = ChunkWriter(sid: id) { seq in
            Task { @MainActor in
                if var m = MeetingUploader.readMeta(id) { m.chunks = max(m.chunks, seq); MeetingUploader.writeMeta(m) }
                await MeetingUploader.shared.kick()
            }
        }
        do {
            try w.open(format: format)
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { buf, _ in w.append(buf) }
            eng.prepare()
            try eng.start()
        } catch {
            input.removeTap(onBus: 0)
            _ = w.close()
            try? FileManager.default.removeItem(at: MeetingUploader.folder(id))
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }

        engine = eng; writer = w; sid = id; startedAt = now
        uploadedMinutes = 0; pendingMinutes = 0
        watchAudioSession()
        startActivity(sid: id, startedAt: now)
        await MeetingUploader.shared.kick()   // op=start goes now, so the server knows

        var line = "Recording. Say stop recording when you're done."
        if consent == "two-party" { line = "Recording. You're somewhere that needs everyone's consent, so tell the room it's being recorded." }
        return line
    }

    func stop() async -> String {
        guard let id = sid, let started = startedAt else { return "Nothing is recording." }
        let bg = UIApplication.shared.beginBackgroundTask(withName: "meeting-upload-tail")
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        let last = writer?.close() ?? 0
        engine = nil; writer = nil
        sessionObservers.forEach { NotificationCenter.default.removeObserver($0) }
        sessionObservers.removeAll()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        let stoppedAt = Date()
        if var m = MeetingUploader.readMeta(id) {
            m.chunks = max(m.chunks, last); m.stoppedAt = stoppedAt
            MeetingUploader.writeMeta(m)
        }
        sid = nil; startedAt = nil
        await updateActivity(recording: false, finished: false)
        await MeetingUploader.shared.kick()
        // Give the tail a minute to land while iOS lets us run; whatever is
        // left goes at the next launch.
        Task {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            UIApplication.shared.endBackgroundTask(bg)
        }
        let minutes = max(1, Int((stoppedAt.timeIntervalSince(started) / 60).rounded()))
        return "Stopped after \(minutes) minute\(minutes == 1 ? "" : "s"). Scarlet will file the meeting and tell you."
    }

    // MARK: progress → Live Activity

    private func progress(_ info: [AnyHashable: Any]) {
        guard let s = info["sid"] as? String else { return }
        let finished = info["finished"] as? Bool ?? false
        if s == sid || activity?.attributes.sid == s {
            uploadedMinutes = info["uploaded"] as? Int ?? uploadedMinutes
            pendingMinutes = info["pending"] as? Int ?? pendingMinutes
            Task { await updateActivity(recording: sid != nil, finished: finished) }
        }
    }

    private func startActivity(sid: String, startedAt: Date) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = MeetingRecordingAttributes.ContentState(startedAt: startedAt, recording: true, uploadedMinutes: 0,
                                                            pendingMinutes: 0, finished: false, consent: consent)
        activity = try? Activity.request(attributes: MeetingRecordingAttributes(sid: sid),
                                         content: .init(state: state, staleDate: nil), pushType: nil)
    }

    private func updateActivity(recording: Bool, finished: Bool) async {
        guard let a = activity else { return }
        let state = MeetingRecordingAttributes.ContentState(
            startedAt: a.content.state.startedAt, recording: recording, uploadedMinutes: uploadedMinutes,
            pendingMinutes: pendingMinutes, finished: finished, consent: a.content.state.consent)
        if finished && !recording {
            await a.end(.init(state: state, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(120)))
            activity = nil
        } else {
            await a.update(.init(state: state, staleDate: nil))
        }
    }

    // MARK: interruptions and route changes

    private func watchAudioSession() {
        let nc = NotificationCenter.default
        sessionObservers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            Task { @MainActor in self?.resume() }
        })
        sessionObservers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.resume() }
        })
    }

    /// After a phone call or a route change: same session, a fresh minute
    /// file in the new format, the engine running again.
    private func resume() {
        guard let eng = engine, let w = writer, sid != nil else { return }
        if eng.isRunning { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        let input = eng.inputNode
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return }
        w.rotate(format: format)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buf, _ in w.append(buf) }
        try? eng.start()
    }

    // MARK: launch

    /// A recording the app was killed in the middle of: its last minute was
    /// never closed (an AAC file without its index is unreadable), so it is
    /// dropped and the rest is finished and uploaded.
    static func recoverOrphans() {
        let root = MeetingUploader.root
        let sids = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for s in sids {
            guard var m = MeetingUploader.readMeta(s), m.stoppedAt == nil else { continue }
            if MeetingRecorder.shared.sid == s { continue }
            let open = MeetingUploader.chunkURL(s, m.chunks + 1)
            let when = (try? FileManager.default.attributesOfItem(atPath: open.path)[.modificationDate] as? Date) ?? Date()
            try? FileManager.default.removeItem(at: open)
            m.stoppedAt = when
            MeetingUploader.writeMeta(m)
        }
        Task { await MeetingUploader.shared.kick() }
    }
}

/// What the intents call in the app's process.
enum RecorderBridge {
    static func start(about: String?) async throws -> String { try await MeetingRecorder.shared.start(about: about) }
    static func stop() async -> String { await MeetingRecorder.shared.stop() }
    static func isRecording() async -> Bool { await MeetingRecorder.shared.isRecording }
}

/// Writes the tap's buffers into one AAC file per minute, on its own queue.
final class ChunkWriter: @unchecked Sendable {
    private let sid: String
    private let q = DispatchQueue(label: "scarlet.meeting.writer")
    private let onMinute: (Int) -> Void
    private var file: AVAudioFile?
    private var seq = 0
    private var frames: AVAudioFramePosition = 0
    private var perMinute: AVAudioFramePosition = 0
    private var format: AVAudioFormat?

    init(sid: String, onMinute: @escaping (Int) -> Void) {
        self.sid = sid
        self.onMinute = onMinute
    }

    func open(format: AVAudioFormat) throws {
        self.format = format
        try q.sync { try openNext() }
    }

    private func openNext() throws {
        guard let f = format else { return }
        seq += 1
        frames = 0
        perMinute = AVAudioFramePosition(f.sampleRate * 60)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: f.sampleRate,
            AVNumberOfChannelsKey: Int(f.channelCount),
            AVEncoderBitRateKey: 48_000 * Int(f.channelCount),
        ]
        file = try AVAudioFile(forWriting: MeetingUploader.chunkURL(sid, seq), settings: settings,
                               commonFormat: f.commonFormat, interleaved: f.isInterleaved)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        q.async { [self] in
            guard let file else { return }
            do { try file.write(from: buffer) } catch { return }
            frames += AVAudioFramePosition(buffer.frameLength)
            if frames >= perMinute { closeCurrent(); try? openNext() }
        }
    }

    /// A new format after a route change: close this minute early, open the next.
    func rotate(format: AVAudioFormat) {
        q.sync { [self] in
            closeCurrent()
            self.format = format
            try? openNext()
        }
    }

    private func closeCurrent() {
        guard file != nil else { return }
        file = nil   // AVAudioFile finalizes on release
        if frames > 0 { onMinute(seq) } else { try? FileManager.default.removeItem(at: MeetingUploader.chunkURL(sid, seq)); seq -= 1 }
    }

    /// Stop: close the open minute; returns the last minute written.
    func close() -> Int {
        q.sync { [self] in
            closeCurrent()
            return seq
        }
    }
}

/// Which recording-consent rule applies where he is (the commission:
/// Massachusetts is two-party, Israel one-party). Best effort from the last
/// known position; nil when it can't tell.
enum ConsentRule {
    static let twoPartyStates: Set<String> = ["CA", "CT", "DE", "FL", "IL", "MD", "MA", "MI", "MT", "NV", "NH", "OR", "PA", "WA",
        "California", "Connecticut", "Delaware", "Florida", "Illinois", "Maryland", "Massachusetts", "Michigan", "Montana",
        "Nevada", "New Hampshire", "Oregon", "Pennsylvania", "Washington"]

    static func current() async -> String? {
        guard let loc = CLLocationManager().location else {
            return TimeZone.current.identifier == "Asia/Jerusalem" ? "one-party" : nil
        }
        let pm: CLPlacemark? = await withTaskGroup(of: CLPlacemark?.self) { g in
            g.addTask { (try? await CLGeocoder().reverseGeocodeLocation(loc))?.first }
            g.addTask { try? await Task.sleep(nanoseconds: 3_000_000_000); return nil }
            let first = await g.next() ?? nil
            g.cancelAll()
            return first
        }
        guard let p = pm else { return nil }
        if p.isoCountryCode == "IL" { return "one-party" }
        if p.isoCountryCode == "US" {
            return twoPartyStates.contains(p.administrativeArea ?? "") ? "two-party" : "one-party"
        }
        return nil
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
