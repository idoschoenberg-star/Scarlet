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
    /// True while ANY DraftView sheet is up (it broadcasts its visibility) —
    /// the presence capsule hides so the sheet is the one Scarlet surface.
    @State private var draftSheetVisible = false
    /// How many screens currently OWN the bottom edge (chat thread compose
    /// bar, mail reader action bar, calendar event detail). A COUNTER, not a
    /// bool: appear/disappear between sibling screens isn't strictly ordered,
    /// so push A → present B → dismiss B must not un-hide wrongly. The
    /// capsule shows only when nobody owns the bottom (list screens).
    @State private var bottomOwners = 0
    /// Keyboard visibility: the capsule's 58pt tab-bar clearance only makes
    /// sense while the tab bar is visible. With the keyboard up the tab bar
    /// is covered, so the capsule hugs the keyboard instead of floating
    /// mid-list above a phantom bar.
    @State private var keyboardUp = false

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
        // The Scarlet Presence: a floating capsule on LIST screens of the
        // non-Talk tabs. Screens that own their bottom edge (open chat
        // thread, open email, open calendar event) broadcast ownership and
        // the capsule yields — it never covers a compose bar or action bar.
        .overlay(alignment: .bottom) {
            if tab != .talk && !draftSheetVisible && bottomOwners == 0 {
                ScarletPresenceView(convo: convo, goToTalk: { tab = .talk })
                    .padding(.bottom, keyboardUp ? 8 : 58)   // above tab bar / hugging keyboard
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIResponder.keyboardWillShowNotification)) { _ in keyboardUp = true }
        .onReceive(NotificationCenter.default.publisher(
            for: UIResponder.keyboardWillHideNotification)) { _ in keyboardUp = false }
        .animation(.easeInOut(duration: 0.2), value: tab)
        .animation(.easeInOut(duration: 0.2), value: bottomOwners)
        .animation(.easeInOut(duration: 0.2), value: keyboardUp)
        // Any DraftView sheet (voice-attach, reply, new-mail, channel) says
        // when it's up; the capsule yields the screen to it.
        .onReceive(NotificationCenter.default.publisher(for: .scarletDraftSheetVisible)) { note in
            draftSheetVisible = (note.userInfo?["visible"] as? Bool) ?? false
        }
        // Bottom-edge ownership: counted (clamped at 0) so overlapping
        // appear/disappear sequences between sibling screens balance out.
        .onReceive(NotificationCenter.default.publisher(for: .scarletBottomOwned)) { note in
            let owned = (note.userInfo?["owned"] as? Bool) ?? false
            bottomOwners = max(0, bottomOwners + (owned ? 1 : -1))
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
