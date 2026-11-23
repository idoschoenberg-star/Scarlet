import ActivityKit
import AVFoundation
import CoreLocation
import Foundation
import SwiftUI
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
    private var starting = false
    private var progressObserver: NSObjectProtocol?
    private var sessionObservers: [NSObjectProtocol] = []

    var isRecording: Bool { sid != nil }
    /// The card this process owns (set before `sid` while a start is under way).
    var liveActivitySid: String? { activity?.attributes.sid }

    private init() {
        // A stop posted from any process (the widget extension, a control).
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            Task { @MainActor in
                guard MeetingRecorder.shared.isRecording else {
                    await MeetingRecorder.endStaleActivities(keeping: MeetingRecorder.shared.liveActivitySid)
                    return
                }
                let line = await MeetingRecorder.shared.stop()
                FlightRecorder.telemetry(kind: "recorder_intent", detail: ["op": "stop", "via": "signal", "line": line])
            }
        }, RecorderSignal.stopName as CFString, nil, .deliverImmediately)
        progressObserver = NotificationCenter.default.addObserver(forName: .meetingUploadProgress, object: nil, queue: .main) { [weak self] n in
            let info = n.userInfo ?? [:]
            Task { @MainActor in self?.progress(info) }
        }
    }

    // MARK: start / stop

    func start(about: String?) async throws -> String {
        if let _ = sid { return "Already recording." }
        if starting { return "Starting the recording." }
        starting = true
        defer { starting = false }
        guard TokenStore.token != nil else { return "Scarlet isn't signed in on this phone yet. Open Talk once and unlock it." }
        if Conversation.shared.state != .idle { return "You're in a live conversation with Scarlet. End it first, then start the recording." }

        // Siri still owns the audio while it hands the intent over (it has
        // just listened and is about to speak the answer), so the session can
        // refuse for a moment and the input can report a dead 0 Hz format.
        // Retry briefly instead of failing; never install a tap on a dead bus.
        let session = AVAudioSession.sharedInstance()
        if #available(iOS 17.0, *) {
            if AVAudioApplication.shared.recordPermission == .undetermined {
                _ = await AVAudioApplication.requestRecordPermission()
            }
            guard AVAudioApplication.shared.recordPermission == .granted else {
                return "Talk doesn't have the microphone. Allow it in Settings, Talk, Microphone."
            }
        }
        var lastError: Error?
        var live = false
        for attempt in 0..<6 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 400_000_000) }
            do {
                // Built-in mic on purpose (no Bluetooth input): the room, not an earbud.
                try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
                try session.setActive(true)
                live = session.isInputAvailable
                if live { break }
            } catch { lastError = error }
        }
        guard live else {
            if let lastError { NSLog("meeting recorder: audio session refused: \(lastError)") }
            return "The microphone isn't available right now. Try again in a moment."
        }

        let now = Date()
        let id = MeetingAPI.newSessionID(at: now)
        consent = await ConsentRule.current()
        let meta = MeetingMeta(sid: id, startedAt: now, stoppedAt: nil, device: "iphone",
                               titleHint: about?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                               consent: consent, tz: TimeZone.current.identifier,
                               chunks: 0, started: false, finished: false)
        MeetingUploader.writeMeta(meta)

        // The Live Activity first: an audio-recording intent is expected to
        // show one as the recording begins.
        startActivity(sid: id, startedAt: now)

        let w = ChunkWriter(sid: id) { seq in
            Task { @MainActor in
                if var m = MeetingUploader.readMeta(id) { m.chunks = max(m.chunks, seq); MeetingUploader.writeMeta(m) }
                await MeetingUploader.shared.kick()
            }
        }
        let eng = AVAudioEngine()
        var started = false
        do {
            try w.open()
            for attempt in 0..<6 {
                if attempt > 0 { try? await Task.sleep(nanoseconds: 400_000_000) }
                if MicTap.start(engine: eng, writer: w) { started = true; break }
            }
            if !started { throw NSError(domain: "ScarletRecorder", code: 2, userInfo: [NSLocalizedDescriptionKey: "microphone format unavailable"]) }
        } catch {
            MicTap.stop(engine: eng)
            _ = w.close()
            try? FileManager.default.removeItem(at: MeetingUploader.folder(id))
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            if let a = activity { await a.end(nil, dismissalPolicy: .immediate); activity = nil }
            return "The microphone isn't available right now. Try again in a moment."
        }

        engine = eng; writer = w; sid = id; startedAt = now
        uploadedMinutes = 0; pendingMinutes = 0
        watchAudioSession()
        RecorderControl.reload()
        await MeetingUploader.shared.kick()   // op=start goes now, so the server knows

        var line = "Recording. Say stop recording when you're done."
        if consent == "two-party" { line = "Recording. You're somewhere that needs everyone's consent, so tell the room it's being recorded." }
        return line
    }

    func stop() async -> String {
        guard let id = sid, let started = startedAt else {
            await MeetingRecorder.endStaleActivities(keeping: liveActivitySid)
            return "Nothing is recording."
        }
        let bg = UIApplication.shared.beginBackgroundTask(withName: "meeting-upload-tail")
        if let eng = engine { MicTap.stop(engine: eng) }
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
        RecorderControl.reload()
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

    /// An audio-recording intent must leave a Live Activity behind: the
    /// 2026-11-15 Siri crash was an App Intents assertion right after a start
    /// whose activity did not come up. Every outcome is reported, so the next
    /// one names its cause.
    private func startActivity(sid: String, startedAt: Date) {
        let enabled = ActivityAuthorizationInfo().areActivitiesEnabled
        let state = MeetingRecordingAttributes.ContentState(startedAt: startedAt, recording: true, uploadedMinutes: 0,
                                                            pendingMinutes: 0, finished: false, consent: consent)
        var failure = ""
        do {
            activity = try Activity.request(attributes: MeetingRecordingAttributes(sid: sid),
                                            content: .init(state: state, staleDate: nil), pushType: nil)
        } catch {
            failure = String(describing: error)
        }
        FlightRecorder.telemetry(kind: "recorder_activity", detail: [
            "sid": sid, "enabled": enabled, "started": activity != nil,
            "error": String(failure.prefix(300)),
            "app_state": UIApplication.shared.applicationState == .active ? "active" : "background",
        ])
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
        MicTap.stop(engine: eng)
        // The writer converts whatever the new route delivers into the
        // minute file's fixed format, so no file rotation is needed.
        _ = MicTap.start(engine: eng, writer: w)
    }

    // MARK: launch

    static func endStaleActivities(keeping sid: String?) async {
        for a in Activity<MeetingRecordingAttributes>.activities where a.attributes.sid != sid {
            var st = a.content.state
            st.recording = false
            await a.end(.init(state: st, staleDate: nil), dismissalPolicy: .immediate)
        }
        RecorderControl.reload()
    }

    /// A recording the app was killed in the middle of: its last minute was
    /// never closed (an AAC file without its index is unreadable), so it is
    /// dropped and the rest is finished and uploaded.
    static func recoverOrphans() {
        _ = MeetingRecorder.shared   // registers the cross-process stop observer
        // A card left by a recording this process does not own (the app was
        // killed mid-recording) would keep counting forever: end it.
        Task { await endStaleActivities(keeping: MeetingRecorder.shared.liveActivitySid) }
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
    static func start(about: String?) async throws -> String {
        let line = try await MeetingRecorder.shared.start(about: about)
        FlightRecorder.telemetry(kind: "recorder_intent", detail: ["op": "start", "line": line])
        return line
    }
    static func stop() async -> String {
        let line = await MeetingRecorder.shared.stop()
        FlightRecorder.telemetry(kind: "recorder_intent", detail: ["op": "stop", "via": "intent", "line": line])
        return line
    }
    static func isRecording() async -> Bool { await MeetingRecorder.shared.isRecording }
}

/// Installs and removes the recorder's tap, outside the main actor: the tap
/// block runs on the audio thread and must not inherit main-actor isolation.
enum MicTap {
    /// false when the input is not live yet (Siri still holding it, a call).
    nonisolated static func start(engine: AVAudioEngine, writer: ChunkWriter) -> Bool {
        let input = engine.inputNode
        let hw = input.inputFormat(forBus: 0)
        guard hw.sampleRate > 0, hw.channelCount > 0 else { return false }
        input.removeTap(onBus: 0)   // never stack taps: a second install crashes
        // format: nil binds the tap to the bus's live format at install time,
        // so a route change between a read and the install (Siri releasing
        // the audio, a Bluetooth handoff) can never raise the uncatchable
        // "format mismatch" exception. The writer converts each buffer.
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { buf, _ in writer.append(buf) }
        engine.prepare()
        do { try engine.start() } catch { input.removeTap(onBus: 0); return false }
        return true
    }

    nonisolated static func stop(engine: AVAudioEngine) {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
    }
}

/// Writes the tap's buffers into one AAC file per minute. Every minute file
/// has ONE fixed format (16 kHz mono, plenty for speech), and each buffer is
/// converted into it, so a buffer in another format (a new route, Siri's
/// session) can never reach the file.
final class ChunkWriter: @unchecked Sendable {
    static let fileFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    private let sid: String
    private let q = DispatchQueue(label: "scarlet.meeting.writer")
    private let onMinute: (Int) -> Void
    private var file: AVAudioFile?
    private var seq = 0
    private var frames: AVAudioFramePosition = 0
    private let perMinute = AVAudioFramePosition(16_000 * 60)
    private var converter: AVAudioConverter?
    private var converterIn: AVAudioFormat?
    private let convertLock = NSLock()

    init(sid: String, onMinute: @escaping (Int) -> Void) {
        self.sid = sid
        self.onMinute = onMinute
    }

    func open() throws {
        try q.sync { try openNext() }
    }

    private func openNext() throws {
        seq += 1
        frames = 0
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        file = try AVAudioFile(forWriting: MeetingUploader.chunkURL(sid, seq), settings: settings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    /// Called on the tap's thread. The tap's buffer is only valid during the
    /// callback, so it is copied (converted) before the hop to the queue.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0, buffer.format.sampleRate > 0 else { return }
        convertLock.lock()
        let converted = convert(buffer)
        convertLock.unlock()
        guard let out = converted else { return }
        q.async { [self] in
            guard let file else { return }
            do { try file.write(from: out) } catch { return }
            frames += AVAudioFramePosition(out.frameLength)
            if frames >= perMinute { closeCurrent(); try? openNext() }
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let target = ChunkWriter.fileFormat
        if converter == nil || converterIn != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            converterIn = buffer.format
        }
        guard let c = converter else { return nil }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 256
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return nil }
        var fed = false
        var err: NSError?
        let status = c.convert(to: out, error: &err) { _, st in
            if fed { st.pointee = .noDataNow; return nil }
            fed = true
            st.pointee = .haveData
            return buffer
        }
        if status == .error || out.frameLength == 0 { return nil }
        return out
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

/// The live recording bar (2026-11-18: tapping the Dynamic Island opened Talk
/// on a screen with no Stop). Shown above every screen while a meeting
/// records, so the island, the Lock Screen card and the app icon all land on
/// a visible Stop.
struct RecordingBar: View {
    @ObservedObject private var rec = MeetingRecorder.shared
    @State private var stopping = false

    var body: some View {
        if rec.isRecording, let started = rec.startedAt {
            HStack(spacing: 12) {
                Image(systemName: "record.circle.fill").foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Recording").font(.headline)
                        Text(timerInterval: started...Date.distantFuture, countsDown: false)
                            .font(.headline.monospacedDigit())
                    }
                    Text(rec.uploadedMinutes > 0 ? "Uploaded \(rec.uploadedMinutes) min" : "First minute uploads at 1:00")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    stopping = true
                    Task {
                        let line = await MeetingRecorder.shared.stop()
                        FlightRecorder.telemetry(kind: "recorder_intent", detail: ["op": "stop", "via": "app", "line": line])
                        stopping = false
                    }
                } label: {
                    Label(stopping ? "Stopping" : "Stop", systemImage: "stop.fill")
                        .font(.headline)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(stopping)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
