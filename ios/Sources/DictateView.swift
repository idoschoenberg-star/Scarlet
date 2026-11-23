import SwiftUI
import AVFoundation

/// DICTATE MODE (Ido 2026-08-28): "in conversation I am often cut off, or she
/// goes into a long speech and I can't interrupt — for real work I use the
/// keyboard with Wispr Flow." This is the native answer: a transcription-only
/// Realtime session (realtime-session?dictate=1) — his audio in, live text
/// out, and STRUCTURALLY nothing can speak back or close his turn: the
/// session has no assistant, no voice, no tools. He speaks as long as he
/// likes, watches the words land, edits inline, then sends the final text
/// into the normal spine (op=send → captures → routing) exactly as if typed.
///
/// The engine is deliberately NOT Conversation.shared (double audio tap =
/// instant crash, CLAUDE.md); it owns a small AVAudioEngine of its own and
/// runs only while the conversation is idle — TalkView ends any live session
/// before presenting this cover.
@MainActor
final class DictationEngine: NSObject, ObservableObject, URLSessionWebSocketDelegate {
    enum DState: Equatable { case idle, connecting, listening, paused, error(String) }

    @Published var state: DState = .idle
    /// Committed transcript — bound to the editor, so his edits are the truth.
    @Published var transcript = ""
    /// In-flight segment (delta stream) — shown live under the editor.
    @Published var partial = ""
    /// Mic energy 0…1 for the level bars — motion is ground truth he's heard.
    @Published var level: Float = 0

    private var ws: URLSessionWebSocketTask?
    private let audio = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var tapInstalled = false
    private var sending = false          // gate: false while paused
    private var wantLive = false         // user intent — survives reconnects
    private var reconnects = 0

    // MARK: session lifecycle

    func start() {
        guard state == .idle || state == .paused else { return }
        wantLive = true
        reconnects = 0
        state = .connecting
        Task { await connect() }
    }

    private func connect() async {
        // 1) Mint a transcription-only session (fast path — one round-trip).
        guard let mintURL = URL(string: AppConfig.realtimeURL.absoluteString + "?dictate=1") else { return }
        var req = URLRequest(url: mintURL)
        req.httpMethod = "POST"
        req.setValue(TokenStore.token ?? "", forHTTPHeaderField: "x-scarlet-token")
        var secret = ""
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let s = obj?["client_secret"] as? String, !s.isEmpty else {
                state = .error("Couldn't start dictation — try again in a moment.")
                wantLive = false
                return
            }
            secret = s
        } catch {
            state = .error("No connection — dictation needs the network.")
            wantLive = false
            return
        }
        guard wantLive else { return }

        // 2) Open the socket. `intent=transcription` matches the session type
        // minted server-side; the ephemeral secret carries the full config.
        guard let wsURL = URL(string: "wss://api.openai.com/v1/realtime?intent=transcription") else { return }
        var wsReq = URLRequest(url: wsURL)
        wsReq.setValue("Bearer " + secret, forHTTPHeaderField: "Authorization")
        let sess = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = sess.webSocketTask(with: wsReq)
        ws = task
        task.resume()
        receiveLoop(task)

        // 3) Mic on.
        do { try ensureAudio() } catch {
            state = .error("Can't reach the microphone — check it's not held by another app.")
            stop()
            return
        }
        sending = true
        state = .listening
    }

    /// Pause = stop streaming audio (socket + engine stay warm); Resume = flow again.
    func togglePause() {
        guard state == .listening || state == .paused else { return }
        sending.toggle()
        state = sending ? .listening : .paused
        if !sending { level = 0 }
    }

    func stop() {
        wantLive = false
        sending = false
        ws?.cancel(with: .normalClosure, reason: nil)
        ws = nil
        if tapInstalled {
            audio.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if audio.isRunning { audio.stop() }
        converter = nil
        level = 0
        if state != .idle { state = .idle }
    }

    // MARK: audio capture → 24 kHz PCM16 mono → base64 append events

    private func ensureAudio() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .allowBluetooth])
        try session.setActive(true)
        let input = audio.inputNode
        let inFormat = input.inputFormat(forBus: 0)
        // A 0 Hz / 0-channel format means the mic isn't real yet — installTap
        // with it is an instant NSException (Conversation's hard lesson).
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw NSError(domain: "dictate", code: 1)
        }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000,
                                         channels: 1, interleaved: true),
              let conv = AVAudioConverter(from: inFormat, to: target) else {
            throw NSError(domain: "dictate", code: 2)
        }
        converter = conv
        if !tapInstalled {
            input.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buffer, _ in
                self?.handleBuffer(buffer)
            }
            tapInstalled = true
        }
        audio.prepare()
        try audio.start()
    }

    private nonisolated func handleBuffer(_ buffer: AVAudioPCMBuffer) {
        Task { @MainActor [weak self] in
            guard let self, self.sending, let conv = self.converter, let task = self.ws else { return }
            // Level meter (RMS on the raw float buffer) — motion = being heard.
            if let ch = buffer.floatChannelData?[0] {
                let n = Int(buffer.frameLength)
                if n > 0 {
                    var acc: Float = 0
                    var i = 0
                    while i < n { acc += ch[i] * ch[i]; i += 64 }
                    let rms = sqrtf(acc / Float(max(1, n / 64)))
                    self.level = min(1, rms * 14)
                }
            }
            // Convert to 24 kHz PCM16 mono.
            let ratio = 24000.0 / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
            guard let out = AVAudioPCMBuffer(pcmFormat: conv.outputFormat, frameCapacity: capacity) else { return }
            var fed = false
            conv.convert(to: out, error: nil) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return buffer
            }
            guard out.frameLength > 0, let ints = out.int16ChannelData?[0] else { return }
            let bytes = Data(bytes: ints, count: Int(out.frameLength) * 2)
            let msg: [String: Any] = ["type": "input_audio_buffer.append",
                                      "audio": bytes.base64EncodedString()]
            if let payload = try? JSONSerialization.data(withJSONObject: msg),
               let text = String(data: payload, encoding: .utf8) {
                task.send(.string(text)) { _ in }
            }
        }
    }

    // MARK: transcript events in

    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.ws === task else { return }
                switch result {
                case .success(let message):
                    if case .string(let text) = message { self.handleEvent(text) }
                    self.receiveLoop(task)
                case .failure:
                    // The socket died mid-dictation. His words are safe (they
                    // live in `transcript`, not the session) — reconnect
                    // quietly up to 3 times and keep going.
                    guard self.wantLive else { return }
                    self.reconnects += 1
                    if self.reconnects <= 3 {
                        self.state = .connecting
                        await self.connect()
                    } else {
                        self.state = .error("Connection lost — your text is safe. Tap the mic to resume.")
                    }
                }
            }
        }
    }

    private func handleEvent(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "conversation.item.input_audio_transcription.delta":
            if let d = obj["delta"] as? String { partial += d }
        case "conversation.item.input_audio_transcription.completed":
            let t = (obj["transcript"] as? String ?? partial).trimmingCharacters(in: .whitespacesAndNewlines)
            partial = ""
            guard !t.isEmpty else { return }
            transcript += (transcript.isEmpty ? "" : "\n") + t
        case "error":
            let msg = ((obj["error"] as? [String: Any])?["message"] as? String) ?? "session error"
            // Schema/auth errors are terminal for this session; the reconnect
            // path in receiveLoop handles transport drops.
            state = .error(msg)
        default:
            break
        }
    }
}

/// Full-screen dictation surface: dark like TalkView, a big editable
/// transcript (per-paragraph direction via TextDirection), a live level
/// strip, and three verbs — Send to Scarlet, Copy, Discard.
struct DictateView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var engine = DictationEngine()
    @State private var sendState: SendState = .ready
    @FocusState private var editing: Bool

    enum SendState: Equatable { case ready, sending, failed }

    var body: some View {
        VStack(spacing: 14) {
            // Header: state + close.
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text(statusLabel)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                Spacer()
                Button {
                    engine.stop(); dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 44, height: 44)
                }
            }
            .padding(.top, 8)

            // The transcript — his words, editable the moment they land.
            ZStack(alignment: .topLeading) {
                if engine.transcript.isEmpty && engine.partial.isEmpty && !editing {
                    Text("Speak freely — pauses are fine.\nThe words appear here as you talk; tap to edit any of it.")
                        .font(.system(size: 17))
                        .foregroundStyle(.white.opacity(0.35))
                        .padding(.top, 14)
                        .padding(.horizontal, 10)
                }
                TextEditor(text: $engine.transcript)
                    .focused($editing)
                    .font(.system(size: 19))
                    .scrollContentBackground(.hidden)
                    .foregroundStyle(.white)
                    .environment(\.layoutDirection, engine.transcript.layoutDir)
                    .multilineTextAlignment(engine.transcript.isRTLDominant ? .trailing : .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.06)))

            // The in-flight line, visibly "still being written".
            if !engine.partial.isEmpty {
                Text(engine.partial)
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity,
                           alignment: engine.partial.isRTLDominant ? .trailing : .leading)
                    .environment(\.layoutDirection, engine.partial.layoutDir)
                    .padding(.horizontal, 6)
            }

            // Level strip — flat means not being heard, motion is ground truth.
            LevelStrip(level: engine.level, active: engine.state == .listening)

            if case .error(let msg) = engine.state {
                Text(msg)
                    .font(.system(size: 13))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Verbs.
            HStack(spacing: 12) {
                // Mic pause/resume — also the "resume after error" button.
                Button {
                    if case .error = engine.state { engine.start() } else { engine.togglePause() }
                } label: {
                    Image(systemName: engine.state == .listening ? "pause.fill" : "mic.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 54, height: 46)
                        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.12)))
                        .foregroundStyle(.white)
                }
                Button {
                    UIPasteboard.general.string = finalText()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 17))
                        .frame(width: 54, height: 46)
                        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.12)))
                        .foregroundStyle(.white)
                }
                .disabled(finalText().isEmpty)

                // Send into the spine — same as typing it to Scarlet.
                Button { Task { await send() } } label: {
                    HStack(spacing: 8) {
                        if sendState == .sending { ProgressView().tint(.black) }
                        Text(sendState == .failed ? "Retry send" : "Send to Scarlet")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(RoundedRectangle(cornerRadius: 12)
                        .fill(Color(red: 0.98, green: 0.85, blue: 0.85)))
                    .foregroundStyle(.black)
                }
                .disabled(finalText().isEmpty || sendState == .sending)
            }
            .padding(.bottom, 10)
        }
        .padding(.horizontal, 16)
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear { engine.start() }
        .onDisappear { engine.stop() }
    }

    private var statusColor: Color {
        switch engine.state {
        case .listening: return .green
        case .connecting: return .yellow
        case .paused: return .orange
        case .error: return .red
        case .idle: return .gray
        }
    }
    private var statusLabel: String {
        switch engine.state {
        case .listening: return "Dictating — she will not interrupt"
        case .connecting: return "Connecting…"
        case .paused: return "Paused"
        case .error: return "Stopped"
        case .idle: return "Dictation"
        }
    }

    private func finalText() -> String {
        (engine.transcript + (engine.partial.isEmpty ? "" : "\n" + engine.partial))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func send() async {
        let text = finalText()
        guard !text.isEmpty else { return }
        sendState = .sending
        engine.togglePauseIfListening()
        do {
            _ = try await ChatsAPI.request("op=send", method: "POST", body: ["text": text])
            engine.stop()
            dismiss()
        } catch {
            sendState = .failed
        }
    }
}

extension DictationEngine {
    /// Pause capture before a send so trailing room noise cannot append a
    /// stray segment underneath the text he just approved.
    func togglePauseIfListening() { if state == .listening { togglePause() } }
}

/// Minimal level bars (self-contained — no dependency on the conversation's
/// meter singleton, which must stay single-owner).
private struct LevelStrip: View {
    var level: Float
    var active: Bool
    private let bars = 24

    private func barHeight(_ i: Int) -> CGFloat {
        guard active else { return 3 }
        let phase: Double = sin(Double(i) / Double(bars) * Double.pi)
        let scaled: Double = Double(level) * 26.0 * (0.4 + 0.6 * phase)
        return CGFloat(max(3.0, scaled))
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<bars, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(active ? Color(red: 0.98, green: 0.85, blue: 0.85) : Color.white.opacity(0.25))
                    .frame(width: 3, height: barHeight(i))
                    .animation(.linear(duration: 0.08), value: level)
            }
        }
        .frame(height: 30)
    }
}
