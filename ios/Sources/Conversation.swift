import Foundation
import AVFoundation
import Combine
import UIKit   // background-task assertion so the car session survives a locked screen
import os      // os_unfair_lock — guards the state the audio-render thread reads

/// Native ElevenLabs conversational client. Same protocol the web app speaks,
/// but over a real AVAudioSession so the conversation never stalls: it keeps
/// running with the screen locked, and pauses/resumes cleanly on interruptions.
@MainActor
final class Conversation: ObservableObject {
    /// ONE conversation for the whole process. The CarPlay scene is a separate
    /// UIScene and can't reach RootView's instance; two instances would both
    /// grab the global AVAudioSession and both installTap (the second tap is an
    /// instant crash), so the phone UI and CarPlay share exactly this one.
    static let shared = Conversation()

    enum State { case idle, connecting, listening, speaking }

    struct Line: Identifiable { let id = UUID(); let text: String; let fromHer: Bool }

    @Published var state: State = .idle
    @Published var status = "Waking her up…"
    @Published var transcript: [Line] = []
    @Published var micOn = true
    @Published var speakerOn = true
    @Published var loudspeaker = true   // route: iPhone speaker vs. call earpiece
    @Published var chatMode = false     // text-only: ears closed, voice silent
    /// True while the live route output is a car (CarPlay / car Bluetooth):
    /// hands-free AND eyes-free. Drives the one-time "driving mode" nudge to
    /// the assistant and is available to the UI. Route-derived, not session.
    @Published var drivingMode = false

    /// Live input meter: RMS of the audio actually captured from the selected
    /// input/channel (post-gain, pre-send), mapped to 0…1 and smoothed. Updated
    /// every buffer regardless of mic-mute or echo gating, so a flat meter is
    /// ground truth that this input is delivering silence. Also mirrored to
    /// `MicSettings.shared.level` for the Settings sheet, which doesn't hold a
    /// reference to this live instance.
    @Published var inputLevel: Float = 0

    /// True while HIS voice is above the speaking threshold — a debounced
    /// (hysteresis) read of `inputLevel`, only trusted when her voice isn't in
    /// the room (not `echoRisk`), so her own loudspeaker can't light it. Drives
    /// the orb's "you're talking" reaction and is the onset half of barge-in.
    @Published var isUserSpeaking = false

    /// Record permission is standing-denied. Published so the UI can show an
    /// honest "enable the mic in Settings" affordance instead of a dead orb.
    @Published var micDenied = false

    /// She has heard him and is composing a reply — the beat between his words
    /// ending and her voice starting. Drives the orb's "thinking" shimmer. Set
    /// when a user turn lands, cleared the instant her audio begins.
    @Published var thinking = false

    /// Manual barge-in latch: true from the moment he taps the orb to cut her
    /// off until his NEXT turn lands. While set, her already-in-flight audio is
    /// dropped so a half-sent response can't keep talking over him.
    private var barged = false

    /// Set by TalkView on its first appearance so tab switches never
    /// re-trigger the auto-connect. Not published — pure bookkeeping.
    var hasAutoStarted = false

    private var ws: URLSessionWebSocketTask?
    private lazy var wsSession = URLSession(configuration: .default)
    private var token = ""
    private var outputRate: Double = 16000

    // Reconnect discipline: one loop at a time, only while the user wants live.
    private var wantLive = false
    private var reconnecting = false
    /// Consecutive failed reconnects — drives exponential backoff and the
    /// eventual give-up, so a dead network can't hammer the mint endpoint at a
    /// fixed 0.9s forever with the orb frozen on "Reconnecting…".
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 6
    /// The in-flight reconnect sleep — cancellable so End (or a fresh Start)
    /// during the reconnect window can't resurrect the session or spawn a
    /// second socket.
    private var reconnectTask: Task<Void, Never>?
    private var observersInstalled = false
    /// A rebuilt socket is a brand-new ElevenLabs conversation with amnesia —
    /// flag it so she's told this is a continuation, not a fresh caller.
    private var resumedSession = false

    /// User messages entered before the socket was live (session idle or still
    /// connecting). `send(_:)` is a no-op against a nil socket, so anything typed
    /// or dictated while she's asleep would silently vanish — these are held here
    /// and flushed exactly once by `flushPendingOutbound()` from `connect()`, the
    /// moment the socket goes live. Main-actor confined, so it can't race the flush.
    private var pendingOutbound: [String] = []

    /// Background-task assertion held while a live session is backgrounded.
    /// UIBackgroundModes:[audio] keeps the engine alive while audio plays, but
    /// this assertion bridges the quiet gaps (nobody speaking) so iOS doesn't
    /// suspend the socket the moment the screen locks in the car. `.invalid`
    /// when none is held.
    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    // Audio — built once, reused across reconnects. Re-running mic setup
    // (a second installTap on the same bus) is an instant NSException crash.
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var converter: AVAudioConverter?
    private var playFormat: AVAudioFormat?
    private var audioReady = false

    // Live-tunable capture settings, mirrored from MicSettings and read on the
    // audio thread the same way `converter` is. Channel/gain changes take
    // effect on the next buffer; a device change needs a fresh audio start.
    private var capChannel = 0
    private var capGainLinear: Float = 1

    // `converter`, `capChannel`, and `capGainLinear` are WRITTEN on the main
    // actor (ensureAudio / applyMicSettings / stopAudio) and READ on the
    // real-time audio thread inside the input tap. A device/format change
    // reassigns `converter` while a tap callback may be mid-read → a torn
    // pointer / use-after-free, the residual "quit unexpectedly". This lock makes
    // every read a consistent snapshot and keeps the old converter alive (via the
    // snapshot's strong ref) for the duration of a convert() already in flight.
    // Heap-allocated so the lock has a stable address (never copied by inout).
    private let audioStateLock: os_unfair_lock_t = {
        let l = os_unfair_lock_t.allocate(capacity: 1)
        l.initialize(to: os_unfair_lock_s())
        return l
    }()

    /// Atomically snapshot the three fields the audio thread needs.
    private func audioStateSnapshot() -> (AVAudioConverter?, Int, Float) {
        os_unfair_lock_lock(audioStateLock)
        defer { os_unfair_lock_unlock(audioStateLock) }
        return (converter, capChannel, capGainLinear)
    }
    /// Meter smoothing state — only ever touched on the main actor.
    private var levelSmoothed: Float = 0

    // MARK: user-speech + barge-in thresholds (all on the smoothed 0…1 meter)
    //
    // Two jobs off one envelope-followed level: a low-hysteresis pair that
    // lights `isUserSpeaking` for the orb, and a HIGHER, sustained gate that
    // decides a real barge-in while she's talking. The barge gate must clear
    // her post-AEC echo residual — Apple's AEC (kept on everywhere) cancels her
    // loudspeaker voice at the mic, so what survives above this line during her
    // speech is HIM, not her. A brief click can't trip it: it also has to hold
    // for `bargeSustainBuffers` consecutive tap callbacks (~200 ms).
    private static let speakOnLevel: Float = 0.14
    private static let speakOffLevel: Float = 0.07
    private static let bargeLevel: Float = 0.5
    private static let bargeSustainBuffers = 5
    /// Consecutive over-threshold tap callbacks while she's speaking. Reset the
    /// instant the level dips or the turn ends, so only sustained speech barges.
    private var bargeRun = 0

    // How many of her audio buffers are scheduled-but-unfinished. This is the
    // ONLY truthful "is she audibly speaking" signal: the server streams her
    // audio faster than realtime, so its own idea of the turn ends while the
    // loudspeaker is still talking. While buffers remain (plus a short reverb
    // tail) the mic must NOT stream — otherwise her own loudspeaker voice
    // comes back as "Ido speaking": the server either truncates her (barge-in)
    // or, with interruptions disabled, transcribes her words as HIS next turn
    // and she starts answering herself — the freeze/derail after long dialogs.
    private var pendingBuffers = 0
    private var speechTailUntil = Date.distantPast

    /// True while sending mic audio would loop her own voice back to her.
    private var echoRisk: Bool {
        if chatMode || !speakerOn { return false }   // her voice is silent
        return pendingBuffers > 0 || Date() < speechTailUntil
    }

    // MARK: lifecycle

    func start(token: String) {
        guard state == .idle else { return }
        // Kill any pending reconnect from a prior session so it can't wake a
        // second socket alongside this fresh one.
        reconnectTask?.cancel(); reconnectTask = nil; reconnecting = false
        reconnectAttempts = 0   // fresh session — start the backoff ladder over
        self.token = token
        wantLive = true
        barged = false; thinking = false
        state = .connecting
        status = "Waking her up…"   // don't leave the stale "Ended." line up during connect
        Task { await connect() }
        observeInterruptions()
    }

    func end() {
        wantLive = false
        reconnectTask?.cancel(); reconnectTask = nil; reconnecting = false
        reconnectAttempts = 0
        pendingOutbound.removeAll()   // hanging up discards anything not yet delivered
        ws?.cancel(with: .goingAway, reason: nil)
        ws = nil
        stopAudio()
        endBackgroundAssertion()
        barged = false; thinking = false
        isUserSpeaking = false; bargeRun = 0
        state = .idle
        status = "Ended. Tap Start (or the orb) when you want me back."
    }

    /// Barge-in: cut her off mid-sentence. Tapping the orb while she's speaking
    /// silences her instantly (flushPlayback stops the player AND clears the echo
    /// gate, so the mic reopens right away), latches `barged` so any audio still
    /// arriving for the killed turn is dropped until he speaks again, and pings
    /// the agent that the user is taking the floor. No-op unless she's audibly
    /// talking, so an accidental tap in silence does nothing.
    func interrupt() {
        guard state == .speaking else { return }
        barged = true
        thinking = false
        flushPlayback()                     // instant silence + echo gate cleared + → listening
        send(["type": "user_activity"])     // ElevenLabs: the user is active now
        if micOn { status = "Go ahead — I'm listening…" }
    }

    // MARK: background survival (locked screen in the car)

    /// Take a background-task assertion so a live, backgrounded session isn't
    /// suspended in a silent gap. Idempotent; the expiration handler releases
    /// it (the audio background mode still keeps us alive while she speaks).
    private func beginBackgroundAssertion() {
        guard bgTask == .invalid else { return }
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "ScarletLiveSession") { [weak self] in
            Task { @MainActor in self?.endBackgroundAssertion() }
        }
    }

    private func endBackgroundAssertion() {
        guard bgTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTask)
        bgTask = .invalid
    }

    func toggleMic() { micOn.toggle(); status = micOn ? "Listening…" : "Mic off — tap Mic to talk" }
    func toggleSpeaker() { speakerOn.toggle(); player.volume = speakerOn ? 1 : 0 }

    /// Loudspeaker ⇄ earpiece. The .defaultToSpeaker category option makes
    /// "no override" still mean loudspeaker, so the category itself must flip
    /// too. AirPods/CarPlay keep priority either way.
    func toggleLoudspeaker() {
        loudspeaker.toggle()
        applyOutputRoute()
    }

    private func applyOutputRoute() {
        let s = AVAudioSession.sharedInstance()
        let phoneIsOutput = s.currentRoute.outputs.allSatisfy {
            $0.portType == .builtInReceiver || $0.portType == .builtInSpeaker
        }
        let base: AVAudioSession.CategoryOptions = [.allowBluetooth, .allowBluetoothA2DP]
        // .voiceChat is tuned for the EARPIECE and keeps loudspeaker output
        // quiet-call level; .videoChat is the speakerphone tuning — full
        // loudspeaker loudness with echo control intact. Keep Apple's AEC on
        // EVERYWHERE including the Mac: turning it off (a pro-interface capture
        // experiment) let her loudspeaker voice loop back and truncate her.
        try? s.setCategory(.playAndRecord, mode: loudspeaker ? .videoChat : .voiceChat,
                           options: loudspeaker ? base.union(.defaultToSpeaker) : base)
        try? s.setActive(true)
        if phoneIsOutput {
            try? s.overrideOutputAudioPort(loudspeaker ? .speaker : .none)
        }
    }

    // MARK: chat mode

    /// Remembered so leaving chat mode restores the mic AND voice the way Ido
    /// left them — if he'd silenced her voice, chat mode must not turn it back on.
    private var micWasOnBeforeChat = true
    private var speakerWasOnBeforeChat = true

    /// Chat mode: her ears close and her voice goes silent — she answers in
    /// text only. Voice mode restores both.
    func setChatMode(_ on: Bool) {
        guard on != chatMode else { return }
        if on {
            micWasOnBeforeChat = micOn
            speakerWasOnBeforeChat = speakerOn
            micOn = false
            speakerOn = false
            player.volume = 0
            chatMode = true
            status = "Chat mode — type to Scarlet"
        } else {
            chatMode = false
            micOn = micWasOnBeforeChat
            speakerOn = speakerWasOnBeforeChat
            player.volume = speakerOn ? 1 : 0
            if micOn { status = "Listening…" }
        }
    }

    // Dictation etiquette: while Ido types/dictates into the text row, her
    // live ears close — otherwise Wispr's spoken dictation reaches the mic
    // and she answers before he presses send.
    private var micWasOnBeforeTyping = true
    func beginTyping() {
        micWasOnBeforeTyping = micOn
        micOn = false
        status = "Typing — mic paused. Tap Type again to talk."
    }
    func endTyping() {
        guard !chatMode else { return }   // chat mode keeps her ears closed
        micOn = micWasOnBeforeTyping
        if micOn { status = "Listening…" }
    }

    /// Dictated/typed input: goes to her exactly like speech. The transcript
    /// bubble appears immediately; if the session is asleep or still connecting
    /// the message is queued and the session is woken, so nothing is dropped on
    /// a nil socket — the queue flushes the instant the socket is live.
    func sendText(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        transcript.append(.init(text: t, fromHer: false))
        deliverUserMessage(t)
    }

    /// A system-initiated turn: reaches her like a user message (so she
    /// SPEAKS, unlike contextual updates) but never shows in the transcript —
    /// used for proactive moments like announcing a recovered draft.
    ///
    /// `ensureLive` decides what happens when she's asleep: the default `false`
    /// keeps the old fire-only-if-already-live behavior (a launch-time draft
    /// recovery must not force a full voice session up on its own); pass `true`
    /// when the nudge MUST reach her even from idle — e.g. a freshly shared
    /// photo/document — in which case it wakes the session and flushes on connect.
    func sendSystemNudge(_ text: String, ensureLive: Bool = false) {
        if ensureLive {
            deliverUserMessage(text)
        } else {
            guard state == .listening || state == .speaking else { return }
            send(["type": "user_message", "text": text])
        }
    }

    /// Deliver a `user_message` to the live socket, or bring the session up and
    /// hold the text until it is. Sending directly only when already live means
    /// we never write to a nil `ws`; `flushPendingOutbound()` drains the queue
    /// once from `connect()`. Confined to the main actor, so enqueue and flush
    /// can't race, and an already-live send is never also queued (no double-send).
    private func deliverUserMessage(_ text: String) {
        // A user/system turn is going out — she'll be composing a reply. Release
        // any barge-in latch so her answer can play, and light "thinking".
        barged = false
        thinking = true
        switch state {
        case .listening, .speaking:
            send(["type": "user_message", "text": text])
        case .connecting:
            pendingOutbound.append(text)
        case .idle:
            pendingOutbound.append(text)
            start(token: TokenStore.token ?? "")
        }
    }

    /// Send everything queued while the socket was down, exactly once, in order.
    /// Called from `connect()` after the socket is live and initial context has
    /// been replayed, so queued turns land after her focus/continuation setup.
    private func flushPendingOutbound() {
        guard !pendingOutbound.isEmpty else { return }
        let queued = pendingOutbound
        pendingOutbound.removeAll()
        for text in queued { send(["type": "user_message", "text": text]) }
    }

    /// Her most recent line — surfaced by the floating presence capsule.
    var lastHerLine: String? { transcript.last(where: { $0.fromHer })?.text }

    // MARK: ambient focus

    /// What Ido is looking at right now (open email, inbox list, Talk
    /// screen). Not published — pure bookkeeping, like hasAutoStarted.
    private(set) var currentFocus: String?

    /// Screen changes ride to her as `contextual_update` — ElevenLabs'
    /// non-interrupting context event: she learns it without it counting as
    /// a user turn, so nothing barges into the conversation.
    func setFocus(_ text: String?) {
        guard text != currentFocus else { return }
        currentFocus = text
        guard state == .listening || state == .speaking else { return }
        send(["type": "contextual_update", "text": text ?? "[FOCUS] Nothing focused."])
    }

    // MARK: car / eyes-free driving mode

    /// Re-derive `drivingMode` from the live route and, when appropriate, tell
    /// the assistant once. Called from the route-change observer (announce only
    /// on the transition INTO a car) and from `connect()` with
    /// `forceAnnounce: true` (a fresh or rebuilt socket has amnesia, so re-tell
    /// it if we're already on a car route).
    private func evaluateDrivingMode(forceAnnounce: Bool = false) {
        let outs = AVAudioSession.sharedInstance().currentRoute.outputs
        let isCar = outs.contains { $0.portType == .carAudio }
        let becameCar = isCar && !drivingMode
        drivingMode = isCar
        if isCar && (becameCar || forceAnnounce) { announceDrivingMode() }
    }

    /// A single non-interrupting `contextual_update` marking eyes-free driving —
    /// same channel as ambient focus, so it never counts as a user turn. Orients
    /// her to speak everything aloud, one item at a time, and never point at the
    /// screen.
    private func announceDrivingMode() {
        guard state == .listening || state == .speaking else { return }
        send(["type": "contextual_update",
              "text": "[DRIVING MODE] Ido is now in the car, connected over the car's speakers and microphone — hands-free AND eyes-free. He cannot look at or touch the screen. Speak everything aloud: never say \"look at your screen\", \"tap\", or \"see below\". Read results out loud ONE item at a time, keep each turn short, and wait for his voice before continuing. Confirm out loud before taking any action."])
    }

    /// CarPlay scene connected — treat as authoritative eyes-free driving even
    /// if the audio route hasn't reported `.carAudio` yet (the scene can connect
    /// a beat before the route flips). Idempotent; the announce is a no-op until
    /// the socket is live, and `connect()`'s forceAnnounce covers a cold start.
    func carPlayDidConnect() {
        if !drivingMode { drivingMode = true }
        announceDrivingMode()
    }

    // MARK: signed URL + socket

    private func connect() async {
        // Mic gate: without record permission the engine can never start, so
        // reconnecting would loop forever. Ask once; if denied, stop cleanly with
        // a message that points at Settings instead of spinning "Reconnecting…".
        guard await ensureMicPermission() else {
            status = "Microphone access is off — turn it on in Settings to talk."
            state = .idle; wantLive = false
            reconnectTask?.cancel(); reconnectTask = nil; reconnecting = false
            pendingOutbound.removeAll()
            return
        }
        do {
            var req = URLRequest(url: AppConfig.elevenURL)
            req.httpMethod = "POST"
            req.setValue(token, forHTTPHeaderField: "x-scarlet-token")
            let (data, _) = try await URLSession.shared.data(for: req)
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let signed = obj?["signed_url"] as? String, let url = URL(string: signed) else {
                status = "Couldn't start — try again."; state = .idle; wantLive = false
                pendingOutbound.removeAll()   // no session is coming — don't replay stale text later
                return
            }
            // The user may have tapped End while we were fetching the URL — do
            // NOT resurrect a session he explicitly hung up on.
            guard wantLive else { return }
            // Audio-start failure is NOT a transport drop — reconnecting can't fix
            // a dead mic/engine, it just loops. Surface it and stop.
            do {
                try ensureAudio()
            } catch {
                status = "Can't reach the microphone right now. Check it's free (not held by another app) and try again."
                state = .idle; wantLive = false
                reconnectTask?.cancel(); reconnectTask = nil; reconnecting = false
                pendingOutbound.removeAll()
                return
            }
            // Connected: a real socket is up. Clear the backoff counter.
            reconnectAttempts = 0
            let task = wsSession.webSocketTask(with: url)
            ws = task
            task.resume()
            send(["type": "conversation_initiation_client_data"])
            listen()
            // A reconnect is a brand-new socket: never carry a barge-in latch or
            // a "thinking" flag across it, or her resumed speech would be dropped
            // by playPCM's `barged` gate (silent, until he happens to speak) and
            // the orb could shimmer forever. Same reset start() does.
            barged = false; thinking = false
            state = .listening
            status = micOn ? "Listening…" : "Mic off — tap Mic to talk"
            // A fresh socket knows nothing about the screen — replay the
            // current focus so a reconnect regains ambient context.
            if let focus = currentFocus {
                send(["type": "contextual_update", "text": focus])
            }
            if resumedSession {
                resumedSession = false
                // Recent transcript lines ride along so the renewed session
                // keeps the thread instead of greeting him like a stranger.
                let recent = transcript.suffix(6)
                    .map { ($0.fromHer ? "Scarlet: " : "Ido: ") + $0.text.prefix(200) }
                    .joined(separator: "\n")
                send(["type": "contextual_update",
                      "text": "[FOCUS] Connection renewed mid-conversation (the previous session hit a transport drop or time cap). This is a CONTINUATION — do not greet, do not reset. Recent exchange:\n" + recent])
            }
            // Car / eyes-free: now that we're connected, re-check the live route.
            // forceAnnounce so a fresh OR rebuilt (amnesiac) socket is told about
            // driving mode if we're already on a car route.
            evaluateDrivingMode(forceAnnounce: true)
            // Socket is live and context is replayed — deliver anything typed,
            // dictated, or shared while she was asleep/connecting. Exactly once.
            flushPendingOutbound()
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
        // Give up after a bounded number of tries so a truly dead network ends in
        // an actionable state, not an eternal spinner.
        if reconnectAttempts >= maxReconnectAttempts {
            status = "Couldn't reconnect — tap Start to try again."
            state = .idle; wantLive = false
            reconnectTask?.cancel(); reconnectTask = nil; reconnecting = false
            reconnectAttempts = 0
            return
        }
        reconnecting = true
        // Only claim a "continuation" when a conversation actually happened —
        // a failed FIRST connect (empty transcript) must greet normally, not
        // pretend to resume a thread that never existed.
        resumedSession = !transcript.isEmpty
        // Reflect the true state: the socket is down. This makes the orb show
        // the connecting affordance AND makes deliverUserMessage QUEUE typed
        // text instead of dead-sending it to the nil socket.
        state = .connecting
        status = "Reconnecting…"
        ws?.cancel(with: .goingAway, reason: nil)
        ws = nil
        // Exponential backoff: 0.9s, 1.8s, 3.6s … capped at 30s.
        let attempt = reconnectAttempts
        reconnectAttempts += 1
        let delay = min(30.0, 0.9 * pow(2.0, Double(attempt)))
        reconnectTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if wantLive, !Task.isCancelled { await connect() }
            reconnecting = false
        }
    }

    /// Record-permission gate. Returns true only if the mic is authorized.
    /// Requests once on first use; returns the standing decision thereafter.
    private func ensureMicPermission() async -> Bool {
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted:
            micDenied = false
            return true
        case .denied:
            micDenied = true
            return false
        case .undetermined:
            let granted = await withCheckedContinuation { cont in
                session.requestRecordPermission { ok in cont.resume(returning: ok) }
            }
            micDenied = !granted
            if granted {
                // First-ever grant. The input hardware needs a beat to spin up
                // after the permission dialog dismisses; if `ensureAudio()` reads
                // `inputNode.outputFormat` in that gap it gets a 0-rate / 0-channel
                // placeholder and builds a converter over garbage — the classic
                // silent-dead-mic on the very first launch. Prime the session and
                // yield briefly so the graph is built against a real input format.
                try? session.setCategory(.playAndRecord, mode: .voiceChat,
                                         options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP])
                try? session.setActive(true)
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            return granted
        @unknown default:
            return false
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
               !t.isEmpty {
                transcript.append(.init(text: t, fromHer: false))
                // His turn has landed: release any barge-in latch (her NEW reply
                // may now play) and light the "thinking" state until she speaks.
                barged = false
                thinking = true
            }
        case "interruption":
            flushPlayback()
            thinking = false
        case "ping":
            let id = (ev["ping_event"] as? [String: Any])?["event_id"]
            send(["type": "pong", "event_id": id as Any])
        case "client_tool_call":
            // A tool turn is an observable response — the "thinking" beat is over.
            // Clearing it here also stops the orb shimmering forever on a silent
            // tool action that never produces audio (e.g. opening a draft window).
            thinking = false
            if let c = ev["client_tool_call"] as? [String: Any] { runTool(c) }
        default: break
        }
    }

    private func runTool(_ c: [String: Any]) {
        let name = c["tool_name"] as? String ?? ""
        let callId = c["tool_call_id"] as? String ?? ""
        let params = c["parameters"] as? [String: Any] ?? [:]
        // send_photos runs ENTIRELY on-device (the photo library lives here): it
        // selects by place/time, uploads the matches, and opens a draft with them
        // attached — no server tool handler exists or should. Handle it locally
        // and return the result to the agent; skip the default server POST.
        if name == "send_photos" {
            Task { @MainActor in
                let out = await handleSendPhotos(params)
                send(["type": "client_tool_result", "tool_call_id": callId,
                      "result": String(out.prefix(4000)), "is_error": false])
            }
            return
        }
        // INSTANT WINDOW: the tool arguments are already here, before any
        // network round-trip. For a compose, open the drafting window NOW with
        // his request painted in — recipient, channel, and the instruction she
        // heard — so he sees it react the moment he finishes speaking, with the
        // body streaming in a beat later. (The post-result notification below
        // still fires as the reliability net + to record the real draft id.)
        if name == "compose_draft" {
            let intent: [String: String] = [
                "channel": params["channel"] as? String ?? "",
                "recipient": params["recipient"] as? String ?? "",
                "instruction": params["instruction"] as? String ?? "",
                "subject": params["subject"] as? String ?? "",
            ]
            Task { @MainActor in
                NotificationCenter.default.post(name: .scarletVoiceDraftIntent, object: intent)
            }
        }
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
            // 12k cap: every tool result lives in the agent's context for the
            // REST of the conversation — 30k results made hour-long dialogues
            // slower and slower until replies timed out entirely.
            send(["type": "client_tool_result", "tool_call_id": callId,
                  "result": String(out.prefix(12000)), "is_error": false])
            // A voice-started draft: compose_draft came back with a draft id,
            // so tell the shell to open the drafting table over whatever
            // screen is showing.
            if name == "compose_draft",
               let data = out.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let draftId = obj["draft_id"] as? String, !draftId.isEmpty {
                Task { @MainActor in
                    // Carry the id so the shell records it and the backstop poll
                    // won't re-open the same draft after it's dismissed.
                    NotificationCenter.default.post(name: .scarletVoiceDraftStarted, object: draftId)
                }
            }
        }
    }

    // MARK: audio session + capture + playback

    private func startAudioSession() throws {
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playAndRecord, mode: .voiceChat,
                          options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP])
        try s.setActive(true)
        applyPreferredInput()
        routeToSpeakerIfReceiver()
    }

    /// Apply the user's saved input choice (RME/USB interface, headset, …)
    /// BEFORE the engine reads the input format, so a multichannel device's
    /// real format is what the tap/converter see. No saved choice → system
    /// default (nil preferred input). Also refreshes the list the Settings
    /// picker shows and records what we actually resolved to. Never throws:
    /// a stale/absent device just falls back to the default.
    private func applyPreferredInput() {
        let s = AVAudioSession.sharedInstance()
        let m = MicSettings.shared
        let inputs = s.availableInputs ?? []
        m.availableInputs = inputs
        if let uid = m.preferredInputUID,
           let match = inputs.first(where: { $0.uid == uid })
                    ?? inputs.first(where: { $0.portName == m.preferredInputName }) {
            try? s.setPreferredInput(match)
            m.activeInputName = match.portName
        } else {
            try? s.setPreferredInput(nil)
            m.activeInputName = s.currentRoute.inputs.first?.portName
        }
    }

    /// Mirror the live-tunable capture settings (channel, gain) into the plain
    /// fields the audio-thread tap reads.
    private func applyMicSettings() {
        let m = MicSettings.shared
        let ch = max(0, m.channel)
        let gain: Float = pow(10, max(0, m.gainDB) / 20)
        os_unfair_lock_lock(audioStateLock)
        capChannel = ch
        capGainLinear = gain
        os_unfair_lock_unlock(audioStateLock)
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
        // First-launch / just-granted race: if the input isn't up yet the format
        // comes back as 0 Hz / 0 channels. Building a converter over that yields a
        // tap that captures nothing (silent dead mic). Refuse it — connect()'s
        // catch surfaces an honest "try again", and the priming in
        // ensureMicPermission() means a real launch almost never lands here.
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw NSError(domain: "Scarlet.Audio", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Microphone input not ready yet."])
        }
        let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                                   channels: 1, interleaved: true)!
        let newConverter = AVAudioConverter(from: inFormat, to: target)
        os_unfair_lock_lock(audioStateLock)
        converter = newConverter
        os_unfair_lock_unlock(audioStateLock)

        // Channel count decides the capture path: >1 (a multichannel USB/RME
        // interface, esp. iOS-app-on-Mac) means we pull one selected channel
        // out ourselves; ==1 keeps the proven converter downmix. Surfaced to
        // the Settings picker via MicSettings.
        let channelCount = Int(inFormat.channelCount)
        MicSettings.shared.channelCount = channelCount
        applyMicSettings()

        // Guard the attach so the graph can be torn down and rebuilt (on an
        // audio device/format change) without re-attaching an already-attached
        // node — which AVAudioEngine traps on.
        if player.engine == nil { engine.attach(player) }
        // Player speaks standard Float32 — mixer connections in exotic formats
        // are exactly the kind of thing AVAudioEngine throws exceptions over.
        playFormat = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 1)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)

        input.removeTap(onBus: 0)   // never stack taps — a second install crashes
        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buffer, _ in
            guard let self else { return }

            var outData: Data?
            var instRMS: Float = 0
            // One consistent snapshot for this callback — never read the live
            // properties field-by-field while main may be swapping the converter.
            let (snapConverter, snapChannel, gain) = self.audioStateSnapshot()

            // Read the layout from the BUFFER ITSELF on every callback, never
            // from the format captured when the tap was installed. On a Mac the
            // input device/format changes under a live session (Teams grabs the
            // mic, headphones, an interface, an alert sound) and stale channel/
            // stride math would read out of bounds → a hard crash. `bufCh` and
            // `bufInterleaved` always match the samples actually delivered.
            let bufCh = Int(buffer.format.channelCount)
            if bufCh > 1, let fdata = buffer.floatChannelData {
                // Multichannel device (e.g. an RME/USB interface on the Mac):
                // pull the ONE selected channel out directly and resample it to
                // 16k mono ourselves, instead of letting the converter average
                // every channel together — which would bury a single live mic
                // under the silent channels. The channel index is CLAMPED to the
                // BUFFER's real channel count, so it can never read out of range.
                let frames = Int(buffer.frameLength)
                if frames > 0 {
                    let interleaved = buffer.format.isInterleaved
                    let stride = interleaved ? bufCh : 1
                    let chIndex = max(0, min(snapChannel, bufCh - 1))
                    // Planar with a bad index would be out of bounds — guard it.
                    guard interleaved || chIndex < bufCh else { return }
                    let base = interleaved ? fdata[0].advanced(by: chIndex) : fdata[chIndex]

                    let inRate = buffer.format.sampleRate > 0 ? buffer.format.sampleRate : 48000
                    let ratio = inRate / 16000.0
                    let outCount = max(0, Int(Double(frames) / ratio))
                    var pcm = [Int16](); pcm.reserveCapacity(outCount)
                    var i = 0
                    while i < outCount {
                        let pos = Double(i) * ratio
                        let i0 = Int(pos)
                        let i1 = min(i0 + 1, frames - 1)
                        let frac = Float(pos - Double(i0))
                        let s0 = base[i0 * stride]
                        let s1 = base[i1 * stride]
                        var v = (s0 + (s1 - s0) * frac) * gain   // linear resample
                        if v > 1 { v = 1 } else if v < -1 { v = -1 }   // hard limit
                        pcm.append(Int16(v * 32767))
                        i += 1
                    }
                    var sumSq: Float = 0
                    var j = 0
                    while j < frames { let g = base[j * stride] * gain; sumSq += g * g; j += 1 }
                    instRMS = sqrt(sumSq / Float(frames))
                    outData = pcm.withUnsafeBytes { Data($0) }
                }
            } else if let converter = snapConverter {
                // Single-channel input: keep the proven AVAudioConverter downmix.
                // `converter` is the snapshot's strong ref — it stays alive for
                // this convert() even if main reassigns the property meanwhile.
                let inRate = buffer.format.sampleRate > 0 ? buffer.format.sampleRate : 48000
                let ratio = 16000.0 / inRate
                let outCap = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
                if let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCap) {
                    var fed = false
                    var err: NSError?
                    converter.convert(to: out, error: &err) { _, status in
                        if fed { status.pointee = .noDataNow; return nil }
                        fed = true; status.pointee = .haveData; return buffer
                    }
                    if err == nil, out.frameLength > 0, let ch = out.int16ChannelData {
                        if gain != 1 {
                            let n = Int(out.frameLength)
                            var i = 0
                            while i < n {
                                var v = Float(ch[0][i]) * gain
                                if v > 32767 { v = 32767 } else if v < -32767 { v = -32767 }
                                ch[0][i] = Int16(v)
                                i += 1
                            }
                        }
                        outData = Data(bytes: ch[0], count: Int(out.frameLength) * 2)
                        if let fdata = buffer.floatChannelData {
                            let frames = Int(buffer.frameLength)
                            if frames > 0 {
                                var sumSq: Float = 0
                                var j = 0
                                while j < frames { let g = fdata[0][j] * gain; sumSq += g * g; j += 1 }
                                instRMS = sqrt(sumSq / Float(frames))
                            }
                        }
                    }
                }
            }

            guard let data = outData else { return }
            // Map RMS → dB → 0…1 (-60 dB floor). Silence stays at 0; speech
            // fills the meter; raising the gain visibly raises it.
            let db = 20 * log10(max(instRMS, 1e-7))
            let norm = max(0, min(1, (db + 60) / 60))
            Task { @MainActor in
                // Meter FIRST — it reflects the real captured signal regardless
                // of mic-mute/echo gating, so a flat meter is ground truth.
                let prev = self.levelSmoothed
                let next = norm > prev ? norm : prev * 0.82 + norm * 0.18   // fast attack, slow release
                self.levelSmoothed = next
                self.inputLevel = next
                MicSettings.shared.level = next

                // "Is he talking" for the orb — hysteresis so it doesn't flicker
                // on the threshold. Only trusted when her voice isn't in the room:
                // during her speech the meter carries echo residual, not a clean
                // read of him, so we don't assert user-speaking from it there.
                if self.echoRisk {
                    self.isUserSpeaking = false
                } else if self.micOn {
                    if next > Conversation.speakOnLevel { self.isUserSpeaking = true }
                    else if next < Conversation.speakOffLevel { self.isUserSpeaking = false }
                } else {
                    self.isUserSpeaking = false
                }

                // BARGE-IN: he starts talking while she's mid-sentence → cut her
                // off. Runs on the post-AEC input, above the echo-residual line,
                // and only after it HOLDS for a few callbacks — so her own
                // loudspeaker (mostly cancelled by AEC) and stray clicks can't
                // false-trigger. When it fires, `interrupt()` silences her
                // instantly, clears the echo gate (mic reopens so the server
                // hears him), and latches `barged` to drop the killed turn's tail.
                if self.state == .speaking, self.micOn, self.speakerOn, !self.chatMode {
                    if next >= Conversation.bargeLevel {
                        self.bargeRun += 1
                        if self.bargeRun >= Conversation.bargeSustainBuffers {
                            self.bargeRun = 0
                            self.interrupt()
                        }
                    } else {
                        self.bargeRun = 0
                    }
                } else {
                    self.bargeRun = 0
                }

                // Half-duplex: her ears open only when her voice isn't in the
                // room. Kills echo barge-in AND echo phantom turns at the root.
                guard self.micOn, !self.echoRisk else { return }
                self.send(["user_audio_chunk": data.base64EncodedString()])
            }
        }
        engine.prepare()
        try engine.start()
        engine.mainMixerNode.outputVolume = 1.0
        audioReady = true
    }

    /// Single-flight guard so a burst of configuration-change notifications
    /// can't re-enter the rebuild.
    private var audioRebuilding = false

    /// The audio hardware/format changed under a live session — a device swap,
    /// a sample-rate renegotiation, or a phone/Teams call taking then releasing
    /// the mic. Rebuild the capture graph against the NEW format instead of
    /// leaving the old tap/converter running against mismatched buffers, which
    /// is a hard native crash (`try?` can't catch it). This is THE fix for the
    /// "quit unexpectedly" crashes that fire continuously on the Mac next to
    /// Outlook, where audio devices churn constantly.
    @MainActor
    private func rebuildAudioGraph() {
        guard wantLive, audioReady, !audioRebuilding else { return }
        audioRebuilding = true
        defer { audioRebuilding = false }
        stopAudio()
        try? ensureAudio()
    }

    /// Server announced a different output rate — rewire only the player leg.
    private func rebuildPlayback() {
        guard audioReady else { return }
        player.stop()
        // player.stop() discards scheduled buffers WITHOUT firing their
        // completion handlers, so pendingBuffers would stay > 0 forever →
        // echoRisk stuck true → the mic never streams again ("frozen"). Reset the
        // playback bookkeeping the same way flushPlayback()/stopAudio() do.
        pendingBuffers = 0
        speechTailUntil = Date.distantPast
        engine.disconnectNodeOutput(player)
        playFormat = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 1)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)
    }

    private func playPCM(base64: String) {
        // Teardown guard: audio-frame events are dispatched as @MainActor Tasks
        // from the socket receive loop, so one can still run AFTER end() tore the
        // session down. Without this, a late frame would restart a just-stopped
        // engine — player.play() on a non-running engine throws the "IsRunning()"
        // exception (hard crash), and even when it doesn't it resurrects an ended
        // session into a phantom "listening" state. end()/stopAudio() clear both
        // flags synchronously, so any post-teardown frame is dropped here.
        guard wantLive, audioReady else { return }
        // He just barged in — drop the tail of the killed turn so her voice
        // can't crawl back over him. Cleared when his next turn lands.
        if barged { return }
        guard let data = Data(base64Encoded: base64),
              let fmt = playFormat else { return }
        // Her audio has begun — she's no longer "thinking".
        thinking = false
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
        pendingBuffers += 1
        player.scheduleBuffer(buf) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // She's done only when the LAST queued buffer drains — the
                // first buffer's completion used to flip state mid-sentence.
                self.pendingBuffers = max(0, self.pendingBuffers - 1)
                if self.pendingBuffers == 0 {
                    // Short grace so the room's reverb tail can't reach the
                    // mic as a phantom user turn.
                    self.speechTailUntil = Date().addingTimeInterval(0.35)
                    if self.state == .speaking {
                        self.state = .listening
                        if self.micOn { self.status = "Listening…" }
                    }
                }
            }
        }
    }

    private func flushPlayback() {
        player.stop()
        pendingBuffers = 0
        speechTailUntil = Date.distantPast
        thinking = false
        state = .listening
        if micOn { status = "Listening…" }
    }

    private func stopAudio() {
        guard audioReady else { return }
        engine.inputNode.removeTap(onBus: 0)
        // Clear the converter under the lock: the tap is removed, but a callback
        // already dispatched can still be running: snapshotting nil (or the still-
        // live old converter it captured) is safe; a torn read is not.
        os_unfair_lock_lock(audioStateLock)
        converter = nil
        os_unfair_lock_unlock(audioStateLock)
        player.stop()
        pendingBuffers = 0
        speechTailUntil = Date.distantPast
        isUserSpeaking = false; bargeRun = 0
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
                    // iOS is about to tear down the audio unit, discarding every
                    // scheduled buffer WITHOUT firing its completion handler — so
                    // pendingBuffers would never decrement and the echo gate would
                    // stay closed forever, leaving her frozen (mic dead, stuck in
                    // .speaking). Treat the interruption as a barge-in reset: clear
                    // the gate and return to listening so she recovers on .ended.
                    self.flushPlayback()
                case .ended:
                    // A call (Teams/phone) that grabbed the mic likely changed
                    // the input device/format; rebuild rather than restart the
                    // stale graph (a restart with a mismatched format crashes).
                    try? self.startAudioSession()
                    if self.wantLive { self.rebuildAudioGraph() }
                default: break
                }
            }
        }
        // The audio engine's I/O format changed (device swap, sample-rate
        // renegotiation, an interface or headphones coming/going). Rebuild the
        // capture graph on the NEW format — the single most important guard
        // against the continuous Mac "quit unexpectedly" crashes.
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name.AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.rebuildAudioGraph() }
        }
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                if self.wantLive, !self.engine.isRunning { try? self.engine.start() }
                if self.wantLive { self.routeToSpeakerIfReceiver() }
                // Plugging into (or out of) the car flips eyes-free driving mode;
                // announce only on the transition INTO a car.
                self.evaluateDrivingMode()
            }
        }
        // Background survival: take the assertion when a live session goes to the
        // background (screen lock in the car), release it on return — the next
        // background re-takes it. Audio is untouched here; this only guards the
        // socket/engine against suspension in silent gaps.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.wantLive else { return }
                self.beginBackgroundAssertion()
            }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.endBackgroundAssertion() }
        }
        // Live-tunable mic settings (channel, gain) changed in Settings: re-read
        // them so the running tap picks them up on its next buffer. A device
        // change is also broadcast here but only takes effect on the next start.
        NotificationCenter.default.addObserver(
            forName: .scarletMicChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.applyMicSettings() }
        }
    }
}
