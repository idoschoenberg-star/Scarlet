import Combine
import SwiftUI

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

    enum Tab: Hashable { case talk, inbox, calendar, chats }

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
        }
        .tint(Color(red: 1, green: 0.35, blue: 0.42))
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
                .preferredColorScheme(.dark)
        }
        // Ambient focus: Talk at launch and whenever the tab returns to it;
        // switching to Inbox lets that hierarchy report itself.
        .onAppear { convo.setFocus(Self.talkFocus) }
        .onChange(of: tab) { _, newTab in
            if newTab == .talk { convo.setFocus(Self.talkFocus) }
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
