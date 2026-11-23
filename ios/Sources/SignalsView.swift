import SwiftUI

/// The unified "All new" inbox — the native evolution of the web app's
/// Signals page. One list of every OPEN item across Outlook (Amwell focused),
/// Gmail, Teams, WhatsApp and iMessage, newest first, straight from
/// `op=inbox` (`inbound_events` — the same store the voice sweep reads via
/// `inbox_overview`), so what Scarlet says and what Ido sees are one truth.
///
/// Actions are the app's EXISTING flows, reused verbatim — never forked:
/// - Reply opens the same DraftView draft loop every other entry point uses,
///   bound to the item by its `event_id` (exactly how the web Signals reader
///   and the voice sweep's `compose_draft original_event_id` bind).
/// - Archive is `op=inbox_archive` — the REAL mailbox archive (Outlook move /
///   Gmail INBOX-label strip). An item only leaves once the server said ok;
///   a failure puts it back with an honest message, never cosmetic cleanup.
/// - "Later" files a reminder via `op=reminder_add` (the Desk's own add op).
/// Swipes mirror Apple Mail: trailing full-swipe = Archive, leading = Later.

// MARK: - Badge counts (`op=inbox_counts`)

/// One process-wide store for the unread/open counts that drive every badge:
/// the Inbox and Chats tab items, the Chats source segments, and the
/// SplitShell sidebar. Truthful by construction — numbers only ever come from
/// the server (`inbound_events`, unarchived), never from local guesses; on a
/// failed fetch the last real numbers stay up rather than inventing zeros.
///
/// Polling piggybacks RootView's existing ~2s backstop loop (`refreshIfStale`
/// gates it to ~30s) — no timer of its own, per the house rule.
@MainActor
final class InboxCounts: ObservableObject {
    static let shared = InboxCounts()

    struct SourceCount {
        var unread = 0
        var open = 0
    }

    @Published private(set) var totalUnread = 0
    @Published private(set) var totalOpen = 0
    /// source ("outlook_mail" | "gmail" | "teams" | "whatsapp" | "imessage")
    /// → its counts. Sources the server didn't mention have nothing waiting.
    @Published private(set) var bySource: [String: SourceCount] = [:]

    /// Stale-gate for the piggybacked poll. Advanced on every ATTEMPT (not
    /// just success) so a dead network is retried every ~30s, not every 2s.
    private var lastAttempt: Date?
    private var inFlight = false
    private static let minInterval: TimeInterval = 30

    private init() {}

    func unread(_ source: String) -> Int { bySource[source]?.unread ?? 0 }

    /// The Inbox (Amwell) tab's badge — Outlook focused unread.
    var inboxBadge: Int { unread("outlook_mail") }

    /// The Chats tab's badge — every source the Inbox tab doesn't carry
    /// (Teams / WhatsApp / iMessage / Gmail, all surfaced by the Chats hub's
    /// All-new list). The two tab badges always sum to total_unread — no
    /// double counting, no gaps.
    var chatsBadge: Int { max(0, totalUnread - inboxBadge) }

    /// Called from RootView's existing backstop loop — turns its ~2s cadence
    /// into a ~30s counts poll without adding a timer anywhere.
    func refreshIfStale() async {
        if let last = lastAttempt, Date().timeIntervalSince(last) < Self.minInterval { return }
        await refresh()
    }

    /// One cheap `op=inbox_counts` fetch (same token auth as every other op).
    func refresh() async {
        guard !inFlight, TokenStore.token != nil else { return }
        inFlight = true
        lastAttempt = Date()
        defer { inFlight = false }
        guard let data = try? await ChatsAPI.request("op=inbox_counts", method: "GET"),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let totalUnreadValue = obj["total_unread"] as? Int,
              let totalOpenValue = obj["total_open"] as? Int else { return }
        var sources: [String: SourceCount] = [:]
        for (key, value) in (obj["by_source"] as? [String: [String: Any]]) ?? [:] {
            sources[key] = SourceCount(unread: (value["unread"] as? Int) ?? 0,
                                       open: (value["open"] as? Int) ?? 0)
        }
        totalUnread = totalUnreadValue
        totalOpen = totalOpenValue
        bySource = sources
    }
}

/// iOS-convention red count bubble, hidden at zero — worn by the Chats
/// source segments and the SplitShell sidebar rows. (The phone tab items use
/// the system `.badge(_:)`, which is the same convention natively.)
struct UnreadCountBadge: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text(count > 99 ? "99+" : "\(count)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .frame(minWidth: 16, minHeight: 16)
                .background(Capsule().fill(Color.red))
        }
    }
}

// MARK: - Wire type (`op=inbox` rows)

/// One open item, as `op=inbox` returns it (an `inbound_events` row).
struct SignalItem: Identifiable {
    let id: String
    let source: String
    let sender: String
    let preview: String
    let receivedAt: Date?
    var read: Bool
    let bucket: String

    /// `draft_compose` channel for this source — the web Signals page's
    /// DRAFT_SRC map, verbatim. nil → the source can't be replied to.
    var draftChannel: String? {
        switch source {
        case "outlook_mail": return "email_outlook"
        case "gmail": return "email_gmail"
        case "whatsapp", "imessage", "teams": return source
        default: return nil
        }
    }

    var displaySource: String {
        switch source {
        case "outlook_mail": return "Amwell"
        case "gmail": return "Gmail"
        case "teams": return "Teams"
        case "whatsapp": return "WhatsApp"
        case "imessage": return "iMessage"
        case "calendar": return "Calendar"
        default: return source
        }
    }

    /// The identity glyph on the avatar's mini-disc (ChatListRow's pattern).
    var sourceIcon: String {
        switch source {
        case "outlook_mail", "gmail": return "envelope.fill"
        case "calendar": return "calendar"
        default: return ChatChannel(rawValue: source)?.icon ?? "bell.fill"
        }
    }

    /// Each source keeps its own brand color, same as everywhere else in the
    /// app: Outlook blue, Gmail red, and the chat channels' own accents.
    var sourceTint: Color {
        switch source {
        case "outlook_mail": return OutlookStyle.primaryBlue
        case "gmail": return Color(red: 0.918, green: 0.263, blue: 0.208) // Gmail #EA4335
        case "calendar": return Color(red: 0.83, green: 0.55, blue: 0.22)
        default: return ChatChannel(rawValue: source)?.accent ?? Color.gray
        }
    }
}

// MARK: - Model

@MainActor
final class SignalsModel: ObservableObject {
    @Published var items: [SignalItem] = []
    @Published var loading = false
    @Published var errorText = ""
    /// When the rows last came back from the server — drives the header's
    /// "updated Xm ago" stamp (the anti-spinner, like Chats and Inbox).
    @Published var updatedAt: Date?
    /// A draft in review/writing waiting for Ido — the "Waiting on you"
    /// section at the top of the list (§5; pin drafts land here too).
    @Published var waitingDraft: DraftFlowAPI.WaitingDraft?

    /// Monotonic load token: a slow fetch landing after a newer one is
    /// dropped (InboxModel / ChatListModel discipline).
    private var loadGeneration = 0
    /// Rows archived locally: a refresh landing while the server-side move
    /// settles must not resurrect them (InboxModel's pendingArchiveIds).
    private var pendingArchiveIds: Set<String> = []

    func load() async {
        guard TokenStore.token != nil else {
            items = []
            errorText = "Locked — unlock Scarlet to see what's new."
            return
        }
        if items.isEmpty { loading = true }
        errorText = ""
        loadGeneration += 1
        let generation = loadGeneration
        defer { if generation == loadGeneration { loading = false } }
        do {
            let data = try await ChatsAPI.request("op=inbox", method: "GET")
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            // Server order is the product order: primary newest-first, junk
            // blasts at the bottom — keep it. Row ids MUST be unique (the
            // diffable List traps on repeats — the crash class already fixed
            // in Chats/Inbox), so keep only the first of each id.
            var seen = Set<String>()
            let fetched: [SignalItem] = ((obj["events"] as? [[String: Any]]) ?? []).compactMap { e in
                // inbound_events.id is a BIGINT — JSON delivers it as a
                // NUMBER, and an `as? String` cast alone silently dropped
                // EVERY row (the "All clear" lie under a 99+ badge).
                guard let id = (e["id"] as? String) ?? (e["id"] as? NSNumber)?.stringValue,
                      !id.isEmpty else { return nil }
                guard seen.insert(id).inserted else { return nil }
                let source = (e["source"] as? String) ?? ""
                // news_breaking is a push, never a message (spec rule), and
                // calendar events live on the Calendar page — op=inbox_counts
                // excludes both, so the list must too or the numbers and the
                // rows would tell different stories.
                guard source != "news_breaking", source != "outlook_calendar" else { return nil }
                return SignalItem(
                    id: id,
                    source: source,
                    sender: (e["sender"] as? String) ?? "",
                    preview: (e["preview"] as? String) ?? "",
                    receivedAt: ChatDates.parse(e["received_at"]),
                    read: (e["read_at"] as? String) != nil,
                    bucket: (e["bucket"] as? String) ?? "primary"
                )
            }
            guard generation == loadGeneration else { return }
            let listed = Set(fetched.map { $0.id })
            // Forget archives the server has already applied; keep hiding the
            // ones it hasn't caught up with yet.
            pendingArchiveIds.formIntersection(listed)
            var rows = fetched
            rows.removeAll { pendingArchiveIds.contains($0.id) }
            withAnimation(.snappy) { items = rows }
            updatedAt = Date()
            // "Waiting on you": one cheap check per refresh, never blocking
            // the list itself. Failure just means no section.
            waitingDraft = await DraftFlowAPI.fetchWaiting()
        } catch {
            guard generation == loadGeneration else { return }
            errorText = "Couldn't reach the inbox — check your connection."
        }
    }

    /// Optimistic archive → the REAL archive. `op=inbox_archive` moves the
    /// mail in Outlook / strips Gmail's INBOX label; chat mirrors just clear
    /// (they're read-only upstream). ok:false means the mailbox move failed —
    /// the row comes BACK with an honest message. Idempotent server-side, so
    /// a double-tap is safe.
    func archive(_ item: SignalItem) {
        let index = items.firstIndex { $0.id == item.id }
        if let index {
            _ = withAnimation(.snappy) { items.remove(at: index) }
        }
        pendingArchiveIds.insert(item.id)
        Task {
            do {
                let data = try await ChatsAPI.request("op=inbox_archive", method: "POST",
                                                      body: ["ids": [item.id]])
                let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                guard (obj?["ok"] as? Bool) == true else { throw URLError(.badServerResponse) }
                // The badge numbers just changed for real — reflect it now.
                await InboxCounts.shared.refresh()
            } catch {
                pendingArchiveIds.remove(item.id)
                let at = min(index ?? items.count, items.count)
                withAnimation(.snappy) { items.insert(item, at: at) }
                errorText = "Couldn't archive that one — it's back in the list."
            }
        }
    }

    /// READ-FIRST state discipline (spec §1): opening an item marks it READ
    /// and nothing else — only starting an actual reply marks it acted.
    /// Local flip first so the row un-bolds instantly; the mirrors are
    /// fire-and-forget (the next refresh reconciles either way).
    func markRead(_ item: SignalItem) {
        if let i = items.firstIndex(where: { $0.id == item.id }) { items[i].read = true }
        Task {
            _ = try? await ChatsAPI.request("op=inbox_read", method: "POST",
                                            body: ["ids": [item.id]])
            await InboxCounts.shared.refresh()
        }
    }

    /// Ido chose a reply mode — NOW the item counts as acted on.
    func markActed(_ item: SignalItem) {
        Task {
            _ = try? await ChatsAPI.request("op=inbox_acted", method: "POST",
                                            body: ["ids": [item.id]])
        }
    }

    /// "Later": file a reminder for this item (`op=reminder_add` — the same
    /// op the Desk uses) and mark it read. The item stays OPEN until he
    /// archives it — a reminder is a promise, not a cleanup.
    func later(_ item: SignalItem) {
        if let i = items.firstIndex(where: { $0.id == item.id }) { items[i].read = true }
        Task {
            let who = item.sender.isEmpty ? item.displaySource : item.sender
            let title = String("Follow up: \(who) — \(item.preview)".prefix(200))
            do {
                let data = try await ChatsAPI.request("op=reminder_add", method: "POST",
                                                      body: ["title": title,
                                                             "notes": String(item.preview.prefix(1000))])
                let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                guard (obj?["ok"] as? Bool) == true else { throw URLError(.badServerResponse) }
                _ = try? await ChatsAPI.request("op=inbox_read", method: "POST",
                                                body: ["ids": [item.id]])
                await InboxCounts.shared.refresh()
            } catch {
                errorText = "Couldn't file that reminder — try again."
            }
        }
    }
}

// MARK: - List view (embedded in the Chats hub's "All" segment)

struct SignalsListView: View {
    @ObservedObject var model: SignalsModel
    @EnvironmentObject private var convo: Conversation
    @ObservedObject private var counts = InboxCounts.shared
    /// ONE sheet on this view (the Catalyst single-presentation rule): the
    /// review surface for a "Waiting on you" draft, driven by `.sheet(item:)`.
    /// (Replies now go READ VIEW → chooser → review, never straight from a
    /// row tap — spec §1: tapping an item NEVER creates a draft.)
    enum ListSheet: Identifiable {
        case waitingDraft(String)   // draft id — attach to the active draft
        var id: String {
            switch self { case .waitingDraft(let id): return "waiting-\(id)" }
        }
    }
    @State private var activeSheet: ListSheet?

    private let scarletRose = Color(red: 1, green: 0.35, blue: 0.42)

    var body: some View {
        content
            .reportsModalPresence(activeSheet != nil)
            .sheet(item: $activeSheet, onDismiss: {
                Task { await model.load() }
            }) { sheet in
                switch sheet {
                case .waitingDraft:
                    // The standard review surface, attached to the draft that
                    // is already waiting server-side (pin drafts included).
                    DraftView(seed: nil, attachToActive: true)
                        .environmentObject(convo)   // DraftView hard-requires it
                        .preferredColorScheme(.dark)
                }
            }
            // Piggyback reconcile: when the badge poll sees the store change,
            // the visible list catches up too — no timer of its own.
            .onChange(of: counts.totalOpen) { _, _ in
                Task { await model.load() }
            }
    }

    @ViewBuilder
    private var content: some View {
        if model.loading && model.items.isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                Text("Checking what's new…")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.items.isEmpty && !model.errorText.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.title2).foregroundStyle(.secondary)
                Text(model.errorText)
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try again") { Task { await model.load() } }
                    .buttonStyle(.bordered)
                    .tint(scarletRose)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.items.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.seal")
                    .font(.title2).foregroundStyle(.secondary)
                Text("All clear — nothing waiting.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            list
        }
    }

    /// The Focused/Other split (Ido 2026-08-10 — the Outlook-Focused
    /// equivalent across every channel): 'junk'-bucket chatter — big WhatsApp
    /// groups, low-value blasts — collapses into Other and never masquerades
    /// as needing attention.
    private var focusedItems: [SignalItem] { model.items.filter { $0.bucket != "junk" } }
    private var otherItems: [SignalItem] { model.items.filter { $0.bucket == "junk" } }
    @State private var otherExpanded = false

    private var list: some View {
        List {
            if !model.errorText.isEmpty {
                Text(model.errorText)
                    .font(.footnote)
                    .foregroundStyle(Color(red: 0.91, green: 0.69, blue: 0.31))
                    .listRowBackground(Color.clear)
            }
            // "Waiting on you" (§5): drafts in review/saved sit ABOVE the new
            // mail — his own unfinished decisions outrank fresh arrivals.
            if let waiting = model.waitingDraft {
                Section {
                    Button {
                        activeSheet = .waitingDraft(waiting.id)
                    } label: {
                        WaitingDraftRow(draft: waiting)
                    }
                    .buttonStyle(.plain)
                    .listRowSeparatorTint(.white.opacity(0.12))
                } header: {
                    Text("WAITING ON YOU")
                        .font(.system(size: 12, weight: .semibold))
                        .kerning(0.5)
                        .foregroundStyle(scarletRose.opacity(0.9))
                }
            }
            Section {
                ForEach(focusedItems) { item in
                    signalRow(item)
                }
            } header: {
                HStack(spacing: 8) {
                    Text("FOCUSED")
                        .font(.system(size: 12, weight: .semibold))
                        .kerning(0.5)
                        .foregroundStyle(.white.opacity(0.7))
                    let newCount = focusedItems.filter { !$0.read }.count
                    if newCount > 0 {
                        Text("\(newCount) new")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(OutlookStyle.accentBlue))
                    }
                    Spacer()
                }
            }
            if !otherItems.isEmpty {
                Section {
                    Button {
                        withAnimation { otherExpanded.toggle() }
                    } label: {
                        HStack(spacing: 8) {
                            Text("OTHER — LARGE GROUPS & FEEDS")
                                .font(.system(size: 12, weight: .semibold))
                                .kerning(0.5)
                            Text("\(otherItems.count)")
                                .font(.system(size: 11, weight: .semibold))
                            Spacer()
                            Image(systemName: otherExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(.white.opacity(0.45))
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    if otherExpanded {
                        ForEach(otherItems) { item in
                            signalRow(item)
                                .opacity(0.75)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable {
            await model.load()
            await InboxCounts.shared.refresh()
        }
    }

    /// One row with the shared tap + swipe behavior (identical in both
    /// sections — the approve-loop consistency rule). READ-FIRST (spec §1):
    /// the tap opens the full READ view — it NEVER starts a draft; list
    /// swipes stay triage-only.
    private func signalRow(_ item: SignalItem) -> some View {
        // Archive is the SAME gesture as the Amwell inbox everywhere
        // (OutlookArchiveSwipe): full-bleed green bar, glyph pops at the 45%
        // commit, row flies off. The consistency rule — one look per action.
        OutlookArchiveSwipe(
            baseBackground: Color.clear,
            onArchive: { model.archive(item) }
        ) {
            ZStack {
                // ZStack + zero-opacity link (InboxView's pattern): full
                // NavigationLink behavior without the disclosure chevron.
                NavigationLink {
                    SignalReadView(item: item, model: model)
                        // Catalyst drops @EnvironmentObject across the
                        // NavigationLink boundary — re-inject (crash class
                        // already fixed in Inbox/Chats).
                        .environmentObject(convo)
                } label: {
                    EmptyView()
                }
                .opacity(0)
                SignalRow(item: item)
            }
        }
        .listRowSeparatorTint(.white.opacity(0.12))
        // Leading files it for later (a reminder, not a cleanup) — stays on
        // the system swipe, exactly like the inbox's leading flag/read.
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                model.later(item)
            } label: {
                Label("Later", systemImage: "clock.fill")
            }
            .tint(OutlookStyle.flagOrange)
        }
    }
}

// MARK: - Row

/// One unified-inbox row, in the house list anatomy (InboxRow / ChatListRow):
/// unread rose dot at the left edge, initials avatar wearing the source's
/// colored mini-disc glyph, sender + relative age on the first line, the
/// source's name in its brand tint, then a two-line preview.
struct SignalRow: View {
    let item: SignalItem

    private let scarletRose = Color(red: 1, green: 0.35, blue: 0.42)

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Unread marker, centered on the avatar (InboxRow's geometry).
            Circle()
                .fill(scarletRose)
                .frame(width: 8, height: 8)
                .padding(.top, 18)
                .opacity(item.read ? 0 : 1)
            badgedAvatar
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(senderName)
                        .font(.system(size: 15, weight: item.read ? .semibold : .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    if let d = item.receivedAt {
                        Text(ChatTimeFormat.agoLabel(d))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(item.displaySource)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(item.sourceTint)
                Text(item.preview)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
        }
        .padding(.vertical, 6)
    }

    private var senderName: String {
        item.sender.isEmpty ? item.displaySource : item.sender
    }

    /// The source identity, worn subtly — ChatListRow's badged avatar,
    /// with the sender-initials circle underneath.
    private var badgedAvatar: some View {
        ZStack(alignment: .bottomTrailing) {
            SenderAvatar(name: senderName, email: "", size: 40)
            Circle()
                .fill(item.sourceTint)
                .frame(width: 17, height: 17)
                .overlay(
                    Image(systemName: item.sourceIcon)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                )
                .overlay(Circle().stroke(Color.black.opacity(0.55), lineWidth: 1.5))
                .offset(x: 3, y: 3)
        }
    }
}

// MARK: - Read view (READ FIRST — the item in full, then the reply chooser)

/// Keep byte-identical to ChatsView's allNewFocus (it's private there): the
/// read view restores this exact line on the way out, stale-guarded.
private let signalsBrowsingFocus =
    "[FOCUS] Ido is browsing his unified All-new inbox — every open message across Amwell Outlook, Gmail, Teams, WhatsApp and iMessage. No single item open."

/// The full READ view for a unified-inbox item (spec §1/§3): tapping a row
/// lands HERE — never in a draft. Email signals load their complete message
/// (op=inbox_full, same renderer as the Amwell reader); chat signals show the
/// message big and bidirectional. "Reply" opens the three-option chooser —
/// bottom sheet on iPhone, menu on iPad/Mac — and every option lands in the
/// standard review surface.
struct SignalReadView: View {
    let item: SignalItem
    @ObservedObject var model: SignalsModel
    @EnvironmentObject private var convo: Conversation
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var hSize

    /// One fetched email, as `op=inbox_full` returns it.
    struct FullEmail {
        let subject: String
        let from: String
        let to: String
        let at: Date?
        let html: String
        let attachments: [EmailAttachment]
    }

    /// One attachment on a fetched email; `dataUrl` nil → too big to inline.
    struct EmailAttachment: Identifiable {
        let id = UUID()
        let name: String
        let size: Int
        let dataUrl: String?
    }

    @State private var email: FullEmail?
    @State private var emailFailed = false
    /// ONE sheet on this view (the Catalyst single-presentation rule):
    /// chooser, review surface, or attachment preview — one enum drives all.
    enum ReadSheet: Identifiable {
        case chooser
        case draft(ReplyMode)
        case preview(PreviewFile)
        var id: String {
            switch self {
            case .chooser: return "chooser"
            case .draft(let m): return "draft-\(m.rawValue)"
            case .preview(let f): return "preview-\(f.id)"
            }
        }
    }
    @State private var activeSheet: ReadSheet?
    /// The chooser's pick — presented from the sheet's onDismiss (the
    /// reliable Catalyst sheet-swap pattern; never two presentations at once).
    @State private var pendingMode: ReplyMode?
    /// In-app reading size (§5): default 17, A−/A+ steps to 19/21.
    @AppStorage("scarlet.readingSize") private var readingSize: Double = 17

    private let scarletRose = Color(red: 1, green: 0.35, blue: 0.42)

    private var isEmail: Bool {
        item.source == "outlook_mail" || item.source == "gmail"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(OutlookStyle.separator)
            if isEmail, let email, !email.attachments.isEmpty {
                attachmentsRow(email.attachments)
                Divider().overlay(OutlookStyle.separator)
            }
            bodyPane
            Divider().overlay(OutlookStyle.separator)
            actionBar
        }
        .background(OutlookStyle.background.ignoresSafeArea())
        .navigationTitle(item.displaySource)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(OutlookStyle.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .reportsModalPresence(activeSheet != nil)
        .sheet(item: $activeSheet, onDismiss: sheetClosed) { sheet in
            switch sheet {
            case .chooser:
                ReplyChooserView(recipient: senderName) { mode in
                    // Only remember the pick; the review surface presents
                    // from onDismiss — never two sheets in flight.
                    pendingMode = mode
                }
            case .draft(let mode):
                DraftView(seed: DraftSeed(
                    messageId: "",
                    fromName: item.sender,
                    fromEmail: "",
                    subject: email?.subject ?? "",
                    preview: item.preview,
                    eventId: item.id,
                    channel: item.draftChannel ?? "email_outlook"
                ), replyMode: mode)
                .environmentObject(convo)   // DraftView hard-requires it
                .preferredColorScheme(.dark)
            case .preview(let file):
                ZStack(alignment: .topLeading) {
                    QuickLookPreview(url: file.url)
                        .ignoresSafeArea()
                    Button {
                        activeSheet = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(Color.black.opacity(0.5)))
                    }
                    .padding(.top, 12)
                    .padding(.leading, 12)
                    .accessibilityLabel("Close attachment")
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(OutlookStyle.background)
                .preferredColorScheme(.dark)
            }
        }
        .task {
            FlightRecorder.note(screen: "signal-reader")
            // READ-FIRST: opening marks READ — and nothing else (spec §1).
            model.markRead(item)
            await fetchEmail()
        }
        .onAppear { convo.setFocus(readFocus) }
        .onDisappear {
            if convo.currentFocus == readFocus {
                convo.setFocus(signalsBrowsingFocus)
            }
        }
        // Work-surface keys (§5): R = reply chooser, E = archive; both are
        // silent twins of the visible buttons below.
        .background {
            Group {
                if item.draftChannel != nil {
                    Button("") { activeSheet = .chooser }
                        .keyboardShortcut("r", modifiers: [])
                }
                Button("") { archiveTapped() }
                    .keyboardShortcut("e", modifiers: [])
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    // MARK: header (sender card + reading-size control)

    private var senderName: String {
        item.sender.isEmpty ? item.displaySource : item.sender
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isEmail {
                Text(subjectText)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(subjectText.readingAlignment)
                    .frame(maxWidth: .infinity, alignment: subjectText.readingFrameAlignment)
                    .environment(\.layoutDirection, subjectText.layoutDir)
                    .lineLimit(3)
                    .truncationMode(.tail)
            }
            HStack(alignment: .center, spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    SenderAvatar(name: senderName, email: "", size: 40)
                    Circle()
                        .fill(item.sourceTint)
                        .frame(width: 17, height: 17)
                        .overlay(
                            Image(systemName: item.sourceIcon)
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white)
                        )
                        .overlay(Circle().stroke(Color.black.opacity(0.55), lineWidth: 1.5))
                        .offset(x: 3, y: 3)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(senderName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    HStack(spacing: 6) {
                        Text(item.displaySource)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(item.sourceTint)
                        if let d = item.receivedAt {
                            Text(ChatTimeFormat.agoLabel(d))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 8)
                if !isEmail {
                    readingSizeControl
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// A−/A+ (§5): the chat body's type size, remembered across launches.
    /// (Email bodies render in the shared HTML frame, which pinch-zooms.)
    private var readingSizeControl: some View {
        HStack(spacing: 0) {
            Button {
                readingSize = max(15, readingSize - 2)
            } label: {
                Text("A−").font(.system(size: 13, weight: .semibold))
                    .frame(width: 34, height: 28)
            }
            .disabled(readingSize <= 15)
            Divider().frame(height: 16).overlay(OutlookStyle.separator)
            Button {
                readingSize = min(25, readingSize + 2)
            } label: {
                Text("A+").font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 28)
            }
            .disabled(readingSize >= 25)
        }
        .foregroundStyle(.white.opacity(0.8))
        .background(OutlookStyle.surface, in: Capsule())
        .overlay(Capsule().stroke(OutlookStyle.separator, lineWidth: 1))
        .buttonStyle(.plain)
    }

    private var subjectText: String {
        if let s = email?.subject, !s.isEmpty { return s }
        return item.preview
    }

    // MARK: body

    @ViewBuilder
    private var bodyPane: some View {
        if isEmail {
            if let email {
                // The shared dark-mode-safe email frame — one renderer with
                // the Amwell reader, so the two readers never drift.
                MailBodyView(html: email.html)
            } else if emailFailed {
                VStack(spacing: 12) {
                    Text("Couldn't open this message.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Try again") {
                        emailFailed = false
                        Task { await fetchEmail() }
                    }
                    .buttonStyle(.bordered)
                    .tint(OutlookStyle.accentBlue)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            // Chat message: the words, big (≥17pt, user-scalable), each
            // paragraph in ITS OWN direction — Hebrew hugs the right, English
            // the left. Measure capped so long lines stay readable (§5).
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(item.preview.components(separatedBy: "\n").enumerated()),
                            id: \.offset) { _, line in
                        if line.trimmingCharacters(in: .whitespaces).isEmpty {
                            Color.clear.frame(height: 10)
                        } else {
                            Text(line)
                                .font(.system(size: readingSize))
                                .lineSpacing(4)
                                .foregroundStyle(.white.opacity(0.92))
                                .textSelection(.enabled)
                                .multilineTextAlignment(line.readingAlignment)
                                .frame(maxWidth: .infinity, alignment: line.readingFrameAlignment)
                                .environment(\.layoutDirection, line.layoutDir)
                        }
                    }
                    Text("The full conversation lives in the \(item.displaySource) tab.")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 18)
                }
                .padding(16)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: attachments (email only — inline data from op=inbox_full)

    private func attachmentsRow(_ attachments: [EmailAttachment]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { att in
                    Button {
                        openAttachment(att)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "paperclip")
                                .font(.system(size: 15))
                                .foregroundStyle(att.dataUrl == nil ? .gray : OutlookStyle.accentBlue)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(att.name)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: 170, alignment: .leading)
                                Text(att.dataUrl == nil
                                     ? "Too big here — open in the mail app"
                                     : ByteCountFormatter.string(fromByteCount: Int64(att.size),
                                                                 countStyle: .file))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 12).fill(OutlookStyle.surface))
                        .overlay(RoundedRectangle(cornerRadius: 12)
                            .stroke(OutlookStyle.separator, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(att.dataUrl == nil)
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 8)
    }

    /// data: URI → temp file (real filename, so QuickLook picks the right
    /// renderer) → the system viewer. Same isolation discipline as the
    /// Amwell reader: each open gets its own subfolder.
    private func openAttachment(_ att: EmailAttachment) {
        guard let dataUrl = att.dataUrl,
              let comma = dataUrl.firstIndex(of: ","),
              let data = Data(base64Encoded: String(dataUrl[dataUrl.index(after: comma)...]),
                              options: .ignoreUnknownCharacters) else { return }
        var clean = att.name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty || clean == "." || clean == ".." { clean = "attachment" }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sig-att-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(clean)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        activeSheet = .preview(PreviewFile(url: url))
    }

    // MARK: action bar (Reply · Archive · Later — triage verbs, one look)

    private var actionBar: some View {
        HStack(spacing: 10) {
            replyControl
            actionButton("Archive", icon: "archivebox.fill",
                         tint: OutlookStyle.archiveGreen) {
                archiveTapped()
            }
            actionButton("Later", icon: "clock.fill",
                         tint: OutlookStyle.flagOrange) {
                model.later(item)
                dismiss()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// The Reply control: iPhone opens the chooser as a bottom sheet;
    /// iPad/Mac offers the SAME three choices as a menu (§2, §5). A
    /// non-replyable source (calendar pushes) simply has no Reply.
    @ViewBuilder
    private var replyControl: some View {
        if item.draftChannel != nil {
            if hSize == .regular {
                ReplyChooserMenu(onChoose: { mode in choose(mode) }) {
                    replyLabel
                }
                .frame(maxWidth: .infinity)
            } else {
                Button {
                    activeSheet = .chooser
                } label: {
                    replyLabel
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var replyLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.system(size: 13, weight: .semibold))
            Text("Reply").font(.footnote.weight(.semibold))
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(OutlookStyle.primaryBlue, in: Capsule())
        .foregroundStyle(.white)
    }

    private func actionButton(_ label: String, icon: String, tint: Color,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                Text(label).font(.footnote.weight(.semibold))
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(OutlookStyle.surface, in: Capsule())
            .overlay(Capsule().stroke(OutlookStyle.separator, lineWidth: 1))
            .foregroundStyle(tint)
        }
    }

    private func archiveTapped() {
        model.archive(item)
        dismiss()
    }

    // MARK: chooser plumbing

    /// A mode was picked. From the menu (no sheet up) the review surface
    /// presents immediately; from the chooser sheet it presents on dismiss.
    private func choose(_ mode: ReplyMode) {
        model.markActed(item)
        if activeSheet == nil {
            activeSheet = .draft(mode)
        } else {
            pendingMode = mode
        }
    }

    private func sheetClosed() {
        if let mode = pendingMode {
            pendingMode = nil
            model.markActed(item)
            activeSheet = .draft(mode)
            return
        }
        // A closed review surface may have changed the waiting/read state.
        Task { await model.load() }
    }

    // MARK: fetch (email signals only)

    private func fetchEmail() async {
        guard isEmail, email == nil else { return }
        let encoded = ChatsAPI.encode(item.id)
        guard let data = try? await ChatsAPI.request("op=inbox_full&id=\(encoded)",
                                                     method: "GET"),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              obj["error"] == nil else {
            emailFailed = true
            return
        }
        let atts: [EmailAttachment] = ((obj["attachments"] as? [[String: Any]]) ?? [])
            .compactMap { a in
                guard let name = a["name"] as? String, !name.isEmpty else { return nil }
                return EmailAttachment(
                    name: name,
                    size: (a["size"] as? Int) ?? 0,
                    dataUrl: a["dataUrl"] as? String
                )
            }
        email = FullEmail(
            subject: (obj["subject"] as? String) ?? "",
            from: (obj["from"] as? String) ?? "",
            to: (obj["to"] as? String) ?? "",
            at: MailDates.parse(obj["at"] as? String),
            html: (obj["html"] as? String) ?? "",
            attachments: atts
        )
    }

    // MARK: focus

    /// Byte-identical on appear and disappear (built from the list row
    /// alone) — the stale-guard compares against it.
    private var readFocus: String {
        "[FOCUS] Ido is READING an inbound \(item.displaySource) item full-screen (read-first view).\n"
            + "from: \(item.sender)\n"
            + "source: \(item.source)\n"
            + "event_id: \(item.id)\n"
            + "preview: \(String(item.preview.prefix(280)))\n"
            + "He has NOT chosen to reply. If he asks to reply, the reply "
            + "chooser applies: Scarlet drafts it / he writes it himself / "
            + "he dictates what to say — never draft without his choice."
    }
}
