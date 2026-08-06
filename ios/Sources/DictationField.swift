import Foundation
import SwiftUI
import AVFoundation
import UIKit   // UIApplication.openSettingsURLString for the mic-denied recovery path

/// # Embedded dictation — tap a mic, whisper, the words fill the field
///
/// Ido's ask: pressing an input should let him just speak, with no keyboard at
/// all. iOS forbids force-activating a third-party keyboard (Wispr), so this is
/// OUR OWN embedded mic: it records a short clip, uploads it to the SAME Whisper
/// endpoint the rest of the app uses (`op=transcribe`), and drops the transcript
/// straight into the bound text.
///
/// ## Why it can never collide with a live voice call
/// The live conversation (`Conversation.shared`) owns an `AVAudioEngine` with a
/// tap installed on its input bus; a SECOND `installTap` is an instant crash.
/// This recorder uses a **standalone `AVAudioRecorder`** writing to a temp file
/// — it never touches that engine, so there is no second tap and no crash. It
/// also never DEACTIVATES the shared `AVAudioSession`, and only sets the record
/// category when the session isn't already record-capable: if a call is live
/// (already `.playAndRecord`) the session is left completely untouched, so a
/// live call is never degraded or interrupted. We also never construct a
/// `Conversation` (the pre-flight gate forbids it).
///
/// ## The pieces
///   • `DictationRecorder`  — @MainActor engine: permission, record, upload.
///   • `DictationMicButton` — the tappable mic glyph (record / stop / spinner).
///   • `DictationField`     — a drop-in TextField + trailing mic.
///   • `.dictatable(text:)` — adds a mic to any existing field with one line.

// MARK: - Recorder

/// Owns one `AVAudioRecorder`, records to a temp `.m4a` (AAC), then base64s the
/// clip to `op=transcribe` and hands back the words. All @Published mutation is
/// on the main actor; the `AVAudioRecorderDelegate` callbacks (which arrive on an
/// arbitrary thread) hop to the main actor before touching any state.
@MainActor
final class DictationRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {

    enum Phase: Equatable { case idle, recording, transcribing, denied, failed }

    @Published private(set) var phase: Phase = .idle

    /// True while the mic is actively capturing — drives the pulsing ring.
    var isRecording: Bool { phase == .recording }

    private var recorder: AVAudioRecorder?
    private var fileURL: URL?
    /// Held from stop() until the finished file is transcribed, so the delegate
    /// callback knows where to deliver the words.
    private var pendingOnText: ((String) -> Void)?

    /// AAC in an MPEG-4 container. 16 kHz mono is plenty for speech and keeps the
    /// base64 upload tiny. The server names the blob `voice.mp4` (our mime carries
    /// "mp4"), which Whisper decodes directly.
    private static let recordSettings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 16000.0,
        AVNumberOfChannelsKey: 1,
        AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
    ]

    /// The one entry point the button calls: idle → start; recording → stop and
    /// transcribe; mid-upload taps are ignored.
    func toggle(onText: @escaping (String) -> Void) {
        switch phase {
        case .recording:    stopAndTranscribe(onText: onText)
        case .transcribing: break
        default:            startRecording()
        }
    }

    private func startRecording() {
        Task { @MainActor in
            guard await ensurePermission() else { phase = .denied; return }
            do {
                let session = AVAudioSession.sharedInstance()
                // Only set the category if the session isn't already
                // record-capable — a live call owns `.playAndRecord` and must be
                // left untouched. Never deactivate on stop (see file header).
                if session.category != .playAndRecord && session.category != .record {
                    try session.setCategory(.playAndRecord, mode: .default,
                                            options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP])
                }
                try session.setActive(true)

                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("scarlet-dictation-\(UUID().uuidString).m4a")
                let rec = try AVAudioRecorder(url: url, settings: Self.recordSettings)
                rec.delegate = self
                guard rec.record() else { phase = .failed; scheduleFailedReset(); return }
                recorder = rec
                fileURL = url
                phase = .recording
            } catch {
                phase = .failed
                scheduleFailedReset()
            }
        }
    }

    private func stopAndTranscribe(onText: @escaping (String) -> Void) {
        guard let rec = recorder, rec.isRecording else { phase = .idle; return }
        pendingOnText = onText
        phase = .transcribing
        rec.stop()   // → audioRecorderDidFinishRecording(_:successfully:)
    }

    /// The clip finished writing — read it, upload it, deliver the words.
    private func finishRecording(success: Bool) {
        let deliver = pendingOnText
        pendingOnText = nil
        recorder?.delegate = nil
        recorder = nil
        guard success, let url = fileURL else {
            cleanupFile()
            phase = .failed
            scheduleFailedReset()
            return
        }
        Task { @MainActor in
            let result = await Self.transcribe(url: url)
            cleanupFile()
            switch result {
            case .text(let t):
                deliver?(t)
                phase = .idle
            case .empty, .failed:
                phase = .failed
                scheduleFailedReset()
            }
        }
    }

    /// Tear everything down without delivering — for the view disappearing
    /// mid-capture. Detach the delegate first so stop() fires no callback.
    func cancel() {
        recorder?.delegate = nil
        if let rec = recorder, rec.isRecording { rec.stop() }
        recorder = nil
        pendingOnText = nil
        cleanupFile()
        if phase == .recording || phase == .transcribing { phase = .idle }
    }

    private func cleanupFile() {
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
        fileURL = nil
    }

    /// A brief error flash that returns to idle on its own, so the mic never
    /// gets stuck on a failure.
    private func scheduleFailedReset() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if phase == .failed { phase = .idle }
        }
    }

    // MARK: permission (mirrors Conversation's proven gate)

    private func ensurePermission() async -> Bool {
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted: return true
        case .denied:  return false
        case .undetermined:
            return await withCheckedContinuation { cont in
                session.requestRecordPermission { ok in cont.resume(returning: ok) }
            }
        @unknown default:
            return false
        }
    }

    // MARK: AVAudioRecorderDelegate (arbitrary thread → hop to main)

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in self.finishRecording(success: flag) }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in self.finishRecording(success: false) }
    }

    // MARK: upload (same shape as DraftView.request — apiBase + x-scarlet-token)

    private enum TranscribeResult { case text(String), empty, failed }

    private static func transcribe(url: URL) async -> TranscribeResult {
        guard let clip = try? Data(contentsOf: url) else { return .failed }
        guard let endpoint = URL(string: "\(AppConfig.apiBase)/app-api?v=2&op=transcribe") else { return .failed }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue(TokenStore.token ?? "", forHTTPHeaderField: "x-scarlet-token")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = ["audio": clip.base64EncodedString(), "mime": "audio/mp4"]
        guard let httpBody = try? JSONSerialization.data(withJSONObject: payload) else { return .failed }
        req.httpBody = httpBody
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return .failed }
        // Server returns { ok, transcript }; accept `text` too, defensively.
        let words = ((obj["transcript"] as? String) ?? (obj["text"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return words.isEmpty ? .empty : .text(words)
    }
}

// MARK: - Mic button

/// The tappable mic glyph. Tap to start (glyph reddens, a soft ring pulses),
/// tap again to stop → a spinner while it transcribes → `onText` fires with the
/// words. Self-contained: it owns its recorder and cleans up if it disappears.
struct DictationMicButton: View {
    /// Called on the main actor with the finished transcript.
    var onText: (String) -> Void
    var tint: Color = Color(red: 1, green: 0.35, blue: 0.42)
    var size: CGFloat = 44

    @StateObject private var recorder = DictationRecorder()
    @State private var pulse = false

    var body: some View {
        Button {
            if recorder.phase == .denied {
                // Mic access is off — send him straight to the app's Settings
                // pane to turn it on, rather than silently doing nothing.
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } else {
                recorder.toggle(onText: onText)
            }
        } label: {
            glyph
        }
        .buttonStyle(.plain)
        .disabled(recorder.phase == .transcribing)
        .accessibilityLabel(label)
        .onChange(of: recorder.isRecording) { _, recording in
            if recording {
                withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) { pulse = true }
            } else {
                withAnimation(.easeInOut(duration: 0.2)) { pulse = false }
            }
        }
        .onDisappear { recorder.cancel() }
    }

    private var label: String {
        switch recorder.phase {
        case .recording:    return "Stop dictation"
        case .transcribing: return "Transcribing"
        case .denied:       return "Microphone access is off — open Settings"
        default:            return "Dictate — tap and speak"
        }
    }

    private var glyph: some View {
        ZStack {
            Circle()
                .fill(recorder.isRecording ? Color.red.opacity(0.16) : Color.white.opacity(0.08))
            // Listening ring: a soft pulse only while recording.
            if recorder.isRecording {
                Circle()
                    .stroke(Color.red.opacity(0.55), lineWidth: 2)
                    .scaleEffect(pulse ? 1.18 : 0.92)
                    .opacity(pulse ? 0.0 : 0.85)
            } else {
                Circle().stroke(tint.opacity(0.4), lineWidth: 1)
            }
            icon
        }
        .frame(width: size, height: size)
        .animation(.easeInOut(duration: 0.2), value: recorder.phase)
    }

    private var icon: some View {
        Group {
            switch recorder.phase {
            case .transcribing:
                ProgressView().controlSize(.small).tint(tint)
            case .denied:
                Image(systemName: "mic.slash.fill").foregroundStyle(.white.opacity(0.65))
            case .recording:
                Image(systemName: "mic.fill").foregroundStyle(Color.red)
            case .failed:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.yellow.opacity(0.85))
            case .idle:
                Image(systemName: "mic.fill").foregroundStyle(tint)
            }
        }
        .font(.system(size: size * 0.4, weight: .semibold))
    }
}

// MARK: - Drop-in field

/// A text input with an embedded mic: a `TextField` plus a trailing
/// `DictationMicButton`. The transcript APPENDS to whatever's there (a space
/// between), or fills the field when empty. Per-paragraph direction so mixed
/// Hebrew/English reads correctly (same rule the draft window uses).
struct DictationField: View {
    let title: String
    @Binding var text: String
    /// `.vertical` grows to multiple lines; `.horizontal` stays a single line.
    var axis: Axis = .horizontal
    var lineLimit: ClosedRange<Int> = 1...4
    var font: Font = .scarletBody
    var tint: Color = Color(red: 1, green: 0.35, blue: 0.42)
    var micSize: CGFloat = 44

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            field
            DictationMicButton(onText: appendTranscript, tint: tint, size: micSize)
        }
    }

    @ViewBuilder
    private var field: some View {
        let rtl = text.isRTLDominant
        Group {
            if axis == .vertical {
                TextField(title, text: $text, axis: .vertical)
                    .lineLimit(lineLimit)
            } else {
                TextField(title, text: $text)
            }
        }
        .font(font)
        .multilineTextAlignment(rtl ? .trailing : .leading)
        .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
        .padding(11)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
    }

    private func appendTranscript(_ words: String) {
        text = Self.merge(existing: text, adding: words)
    }

    /// Append with a single space, or replace when the field is empty.
    static func merge(existing: String, adding words: String) -> String {
        let base = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? words : base + " " + words
    }
}

// MARK: - Convenience modifier

extension View {
    /// Give any existing input control an embedded dictation mic with one line:
    /// `TextField(...).dictatable(text: $mealText)`. Wraps the field in an HStack
    /// with a trailing `DictationMicButton` that appends the transcript to `text`.
    func dictatable(text: Binding<String>,
                    tint: Color = Color(red: 1, green: 0.35, blue: 0.42),
                    size: CGFloat = 44) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            self
            DictationMicButton(
                onText: { words in
                    text.wrappedValue = DictationField.merge(existing: text.wrappedValue, adding: words)
                },
                tint: tint,
                size: size)
        }
    }
}
