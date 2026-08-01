import Foundation
import AVFoundation
import Combine

/// Native ElevenLabs conversational client. Same protocol the web app speaks,
/// but over a real AVAudioSession so the conversation never stalls: it keeps
/// running with the screen locked, and pauses/resumes cleanly on interruptions.
@MainActor
final class Conversation: ObservableObject {
    enum State { case idle, connecting, listening, speaking }

    struct Line: Identifiable { let id = UUID(); let text: String; let fromHer: Bool }

    @Published var state: State = .idle
    @Published var status = "Waking her up…"
    @Published var transcript: [Line] = []
    @Published var micOn = true
    @Published var speakerOn = true
    @Published var loudspeaker = true   // route: iPhone speaker vs. call earpiece

    private var ws: URLSessionWebSocketTask?
    private lazy var wsSession = URLSession(configuration: .default)
    private var token = ""
    private var outputRate: Double = 16000

    // Reconnect discipline: one loop at a time, only while the user wants live.
    private var wantLive = false
    private var reconnecting = false
    private var observersInstalled = false

    // Audio — built once, reused across reconnects. Re-running mic setup
    // (a second installTap on the same bus) is an instant NSException crash.
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var converter: AVAudioConverter?
    private var playFormat: AVAudioFormat?
    private var audioReady = false

    // MARK: lifecycle

    func start(token: String) {
        guard state == .idle else { return }
        self.token = token
        wantLive = true
        state = .connecting
        Task { await connect() }
        observeInterruptions()
    }

    func end() {
        wantLive = false
        ws?.cancel(with: .goingAway, reason: nil)
        ws = nil
        stopAudio()
        state = .idle
        status = "Ended. Press your Scarlet button anytime."
    }

    func toggleMic() { micOn.toggle(); status = micOn ? "Listening…" : "Mic off — tap Mic to talk" }
    func toggleSpeaker() { speakerOn.toggle(); player.volume = speakerOn ? 1 : 0 }

    /// Loudspeaker ⇄ earpiece. Only touches the route when the phone itself is
    /// playing — AirPods/CarPlay keep priority either way.
    func toggleLoudspeaker() {
        loudspeaker.toggle()
        let s = AVAudioSession.sharedInstance()
        if loudspeaker { routeToSpeakerIfReceiver() }
        else { try? s.overrideOutputAudioPort(.none) }
    }

    /// Dictated/typed input: goes to her exactly like speech.
    func sendText(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        transcript.append(.init(text: t, fromHer: false))
        send(["type": "user_message", "text": t])
    }

    // MARK: signed URL + socket

    private func connect() async {
        do {
            var req = URLRequest(url: AppConfig.elevenURL)
            req.httpMethod = "POST"
            req.setValue(token, forHTTPHeaderField: "x-scarlet-token")
            let (data, _) = try await URLSession.shared.data(for: req)
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let signed = obj?["signed_url"] as? String, let url = URL(string: signed) else {
                status = "Couldn't start — try again."; state = .idle; wantLive = false; return
            }
            try ensureAudio()
            let task = wsSession.webSocketTask(with: url)
            ws = task
            task.resume()
            send(["type": "conversation_initiation_client_data"])
            listen()
            state = .listening
            status = micOn ? "Listening…" : "Mic off — tap Mic to talk"
        } catch {
            if wantLive { scheduleReconnect() } else { status = "Couldn't connect — tap to retry."; state = .idle }
        }
    }

    private func listen() {
        ws?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                Task { @MainActor in self.scheduleReconnect() }
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

    /// Silent auto-reconnect, native edition of the web app's transport-drop
    /// handler. Single-flight; audio graph stays up, only the socket rebuilds.
    private func scheduleReconnect() {
        guard wantLive, !reconnecting else { return }
        reconnecting = true
        status = "Reconnecting…"
        ws?.cancel(with: .goingAway, reason: nil)
        ws = nil
        Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            if wantLive { await connect() }
            reconnecting = false
        }
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
               let hz = Int(fmt.components(separatedBy: CharacterSet(charactersIn: "_")).last ?? ""),
               Double(hz) != outputRate {
                outputRate = Double(hz)
                rebuildPlayback()
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
        routeToSpeakerIfReceiver()
    }

    /// Voice-chat sessions love falling back to the phone-call earpiece, which
    /// sounds "very faint". Force the loudspeaker — but only when the route IS
    /// the earpiece, so AirPods/CarPlay stay untouched.
    private func routeToSpeakerIfReceiver() {
        guard loudspeaker else { return }
        let s = AVAudioSession.sharedInstance()
        if s.currentRoute.outputs.contains(where: { $0.portType == .builtInReceiver }) {
            try? s.overrideOutputAudioPort(.speaker)
        }
    }

    /// Idempotent: builds the audio graph exactly once; later calls just make
    /// sure the engine is running.
    private func ensureAudio() throws {
        if audioReady {
            if !engine.isRunning { try engine.start() }
            return
        }
        try startAudioSession()

        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                                   channels: 1, interleaved: true)!
        converter = AVAudioConverter(from: inFormat, to: target)

        engine.attach(player)
        // Player speaks standard Float32 — mixer connections in exotic formats
        // are exactly the kind of thing AVAudioEngine throws exceptions over.
        playFormat = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 1)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)

        input.removeTap(onBus: 0)   // never stack taps — a second install crashes
        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buffer, _ in
            guard let self, let converter = self.converter else { return }
            let ratio = 16000.0 / inFormat.sampleRate
            let outCap = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCap) else { return }
            var fed = false
            var err: NSError?
            converter.convert(to: out, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return buffer
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
        engine.prepare()
        try engine.start()
        engine.mainMixerNode.outputVolume = 1.0
        audioReady = true
    }

    /// Server announced a different output rate — rewire only the player leg.
    private func rebuildPlayback() {
        guard audioReady else { return }
        player.stop()
        engine.disconnectNodeOutput(player)
        playFormat = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 1)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)
    }

    private func playPCM(base64: String) {
        guard let data = Data(base64Encoded: base64),
              let fmt = playFormat else { return }
        let frames = AVAudioFrameCount(data.count / 2)
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames),
              let ch = buf.floatChannelData else { return }
        buf.frameLength = frames
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<Int(frames) { ch[0][i] = Float(samples[i]) / 32768.0 }
        }
        if !engine.isRunning { try? engine.start() }
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
        guard audioReady else { return }
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        audioReady = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: interruptions — the flow guarantee

    private func observeInterruptions() {
        guard !observersInstalled else { return }
        observersInstalled = true
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
                    if self.wantLive, !self.engine.isRunning { try? self.engine.start() }
                default: break
                }
            }
        }
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                if self.wantLive, !self.engine.isRunning { try? self.engine.start() }
                if self.wantLive { self.routeToSpeakerIfReceiver() }
            }
        }
    }
}
