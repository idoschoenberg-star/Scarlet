import Combine
import SwiftUI
import UIKit

@main
struct ScarletTalkApp: App {
    @StateObject private var session = AppSession()

    init() {
        // Install the crash black-box before anything else can die, so the
        // faulting stack is captured and reported on the next launch.
        FlightRecorder.installCrashHandlers()
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                ScarletBackground().ignoresSafeArea()
                if session.unlocked {
                    RootView().environmentObject(session)
                } else {
                    UnlockView().environmentObject(session)
                }
            }
            .preferredColorScheme(.dark)
        }
    }
}

/// Post-unlock shell: Talk, Inbox, Calendar and Chats tabs. The conversation
/// lives HERE, above the tabs, so switching pages never tears down a live
/// call — only the explicit End button (or the OS) ends it.
struct RootView: View {
    // The one process-wide conversation — shared with the CarPlay scene so the
    // car continues the same session instead of racing a second audio graph.
    @StateObject private var convo = Conversation.shared
    @State private var tab: Tab = .talk
    @State private var voiceDraftPresented = false
    /// The compose_draft tool arguments (recipient, instruction, channel) posted
    /// the instant Scarlet calls the tool — handed to the DraftView so the
    /// writing card paints his request before the server row exists.
    @State private var voiceDraftIntent: [String: String]? = nil
    /// Draft ids already offered for recovery THIS process — a fresh launch
    /// (i.e. after a crash) offers again; within one run we don't nag.
    @State private var recoveredDraftIds: Set<String> = []
    /// True while ANY draft sheet is on screen (RootView's or Inbox/Chats/Desk's,
    /// via the shared scarletDraftSheetVisible signal) — the backstop poll must
    /// not open a second window over one already up.
    @State private var draftSheetOpen = false
    @Environment(\.scenePhase) private var scenePhase
    /// iPhone keeps the TabView; iPad/Mac (regular width) get the
    /// three-pane SplitShell — one codebase, presentation by surface.
    @Environment(\.horizontalSizeClass) private var hSize

    enum Tab: Hashable { case talk, inbox, calendar, chats, library, health, desk }

    /// Ambient focus for the Talk screen; the Inbox hierarchy reports its
    /// own (list vs. open email) from its onAppears.
    private static let talkFocus =
        "[FOCUS] Ido is on the Talk screen, in live conversation. No item focused."

    var body: some View {
        Group {
            if hSize == .regular {
                SplitShell(convo: convo)
            } else {
                phoneTabs
            }
        }
        .tint(Color(red: 1, green: 0.35, blue: 0.42))
        // The Scarlet Presence capsule is EMBEDDED inside each list screen
        // (safeAreaInset in InboxView / CalendarView / ChatsView), not
        // overlaid here — a pushed detail or a sheet structurally replaces
        // it, so it can never cover another screen's buttons. This shell
        // only answers the capsule's "take me to Talk" request.
        .onReceive(NotificationCenter.default.publisher(for: .scarletGoToTalk)) { _ in
            tab = .talk
        }
        // "Hey Siri, Talk to Scarlet" (App Intent): wake the live conversation.
        // Warm launch (app already running) arrives here via the notification;
        // the cold-launch case is drained in .onAppear below.
        .onReceive(NotificationCenter.default.publisher(for: .scarletStartFromIntent)) { _ in
            startFromIntent()
        }
        // "Ask Scarlet about this email": the mail reader posts a notification;
        // this shell (which owns the conversation) switches to Talk and hands
        // her the question — waking the conversation first if it isn't live.
        .onReceive(NotificationCenter.default.publisher(for: .scarletAskAboutEmail)) { note in
            guard let text = note.userInfo?["text"] as? String, !text.isEmpty else { return }
            tab = .talk
            if convo.state == .idle {
                convo.hasAutoStarted = true
                convo.start(token: TokenStore.token ?? "")
            }
            Task { @MainActor in
                // Give a cold socket a moment to come up before delivering.
                var waited = 0
                while convo.state == .connecting && waited < 40 {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    waited += 1
                }
                convo.sendText(text)
            }
        }
        // Scarlet started a draft by voice (compose_draft tool): open the
        // drafting table over whatever screen Ido is on. The sheet attaches
        // to the active server-side draft instead of composing its own.
        .onReceive(NotificationCenter.default.publisher(for: .scarletVoiceDraftStarted)) { note in
            // Mark the id "seen" ONLY when we actually present it. Marking it
            // unconditionally (the old bug) permanently blinded the backstop
            // poll for that draft whenever draftSheetOpen was momentarily true,
            // so the window then never opened at all.
            if !draftSheetOpen {
                if let id = note.object as? String { recoveredDraftIds.insert(id) }
                voiceDraftPresented = true
            }
        }
        // The INSTANT Scarlet calls compose_draft (before the network round-trip):
        // capture his request and open the window immediately so it reacts the
        // moment he finishes speaking, with the body streaming in a beat later.
        .onReceive(NotificationCenter.default.publisher(for: .scarletVoiceDraftIntent)) { note in
            if let intent = note.object as? [String: String] { voiceDraftIntent = intent }
            if !draftSheetOpen { voiceDraftPresented = true }
        }
        // Track any draft sheet's visibility (from every DraftView) so the
        // backstop poll never double-opens.
        .onReceive(NotificationCenter.default.publisher(for: .scarletDraftSheetVisible)) { note in
            draftSheetOpen = (note.userInfo?["visible"] as? Bool) ?? false
        }
        // Reliability backstop: a voice-composed draft reaches the window even if
        // the compose_draft tool-result notification is missed. Every ~2s, if no
        // draft sheet is open, check for a fresh server-side draft and open it.
        // recoverActiveDraft() only opens ids not already seen, so a dismissed
        // draft is never reopened.
        .task {
            while !Task.isCancelled {
                if !draftSheetOpen && !voiceDraftPresented { await recoverActiveDraft() }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        .sheet(isPresented: $voiceDraftPresented, onDismiss: { voiceDraftIntent = nil }) {
            DraftView(seed: nil, attachToActive: true, voiceIntent: voiceDraftIntent)
                .environmentObject(convo)
                .preferredColorScheme(.dark)
        }
        // Ambient focus: Talk at launch and whenever the tab returns to it;
        // switching to Inbox lets that hierarchy report itself.
        .onAppear {
            convo.setFocus(Self.talkFocus)
            FlightRecorder.reportUncleanExitIfAny()
            FlightRecorder.note(screen: "talk")
            Task { await recoverActiveDraft() }
            // Cold-launch "Talk to Scarlet": the intent may have fired before
            // the observer above was listening, so drain the pending flag once.
            if ScarletLauncher.shared.consumePendingStart() { startFromIntent() }
        }
        // Coming back to the foreground re-checks for an orphaned draft —
        // a crash or an iOS kill mid-draft must NEVER lose Ido's work.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await recoverActiveDraft() } }
            FlightRecorder.note(screen: "phase:\(phase)")
        }
        .onChange(of: tab) { _, newTab in
            if newTab == .talk { convo.setFocus(Self.talkFocus) }
        }
        // Desk mode: while the phone sits open on Talk next to his Mac, poll
        // what he's focused on at the desk. Reading an email in DESKTOP
        // Outlook flows to Scarlet as [FOCUS] — he speaks to the phone, the
        // draft opens here, and the approved reply lands back in Outlook.
        // Only on the Talk tab: inside the app, each screen owns its focus.
        .task(id: tab) {
            guard tab == .talk else { return }
            var lastSig = ""
            while !Task.isCancelled {
                if convo.state == .listening || convo.state == .speaking {
                    if let desk = await Self.fetchMacFocus() {
                        if desk.sig != lastSig {
                            lastSig = desk.sig
                            convo.setFocus(desk.focusText)
                        }
                    } else if lastSig != "" {
                        lastSig = ""
                        if tab == .talk { convo.setFocus(Self.talkFocus) }
                    }
                }
                try? await Task.sleep(nanoseconds: 8_000_000_000)
            }
        }
    }

    /// The iPhone presentation: the main tabs (5+ fold into More).
    private var phoneTabs: some View {
        TabView(selection: $tab) {
            TalkView(convo: convo)
                .background(ScarletBackground().ignoresSafeArea())
                .tabItem { Label("Talk", systemImage: "waveform") }
                .tag(Tab.talk)
            InboxView()
                .environmentObject(convo)
                .tabItem { Label("Inbox", systemImage: "envelope.fill") }
                .tag(Tab.inbox)
            CalendarView()
                .environmentObject(convo)
                .tabItem { Label("Calendar", systemImage: "calendar") }
                .tag(Tab.calendar)
            ChatsView()
                .environmentObject(convo)
                .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right.fill") }
                .tag(Tab.chats)
            LibraryView()
                .environmentObject(convo)
                .tabItem { Label("Library", systemImage: "books.vertical.fill") }
                .tag(Tab.library)
            HealthView()
                .environmentObject(convo)
                .tabItem { Label("Health", systemImage: "heart.fill") }
                .tag(Tab.health)
            DeskView()
                .environmentObject(convo)
                .tabItem { Label("Desk", systemImage: "checklist") }
                .tag(Tab.desk)
        }
    }

    /// Wake the conversation from the "Talk to Scarlet" App Intent — switch to
    /// Talk and start a session if one isn't already live.
    private func startFromIntent() {
        tab = .talk
        if convo.state == .idle {
            convo.hasAutoStarted = true
            convo.start(token: TokenStore.token ?? "")
        }
    }

    /// Crash/kill recovery: if a draft is still open server-side (status
    /// "draft" — the server keeps them), reopen the drafting table over
    /// whatever screen we're on. Once per draft per process: a fresh launch
    /// after a crash offers again; dismissing it doesn't nag within a run.
    // @MainActor: after the `await` below the continuation can resume off-main,
    // and everything past it mutates SwiftUI @State (recoveredDraftIds,
    // voiceDraftPresented) and touches `convo`. Pin the whole method to main.
    @MainActor
    private func recoverActiveDraft() async {
        guard !voiceDraftPresented, !draftSheetOpen else { return }
        var comps = URLComponents(url: AppConfig.appAPIURL, resolvingAgainstBaseURL: false)!
        var items = comps.queryItems ?? []
        items.append(URLQueryItem(name: "op", value: "draft_active"))
        comps.queryItems = items
        guard let url = comps.url else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(TokenStore.token ?? "", forHTTPHeaderField: "x-scarlet-token")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let draft = obj["draft"] as? [String: Any],
              let id = draft["id"] as? String, !id.isEmpty,
              // Open on "writing" too, not only "draft": a voice-composed draft
              // sits in "writing" for the seconds the body streams in, and the
              // window is meant to open immediately and show it filling. Gating
              // on "draft" alone meant the window often never opened.
              ["writing", "draft"].contains(draft["status"] as? String ?? "") else { return }
        // Only resurrect reasonably recent work (48h) — not archaeology.
        if let ts = draft["updated_at"] as? String,
           let when = MailDates.parse(ts),
           Date().timeIntervalSince(when) > 48 * 3600 { return }
        guard !recoveredDraftIds.contains(id) else { return }
        recoveredDraftIds.insert(id)
        FlightRecorder.note(screen: "draft-recovered:\(id)")
        voiceDraftPresented = true
        // She announces it — Ido should never have to go looking for lost
        // work. Sent as a hidden system turn so she speaks up proactively.
        let recipient = (draft["recipient"] as? String) ?? ""
        let channel = (draft["channel"] as? String) ?? ""
        convo.sendSystemNudge(
            "[SYSTEM] The app just recovered a draft that was interrupted mid-work" +
            (recipient.isEmpty ? "" : " (a \(channel) message to \(recipient))") +
            ". It is back on his screen now. Tell Ido in ONE warm short sentence that his draft to " +
            (recipient.isEmpty ? "them" : recipient) +
            " was interrupted and is back on his screen, and that you can pick up right where you left off. Nothing more.")
    }

    /// One desk-focus poll. Returns nil when the Mac is idle/stale or not
    /// on Outlook — the phone then falls back to its own ambient focus.
    private struct DeskFocus { let sig: String; let focusText: String }
    private static func fetchMacFocus() async -> DeskFocus? {
        var comps = URLComponents(url: AppConfig.appAPIURL, resolvingAgainstBaseURL: false)!
        var items = comps.queryItems ?? []
        items.append(URLQueryItem(name: "op", value: "mac_focus"))
        comps.queryItems = items
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(TokenStore.token ?? "", forHTTPHeaderField: "x-scarlet-token")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["fresh"] as? Bool) == true,
              let outlook = obj["outlook"] as? [String: Any],
              let subject = outlook["subject"] as? String, !subject.isEmpty else { return nil }
        let sender = (outlook["sender"] as? String) ?? ""
        let messageId = (outlook["message_id"] as? String) ?? ""
        var text = "[FOCUS] DESK MODE: Ido is at his Mac, reading in desktop Outlook — \"\(subject)\""
        if !sender.isEmpty { text += " from \(sender)" }
        text += ". If he gives a drafting instruction, it refers to THIS email: ONE compose_draft with channel email_outlook"
        if !messageId.isEmpty { text += " and message_id \(messageId)" }
        text += ". The draft window opens on his phone; the approved draft appears in Outlook Drafts on his desktop."
        return DeskFocus(sig: subject + "|" + sender, focusText: text)
    }
}

/// Flight recorder: a tiny black box. Every screen change stamps local
/// state; if the app dies without a clean record (crash, freeze-kill, iOS
/// memory reclaim), the NEXT launch reports what was on screen and when —
/// so "she froze and everything disappeared" leaves evidence, not mystery.
enum FlightRecorder {
    private static let stateKey = "scarlet.flight.state"
    private static let aliveKey = "scarlet.flight.alive"
    private static let crashKey = "scarlet.flight.crash"
    /// One capture per process — the first fault wins (an NSException that
    /// aborts would otherwise be overwritten by the ensuing SIGABRT's thinner
    /// stack).
    private static var didCapture = false

    static func note(screen: String) {
        let d = UserDefaults.standard
        d.set(["screen": screen, "ts": ISO8601DateFormatter().string(from: Date())],
              forKey: stateKey)
        d.set(true, forKey: aliveKey)
    }

    /// Install once at launch. Captures BOTH uncaught Obj-C/Swift exceptions and
    /// fatal POSIX signals (EXC_BAD_ACCESS→SIGSEGV/SIGBUS, SIGABRT, SIGILL,
    /// SIGTRAP, SIGFPE), persisting the backtrace so the next launch reports
    /// exactly where it died. A pragmatic in-house reporter — enough to pinpoint
    /// the faulting frame without a third-party SDK. The handler closures capture
    /// no context, so they convert cleanly to the C function pointers both APIs
    /// require.
    static func installCrashHandlers() {
        NSSetUncaughtExceptionHandler { exc in
            FlightRecorder.capture(
                type: "exception",
                name: exc.name.rawValue,
                reason: exc.reason ?? "",
                stack: exc.callStackSymbols.joined(separator: "\n"))
        }
        for sig in [SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGTRAP, SIGFPE] {
            signal(sig) { s in
                if !FlightRecorder.didCapture {
                    FlightRecorder.capture(
                        type: "signal",
                        name: "signal_\(s)",
                        reason: "fatal signal \(s)",
                        stack: Thread.callStackSymbols.joined(separator: "\n"))
                }
                // Re-raise through the default handler so the OS still records it.
                signal(s, SIG_DFL)
                raise(s)
            }
        }
    }

    private static func capture(type: String, name: String, reason: String, stack: String) {
        if didCapture { return }
        didCapture = true
        let d = UserDefaults.standard
        let last = d.dictionary(forKey: stateKey) ?? [:]
        d.set([
            "type": type, "name": name, "reason": reason,
            // callStackSymbols runs top-first (the faulting frame leads), so a
            // prefix still names the culprit; cap keeps the JSON body sane.
            "stack": String(stack.prefix(9000)),
            "last_screen": last["screen"] ?? "unknown",
            "last_ts": last["ts"] ?? "",
            "ts": ISO8601DateFormatter().string(from: Date()),
        ], forKey: crashKey)
        d.synchronize() // we are about to die — force it to disk
    }

    static func reportUncleanExitIfAny() {
        let d = UserDefaults.standard
        // A caught crash from the previous run — the richest signal there is.
        if let crash = d.dictionary(forKey: crashKey) {
            d.removeObject(forKey: crashKey)
            d.set(true, forKey: aliveKey) // handled — don't also fire unclean_exit
            post(kind: "crash", detail: crash)
            return
        }
        // Otherwise: the pre-existing heuristic (freeze/jetsam kill no handler caught).
        guard d.bool(forKey: aliveKey) else { d.set(true, forKey: aliveKey); return }
        let last = d.dictionary(forKey: stateKey) ?? [:]
        post(kind: "unclean_exit",
             detail: ["last_screen": last["screen"] ?? "unknown", "last_ts": last["ts"] ?? ""])
    }

    private static func post(kind: String, detail: [String: Any]) {
        Task {
            var comps = URLComponents(url: AppConfig.appAPIURL, resolvingAgainstBaseURL: false)!
            var items = comps.queryItems ?? []
            items.append(URLQueryItem(name: "op", value: "app_event"))
            comps.queryItems = items
            guard let url = comps.url else { return }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue(TokenStore.token ?? "", forHTTPHeaderField: "x-scarlet-token")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["kind": kind, "detail": detail])
            _ = try? await URLSession.shared.data(for: req)
        }
    }
}

/// App-wide state: whether we hold a valid device token.
final class AppSession: ObservableObject {
    @Published var unlocked: Bool

    init() { self.unlocked = TokenStore.token != nil }

    func setToken(_ token: String) {
        TokenStore.token = token
        unlocked = true
    }
    func signOut() {
        TokenStore.token = nil
        unlocked = false
    }
}

/// The living scarlet silk background, native gradient version of the web app.
struct ScarletBackground: View {
    var body: some View {
        RadialGradient(
            colors: [Color(red: 0.55, green: 0.07, blue: 0.19),
                     Color(red: 0.043, green: 0.02, blue: 0.027)],
            center: .center, startRadius: 40, endRadius: 620
        )
    }
}
