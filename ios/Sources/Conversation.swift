import Foundation
import AVFoundation
import Network  // NWPathMonitor — preemptive reconnect on Wi-Fi ⇄ cellular handoff (CarPlay)
import CallKit // CXCallObserver — announce an incoming cellular call by voice
import Combine
import HealthKit // startWatchApp — voice-initiated workouts launch on the WATCH
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
    /// realtime-session. The ElevenLabs branch below is retained as the
    /// PARACHUTE: `engine` leaves .openai only via switchToElevenFallback
    /// (two deaf OpenAI sessions inside 90s — tier 2 of the failover
    /// ladder), and every fresh start() tries OpenAI first again.
    enum Engine: String { case eleven, openai }
    @Published private(set) var engine: Engine = .openai
    /// Set once a failover happened this session — prevents ping-ponging.
    /// Direction: eleven→openai only (the era ElevenLabs was primary). The
    /// tier-2 openai→eleven parachute is the OPPOSITE direction and has its
    /// own flag — elFallbackActive below — never this one.
    private var engineFellBack = false
    /// The tier-2 parachute is deployed: OpenAI proved deaf twice and this
    /// session is living on the ElevenLabs voice. One-way for the SESSION —
    /// while up, the eleven→openai failover paths must NOT bounce back to
    /// the engine that just proved deaf (they stop honestly via
    /// voiceUnavailableStop instead). A fresh start() clears it and tries
    /// OpenAI first again.
    private var elFallbackActive = false
    /// The way BACK off the parachute (Ido 2026-08-13: "think about the
    /// switching back… when the capability resumes"). While the fallback
    /// session is live, a 75s background probe POSTs the real mint check
    /// (realtime-session?check=1 — the server mints and DISCARDS an actual
    /// OpenAI session, so a 200 is proof the engine can START, not merely
    /// that the endpoint answers). Two consecutive greens arm this flag; the
    /// switch itself happens only at a quiet boundary — neither of them
    /// mid-utterance — checked from the existing 10s health tick
    /// (completeOpenAIRecoveryIfQuiet), so recovery never cuts a sentence.
    private var openAIRecovered = false
    private var elRecoveryProbeTask: Task<Void, Never>?
    /// Fallback-period epoch: bumped when the parachute deploys and on every
    /// teardown (end / voiceUnavailableStop / fresh start). The probe captures
    /// the value it was born with and re-checks it around every await — a
    /// stale probe from a PREVIOUS fallback period can never count a success
    /// into, or fire a switch on, a session it doesn't own.
    private var elFallbackEpoch = 0

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
    /// WHY the deferral exists. A cancelled response only invalidates a
    /// VAD-SPEECH deferral — semantic VAD creates the response for his new
    /// turn by itself, so the deferred create would just double-answer (the
    /// 225 bug). An ITEM-BACKED deferral (typed turn, tool output, system
    /// item) has NO VAD coming to answer it: dropping it on cancel left the
    /// item permanently unanswered — she went silent on a typed question the
    /// moment a barge-in cancelled the response it was queued behind.
    private enum DeferredResponseReason { case vadSpeech, itemBacked }
    private var deferredResponseReason: DeferredResponseReason = .vadSpeech
    /// The ONLY way to set needsResponseAfterDone: records why, and never
    /// downgrades a pending item-backed deferral to vad-speech — the stronger
    /// reason must survive so a cancel can't discard the item's answer.
    private func deferResponse(_ reason: DeferredResponseReason) {
        if !needsResponseAfterDone {
            deferredResponseReason = reason
        } else if reason == .itemBacked {
            deferredResponseReason = .itemBacked
        }
        needsResponseAfterDone = true
    }

    /// Schedule the client-driven response.create behind the patience window.
    /// Long utterances (≥6s of speech before the pause — dictation) get 2.2s
    /// of grace; short ones get 0.9s, close to semantic VAD's own pace. The
    /// watchdog arms only when the create is actually sent, so the stall net
    /// never counts the deliberate wait as a stall.
    private func schedulePatienceCreate() {
        pendingResponseCreate?.cancel()
        let utterance = lastSpeechStoppedAt.timeIntervalSince(lastSpeechStartedAt)
        let patience: TimeInterval = utterance >= 6 ? 2.2 : 0.9
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingResponseCreate = nil
            guard self.wantLive else { return }
            if self.responseActive {
                self.deferResponse(.vadSpeech)   // a reply started meanwhile — create after its done
            } else {
                self.awaitingReplyText = ""
                self.send(["type": "response.create"])
                self.armReplyWatchdog()
            }
        }
        pendingResponseCreate = work
        DispatchQueue.main.asyncAfter(deadline: .now() + patience, execute: work)
    }
    private var lastSpeechStoppedAt = Date.distantPast
    private var lastResponseCreatedAt = Date.distantPast
    /// THE PATIENCE WINDOW (2026-08-14, Ido: "she loses patience and just
    /// barges in" mid-dictation, and the truncated rest never registers).
    /// This build mints with ?defer=1 — the server's VAD still detects and
    /// commits his turns, but no longer auto-creates the reply. Instead,
    /// speech_stopped schedules this work item: 0.9s after a short utterance,
    /// 2.2s after a long one (dictation). If he RESUMES speaking inside the
    /// window, speech_started cancels it and his continuation streams into
    /// the same exchange — the mic never gated because she never spoke — and
    /// the eventual reply covers everything he said. Nothing is truncated.
    private var pendingResponseCreate: DispatchWorkItem?
    /// Server-VAD is mid-utterance: speech_started arrived, speech_stopped
    /// hasn't. If the echo gate closes the mic NOW (her audio starts playing),
    /// the server is left holding a chopped fragment with no end — semantic
    /// VAD dangles, and when the gate reopens the tail commits as a garbage
    /// turn that gets a wrong answer (2026-08-12 root-cause finding #1). The
    /// gate-close path uses this flag to discard the fragment instead.
    private var serverHearsSpeech = false
    /// When his CURRENT utterance began (input_audio_buffer.speech_started).
    /// The gate-close branch reads the AGE: a start under 0.5s old is the
    /// race window between his voice registering and her first buffer — a
    /// fragment, safe to discard. Older means he is genuinely mid-sentence,
    /// and clearing would eat his real words.
    private var lastSpeechStartedAt = Date.distantPast
    /// DEAF-SERVER-EAR detector state (2026-08-13, QA harness runs
    /// 8/12/14/15/16/18 against the production-identical session): a session
    /// can be deaf on the SERVER side — socket open, every audio send
    /// SUCCEEDING — while the server never emits a single
    /// input_audio_buffer.*/transcription event. No existing net can fire:
    /// the reply watchdog arms on speech_stopped (which never comes), and
    /// the send-side guards key on failures/drops (which never happen).
    /// Evidence pair instead: seconds of REAL SPEECH the open gate actually
    /// delivered vs. when the server last acknowledged ANY input. Speech
    /// accumulating with zero acknowledgment is impossible in a healthy
    /// session — convictDeafSessionIfNeeded reconnects on it (tier 1 of the
    /// voice-failover ladder). Both reset on connect(); the ledger also
    /// zeroes on every server input event.
    private var lastServerInputEventAt: Date?
    private var loudSpeechSeconds: Double = 0
    /// Timestamps of deaf-session convictions, pruned past 120s. ONE deaf
    /// session earns a fast same-vendor rebuild; a SECOND inside 90s means
    /// the FRESH session was born deaf too — a vendor-side burst, where a
    /// third identical mint would just keep eating his words. That is the
    /// tier-2 trigger (switchToElevenFallback).
    private var recentDeafConvictions: [Date] = []
    /// Truncation bookkeeping (2026-08-12 root-cause finding #4): when local
    /// playback is flushed (barge-in, Stop, interruption), the server still
    /// believes every unplayed word was HEARD — its context and his screen
    /// contain speech that never reached his ears, and later answers build on
    /// it ("she gives different answers"). Track the current assistant audio
    /// item and how much of it actually played, so the flush can tell the
    /// server the truth with conversation.item.truncate.
    private var currentAssistantItemId: String?
    /// The item the last flush truncated. Its remaining audio deltas are
    /// stragglers of an answer already cut in his ear — playing them would
    /// resume her mid-garble seconds later (the AirPods barge-in half-fix).
    /// playPCM's delta path drops them until a DIFFERENT item id appears.
    private var truncatedItemId: String?
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
        // The pin arrives ASYNC (from the previous turn's transcript) and can
        // land after Ido already switched languages — so it must yield to the
        // CURRENT audio, never outvote it (nightly run 33: a stale Hebrew pin
        // made her answer an English request in Hebrew).
        sendContext(lang == "he"
            ? "[LANGUAGE] התור האחרון של עידו היה בעברית. אם דבריו הנוכחיים בעברית — עני בעברית. אבל שפת האודיו הנוכחי שלו תמיד גוברת על ההערה הזו: אם הוא מדבר עכשיו אנגלית, עני באנגלית. (פריטי חדשות עדיין נקראים בשפת המקור שלהם.)"
            : "[LANGUAGE] Ido's LAST turn was in ENGLISH. If his current words are English, reply in English. But the language of his CURRENT audio always OVERRIDES this note: if he is speaking Hebrew now, answer in Hebrew. (News items are still read in their original language.)")
    }

    /// Tool calls already executed this session (by call_id) — execution is
    /// deliberately triggered from TWO independent server events
    /// (function_call_arguments.done AND output_item.done), so a single
    /// missed event can never silently lose a tool call. This set dedupes.
    private var handledToolCalls = Set<String>()
    /// The capture sample rate the CURRENT engine expects (OAI 24k; EL 16k).
    private var captureRate: Double = 24000

    /// One-way, once-per-session switch to the backup engine (eleven→openai
    /// — the era ElevenLabs was primary). NEVER while the tier-2 parachute
    /// is up: elFallbackActive means OpenAI already proved deaf twice this
    /// session, so "falling back" to it is ping-pong, not recovery — the
    /// call sites stop honestly via voiceUnavailableStop() instead, and the
    /// guard here is the belt behind them.
    private func switchToBackupEngine(_ why: String) {
        guard engine == .eleven, !engineFellBack, !elFallbackActive else { return }
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

    /// TIER 2 of the voice-failover ladder — the OPPOSITE direction of
    /// switchToBackupEngine. In burst windows ~25% of fresh OpenAI Realtime
    /// sessions are born deaf (2026-08-13: the server never emits input
    /// events while every audio send SUCCEEDS), and when the fresh session
    /// of a tier-1 cutover is deaf too, a third identical mint would just
    /// keep eating his words. Fall over to the dormant ElevenLabs engine
    /// LIVE: connect() branches on `engine` for the mint URL and handle()
    /// for the protocol, so flipping the flag + the wire rates + a graph
    /// rebuild IS the whole switch. One-way for the session
    /// (elFallbackActive); a fresh start() tries OpenAI first again.
    private func switchToElevenFallback(_ why: String) {
        guard engine == .openai, !elFallbackActive else { return }
        clientLog("el-fallback", why)
        elFallbackActive = true
        engine = .eleven
        captureRate = 16000   // ElevenLabs listens at 16 kHz…
        outputRate = 16000    // …and speaks it (initiation metadata corrects if not)
        stopAudio()   // the graph rebuilds at the fallback engine's rates
        transcript.append(.init(
            text: "🎙 Voice engine unresponsive — switching to the backup voice for now.",
            fromHer: true))
        status = "Switching to the backup voice…"
        // Same no-backoff logic as the deaf cutover itself: the NETWORK is
        // fine (sends were succeeding), so the parachute opens NOW — and the
        // unanswered-turn requeue inside scheduleReconnect carries his
        // sentence onto the ElevenLabs session.
        reconnectAttempts = 0
        // serverHearsSpeech is OpenAI-socket state and that socket is dead —
        // a leftover `true` (a speech_started whose stop never arrived) has
        // no event stream to ever clear it on the ElevenLabs session, and it
        // would block the recovery boundary check forever.
        serverHearsSpeech = false
        scheduleReconnect(reason: "el-fallback: " + why, immediate: true)
        startOpenAIRecoveryProbe()
    }

    /// The recovery probe: every 75s while the fallback carries a live
    /// session, POST the mint check — SAME base URL and SAME x-scarlet-token
    /// auth as connect()'s mint, plus ?check=1 so the minted session is
    /// discarded server-side. Consecutive successes are counted here; the
    /// arm threshold is 2 so one lucky mint inside a flapping burst can't
    /// trigger a bounce back into a still-sick vendor.
    private func startOpenAIRecoveryProbe() {
        elRecoveryProbeTask?.cancel()
        elFallbackEpoch += 1
        let epoch = elFallbackEpoch
        elRecoveryProbeTask = Task { @MainActor [weak self] in
            var consecutiveOK = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 75_000_000_000)
                // Epoch + liveness gate: only the CURRENT fallback period's
                // probe may run — a stale one (the session recovered, ended,
                // or restarted since this task was born) dies here.
                guard let self, !Task.isCancelled,
                      self.elFallbackEpoch == epoch, self.elFallbackActive,
                      self.engine == .eleven, self.wantLive else { return }
                // Transient, not fatal: the eleven socket mid-reconnect (ws
                // nil for a beat) just skips this tick — killing the probe
                // over it would lose recovery for the rest of the session.
                guard self.ws != nil else { continue }
                guard let url = URL(string: AppConfig.realtimeURL.absoluteString + "?check=1") else { return }
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue(self.token, forHTTPHeaderField: "x-scarlet-token")
                req.timeoutInterval = 10   // a hung mint is a failed probe, fast
                let ok: Bool
                do {
                    let (_, resp) = try await URLSession.shared.data(for: req)
                    ok = (resp as? HTTPURLResponse)?.statusCode == 200
                } catch { ok = false }
                // The await released the main actor — re-check the world
                // before counting anything into it.
                guard !Task.isCancelled, self.elFallbackEpoch == epoch,
                      self.elFallbackActive else { return }
                if ok {
                    consecutiveOK += 1
                    self.clientLog("el-recovery-probe", "mint check ok — streak=\(consecutiveOK)")
                    if consecutiveOK >= 2 { self.openAIRecovered = true }
                } else {
                    // A failure breaks the streak AND disarms: the vendor
                    // flapped, so an armed-but-unlanded switch must wait for
                    // two FRESH greens, not ride month-old evidence.
                    consecutiveOK = 0
                    self.openAIRecovered = false
                    self.clientLog("el-recovery-probe", "mint check failed — streak reset")
                }
            }
        }
    }

    /// Kill the probe and invalidate its epoch. Every teardown/restart path
    /// (end, voiceUnavailableStop, a fresh start) runs this, so no probe can
    /// outlive the fallback period it was born in.
    private func cancelOpenAIRecoveryProbe() {
        elRecoveryProbeTask?.cancel(); elRecoveryProbeTask = nil
        elFallbackEpoch += 1
        openAIRecovered = false
    }

    /// The armed recovery LANDS only at a quiet boundary: she is not speaking
    /// (no queued playback, no active response) and he is not mid-utterance
    /// (no VAD-open turn, no fresh speech_started, no overlap hold) — so the
    /// engine switch never cuts a sentence in either direction. Checked from
    /// the existing 10s health tick (one bool most ticks) instead of a timer
    /// of its own; worst case the switch waits one extra tick for quiet.
    private func completeOpenAIRecoveryIfQuiet() {
        guard openAIRecovered, elFallbackActive, engine == .eleven, wantLive,
              state == .listening else { return }
        guard pendingBuffers == 0, !responseActive,
              !serverHearsSpeech, !holdingForUserSpeech,
              Date().timeIntervalSince(lastSpeechStartedAt) > 1 else { return }
        cancelOpenAIRecoveryProbe()
        clientLog("el-recovery", "2 consecutive mint checks green — switching back to OpenAI at quiet boundary")
        transcript.append(.init(
            text: "🎙 Primary voice engine recovered — switching back.",
            fromHer: true))
        engine = .openai
        elFallbackActive = false
        // The vendor just PROVED healthy twice in a row — stale convictions
        // from the old burst must not re-trip the parachute on the first
        // hiccup of the recovered session. The ladder starts honest again.
        recentDeafConvictions.removeAll()
        captureRate = 24000   // OpenAI listens at 24 kHz…
        outputRate = 24000    // …and speaks 24 kHz PCM16
        stopAudio()   // graph rebuilds at the primary engine's rates; held/queued buffers die with it
        status = "Switching back to the primary voice…"
        // Session-side switch with the network proven fine (the probe just
        // completed a full mint round-trip) — same no-backoff logic as the
        // cutovers in the other direction.
        reconnectAttempts = 0
        scheduleReconnect(reason: "el-recovery", immediate: true)
    }

    /// Both rungs of the ladder failed this session: OpenAI proved deaf
    /// twice, then the ElevenLabs parachute hit its own quota/failure path.
    /// Bouncing back to OpenAI mid-session would ping-pong into the engine
    /// that just went deaf — the honest move is a clean stop that SAYS so.
    /// Deliberately not endedByUser: the foreground self-heal may retry
    /// later, and start() resets to OpenAI-first, so recovery is one tap
    /// (or one app-open) away once the burst passes.
    private func voiceUnavailableStop() {
        clientLog("voice-unavailable", "EL fallback failed after deaf OpenAI sessions — stopping")
        cancelOpenAIRecoveryProbe()
        wantLive = false
        LocationReporter.shared.stopLiveUpdates()
        reconnectTask?.cancel(); reconnectTask = nil; reconnecting = false
        replyWatchdog?.cancel(); replyWatchdog = nil; awaitingReplyText = nil
        livenessTask?.cancel(); livenessTask = nil
        pathMonitor?.cancel(); pathMonitor = nil
        ws?.cancel(with: .goingAway, reason: nil)
        ws = nil
        stopAudio()
        endBackgroundAssertion()
        state = .idle
        status = "Voice temporarily unavailable — try again in a minute."
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
    /// When all currently queued playback MUST have finished (sum of scheduled
    /// buffer durations). The health tick force-clears a wedged gate: a buffer
    /// completion that never fires (route change mid-play, engine hiccup)
    /// leaves pendingBuffers > 0 forever — mic shut, session looks alive, she
    /// never hears him again. Found on the watch (build 252 "one round then
    /// silent death"); the phone/CarPlay engine shares the same structure, so
    /// it gets the same failsafe BEFORE it burns a car ride.
    private var playbackDeadline = Date.distantPast
    private var gateHealthTask: Task<Void, Never>?
    /// Overlap hold (half-duplex routes): her first buffer arrived while HIS
    /// established utterance was still running. Instead of clearing his words
    /// off the server, she waits him out like a person — her decoded buffers
    /// queue here UNPLAYED (the echo gate stays open, so his speech keeps
    /// streaming) until speech_stopped/committed closes his turn, or the
    /// hold timeout gives up and falls back to the old clear-and-play.
    private var holdingForUserSpeech = false
    private var heldPlaybackBuffers: [AVAudioPCMBuffer] = []
    private var holdTimeoutTask: Task<Void, Never>?

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
        // A fresh user-initiated session ALWAYS tries the primary engine
        // first: even if the last session ended on the ElevenLabs parachute,
        // the burst that convicted OpenAI has usually passed by the next
        // start — and if it hasn't, the parachute just re-opens by itself
        // (recentDeafConvictions deliberately survives, so a still-deaf
        // vendor is convicted on the FIRST fresh failure, not two more).
        engine = .openai
        elFallbackActive = false
        cancelOpenAIRecoveryProbe()   // fresh start owns its own fallback period
        outputRate = 24000   // OpenAI's wire rate; connect() re-derives captureRate
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
        // backend's location fix so her answers are about where he IS, and
        // keep following MOVEMENT (~2 min cadence) for the length of the
        // call: a CarPlay drive must not answer from the fix taken at
        // connect time an hour earlier.
        LocationReporter.shared.startLiveUpdates(while: { [weak self] in
            self?.wantLive == true
        })
        Task { await connect() }
        observeInterruptions()
        // Live message ANNOUNCEMENTS are OFF (Ido 2026-08-12: "I don't need
        // her to announce new emails while we're talking… that's just a
        // distraction"). The signals poll no longer runs; arrivals stay in
        // the Signals page and badges. The incoming-CALL ring announcement
        // stays — a ringing phone he can't hear is a different animal.
        startCallWatch()
        startGateHealthWatch()
        startPathMonitor()
    }

    /// The gate-wedge failsafe + heartbeat telemetry (see playbackDeadline).
    private func startGateHealthWatch() {
        gateHealthTask?.cancel()
        gateHealthTask = Task { @MainActor [weak self] in
            var tick = 0
            var interruptedTicks = 0   // consecutive ticks the interruption latch has been up
            var deafTicks = 0          // consecutive ticks of the silent-deafness signature
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self, self.wantLive, !Task.isCancelled else { return }
                tick += 1
                if self.pendingBuffers > 0, Date() > self.playbackDeadline.addingTimeInterval(3) {
                    self.clientLog("gate-stuck",
                                   "pending=\(self.pendingBuffers) — flushed, mic reopened")
                    // A REAL flush, not raw counter resets: zeroing the
                    // counters left the stalled buffers still scheduled on the
                    // player — when it later unwedged they REPLAYED into the
                    // now-open mic on loudspeaker and she answered her own
                    // voice (phantom self-answers). flushPlayback stops the
                    // player, truncates so the server knows what he actually
                    // heard, and resets the same bookkeeping.
                    self.flushPlayback()
                }
                // Interruption-latch rescue: iOS does NOT guarantee `.ended`
                // (a declined call, some Siri paths) — and `.began` only
                // PAUSED the engine, so audioReady stays true and the
                // foreground !audioReady recovery never fires, while every
                // other recovery path stands down behind `interrupted`. Two
                // ticks of the latch with the other app's audio gone and the
                // app active means nobody is coming to clear it — reclaim.
                if self.interrupted { interruptedTicks += 1 } else { interruptedTicks = 0 }
                if interruptedTicks > 1,
                   !AVAudioSession.sharedInstance().isOtherAudioPlaying,
                   UIApplication.shared.applicationState == .active {
                    interruptedTicks = 0
                    self.clientLog("gate-stuck-repaired", "reason=interrupted — no .ended ever arrived")
                    self.interrupted = false
                    try? self.startAudioSession()
                    self.rebuildAudioGraph()
                }
                // A typing pause that outlives any real typing is a leaked
                // focus event holding her ears shut — restore what Ido had
                // BEFORE the pause (an unconditional `true` here overrode an
                // explicit mute he chose, the one silence that must stand).
                if let t = self.typingPausedAt, Date() > t.addingTimeInterval(90), !self.chatMode {
                    self.clientLog("typing-pause-expired", "auto-restoring ears after 90s")
                    self.typingPausedAt = nil
                    self.micOn = self.micWasOnBeforeTyping
                    if self.micOn { self.status = "Listening…" }
                }
                // Silent-deafness self-heal (2026-08-13 beacons: listening,
                // micOn=false, streaming=false for 4+ minutes with NO gate, no
                // typing pause, no chat mode, no explicit mute — some path
                // dropped micOn and nothing owned restoring it). Two straight
                // ticks of that exact signature is a leak, not a choice:
                // reopen her ears and say so in the logs.
                if self.state == .listening, !self.micOn, !self.responseActive,
                   self.pendingBuffers == 0, self.typingPausedAt == nil,
                   !self.chatMode, !self.userExplicitlyMuted {
                    deafTicks += 1
                    if deafTicks >= 2 {
                        deafTicks = 0
                        self.clientLog("gate-stuck-repaired", "reason=deaf-listening")
                        self.micOn = true
                        self.speechTailUntil = .distantPast   // same stale-tail clear as an unmute
                        self.status = "Listening…"
                    }
                } else {
                    deafTicks = 0
                }
                // DEAF SERVER EAR (2026-08-13, QA harness runs
                // 8/12/14/15/16/18): socket open, audio sends SUCCEEDING, yet
                // the server emits no input_audio_buffer.*/transcription
                // events at all — no other net can fire (the reply watchdog
                // needs speech_stopped; the send guards need failures). The
                // conviction and its two-tier response live in
                // convictDeafSessionIfNeeded — the tap's main-actor hop calls
                // it the moment the ledger crosses (the ~4s verdict the fast
                // cutover budget is built on); this tick is only the net for
                // a ledger that crossed right as he stopped talking.
                self.convictDeafSessionIfNeeded()
                // Recovery off the ElevenLabs parachute lands here: the probe
                // armed openAIRecovered, and this tick is the quiet-boundary
                // check that performs the actual switch (no-op otherwise).
                self.completeOpenAIRecoveryIfQuiet()
                // Every 30s: one heartbeat line so a dead session names its
                // own state in the logs instead of dying invisibly.
                if tick % 3 == 0 {
                    self.clientLog("session-health",
                                   "state=\(self.state) micOn=\(self.micOn) streaming=\(self.micStreaming) "
                                   + "pending=\(self.pendingBuffers) responseActive=\(self.responseActive) "
                                   + "interrupted=\(self.interrupted) engineRunning=\(self.audioEngine.isRunning)")
                }
            }
        }
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
                if self.responseActive { self.deferResponse(.itemBacked) } else { self.send(["type": "response.create"]) }
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
                if self.responseActive { self.deferResponse(.itemBacked) } else { self.send(["type": "response.create"]) }
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
        LocationReporter.shared.stopLiveUpdates()
        cancelOpenAIRecoveryProbe()
        reconnectTask?.cancel(); reconnectTask = nil; reconnecting = false
        reconnectAttempts = 0
        signalsTask?.cancel(); signalsTask = nil
        gateHealthTask?.cancel(); gateHealthTask = nil
        pendingOutbound.removeAll()   // hanging up discards anything not yet delivered
        replyWatchdog?.cancel(); replyWatchdog = nil; awaitingReplyText = nil
        livenessTask?.cancel(); livenessTask = nil
        pathMonitor?.cancel(); pathMonitor = nil
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

    /// True only while a mute Ido CHOSE (the Mic button) is standing. The
    /// watchdog's deaf-listening self-heal keys off this: a false micOn with
    /// this flag down is a leaked gate, with it up it's his decision — the
    /// repair must never talk over a silence he asked for.
    private var userExplicitlyMuted = false

    func toggleMic() {
        micOn.toggle()
        userExplicitlyMuted = !micOn
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

    // MARK: route-aware noise reduction + preemptive path watch (2026-08-13)

    /// The noise-reduction mode the LIVE session was last told. Reset to the
    /// minted default ("near_field") on every connect — a fresh socket is
    /// born with the mint config, so only a *change* needs a session.update.
    private var lastNoiseModeSent: String?

    /// The session is minted with near_field noise reduction — right for the
    /// phone in his hand and the wrist mic, both close-talking. A CarPlay
    /// cabin mic is the opposite: a FAR-FIELD array in the dashboard/headliner,
    /// where near_field under-suppresses road noise — exactly the "catching
    /// external voices that confused her" failure Ido reported. Retune the
    /// live session whenever car-ness flips. OpenAI only: the EL fallback has
    /// no session.update and its pipeline is untouched.
    private func syncNoiseReductionForRoute() {
        guard engine == .openai, ws != nil else { return }
        let mode = onCarRoute ? "far_field" : "near_field"
        guard mode != lastNoiseModeSent else { return }
        lastNoiseModeSent = mode
        send(["type": "session.update",
              "session": ["type": "realtime",
                          "audio": ["input": ["noise_reduction": ["type": mode]]]]])
        clientLog("noise-mode", mode)
    }

    private var pathMonitor: NWPathMonitor?
    private var lastPathSignature: String?
    private var lastPathReconnectAt = Date.distantPast

    /// Driving hands the phone between Wi-Fi and cellular and the socket dies
    /// SILENTLY on the old interface — the liveness ping finds the corpse in
    /// ~15s, but the OS knows about the flip instantly. Reconnect the moment
    /// the path's interface set changes while live (debounced 30s so a
    /// flapping garage/driveway edge can't reconnect-storm). A path going
    /// DOWN is deliberately not acted on: nothing to connect to — the ping
    /// loop + long-tail retry own that; the up-transition lands here and
    /// recovers immediately.
    private func startPathMonitor() {
        pathMonitor?.cancel()
        let mon = NWPathMonitor()
        pathMonitor = mon
        lastPathSignature = nil
        mon.pathUpdateHandler = { [weak self] path in
            let sig = path.status == .satisfied
                ? path.availableInterfaces.map { String(describing: $0.type) }
                    .sorted().joined(separator: "+")
                : "down"
            Task { @MainActor in
                guard let self, self.wantLive else { return }
                let prev = self.lastPathSignature
                self.lastPathSignature = sig
                // First callback is the baseline, not a change.
                guard let prev, prev != sig, sig != "down" else { return }
                guard Date().timeIntervalSince(self.lastPathReconnectAt) > 30 else { return }
                self.lastPathReconnectAt = Date()
                self.clientLog("path-change", "\(prev) → \(sig) — preemptive reconnect")
                self.scheduleReconnect(reason: "network-path-change", immediate: true)
            }
        }
        mon.start(queue: DispatchQueue.global(qos: .utility))
    }

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
            // If a typing pause holds the mic shut RIGHT NOW, micOn=false is
            // transient — snapshotting it would remember "deaf" and restore
            // deaf on exit, permanently (the poisoned-snapshot variant of the
            // 08-12 deafness). Snapshot what the mic WOULD be once typing
            // ends, then clear the pause: the chat-mode gate owns the mic now.
            micWasOnBeforeChat = typingPausedAt != nil ? micWasOnBeforeTyping : micOn
            typingPausedAt = nil
            speakerWasOnBeforeChat = speakerOn
            micOn = false
            speakerOn = false
            player.volume = 0
            chatMode = true
            status = "Chat mode — type to Scarlet"
        } else {
            chatMode = false
            // Any pause that accrued during chat mode is the chat gate's —
            // a stale one left here would re-mute the restored mic later.
            typingPausedAt = nil
            micOn = micWasOnBeforeChat
            speakerOn = speakerWasOnBeforeChat
            player.volume = speakerOn ? 1 : 0
            if micOn { status = "Listening…" }
        }
    }

    // Dictation etiquette: while Ido types/dictates into the text row, her
    // live ears close — otherwise Wispr's spoken dictation reaches the mic
    // and she answers before he presses send.
    //
    // HARDENED (2026-08-12, heartbeat evidence: micOn=false for MINUTES while
    // state=listening — "she stops hearing me" on the phone): three screens
    // drive this from focus events, and focus bouncing between two fields ran
    // beginTyping twice — the second snapshot saved micOn=false, so the
    // restore restored DEAF, permanently and silently. The snapshot is now
    // taken only by the FIRST begin of a pause, and the session health tick
    // force-expires any typing pause older than 90s (a leaked focus event,
    // not a person still typing).
    private var micWasOnBeforeTyping = true
    private var typingPausedAt: Date?
    func beginTyping() {
        if typingPausedAt == nil { micWasOnBeforeTyping = micOn }
        typingPausedAt = Date()
        micOn = false
        status = "Typing — mic paused. Tap Type again to talk."
    }
    func endTyping() {
        // The pause clears in EVERY mode. The old chat-mode early-return left
        // a stale timestamp standing forever: the NEXT beginTyping read it as
        // "same pause, keep the snapshot" (first-begin-wins) and later
        // restored an ancient mic value — the poisoned-snapshot deafness.
        typingPausedAt = nil
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
                        self.deferResponse(.itemBacked)   // a typed turn: only a create answers it
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

    /// Server-side proof the EAR works — any input_audio_buffer.* or input-
    /// transcription event. Stamps the deaf-session clock and zeroes the
    /// loud-speech ledger: acknowledged speech is not evidence of deafness.
    private func noteServerInputEvent() {
        lastServerInputEventAt = Date()
        loudSpeechSeconds = 0
    }

    /// The deaf-session CONVICTION — tier 1 of the voice-failover ladder.
    /// Evidence pair: >4s of REAL SPEECH the open gate delivered with no
    /// server input acknowledgment in 15s (or ever on this socket). VAD
    /// normally acks within ~1s, so 4s of voiced unacknowledged frames is
    /// solidly abnormal (was >10s — that number alone cost 6+ extra seconds
    /// of him repeating himself before the rebuild even began). Called from
    /// the tap's main-actor hop at the moment the ledger crosses — the ~4s
    /// verdict a ~6-7s total cutover needs — and from the gate-health tick
    /// as the net for a ledger that crossed right as he stopped talking.
    /// OpenAI-only: the dormant ElevenLabs stream has no input_audio_buffer
    /// events, so the detector would convict every healthy eleven session.
    private func convictDeafSessionIfNeeded() {
        guard engine == .openai, micOn, ws != nil,
              loudSpeechSeconds > 4,
              lastServerInputEventAt.map({ Date().timeIntervalSince($0) > 15 }) ?? true
        else { return }
        let loud = loudSpeechSeconds
        loudSpeechSeconds = 0
        clientLog("deaf-session",
                  "loud=\(String(format: "%.1f", loud))s level=\(String(format: "%.2f", inputLevel)) serverInput="
                  + (lastServerInputEventAt.map { "\(Int(Date().timeIntervalSince($0)))s-ago" } ?? "never"))
        recentDeafConvictions.append(Date())
        recentDeafConvictions.removeAll { Date().timeIntervalSince($0) > 120 }
        if recentDeafConvictions.filter({ Date().timeIntervalSince($0) < 90 }).count >= 2 {
            // The REBUILT session was born deaf too — a vendor-side burst,
            // where a third identical mint would just keep eating his words.
            // Tier 2: open the ElevenLabs parachute.
            switchToElevenFallback("2 deaf OpenAI sessions in 90s")
        } else {
            // Tier 1: the SESSION is deaf, not the network — every audio
            // send is still succeeding — so the backoff ladder buys nothing
            // and costs the very seconds the cutover budget is for. Reset
            // the ladder and rebuild NOW; the unanswered-turn requeue inside
            // scheduleReconnect still re-asks his sentence on the fresh
            // session.
            reconnectAttempts = 0
            scheduleReconnect(reason: "deaf-session", immediate: true)
        }
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
        // A NEW session has no language pin — forget the old one so the first
        // utterance re-pins. Keeping the stale value made the client skip the
        // pin ("unchanged") and the fresh session drifted into Hebrew mid-reply
        // after every reconnect (audio-e2e runs 34–35; the production
        // language-mixing class of build 225).
        pinnedLanguage = nil
        // A patience-window timer from the OLD session must never fire a
        // response.create into this fresh, empty one (she'd speak first).
        pendingResponseCreate?.cancel()
        pendingResponseCreate = nil
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
                // Unless ElevenLabs IS the tier-2 parachute: OpenAI just
                // proved deaf twice, so bouncing back to it is ping-pong,
                // not recovery — both rungs down, stop honestly.
                if (resp as? HTTPURLResponse)?.statusCode == 402 {
                    if elFallbackActive { voiceUnavailableStop(); return }
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
                // ?defer=1 — this build drives response.create itself (the
                // patience window), so the mint suppresses the VAD
                // auto-response. Older builds don't send it and keep the
                // legacy auto-reply.
                var mintString = AppConfig.realtimeURL.absoluteString + "?defer=1"
                if let v = UserDefaults.standard.string(forKey: SettingsModel.voiceKey), !v.isEmpty {
                    mintString += "&voice=" + v
                }
                let mintURL = URL(string: mintString) ?? AppConfig.realtimeURL
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
            // A rebuilt session's EAR starts unproven: speech the OLD socket
            // never acknowledged must not convict the new one seconds in.
            lastServerInputEventAt = nil
            loudSpeechSeconds = 0
            // Parachute bookkeeping: a fresh OPENAI socket is proof the
            // tier-2 fallback is not riding this session — clear any stale
            // flag so a later REAL fallback isn't a no-op. While the EL
            // fallback IS live (engine == .eleven) the flag must stand: it
            // is what keeps the quota/failure paths from bouncing back to
            // the engine that just proved deaf. (recentDeafConvictions
            // stays — it is the tier-2 trigger's memory across rebuilds.)
            if engine == .openai { elFallbackActive = false }
            responseActive = false
            needsResponseAfterDone = false
            pinnedLanguage = nil   // fresh session — re-pin from his first words
            lastNoiseModeSent = "near_field"   // the minted default; only a CHANGE sends session.update
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
            // If we connected while ALREADY on the car route, retune the
            // freshly-minted near_field session for the far-field cabin mic.
            syncNoiseReductionForRoute()
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
                        // The tier-2 parachute session hitting quota must NOT
                        // bounce back to the engine that just proved deaf
                        // twice — both rungs down, stop honestly.
                        if self.elFallbackActive { self.voiceUnavailableStop(); return }
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
    /// `immediate` (the deaf-session cutover and the tier-2 parachute) skips
    /// the backoff sleep entirely: the SESSION is broken, not the network —
    /// every audio send was still succeeding — so waiting helps nothing.
    private func scheduleReconnect(reason: String = "unspecified", immediate: Bool = false) {
        guard wantLive, !reconnecting else { return }
        clientLog("reconnect", reason)
        // Three straight failures on the premium engine → stop insisting and
        // fall over to the backup (≈6s in, not a minute of backoff). She must
        // ALWAYS come back on SOME voice — EXCEPT when ElevenLabs is itself
        // the tier-2 parachute: OpenAI just proved deaf twice, so "the
        // backup" is the broken engine. Both rungs down → stop honestly.
        if reconnectAttempts >= 3, engine == .eleven, !engineFellBack {
            if elFallbackActive { voiceUnavailableStop(); return }
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
        // Exponential backoff: 0.9s, 1.8s, 3.6s … capped at 30s — unless the
        // caller proved the failure is session-side (`immediate`), where even
        // the first 0.9s rung is pure loss against the ~6-7s cutover budget.
        let attempt = reconnectAttempts
        reconnectAttempts += 1
        let delay = immediate ? 0 : min(30.0, 0.9 * pow(2.0, Double(attempt)))
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
        // Server-ear heartbeat: ANY input-side event (speech start/stop,
        // commit, transcription — even a failed one) is proof the server
        // hears the mic. Matched by prefix, not per-case, so a server-side
        // event rename or addition can't dodge the deaf-session detector.
        if let t = ev["type"] as? String,
           t.hasPrefix("input_audio_buffer.") || t.contains("input_audio_transcription") {
            noteServerInputEvent()
        }
        switch ev["type"] as? String {
        case "response.output_audio.delta", "response.audio.delta":
            if let id = ev["item_id"] as? String {
                // Stragglers of an item the flush already truncated — they
                // were in flight before the cancel landed at the server.
                // Playing them resumes her cut answer garbled seconds after
                // he barged in; drop them until a NEW item starts speaking.
                if id == truncatedItemId { break }
                truncatedItemId = nil
                if id != currentAssistantItemId {
                    currentAssistantItemId = id
                    drainedAudioFrames = 0
                }
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
            if rstatus == "cancelled", deferredResponseReason == .vadSpeech {
                // Cancelled = Ido cut her off (barge-in or Stop). Semantic VAD
                // creates the response for his NEW turn itself (create_response
                // is on) — a deferred create here would race that one and then
                // re-fire input-less at ITS done: the 225 double-answer bug in
                // a new coat. Drop the deferral; his next turn answers itself.
                // ONLY for a vad-speech deferral, though: an ITEM-backed one
                // (typed turn, tool output, system item) has no VAD turn coming
                // to answer it — keep it, and the create below fires as usual.
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
            lastSpeechStartedAt = Date()   // the gate-close branch keys on this age
            // Server-side truth that his voice is registering — instant cue.
            // On sealed-ear (full-duplex) routes this can fire WHILE she is
            // speaking: that is Ido interrupting her. The server no longer
            // truncates on its own (interrupt_response=false after the
            // 2026-08-12 disaster) — cut the locally queued audio AND tell
            // the server what was actually heard (flushPlayback truncates),
            // so she stops in his ear the moment he speaks. Also cancel her
            // GENERATION: flushing only the local queue left the still-
            // streaming deltas to resume her garbled mid-answer. This is a
            // CLIENT-initiated cancel on a route where the mic never gates —
            // his utterance always completes and semantic VAD closes the turn
            // normally (the 08-12 disaster was the opposite shape:
            // SERVER-initiated cancel plus a gated mic).
            if pendingBuffers > 0, sealedEarRoute {
                if responseActive { send(["type": "response.cancel"]) }
                flushPlayback()
                clientLog("barge-in", "speech_started during playback — cut her audio")
            }
            // He resumed inside the patience window — cancel the pending
            // reply; his continuation joins the same exchange untruncated.
            if let pending = pendingResponseCreate {
                pending.cancel()
                pendingResponseCreate = nil
                clientLog("patience", "he resumed — pending reply cancelled")
            }
            if state == .listening, micOn { status = "Hearing you…" }
        case "input_audio_buffer.speech_stopped":
            serverHearsSpeech = false
            lastSpeechStoppedAt = Date()
            releaseHeldPlayback()   // his turn is closed — her held answer plays now
            // The reply is now OURS to request (?defer=1 mint — no VAD
            // auto-response). Schedule it behind the patience window; the
            // watchdog arms when the create is actually sent.
            if responseActive {
                deferResponse(.vadSpeech)
            } else {
                schedulePatienceCreate()
            }
            if state == .listening { status = "Thinking…" }
        case "input_audio_buffer.committed":
            serverHearsSpeech = false
            releaseHeldPlayback()   // his turn is closed — her held answer plays now
            if responseActive {
                deferResponse(.vadSpeech)
            } else if pendingResponseCreate == nil {
                // Defensive: a commit with no scheduled create (some VAD
                // paths skip speech_stopped) must still get answered.
                schedulePatienceCreate()
            }
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
            // Our creates are only ever sent for item-backed inputs (typed
            // turns, tool outputs, system items) — a collided one must
            // survive a cancel, so it re-asks as item-backed.
            if code.contains("active_response") { deferResponse(.itemBacked) }
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

    // ── Voice-initiated workouts: DEVICE-LOCAL tools ──
    // HKWorkoutSession exists only on watchOS, so the WATCH runs the workout
    // (WatchSources/WorkoutManager.swift intercepts the same five names
    // wrist-side). The phone's whole contribution is startWatchApp — launch
    // the watch app carrying the workout configuration; live status, pause,
    // resume and ending belong to the wrist. agent-tools keeps server cases
    // for these names so a Telegram/web call still answers honestly —
    // interception here is what makes a phone voice session start a real
    // workout.

    private static let workoutTools: Set<String> = [
        "start_workout", "end_workout", "workout_status",
        "pause_workout", "resume_workout",
    ]

    /// A store of our own: HKHealthStore instances are independent and cheap
    /// (nothing double-installs, unlike the audio tap), and HealthSync's is
    /// private to its read-only sync world.
    private let workoutStore = HKHealthStore()

    /// Routes device-local tools away from the HTTP proxy; everything else
    /// is the normal authorized round-trip.
    private func performTool(name: String, params: [String: Any]) async -> String {
        Self.workoutTools.contains(name)
            ? await performWorkoutTool(name: name, params: params)
            : await performToolHTTP(name: name, params: params)
    }

    private func performWorkoutTool(name: String, params: [String: Any]) async -> String {
        func json(_ obj: [String: Any]) -> String {
            String(data: (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8),
                   encoding: .utf8) ?? "{}"
        }
        guard name == "start_workout" else {
            // No phone-side handle exists for a session running on the watch
            // (HKWorkoutSession state is not reachable across devices) — the
            // honest answer beats a guessed one. Covers workout_status,
            // pause_workout, resume_workout and end_workout alike.
            return json([
                "ok": false,
                "error": "the workout session lives on his Apple Watch — this phone can only START one",
                "note": "Tell Ido status, pause, resume and ending happen from the wrist: raise the watch and ask there.",
            ])
        }
        let raw = params["type"] as? String ?? "other"
        let (config, type, recognized) = Self.workoutConfiguration(for: raw)
        do {
            // Completion-handler form wrapped by hand: the (Bool, Error?)
            // pattern can complete (false, nil) — "the watch didn't confirm"
            // — which a thrown-error-only path would report as success.
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                workoutStore.startWatchApp(with: config) { ok, error in
                    if ok { cont.resume() }
                    else {
                        cont.resume(throwing: error ?? NSError(
                            domain: "ScarletWorkout", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "the watch did not confirm the launch"]))
                    }
                }
            }
            clientLog("workout-start", "type=\(type) recognized=\(recognized) → watch launched")
            var out: [String: Any] = [
                "ok": true, "type": type,
                "note": "watch app LAUNCHED with the \(type) workout — it starts on his wrist within a couple of seconds. Confirm in a few words; live numbers, pause/resume and ending happen from the watch.",
            ]
            if !recognized {
                // .other on the wire — echo his words so she can say what
                // she started instead of a generic "workout".
                out["requested"] = raw
                out["note"] = "watch app LAUNCHED — no exact Workout-app match for '\(raw)', so it starts as a general workout (heart rate + calories still tracked). Say you started '\(raw)' as a general session."
            }
            return json(out)
        } catch {
            clientLog("workout-start", "type=\(type) failed: " + String(String(describing: error).prefix(120)))
            return json([
                "ok": false,
                "error": "couldn't start the workout on his watch: \(error.localizedDescription)",
                "note": "Say plainly the watch app isn't reachable (no paired watch, Scarlet not installed on it, or the watch is off) — he can start the workout from the watch directly.",
            ])
        }
    }

    /// Free-form spoken name → (configuration, spoken-back name, recognized).
    /// TWIN of the table in WatchSources/WorkoutManager.swift — it must map
    /// to the SAME (activity, location) pairs, because the configuration
    /// crosses to the wrist as bare HealthKit enums and the watch recovers
    /// the name from ITS copy. Ordered specific-first; case-insensitive
    /// substring match over his words.
    private static func workoutConfiguration(for raw: String)
        -> (config: HKWorkoutConfiguration, name: String, recognized: Bool) {
        let rows: [(keys: [String], name: String,
                    activity: HKWorkoutActivityType,
                    location: HKWorkoutSessionLocationType,
                    swim: HKWorkoutSwimmingLocationType?)] = [
            (["treadmill", "indoor run"], "indoor run", .running, .indoor, nil),
            (["indoor walk"], "indoor walk", .walking, .indoor, nil),
            (["open water", "sea swim", "ocean swim"], "open-water swim", .swimming, .outdoor, .openWater),
            (["swim", "pool", "שחייה", "שחיה"], "pool swim", .swimming, .indoor, .pool),
            (["spin", "indoor cycl", "indoor bike", "indoor ride", "stationary bike", "exercise bike", "peloton"], "indoor cycling", .cycling, .indoor, nil),
            (["kickbox"], "kickboxing", .kickboxing, .indoor, nil),
            (["box"], "boxing", .boxing, .indoor, nil),
            (["jump rope", "jumprope", "jump-rope", "skipping"], "jump rope", .jumpRope, .indoor, nil),
            (["functional"], "functional strength", .functionalStrengthTraining, .indoor, nil),
            (["strength", "weight", "lifting", "lift", "משקולות", "כוח"], "strength training", .traditionalStrengthTraining, .indoor, nil),
            (["stair", "stepmill"], "stair climbing", .stairClimbing, .indoor, nil),
            (["stepper", "step training", "step machine"], "stepper", .stepTraining, .indoor, nil),
            (["elliptical", "cross trainer", "cross-trainer"], "elliptical", .elliptical, .indoor, nil),
            (["rowing", "row", "erg"], "rowing", .rowing, .indoor, nil),
            (["hiit", "high intensity", "high-intensity", "interval", "tabata"], "HIIT", .highIntensityIntervalTraining, .indoor, nil),
            (["yoga", "יוגה"], "yoga", .yoga, .indoor, nil),
            (["pilates", "פילאטיס"], "pilates", .pilates, .indoor, nil),
            (["core", "abs"], "core training", .coreTraining, .indoor, nil),
            (["cooldown", "cool down", "cool-down"], "cooldown", .cooldown, .indoor, nil),
            (["stretch", "flexibility", "mobility"], "stretching", .flexibility, .indoor, nil),
            (["danc", "zumba", "ריקוד"], "dance", .cardioDance, .indoor, nil),
            (["hike", "hiking", "trail"], "hiking", .hiking, .outdoor, nil),
            (["cycl", "bike", "biking", "ride", "אופניים"], "outdoor cycling", .cycling, .outdoor, nil),
            (["run", "jog", "ריצה"], "outdoor run", .running, .outdoor, nil),
            (["walk", "הליכה"], "outdoor walk", .walking, .outdoor, nil),
        ]
        let q = raw.lowercased()
        let config = HKWorkoutConfiguration()
        if let row = rows.first(where: { row in row.keys.contains(where: { q.contains($0) }) }) {
            config.activityType = row.activity
            config.locationType = row.location
            if let s = row.swim { config.swimmingLocationType = s }
            return (config, row.name, true)
        }
        config.activityType = .other
        config.locationType = .unknown
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return (config, trimmed.isEmpty ? "workout" : trimmed, false)
    }

    /// ElevenLabs client_tool_call entry.
    private func runTool(_ c: [String: Any]) {
        let name = c["tool_name"] as? String ?? ""
        let callId = c["tool_call_id"] as? String ?? ""
        let params = c["parameters"] as? [String: Any] ?? [:]
        preToolCues(name: name, params: params)
        Task {
            let out = await performTool(name: name, params: params)
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
            let out = await performTool(name: name, params: params)
            send(["type": "conversation.item.create",
                  "item": ["type": "function_call_output", "call_id": callId,
                           "output": cappedToolResult(name, out)]])
            // Same one-active-response gate as user turns: if Ido spoke while
            // the tool HTTP ran, semantic VAD already created a response — an
            // unconditional create here collides (the 225 error bursts) and
            // the deferral then re-answered the turn twice. Defer instead.
            if responseActive {
                deferResponse(.itemBacked)   // a tool output only a create can voice
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
                                if self.responseActive { self.deferResponse(.itemBacked) } else { self.send(["type": "response.create"]) }
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
            // Wall-clock duration of this callback's audio, computed HERE so
            // only a scalar (never the non-Sendable buffer) crosses into the
            // main-actor hop — the deaf-session ledger accumulates it below.
            let frameDur = Double(buffer.frameLength) / max(buffer.format.sampleRate, 1)
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
                // Deaf-session ledger (QA runs 8/12/14/15/16/18): count REAL
                // SPEECH the open gate is actually delivering. 0.30 is the
                // same dB-mapped level the "Hearing you…" cue above already
                // treats as speech (-42 dB RMS on the -60 dB-floor scale;
                // silence idles under 0.06) — but on the INSTANTANEOUS norm,
                // not the smoothed meter, so the meter's slow release can't
                // inflate the count. Zeroed by any server input event; >4s
                // surviving means the server heard NOTHING he said (VAD
                // normally acks within ~1s). Convict at the CROSSING, right
                // here — the next 10s health tick is too late for the ~6-7s
                // deaf-cutover budget; the tick stays only as the net.
                if norm > 0.30 {
                    self.loudSpeechSeconds += frameDur
                    self.convictDeafSessionIfNeeded()
                }
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
        // Held buffers carry the OLD output rate — never release them into
        // the re-wired player leg.
        holdTimeoutTask?.cancel(); holdTimeoutTask = nil
        holdingForUserSpeech = false
        heldPlaybackBuffers.removeAll()
        pendingBuffers = 0
        speechTailUntil = Date.distantPast
        playbackDeadline = .distantPast
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
        // Already waiting out his utterance: every further delta joins the
        // held queue in order — speech_stopped/committed (or the hold
        // timeout) releases them together.
        if holdingForUserSpeech {
            heldPlaybackBuffers.append(buf)
            return
        }
        // The echo gate is about to close (her audio starts) while server-VAD
        // is mid-HIS-utterance. TWO realities share that signal, told apart
        // by how long ago speech_started fired:
        //  • under 0.5s — the race window between his voice registering and
        //    her first buffer. A fragment; discard it (2026-08-12 root cause
        //    #1) and he repeats naturally once she finishes.
        //  • longer — he is REALLY talking, and clearing here ate his words
        //    mid-sentence. Instead she waits out his overlap like a person:
        //    her buffers queue unplayed, the gate stays OPEN for him, and
        //    speech_stopped/committed both closes his turn and releases her
        //    held audio. His words survive.
        if pendingBuffers == 0, serverHearsSpeech, !sealedEarRoute {
            if Date().timeIntervalSince(lastSpeechStartedAt) < 0.5 {
                serverHearsSpeech = false
                send(["type": "input_audio_buffer.clear"])
                clientLog("gate-close-clear", "discarded mid-utterance fragment at gate close")
            } else {
                holdingForUserSpeech = true
                heldPlaybackBuffers.append(buf)
                armHoldTimeout()
                clientLog("gate-hold", "his speech predates her audio — holding playback for his turn")
                return
            }
        }
        schedulePlayback(buf)
    }

    /// His overlapping turn closed (speech_stopped/committed, or the hold
    /// timeout gave up) — her held answer plays now, from its first word,
    /// with nothing of his speech lost.
    private func releaseHeldPlayback() {
        guard holdingForUserSpeech else { return }
        holdTimeoutTask?.cancel(); holdTimeoutTask = nil
        holdingForUserSpeech = false
        let held = heldPlaybackBuffers
        heldPlaybackBuffers.removeAll()
        for buf in held { schedulePlayback(buf) }
    }

    /// The hold's failsafe: if the server never closes his turn (VAD dangling
    /// on a noise floor, a missed event), her voice must not be held hostage —
    /// after 2.5s fall back to exactly the old behavior: clear his input,
    /// play what was held, and log that the wait was abandoned.
    private func armHoldTimeout() {
        holdTimeoutTask?.cancel()
        holdTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self, !Task.isCancelled, self.holdingForUserSpeech else { return }
            self.serverHearsSpeech = false
            self.send(["type": "input_audio_buffer.clear"])
            self.clientLog("gate-hold-timeout", "no speech_stopped in 2.5s — clearing input, playing held audio")
            self.releaseHeldPlayback()
        }
    }

    /// Actually start one of her buffers on the player — the lower half of
    /// the old playPCM, shared by the live path and the held-queue release.
    private func schedulePlayback(_ buf: AVAudioPCMBuffer) {
        guard !interrupted else { return }   // the release path can race an interruption
        if !audioEngine.isRunning { try? audioEngine.start() }
        guard audioEngine.isRunning else { return }
        let frames = buf.frameLength
        if !player.isPlaying { player.play() }
        state = .speaking
        status = speakerOn ? "Scarlet is speaking…" : "Answering silently — read below"
        pendingBuffers += 1
        // Duration at the CURRENT engine's play rate, never a hard-coded
        // 24000: buffers are minted in playFormat (= outputRate), and on the
        // ElevenLabs fallback that is 16 kHz — dividing by 24k there ran the
        // deadline 33% short, so the gate-wedge failsafe (deadline+3s) could
        // flush a perfectly healthy long answer mid-sentence.
        playbackDeadline = max(playbackDeadline, Date()).addingTimeInterval(Double(frames) / outputRate)
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
        // Audio held back for his overlap dies with the flush — the answer it
        // belonged to is cut. Held buffers still count as UNPLAYED for the
        // truncate below: the server must learn none of them was heard.
        let hadHeld = !heldPlaybackBuffers.isEmpty
        holdTimeoutTask?.cancel(); holdTimeoutTask = nil
        holdingForUserSpeech = false
        heldPlaybackBuffers.removeAll()
        // Tell the server how much he ACTUALLY heard before the cut (root
        // cause #4, "she gives different answers"): without truncate, her
        // context keeps every unplayed word as if spoken, and later replies
        // build on things that never reached his ears. 24kHz mono wire rate.
        if let itemId = currentAssistantItemId, pendingBuffers > 0 || hadHeld {
            let heardMs = max(0, drainedAudioFrames * 1000 / 24000)
            send(["type": "conversation.item.truncate",
                  "item_id": itemId, "content_index": 0, "audio_end_ms": heardMs])
            clientLog("truncate", "item=\(itemId) heard=\(heardMs)ms")
            // Deltas for the truncated item may still be in flight from the
            // server — remember it so playPCM drops the stragglers instead of
            // resuming the cut answer garbled (the AirPods barge-in half-fix).
            truncatedItemId = itemId
            currentAssistantItemId = nil
        }
        player.stop()
        pendingBuffers = 0
        speechTailUntil = Date.distantPast
        playbackDeadline = .distantPast
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
        // The held-overlap queue holds buffers in the OLD play format — a
        // graph rebuilt at a new rate must never schedule them (format
        // mismatch traps), so the hold dies with the graph.
        holdTimeoutTask?.cancel(); holdTimeoutTask = nil
        holdingForUserSpeech = false
        heldPlaybackBuffers.removeAll()
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
        playbackDeadline = .distantPast
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
                // Held-overlap buffers belonged to the orphaned player — a
                // release into the fresh one would schedule stale audio.
                self.holdTimeoutTask?.cancel(); self.holdTimeoutTask = nil
                self.holdingForUserSpeech = false
                self.heldPlaybackBuffers.removeAll()
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
                    self.syncNoiseReductionForRoute()
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
                // to the foreground is the moment to reclaim it. The latch
                // check is SEPARATE from audioReady: `.began` only pauses the
                // engine, so after a declined call / Siri grab the latch is up
                // while audioReady is still true — the old !audioReady-only
                // guard skipped recovery and she stayed deaf for minutes
                // (2026-08-13 beacons). A standing latch on foreground always
                // recovers: iOS never promises the `.ended` that would.
                if self.wantLive, self.interrupted || !self.audioReady {
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
