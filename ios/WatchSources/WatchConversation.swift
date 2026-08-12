import AVFoundation
import Foundation
import Observation
import WatchKit

/// The wrist port of the phone's Conversation: same server brain (persona,
/// tools, semantic VAD all live in realtime-session), same wire protocol
/// (24 kHz PCM16 over the OpenAI Realtime socket), same authorized tool
/// proxy — reduced to what a watch actually is: one mic, one speaker (or
/// AirPods), one screen, a battery that matters.
///
/// Two modes, per the roadmap staging:
///  - tapToTalk (v1): the mic streams only while ARMED. Tap the orb, speak;
///    semantic VAD commits the turn and the mic disarms itself; her reply
///    plays; tap again for the next turn. Predictable, battery-kind.
///  - continuous (v2): the mic streams whenever she isn't speaking — the
///    CarPlay feel. Costs battery; the session lives while the app is
///    frontmost (watchOS suspends backgrounded apps; wrist-raise resumes).
/// Plain (non-actor) state the audio-thread tap reads, guarded by a lock —
/// the same discipline as the phone's audioStateSnapshot. The tap must never
/// touch main-actor state directly.
private final class TapState: @unchecked Sendable {
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var gate = false
    func set(converter c: AVAudioConverter?) { lock.lock(); converter = c; lock.unlock() }
    func set(gate g: Bool) { lock.lock(); gate = g; lock.unlock() }
    func snapshot() -> (AVAudioConverter?, Bool) {
        lock.lock(); defer { lock.unlock() }
        return (converter, gate)
    }
}

@MainActor
@Observable
final class WatchConversation {
    static let shared = WatchConversation()
    private init() {}

    enum ConvoState { case idle, connecting, listening, thinking, speaking }
    enum Mode: String { case tapToTalk, continuous }

    struct Line: Identifiable {
        let id = UUID()
        let text: String
        let fromHer: Bool
    }

    private(set) var state: ConvoState = .idle
    private(set) var status = "Tap to talk"
    private(set) var transcript: [Line] = []
    /// v1 gate: true while the mic is genuinely streaming his voice.
    private(set) var micArmed = false

    var mode: Mode {
        get { Mode(rawValue: UserDefaults.standard.string(forKey: "watch.mode") ?? "") ?? .tapToTalk }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "watch.mode") }
    }

    // MARK: - session plumbing

    private var ws: URLSessionWebSocketTask?
    private let wsSession = URLSession(configuration: .default)
    private var wantLive = false
    private var endedByUser = false
    private var reconnectAttempts = 0
    private var reconnectTask: Task<Void, Never>?
    private var handledToolCalls = Set<String>()
    private var responseActive = false
    private var needsResponseAfterDone = false

    // MARK: - audio plumbing

    private let audioEngine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var audioReady = false
    private let tapState = TapState()
    private var playFormat: AVAudioFormat?
    private let wireRate: Double = 24000
    /// Echo gate: while her audio is queued/playing, mic frames are dropped so
    /// the watch speaker can't feed her own voice back into the turn.
    private var pendingBuffers = 0
    private var speechTailUntil = Date.distantPast

    private var playbackActive: Bool { pendingBuffers > 0 || Date() < speechTailUntil }

    /// Recompute the one Bool the audio thread reads. Called at every point
    /// that changes whether his voice should flow.
    private func syncGate() {
        tapState.set(gate: micArmed && !playbackActive && ws != nil)
    }

    // MARK: - lifecycle

    func start() {
        guard state == .idle, let token = TokenStore.token else { return }
        reconnectTask?.cancel(); reconnectTask = nil
        reconnectAttempts = 0
        endedByUser = false
        wantLive = true
        state = .connecting
        status = "Waking her up…"
        Task { await connect(token: token) }
    }

    func end() {
        endedByUser = true
        wantLive = false
        reconnectTask?.cancel(); reconnectTask = nil
        ws?.cancel(with: .goingAway, reason: nil)
        ws = nil
        stopAudio()
        micArmed = false
        syncGate()
        responseActive = false
        needsResponseAfterDone = false
        state = .idle
        status = "Tap to talk"
    }

    /// The orb tap. Idle → start a session. Live in tapToTalk → arm the mic
    /// for one turn. Live in continuous → toggle a mute.
    func orbTapped() {
        switch state {
        case .idle:
            start()
        case .connecting:
            break
        default:
            if mode == .tapToTalk {
                micArmed.toggle()
                status = micArmed ? "Listening…" : "Tap to talk"
            } else {
                micArmed.toggle()
                status = micArmed ? "Listening…" : "Mic muted — tap to unmute"
            }
            syncGate()
        }
    }

    /// Wrist-raise / app foreground: a session that died while the app was
    /// suspended self-heals here — unless Ido explicitly ended it.
    func appBecameActive() {
        guard wantLive, !endedByUser, state == .idle || ws == nil else { return }
        state = .idle
        start()
    }

    // MARK: - connect

    private func connect(token: String) async {
        do {
            var req = URLRequest(url: AppConfig.realtimeURL)
            req.httpMethod = "POST"
            req.setValue(token, forHTTPHeaderField: "x-scarlet-token")
            let (data, resp) = try await URLSession.shared.data(for: req)
            let httpStatus = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let secret = obj?["client_secret"] as? String, !secret.isEmpty,
                  let url = URL(string: "wss://api.openai.com/v1/realtime?model=gpt-realtime") else {
                if httpStatus == 401 || httpStatus == 403 {
                    TokenStore.token = nil
                    status = "Sign in again"
                    state = .idle; wantLive = false
                    return
                }
                if wantLive { scheduleReconnect() }
                return
            }
            guard wantLive else { return }
            do { try ensureAudio() } catch {
                status = "Mic unavailable — try again"
                state = .idle; wantLive = false
                return
            }
            var wsReq = URLRequest(url: url)
            wsReq.setValue("Bearer " + secret, forHTTPHeaderField: "Authorization")
            let task = wsSession.webSocketTask(with: wsReq)
            ws = task
            task.resume()
            listen(task)
            reconnectAttempts = 0
            handledToolCalls.removeAll()
            responseActive = false
            needsResponseAfterDone = false
            state = .listening
            // Continuous mode listens from the first breath; tapToTalk waits
            // for the tap that arms the turn.
            micArmed = mode == .continuous
            status = micArmed ? "Listening…" : "Tap to talk"
            syncGate()
            sendContext("[FOCUS] Ido is on his Apple Watch (small screen, walking or running, possibly loud surroundings). Keep every answer SHORT — one to three spoken sentences — unless he explicitly asks for depth. All tools work normally.")
            if !transcript.isEmpty {
                let recent = transcript.suffix(4)
                    .map { ($0.fromHer ? "Scarlet: " : "Ido: ") + $0.text.prefix(160) }
                    .joined(separator: "\n")
                sendContext("[FOCUS] Connection renewed mid-conversation — CONTINUE, do not greet. Recent exchange:\n" + recent)
            }
        } catch {
            if wantLive { scheduleReconnect() } else { state = .idle; status = "Tap to talk" }
        }
    }

    private func scheduleReconnect() {
        guard wantLive, reconnectAttempts < 4, let token = TokenStore.token else {
            if wantLive { status = "Connection lost — tap to retry"; state = .idle; wantLive = false }
            return
        }
        let delay = UInt64(pow(2, Double(reconnectAttempts))) * 1_000_000_000
        reconnectAttempts += 1
        status = "Reconnecting…"
        state = .connecting
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self, self.wantLive, !Task.isCancelled else { return }
            await self.connect(token: token)
        }
    }

    // MARK: - socket receive

    private func listen(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            Task { @MainActor in
                guard self.ws === task else { return }
                switch result {
                case .failure:
                    self.ws = nil
                    if self.wantLive { self.scheduleReconnect() }
                case .success(let message):
                    if case .string(let text) = message,
                       let data = text.data(using: .utf8),
                       let ev = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        self.handleEvent(ev)
                    }
                    self.listen(task)
                }
            }
        }
    }

    private func handleEvent(_ ev: [String: Any]) {
        switch ev["type"] as? String ?? "" {
        case "response.created":
            responseActive = true
            state = .thinking
            if mode == .tapToTalk { micArmed = false }
            syncGate()
        case "response.output_audio.delta", "response.audio.delta":
            if let b64 = ev["delta"] as? String, let pcm = Data(base64Encoded: b64) {
                state = .speaking
                status = "Speaking…"
                playPCM(pcm)
            }
        case "response.done":
            responseActive = false
            state = .listening
            status = micArmed ? "Listening…" : "Tap to talk"
            syncGate()
            if needsResponseAfterDone {
                needsResponseAfterDone = false
                send(["type": "response.create"])
            }
        case "response.output_audio_transcript.done", "response.audio_transcript.done":
            if let text = (ev["transcript"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                appendLine(text, fromHer: true)
            }
        case "conversation.item.input_audio_transcription.completed":
            if let text = (ev["transcript"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                appendLine(text, fromHer: false)
            }
        case "input_audio_buffer.speech_started":
            state = .listening
            status = "Hearing you…"
        case "input_audio_buffer.committed":
            state = .thinking
            status = "Thinking…"
        case "response.function_call_arguments.done":
            let callId = ev["call_id"] as? String ?? ""
            guard !callId.isEmpty, !handledToolCalls.contains(callId) else { break }
            handledToolCalls.insert(callId)
            runTool(name: ev["name"] as? String ?? "",
                    callId: callId,
                    argsJSON: ev["arguments"] as? String ?? "{}")
        case "response.output_item.done":
            // Redundant trigger, mirroring the phone: the completed item
            // carries the full call, so a missed arguments.done can't skip it.
            if let item = ev["item"] as? [String: Any],
               (item["type"] as? String) == "function_call" {
                let callId = item["call_id"] as? String ?? ""
                guard !callId.isEmpty, !handledToolCalls.contains(callId) else { break }
                handledToolCalls.insert(callId)
                runTool(name: item["name"] as? String ?? "",
                        callId: callId,
                        argsJSON: item["arguments"] as? String ?? "{}")
            }
        case "error":
            let code = ((ev["error"] as? [String: Any])?["code"] as? String) ?? ""
            if code.contains("active_response") { needsResponseAfterDone = true }
        default:
            break
        }
    }

    private func appendLine(_ text: String, fromHer: Bool) {
        transcript.append(Line(text: text, fromHer: fromHer))
        if transcript.count > 30 { transcript.removeFirst(transcript.count - 30) }
    }

    // MARK: - tools

    private func runTool(name: String, callId: String, argsJSON: String) {
        let params = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any] ?? [:]
        status = "Working…"
        Task {
            let out = await performToolHTTP(name: name, params: params)
            // The watch has less headroom than the phone — cap what rides back
            // into the model context so a fat inbox can't blow the session.
            let capped = out.count > 12000
                ? String(out.prefix(12000)) + "\n[TRUNCATED — tell Ido there is more and offer to continue]"
                : out
            send(["type": "conversation.item.create",
                  "item": ["type": "function_call_output", "call_id": callId,
                           "output": capped]])
            if responseActive { needsResponseAfterDone = true } else { send(["type": "response.create"]) }
            postToolCues(name: name, out: out)
        }
    }

    private func performToolHTTP(name: String, params: [String: Any]) async -> String {
        do {
            var req = URLRequest(url: AppConfig.toolURL(name))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(TokenStore.token ?? "", forHTTPHeaderField: "x-scarlet-token")
            req.httpBody = try JSONSerialization.data(withJSONObject: params)
            let (data, _) = try await URLSession.shared.data(for: req)
            return String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            return "{\"error\":\"tool failed\"}"
        }
    }

    /// Watch-side effects for the handful of tools whose result is an action
    /// on THIS device. Telephony hands off to the system dialer.
    private func postToolCues(name: String, out: String) {
        guard name == "start_call",
              let data = out.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        for key in ["open_url", "url"] {
            if let s = obj[key] as? String,
               s.hasPrefix("tel:") || s.hasPrefix("facetime-audio:"),
               let url = URL(string: s) {
                WKApplication.shared().openSystemURL(url)
                return
            }
        }
    }

    // MARK: - send

    private func send(_ obj: [String: Any]) {
        guard let ws,
              let data = try? JSONSerialization.data(withJSONObject: obj),
              let text = String(data: data, encoding: .utf8) else { return }
        ws.send(.string(text)) { _ in }
    }

    private func sendContext(_ text: String) {
        send(["type": "conversation.item.create",
              "item": ["type": "message", "role": "user",
                       "content": [["type": "input_text", "text": text]]]])
    }

    // MARK: - audio

    private func ensureAudio() throws {
        if audioReady {
            if !audioEngine.isRunning { try audioEngine.start() }
            return
        }
        let session = AVAudioSession.sharedInstance()
        // .allowBluetoothA2DP so AirPods get the full-band codec — the same
        // never-HFP rule the phone enforces.
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothA2DP])
        try session.setActive(true)

        let input = audioEngine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw NSError(domain: "ScarletWatchAudio", code: 1)
        }
        let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: wireRate,
                                   channels: 1, interleaved: true)!
        tapState.set(converter: AVAudioConverter(from: inFormat, to: target))

        if player.engine == nil { audioEngine.attach(player) }
        playFormat = AVAudioFormat(standardFormatWithSampleRate: wireRate, channels: 1)
        audioEngine.connect(player, to: audioEngine.mainMixerNode, format: playFormat)

        input.removeTap(onBus: 0)
        let tapState = self.tapState
        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buffer, _ in
            // Audio thread: everything it reads comes from the lock-guarded
            // snapshot; the send hops to the main actor with plain Data.
            let (converter, gate) = tapState.snapshot()
            guard gate, let converter,
                  let data = Self.convertToWire(buffer, converter: converter) else { return }
            Task { @MainActor [weak self] in
                guard let self, self.ws != nil else { return }
                self.send(["type": "input_audio_buffer.append", "audio": data.base64EncodedString()])
            }
        }
        try audioEngine.start()
        audioReady = true
        syncGate()
    }

    private nonisolated static func convertToWire(_ buffer: AVAudioPCMBuffer,
                                                  converter: AVAudioConverter) -> Data? {
        let target = converter.outputFormat
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var fed = false
        converter.convert(to: out, error: nil) { _, outStatus in
            if fed { outStatus.pointee = .noDataNow; return nil }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard out.frameLength > 0, let ch = out.int16ChannelData else { return nil }
        return Data(bytes: ch[0], count: Int(out.frameLength) * 2)
    }

    private func playPCM(_ pcm: Data) {
        guard audioReady, let playFormat else { return }
        let frames = pcm.count / 2
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let int16 = raw.bindMemory(to: Int16.self)
            if let out = buffer.floatChannelData?[0] {
                for i in 0..<frames { out[i] = Float(int16[i]) / 32768 }
            }
        }
        pendingBuffers += 1
        syncGate()
        player.scheduleBuffer(buffer) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.pendingBuffers = max(0, self.pendingBuffers - 1)
                if self.pendingBuffers == 0 {
                    // Half-second tail: the room is still ringing with her
                    // voice; opening the mic instantly would echo.
                    self.speechTailUntil = Date().addingTimeInterval(0.5)
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        self.syncGate()   // reopen the mic once the tail passed
                    }
                }
            }
        }
        if !player.isPlaying { player.play() }
    }

    private func stopAudio() {
        player.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        audioReady = false
        tapState.set(converter: nil)
        tapState.set(gate: false)
        pendingBuffers = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
