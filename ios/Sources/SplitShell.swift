import SwiftUI

/// The large-screen shell: on iPad and Mac (regular horizontal size class)
/// Scarlet Talk becomes an Outlook-sibling — a dark-scarlet sidebar of
/// sections on the left and a big always-open working pane on the right.
/// iPhone keeps RootView's TabView; RootView renders THIS instead when
/// `horizontalSizeClass == .regular`. One codebase, presentation switches
/// by size class.
///
/// Column anatomy: a `NavigationSplitView` with a custom sidebar plus a
/// detail column. Inbox, Chats and Library are ALREADY self-contained
/// `NavigationStack`s with their own pushed details, so they render
/// full-width in the detail column — their internal list→reader push IS the
/// list-pane→reading-pane flow, and at iPad width the pushed reader is the
/// big pane. Talk gets centered (max ~700pt); Calendar and Settings manage
/// their own layouts.
///
/// IMPORTANT — this view is rendered INSIDE RootView's body, so RootView's
/// onReceive listeners (ask-about-email delivery, voice-draft sheet, draft
/// recovery, desk-mode polling) still run above it. This shell must NOT
/// duplicate that work; it only mirrors the *visual* "go to Talk" switch,
/// because RootView's `tab` state drives the compact TabView, not this
/// shell's selection.
struct SplitShell: View {
    /// TalkView reads it from the environment; declared here so the
    /// dependency is explicit (RootView already has it injected app-wide).
    @EnvironmentObject var session: AppSession
    /// Owned by RootView — the live conversation survives pane switches
    /// exactly as it survives tab switches on the phone.
    @ObservedObject var convo: Conversation

    /// Sidebar sections. Order here is also the ⌘1…⌘6 shortcut order.
    enum ShellSection: String, CaseIterable, Identifiable {
        case talk
        case inbox
        case calendar
        case chats
        case library
        case health
        case desk
        case settings

        var id: String { rawValue }

        var title: String {
            switch self {
            case .talk: return "Talk"
            case .inbox: return "Inbox"
            case .calendar: return "Calendar"
            case .chats: return "Chats"
            case .library: return "Library"
            case .health: return "Health"
            case .desk: return "Desk"
            case .settings: return "Settings"
            }
        }

        /// Mirrors RootView's tabItem icons so the two shells feel like one app.
        var icon: String {
            switch self {
            case .talk: return "waveform"
            case .inbox: return "envelope.fill"
            case .calendar: return "calendar"
            case .chats: return "bubble.left.and.bubble.right.fill"
            case .library: return "books.vertical.fill"
            case .health: return "heart.fill"
            case .desk: return "checklist"
            case .settings: return "gearshape.fill"
            }
        }

        /// Hardware-keyboard shortcut: ⌘1…⌘6 in sidebar order.
        var shortcutKey: KeyEquivalent {
            switch self {
            case .talk: return "1"
            case .inbox: return "2"
            case .calendar: return "3"
            case .chats: return "4"
            case .library: return "5"
            case .health: return "6"
            case .desk: return "7"
            case .settings: return "8"
            }
        }
    }

    @State private var section: ShellSection = .talk
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// Unified-inbox badge counts — same shared store as the phone's tab
    /// badges (RootView's backstop loop refreshes it above this shell), so
    /// the sidebar and the tab bar always tell one story.
    @ObservedObject private var counts = InboxCounts.shared

    private let scarletRose = Color(red: 1, green: 0.35, blue: 0.42)

    /// Byte-identical to RootView's Talk-screen ambient focus line, so the
    /// server sees the same focus regardless of which shell is presenting.
    private static let talkFocus =
        "[FOCUS] Ido is on the Talk screen, in live conversation. No item focused."

    /// The main (top) sidebar group; Settings renders separately at the
    /// bottom of the sidebar.
    private var mainSections: [ShellSection] {
        [.talk, .inbox, .calendar, .chats, .library, .health, .desk]
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 250)
                // The sidebar is fully custom (brand header + rows) — no
                // system bar on top of it.
                .toolbar(.hidden, for: .navigationBar)
        } detail: {
            detailColumn
        }
        .navigationSplitViewStyle(.balanced)
        .tint(scarletRose)
        // Visual mirrors of RootView's cross-screen wiring. RootView still
        // OWNS the behavior behind these notifications (waking her,
        // delivering the question, presenting the draft sheet); this shell
        // only brings the Talk pane forward, since RootView's `tab` state
        // doesn't drive this presentation.
        .onReceive(NotificationCenter.default.publisher(for: .scarletGoToTalk)) { _ in
            section = .talk
        }
        .onReceive(NotificationCenter.default.publisher(for: .scarletAskAboutEmail)) { _ in
            section = .talk
        }
        // Returning to Talk re-reports its ambient focus (the other panes
        // report their own from their onAppears, exactly as on the phone).
        .onChange(of: section) { _, newSection in
            if newSection == .talk { convo.setFocus(Self.talkFocus) }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Brand header — same thin tracked wordmark as the Talk screen.
            Text("SCARLET")
                .font(.system(size: 17, weight: .thin))
                .tracking(7)
                .foregroundStyle(Color(red: 0.98, green: 0.92, blue: 0.92))
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 16)

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(mainSections) { s in
                        sidebarRow(s)
                    }
                }
                .padding(.horizontal, 10)
            }

            Spacer(minLength: 0)

            VStack(spacing: 12) {
                sidebarRow(.settings)
                    .padding(.horizontal, 10)
                // On big screens she lives in the corner, always: the same
                // self-contained presence capsule the phone embeds per list
                // screen, pinned here so she's visible from every pane.
                // (List panes keep their own embedded capsule too — see the
                // compatibility note in the type doc above.)
                ScarletPresenceView(convo: convo)
                    .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(ScarletBackground().ignoresSafeArea())
    }

    /// One sidebar row: icon + label, rose selection pill, ⌘n shortcut.
    private func sidebarRow(_ s: ShellSection) -> some View {
        Button {
            section = s
        } label: {
            HStack(spacing: 11) {
                Image(systemName: s.icon)
                    .font(.system(size: 15))
                    .frame(width: 24)
                Text(s.title)
                    .font(.system(size: 15, weight: section == s ? .semibold : .regular))
                Spacer(minLength: 0)
                // Unread bubble, hidden at zero — mirrors the phone's tab
                // badges (Inbox = Amwell focused, Chats = everything else).
                UnreadCountBadge(count: sidebarBadge(s))
            }
            .foregroundStyle(section == s ? .white : .white.opacity(0.72))
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(section == s ? scarletRose.opacity(0.26) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .stroke(section == s ? scarletRose.opacity(0.55) : Color.clear,
                        lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(s.shortcutKey, modifiers: .command)
    }

    /// Which unread count a sidebar row wears — identical numbers to the
    /// phone's tab badges, so the two shells never disagree.
    private func sidebarBadge(_ s: ShellSection) -> Int {
        switch s {
        case .inbox: return counts.inboxBadge
        case .chats: return counts.chatsBadge
        default: return 0
        }
    }

    // MARK: - Detail column

    /// Section hosting. A plain switch is deliberate: the section views
    /// re-`.task` on appear by design (that's their refresh path on the
    /// phone's TabView too), and the Conversation lives above this shell so
    /// nothing that matters is torn down by switching.
    @ViewBuilder
    private var detailColumn: some View {
        switch section {
        case .talk:
            // The one-pager, centered like a sheet of paper on the desk —
            // full-width Talk on a 13" screen reads as stretched.
            ZStack {
                ScarletBackground().ignoresSafeArea()
                TalkView(convo: convo)
                    .frame(maxWidth: 700)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .toolbar(.hidden, for: .navigationBar)
        case .inbox:
            // Self-contained NavigationStack: list full-width, pushed reader
            // becomes the big reading pane. Zero rewrites.
            InboxView()
                .environmentObject(convo)
        case .calendar:
            // Manages its own layout (week strip + agenda; detail is a sheet).
            CalendarView()
                .environmentObject(convo)
                .toolbar(.hidden, for: .navigationBar)
        case .chats:
            // Self-contained NavigationStack (channel lists + pushed threads).
            ChatsView()
                .environmentObject(convo)
        case .library:
            // Self-contained NavigationStack (shelves + viewers).
            LibraryView()
                .environmentObject(convo)
        case .health:
            HealthView()
                .environmentObject(convo)
        case .desk:
            // Self-contained (Reminders + Apple Notes; serif reading sheet).
            DeskView()
                .environmentObject(convo)
        case .settings:
            // Has its own NavigationStack and title bar. As a detail column there
            // is nothing to dismiss, so suppress the (otherwise dead) Done button.
            SettingsView(presentedAsSheet: false)
                .background(ScarletBackground().ignoresSafeArea())
        }
    }
}
