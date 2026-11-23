import AVFoundation
import Foundation
import Observation

/// The Watch's meeting recorder (commission 2026-11-07, the capture layer):
/// for the meeting where the phone is in a bag. Same pipe as the iPhone
/// (`MeetingUploader`, one minute at a time to `meeting-capture`), recorded
/// with AVAudioRecorder, one file per minute, kept running with the wrist
/// down by the audio background mode. Uploads straight from the Watch on
/// Wi-Fi or cellular; anything left is sent at the next launch.
@MainActor
@Observable
final class WatchMeetingRecorder {
    static let shared = WatchMeetingRecorder()
    private init() {}

    private(set) var sid: String?
    private(set) var startedAt: Date?
    private(set) var status = ""
    private var recorder: AVAudioRecorder?
    private var seq = 0
    private var timer: Timer?

    var isRecording: Bool { sid != nil }

    func toggle() {
        if isRecording { stop() } else { start() }
    }

    func start() {
        guard sid == nil else { return }
        guard TokenStore.token != nil else { status = "Unlock Scarlet first."; return }
        guard WatchConversation.shared.state == .idle else { status = "End the conversation first."; return }
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playAndRecord, mode: .default)
            try s.setActive(true)
        } catch { status = "The microphone isn't available."; return }
        let now = Date()
        let id = MeetingAPI.newSessionID(at: now)
        MeetingUploader.writeMeta(MeetingMeta(sid: id, startedAt: now, stoppedAt: nil, device: "watch", titleHint: nil,
                                              consent: nil, tz: TimeZone.current.identifier, chunks: 0, started: false, finished: false))
        sid = id; startedAt = now; seq = 0
        guard openNext() else { abandon(id); status = "Recording didn't start."; return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.rotate() }
        }
        status = "Recording"
        Task { await MeetingUploader.shared.kick() }
    }

    func stop() {
        guard let id = sid else { return }
        timer?.invalidate(); timer = nil
        recorder?.stop(); recorder = nil
        if var m = MeetingUploader.readMeta(id) {
            m.chunks = max(m.chunks, seq); m.stoppedAt = Date()
            MeetingUploader.writeMeta(m)
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        sid = nil; startedAt = nil
        status = "Stopped. Scarlet will file it."
        Task { await MeetingUploader.shared.kick() }
    }

    private func openNext() -> Bool {
        guard let id = sid else { return false }
        seq += 1
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        guard let r = try? AVAudioRecorder(url: MeetingUploader.chunkURL(id, seq), settings: settings), r.record() else { return false }
        recorder = r
        return true
    }

    /// Close this minute (the file is finalized on stop), hand it to the
    /// uploader, open the next.
    private func rotate() {
        guard let id = sid else { return }
        recorder?.stop()
        if var m = MeetingUploader.readMeta(id) { m.chunks = seq; MeetingUploader.writeMeta(m) }
        _ = openNext()
        Task { await MeetingUploader.shared.kick() }
    }

    private func abandon(_ id: String) {
        try? FileManager.default.removeItem(at: MeetingUploader.folder(id))
        sid = nil; startedAt = nil
    }

    /// A recording the Watch app was killed in: drop the unclosed minute,
    /// finish the rest.
    static func recoverOrphans() {
        let sids = (try? FileManager.default.contentsOfDirectory(atPath: MeetingUploader.root.path)) ?? []
        for s in sids where s != shared.sid {
            guard var m = MeetingUploader.readMeta(s), m.stoppedAt == nil else { continue }
            try? FileManager.default.removeItem(at: MeetingUploader.chunkURL(s, m.chunks + 1))
            m.stoppedAt = Date()
            MeetingUploader.writeMeta(m)
        }
        Task { await MeetingUploader.shared.kick() }
    }
}
