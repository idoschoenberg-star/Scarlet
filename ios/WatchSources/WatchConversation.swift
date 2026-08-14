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
    // Audio-flow accounting (2026-08-12, "green mic but she never answers"):
    // frames actually sent + the loudest sample seen. peak≈0 with frames>0
    // means the mic is delivering SILENCE (permission / hardware), while
    // frames==0 means the gate/converter never let audio out — two different
    // bugs the wrist can't distinguish without these numbers.
    private var frames = 0
    private var peak: Int16 = 0
    // Raw-tap accounting (2026-08-12, "frames=58 peak=0"): `taps`/`rawPeak`
    // are measured on the UNCONVERTED buffer before the gate — so the beacon
    // can tell "mic delivers silence" (rawPeak≈0) from "converter zeroes it"
    // (rawPeak>0, peak=0) from "gate never opened" (taps>0, frames=0).
    private var taps = 0
    private var rawPeak: Float = 0
    // Deaf-session ledger (2026-08-13, QA harness runs 8/12/14/15/16/18):
    // cumulative seconds of REAL SPEECH that passed the OPEN gate — audio the
    // server must have heard. 1500 on the int16 wire scale (~5% full scale):
    // the beacons put observed real speech at peak=29822 and silence under
    // 300, so 1500 sits 5× above the noise floor yet 20× below an utterance —
    // breath and room rumble never accumulate, his voice always does. Zeroed
    // by every server input event and every connect(); the health tick reads
    // it as evidence against a server-side ear that emits nothing.
    static let realSpeechPeak: Int16 = 1500
    private var loudSpeech: Double = 0
    func set(converter c: AVAudioConverter?) { lock.lock(); converter = c; lock.unlock() }
    func set(gate g: Bool) { lock.lock(); gate = g; lock.unlock() }
    func note(peak p: Int16, frameSeconds: Double) {
        lock.lock()
        frames += 1
        if p > peak { peak = p }
        if p > Self.realSpeechPeak { loudSpeech += frameSeconds }
        lock.unlock()
    }
    func loudSpeechSeconds() -> Double { lock.lock(); defer { lock.unlock() }; return loudSpeech }
    func resetLoudSpeech() { lock.lock(); loudSpeech = 0; lock.unlock() }
    func note(raw p: Float) { lock.lock(); taps += 1; if p > rawPeak { rawPeak = p }; lock.unlock() }
    func audioStats() -> (frames: Int, peak: Int16, taps: Int, rawPeak: Float) {
        lock.lock(); defer { lock.unlock() }
        return (frames, peak, taps, rawPeak)
    }
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
    /// Explicit continuous-mode mute (2026-08-13): response.done auto re-arms
    /// the mic so a conversation stays a conversation — but that re-arm was
    /// silently overriding a deliberate mute tap seconds later. Set ONLY by
    /// the continuous-mode mute tap; cleared by start() and any orb re-arm.
    /// While true, response.done leaves the mic alone.
    private var userMuted = false

    var mode: Mode {
        get { Mode(rawValue: UserDefaults.standard.string(forKey: "watch.mode") ?? "") ?? .tapToTalk }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "watch.mode") }
    }

    // MARK: - session plumbing

    private var ws: URLSessionWebSocketTask?
    /// WATCH NETWORKING IS NOT PHONE NETWORKING (2026-08-12, "Reconnecting…"
    /// loop on the wrist): at wrist-raise the transport (BT-to-phone / Wi-Fi /
    /// LTE) is often still coming up, and a default session fails INSTANTLY —
    /// each fast failure burned one of the few reconnect attempts and the app
    /// died in ~15s without ever having had a network path. Both sessions now
    /// WAIT for connectivity instead of failing on a not-yet-ready link.
    /// resourceTimeout applies to the WHOLE task lifetime — right for the
    /// quick mint POST, FATAL for the WebSocket (2026-08-12, build 245: the
    /// 25s cap CANCELLED the live socket every ~25s — beacons showed -999
    /// "cancelled" on a metronome — so she connected, then died mid-turn
    /// before ever answering). The socket session waits for connectivity but
    /// lives as long as the call does.
    private static func patientSession(resourceTimeout: TimeInterval?) -> URLSession {
        let c = URLSessionConfiguration.default
        c.waitsForConnectivity = true
        if let t = resourceTimeout { c.timeoutIntervalForResource = t }
        return URLSession(configuration: c)
    }
    private let wsSession = WatchConversation.patientSession(resourceTimeout: nil)
    /// 40s, not 25 (2026-08-13): the server mint can add whole seconds under
    /// cold start, and this budget also absorbs waitsForConnectivity's radio
    /// wake — a tighter cap cancelled legitimate mints on a slow LTE wake and
    /// burned a reconnect attempt on a request that was about to succeed.
    private let mintSession = WatchConversation.patientSession(resourceTimeout: 40)
    /// Tool calls ride the same flaky wrist transport as the mint — a default
    /// session fails instantly on a link that is still coming up, and she then
    /// told him the DATA didn't exist. 30s: tools may legitimately be slow.
    private let toolSession = WatchConversation.patientSession(resourceTimeout: 30)
    private var wantLive = false
    private var endedByUser = false
    private var reconnectAttempts = 0
    private var reconnectTask: Task<Void, Never>?
    private var handledToolCalls = Set<String>()
    private var responseActive = false
    private var needsResponseAfterDone = false
    // The always-answer net, ported from the phone: a wrist socket can die
    // WITHOUT the receive callback ever firing (NAT timeout while the screen
    // is down) — the app then sits in .listening against a corpse and his
    // question vanishes into it. Three guards close it: a reply watchdog armed
    // on every closed turn, a transport ping loop that detects the corpse
    // even while nobody is talking, and checked completions on every
    // conversation-level send.
    private var replyWatchdog: Task<Void, Never>?
    private let replyWatchdogSeconds: UInt64 = 25
    private var lastSpeechStoppedAt = Date.distantPast
    private var lastResponseCreatedAt = Date.distantPast
    private var livenessTask: Task<Void, Never>?
    /// One free retry for a failed/incomplete response: the spoken turn is
    /// still in the conversation, so a bare response.create recovers it.
    /// Reset on every response.created; single-shot so a server-side failure
    /// can't loop.
    private var failedResponseRetried = false
    /// When the transcript last grew — the replay-on-reconnect freshness test.
    private var lastLineAt = Date.distantPast
    /// A tool result whose delivery the socket may have eaten: held until a
    /// response covers it, re-injected as context on the rebuilt session so
    /// the answer still happens. One slot — the watch runs one tool at a time.
    private var pendingToolOutput: (name: String, output: String)?
    // Backpressure, phone-proven: when the transport stalls, continuous audio
    // sends queue inside the socket without bound until it collapses. Cap the
    // in-flight sends (~0.5s of audio at the 2048-frame tap); past it chunks
    // are DROPPED — server VAD tolerates gaps far better than a dead socket —
    // and the pressure is counted for the beacons.
    private var audioSendsInFlight = 0
    private var droppedChunks = 0
    // BLACK-HOLE DETECTION (2026-08-13, beacons: armed=true pending=0 with
    // frames AND dropped climbing 1:1 for 4+ minutes): a NAT-dead socket
    // ACCEPTS sends but completes none — audioSendsInFlight latches at the
    // cap and every later chunk is dropped, while the liveness ping stays
    // silent (sendPing's callback fires only on a pong OR a transport error;
    // a black hole produces neither) and the reply watchdog never arms (it
    // needs a server event). Three independent clocks convict the corpse:
    //  - pendingPongSince: an outstanding ping whose pong is 6s overdue;
    //  - oldestInFlightSince: an audio send whose completion is 8s overdue;
    //  - lastHealthFrames/Dropped + sendStallTicks: two consecutive health
    //    ticks in which ~every produced chunk died at the backpressure cap.
    // Any one of them → scheduleReconnect() (never just free the slots — the
    // socket is dead, only a rebuild answers him). All are bound to the
    // current socket and reset in connect() so a rebuilt session starts clean.
    private var pendingPongSince: Date?
    private weak var pendingPongTask: URLSessionWebSocketTask?
    private var oldestInFlightSince: Date?
    private var lastHealthFrames = 0
    private var lastHealthDropped = 0
    private var sendStallTicks = 0
    // DEAF-SERVER-EAR clock (2026-08-13, QA runs 8/12/14/15/16/18): every
    // guard above keys off SEND-side failure — but a session can be deaf on
    // the SERVER side with every send SUCCEEDING: socket open, chunks ACKed,
    // yet zero input_audio_buffer.*/transcription events ever come back, so
    // no watchdog here ever fires and he talks into a live-looking corpse
    // forever. Stamped by ANY server input event (which also zeroes the tap's
    // loud-speech ledger); nil since connect() + real speech accumulated =
    // impossible in a healthy session → the health tick reconnects.
    private var lastServerInputEventAt: Date?
    // Deaf-conviction history (2026-08-13, pruned >120s): the FIRST deaf
    // conviction earns a zero-delay remint (server-brain failure — the
    // transport already proved itself by ACKing every send, so backoff buys
    // nothing but dead air); a SECOND conviction within 90s means the engine
    // itself is sick and demotes to the normal ladder, so a server that stays
    // deaf can't drive a hot mint/teardown loop. Deliberately NOT reset in
    // connect() — it must remember convictions ACROSS rebuilt sessions.
    private var recentDeafConvictions: [Date] = []
    // Duplicate-connect guard (2026-08-13): wrist-raise during an in-flight
    // connect used to reset state to .idle and start a SECOND connect — two
    // sockets raced, and the loser's failure path scheduled a reconnect that
    // tore down the winner. The epoch stamps every connect; a stale await or
    // stale failure path sees a newer epoch and stands down.
    private var connectEpoch = 0
    private var connectInFlight = false

    // MARK: - audio plumbing

    // `var`, not `let` (2026-08-13): a mediaServicesWereReset orphans every
    // audio object we hold — Apple's contract is to DISCARD the engine and
    // players and build fresh ones; driving the orphans traps. The reset
    // observer replaces all three.
    private var audioEngine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    /// WRIST-DOWN SURVIVAL (2026-08-12, beacons: watch-ws-fail POSIX 89
    /// "Operation canceled" 35s-2.5min after every connect — watchOS SUSPENDS
    /// the app when the screen dims, killing the socket mid-conversation;
    /// every session died after one or two rounds). Background-audio keeps a
    /// watch app alive only while audio is actively RENDERING, so this second
    /// player loops silence at zero volume for the whole session. It never
    /// touches pendingBuffers, so the echo gate is unaffected.
    private var keepAlivePlayer = AVAudioPlayerNode()
    private var keepAliveTask: Task<Void, Never>?
    private var audioReady = false
    /// True from interruption .began to .ended: watchOS has torn the audio
    /// unit down and NOTHING may drive it — playPCM drops buffers (her words
    /// still arrive as transcript), rebuilds and the keep-alive stand down.
    /// The phone learned this the hard way ("Spotify started mid-call").
    private var interrupted = false
    private var observersInstalled = false
    private let tapState = TapState()
    private var playFormat: AVAudioFormat?
    private let wireRate: Double = 24000
    /// Echo gate: while her audio is queued/playing, mic frames are dropped so
    /// the watch speaker can't feed her own voice back into the turn.
    private var pendingBuffers = 0
    private var speechTailUntil = Date.distantPast
    /// When all currently queued playback MUST have finished (sum of buffer
    /// durations). The health tick uses it to break a wedged gate — see the
    /// playPCM comment (build-252 one-round silent death).
    private var playbackDeadline = Date.distantPast
    private var healthTask: Task<Void, Never>?

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
        userMuted = false
        wantLive = true
        state = .connecting
        status = "Waking her up…"
        // EXPLICIT mic permission (2026-08-12, "green mic but she never
        // answers"): watchOS permission is separate from the iPhone's, and
        // nothing here ever requested it — without the grant the tap can
        // deliver pure silence, which looks exactly like listening. Ask
        // first (instant no-op once granted), fail loudly on denial.
        AVAudioApplication.requestRecordPermission { granted in
            Task { @MainActor in
                guard granted else {
                    self.beacon("watch-mic-denied", "")
                    self.status = "Allow the microphone in Settings → Privacy"
                    self.state = .idle; self.wantLive = false
                    return
                }
                await self.connect(token: token)
            }
        }
    }

    func end() {
        endedByUser = true
        wantLive = false
        reconnectTask?.cancel(); reconnectTask = nil
        replyWatchdog?.cancel(); replyWatchdog = nil
        livenessTask?.cancel(); livenessTask = nil
        pendingToolOutput = nil
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

    /// The orb tap. Idle → start a session. While she SPEAKS → stop her (the
    /// phone's tap-to-interrupt, Ido 2026-08-11: an urgent question never
    /// waits out a long story). Live in tapToTalk → ARM, idempotently. Live
    /// in continuous → toggle a mute.
    func orbTapped() {
        switch state {
        case .idle:
            start()
        case .connecting:
            break
        default:
            // STOP-HER first (2026-08-13): while her audio is queued/playing
            // or a response is generating, the tap is the stop button —
            // mirroring the phone's stopSpeaking. Cancel the generation,
            // flush playback, reopen the mic. Without this, a tap mid-answer
            // in tapToTalk DISARMED the mic — the opposite of his intent.
            if state == .speaking || pendingBuffers > 0 || responseActive {
                if responseActive { send(["type": "response.cancel"]) }
                player.stop()   // fires completions; decrements are clamped at 0
                pendingBuffers = 0
                speechTailUntil = .distantPast
                playbackDeadline = .distantPast
                micArmed = true
                userMuted = false
                state = .listening
                status = "Listening…"
                syncGate()
                return
            }
            if mode == .tapToTalk {
                // ARM, never toggle (2026-08-13): response.done already
                // re-arms the mic, so a "ritual" tap before speaking used to
                // MUTE an armed mic and his next words fell on the floor.
                // Arming is idempotent; only End or a continuous-mode mute
                // tap silences her ear.
                micArmed = true
                userMuted = false
                status = "Listening…"
            } else {
                micArmed.toggle()
                // Track the explicit mute so response.done's auto re-arm
                // can't silently override a deliberate "stop listening".
                userMuted = !micArmed
                status = micArmed ? "Listening…" : "Mic muted — tap to unmute"
            }
            syncGate()
        }
    }

    /// Wrist-raise / app foreground: a session that died while the app was
    /// suspended self-heals here — unless Ido explicitly ended it. A socket
    /// that LOOKS live gets probed instead of trusted: backgrounded sockets
    /// die without any callback ever firing, and returning early on ws != nil
    /// left him talking into the corpse until the next turn timed out.
    func appBecameActive() {
        // SELF-HEAL, mirroring the phone (2026-08-13): a session that gave up
        // (mint dead, audio failed mid-reconnect) dropped wantLive — and the
        // wrist then stayed dark until a manual tap he had no reason to make.
        // If he didn't end it himself, raising the wrist IS the intent to
        // talk — bring her back automatically.
        if !wantLive, !endedByUser, state == .idle {
            start()
            return
        }
        guard wantLive, !endedByUser else { return }
        // Audio died while we were away (an interruption whose .ended never
        // reached a suspended app): coming to the foreground is the moment to
        // reclaim it — re-ensure instead of talking into a dead engine.
        if interrupted {
            interrupted = false
            audioReady = false
            Task { @MainActor in
                try? await self.ensureAudio()
                self.syncGate()
            }
        }
        if ws != nil {
            pingNow()
            return
        }
        // A connect is ALREADY in flight (mint POST awaiting): restarting it
        // here spawned a second racing socket whose loser tore down the
        // winner (2026-08-13). It has its own timeout budget — let it finish.
        if connectInFlight { return }
        // No socket: whatever the ladder (or its 60s long tail) was waiting
        // on, wrist-raise is intent NOW — restart from attempt zero rather
        // than making him stare at a backoff timer.
        reconnectTask?.cancel(); reconnectTask = nil
        state = .idle
        start()
    }

    // MARK: - connect

    private func connect(token: String) async {
        // Stamp this attempt: any await below is a window where a NEWER
        // connect can start (wrist-raise, a watchdog) — the stale attempt
        // must abandon, never schedule a reconnect that kills the winner.
        connectEpoch += 1
        let epoch = connectEpoch
        connectInFlight = true
        defer { if connectEpoch == epoch { connectInFlight = false } }
        do {
            var req = URLRequest(url: AppConfig.realtimeURL)
            req.httpMethod = "POST"
            req.setValue(token, forHTTPHeaderField: "x-scarlet-token")
            let (data, resp) = try await mintSession.data(for: req)
            guard connectEpoch == epoch else { return }
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
                beacon("watch-mint-fail", "http=\(httpStatus) attempt=\(reconnectAttempts)")
                if wantLive { scheduleReconnect() }
                return
            }
            guard wantLive else { return }
            do { try await ensureAudio() } catch {
                beacon("watch-audio-fail", String(describing: error).prefix(120).description + " " + routeSummary())
                guard connectEpoch == epoch else { return }
                // A RECONNECT's audio failure is transient territory — the
                // route is mid-handoff, the session mid-wake — and audio
                // often recovers seconds later. Going permanently idle here
                // (the old branch) meant a 1-second hiccup ended a live
                // conversation for good. Keep the want and retry; permanent
                // idle is reserved for first-start failure and explicit mic
                // permission denial (handled in start()).
                if reconnectAttempts > 0 {
                    status = "Mic waking — retrying…"
                    scheduleReconnect()
                } else {
                    status = "Mic unavailable — try again"
                    state = .idle; wantLive = false
                }
                return
            }
            guard connectEpoch == epoch, wantLive else { return }
            // Route truth at session start: prove which ports the session
            // actually holds BEFORE any audio flows (next build's logs read
            // the verdict directly — in=[NONE] or hwIn=0 means dead input).
            beacon("watch-route", routeSummary())
            var wsReq = URLRequest(url: url)
            wsReq.setValue("Bearer " + secret, forHTTPHeaderField: "Authorization")
            let task = wsSession.webSocketTask(with: wsReq)
            ws = task
            task.resume()
            listen(task)
            reconnectAttempts = 0
            handledToolCalls.removeAll()
            pinnedLanguage = nil   // fresh session — re-pin from his first words
            responseActive = false
            needsResponseAfterDone = false
            failedResponseRetried = false
            // Fresh socket, fresh accounting — stale in-flight counts from the
            // previous socket's corpse would trip the backpressure cap forever,
            // and stale black-hole clocks would convict the NEW socket for the
            // old one's silence.
            audioSendsInFlight = 0
            oldestInFlightSince = nil
            pendingPongSince = nil
            pendingPongTask = nil
            sendStallTicks = 0
            lastHealthFrames = tapState.audioStats().frames
            lastHealthDropped = droppedChunks
            // A rebuilt session's EAR starts unproven: speech the OLD socket
            // never acknowledged must not convict the new one seconds after
            // it opens.
            lastServerInputEventAt = nil
            tapState.resetLoudSpeech()
            state = .listening
            beacon("watch-connected", "attempt=\(reconnectAttempts)")
            startLivenessPings()
            // Audio-flow verdict 8s in: did real sound leave the wrist?
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard let self, self.ws != nil else { return }
                let stats = self.tapState.audioStats()
                self.beacon("watch-audio",
                            "frames=\(stats.frames) peak=\(stats.peak) taps=\(stats.taps) "
                            + "rawPeak=\(String(format: "%.4f", stats.rawPeak)) "
                            + "armed=\(self.micArmed) mode=\(self.mode.rawValue) "
                            + self.routeSummary())
            }
            // Session health tick (build-252 "one round then silent death"):
            // every 10s, break a wedged echo gate — pendingBuffers stuck > 0
            // past the moment all queued audio must have finished means a
            // buffer completion was dropped; without this the mic stays shut
            // forever while the session looks alive. Every third tick also
            // beacons live state so any future wrist death names itself.
            healthTask?.cancel()
            healthTask = Task { @MainActor [weak self] in
                var tick = 0
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    guard let self, self.ws != nil, !Task.isCancelled else { return }
                    tick += 1
                    // BLACK-HOLE GUARDS (2026-08-13, the 4-minute deaf spell):
                    // a NAT-dead socket produces NO callback anywhere — not on
                    // sendPing, not on send completions, not on receive — so
                    // every event-driven watchdog slept through it. These three
                    // clocks are checked on wall time instead; any conviction
                    // reconnects (never just frees slots — the socket is dead).
                    // (1) A ping is outstanding and its pong is 6s overdue.
                    if let since = self.pendingPongSince, self.pendingPongTask === self.ws,
                       Date().timeIntervalSince(since) > 6 {
                        self.beacon("watch-pong-timeout",
                                    "no pong for \(Int(Date().timeIntervalSince(since)))s")
                        self.scheduleReconnect()
                        continue   // ws is nil now; next pass exits the loop
                    }
                    // (2) An audio send's completion is 8s overdue — the exact
                    //    latched-at-the-cap geometry the beacons convicted.
                    if self.audioSendsInFlight > 0, let t = self.oldestInFlightSince,
                       Date().timeIntervalSince(t) > 8 {
                        self.beacon("watch-send-timeout",
                                    "inflight=\(self.audioSendsInFlight) age=\(Int(Date().timeIntervalSince(t)))s")
                        self.scheduleReconnect()
                        continue
                    }
                    // (3) The gate is open but ~every chunk this tick died at
                    //    the backpressure cap — twice in a row is a stall, not
                    //    a blip. (>20 frames/tick ≈ real audio flowing.)
                    let stats = self.tapState.audioStats()
                    let dFrames = stats.frames - self.lastHealthFrames
                    let dDropped = self.droppedChunks - self.lastHealthDropped
                    self.lastHealthFrames = stats.frames
                    self.lastHealthDropped = self.droppedChunks
                    if self.micArmed, self.wantLive, dFrames > 20,
                       Double(dDropped) >= 0.9 * Double(dFrames) {
                        self.sendStallTicks += 1
                    } else {
                        self.sendStallTicks = 0
                    }
                    if self.sendStallTicks >= 2 {
                        self.sendStallTicks = 0
                        self.beacon("watch-sends-stalled", "dFrames=\(dFrames) dDropped=\(dDropped)")
                        self.scheduleReconnect()
                        continue
                    }
                    // (4) DEAF SERVER EAR (QA runs 8/12/14/15/16/18): none of
                    //    the guards above can fire because every send SUCCEEDS
                    //    — yet the server emits no input_audio_buffer.* or
                    //    transcription event at all. Server VAD normally ACKs
                    //    speech within ~1s, so >4s of voiced frames through an
                    //    OPEN gate with no server input event in 15s (or ever
                    //    on this socket) is solidly abnormal — and on the
                    //    wrist every second of dead air is expensive. Only a
                    //    rebuild restores the ear.
                    let loud = self.tapState.loudSpeechSeconds()
                    if self.micArmed, self.wantLive, loud > 4,
                       self.lastServerInputEventAt.map({ Date().timeIntervalSince($0) > 15 }) ?? true {
                        self.tapState.resetLoudSpeech()
                        // FAST CUTOVER (2026-08-13): a deaf session is a
                        // server-BRAIN failure, not a transport failure — the
                        // ladder's delays help nothing, so the first
                        // conviction remints from attempt zero at ZERO delay;
                        // connect()'s replay then re-asks his unanswered
                        // sentence on the fresh session. A SECOND conviction
                        // within 90s demotes to the honest ladder instead of
                        // remint-looping hot. (The phone can fall cross-vendor
                        // to ElevenLabs; the watch has one engine — a
                        // cross-vendor fallback here is future work.)
                        self.recentDeafConvictions.removeAll { Date().timeIntervalSince($0) > 120 }
                        let fastPath = !self.recentDeafConvictions.contains { Date().timeIntervalSince($0) < 90 }
                        self.recentDeafConvictions.append(Date())
                        self.beacon("watch-deaf-session",
                                    "loud=\(String(format: "%.1f", loud))s peak=\(stats.peak) "
                                    + "path=\(fastPath ? "fast" : "ladder") serverInput="
                                    + (self.lastServerInputEventAt.map { "\(Int(Date().timeIntervalSince($0)))s-ago" } ?? "never"))
                        if fastPath {
                            self.reconnectAttempts = 0
                            self.scheduleReconnect(immediate: true)
                        } else {
                            self.scheduleReconnect()
                            // After the call: scheduleReconnect writes its own
                            // status; a repeat deaf spell deserves the truth.
                            self.status = "Voice engine unstable — retrying…"
                        }
                        continue
                    }
                    if self.pendingBuffers > 0, Date() > self.playbackDeadline.addingTimeInterval(3) {
                        self.beacon("watch-gate-stuck",
                                    "pending=\(self.pendingBuffers) — force-cleared, mic reopened")
                        self.pendingBuffers = 0
                        self.speechTailUntil = .distantPast
                        if self.state == .speaking { self.state = .listening; self.status = self.micArmed ? "Listening…" : "Tap to talk" }
                        self.syncGate()
                    }
                    if tick % 3 == 0 {
                        let stats = self.tapState.audioStats()
                        self.beacon("watch-health",
                                    "state=\(self.state) armed=\(self.micArmed) pending=\(self.pendingBuffers) "
                                    + "frames=\(stats.frames) peak=\(stats.peak) dropped=\(self.droppedChunks)")
                    }
                }
            }
            // Continuous mode listens from the first breath; tapToTalk waits
            // for the tap that arms the turn.
            micArmed = mode == .continuous
            status = micArmed ? "Listening…" : "Tap to talk"
            syncGate()
            sendContext("[FOCUS] Ido is on his Apple Watch (small screen, walking or running, possibly loud surroundings). Keep every answer SHORT — one to three spoken sentences — unless he explicitly asks for depth. All tools work normally.")
            // Replay only a LIVE thread: after the watch sat dead for hours,
            // "CONTINUE, do not greet" resurrected a long-finished topic at
            // the next wrist-raise. Ten minutes of silence means the thread is
            // over — start clean instead.
            if !transcript.isEmpty, Date().timeIntervalSince(lastLineAt) < 600 {
                var context = "[FOCUS] Connection renewed mid-conversation — CONTINUE, do not greet. Recent exchange:\n"
                    + transcript.suffix(4)
                        .map { ($0.fromHer ? "Scarlet: " : "Ido: ") + $0.text.prefix(160) }
                        .joined(separator: "\n")
                // THE LOST QUESTION (2026-08-13): every watchdog/ping/stall
                // reconnect lands here — and when the last transcript line is
                // HIS, the reply died with the old socket. A bare CONTINUE
                // left the model waiting politely for input it will never
                // get; name the debt explicitly and force the answer.
                let lastIsHis = transcript.last.map { !$0.fromHer } ?? false
                if lastIsHis, let q = transcript.last?.text {
                    context += "\nIdo's last words were: \"\(q.prefix(160))\" — his last question is still UNANSWERED; answer it now."
                }
                sendContext(context)
                // A tool result the old socket ate rides over: the rebuilt
                // session has no memory of the call, so the result arrives as
                // context and the create makes the answer finally happen.
                if let pending = pendingToolOutput {
                    pendingToolOutput = nil
                    sendContext("[TOOL RESULT for your earlier \(pending.name) call]: " + pending.output)
                    send(["type": "response.create"])
                } else if lastIsHis {
                    // Same defer-on-busy rule as everywhere: a create against
                    // an active response 400s and the answer is lost again.
                    if responseActive { needsResponseAfterDone = true } else { send(["type": "response.create"]) }
                }
            } else {
                transcript.removeAll()
                // Released even though the replay is skipped for staleness —
                // a held slot surviving here would re-inject a long-dead tool
                // result into some future session's first turn.
                pendingToolOutput = nil
            }
        } catch {
            beacon("watch-mint-error", String(describing: error).prefix(160).description)
            // A throw caused by a NEWER connect cancelling this one must not
            // schedule a reconnect — that would tear down the winner's socket
            // (the duplicate-connect race, 2026-08-13).
            guard connectEpoch == epoch else { return }
            if wantLive { scheduleReconnect() } else { state = .idle; status = "Tap to talk" }
        }
    }

    /// Fire-and-forget telemetry so a failing watch is DIAGNOSABLE from the
    /// server logs (2026-08-12: the reconnect loop was invisible — no way to
    /// tell a mint failure from a socket drop without the wrist in hand).
    private func beacon(_ kind: String, _ detail: String) {
        guard let base = URL(string: "\(AppConfig.apiBase)/app-api?v=2&op=clientlog") else { return }
        var req = URLRequest(url: base)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(TokenStore.token ?? "", forHTTPHeaderField: "x-scarlet-token")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["kind": kind, "detail": detail])
        mintSession.dataTask(with: req).resume()
    }

    /// `immediate`: the deaf-session fast cutover — the caller has already
    /// proven the transport healthy (every send ACKed), so the backoff delay
    /// would only buy dead air. Zero delay for THIS attempt only; the attempt
    /// still counts, so a mint that fails right after re-enters the ladder.
    private func scheduleReconnect(immediate: Bool = false) {
        // 6 attempts with the delay capped at 8s (~31s of patience) — with
        // waitsForConnectivity each attempt now genuinely waits for a link
        // instead of failing instantly on a transport that isn't up yet.
        guard wantLive else { return }
        guard let token = TokenStore.token else {
            status = "Sign in again"; state = .idle; wantLive = false
            return
        }
        // The rebuilt session starts clean: kill the corpse NOW so syncGate
        // closes the mic, a late completion can't act on the old socket, and
        // a watchdog armed against it can't fire mid-rebuild.
        ws?.cancel(with: .goingAway, reason: nil)
        ws = nil
        replyWatchdog?.cancel(); replyWatchdog = nil
        syncGate()
        if reconnectAttempts >= 6 {
            // Exhausted attempts must NOT go permanently dark (Ido: the watch
            // works continuously, in endless loops). The old branch dropped
            // wantLive and the wrist stayed dead until a manual tap he had no
            // reason to make. Hold the want, tell the truth on screen, and
            // re-enter the ladder every 60s — a network handoff that recovers
            // brings her back by itself.
            beacon("watch-gaveup", "attempts=\(reconnectAttempts) — long-tail retry in 60s")
            status = "Connection lost — retrying…"
            state = .connecting
            reconnectTask?.cancel()
            reconnectTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard let self, self.wantLive, !Task.isCancelled else { return }
                self.reconnectAttempts = 0
                self.scheduleReconnect()
            }
            return
        }
        let delay = immediate ? 0 : UInt64(min(8, pow(2, Double(reconnectAttempts)))) * 1_000_000_000
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

    // MARK: - always-answer net

    /// Armed when his turn closes (speech_stopped / committed); disarmed by
    /// her first sign of life (response.created, a finished transcript, a
    /// tool call). Total silence for the window means the session is stalled
    /// or the socket is a corpse — the context replay restores the thread on
    /// the rebuilt socket, so tearing it down is cheaper than dead air.
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
        guard wantLive, ws != nil else { return }
        beacon("watch-reply-stall", "no response events \(replyWatchdogSeconds)s after his turn")
        status = "Stalled — reconnecting…"
        scheduleReconnect()   // tears the socket down itself
    }

    /// Her first response event for the outstanding turn — the reply is
    /// coming, stand the watchdog down.
    private func noteSignsOfLife() {
        replyWatchdog?.cancel(); replyWatchdog = nil
    }

    /// Server-side proof the EAR works — any input_audio_buffer.* or input-
    /// transcription event. Stamps the deaf-session clock and zeroes the
    /// loud-speech ledger: acknowledged speech is not evidence of deafness.
    private func noteServerInputEvent() {
        lastServerInputEventAt = Date()
        tapState.resetLoudSpeech()
    }

    /// Repeating transport-level ping. WebSocket pings ride below the Realtime
    /// protocol, so they cost nothing in the conversation — but a socket the
    /// network silently killed fails the pong, which is the ONLY timely signal
    /// of a dead wrist link while nobody is talking. Single instance:
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

    /// One transport ping; a failed pong means the socket is a corpse →
    /// rebuild. Also called on wrist-raise, where a suspended socket has often
    /// died without any callback ever firing.
    ///
    /// PONG DEADLINE (2026-08-13, the 4-minute black hole): sendPing's
    /// callback fires only on a pong OR a transport error — a NAT-dead socket
    /// produces NEITHER, so this loop pinged the void forever while every
    /// audio chunk died at the backpressure cap. Timestamp the outstanding
    /// ping instead; the health tick convicts a pong 6s overdue. The
    /// timestamp is bound to THIS task so a reconnect can't inherit it.
    private func pingNow() {
        guard wantLive, let ws else { return }
        let task = ws   // bind the verdict to THIS socket, not whatever ws is later
        if pendingPongSince == nil {   // keep the OLDEST unanswered ping's clock
            pendingPongSince = Date()
            pendingPongTask = task
        }
        task.sendPing { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if error == nil {
                    // Pong arrived — the socket drains; stand the clock down.
                    if self.pendingPongTask === task {
                        self.pendingPongSince = nil
                        self.pendingPongTask = nil
                    }
                    return
                }
                guard self.wantLive, self.ws === task else { return }
                self.beacon("watch-ping-fail", String(describing: error).prefix(120).description)
                self.scheduleReconnect()
            }
        }
    }

    // MARK: - socket receive

    private func listen(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            Task { @MainActor in
                guard self.ws === task else { return }
                switch result {
                case .failure(let err):
                    self.ws = nil
                    self.beacon("watch-ws-fail", String(describing: err).prefix(160).description)
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
        let type = ev["type"] as? String ?? ""
        // Server-ear heartbeat: ANY input-side event (speech start/stop,
        // commit, transcription) is proof the server hears the wrist — stamp
        // the clock and forgive the accumulated loud-speech evidence. Matched
        // by prefix, not per-case, so a server-side event rename or addition
        // can't dodge the deaf-session detector.
        if type.hasPrefix("input_audio_buffer.") || type.contains("input_audio_transcription") {
            noteServerInputEvent()
        }
        switch type {
        case "response.created":
            responseActive = true
            // A new response reads the FULL conversation — every input that
            // landed before this moment is covered by it, so a surviving
            // deferral would only make her re-answer the same thing (the
            // build-225 double-answer bug). Same reason the held tool output
            // is released: a response now exists to carry it.
            needsResponseAfterDone = false
            lastResponseCreatedAt = Date()
            failedResponseRetried = false
            pendingToolOutput = nil
            noteSignsOfLife()
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
            let rstatus = ((ev["response"] as? [String: Any])?["status"] as? String) ?? "completed"
            if rstatus == "cancelled" {
                // Cancelled = Ido cut her off. Semantic VAD creates the
                // response for his NEW turn itself — a deferred create here
                // would race that one and re-fire input-less at ITS done: the
                // build-225 double-answer bug in a new coat. Drop it.
                needsResponseAfterDone = false
            }
            if rstatus != "completed" && rstatus != "cancelled" {
                // Failed/incomplete response: his committed audio is still in
                // the conversation — one bare response.create answers it
                // instead of going silent.
                beacon("watch-response-failed", rstatus)
                if !failedResponseRetried {
                    failedResponseRetried = true
                    send(["type": "response.create"])
                }
            }
            state = .listening
            // A conversation stays a conversation (Ido 2026-08-12: "I talk,
            // she answers, then when I talk again I don't get any answer") —
            // the old tap-per-turn design disarmed the mic at response.created
            // and never re-armed it, so every session died after one round.
            // Re-arm after every answer, exactly like the phone behaves; the
            // orb tap is the mute/stop, not a per-turn ritual. EXCEPT when he
            // explicitly muted (continuous-mode tap, 2026-08-13): the auto
            // re-arm was silently overriding his deliberate "stop listening"
            // one answer later.
            if wantLive, !endedByUser, !userMuted { micArmed = true }
            status = micArmed ? "Listening…" : (userMuted ? "Mic muted — tap to unmute" : "Tap to talk")
            syncGate()
            if needsResponseAfterDone {
                needsResponseAfterDone = false
                send(["type": "response.create"])
            }
        case "response.output_audio_transcript.done", "response.audio_transcript.done":
            noteSignsOfLife()
            if let text = (ev["transcript"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                appendLine(text, fromHer: true)
            }
        case "conversation.item.input_audio_transcription.completed":
            if let text = (ev["transcript"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                appendLine(text, fromHer: false)
                // Transcription is ASYNC and routinely lands AFTER the reply.
                // Arming here unconditionally tore the phone's sessions down
                // 25s after every quiet turn (the phantom-stall trap) — arm
                // only when no response has started since the speech ended.
                if lastResponseCreatedAt < lastSpeechStoppedAt { armReplyWatchdog() }
                pinLanguage(from: text)
            }
        case "input_audio_buffer.speech_started":
            state = .listening
            status = "Hearing you…"
        case "input_audio_buffer.speech_stopped":
            lastSpeechStoppedAt = Date()
            // A reply is now DUE — arm the stall net. Speech that landed while
            // a response was active is dropped by the server: defer a create
            // to its done instead of watching for a reply that was never
            // going to exist.
            if responseActive { needsResponseAfterDone = true } else { armReplyWatchdog() }
            status = "Thinking…"
        case "input_audio_buffer.committed":
            lastSpeechStoppedAt = Date()
            if responseActive { needsResponseAfterDone = true } else { armReplyWatchdog() }
            state = .thinking
            status = "Thinking…"
        case "response.function_call_arguments.done":
            let callId = ev["call_id"] as? String ?? ""
            guard !callId.isEmpty, !handledToolCalls.contains(callId) else { break }
            handledToolCalls.insert(callId)
            noteSignsOfLife()
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
                noteSignsOfLife()
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
        lastLineAt = Date()
        transcript.append(Line(text: text, fromHer: fromHer))
        if transcript.count > 30 { transcript.removeFirst(transcript.count - 30) }
    }

    // MARK: - tools

    private func runTool(name: String, callId: String, argsJSON: String) {
        let params = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any] ?? [:]
        status = "Working…"
        Task {
            // Workout tools are DEVICE-LOCAL: HKWorkoutSession only runs on
            // watchOS, so these five (start/status/pause/resume/end) never
            // touch the HTTP proxy — the wrist IS the executor. Everything
            // downstream (cap, output event, the one-active-response gate)
            // is identical to the proxied path.
            let out = WorkoutManager.toolNames.contains(name)
                ? await WorkoutManager.shared.run(tool: name, params: params)
                : await performToolHTTP(name: name, params: params)
            // The watch has less headroom than the phone — cap what rides back
            // into the model context so a fat inbox can't blow the session.
            let capped = out.count > 12000
                ? String(out.prefix(12000)) + "\n[TRUNCATED — tell Ido there is more and offer to continue]"
                : out
            // Held until a response covers it: if the socket eats this send,
            // connect() re-injects the result so the answer still happens.
            pendingToolOutput = (name, capped)
            send(["type": "conversation.item.create",
                  "item": ["type": "function_call_output", "call_id": callId,
                           "output": capped]])
            if responseActive { needsResponseAfterDone = true } else { send(["type": "response.create"]) }
            postToolCues(name: name, out: out)
        }
    }

    private func performToolHTTP(name: String, params: [String: Any]) async -> String {
        // A bare "tool failed" made her claim the DATA didn't exist — the
        // inbox looked empty because the wrist link hiccuped. Patient session,
        // retries, and on real failure a result string that names the truth.
        for attempt in 0...2 {
            if attempt > 0 {
                // PAUSE before retrying (2026-08-14, the 8:24 "can't fetch
                // the news" incident while traveling): back-to-back attempts
                // both die inside the SAME radio handoff. 1.5s then 3s lets
                // the wrist link finish its Wi-Fi↔cellular flip — worst case
                // adds ~4.5s before an honest failure, and turns most
                // one-off drops into an answer he never knew was retried.
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_500_000_000)
            }
            do {
                var req = URLRequest(url: AppConfig.toolURL(name))
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.setValue(TokenStore.token ?? "", forHTTPHeaderField: "x-scarlet-token")
                req.httpBody = try JSONSerialization.data(withJSONObject: params)
                let (data, resp) = try await toolSession.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<300).contains(code) {
                    return String(data: data, encoding: .utf8) ?? "{}"
                }
                beacon("watch-tool-http", "\(name) http=\(code) attempt=\(attempt)")
            } catch {
                beacon("watch-tool-http", "\(name) \(String(describing: error).prefix(120)) attempt=\(attempt)")
            }
        }
        return "{\"error\":\"network failed on the watch — tell him the lookup failed on the wrist connection and offer to retry\"}"
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

    /// Conversation-level send with a CHECKED completion. A discarded send
    /// error was the "answering silently" dead end: context items, tool
    /// outputs, and response.creates vanished into a corpse and nothing
    /// noticed. A failed send means the socket is dead — rebuild; the held
    /// tool output (if any) rides over via connect().
    private func send(_ obj: [String: Any]) {
        guard let ws,
              let data = try? JSONSerialization.data(withJSONObject: obj),
              let text = String(data: data, encoding: .utf8) else { return }
        ws.send(.string(text)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                guard let self, self.wantLive, self.ws === ws else { return }
                self.beacon("watch-send-fail", String(describing: error).prefix(120).description)
                self.scheduleReconnect()
            }
        }
    }

    /// Audio chunk send with in-flight accounting — the completion is the only
    /// truth about whether the socket is draining. A failed audio chunk is NOT
    /// a reconnect trigger (the ping loop and reply watchdog own that verdict);
    /// it only releases its slot.
    private func sendAudio(_ b64: String) {
        audioSendsInFlight += 1
        // Per-send deadline clock (2026-08-13 black hole): the count going
        // 0→1 starts it, returning to 0 clears it. On a live socket sends
        // complete in well under a second, so the count touches 0 constantly;
        // 8s with the FIRST send still unacknowledged means the completions
        // are never coming — the health tick reconnects on it.
        if audioSendsInFlight == 1 { oldestInFlightSince = Date() }
        guard let ws,
              let data = try? JSONSerialization.data(withJSONObject: ["type": "input_audio_buffer.append", "audio": b64]),
              let text = String(data: data, encoding: .utf8) else {
            audioSendsInFlight -= 1
            if audioSendsInFlight == 0 { oldestInFlightSince = nil }
            return
        }
        ws.send(.string(text)) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.audioSendsInFlight = max(0, self.audioSendsInFlight - 1)
                if self.audioSendsInFlight == 0 { self.oldestInFlightSince = nil }
            }
        }
    }

    private func sendContext(_ text: String) {
        send(["type": "conversation.item.create",
              "item": ["type": "message", "role": "user",
                       "content": [["type": "input_text", "text": text]]]])
    }

    // MARK: - language pinning (ported from the phone, 2026-08-13)
    //
    // The QA harness proved the mirror rule cannot be prompted into
    // reliability: the model answers English speech in Hebrew ~1 turn per
    // session, and after an explicit "עני בעברית" it REFUSES to switch back
    // ("I can only respond in Hebrew, as you requested" — run 23). The phone
    // self-corrects within one turn by pinning the reply language from each
    // completed input transcription; the watch never got that net, which is
    // where the sticky-wrong-language sessions lived. Detection mirrors the
    // phone exactly: Hebrew script → "he"; ARABIC script also → "he" (the
    // transcriber mis-writes his Hebrew in Arabic glyphs; Ido never speaks
    // Arabic); English needs two real ASCII words so a garbled scrap pins
    // nothing and the previous pin stands.
    private var pinnedLanguage: String?

    private func detectLanguage(_ text: String) -> String? {
        let scalars = text.unicodeScalars
        if scalars.contains(where: { (0x0590...0x05FF).contains($0.value) }) { return "he" }
        if scalars.contains(where: { (0x0600...0x06FF).contains($0.value) }) { return "he" }
        let asciiWords = text.split(whereSeparator: { !$0.isLetter })
            .filter { w in w.count >= 2 && w.allSatisfy { $0.isASCII } }
        if asciiWords.count >= 2 { return "en" }
        return nil
    }

    private func pinLanguage(from utterance: String) {
        guard let lang = detectLanguage(utterance), lang != pinnedLanguage else { return }
        pinnedLanguage = lang
        sendContext(lang == "he"
            ? "[LANGUAGE] עידו מדבר עכשיו עברית. ענה אך ורק בעברית עד שהוא עובר שפה. (פריטי חדשות עדיין נקראים בשפת המקור שלהם.)"
            : "[LANGUAGE] Ido is speaking ENGLISH right now. Reply ONLY in English until he switches languages. This supersedes ANY earlier language request. (News items are still read in their original language.)")
    }

    // MARK: - audio

    /// One-line route + format truth for beacons: the ports the session
    /// actually holds, the session sample rate, and the INPUT hardware format
    /// — the one that reads 0 Hz when the mic side of the route is dead.
    private func routeSummary() -> String {
        let s = AVAudioSession.sharedInstance()
        let ins = s.currentRoute.inputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: "+")
        let outs = s.currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: "+")
        let hw = audioEngine.inputNode.inputFormat(forBus: 0)
        return "in=[\(ins.isEmpty ? "NONE" : ins)] out=[\(outs.isEmpty ? "NONE" : outs)] "
             + "sr=\(Int(s.sampleRate)) hwIn=\(Int(hw.sampleRate))x\(hw.channelCount)"
    }

    private func ensureAudio() async throws {
        installAudioObservers()
        // Mid-interruption there is nothing to ensure — another app owns the
        // session and rebuildAudioGraph would silently stand down, leaving
        // audioReady=true over no graph. Throw instead: connect()'s reconnect
        // ladder retries, and .ended re-ensures the moment the session is ours.
        guard !interrupted else { throw NSError(domain: "ScarletWatchAudio", code: 3) }
        if audioReady {
            // Fast path is no longer a bare engine.start() (2026-08-13): after
            // a suspension/interruption the SESSION is often deactivated, and
            // starting the engine against it fails — the old path then threw,
            // and a reconnect's connect() went permanently idle over a
            // one-second hiccup. Re-activate first; on ANY fast-path failure
            // fall through to the full rebuild instead of throwing — fresh
            // hardware truth usually recovers what a bare start can't.
            do {
                try await activateAudioSession()
                if !audioEngine.isRunning { try audioEngine.start() }
                return
            } catch {
                beacon("watch-audio-fastpath", String(describing: error).prefix(120).description + " " + routeSummary())
                audioReady = false
            }
        }
        let session = AVAudioSession.sharedInstance()
        // Mode .default, NOT .voiceChat (2026-08-12, wrist streams pure
        // zeros — "frames=58 peak=0"): .voiceChat is a VoIP mode that
        // restricts allowable routes and engages voice-processing DSP; its
        // own documented side effect (.allowBluetooth / HFP) doesn't even
        // EXIST on watchOS, and voice-processed input is the classic way a
        // tap runs at full rate while delivering silence. Echo is already
        // handled client-side by the half-duplex gate (syncGate), the same
        // argument the phone makes for its loudspeaker .default path.
        // .allowBluetoothA2DP stays — output-only, keeps AirPods full-band.
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothA2DP])
        try await activateAudioSession()
        try rebuildAudioGraph()
        audioReady = true
    }

    /// watchOS activation is the ASYNC, watch-only API (WWDC19-716 /
    /// AVAudioSession.h): activation on the watch is "a relatively time
    /// consuming operation" and may need to bring a route up; the async
    /// form reports the real outcome instead of returning early success.
    private func activateAudioSession() async throws {
        let session = AVAudioSession.sharedInstance()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            session.activate(options: []) { activated, error in
                if activated { cont.resume() }
                else { cont.resume(throwing: error ?? NSError(domain: "ScarletWatchAudio", code: 2)) }
            }
        }
    }

    /// (Re)build the whole capture/playback graph on the CURRENT hardware
    /// formats. Split out of ensureAudio (2026-08-13) because route and
    /// engine-configuration changes must rebuild too: a format change under a
    /// LIVE tap is a hard native crash (the tap keeps handing the converter
    /// buffers in a format it no longer accepts), so the tap is removed and
    /// reinstalled with fresh inputFormat truth every time.
    private func rebuildAudioGraph() throws {
        // Never drive the audio unit while another app owns the session —
        // the interruption's .ended (or the next foreground) is the resume
        // signal, not whatever notification got us here.
        guard !interrupted else { return }
        audioEngine.stop()
        player.stop()   // completions fire → pendingBuffers drains naturally
        let input = audioEngine.inputNode
        // The HARDWARE side of the input node (2026-08-12): outputFormat(
        // forBus:) can report a healthy-looking default while the input
        // hardware is dead — exactly the geometry of a tap that "works" and
        // delivers zeros. inputFormat(forBus:) is the format that tells the
        // truth (0 Hz when the mic side never came up), and it's the format
        // Apple's watch recording code taps with.
        let inFormat = input.inputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            beacon("watch-audio-noinput", routeSummary())
            throw NSError(domain: "ScarletWatchAudio", code: 1)
        }
        let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: wireRate,
                                   channels: 1, interleaved: true)!
        tapState.set(converter: AVAudioConverter(from: inFormat, to: target))

        if player.engine == nil { audioEngine.attach(player) }
        playFormat = AVAudioFormat(standardFormatWithSampleRate: wireRate, channels: 1)
        audioEngine.connect(player, to: audioEngine.mainMixerNode, format: playFormat)
        if keepAlivePlayer.engine == nil { audioEngine.attach(keepAlivePlayer) }
        audioEngine.connect(keepAlivePlayer, to: audioEngine.mainMixerNode, format: playFormat)
        keepAlivePlayer.volume = 0   // renders (keeps the app alive), never heard

        input.removeTap(onBus: 0)
        let tapState = self.tapState
        let wire = wireRate   // captured by value — the tap never touches self's state
        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buffer, _ in
            // Audio thread: everything it reads comes from the lock-guarded
            // snapshot; the send hops to the main actor with plain Data.
            // RAW peak first — before gate and converter — so the beacon can
            // separate a silent mic from a silent converter from a shut gate.
            var rp: Float = 0
            if let f = buffer.floatChannelData?[0] {
                let n = Int(buffer.frameLength)
                var i = 0
                while i < n { let v = abs(f[i]); if v > rp { rp = v }; i += 32 }
            }
            tapState.note(raw: rp)
            let (converter, gate) = tapState.snapshot()
            guard gate, let converter,
                  let data = Self.convertToWire(buffer, converter: converter) else { return }
            // Cheap peak over the wire samples — the audio-flow beacon's raw
            // material. ~0 peak with frames flowing = the mic is silent.
            var p: Int16 = 0
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let s = raw.bindMemory(to: Int16.self)
                var i = 0
                while i < s.count { let v = s[i].magnitude; if Int16(clamping: v) > p { p = Int16(clamping: v) }; i += 32 }
            }
            // The gate guard above already passed, so this frame WAS offered
            // for send — its wire duration (int16 samples / 24 kHz) feeds the
            // deaf-session ledger when the peak says real speech. One Double
            // add under the existing lock; nothing new runs per frame.
            tapState.note(peak: p, frameSeconds: Double(data.count / 2) / wire)
            Task { @MainActor [weak self] in
                guard let self, self.ws != nil else { return }
                // Backpressure cap (~0.5s of audio): a socket that stopped
                // draining gets gaps, not an unbounded queue that collapses
                // the transport. Drops are counted into watch-health.
                guard self.audioSendsInFlight < 12 else {
                    self.droppedChunks += 1
                    return
                }
                self.sendAudio(data.base64EncodedString())
            }
        }
        try audioEngine.start()
        syncGate()
        startKeepAlive()
    }

    /// Installed ONCE, at the first ensureAudio. The phone learned each of
    /// these the hard way; the watch had inherited none of them (2026-08-13):
    /// an interruption discards every scheduled buffer WITHOUT firing its
    /// completion (echo gate wedged shut forever), a route/format change
    /// under a live tap is an uncatchable native crash, and a media-services
    /// reset orphans the engine objects outright. On a watch each of these
    /// also stops background audio — and stopped background audio means
    /// watchOS suspends the app and the socket dies with it.
    private func installAudioObservers() {
        guard !observersInstalled else { return }
        observersInstalled = true
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            Task { @MainActor in
                guard let self else { return }
                switch type {
                case .began:
                    // The audio unit is being torn down, discarding every
                    // scheduled buffer WITHOUT its completion — pendingBuffers
                    // would never decrement and the gate would stay shut while
                    // the session looked alive. Mark the pipeline dead FIRST
                    // (playPCM and the rebuilds check it), then zero the gate.
                    self.interrupted = true
                    self.player.stop()
                    // Pause ourselves so engine state matches reality — the
                    // system is tearing the unit down either way, and a
                    // half-torn engine that still claims isRunning would let
                    // the keep-alive loop schedule into the void.
                    self.audioEngine.pause()
                    self.pendingBuffers = 0
                    self.speechTailUntil = .distantPast
                    self.playbackDeadline = .distantPast
                    if self.state == .speaking { self.state = .listening }
                    self.syncGate()
                case .ended:
                    // The grabbing app may have changed the input format —
                    // full re-ensure (session activate + graph rebuild on
                    // fresh hardware truth), never a bare engine restart.
                    self.interrupted = false
                    guard self.wantLive else { break }
                    self.audioReady = false
                    do { try await self.ensureAudio() } catch {
                        self.beacon("watch-audio-reensure", String(describing: error).prefix(120).description)
                    }
                    self.syncGate()
                default: break
                }
            }
        }
        // Route or I/O-format change: rebuild on the NEW format. `object: nil`
        // deliberately — a media-services reset replaces the engine instance,
        // and an observer bound to the old one would go deaf forever.
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleAudioPathChange("route-change") }
        }
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name.AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleAudioPathChange("config-change") }
        }
        // mediaserverd died and restarted (rare, but aggressive session
        // handoffs trigger it): every audio object we hold is an orphan —
        // Apple's contract is to DISCARD the engine and players and build
        // fresh ones; driving the orphans traps. Full teardown, re-ensure.
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.interrupted = false
                self.keepAliveTask?.cancel(); self.keepAliveTask = nil
                self.tapState.set(converter: nil)
                self.tapState.set(gate: false)
                self.pendingBuffers = 0
                self.speechTailUntil = .distantPast
                self.playbackDeadline = .distantPast
                self.audioEngine = AVAudioEngine()
                self.player = AVAudioPlayerNode()
                self.keepAlivePlayer = AVAudioPlayerNode()
                self.audioReady = false
                guard self.wantLive else { return }
                do { try await self.ensureAudio() } catch {
                    self.beacon("watch-audio-reset-fail", String(describing: error).prefix(120).description)
                }
                self.syncGate()
            }
        }
    }

    /// The rebuild both change notifications funnel into. A failed rebuild
    /// drops audioReady so the next re-ensure (foreground, keep-alive
    /// escalation, interruption .ended) retries from the top instead of
    /// fast-pathing onto a broken graph.
    private func handleAudioPathChange(_ reason: String) {
        guard wantLive, !interrupted, audioReady else { return }
        do {
            try rebuildAudioGraph()
        } catch {
            beacon("watch-audio-rebuild-fail", reason + " " + String(describing: error).prefix(100).description + " " + routeSummary())
            audioReady = false
        }
        syncGate()
    }

    /// Loop 0.5s silent buffers on the muted keep-alive player so the audio
    /// engine renders CONTINUOUSLY — the condition for watchOS background
    /// audio to keep the app (and its WebSocket) alive through wrist-down.
    /// Scheduled two-ahead so a late tick can't leave a rendering gap.
    private func startKeepAlive() {
        keepAliveTask?.cancel()
        guard let fmt = playFormat,
              let silent = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(wireRate / 2)) else { return }
        silent.frameLength = AVAudioFrameCount(wireRate / 2)   // zero-filled by allocation
        keepAlivePlayer.scheduleBuffer(silent, completionHandler: nil)
        keepAlivePlayer.scheduleBuffer(silent, completionHandler: nil)
        if !keepAlivePlayer.isPlaying { keepAlivePlayer.play() }
        keepAliveTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 450_000_000)
                guard let self, self.audioReady, !Task.isCancelled else { return }
                if !self.audioEngine.isRunning, !self.interrupted {
                    // A stopped engine SILENTLY ends background audio →
                    // watchOS suspends the app → the socket dies (2026-08-13;
                    // the old loop just skipped the schedule and let it
                    // happen). Restart in place; if the engine won't start,
                    // escalate to a full re-ensure instead of going quiet.
                    try? self.audioEngine.start()
                    if !self.audioEngine.isRunning {
                        self.audioReady = false   // ends this loop; the rebuild starts a fresh one
                        Task { @MainActor in
                            try? await self.ensureAudio()
                            self.syncGate()
                        }
                        return
                    }
                }
                if self.audioEngine.isRunning {
                    self.keepAlivePlayer.scheduleBuffer(silent, completionHandler: nil)
                    if !self.keepAlivePlayer.isPlaying { self.keepAlivePlayer.play() }
                }
            }
        }
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
        // Session stolen (interruption in progress): the audio unit is torn
        // down — scheduling would pile up pendingBuffers whose completions
        // never fire (gate wedged shut). Drop the buffers; her words still
        // arrive as transcript text.
        guard !interrupted else { return }
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
        // THE crash the phone already guards against (2026-08-13, ported):
        // scheduleBuffer/play against a non-running engine raises 'required
        // condition is false: _engine->IsRunning()' — an NSException the
        // Swift try can't catch; the app just quits. Start it if it stopped;
        // if the start FAILS (another app holds the session — try? swallows
        // it), DROP the buffer before any bookkeeping, degrading to text.
        if !audioEngine.isRunning { try? audioEngine.start() }
        guard audioEngine.isRunning else { return }
        pendingBuffers += 1
        // Time-based failsafe bookkeeping (2026-08-12, build 252 "one round
        // then silent death"): the gate reopens on buffer COMPLETIONS, and a
        // completion that never fires (engine hiccup, route change mid-play)
        // wedges pendingBuffers > 0 forever — mic shut, session looks alive,
        // she never hears him again. Track when all queued audio MUST have
        // finished playing; the health tick force-clears a wedged gate.
        let dur = Double(frames) / wireRate
        playbackDeadline = max(playbackDeadline, Date()).addingTimeInterval(dur)
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
        playbackDeadline = .distantPast
        healthTask?.cancel(); healthTask = nil
        replyWatchdog?.cancel(); replyWatchdog = nil
        livenessTask?.cancel(); livenessTask = nil
        audioSendsInFlight = 0
        // The black-hole clocks and interruption mark die with the session —
        // a stale timestamp surviving into the next start() would convict a
        // brand-new socket for this one's silence.
        oldestInFlightSince = nil
        pendingPongSince = nil
        pendingPongTask = nil
        sendStallTicks = 0
        interrupted = false
        keepAliveTask?.cancel(); keepAliveTask = nil
        keepAlivePlayer.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
