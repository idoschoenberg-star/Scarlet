import Foundation
import AVFoundation
import Combine

/// Native ElevenLabs conversational client. Same protocol the web app speaks,
/// but over a real AVAudioSession so the conversation never stalls: it keeps
/// running with the screen locked, and pauses/resumes cleanly on interruptions.
///
/// NOTE: this is written against the protocol we already implemented in JS and
/// will get its compile/tune pass in the first CI build.
@MainActor
final class Conversation: ObservableObject {
    enum State { case idle, connecting, listening, speaking }

    struct Line: Identifiable { let id = UUID(); let text: String; let fromHer: Bool }

    @Published var state: State = .idle
    @Published var status = "Waking her up…"
    @Published var transcript: [Line] = []
    @Published var micOn = true
    @Published var speakerOn = true

    private var ws: URLSessionWebSocketTask?
    private var token = ""
    private var outputRate: Double = 16000

    // Audio
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var converter: AVAudioConverter?
    private var playFormat: AVAudioFormat?

    // MARK: lifecycle

    func start(token: String) {
        guard state == .idle else { return }
        self.token = token
        state = .connecting
        Task { await connect() }
        observeInterruptions()
    }

    func end() {
        ws?.cancel(with: .goingAway, reason: nil)
        ws = nil
        stopAudio()
        state = .idle
        status = "Ended. Press your Scarlet button anytime."
    }

    func toggleMic() { micOn.toggle(); status = micOn ? "Listening…" : "Mic off — tap Mic to talk" }
    func toggleSpeaker() { speakerOn.toggle(); player.volume = speakerOn ? 1 : 0 }

    // MARK: signed URL + socket

    private func connect() async {
        do {
            var req = URLRequest(url: AppConfig.elevenURL)
            req.httpMethod = "POST"
            req.setValue(token, forHTTPHeaderField: "x-scarlet-token")
            let (data, _) = try await URLSession.shared.data(for: req)
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let signed = obj?["signed_url"] as? String, let url = URL(string: signed) else {
                status = "Couldn't start — try again."; state = .idle; return
            }
            try startAudioSession()
            let task = URLSession(configuration: .default).webSocketTask(with: url)
            ws = task
            task.resume()
            send(["type": "conversation_initiation_client_data"])
            listen()
            startCapture()
            state = .listening
            status = "Listening…"
        } catch {
            status = "Couldn't connect — tap to retry."; state = .idle
        }
    }

    private func listen() {
        ws?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                Task { @MainActor in if self.state != .idle { self.reconnectSoon() } }
            case .success(let msg):
                if case .string(let text) = msg,
                   let data = text.data(using: .utf8),
                   let ev = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    Task { @MainActor in self.handle(ev) }
                }
                self.listen()
            }
        }
    }

    private func reconnectSoon() {
        // The flow watchdog, native edition: a dropped socket reconnects.
        guard state != .idle else { return }
        status = "Reconnecting…"
        ws = nil
        Task { try? await Task.sleep(nanoseconds: 800_000_000); await connect() }
    }

    private func send(_ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: d, encoding: .utf8) else { return }
        ws?.send(.string(s)) { _ in }
    }

    // MARK: protocol

    private func handle(_ ev: [String: Any]) {
        switch ev["type"] as? String {
        case "conversation_initiation_metadata":
            if let m = ev["conversation_initiation_metadata_event"] as? [String: Any],
               let fmt = m["agent_output_audio_format"] as? String,
               let hz = Int(fmt.components(separatedBy: CharacterSet(charactersIn: "_")).last ?? "") {
                outputRate = Double(hz)
            }
        case "audio":
            if let a = ev["audio_event"] as? [String: Any], let b64 = a["audio_base_64"] as? String {
                playPCM(base64: b64)
            }
        case "agent_response":
            if let x = ev["agent_response_event"] as? [String: Any],
               let t = (x["agent_response"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !t.isEmpty { transcript.append(.init(text: t, fromHer: true)) }
        case "user_transcript":
            if let x = ev["user_transcription_event"] as? [String: Any],
               let t = (x["user_transcript"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !t.isEmpty { transcript.append(.init(text: t, fromHer: false)) }
        case "interruption":
            flushPlayback()
        case "ping":
            let id = (ev["ping_event"] as? [String: Any])?["event_id"]
            send(["type": "pong", "event_id": id as Any])
        case "client_tool_call":
            if let c = ev["client_tool_call"] as? [String: Any] { runTool(c) }
        default: break
        }
    }

    private func runTool(_ c: [String: Any]) {
        let name = c["tool_name"] as? String ?? ""
        let callId = c["tool_call_id"] as? String ?? ""
        let params = c["parameters"] as? [String: Any] ?? [:]
        Task {
            var out = "{}"
            do {
                var req = URLRequest(url: AppConfig.toolURL(name))
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.setValue(token, forHTTPHeaderField: "x-scarlet-token")
                req.httpBody = try JSONSerialization.data(withJSONObject: params)
                let (data, _) = try await URLSession.shared.data(for: req)
                out = String(data: data, encoding: .utf8) ?? "{}"
            } catch { out = "{\"error\":\"tool failed\"}" }
            send(["type": "client_tool_result", "tool_call_id": callId,
                  "result": String(out.prefix(30000)), "is_error": false])
        }
    }

    // MARK: audio session + capture + playback

    private func startAudioSession() throws {
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playAndRecord, mode: .voiceChat,
                          options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP])
        try s.setActive(true)
    }

    private func startCapture() {
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                                   channels: 1, interleaved: true)!
        converter = AVAudioConverter(from: inFormat, to: target)

        engine.attach(player)
        playFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: outputRate,
                                   channels: 1, interleaved: true)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)

        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buffer, _ in
            guard let self, let converter = self.converter else { return }
            let ratio = 16000.0 / inFormat.sampleRate
            let outCap = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCap) else { return }
            var err: NSError?
            converter.convert(to: out, error: &err) { _, status in
                status.pointee = .haveData; return buffer
            }
            guard err == nil, out.frameLength > 0,
                  let ch = out.int16ChannelData else { return }
            let bytes = Int(out.frameLength) * 2
            let data = Data(bytes: ch[0], count: bytes)
            Task { @MainActor in
                guard self.micOn else { return }
                self.send(["user_audio_chunk": data.base64EncodedString()])
            }
        }
        do { try engine.start() } catch { status = "Audio start failed" }
    }

    private func playPCM(base64: String) {
        guard let data = Data(base64Encoded: base64),
              let fmt = playFormat else { return }
        let frames = AVAudioFrameCount(data.count / 2)
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames),
              let ch = buf.int16ChannelData else { return }
        buf.frameLength = frames
        data.withUnsafeBytes { raw in
            memcpy(ch[0], raw.baseAddress!, data.count)
        }
        if !player.isPlaying { player.play() }
        state = .speaking
        status = speakerOn ? "Scarlet is speaking…" : "Answering silently — read below"
        player.scheduleBuffer(buf) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.state == .speaking { self.state = .listening; self.status = self.micOn ? "Listening…" : self.status }
            }
        }
    }

    private func flushPlayback() {
        player.stop()
        state = .listening
        if micOn { status = "Listening…" }
    }

    private func stopAudio() {
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: interruptions — the flow guarantee

    private func observeInterruptions() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            Task { @MainActor in
                switch type {
                case .began:
                    self.player.pause()
                case .ended:
                    try? self.startAudioSession()
                    if self.state != .idle, !self.engine.isRunning { try? self.engine.start() }
                    if self.player.isPlaying == false { self.player.play() }
                default: break
                }
            }
        }
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in if self.state != .idle, !self.engine.isRunning { try? self.engine.start() } }
        }
    }
}
