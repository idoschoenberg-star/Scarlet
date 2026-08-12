import Foundation
import AVFoundation
import CallKit // CXCallObserver — announce an incoming cellular call by voice
import Combine
import UIKit   // background-task assertion so the car session survives a locked screen
import os      // os_unfair_lock — guards the state the audio-render thread reads

/// Tiny CXCallObserver delegate: fires once per NEW incoming ring (not on
/// connect/end), forwarding to the live conversation on the main actor.
final class CallWatchDelegate: NSObject, CXCallObserverDelegate {
    private let onIncoming: () -> Void
    private var announced = Set<UUID>()
    init(onIncoming: @escaping () -> Void) { self.onIncoming = onIncoming }
    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        guard !call.isOutgoing, !call.hasConnected, !call.hasEnded,
              !announced.contains(call.uuid) else { return }
        announced.insert(call.uuid)
        onIncoming()
    }
}

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

    /// THE voice engine is OpenAI Realtime (Ido 2026-08-11: "Dump 11 Labs.
    /// Just use OpenAI and make it a super reliable platform."). One vendor,
    /// one pipe, the ChatGPT-class voice he picked, semantic turn detection,
    /// the full persona + ~59 tools configured server-side in
    /// realtime-session. The ElevenLabs branch below is retained as DORMANT
    /// code only — `engine` never leaves .openai (switchToBackupEngine guards
    /// on .eleven and so never fires).
    enum Engine: String { case eleven, openai }
    @Published private(set) var engine: Engine = .openai
    /// Set once a failover happened this session — prevents ping-ponging.
    private var engineFellBack = false

    // OpenAI per-turn bookkeeping. Two GA facts shape the always-answer logic:
    // input transcription is an ASYNC side channel that routinely lands AFTER
    // the reply, and only ONE response can be active at a time.
    private var responseActive = false
    /// A turn (speech or text) or a tool result landed while a response was
    /// active — with interrupt_response=false the server may drop it
    /// unanswered, so ask for a response explicitly the moment the active one
    /// finishes. CRITICAL INVARIANT (the build-225 double-answer bug): any
    /// response.created CLEARS this flag, because a new response reads the
    /// FULL conversation and therefore covers every input that preceded it.
    /// Without that clear, a create that collided with a VAD-created response
    /// queued a SECOND, input-less response at done — she re-answered the
    /// same question unprompted, often drifting into the other language.
    private var needsResponseAfterDone = false
    private var lastSpeechStoppedAt = Date.distantPast
    private var lastResponseCreatedAt = Date.distantPast
    /// Server-VAD is mid-utterance: speech_started arrived, speech_stopped
    /// hasn't. If the echo gate closes the mic NOW (her audio starts playing),
    /// the server is left holding a chopped fragment with no end — semantic
    /// VAD dangles, and when the gate reopens the tail commits as a garbage
    /// turn that gets a wrong answer (2026-08-12 root-cause finding #1). The
    /// gate-close path uses this flag to discard the fragment instead.
    private var serverHearsSpeech = false
    /// Truncation bookkeeping (2026-08-12 root-cause finding #4): when local
    /// playback is flushed (barge-in, Stop, interruption), the server still
    /// believes every unplayed word was HEARD — its context and his screen
    /// contain speech that never reached his ears, and later answers build on
    /// it ("she gives different answers"). Track the current assistant audio
    /// item and how much of it actually played, so the flush can tell the
    /// server the truth with conversation.item.truncate.
    private var currentAssistantItemId: String?
    private var drainedAudioFrames = 0
    /// One free retry for a failed/incomplete response when there is no
    /// queued text to re-send (finding #5): the spoken turn is still in the
    /// conversation, so a bare response.create recovers it. Reset on every
    /// response.created; the single-shot guard prevents a failure loop.
    private var failedResponseRetried = false
    /// MECHANICAL language mirroring (2026-08-11, build 230: English in,
    /// Hebrew out — persona instructions alone do not hold in long real
    /// sessions). The app DETECTS the language of every transcribed/typed
    /// utterance and, whenever it changes, pins the session with a system
    /// context item ("Ido is speaking ENGLISH — reply only in English…").
    /// Recent conversation items outweigh 36k-char instructions, so the pin
    /// wins where prose lost. nil until his first utterance each session.
    private var pinnedLanguage: String?

    /// Detect the utterance's language by script. Hebrew letters → "he".
    /// ARABIC script ALSO → "he" (2026-08-12: the transcriber sometimes
    /// mis-writes his Hebrew in Arabic script — Ido never speaks Arabic, so
    /// Arabic glyphs are misread Hebrew; the old any-letter→"en" rule pinned
    /// English from them and she answered his Hebrew in English repeatedly,
    /// apologizing and doing it again). English now needs REAL evidence —
    /// two ASCII words — so a garbled scrap pins nothing and the previous
    /// pin stands.
    private func detectLanguage(_ text: String) -> String? {
        let scalars = text.unicodeScalars
        if scalars.contains(where: { (0x0590...0x05FF).contains($0.value) }) { return "he" }
        if scalars.contains(where: { (0x0600...0x06FF).contains($0.value) }) { return "he" }
        let asciiWords = text.split(whereSeparator: { !$0.isLetter })
            .filter { w in w.count >= 2 && w.allSatisfy { $0.isASCII } }
        if asciiWords.count >= 2 { return "en" }
        return nil
    }

    /// Re-pin the session's reply language when his utterance's language
    /// differs from the current pin. Sent as a non-interrupting system item —
    /// it lands in context BEFORE the next response is generated.
    private func pinLanguage(from utterance: String) {
        guard engine == .openai, let lang = detectLanguage(utterance), lang != pinnedLanguage else { return }
        pinnedLanguage = lang
        sendContext(lang == "he"
            ? "[LANGUAGE] עידו מדבר עכשיו עברית. ענה אך ורק בעברית עד שהוא עובר שפה. (פריטי חדשות עדיין נקראים בשפת המקור שלהם.)"
            : "[LANGUAGE] Ido is speaking ENGLISH right now. Reply ONLY in English until he switches languages. (News items are still read in their original language.)")
    }

    /// Tool calls already executed this session (by call_id) — execution is
    /// deliberately triggered from TWO independent server events
    /// (function_call_arguments.done AND output_item.done), so a single
    /// missed event can never silently lose a tool call. This set dedupes.
    private var handledToolCalls = Set<String>()
    /// The capture sample rate the CURRENT engine expects (OAI 24k; EL 16k).
    private var captureRate: Double = 24000

    /// One-way, once-per-session switch to the backup engine.
    private func switchToBackupEngine(_ why: String) {
        guard engine == .eleven, !engineFellBack else { return }
        clientLog("engine-failover", why)
        engine = .openai
        engineFellBack = true
        outputRate = 24000
        stopAudio()   // the graph rebuilds at the backup engine's rates
        transcript.append(.init(
            text: "🎙 Premium voice unavailable (\(why)) — switching to the backup voice. The premium voice returns automatically.",
            fromHer: true))
        status = "Switching to the backup voice…"
        reconnectAttempts = 0
    }

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

    /// Set by TalkView on its first appearance so tab switches never
    /// re-trigger the auto-connect. Not published — pure bookkeeping.
    var hasAutoStarted = false

    private var ws: URLSessionWebSocketTask?
    private lazy var wsSession = URLSession(configuration: .default)
    private var token = ""
    private var outputRate: Double = 24000   // OpenAI Realtime speaks 24 kHz PCM16

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

    // The always-answer guarantee. A cell socket can die WITHOUT the receive
    // callback ever firing (NAT timeout on hotel LTE): the app then sits in
    // .listening against a corpse, and a typed question vanishes into it with
    // the send error silently discarded — the "answering silently" dead end.
    // Three guards close it:
    //  1. sendUserMessage() checks the send completion — a failed send requeues
    //     the text and rebuilds the socket.
    //  2. A reply watchdog arms on every user turn — no sign of life from her
    //     (audio, text, or a tool call) within the window means the session is
    //     stalled: requeue the question and rebuild.
    //  3. A transport-level ping loop detects the dead socket within seconds
    //     even while nobody is talking, instead of never.
    /// The user turn currently awaiting her first sign of life; requeued on
    /// stall or transport death so it is ALWAYS eventually answered.
    private var awaitingReplyText: String?
    private var replyWatchdog: Task<Void, Never>?
    /// How long a user turn may go with zero response events before the
    /// session is declared stalled. Signs of life (first audio/text/tool
    /// event) cancel it — so a long tool run doesn't trip it, only silence.
    private let replyWatchdogSeconds: UInt64 = 25
    private var livenessTask: Task<Void, Never>?

    // Transport visibility (2026-08-11 death-loop hunt): every reconnect and
    // its REASON is beaconed to the backend so the loop's cause is readable
    // from server logs instead of guessed. Fire-and-forget; never blocks.
    private var connectedAt = Date.distantPast
    private func clientLog(_ kind: String, _ detail: String) {
        var comps = URLComponents(url: AppConfig.appAPIURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = (comps.queryItems ?? []) + [URLQueryItem(name: "op", value: "clientlog")]
        guard let u = comps.url else { return }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(TokenStore.token ?? "", forHTTPHeaderField: "x-scarlet-token")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "kind": kind,
            "detail": detail,
            "session_secs": Int(Date().timeIntervalSince(connectedAt)),
            "reconnects": reconnectAttempts,
            "dropped_chunks": droppedChunks,
            "transcript_lines": transcript.count,
        ])
        URLSession.shared.dataTask(with: req).resume()
    }

    // Audio send backpressure. On a weak uplink (hotel Wi-Fi) unchecked
    // continuous audio sends queue inside the socket without bound until the
    // transport collapses — prime death-loop fuel. Cap the in-flight sends at
    // ~1s of audio; past it chunks are DROPPED (server VAD tolerates gaps far
    // better than a dead socket) and the pressure is counted for the beacons.
    private var audioSendsInFlight = 0
    private var droppedChunks = 0

    /// Background-task assertion held while a live session is backgrounded.
    /// UIBackgroundModes:[audio] keeps the engine alive while audio plays, but
    /// this assertion bridges the quiet gaps (nobody speaking) so iOS doesn't
    /// suspend the socket the moment the screen locks in the car. `.invalid`
    /// when none is held.
    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    // Audio — built once, reused across reconnects. Re-running mic setup
    // (a second installTap on the same bus) is an instant NSException crash.
    // `var`, not `let`: a media-services reset orphans both objects and Apple's
    // contract for that notification is to discard and recreate them (see the
    // reset observer). Still exactly ONE live instance at any moment — the
    // singleton invariant holds.
    private var audioEngine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var converter: AVAudioConverter?
    private var playFormat: AVAudioFormat?
    private var audioReady = false
    /// True from interruption `.began` (another app — Spotify starting to play,
    /// a phone call, Siri — took the audio session) until a successful recovery.
    /// While set, NOTHING drives the torn-down audio unit: incoming speech
    /// audio is dropped (player.play() against a dead engine is an NSException
    /// crash, not a throw — THE "moved music to the phone mid-call" crash) and
    /// the route-change / config-change observers stand down instead of
    /// fighting the other app for the session. The call itself — socket,
    /// transcript, state — stays fully alive; audio comes back on `.ended`.
    private var interrupted = false

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
    /// HALF-DUPLEX ON EVERY OPEN-AIR ROUTE — deliberately. The 2026-08-11
    /// full-duplex experiment (stream through the session's AEC while she
    /// speaks, for barge-in) put build 218 into a listening↔reconnecting death
    /// loop: the raw AVAudioEngine input tap is NOT voice-processed, so her
    /// loudspeaker voice fed straight back as "user speech", tripping
    /// interruptions and phantom turns until sessions collapsed. Do not
    /// re-open the LOUDSPEAKER gate without true voice-processing I/O
    /// (inputNode.setVoiceProcessingEnabled) proven on-device first.
    /// Sealed-ear routes are the exception — see sealedEarRoute.
    private var echoRisk: Bool {
        if chatMode || !speakerOn { return false }   // her voice is silent
        if sealedEarRoute { return false }           // her voice can't reach the mic
        return pendingBuffers > 0 || Date() < speechTailUntil
    }

    /// True when EVERY live output is sealed in/against Ido's ear — wired
    /// headphones, a Bluetooth headset (AirPods run the HFP hands-free
    /// profile while our mic is live), or the call earpiece. On these routes
    /// her voice physically cannot reach the microphone, so full duplex is
    /// safe and Ido can interrupt her just by speaking (2026-08-12: "she
    /// starts talking and then she stops listening to me" — the gate was
    /// closed even on AirPods). Loudspeaker, Bluetooth SPEAKERS (A2DP
    /// playback-only), car and USB audio are NOT sealed — those stay
    /// half-duplex per the build-218 lesson above.
    /// CACHED — echoRisk is read per mic buffer and by SwiftUI every frame;
    /// querying the session's currentRoute that often is waste. Refreshed on
    /// session start and on every route change (the only times it can flip).
    private var sealedEarRoute = false

    private func refreshSealedEarRoute() {
        let outs = AVAudioSession.sharedInstance().currentRoute.outputs
        sealedEarRoute = !outs.isEmpty && outs.allSatisfy { out in
            if out.portType == .headphones || out.portType == .bluetoothHFP
                || out.portType == .builtInReceiver || out.portType == .bluetoothLE { return true }
            // AirPods in THIS app run A2DP output + built-in phone mic (HFP is
            // deliberately banned for quality) — so the HFP check above never
            // matched and the sealed path was dead on the one route it was
            // built for (2026-08-12 root-cause finding #3). A2DP alone can't
            // be trusted (car stereos and BT speakers are A2DP too — build-218
            // lesson), so gate on the product NAME: only known ear-worn
            // devices count, anything unrecognized stays safely half-duplex.
            if out.portType == .bluetoothA2DP {
                let n = out.portName.lowercased()
                return n.contains("airpods") || n.contains("buds")
                    || n.contains("powerbeats") || n.contains("beats fit")
                    || n.contains("beats studio buds") || n.contains("earbuds")
            }
            return false
        }
    }

    /// True while the mic is genuinely delivering Ido's voice to the server —
    /// what the capture wave visualizes. NOT true while her own playback
    /// gates the mic (echoRisk), so her loudspeaker voice never masquerades
    /// as "your voice is being captured".
    var micStreaming: Bool { micOn && !echoRisk && (state == .listening || state == .speaking) }

    // MARK: lifecycle

    func start(token: String) {
        guard state == .idle else { return }
        // Kill any pending reconnect from a prior session so it can't wake a
        // second socket alongside this fresh one.
        reconnectTask?.cancel(); reconnectTask = nil; reconnecting = false
        reconnectAttempts = 0   // fresh session — start the backoff ladder over
        // A stale interrupted flag from a previous session would silently drop
        // every audio buffer of this one — a fresh start reclaims the session.
        interrupted = false
        endedByUser = false
        // OpenAI is the one and only engine — no per-session engine reset.
        engineFellBack = false
        responseActive = false
        needsResponseAfterDone = false
        // A restart mid-thread (self-heal, CarPlay revival) must continue the
        // conversation, not greet like a stranger — same as the reconnect path.
        resumedSession = !transcript.isEmpty
        self.token = token
        wantLive = true
        state = .connecting
        status = "Waking her up…"   // don't leave the stale "Ended." line up during connect
        // A live call is the moment "here" questions happen — refresh the
        // backend's location fix so her answers are about where he IS.
        LocationReporter.shared.report()
        Task { await connect() }
        observeInterruptions()
        startSignalsWatch()
        startCallWatch()
    }

    // MARK: live announcements (2026-08-11: "announce incoming messages/calls")

    /// While a session is live, poll for NEW focused arrivals (WhatsApp,
    /// iMessage, Teams, mail) and let her announce them in ONE short sentence
    /// — only when she's idle-listening, never over him or herself.
    private var signalsTask: Task<Void, Never>?
    private var lastSignalCheck = ISO8601DateFormatter().string(from: Date())

    private func startSignalsWatch() {
        signalsTask?.cancel()
        lastSignalCheck = ISO8601DateFormatter().string(from: Date())
        signalsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 45_000_000_000)
                guard let self, self.wantLive else { return }
                // Quiet moments only: mid-answer or mid-speech, skip the tick —
                // arrivals are re-fetched next round (since doesn't advance
                // until a poll actually runs).
                guard self.state == .listening, !self.responseActive, self.speakerOn else { continue }
                let since = self.lastSignalCheck
                let out = await self.performToolHTTP(name: "signals_since", params: ["since": since])
                guard let data = out.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let now = obj["now"] as? String else { continue }
                self.lastSignalCheck = now
                let signals = (obj["signals"] as? [[String: Any]]) ?? []
                guard !signals.isEmpty, self.state == .listening, !self.responseActive else { continue }
                let lines = signals.prefix(4).map { s -> String in
                    let src = (s["source"] as? String) ?? "?"
                    let sender = (s["sender"] as? String) ?? "?"
                    let preview = (s["preview"] as? String) ?? ""
                    return "\(src) from \(sender): \(preview)"
                }.joined(separator: " | ")
                self.send(["type": "conversation.item.create",
                           "item": ["type": "message", "role": "user",
                                    "content": [["type": "input_text",
                                                 "text": "[SYSTEM] New message(s) arrived: \(lines). Announce per the LIVE ANNOUNCEMENTS rule — one short sentence, then wait."]]]])
                if self.responseActive { self.needsResponseAfterDone = true } else { self.send(["type": "response.create"]) }
            }
        }
    }

    /// Incoming CELLULAR call: iOS never exposes the caller to apps, but the
    /// RINGING is knowable — she says so instead of being talked over by a
    /// ringtone he can't see (walking, CarPlay).
    private var callObserver: CXCallObserver?
    private var callWatchDelegate: CallWatchDelegate?

    private func startCallWatch() {
        guard callObserver == nil else { return }
        let observer = CXCallObserver()
        let delegate = CallWatchDelegate { [weak self] in
            Task { @MainActor in
                guard let self, self.wantLive else { return }
                self.transcript.append(Line(text: "📞 Incoming phone call", fromHer: true))
                self.send(["type": "conversation.item.create",
                           "item": ["type": "message", "role": "user",
                                    "content": [["type": "input_text",
                                                 "text": "[SYSTEM] An incoming cellular call is RINGING on his iPhone right now (iOS hides who from). Tell him in three or four words, immediately."]]]])
                if self.responseActive { self.needsResponseAfterDone = true } else { self.send(["type": "response.create"]) }
            }
        }
        observer.setDelegate(delegate, queue: nil)
        callObserver = observer
        callWatchDelegate = delegate
    }

    /// True only when IDO hung up (End button). Distinguishes his explicit
    /// choice from a give-up (network died, reconnects exhausted): a give-up
    /// self-heals on the next foreground, an explicit End stays ended —
    /// readable so CarPlay's self-restart also respects his End.
    private(set) var endedByUser = false

    func end() {
        endedByUser = true
        wantLive = false
        reconnectTask?.cancel(); reconnectTask = nil; reconnecting = false
        reconnectAttempts = 0
        signalsTask?.cancel(); signalsTask = nil
        pendingOutbound.removeAll()   // hanging up discards anything not yet delivered
        replyWatchdog?.cancel(); replyWatchdog = nil; awaitingReplyText = nil
        livenessTask?.cancel(); livenessTask = nil
        ws?.cancel(with: .goingAway, reason: nil)
        ws = nil
        stopAudio()
        endBackgroundAssertion()
        state = .idle
        status = "Ended. Tap Start (or the orb) when you want me back."
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

    func toggleMic() {
        micOn.toggle()
        // Unmuting must open her ears NOW — a stale speech-tail gate from
        // before the mute would swallow his first words after unmute.
        if micOn { speechTailUntil = .distantPast }
        // An EXPLICIT toggle overrides any typing/chat-mode snapshot: leaving
        // those modes must restore what Ido chose, never clobber it back.
        micWasOnBeforeTyping = micOn
        micWasOnBeforeChat = micOn
        status = micOn ? "Listening…" : "Mic off — tap Mic to talk"
    }
    func toggleSpeaker() {
        speakerOn.toggle()
        player.volume = speakerOn ? 1 : 0
        speakerWasOnBeforeChat = speakerOn   // explicit choice survives chat mode
    }

    /// TAP-TO-INTERRUPT (Ido 2026-08-11): the orb is the stop button while
    /// she speaks — one tap cancels the generation, flushes every queued
    /// audio buffer, and returns to listening, so an urgent question never
    /// waits out a long story. Works from the phone even while CarPlay runs
    /// (one shared session); the car screen itself cannot take touches under
    /// Apple's voice-conversation template.
    func stopSpeaking() {
        guard state == .speaking || pendingBuffers > 0 || responseActive else { return }
        if engine == .openai, responseActive {
            send(["type": "response.cancel"])
        }
        flushPlayback()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if micOn { status = "Listening…" }
    }

    /// Loudspeaker ⇄ earpiece/headset. The .defaultToSpeaker category option
    /// makes "no override" still mean loudspeaker, so the category itself must
    /// flip too. Speaker mode means the PHONE's speaker (CarPlay excepted);
    /// earpiece mode is where AirPods/Bluetooth take priority.
    func toggleLoudspeaker() {
        loudspeaker.toggle()
        applyOutputRoute()
    }

    /// True when CarPlay owns (or can own) the audio route — never fight the car.
    private var onCarRoute: Bool {
        let s = AVAudioSession.sharedInstance()
        return s.currentRoute.outputs.contains { $0.portType == .carAudio }
            || (s.availableInputs ?? []).contains { $0.portType == .carAudio }
    }

    /// The car-ness the session category was last configured for — route
    /// changes re-apply the category only on a car transition, so a category
    /// change can't re-trigger itself through its own route notification.
    private var lastAppliedCar: Bool?

    /// Category options for the chosen output. The thin-voice culprit was
    /// HFP — the narrowband phone-call codec .allowBluetooth invites, which
    /// any paired headset/Mac silently claims, while overrideOutputAudioPort
    /// cannot pull audio back off Bluetooth (2026-08-11, "her voice is very
    /// very thin"). Banning ALL Bluetooth was the first fix and broke real
    /// life: a Bluetooth-A2DP car stereo lost the audio to the iPhone
    /// ("why does car music play on my iPhone?"). The precise rule: never
    /// HFP, always A2DP — full-quality Bluetooth (cars, AirPods) keeps
    /// priority, the phone-call codec can never grab the route, and with no
    /// Bluetooth device around .defaultToSpeaker lands on the loudspeaker.
    private func outputOptions(car: Bool) -> AVAudioSession.CategoryOptions {
        // .duckOthers (2026-08-12, "when Spotify plays she can't hear me"):
        // without a mixing option, Spotify's playback fires an audio-session
        // INTERRUPTION that pauses our engine — for continuous music the
        // interruption never ends, so Scarlet went permanently deaf while a
        // song played. Ducking makes the sessions coexist: Spotify keeps
        // playing (lowered while the call is live), the mic keeps capturing,
        // and phone calls/Siri still interrupt as before. Honest limit: on
        // the LOUDSPEAKER the mic also hears the music, so recognition is
        // best with the music ducked or on headphones.
        let base: AVAudioSession.CategoryOptions = [.allowBluetoothA2DP, .duckOthers]
        _ = car // car routes need no extra options; CarPlay rides its own port
        return loudspeaker ? base.union(.defaultToSpeaker) : base
    }

    /// THE single session policy (root-caused 2026-08-12, "still faint on full
    /// speaker"): .voiceChat AND .videoChat are BOTH voice-processing modes —
    /// they reserve AEC headroom, apply call AGC, and ride the CALL volume
    /// domain, whose ceiling sits well below the media domain at the same
    /// hardware-button position. That is why the .videoChat fix helped but
    /// left her quieter than Spotify. Loudspeaker now uses .default — true
    /// media loudness. Safe because the mic is gated half-duplex client-side
    /// (echoRisk): frames are never TRANSMITTED while any of her buffers is
    /// undrained, so hardware AEC is dispensable (build-218 evidence: the raw
    /// AVAudioEngine tap was never voice-processed anyway). The car keeps
    /// .videoChat — the cabin mic needs iOS's capture tuning — and the
    /// private earpiece keeps .voiceChat by explicit choice.
    private func sessionMode(car: Bool) -> AVAudioSession.Mode {
        if car { return .videoChat }
        return loudspeaker ? .default : .voiceChat
    }

    private func applySessionCategory(car: Bool) throws {
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playAndRecord, mode: sessionMode(car: car),
                          options: outputOptions(car: car))
        try s.setActive(true)
        lastAppliedCar = car
    }

    private func applyOutputRoute() {
        let s = AVAudioSession.sharedInstance()
        let car = onCarRoute
        try? applySessionCategory(car: car)
        // Evaluate the route AFTER the category change — dropping Bluetooth
        // just moved the route back to the phone, and that's when the
        // receiver→speaker override matters. Wired headphones stay untouched.
        // Override ONLY when the port is actually wrong (2026-08-12 noise
        // regression): a redundant override emits its own route-change
        // notification, the observer re-enters here, and the resulting
        // override storm audibly stutters/clicks the output.
        let outs = s.currentRoute.outputs
        let phoneIsOutput = outs.allSatisfy {
            $0.portType == .builtInReceiver || $0.portType == .builtInSpeaker
        }
        let onSpeaker = outs.contains { $0.portType == .builtInSpeaker }
        if phoneIsOutput {
            if loudspeaker && !onSpeaker {
                try? s.overrideOutputAudioPort(.speaker)
            } else if !loudspeaker && onSpeaker {
                try? s.overrideOutputAudioPort(.none)
            }
        }
        refreshSealedEarRoute()
        logAudioState("route-applied")
    }

    /// Route changed (car connected/disconnected): re-apply the category only
    /// when car-ness actually flipped, so speaker mode frees the route for
    /// CarPlay and reclaims the phone speaker when he leaves the car.
    private func reapplyRouteForCarTransition() {
        if onCarRoute != lastAppliedCar { applyOutputRoute() }
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
        pinLanguage(from: t)   // typed words mirror the same as spoken ones
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
            sendUserMessage(text)
        }
    }

    /// Deliver a `user_message` to the live socket, or bring the session up and
    /// hold the text until it is. Sending directly only when already live means
    /// we never write to a nil `ws`; `flushPendingOutbound()` drains the queue
    /// once from `connect()`. Confined to the main actor, so enqueue and flush
    /// can't race, and an already-live send is never also queued (no double-send).
    private func deliverUserMessage(_ text: String) {
        switch state {
        case .listening, .speaking:
            sendUserMessage(text)
        case .connecting:
            pendingOutbound.append(text)
        case .idle:
            pendingOutbound.append(text)
            start(token: TokenStore.token ?? "")
        }
    }

    /// A user turn with the always-answer guarantee: the send completion is
    /// checked (not discarded), and the reply watchdog arms. Either failure
    /// path requeues the text and rebuilds the socket, so the question is
    /// re-asked on the fresh session instead of vanishing.
    private func sendUserMessage(_ text: String, createResponse: Bool = true) {
        awaitingReplyText = text
        armReplyWatchdog()
        let payload: [String: Any] = engine == .eleven
            ? ["type": "user_message", "text": text]
            : ["type": "conversation.item.create",
               "item": ["type": "message", "role": "user",
                        "content": [["type": "input_text", "text": text]]]]
        guard let d = try? JSONSerialization.data(withJSONObject: payload),
              let s = String(data: d, encoding: .utf8) else { return }
        ws?.send(.string(s)) { [weak self] error in
            guard error != nil else {
                // OpenAI: a message item doesn't answer itself — ask for the
                // response after the item lands. Only ONE response may be
                // active at a time, so while one runs the request is deferred
                // to that response's done event instead of erroring out.
                Task { @MainActor in
                    guard let self, self.engine == .openai, createResponse else { return }
                    if self.responseActive {
                        self.needsResponseAfterDone = true
                    } else {
                        self.send(["type": "response.create"])
                    }
                }
                return
            }
            Task { @MainActor in
                guard let self, self.wantLive else { return }
                // The socket rejected it, so it was NOT delivered — requeue
                // (guarding against the watchdog/reconnect having done so
                // already) and rebuild. Even a rapid burst where several sends
                // fail requeues each exactly once.
                if !self.pendingOutbound.contains(text) {
                    self.pendingOutbound.insert(text, at: 0)
                }
                if self.awaitingReplyText == text {
                    self.awaitingReplyText = nil
                    self.replyWatchdog?.cancel(); self.replyWatchdog = nil
                }
                self.scheduleReconnect(reason: "user-message-send-failed")
            }
        }
    }

    private func armReplyWatchdog() {
        replyWatchdog?.cancel()
        replyWatchdog = Task { [weak self] in
            guard let secs = self?.replyWatchdogSeconds else { return }
            try? await Task.sleep(nanoseconds: secs * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.replyWatchdogFired()
        }
    }

    private func replyWatchdogFired() {
        guard wantLive else { return }
        // Total silence for the whole window — the session is stalled or the
        // socket is dead. Hold the question when its text is known (a spoken
        // turn's watchdog can be armed before its transcript arrives — then
        // there is nothing to requeue, only a rebuild) and reconnect.
        if let text = awaitingReplyText, !text.isEmpty {
            pendingOutbound.insert(text, at: 0)
        }
        awaitingReplyText = nil
        status = "Stalled — reconnecting…"
        scheduleReconnect(reason: "reply-watchdog-stall")
    }

    /// Her first response event for the outstanding turn — the reply is coming,
    /// stand the watchdog down.
    private func noteSignsOfLife() {
        guard awaitingReplyText != nil || replyWatchdog != nil else { return }
        awaitingReplyText = nil
        replyWatchdog?.cancel(); replyWatchdog = nil
    }

    /// Send everything queued while the socket was down, exactly once, in order.
    /// Called from `connect()` after the socket is live and initial context has
    /// been replayed, so queued turns land after her focus/continuation setup.
    private func flushPendingOutbound() {
        guard !pendingOutbound.isEmpty else { return }
        let queued = pendingOutbound
        pendingOutbound.removeAll()
        // One response answers ALL queued turns (it reads the full
        // conversation) — per-message creates would collide on the
        // one-active-response rule and orphan the extras.
        for (i, text) in queued.enumerated() {
            sendUserMessage(text, createResponse: i == queued.count - 1)
        }
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
        sendContext(text ?? "[FOCUS] Nothing focused.")
    }

    /// Non-interrupting ambient context, engine-appropriate: ElevenLabs has a
    /// dedicated contextual_update event; OpenAI takes a system message item
    /// WITHOUT response.create, so it never counts as a user turn either.
    private func sendContext(_ text: String) {
        if engine == .eleven {
            send(["type": "contextual_update", "text": text])
        } else {
            send(["type": "conversation.item.create",
                  "item": ["type": "message", "role": "system",
                           "content": [["type": "input_text", "text": text]]]])
        }
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
        sendContext("[DRIVING MODE] Ido is now in the car, connected over the car's speakers and microphone — hands-free AND eyes-free. He cannot look at or touch the screen. Speak everything aloud: never say \"look at your screen\", \"tap\", or \"see below\". Read results out loud ONE item at a time, keep each turn short, and wait for his voice before continuing. Confirm out loud before taking any action. In the car the draft-window rules INVERT: read every draft FULLY aloud, take his revisions by voice, and send only on his spoken approval — never say \"it's on your screen\" while he's driving.")
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
            // ── Mint per engine ──
            let socketRequest: URLRequest
            if engine == .eleven {
                var req = URLRequest(url: AppConfig.elevenURL)
                req.httpMethod = "POST"
                req.setValue(token, forHTTPHeaderField: "x-scarlet-token")
                let (data, resp) = try await URLSession.shared.data(for: req)
                // 402 = the quota gate said the premium voice is out of
                // credits BEFORE a doomed socket — fall over immediately.
                if (resp as? HTTPURLResponse)?.statusCode == 402 {
                    switchToBackupEngine("out of credits")
                    guard wantLive else { return }
                    await connect()
                    return
                }
                let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                guard let signed = obj?["signed_url"] as? String, let url = URL(string: signed) else {
                    status = "Couldn't start — try again."; state = .idle; wantLive = false
                    pendingOutbound.removeAll()   // no session is coming — don't replay stale text later
                    return
                }
                socketRequest = URLRequest(url: url)
            } else {
                // THE engine: OpenAI Realtime. realtime-session carries the
                // full brain server-side (persona, tools, semantic VAD) — the
                // mint returns an ephemeral client secret for the GA socket.
                // The Settings-chosen voice rides along (?voice=), Marin when
                // unset — Ido's recorded pick.
                var mintURL = AppConfig.realtimeURL
                if let v = UserDefaults.standard.string(forKey: SettingsModel.voiceKey),
                   !v.isEmpty,
                   let u = URL(string: AppConfig.realtimeURL.absoluteString + "?voice=" + v) {
                    mintURL = u
                }
                var req = URLRequest(url: mintURL)
                req.httpMethod = "POST"
                req.setValue(token, forHTTPHeaderField: "x-scarlet-token")
                let (data, resp) = try await URLSession.shared.data(for: req)
                let httpStatus = (resp as? HTTPURLResponse)?.statusCode ?? 0
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                guard let secret = obj?["client_secret"] as? String, !secret.isEmpty,
                      let url = URL(string: "wss://api.openai.com/v1/realtime?model=gpt-realtime") else {
                    // A bad token is terminal; everything else (cold start,
                    // 429, 5xx, malformed body) is TRANSIENT — retry through
                    // the normal backoff and KEEP the queued text. Hard-idling
                    // here destroyed the very question the always-answer
                    // machinery was holding.
                    if httpStatus == 401 || httpStatus == 403 {
                        status = "Couldn't start — sign in again from Settings."
                        state = .idle; wantLive = false
                        pendingOutbound.removeAll()
                        return
                    }
                    if wantLive { scheduleReconnect(reason: "mint-failed-\(httpStatus)") }
                    return
                }
                var wsReq = URLRequest(url: url)
                wsReq.setValue("Bearer " + secret, forHTTPHeaderField: "Authorization")
                socketRequest = wsReq
            }
            // The engine decides the capture rate — a mismatched graph is
            // rebuilt by ensureAudio after stopAudio.
            let desiredCapture: Double = engine == .openai ? 24000 : 16000
            if captureRate != desiredCapture {
                captureRate = desiredCapture
                if audioReady { stopAudio() }
            }
            // The user may have tapped End while we were fetching the URL — do
            // NOT resurrect a session he explicitly hung up on.
            guard wantLive else { return }
            // Audio-start failure is NOT a transport drop — reconnecting can't fix
            // a dead mic/engine, it just loops. Surface it and stop — UNLESS an
            // interruption is in progress (another app holds the session, e.g.
            // Spotify playing mid-call): there audio is EXPECTED to be
            // unavailable, so bring the socket up anyway and continue in text;
            // the interruption's .ended handler restores the audio.
            do {
                try ensureAudio()
            } catch where !interrupted {
                status = "Can't reach the microphone right now. Check it's free (not held by another app) and try again."
                state = .idle; wantLive = false
                reconnectTask?.cancel(); reconnectTask = nil; reconnecting = false
                pendingOutbound.removeAll()
                return
            } catch {
                // Interrupted: proceed without audio — the call lives in text.
            }
            // Connected: a real socket is up. Clear the backoff counter and
            // stale send accounting from the previous socket's corpse.
            connectedAt = Date()   // BEFORE the beacon, so session_secs is sane
            clientLog("connected", "attempt=\(reconnectAttempts)")
            reconnectAttempts = 0
            audioSendsInFlight = 0
            handledToolCalls.removeAll()
            responseActive = false
            needsResponseAfterDone = false
            pinnedLanguage = nil   // fresh session — re-pin from his first words
            let task = wsSession.webSocketTask(with: socketRequest)
            ws = task
            task.resume()
            if engine == .eleven {
                send(["type": "conversation_initiation_client_data"])
            }
            listen(task)
            state = .listening
            status = micOn ? "Listening…" : "Mic off — tap Mic to talk"
            // A fresh socket knows nothing about the screen — replay the
            // current focus so a reconnect regains ambient context.
            if let focus = currentFocus {
                sendContext(focus)
            }
            if resumedSession {
                resumedSession = false
                // Recent transcript lines ride along so the renewed session
                // keeps the thread instead of greeting him like a stranger.
                let recent = transcript.suffix(6)
                    .map { ($0.fromHer ? "Scarlet: " : "Ido: ") + $0.text.prefix(200) }
                    .joined(separator: "\n")
                sendContext("[FOCUS] Connection renewed mid-conversation (the previous session hit a transport drop or time cap). This is a CONTINUATION — do not greet, do not reset. Recent exchange:\n" + recent)
            }
            // Car / eyes-free: now that we're connected, re-check the live route.
            // forceAnnounce so a fresh OR rebuilt (amnesiac) socket is told about
            // driving mode if we're already on a car route.
            evaluateDrivingMode(forceAnnounce: true)
            // Transport truth: without pings a cell socket killed by a NAT
            // timeout looks "connected" forever and the receive callback never
            // fires — this loop finds the corpse within seconds instead of never.
            startLivenessPings()
            // Socket is live and context is replayed — deliver anything typed,
            // dictated, or shared while she was asleep/connecting. Exactly once.
            flushPendingOutbound()
        } catch {
            if wantLive {
                scheduleReconnect(reason: "connect-error: " + String(String(describing: error).prefix(120)))
            } else { status = "Couldn't connect — tap to retry."; state = .idle }
        }
    }

    /// The receive loop is BOUND TO ONE SOCKET: the task is captured and every
    /// action re-checks `self.ws === task` on the main actor. Without this, a
    /// dead socket's late failure callback could tear down its healthy
    /// replacement, and the re-arm could attach a SECOND receive loop to the
    /// new socket — two loops splitting events destroys ordering.
    private func listen(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                // The server's close reason is the only honest diagnosis of a
                // kill — read it BEFORE rebuilding (safe: closeReason on the
                // captured task, not the mutable self.ws).
                let closeReason = task.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                Task { @MainActor in
                    guard self.ws === task else { return }   // a ghost's failure — ignore
                    // A quota kill mid-session: the premium voice is spent.
                    // Fall over to the backup engine LIVE — the conversation
                    // continues on the other voice instead of dying.
                    if closeReason.lowercased().contains("quota"), self.engine == .eleven, !self.engineFellBack {
                        self.clientLog("quota-exhausted", closeReason)
                        self.switchToBackupEngine("out of credits")
                        self.scheduleReconnect(reason: "quota-failover")
                        return
                    }
                    self.scheduleReconnect(reason: "ws-receive: " + String(String(describing: err).prefix(120))
                        + (closeReason.isEmpty ? "" : " | close: " + String(closeReason.prefix(80))))
                }
            case .success(let msg):
                if case .string(let text) = msg,
                   let data = text.data(using: .utf8),
                   let ev = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    Task { @MainActor in
                        guard self.ws === task else { return }   // stale socket's leftovers
                        self.handle(ev)
                    }
                }
                self.listen(task)   // re-arm on the SAME socket, never self.ws
            }
        }
    }

    /// Silent auto-reconnect, native edition of the web app's transport-drop
    /// handler. Single-flight; audio graph stays up, only the socket rebuilds.
    private func scheduleReconnect(reason: String = "unspecified") {
        guard wantLive, !reconnecting else { return }
        clientLog("reconnect", reason)
        // Three straight failures on the premium engine → stop insisting and
        // fall over to the backup (≈6s in, not a minute of backoff). She must
        // ALWAYS come back on SOME voice.
        if reconnectAttempts >= 3, engine == .eleven, !engineFellBack {
            switchToBackupEngine("connection kept failing")
        }
        // Give up after a bounded number of tries so a truly dead network ends in
        // an actionable state, not an eternal spinner. VOICE-ONLY (2026-08-11
        // audit): walking with the phone locked, ~57s of bad network used to
        // end the session in total silence — he kept talking to a corpse. Now
        // the give-up (a) keeps a LONG-TAIL retry alive every 60s while the
        // app still wants a session, so a network handoff that recovers
        // brings her back by itself, and (b) will announce the recovery
        // (connect() greets a resumed session).
        if reconnectAttempts >= maxReconnectAttempts {
            status = "Connection lost — retrying in the background…"
            state = .connecting
            reconnectTask?.cancel(); reconnecting = false
            reconnectAttempts = maxReconnectAttempts // hold the ladder at max
            reconnectTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard let self, self.wantLive, !Task.isCancelled else { return }
                await MainActor.run {
                    self.reconnectAttempts = 3 // re-enter the ladder mid-way
                    self.scheduleReconnect(reason: "long-tail retry after network loss")
                }
            }
            return
        }
        reconnecting = true
        // A turn still waiting for its reply rides over to the rebuilt session:
        // requeue it so connect() re-asks it — never silently dropped.
        if let text = awaitingReplyText {
            awaitingReplyText = nil
            replyWatchdog?.cancel(); replyWatchdog = nil
            pendingOutbound.insert(text, at: 0)
        }
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
            // Clear the single-flight flag BEFORE connect(): if connect()
            // throws it calls scheduleReconnect itself, and with the flag
            // still up that call was swallowed — the loop silently died and
            // the app sat in "Reconnecting…" forever (the one-failed-retry
            // dead end).
            reconnecting = false
            if wantLive, !Task.isCancelled { await connect() }
        }
    }

    /// Repeating transport-level ping. WebSocket pings ride below the ElevenLabs
    /// protocol, so they cost nothing in the conversation — but a socket the
    /// network silently killed fails the pong, which is the ONLY timely signal
    /// of a dead cell connection while nobody is talking. Single instance:
    /// re-arming cancels the previous loop.
    private func startLivenessPings() {
        livenessTask?.cancel()
        livenessTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self, !Task.isCancelled, self.wantLive else { return }
                self.pingNow()
            }
        }
    }

    /// One transport ping; a failed pong means the socket is a corpse → rebuild.
    /// Also called on return to foreground, where a backgrounded socket has
    /// often died without any callback ever firing.
    private func pingNow() {
        guard wantLive, state == .listening || state == .speaking, let ws else { return }
        let task = ws   // bind the verdict to THIS socket, not whatever ws is later
        task.sendPing { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor in
                guard let self, self.wantLive, self.ws === task else { return }
                self.scheduleReconnect(reason: "ping-failed")
            }
        }
    }

    /// Record-permission gate. Returns true only if the mic is authorized.
    /// Requests once on first use; returns the standing decision thereafter.
    private func ensureMicPermission() async -> Bool {
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

    private func send(_ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: d, encoding: .utf8) else { return }
        ws?.send(.string(s)) { _ in }
    }

    /// Audio chunk send with in-flight accounting — the completion is the only
    /// truth about whether the socket is draining. Pairs with the backpressure
    /// guard at the call site.
    private func sendAudio(_ b64: String) {
        audioSendsInFlight += 1
        let payload: [String: Any] = engine == .eleven
            ? ["user_audio_chunk": b64]
            : ["type": "input_audio_buffer.append", "audio": b64]
        guard let d = try? JSONSerialization.data(withJSONObject: payload),
              let s = String(data: d, encoding: .utf8) else {
            audioSendsInFlight -= 1
            return
        }
        ws?.send(.string(s)) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.audioSendsInFlight = max(0, self.audioSendsInFlight - 1)
            }
        }
    }

    // MARK: protocol

    private func handle(_ ev: [String: Any]) {
        if engine == .openai { handleOpenAI(ev); return }
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
            // Deliberately NOT signs-of-life for the reply watchdog: trailing
            // audio chunks of her PREVIOUS sentence ("are you still there?")
            // keep streaming after a typed turn is sent, and treating them as
            // "the reply started" disarmed the watchdog while the server never
            // actually answered — the typed question then vanished silently
            // (the 2026-08-10 dead end). Only semantic reply markers —
            // agent_response and client_tool_call — stand the watchdog down.
            if let a = ev["audio_event"] as? [String: Any], let b64 = a["audio_base_64"] as? String {
                playPCM(base64: b64)
            }
        case "agent_response":
            noteSignsOfLife()
            if let x = ev["agent_response_event"] as? [String: Any],
               let t = (x["agent_response"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !t.isEmpty { transcript.append(.init(text: t, fromHer: true)) }
        case "user_transcript":
            if let x = ev["user_transcription_event"] as? [String: Any],
               let t = (x["user_transcript"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !t.isEmpty {
                transcript.append(.init(text: t, fromHer: false))
                // THE ≤2s ACK (Ido 2026-08-11): the instant the server heard
                // him, he knows it — his words appear as a bubble, the status
                // flips, and the phone taps. Never again "did she get that?".
                status = "Got it — on it…"
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                // A SPOKEN turn the server heard gets the same always-answer
                // guarantee as a typed one: if no reply ever starts, the
                // watchdog requeues this text on the rebuilt session.
                awaitingReplyText = t
                armReplyWatchdog()
            }
        case "agent_response_correction":
            // She was interrupted mid-sentence: the server sends what she
            // ACTUALLY got to say. The text box must be the exact replica of
            // her spoken words (Ido 2026-08-11) — replace, never leave words
            // she never voiced.
            if let x = ev["agent_response_correction_event"] as? [String: Any],
               let t = ((x["corrected_agent_response"] as? String) ?? "")
                   .trimmingCharacters(in: .whitespacesAndNewlines) as String?,
               let idx = transcript.lastIndex(where: { $0.fromHer }) {
                if t.isEmpty {
                    transcript.remove(at: idx)   // cut off before a word landed
                } else {
                    transcript[idx] = .init(text: t, fromHer: true)
                }
            }
        case "interruption":
            flushPlayback()
        case "ping":
            let id = (ev["ping_event"] as? [String: Any])?["event_id"]
            send(["type": "pong", "event_id": id as Any])
        case "client_tool_call":
            noteSignsOfLife()
            if let c = ev["client_tool_call"] as? [String: Any] { runTool(c) }
        default: break
        }
    }

    /// The backup engine's event stream (OpenAI Realtime GA). Beta-era event
    /// names are handled alongside GA ones so an API-side rename can't mute her.
    private func handleOpenAI(_ ev: [String: Any]) {
        switch ev["type"] as? String {
        case "response.output_audio.delta", "response.audio.delta":
            if let id = ev["item_id"] as? String, id != currentAssistantItemId {
                currentAssistantItemId = id
                drainedAudioFrames = 0
            }
            if let b64 = ev["delta"] as? String { playPCM(base64: b64) }
        case "response.created":
            // The reply is being generated — semantic sign of life. It reads
            // the full conversation, so every input that landed before this
            // moment is covered by it — a deferred create would only make her
            // re-answer the same thing (the 225 double-answer/translation bug).
            responseActive = true
            needsResponseAfterDone = false
            lastResponseCreatedAt = Date()
            failedResponseRetried = false
            noteSignsOfLife()
        case "response.done":
            responseActive = false
            let rstatus = ((ev["response"] as? [String: Any])?["status"] as? String) ?? "completed"
            if rstatus == "cancelled" {
                // Cancelled = Ido cut her off (barge-in or Stop). Semantic VAD
                // creates the response for his NEW turn itself (create_response
                // is on) — a deferred create here would race that one and then
                // re-fire input-less at ITS done: the 225 double-answer bug in
                // a new coat. Drop the deferral; his next turn answers itself.
                needsResponseAfterDone = false
            }
            if rstatus != "completed" && rstatus != "cancelled" {
                // Failed/incomplete response: the always-answer net catches it
                // here — the watchdog was already disarmed by response.created.
                clientLog("response-failed", rstatus)
                if let q = awaitingReplyText, !q.isEmpty {
                    awaitingReplyText = nil
                    pendingOutbound.insert(q, at: 0)
                    flushPendingOutbound()
                } else if !failedResponseRetried {
                    // Spoken turn with no re-sendable text (finding #5): his
                    // committed audio is still in the conversation — one bare
                    // response.create answers it instead of going silent.
                    failedResponseRetried = true
                    clientLog("response-failed-retry", "bare create for spoken turn")
                    send(["type": "response.create"])
                } else {
                    flushPendingOutbound()
                }
            }
            // A turn that arrived while this response ran gets its answer now.
            if needsResponseAfterDone {
                needsResponseAfterDone = false
                clientLog("deferred-response", "create-after-done")
                send(["type": "response.create"])
            }
        case "response.output_audio_transcript.done", "response.audio_transcript.done":
            noteSignsOfLife()
            if let t = (ev["transcript"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !t.isEmpty { transcript.append(.init(text: t, fromHer: true)) }
        case "conversation.item.input_audio_transcription.completed":
            if let t = (ev["transcript"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !t.isEmpty {
                transcript.append(.init(text: t, fromHer: false))
                // Mirror his language mechanically: detect what he ACTUALLY
                // spoke and pin the session to it the moment it changes.
                pinLanguage(from: t)
                status = "Got it — on it…"
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                // Transcription is ASYNC and routinely lands AFTER the reply.
                // Arming the watchdog here regardless tore down a healthy
                // session 25s after every quiet turn (the phantom-stall trap).
                // Only treat this as an unanswered turn when no response has
                // started since the speech ended; otherwise just record it.
                if lastResponseCreatedAt < lastSpeechStoppedAt {
                    awaitingReplyText = t
                    armReplyWatchdog()
                } else if awaitingReplyText != nil, awaitingReplyText!.isEmpty {
                    awaitingReplyText = t   // give the armed placeholder its text
                }
            }
        case "conversation.item.input_audio_transcription.failed":
            clientLog("transcription-failed",
                      String(describing: ev["error"] ?? "unknown").prefix(160).description)
        case "input_audio_buffer.speech_started":
            serverHearsSpeech = true
            // Server-side truth that his voice is registering — instant cue.
            // On sealed-ear (full-duplex) routes this can fire WHILE she is
            // speaking: that is Ido interrupting her. The server no longer
            // truncates on its own (interrupt_response=false after the
            // 2026-08-12 disaster) — cut the locally queued audio AND tell
            // the server what was actually heard (flushPlayback truncates),
            // so she stops in his ear the moment he speaks.
            if pendingBuffers > 0, sealedEarRoute {
                flushPlayback()
                clientLog("barge-in", "speech_started during playback — cut her audio")
            }
            if state == .listening, micOn { status = "Hearing you…" }
        case "input_audio_buffer.speech_stopped":
            serverHearsSpeech = false
            lastSpeechStoppedAt = Date()
            // A reply is now DUE — arm the stall net immediately (with an
            // empty placeholder; the async transcript fills it in). Speech
            // that landed while a response was active would otherwise be
            // dropped by the server — defer a response.create to its done.
            if responseActive {
                needsResponseAfterDone = true
            } else {
                awaitingReplyText = ""
                armReplyWatchdog()
            }
            if state == .listening { status = "Thinking…" }
        case "input_audio_buffer.committed":
            serverHearsSpeech = false
            if responseActive { needsResponseAfterDone = true }
        case "response.function_call_arguments.done":
            noteSignsOfLife()
            let toolName = ev["name"] as? String ?? ""
            let callId = ev["call_id"] as? String ?? ""
            guard !callId.isEmpty, !handledToolCalls.contains(callId) else { break }
            handledToolCalls.insert(callId)
            clientLog("tool-call", toolName.isEmpty ? "MISSING-NAME" : toolName)
            runToolOpenAI(name: toolName,
                          callId: callId,
                          argsJSON: ev["arguments"] as? String ?? "{}")
        case "response.output_item.done":
            // Redundant tool-call trigger: the completed output item carries
            // the FULL function call (name, call_id, arguments). If the
            // arguments.done event was ever missed or malformed, this one
            // still executes the tool — she can never silently skip a call.
            if let item = ev["item"] as? [String: Any],
               (item["type"] as? String) == "function_call" {
                let callId = item["call_id"] as? String ?? ""
                guard !callId.isEmpty, !handledToolCalls.contains(callId) else { break }
                handledToolCalls.insert(callId)
                noteSignsOfLife()
                clientLog("tool-call-fallback", item["name"] as? String ?? "MISSING-NAME")
                runToolOpenAI(name: item["name"] as? String ?? "",
                              callId: callId,
                              argsJSON: item["arguments"] as? String ?? "{}")
            }
        case "error":
            let eobj = ev["error"] as? [String: Any]
            let code = (eobj?["code"] as? String) ?? ""
            let msg = (eobj?["message"] as? String) ?? "unknown"
            // A create that collided with an active response is recoverable:
            // re-ask the moment the active one finishes.
            if code.contains("active_response") { needsResponseAfterDone = true }
            clientLog("openai-error", String((code + " " + msg).prefix(200)))
        default: break
        }
    }

    // ── Tool execution, shared by BOTH voice engines ──
    // The cues and the HTTP are engine-agnostic; only the result event that
    // rides back on the socket differs (client_tool_result vs
    // function_call_output + response.create).

    /// Instant, pre-network cues the moment a tool call arrives.
    private func preToolCues(name: String, params: [String: Any]) {
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
            NotificationCenter.default.post(name: .scarletVoiceDraftIntent, object: intent)
        }
        // MUSIC ACK GUARANTEE (Ido 2026-08-10): the instant a music tool call
        // arrives — before any network round-trip — the phone acknowledges in
        // feel and sight: a light haptic tap + live status. Her spoken ack
        // rides the voice channel; this cue fires even when the room is loud.
        if Self.musicTools.contains(name) {
            status = "🎵 On the music…"
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    private static let musicTools: Set<String> = ["play_music", "music_control", "start_radio",
                                                  "create_playlist", "whats_playing", "fm_radio"]

    /// Cap a tool result for the model's context — but never SILENTLY
    /// (2026-08-11 voice-only audit: a busy sweep's payload was cut mid-JSON
    /// and the model answered from half the data without knowing). The sweep
    /// gets a higher ceiling — its items are the only way to act on messages
    /// — and any cut is MARKED so she says so instead of inventing.
    private func cappedToolResult(_ name: String, _ out: String) -> String {
        let cap = name == "inbox_overview" ? 24_000 : 12_000
        guard out.count > cap else { return out }
        return String(out.prefix(cap))
            + "\n…[RESULT TRUNCATED at \(cap) chars — data beyond this point was cut; say so honestly if something seems missing and fetch a narrower page instead of guessing]"
    }

    /// The authorized tool proxy round-trip (realtime-session → agent-tools).
    private func performToolHTTP(name: String, params: [String: Any]) async -> String {
        do {
            var req = URLRequest(url: AppConfig.toolURL(name))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(token, forHTTPHeaderField: "x-scarlet-token")
            req.httpBody = try JSONSerialization.data(withJSONObject: params)
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code < 200 || code > 299 {
                clientLog("tool-http", "\(name) status=\(code)")
            }
            return String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            clientLog("tool-http", "\(name) failed: " + String(String(describing: error).prefix(100)))
            return "{\"error\":\"tool failed\"}"
        }
    }

    /// ElevenLabs client_tool_call entry.
    private func runTool(_ c: [String: Any]) {
        let name = c["tool_name"] as? String ?? ""
        let callId = c["tool_call_id"] as? String ?? ""
        let params = c["parameters"] as? [String: Any] ?? [:]
        preToolCues(name: name, params: params)
        Task {
            let out = await performToolHTTP(name: name, params: params)
            // 12k cap: every tool result lives in the agent's context for the
            // REST of the conversation — 30k results made hour-long dialogues
            // slower and slower until replies timed out entirely.
            send(["type": "client_tool_result", "tool_call_id": callId,
                  "result": cappedToolResult(name, out), "is_error": false])
            postToolCues(name: name, out: out)
        }
    }

    /// OpenAI Realtime function-call entry (the backup engine).
    private func runToolOpenAI(name: String, callId: String, argsJSON: String) {
        let params = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any] ?? [:]
        preToolCues(name: name, params: params)
        Task {
            let out = await performToolHTTP(name: name, params: params)
            send(["type": "conversation.item.create",
                  "item": ["type": "function_call_output", "call_id": callId,
                           "output": cappedToolResult(name, out)]])
            // Same one-active-response gate as user turns: if Ido spoke while
            // the tool HTTP ran, semantic VAD already created a response — an
            // unconditional create here collides (the 225 error bursts) and
            // the deferral then re-answered the turn twice. Defer instead.
            if responseActive {
                needsResponseAfterDone = true
            } else {
                send(["type": "response.create"])
            }
            postToolCues(name: name, out: out)
            // Her 1Password ask just went through THIS device — surface the
            // Face-ID approval card immediately instead of waiting for a poll
            // (the card expires in ~3 minutes; every second of lag is felt).
            if name == "request_secret" { SecretApprovalsModel.shared.refresh() }
        }
    }

    /// Post-result cues: the visual confirmations that ride the RESULT.
    private func postToolCues(name: String, out: String) {
        do {
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
            // FM radio result → the server resolved the station; the PHONE is
            // the player. Start/pause/stop the stream and mirror it visually,
            // exactly like the Spotify confirmations below.
            if name == "fm_radio",
               let data = out.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                Task { @MainActor in
                    if (obj["ok"] as? Bool) == true {
                        RadioPlayer.shared.apply(toolResult: obj)
                        if let st = obj["station"] as? [String: Any],
                           let nm = (st["name_he"] as? String) ?? (st["name"] as? String) {
                            transcript.append(Line(text: "📻 \(nm) — live", fromHer: true))
                            status = "Radio: \(nm)"
                        } else if let action = obj["action"] as? String, action != "list" {
                            status = "Listening…"
                        }
                    } else if let err = obj["error"] as? String {
                        transcript.append(Line(text: "📻 \(err)", fromHer: true))
                    }
                }
            }
            // Music result → the VISUAL confirmation names the device (the
            // speaker-specificity rule): a transcript line the moment the
            // server answers, mirroring what she says aloud.
            if Self.musicTools.contains(name), name != "fm_radio",
               let data = out.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                Task { @MainActor in
                    if let dev = obj["on_device"] as? String {
                        transcript.append(Line(text: "🎵 Playing on \(dev)", fromHer: true))
                        status = "Playing on \(dev)"
                    } else if let err = obj["error"] as? String {
                        transcript.append(Line(text: "🎵 \(err)", fromHer: true))
                        status = "Listening…"
                    } else if obj["retrying"] as? Bool == true {
                        // The server armed a ~24s watcher that starts playback
                        // the moment a Spotify device appears — so WAKE the
                        // Spotify app ourselves instead of asking Ido to. It
                        // foregrounds briefly, registers as a device, and the
                        // music starts on this phone by itself.
                        if let spotify = URL(string: "spotify:") {
                            UIApplication.shared.open(spotify)
                            transcript.append(Line(text: "🎵 Waking Spotify — starting on this phone…", fromHer: true))
                        } else {
                            transcript.append(Line(text: "🎵 Open Spotify once — it will start by itself", fromHer: true))
                        }
                        status = "Listening…"
                    } else {
                        status = "Listening…"
                    }
                }
            }
            // "Call Phyllis" → the server resolved the number; the call is
            // cued in EVERY modality (Ido 2026-08-10): she says it (persona),
            // the phone taps a success haptic (audio-felt), the transcript +
            // status line show it (visual) — then the call opens. tel: raises
            // iOS's one-tap Call confirm (Apple's floor, and Ido's approve
            // loop); wa.me / tg: open the person, call button one tap away.
            // Scheme allowlist so a server bug can never open arbitrary URLs.
            if name == "start_call",
               let data = out.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let urlStr = obj["url"] as? String,
                   let url = URL(string: urlStr),
                   ["tel", "https", "tg", "facetime-audio"].contains(url.scheme ?? "") {
                    let label = (obj["label"] as? String) ?? (obj["number"] as? String) ?? "…"
                    let channel = (obj["channel"] as? String) ?? "phone"
                    let channelName = channel == "whatsapp" ? "WhatsApp"
                        : channel == "telegram" ? "Telegram"
                        : channel == "facetime" ? "FaceTime audio"
                        : channel == "teams" ? "Teams" : "phone"
                    Task { @MainActor in
                        transcript.append(Line(
                            text: "📞 Calling \(label) — \(channelName)"
                                + (channel == "phone" ? " · tap Call to confirm" : ""),
                            fromHer: true))
                        status = "Calling \(label)…"
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        // NEVER a silent drop (2026-08-11 voice-only audit):
                        // under CarPlay with a locked phone, open() can fail —
                        // detect it and TELL him, in his ears, what to do.
                        UIApplication.shared.open(url, options: [:]) { [weak self] opened in
                            guard !opened else { return }
                            Task { @MainActor in
                                guard let self else { return }
                                self.transcript.append(Line(
                                    text: "📞 The \(channelName) call to \(label) couldn't open — the phone may be locked. Unlock it, or say 'call on phone' for a cellular dial through the car.",
                                    fromHer: true))
                                self.status = "Call didn't open"
                                self.send(["type": "conversation.item.create",
                                           "item": ["type": "message", "role": "user",
                                                    "content": [["type": "input_text",
                                                                 "text": "[SYSTEM] The \(channelName) call to \(label) FAILED to open (phone locked). Tell Ido honestly in one sentence and offer the cellular fallback."]]]])
                                if self.responseActive { self.needsResponseAfterDone = true } else { self.send(["type": "response.create"]) }
                            }
                        }
                    }
                } else if let err = obj["error"] as? String {
                    // The failure is cued visually too — never a silent shrug.
                    Task { @MainActor in
                        transcript.append(Line(text: "📞 Couldn't place the call — \(err)", fromHer: true))
                    }
                }
            }
            // "Take me to…" → the server's navigate_to resolved the place and
            // returned an Apple Maps driving link ({ok, name, address,
            // maps_url, google_url}). Open it directly: in the car this hands
            // off to CarPlay's own Maps with live traffic; on the phone it
            // opens driving directions. Same discipline as start_call —
            // transcript + status + haptic cue, and a scheme/host allowlist
            // (only Apple Maps) so a server bug can never open arbitrary URLs.
            if name == "navigate_to",
               let data = out.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let err = obj["error"] as? String {
                    Task { @MainActor in
                        transcript.append(Line(text: "🧭 Couldn't start navigation — \(err)", fromHer: true))
                    }
                } else {
                    let label = ((obj["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }) ?? "your destination"
                    var dest: URL?
                    for key in ["maps_url", "url"] {
                        if let s = obj[key] as? String, let u = URL(string: s),
                           Self.isAllowedMapsURL(u) { dest = u; break }
                    }
                    if dest == nil {
                        // Defensive: no usable link — build the daddr URL from
                        // whatever coordinates/name the result did carry.
                        var daddr: String?
                        if let lat = obj["lat"] as? Double, let lng = obj["lng"] as? Double {
                            daddr = "\(lat),\(lng)"
                        } else if let q = (obj["name"] as? String)?
                            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed), !q.isEmpty {
                            daddr = q
                        }
                        if let d = daddr { dest = URL(string: "https://maps.apple.com/?daddr=\(d)&dirflg=d") }
                    }
                    if let url = dest {
                        Task { @MainActor in
                            transcript.append(Line(text: "🧭 Navigating to \(label) — opening Apple Maps", fromHer: true))
                            status = "Navigating to \(label)…"
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                            UIApplication.shared.open(url)
                        }
                    } else {
                        Task { @MainActor in
                            transcript.append(Line(text: "🧭 Couldn't start navigation — no destination in the result", fromHer: true))
                        }
                    }
                }
            }
        }
    }

    /// Navigation results may only open Apple Maps: the maps:// scheme, or an
    /// http(s) link whose host is maps.apple.com. Everything else is dropped.
    private static func isAllowedMapsURL(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "maps" { return true }
        if scheme == "http" || scheme == "https" {
            return url.host?.lowercased() == "maps.apple.com"
        }
        return false
    }

    // MARK: audio session + capture + playback

    private func startAudioSession() throws {
        // ONE session policy for every path (applySessionCategory) — this used
        // to duplicate the setCategory call, and duplicated policies are how
        // the loudspeaker went quiet twice. Runs on session start and every
        // audio-graph rebuild.
        try applySessionCategory(car: onCarRoute)
        applyPreferredInput()
        routeToSpeakerIfReceiver()
        refreshSealedEarRoute()
        logAudioState("session-start")
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

    /// Everything that decides loudness, in one beacon — the next "she's
    /// faint" report arrives with the actual state instead of a guess.
    /// sysVol is the load-bearing field: it reads the system slider of the
    /// ACTIVE volume domain, so it directly separates "call-volume ceiling"
    /// from "quiet stream" from "wrong route".
    private func logAudioState(_ why: String) {
        let s = AVAudioSession.sharedInstance()
        let outs = s.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: "+")
        let ins = s.currentRoute.inputs.map { $0.portType.rawValue }.joined(separator: "+")
        clientLog("audio-state",
            "\(why) route=\(outs) in=\(ins) mode=\(s.mode.rawValue) "
          + "sysVol=\(String(format: "%.2f", s.outputVolume)) "
          + "loudspeaker=\(loudspeaker) speakerOn=\(speakerOn) "
          + "playerVol=\(player.volume) mixVol=\(audioEngine.mainMixerNode.outputVolume) "
          + "engineRunning=\(audioEngine.isRunning) pending=\(pendingBuffers) "
          + "sealed=\(sealedEarRoute)")
    }

    /// Idempotent: builds the audio graph exactly once; later calls just make
    /// sure the engine is running.
    private func ensureAudio() throws {
        if audioReady {
            if !audioEngine.isRunning { try audioEngine.start() }
            return
        }
        try startAudioSession()

        let input = audioEngine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        // While another app owns the audio session (an interruption in
        // progress, e.g. Spotify mid-handoff) the input node can report a dead
        // 0 Hz / 0-channel format — and installTap with that format is an
        // NSException crash `try?` can't catch. Throw a real error instead:
        // callers treat it as "audio not available yet", and the
        // interruption-ended / route-change handlers retry with a live format.
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw NSError(domain: "ScarletAudio", code: 1, userInfo:
                [NSLocalizedDescriptionKey: "Input format unavailable — audio session held elsewhere"])
        }
        // The ENGINE decides the wire rate: ElevenLabs listens at 16 kHz,
        // OpenAI Realtime at 24 kHz. Captured once here; an engine switch
        // stopAudio()s so the graph re-installs at the new rate.
        let capRate = captureRate
        let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: capRate,
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
        if player.engine == nil { audioEngine.attach(player) }
        // Player speaks standard Float32 — mixer connections in exotic formats
        // are exactly the kind of thing AVAudioEngine throws exceptions over.
        playFormat = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 1)
        audioEngine.connect(player, to: audioEngine.mainMixerNode, format: playFormat)

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
                    let ratio = inRate / capRate
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
                let ratio = capRate / inRate
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
                // Live "I hear you" cue: real speech energy while she listens
                // flips the status instantly — sub-second visible proof his
                // voice is reaching her, long before the server's transcript.
                // Only ever swaps between these two exact strings, so it can
                // never stomp a richer status (tool acks, reconnects, …).
                if self.micOn, self.state == .listening {
                    if next > 0.30, self.status == "Listening…" {
                        self.status = "Hearing you…"
                    } else if next < 0.06, self.status == "Hearing you…" {
                        self.status = "Listening…"
                    }
                }
                // Half-duplex + state truth: stream only when the mic is
                // GENUINELY delivering to a live session (micStreaming folds
                // in mic, echo gate, and session state) — during .connecting
                // the old guard kept "sending" into a nil socket, inflating
                // the in-flight count until every buffer looked dropped.
                guard self.micStreaming else { return }
                // Backpressure: never queue unbounded audio into a slow socket.
                // 96 in-flight (~10s) rides out real network jitter — the old
                // 24 punched holes in the MIDDLE of his sentences on a slow
                // patch (19 drops in the 225 session = ~2s of his words gone),
                // which the server heard as garbled speech it couldn't answer.
                // A socket genuinely stalled longer than this is dead anyway —
                // the reply watchdog rebuilds it.
                guard self.audioSendsInFlight < 96 else {
                    self.droppedChunks += 1
                    return
                }
                self.sendAudio(data.base64EncodedString())
            }
        }
        audioEngine.prepare()
        try audioEngine.start()
        // Re-assert the WHOLE gain chain on every build — a rebuilt graph that
        // silently inherited a 0 player volume is a "she's faint/silent" bug.
        audioEngine.mainMixerNode.outputVolume = 1.0
        player.volume = speakerOn ? 1 : 0
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
        // Never rebuild while another app owns the session (`interrupted`):
        // ensureAudio would read a dead input format and fight the other app
        // for activation. `.ended` clears the flag and calls back here.
        // No `audioReady` requirement — a rebuild whose ensureAudio threw
        // leaves audio down but the call alive, and the next route change /
        // foreground retries through this same path (stopAudio() is already
        // a no-op when nothing is built).
        guard wantLive, !interrupted, !audioRebuilding else { return }
        audioRebuilding = true
        defer { audioRebuilding = false }
        stopAudio()
        try? ensureAudio()
        if audioReady, state == .listening, micOn { status = "Listening…" }
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
        audioEngine.disconnectNodeOutput(player)
        playFormat = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 1)
        audioEngine.connect(player, to: audioEngine.mainMixerNode, format: playFormat)
        // Same gain-chain re-assertion as ensureAudio — this path used to
        // rebuild the player leg without it.
        player.volume = speakerOn ? 1 : 0
        audioEngine.mainMixerNode.outputVolume = 1.0
    }

    private func playPCM(base64: String) {
        // Session stolen (Spotify started playing, a phone call, Siri): the
        // socket keeps streaming her audio, but the audio unit is torn down.
        // Drop the buffers — scheduling them would pile up pendingBuffers whose
        // completions never fire (echo gate stuck shut), and starting playback
        // would trap. Her words still arrive as transcript text.
        guard !interrupted else { return }
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
        if !audioEngine.isRunning { try? audioEngine.start() }
        // THE crash the "Spotify started mid-call" report traced to: if that
        // start FAILED (another app holds the session — `try?` swallows the
        // error), player.play() against a non-running engine raises
        // 'required condition is false: _engine->IsRunning()' — an NSException,
        // not a throw. Never drive the player unless the engine truly runs;
        // dropping the buffer degrades to text, which recovery undoes.
        guard audioEngine.isRunning else { return }
        if !player.isPlaying { player.play() }
        state = .speaking
        status = speakerOn ? "Scarlet is speaking…" : "Answering silently — read below"
        // The echo gate is about to close (her audio starts). If server-VAD is
        // mid-HIS-utterance right now — the race window between his speech
        // registering and her first buffer — the audio stream simply stops
        // from the server's view: VAD dangles, and the reopened gate later
        // commits a chopped tail that gets a wrong answer (2026-08-12 root
        // cause #1). Discard the fragment instead: he repeats naturally once
        // she finishes, which is honest half-duplex — garbage turns are not.
        if pendingBuffers == 0, serverHearsSpeech, !sealedEarRoute {
            serverHearsSpeech = false
            send(["type": "input_audio_buffer.clear"])
            clientLog("gate-close-clear", "discarded mid-utterance fragment at gate close")
        }
        pendingBuffers += 1
        // Her voice DUCKS the radio (2026-08-11 voice-only audit: both used
        // to play at full volume simultaneously); the last buffer's drain
        // restores the music.
        RadioPlayer.shared.duck(true)
        player.scheduleBuffer(buf) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // She's done only when the LAST queued buffer drains — the
                // first buffer's completion used to flip state mid-sentence.
                self.pendingBuffers = max(0, self.pendingBuffers - 1)
                self.drainedAudioFrames += Int(frames)   // audio he actually heard
                if self.pendingBuffers == 0 {
                    // Grace so the room's reverb tail can't reach the mic as a
                    // phantom user turn. 0.6s (was 0.35): loudspeaker now runs
                    // WITHOUT a voice-processing mode, so this client gate is
                    // the only echo protection — the wider tail is its price.
                    self.speechTailUntil = Date().addingTimeInterval(0.6)
                    RadioPlayer.shared.duck(false)
                    if self.state == .speaking {
                        self.state = .listening
                        if self.micOn { self.status = "Listening…" }
                    }
                }
            }
        }
    }

    private func flushPlayback() {
        // Tell the server how much he ACTUALLY heard before the cut (root
        // cause #4, "she gives different answers"): without truncate, her
        // context keeps every unplayed word as if spoken, and later replies
        // build on things that never reached his ears. 24kHz mono wire rate.
        if let itemId = currentAssistantItemId, pendingBuffers > 0 {
            let heardMs = max(0, drainedAudioFrames * 1000 / 24000)
            send(["type": "conversation.item.truncate",
                  "item_id": itemId, "content_index": 0, "audio_end_ms": heardMs])
            clientLog("truncate", "item=\(itemId) heard=\(heardMs)ms")
            currentAssistantItemId = nil
        }
        player.stop()
        pendingBuffers = 0
        speechTailUntil = Date.distantPast
        RadioPlayer.shared.duck(false)
        // Only her-speaking transitions back to listening. Forcing .listening
        // from ANY state let an interruption during a reconnect fake a live
        // session (nil socket, "Listening…" status) — or resurrect End-state
        // UI from idle.
        if state == .speaking {
            state = .listening
            if micOn { status = "Listening…" }
        }
    }

    private func stopAudio() {
        guard audioReady else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        // Clear the converter under the lock: the tap is removed, but a callback
        // already dispatched can still be running: snapshotting nil (or the still-
        // live old converter it captured) is safe; a torn read is not.
        os_unfair_lock_lock(audioStateLock)
        converter = nil
        os_unfair_lock_unlock(audioStateLock)
        player.stop()
        pendingBuffers = 0
        speechTailUntil = Date.distantPast
        audioEngine.stop()
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
                    // Mark the pipeline interrupted FIRST — from this instant no
                    // one may drive the dead audio unit (playPCM drops buffers,
                    // the observers stand down) — then pause the engine ourselves
                    // so its state matches reality. The call survives: socket,
                    // transcript, and reconnect logic are all untouched.
                    self.interrupted = true
                    self.flushPlayback()
                    // Stop the model's generation too — otherwise deltas keep
                    // streaming into the torn-down audio path and she "resumes"
                    // a half-heard answer when audio comes back.
                    if self.engine == .openai, self.responseActive {
                        self.send(["type": "response.cancel"])
                    }
                    self.audioEngine.pause()
                    if self.wantLive {
                        self.status = "Sound paused — another app is playing. Still here in text."
                    }
                case .ended:
                    // A call (Teams/phone) that grabbed the mic likely changed
                    // the input device/format; rebuild rather than restart the
                    // stale graph (a restart with a mismatched format crashes).
                    // We attempt the resume even without .shouldResume — a live
                    // conversation going permanently mute is worse than ducking
                    // whatever else was playing — and every step is guarded, so
                    // a session we can't reclaim leaves audio paused (the next
                    // route change retries), never crashed.
                    self.interrupted = false
                    // Only reclaim the mic for a LIVE session — an ended app
                    // re-grabbing .playAndRecord (orange mic dot) whenever a
                    // phone call finishes is a privacy-feel bug.
                    guard self.wantLive else { break }
                    try? self.startAudioSession()
                    self.rebuildAudioGraph()
                default: break
                }
            }
        }
        // The media server itself died and restarted (mediaserverd reset — rare,
        // but aggressive session handoffs can trigger it). Every audio object we
        // hold is orphaned; Apple's contract is to DISCARD the engine and player
        // and build fresh ones — driving the orphans traps. The config-change
        // observer below deliberately uses `object: nil` so it follows us to the
        // replacement engine (there is only ever one in this process).
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.interrupted = false
                os_unfair_lock_lock(self.audioStateLock)
                self.converter = nil
                os_unfair_lock_unlock(self.audioStateLock)
                self.pendingBuffers = 0
                self.speechTailUntil = Date.distantPast
                self.audioEngine = AVAudioEngine()
                self.player = AVAudioPlayerNode()
                self.player.volume = self.speakerOn ? 1 : 0
                self.audioReady = false
                if self.wantLive { self.rebuildAudioGraph() }
            }
        }
        // The audio engine's I/O format changed (device swap, sample-rate
        // renegotiation, an interface or headphones coming/going). Rebuild the
        // capture graph on the NEW format — the single most important guard
        // against the continuous Mac "quit unexpectedly" crashes.
        // `object: nil`, NOT `object: engine`: a media-services reset replaces
        // the engine instance, and an observer bound to the old one would go
        // deaf forever. There is exactly one engine in this process, so nil is
        // unambiguous. rebuildAudioGraph itself refuses to run mid-interruption.
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name.AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.rebuildAudioGraph() }
        }
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                // Never poke the engine while another app owns the session —
                // start() would fail (or worse) and we'd be fighting Spotify
                // for the hardware. `.ended` is the resume signal, not this.
                if self.wantLive, !self.interrupted {
                    if !self.audioReady {
                        // Audio stayed down after a failed recovery (dead input
                        // format at .ended) — fresh hardware truth, try again.
                        self.rebuildAudioGraph()
                    } else if !self.audioEngine.isRunning {
                        try? self.audioEngine.start()
                    }
                    self.routeToSpeakerIfReceiver()
                    // Re-apply the full session policy only when it is
                    // actually STALE (mode drifted or car-ness flipped).
                    // Unconditionally re-applying on every route change
                    // (this morning's first cut) re-triggered notifications
                    // through the port override and stuttered the audio.
                    let s = AVAudioSession.sharedInstance()
                    if s.mode != self.sessionMode(car: self.onCarRoute)
                        || self.onCarRoute != self.lastAppliedCar {
                        self.applyOutputRoute()
                    }
                    self.refreshSealedEarRoute()
                    self.logAudioState("route-change")
                }
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
            Task { @MainActor in
                guard let self else { return }
                self.endBackgroundAssertion()
                // The socket often dies while backgrounded with no callback —
                // probe it NOW so the first thing he types on return doesn't
                // fall into a corpse.
                self.pingNow()
                // If audio died while we were away (an interruption whose
                // .ended never reached us, or a failed recovery), coming back
                // to the foreground is the moment to reclaim it.
                if self.wantLive, !self.audioReady {
                    self.interrupted = false
                    try? self.startAudioSession()
                    self.rebuildAudioGraph()
                }
                // SELF-HEAL (Ido 2026-08-11): a session that GAVE UP (reconnects
                // exhausted on dead hotel Wi-Fi, a failed mint) left him talking
                // to a dead app unless he noticed the small status line. If he
                // didn't end it himself, opening the app IS the intent to talk —
                // bring her back automatically.
                if !self.wantLive, !self.endedByUser, self.hasAutoStarted,
                   self.state == .idle {
                    self.start(token: TokenStore.token ?? "")
                }
            }
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
