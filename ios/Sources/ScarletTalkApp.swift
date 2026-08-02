import Combine
import SwiftUI
import UIKit

@main
struct ScarletTalkApp: App {
    @StateObject private var session = AppSession()

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
    @StateObject private var convo = Conversation()
    @State private var tab: Tab = .talk
    @State private var voiceDraftPresented = false
    /// Draft ids already offered for recovery THIS process — a fresh launch
    /// (i.e. after a crash) offers again; within one run we don't nag.
    @State private var recoveredDraftIds: Set<String> = []
    @Environment(\.scenePhase) private var scenePhase

    enum Tab: Hashable { case talk, inbox, calendar, chats, library }

    /// Ambient focus for the Talk screen; the Inbox hierarchy reports its
    /// own (list vs. open email) from its onAppears.
    private static let talkFocus =
        "[FOCUS] Ido is on the Talk screen, in live conversation. No item focused."

    var body: some View {
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
        .onReceive(NotificationCenter.default.publisher(for: .scarletVoiceDraftStarted)) { _ in
            voiceDraftPresented = true
        }
        .sheet(isPresented: $voiceDraftPresented) {
            DraftView(seed: nil, attachToActive: true)
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

    /// Crash/kill recovery: if a draft is still open server-side (status
    /// "draft" — the server keeps them), reopen the drafting table over
    /// whatever screen we're on. Once per draft per process: a fresh launch
    /// after a crash offers again; dismissing it doesn't nag within a run.
    private func recoverActiveDraft() async {
        guard !voiceDraftPresented else { return }
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
              (draft["status"] as? String) == "draft" else { return }
        // Only resurrect reasonably recent work (48h) — not archaeology.
        if let ts = draft["updated_at"] as? String,
           let when = MailDates.parse(ts),
           Date().timeIntervalSince(when) > 48 * 3600 { return }
        guard !recoveredDraftIds.contains(id) else { return }
        recoveredDraftIds.insert(id)
        FlightRecorder.note(screen: "draft-recovered:\(id)")
        voiceDraftPresented = true
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

    static func note(screen: String) {
        let d = UserDefaults.standard
        d.set(["screen": screen, "ts": ISO8601DateFormatter().string(from: Date())],
              forKey: stateKey)
        d.set(true, forKey: aliveKey)
    }

    static func reportUncleanExitIfAny() {
        let d = UserDefaults.standard
        guard d.bool(forKey: aliveKey) else { d.set(true, forKey: aliveKey); return }
        let last = d.dictionary(forKey: stateKey) ?? [:]
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
            req.httpBody = try? JSONSerialization.data(withJSONObject: [
                "kind": "unclean_exit",
                "detail": ["last_screen": last["screen"] ?? "unknown",
                           "last_ts": last["ts"] ?? ""],
            ])
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
