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
                guard let id = e["id"] as? String, !id.isEmpty else { return nil }
                guard seen.insert(id).inserted else { return nil }
                let source = (e["source"] as? String) ?? ""
                // news_breaking is a push, never a message (spec rule) —
                // op=inbox_counts already excludes it, so the list must too
                // or the numbers and the rows would tell different stories.
                guard source != "news_breaking" else { return nil }
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

    /// Reply-tap bookkeeping, exactly like the web Signals reader: opening
    /// the item marks it read, starting the reply marks it acted. Local flip
    /// first so the row un-bolds instantly; the mirrors are fire-and-forget
    /// (the next refresh reconciles either way).
    func markEngaged(_ item: SignalItem) {
        if let i = items.firstIndex(where: { $0.id == item.id }) { items[i].read = true }
        Task {
            _ = try? await ChatsAPI.request("op=inbox_read", method: "POST",
                                            body: ["ids": [item.id]])
            _ = try? await ChatsAPI.request("op=inbox_acted", method: "POST",
                                            body: ["ids": [item.id]])
            await InboxCounts.shared.refresh()
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
    /// reply draft window, driven by `.sheet(item:)`.
    @State private var replyItem: SignalItem?

    private let scarletRose = Color(red: 1, green: 0.35, blue: 0.42)

    var body: some View {
        content
            .reportsModalPresence(replyItem != nil)
            // The SAME drafting studio as every other entry point — seed mode
            // auto-composes on appear, revisions and Approve are untouched.
            // The event_id binds the draft to THIS conversation server-side
            // (true threaded Reply-All for mail, exact chat for the mirrors).
            .sheet(item: $replyItem, onDismiss: {
                Task { await model.load() }
            }) { item in
                DraftView(seed: DraftSeed(
                    messageId: "",
                    fromName: item.sender,
                    fromEmail: "",
                    subject: "",
                    preview: item.preview,
                    eventId: item.id,
                    channel: item.draftChannel ?? "email_outlook"
                ))
                .environmentObject(convo)   // DraftView hard-requires it; match every other call site
                .preferredColorScheme(.dark)
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
    /// sections — the approve-loop consistency rule).
    private func signalRow(_ item: SignalItem) -> some View {
        SignalRow(item: item)
            .contentShape(Rectangle())
            // Tap = react: open the reply draft bound to this item
            // (non-draftable sources — e.g. calendar pushes — have
            // nothing to reply to; their tap is a no-op).
            .onTapGesture { replyTapped(item) }
            .listRowBackground(Color.clear)
            .listRowSeparatorTint(.white.opacity(0.12))
            // Apple Mail's swipes: trailing full-swipe archives…
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button {
                    model.archive(item)
                } label: {
                    Label("Archive", systemImage: "archivebox.fill")
                }
                .tint(OutlookStyle.archiveGreen)
            }
            // …leading files it for later (a reminder, not a cleanup).
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                Button {
                    model.later(item)
                } label: {
                    Label("Later", systemImage: "clock.fill")
                }
                .tint(OutlookStyle.flagOrange)
            }
    }

    private func replyTapped(_ item: SignalItem) {
        guard item.draftChannel != nil else { return }
        model.markEngaged(item)
        replyItem = item
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
