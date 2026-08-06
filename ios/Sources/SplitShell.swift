import SwiftUI

/// The large-screen shell: on iPad and Mac (regular horizontal size class)
/// Scarlet Talk becomes an Outlook-sibling — a dark-scarlet sidebar of
/// sections on the left and a big always-open working pane on the right.
/// iPhone keeps RootView's TabView; RootView renders THIS instead when
/// `horizontalSizeClass == .regular`. One codebase, presentation switches
/// by size class.
///
/// Sections and their order come from the shared `AppSection` catalog +
/// `SectionOrderStore`, the SAME source the phone tabs use — so a reorder in
/// Settings reflows both surfaces identically. Settings is pinned to the
/// bottom of the sidebar (Preferences lives inside it).
///
/// IMPORTANT — this view is rendered INSIDE RootView's body, so RootView's
/// onReceive listeners (ask-about-email delivery, voice-draft sheet, draft
/// recovery, desk-mode polling) still run above it. This shell must NOT
/// duplicate that work; it only mirrors the *visual* "go to Talk" switch.
struct SplitShell: View {
    /// TalkView reads it from the environment; declared here so the
    /// dependency is explicit (RootView already has it injected app-wide).
    @EnvironmentObject var session: AppSession
    /// Owned by RootView — the live conversation survives pane switches
    /// exactly as it survives tab switches on the phone.
    @ObservedObject var convo: Conversation
    /// Ido's chosen section order — the same instance the phone tabs use.
    @ObservedObject var sections: SectionOrderStore

    @State private var section: AppSection = .talk

    private let scarletRose = Color(red: 1, green: 0.35, blue: 0.42)

    /// Byte-identical to RootView's Talk-screen ambient focus line, so the
    /// server sees the same focus regardless of which shell is presenting.
    private static let talkFocus =
        "[FOCUS] Ido is on the Talk screen, in live conversation. No item focused."

    var body: some View {
        // Deterministic two-column layout — NOT a NavigationSplitView.
        //
        // ROOT CAUSE of the "focus → dead sidebar" regression: the shell used
        // to be a `NavigationSplitView(.balanced)` whose *managed sidebar
        // column* held these custom buttons, while the *detail column* hosted a
        // section view that owns its OWN `NavigationStack` (InboxView,
        // ChatsView, LibraryView, …) and pushes a reader via `NavigationLink`.
        // On iPad/Mac-Catalyst, driving detail navigation from inside a
        // split view's detail while the sidebar is a fully-custom button list
        // makes the split view's column management contend with the inner
        // stack's pushes: after Ido opens an email/chat/item (or a focus action
        // brings a detail forward), the balanced style collapses / steals
        // hit-testing from the sidebar column — and because the sidebar's
        // system navigation bar is hidden (`.toolbar(.hidden)`), there is NO
        // toggle left to bring it back. The section buttons go dead with no
        // recovery affordance: a true dead end.
        //
        // The sidebar here is 100% custom (brand header + our own selection
        // pills + manual `section` state) — NavigationSplitView contributed
        // nothing but that fragile auto-collapse. Laying the two panes out as
        // plain HStack siblings makes the sidebar a first-class view that can
        // never be collapsed, covered, or drained of hit-testing by whatever
        // the detail's inner NavigationStack pushes. The sidebar is ALWAYS
        // tappable, regardless of what's open on the right. (SplitShell only
        // ever renders at `horizontalSizeClass == .regular`, so a fixed-width
        // sidebar + flexible detail is always the correct geometry; narrow
        // multitasking widths fall back to RootView's phone TabView.)
        HStack(spacing: 0) {
            sidebar
                .frame(width: 210)
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 0.5)
                .ignoresSafeArea()
            detailColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .tint(scarletRose)
        // Visual mirrors of RootView's cross-screen wiring. RootView still
        // OWNS the behavior behind these notifications; this shell only brings
        // the Talk pane forward, since RootView's `tab` state doesn't drive
        // this presentation.
        .onReceive(NotificationCenter.default.publisher(for: .scarletGoToTalk)) { _ in
            section = .talk
        }
        .onReceive(NotificationCenter.default.publisher(for: .scarletAskAboutEmail)) { _ in
            section = .talk
        }
        .onChange(of: section) { _, newSection in
            if newSection == .talk { convo.setFocus(Self.talkFocus) }
        }
        .task { await sections.refresh() }
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
                    ForEach(Array(sections.order.enumerated()), id: \.element) { idx, s in
                        sidebarRow(s, index: idx)
                    }
                }
                .padding(.horizontal, 10)
            }

            Spacer(minLength: 0)

            VStack(spacing: 12) {
                sidebarRow(.settings, index: nil)
                    .padding(.horizontal, 10)
                // On big screens she lives in the corner, always.
                ScarletPresenceView(convo: convo)
                    .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(ScarletBackground().ignoresSafeArea())
    }

    /// One sidebar row: icon + label, rose selection pill. The first nine
    /// sections get a ⌘1…⌘9 hardware shortcut, in Ido's chosen order.
    private func sidebarRow(_ s: AppSection, index: Int?) -> some View {
        let row = Button {
            section = s
        } label: {
            HStack(spacing: 11) {
                Image(systemName: s.icon)
                    .font(.system(size: 15))
                    .frame(width: 24)
                Text(s.title)
                    .font(.system(size: 16, weight: section == s ? .semibold : .regular))
                Spacer(minLength: 0)
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

        return Group {
            if let i = index, i < 9, let key = KeyEquivalent(digit: i + 1) {
                row.keyboardShortcut(key, modifiers: .command)
            } else {
                row
            }
        }
    }

    // MARK: - Detail column

    /// Section hosting. A plain switch is deliberate: the section views
    /// re-`.task` on appear by design (their refresh path on the phone too),
    /// and the Conversation lives above this shell so nothing that matters is
    /// torn down by switching. Talk, Calendar and Settings get bespoke
    /// framing; everything else uses the shared `destination` builder.
    @ViewBuilder
    private var detailColumn: some View {
        switch section {
        case .talk:
            // Centered like a sheet of paper on the desk — full-width Talk on a
            // 13" screen reads as stretched.
            ZStack {
                ScarletBackground().ignoresSafeArea()
                TalkView(convo: convo)
                    .frame(maxWidth: 700)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .toolbar(.hidden, for: .navigationBar)
        case .calendar:
            CalendarView()
                .environmentObject(convo)
                .toolbar(.hidden, for: .navigationBar)
        case .settings:
            SettingsView(presentedAsSheet: false)
                .background(ScarletBackground().ignoresSafeArea())
        default:
            // Self-contained sections (their own NavigationStack / layout).
            // Uniform convo injection matches the phone shell.
            section.destination(convo: convo)
                .environmentObject(convo)
        }
    }
}

/// ⌘1…⌘9 from a small integer, without force-unwrapping a Character.
private extension KeyEquivalent {
    init?(digit: Int) {
        guard (1...9).contains(digit), let ch = String(digit).first else { return nil }
        self = KeyEquivalent(ch)
    }
}
