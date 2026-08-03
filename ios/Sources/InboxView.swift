import Combine
import QuickLook
import SwiftUI
import UIKit
import WebKit

/// Native inbox: the same mailbox the web app shows, read on the phone with
/// Outlook mobile's dark-mode anatomy — near-black #1B1A19 canvas, Focused|
/// Other pill, per-day section headers, Microsoft-palette sender avatars,
/// unread blue dot, orange Flag / green Archive swipes, and a reader with
/// the sender card + Outlook-blue action row. The list paints instantly from
/// a JSON disk cache (Documents/inbox-cache.json) and refreshes underneath.

// MARK: - Cross-tab wiring

extension Notification.Name {
    /// Posted by the mail reader's "Ask Scarlet" action; RootView (which owns
    /// the live Conversation) observes it, switches to Talk, and delivers the
    /// question.
    static let scarletAskAboutEmail = Notification.Name("scarletAskAboutEmail")
    /// Posted by Conversation when the compose_draft voice tool starts a
    /// draft; RootView presents the drafting sheet in attach mode.
    static let scarletVoiceDraftStarted = Notification.Name("scarletVoiceDraftStarted")
    /// Posted by Conversation the INSTANT a compose_draft tool call arrives —
    /// before the network round-trip — carrying [channel, recipient,
    /// instruction, subject]. RootView opens the drafting sheet immediately and
    /// seeds the writing card with his request so the window reacts the moment
    /// he finishes speaking, ahead of the composed body.
    static let scarletVoiceDraftIntent = Notification.Name("scarletVoiceDraftIntent")
}

/// The list-level ambient-focus line, shared by the list's own appearance
/// and the reader's dismissal so both report the exact same thing.
private func inboxBrowsingFocus(_ tab: MailTab) -> String {
    "[FOCUS] Ido is browsing his Amwell inbox list (\(tab.title) tab). No single email is open."
}

// MARK: - Wire types

/// One inbox row, as `op=mailinbox` returns it.
struct MailMessage: Identifiable {
    let id: String
    let subject: String
    let preview: String
    let fromName: String
    let fromEmail: String
    let received: Date?
    var unread: Bool
    let attachments: Bool
    let importance: String
    var flagged: Bool
}

/// Outlook's inbox split. Raw values ride the query string (`?tab=other`).
enum MailTab: String, CaseIterable {
    case focused
    case other

    var title: String { self == .focused ? "Focused" : "Other" }
}

/// A fully opened message, as `op=mailread` returns it.
struct MailDetail {
    let subject: String
    let from: String
    let to: String
    let cc: String
    let received: String
    let html: String
    let attachments: [MailAttachment]
}

/// One real (non-inline) attachment on an opened message.
struct MailAttachment: Identifiable {
    let id: String
    let name: String
    let contentType: String
    let size: Int
}

/// What `op=mailattachment` handed back: file bytes to preview, a OneDrive/
/// SharePoint link to open in Safari, or a user-facing error line.
enum AttachmentFetchResult {
    case file(Data)
    case link(URL)
    case failure(String)
}

/// ISO-8601 parsing, shared by list and detail. File-scope (no actor) so any
/// view can format synchronously.
enum MailDates {
    static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let isoPlain = ISO8601DateFormatter()

    static func parse(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return isoPlain.date(from: s) ?? isoFractional.date(from: s)
    }
}

// MARK: - Disk cache (instant paint on launch)

/// One cached row: `MailMessage` mirrored into Codable form so the list can
/// persist as plain JSON without touching the wire type's shape.
private struct CachedMessage: Codable {
    let id: String
    let subject: String
    let preview: String
    let fromName: String
    let fromEmail: String
    let received: Date?
    var unread: Bool
    let attachments: Bool
    let importance: String
    var flagged: Bool

    init(_ m: MailMessage) {
        id = m.id
        subject = m.subject
        preview = m.preview
        fromName = m.fromName
        fromEmail = m.fromEmail
        received = m.received
        unread = m.unread
        attachments = m.attachments
        importance = m.importance
        flagged = m.flagged
    }

    var asMessage: MailMessage {
        MailMessage(id: id, subject: subject, preview: preview, fromName: fromName,
                    fromEmail: fromEmail, received: received, unread: unread,
                    attachments: attachments, importance: importance, flagged: flagged)
    }
}

/// The whole local mirror — both tabs plus their fetch stamps — persisted as
/// one JSON file in Documents. Read SYNCHRONOUSLY in `InboxModel.init` so the
/// list paints before the first network byte arrives; written after every
/// successful load and every local mutation (archive, read, flag).
private struct InboxCache: Codable {
    var focused: [CachedMessage] = []
    var other: [CachedMessage] = []
    var focusedStamp: Date?
    var otherStamp: Date?

    static let url: URL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("inbox-cache.json")

    static func loadSync() -> InboxCache {
        guard let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(InboxCache.self, from: data) else {
            return InboxCache()
        }
        return cache
    }

    func rows(for tab: MailTab) -> [CachedMessage] {
        tab == .focused ? focused : other
    }

    func stamp(for tab: MailTab) -> Date? {
        tab == .focused ? focusedStamp : otherStamp
    }

    mutating func set(rows: [MailMessage], stamp: Date?, for tab: MailTab) {
        let cached = rows.map { CachedMessage($0) }
        if tab == .focused {
            focused = cached
            if let stamp { focusedStamp = stamp }
        } else {
            other = cached
            if let stamp { otherStamp = stamp }
        }
    }
}

// MARK: - Model

@MainActor
final class InboxModel: ObservableObject {
    @Published var messages: [MailMessage] = []
    @Published var loading = false
    @Published var errorText = ""
    /// Focused | Other pill. Switch via `setTab`, which reloads.
    @Published var tab: MailTab = .focused
    /// When the current tab's rows last came back from the server (the cache
    /// stamp on a cold start). Drives the subtle "Updated Xm ago" line that
    /// replaces spinners whenever cached content is on screen.
    @Published var lastUpdated: Date?

    /// Rows archived locally: a refresh must not resurrect them while the
    /// Graph move is still settling.
    private var pendingArchiveIds: Set<String> = []
    /// Local read/unread flips that win over a stale server snapshot until
    /// the server catches up.
    private var unreadOverrides: [String: Bool] = [:]
    /// Local flag flips (Outlook's leading swipe). There's no server op for
    /// the flag, so these win over server snapshots and ride the disk cache.
    private var flagOverrides: [String: Bool] = [:]
    /// Monotonic load token: a load that finishes after a newer one started
    /// (e.g. a slow Focused fetch landing after a switch to Other) is dropped.
    private var loadGeneration = 0
    /// In-memory copy of the disk mirror; every mutation re-persists it.
    private var cache: InboxCache

    /// Local-first: the last snapshot paints synchronously, before the first
    /// network byte, so opening the tab never shows a spinner over history.
    init() {
        cache = InboxCache.loadSync()
        messages = localized(cache.rows(for: .focused).map { $0.asMessage })
        lastUpdated = cache.stamp(for: .focused)
    }

    /// Pill tap: swap the tab, paint that tab's cached rows immediately, and
    /// refresh underneath. No cache → empty list (first-load path).
    func setTab(_ newTab: MailTab) {
        guard newTab != tab else { return }
        tab = newTab
        withAnimation(.snappy) {
            messages = localized(cache.rows(for: newTab).map { $0.asMessage })
        }
        lastUpdated = cache.stamp(for: newTab)
        Task { await load() }
    }

    /// Cached rows re-filtered through local state: pending archives stay
    /// hidden and local read/flag flips stay applied across tab hops.
    private func localized(_ rows: [MailMessage]) -> [MailMessage] {
        var out = rows
        out.removeAll { pendingArchiveIds.contains($0.id) }
        for i in out.indices {
            if let want = unreadOverrides[out[i].id] { out[i].unread = want }
            if let want = flagOverrides[out[i].id] { out[i].flagged = want }
        }
        return out
    }

    func load() async {
        guard TokenStore.token != nil else {
            messages = []
            errorText = "Locked — unlock Scarlet to see the inbox."
            return
        }
        if messages.isEmpty { loading = true }
        errorText = ""
        loadGeneration += 1
        let generation = loadGeneration
        defer { if generation == loadGeneration { loading = false } }
        do {
            let data = try await Self.request("op=mailinbox&tab=\(tab.rawValue)", method: "GET")
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            var seen = Set<String>()
            var fetched: [MailMessage] = ((obj["messages"] as? [[String: Any]]) ?? []).compactMap { m in
                guard let id = m["id"] as? String else { return nil }
                // Graph can return the same message id twice (delta/paging). A
                // duplicate id traps the diffable List at regular width (iPad/Mac)
                // — the exact crash class already fixed in Chats. Keep the first.
                guard seen.insert(id).inserted else { return nil }
                return MailMessage(
                    id: id,
                    subject: (m["subject"] as? String) ?? "(no subject)",
                    preview: (m["preview"] as? String) ?? "",
                    fromName: (m["from_name"] as? String) ?? "",
                    fromEmail: (m["from_email"] as? String) ?? "",
                    received: MailDates.parse(m["received"] as? String),
                    unread: (m["unread"] as? Bool) ?? false,
                    attachments: (m["attachments"] as? Bool) ?? false,
                    importance: (m["importance"] as? String) ?? "normal",
                    flagged: (m["flagged"] as? Bool) ?? false
                )
            }
            // A newer load (tab switch, refresh) superseded this one — drop it
            // before touching any shared state.
            guard generation == loadGeneration else { return }
            let listed = Set(fetched.map { $0.id })
            // Forget archives Graph has already applied; hide the ones it
            // hasn't caught up with yet.
            pendingArchiveIds.formIntersection(listed)
            fetched.removeAll { pendingArchiveIds.contains($0.id) }
            for i in fetched.indices {
                if let want = unreadOverrides[fetched[i].id] {
                    if fetched[i].unread == want {
                        unreadOverrides.removeValue(forKey: fetched[i].id)
                    } else {
                        fetched[i].unread = want
                    }
                }
                if let want = flagOverrides[fetched[i].id] {
                    if fetched[i].flagged == want {
                        flagOverrides.removeValue(forKey: fetched[i].id)
                    } else {
                        fetched[i].flagged = want
                    }
                }
            }
            unreadOverrides = unreadOverrides.filter { listed.contains($0.key) }
            flagOverrides = flagOverrides.filter { listed.contains($0.key) }
            withAnimation(.snappy) { messages = fetched }
            cache.set(rows: fetched, stamp: Date(), for: tab)
            lastUpdated = cache.stamp(for: tab)
            persistCache()
        } catch {
            guard generation == loadGeneration else { return }
            errorText = "Couldn't reach the inbox — check your connection."
        }
    }

    /// Optimistic archive: the row leaves the list immediately; if the server
    /// says no, it comes back where it was.
    func archive(_ message: MailMessage) {
        let index = messages.firstIndex { $0.id == message.id }
        if let index {
            _ = withAnimation(.snappy) { messages.remove(at: index) }
        }
        pendingArchiveIds.insert(message.id)
        syncCacheWithMessages()
        Task {
            do {
                let data = try await Self.request("op=mailarchive", method: "POST",
                                                  body: ["id": message.id])
                let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                guard (obj?["ok"] as? Bool) == true else { throw URLError(.badServerResponse) }
            } catch {
                pendingArchiveIds.remove(message.id)
                let at = min(index ?? messages.count, messages.count)
                withAnimation(.snappy) { messages.insert(message, at: at) }
                syncCacheWithMessages()
                errorText = "Couldn't archive that one — it's back in the list."
            }
        }
    }

    /// Outlook's leading swipe: flip the follow-up flag. Local-only for now —
    /// there is no `mailflag` op — so the override map plus the disk cache
    /// keep it sticky across refreshes and launches.
    func toggleFlag(_ message: MailMessage) {
        let nowFlagged = !message.flagged
        flagOverrides[message.id] = nowFlagged
        if let i = messages.firstIndex(where: { $0.id == message.id }) {
            withAnimation(.snappy) { messages[i].flagged = nowFlagged }
        }
        syncCacheWithMessages()
    }

    /// Outlook's leading swipe: flip read/unread locally right away, mirror it
    /// to the real mailbox via `op=mailmark`, revert if the server says no.
    func toggleRead(_ message: MailMessage) {
        let nowUnread = !message.unread
        setUnread(message.id, nowUnread)
        Task {
            do {
                let data = try await Self.request("op=mailmark", method: "POST",
                                                  body: ["id": message.id, "unread": nowUnread])
                let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                guard (obj?["ok"] as? Bool) == true else { throw URLError(.badServerResponse) }
            } catch {
                setUnread(message.id, !nowUnread)
                errorText = "Couldn't change read state — reverted."
            }
        }
    }

    /// Opens a message. Graph ids carry `+ / =` and friends, so the id is
    /// percent-encoded down to alphanumerics before it rides the query string.
    func read(id: String) async throws -> MailDetail {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
        let data = try await Self.request("op=mailread&id=\(encoded)", method: "GET")
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let attachments: [MailAttachment] = ((obj["attachments"] as? [[String: Any]]) ?? [])
            .compactMap { a in
                guard let aid = a["id"] as? String, !aid.isEmpty else { return nil }
                return MailAttachment(
                    id: aid,
                    name: (a["name"] as? String) ?? "attachment",
                    contentType: (a["contentType"] as? String) ?? "",
                    size: (a["size"] as? Int) ?? 0
                )
            }
        return MailDetail(
            subject: Self.stringy(obj["subject"]),
            from: Self.stringy(obj["from"]),
            to: Self.stringy(obj["to"]),
            cc: Self.stringy(obj["cc"]),
            received: Self.stringy(obj["received"]),
            html: Self.stringy(obj["html"]),
            attachments: attachments
        )
    }

    /// Downloads one attachment. The server answers with either the raw file
    /// bytes (normal case) or a small JSON object — a `link` for OneDrive/
    /// SharePoint reference attachments, or an `error`. Discrimination: only
    /// when the Content-Type header says JSON *and* the body parses as a JSON
    /// object do we treat it as a special case; anything else is the file.
    func fetchAttachment(messageId: String, attachmentId: String) async throws
        -> AttachmentFetchResult {
        let mid = messageId.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
            ?? messageId
        let aid = attachmentId.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
            ?? attachmentId
        guard let url = URL(string:
            "\(AppConfig.apiBase)/app-api?v=2&op=mailattachment&id=\(mid)&aid=\(aid)") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(TokenStore.token ?? "", forHTTPHeaderField: "x-scarlet-token")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if contentType.contains("application/json"),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if let link = obj["link"] as? String, let linkURL = URL(string: link) {
                return .link(linkURL)
            }
            return .failure("Couldn't open that attachment — try again.")
        }
        guard !data.isEmpty else {
            return .failure("Couldn't open that attachment — try again.")
        }
        return .file(data)
    }

    /// The server marks read on open; mirror it locally so the row un-bolds.
    func markRead(_ id: String) { setUnread(id, false) }

    private func setUnread(_ id: String, _ unread: Bool) {
        unreadOverrides[id] = unread
        if let i = messages.firstIndex(where: { $0.id == id }) { messages[i].unread = unread }
        syncCacheWithMessages()
    }

    /// Mirror the visible rows into the current tab's cache slot (fetch stamp
    /// unchanged — a local flip isn't a server refresh) and write to disk.
    private func syncCacheWithMessages() {
        cache.set(rows: messages, stamp: nil, for: tab)
        persistCache()
    }

    /// Encode on the main actor (the struct is tiny), write off it — the
    /// list never blocks on disk.
    private func persistCache() {
        let snapshot = cache
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: InboxCache.url, options: .atomic)
        }
    }

    // MARK: plumbing

    private static func request(_ query: String, method: String,
                                body: [String: Any]? = nil) async throws -> Data {
        guard let url = URL(string: "\(AppConfig.apiBase)/app-api?\(query)") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(TokenStore.token ?? "", forHTTPHeaderField: "x-scarlet-token")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private static func stringy(_ v: Any?) -> String {
        if let s = v as? String { return s }
        if let a = v as? [String] { return a.joined(separator: ", ") }
        return ""
    }
}

// MARK: - Outlook palette

/// Compact hex constructor, private to this file (no Assets, per house rule).
private extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255.0,
                  green: Double((hex >> 8) & 0xFF) / 255.0,
                  blue: Double(hex & 0xFF) / 255.0)
    }
}

/// Outlook mobile's dark-mode design tokens, shared by list and reader.
enum OutlookStyle {
    /// Near-black canvas behind everything.
    static let background = Color(hex: 0x1B1A19)
    /// Raised surfaces: chips, cards, the pill track.
    static let surface = Color(hex: 0x252423)
    static let surfaceAlt = Color(hex: 0x292827)
    /// Hairlines between rows.
    static let separator = Color(hex: 0x3B3A39)
    /// Microsoft blue — links, selection, the unread dot.
    static let accentBlue = Color(hex: 0x479EF5)
    /// Microsoft blue — filled primary actions.
    static let primaryBlue = Color(hex: 0x0F6CBD)
    /// Full-swipe Archive.
    static let archiveGreen = Color(hex: 0x498205)
    /// The follow-up flag: glyph, leading swipe.
    static let flagOrange = Color(hex: 0xCA5010)
    /// Secondary text: previews, times, section headers.
    static let textSecondary = Color(hex: 0x979593)
    /// Flagged rows sit on a whisper of the flag orange.
    static let flaggedRowTint = Color(hex: 0xCA5010).opacity(0.08)
    /// Focused | Other pill: darker track, lighter capsule for the selection.
    static let pillTrack = Color(hex: 0x252423)
    static let pillSelected = Color(hex: 0x3B3A39)
}

// MARK: - Sender avatar

/// Outlook-style initials circle: deterministic color from the address, so a
/// sender keeps the same color across launches.
struct SenderAvatar: View {
    let name: String
    let email: String
    var size: CGFloat = 40

    /// Microsoft's avatar palette (blue, magenta, orange, teal, purple,
    /// green) — the colors real Outlook deals to senders.
    private static let palette: [Color] = [
        Color(red: 0.059, green: 0.424, blue: 0.741),  // #0F6CBD blue
        Color(red: 0.761, green: 0.224, blue: 0.702),  // #C239B3 magenta
        Color(red: 0.792, green: 0.314, blue: 0.063),  // #CA5010 orange
        Color(red: 0.012, green: 0.514, blue: 0.529),  // #038387 teal
        Color(red: 0.529, green: 0.392, blue: 0.722),  // #8764B8 purple
        Color(red: 0.286, green: 0.510, blue: 0.020),  // #498205 green
    ]

    var body: some View {
        ZStack {
            Circle().fill(color)
            Text(initials)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }

    /// Hash the sender's name (Outlook's rule); the address is the fallback
    /// for nameless senders — and for ChatsView callers that pass email: "".
    private var seed: String {
        name.isEmpty ? email.lowercased() : name.lowercased()
    }

    /// djb2 over UTF-8 — stable across launches (unlike `hashValue`).
    private var color: Color {
        var h: UInt32 = 5381
        for b in seed.utf8 { h = h &* 33 &+ UInt32(b) }
        return Self.palette[Int(h % UInt32(Self.palette.count))]
    }

    private var initials: String {
        let words = name.split(separator: " ").filter { !$0.isEmpty }
        let letters = words.prefix(2).compactMap { $0.first }
        if !letters.isEmpty {
            return letters.map { String($0).uppercased() }.joined()
        }
        if let c = email.first ?? name.first { return String(c).uppercased() }
        return "?"
    }
}

// MARK: - Inbox list

struct InboxView: View {
    @StateObject private var model = InboxModel()
    @EnvironmentObject private var convo: Conversation
    @State private var showCompose = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                headerBar
                tabPills
                content
            }
            .background(OutlookStyle.background.ignoresSafeArea())
            // Scarlet lives at the bottom of the LIST screen only — part of
            // its layout, so the pushed reader (with its own action bar)
            // structurally replaces it.
            .safeAreaInset(edge: .bottom) {
                ScarletPresenceView(convo: convo)
                    .padding(.vertical, 6)
            }
            // The Outlook-style header row replaces the system bar on the
            // list screen; pushed screens (reader) keep theirs for Back.
            .toolbar(.hidden, for: .navigationBar)
            .reportsModalPresence(showCompose)
            .sheet(isPresented: $showCompose) {
                DraftView(seed: nil)
                    .environmentObject(convo)   // DraftView hard-requires it; match every other call site
                    .preferredColorScheme(.dark)
            }
            // Ambient focus: the list reports itself whenever it's the
            // visible screen (tab selected, reader popped) and again when
            // the Focused|Other pill flips.
            .onAppear { convo.setFocus(inboxBrowsingFocus(model.tab)) }
            .onChange(of: model.tab) { _, newTab in
                convo.setFocus(inboxBrowsingFocus(newTab))
            }
        }
        // .task re-runs every time this tab is selected → auto-refresh on
        // tab appear; foreground return refreshes too.
        .task { await model.load() }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.willEnterForegroundNotification)) { _ in
            Task { await model.load() }
        }
    }

    // MARK: Outlook-style header (avatar · big Inbox title · compose · refresh)

    private var headerBar: some View {
        HStack(spacing: 12) {
            // Account avatar placeholder ("IS" — no photo available).
            ZStack {
                Circle().fill(OutlookStyle.primaryBlue)
                Text("IS")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 36, height: 36)
            Text("Inbox")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white)
            Spacer()
            // New mail: Scarlet drafts it in the native studio.
            Button {
                showCompose = true
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white)
            }
            // (No manual refresh button — pull-to-refresh, tab-appear, and
            // foreground-return already reload, and the "Updated Xm ago" stamp
            // shows freshness; the calendar has no such button either.)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    /// Focused | Other, Outlook's pill-in-a-track toggle, with the quiet
    /// freshness stamp on the right — the anti-spinner.
    private var tabPills: some View {
        HStack {
            HStack(spacing: 0) {
                ForEach(MailTab.allCases, id: \.self) { t in
                    Button {
                        model.setTab(t)
                    } label: {
                        Text(t.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(model.tab == t
                                ? Color.white : OutlookStyle.textSecondary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(model.tab == t
                                    ? OutlookStyle.pillSelected : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(Capsule().fill(OutlookStyle.pillTrack))
            Spacer()
            if let stamp = model.lastUpdated {
                // Tick every minute so the stamp ages while the list sits idle
                // (nothing else drives a re-render) — matches the calendar.
                TimelineView(.everyMinute) { _ in
                    Text(Self.updatedLabel(stamp))
                        .font(.system(size: 11))
                        .foregroundStyle(OutlookStyle.textSecondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    /// "Updated just now / 3m ago / 2h ago" — recomputed on every render,
    /// which each refresh and tab hop triggers anyway.
    private static func updatedLabel(_ stamp: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(stamp))
        if seconds < 90 { return "Updated just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "Updated \(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "Updated \(hours)h ago" }
        return "Updated \(hours / 24)d ago"
    }

    @ViewBuilder
    private var content: some View {
        if model.loading && model.messages.isEmpty {
            // Only reachable with no cache at all (true first run): content
            // could not exist yet, so the one spinner in the flow is here.
            VStack(spacing: 10) {
                ProgressView()
                Text("Checking the mail…").font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.messages.isEmpty && !model.errorText.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.title2).foregroundStyle(.secondary)
                Text(model.errorText)
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try again") { Task { await model.load() } }
                    .buttonStyle(.bordered)
                    .tint(OutlookStyle.accentBlue)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.messages.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "envelope.open")
                    .font(.title2).foregroundStyle(.secondary)
                Text("Inbox is quiet.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                if !model.errorText.isEmpty {
                    Text(model.errorText)
                        .font(.footnote)
                        .foregroundStyle(Color(red: 0.91, green: 0.69, blue: 0.31))
                        .listRowBackground(Color.clear)
                }
                ForEach(groups) { group in
                    // Per-day headers, Outlook style: small caps, quiet gray.
                    Text(group.title.uppercased())
                        .font(.system(size: 12, weight: .semibold))
                        .kerning(0.5)
                        .foregroundStyle(OutlookStyle.textSecondary)
                        .padding(.top, 12)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    ForEach(group.messages) { message in
                        // ZStack + zero-opacity link: full NavigationLink
                        // behavior without the disclosure chevron Outlook
                        // doesn't have.
                        ZStack {
                            NavigationLink {
                                MailDetailView(message: message, model: model)
                            } label: {
                                EmptyView()
                            }
                            .opacity(0)
                            InboxRow(message: message, accent: OutlookStyle.accentBlue)
                        }
                        .listRowBackground(message.flagged
                            ? OutlookStyle.flaggedRowTint : Color.clear)
                        .listRowSeparatorTint(OutlookStyle.separator)
                        // Outlook's swipes: long-swipe left = green Archive,
                        // long-swipe right = orange Flag (plus Read/Unread).
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button {
                                model.archive(message)
                            } label: {
                                Label("Archive", systemImage: "archivebox.fill")
                            }
                            .tint(OutlookStyle.archiveGreen)
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button {
                                model.toggleFlag(message)
                            } label: {
                                Label(message.flagged ? "Unflag" : "Flag",
                                      systemImage: message.flagged
                                          ? "flag.slash.fill" : "flag.fill")
                            }
                            .tint(OutlookStyle.flagOrange)
                            Button {
                                model.toggleRead(message)
                            } label: {
                                Label(message.unread ? "Read" : "Unread",
                                      systemImage: message.unread
                                          ? "envelope.open.fill" : "envelope.badge.fill")
                            }
                            .tint(OutlookStyle.primaryBlue)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .refreshable { await model.load() }
        }
    }

    // MARK: date buckets (Outlook grouping: one section per day)

    private struct MailGroup: Identifiable {
        let id: String
        let title: String
        let messages: [MailMessage]
    }

    /// Group by calendar day, preserving the server's newest-first order.
    /// Undated strays sink into one "Earlier" bucket.
    private var groups: [MailGroup] {
        let cal = Calendar.current
        var order: [String] = []
        var titles: [String: String] = [:]
        var buckets: [String: [MailMessage]] = [:]
        for m in model.messages {
            let key: String
            let title: String
            if let d = m.received {
                let day = cal.startOfDay(for: d)
                key = String(Int(day.timeIntervalSince1970))
                title = Self.dayTitle(day, cal: cal)
            } else {
                key = "undated"
                title = "Earlier"
            }
            if buckets[key] == nil {
                order.append(key)
                titles[key] = title
            }
            buckets[key, default: []].append(m)
        }
        return order.map { key in
            MailGroup(id: key, title: titles[key] ?? "", messages: buckets[key] ?? [])
        }
    }

    private static let weekdayHeaderFormat: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEE"; return f
    }()
    private static let dateHeaderFormat: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEE, MMMM d"; return f
    }()
    private static let oldDateHeaderFormat: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMMM d, yyyy"; return f
    }()

    /// Outlook's header ladder: Today, Yesterday, bare weekday inside the
    /// last week, "Friday, July 18" this year, full date beyond.
    private static func dayTitle(_ day: Date, cal: Calendar) -> String {
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        let days = cal.dateComponents([.day], from: day,
                                      to: cal.startOfDay(for: Date())).day ?? 99
        if days >= 0 && days < 7 { return weekdayHeaderFormat.string(from: day) }
        if cal.component(.year, from: day) == cal.component(.year, from: Date()) {
            return dateHeaderFormat.string(from: day)
        }
        return oldDateHeaderFormat.string(from: day)
    }
}

/// One row, Outlook-mobile anatomy on dark: unread blue dot at the left
/// edge, initials avatar, sender / subject / two-line preview, trailing
/// date, red flag + paperclip on the subject line, high-importance mark.
struct InboxRow: View {
    let message: MailMessage
    let accent: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Unread marker: an 8pt Outlook-blue dot, centered on the avatar
            // (avatar top pad 2 + radius 20 = 22; dot pad 18 + radius 4 = 22).
            Circle()
                .fill(accent)
                .frame(width: 8, height: 8)
                .padding(.top, 18)
                .opacity(message.unread ? 1 : 0)
            SenderAvatar(name: senderName, email: message.fromEmail, size: 40)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(senderName)
                        .font(.system(size: 15, weight: message.unread ? .bold : .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if message.importance == "high" {
                        Text("!")
                            .font(.subheadline.bold())
                            .foregroundStyle(.red)
                    }
                    Spacer(minLength: 8)
                    Text(timeLabel)
                        .font(.system(size: 12))
                        .foregroundStyle(OutlookStyle.textSecondary)
                }
                HStack(spacing: 6) {
                    Text(message.subject)
                        .font(.system(size: 14, weight: message.unread ? .semibold : .regular))
                        .foregroundStyle(Color.white.opacity(message.unread ? 1.0 : 0.9))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    if message.flagged {
                        Image(systemName: "flag.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(OutlookStyle.flagOrange)
                    }
                    if message.attachments {
                        Image(systemName: "paperclip")
                            .font(.system(size: 12))
                            .foregroundStyle(OutlookStyle.textSecondary)
                    }
                }
                Text(message.preview)
                    .font(.system(size: 13))
                    .foregroundStyle(OutlookStyle.textSecondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
        }
        .padding(.vertical, 6)
    }

    private var senderName: String {
        message.fromName.isEmpty ? message.fromEmail : message.fromName
    }

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none; return f
    }()
    private static let weekdayFormat: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEE"; return f
    }()
    private static let dayFormat: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d"; return f
    }()
    private static let yearFormat: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d, yyyy"; return f
    }()

    /// Outlook's ladder: today → time, yesterday through this week → full
    /// weekday ("Friday"), this year → "MMM d", older → "MMM d, yyyy".
    private var timeLabel: String {
        guard let d = message.received else { return "" }
        let cal = Calendar.current
        if cal.isDateInToday(d) { return Self.timeFormat.string(from: d) }
        let days = cal.dateComponents([.day],
                                      from: cal.startOfDay(for: d),
                                      to: cal.startOfDay(for: Date())).day ?? 99
        if days >= 0 && days < 7 { return Self.weekdayFormat.string(from: d) }
        if cal.component(.year, from: d) == cal.component(.year, from: Date()) {
            return Self.dayFormat.string(from: d)
        }
        return Self.yearFormat.string(from: d)
    }
}

// MARK: - Detail

struct MailDetailView: View {
    let message: MailMessage
    @ObservedObject var model: InboxModel
    @EnvironmentObject private var convo: Conversation
    @Environment(\.dismiss) private var dismiss

    @State private var detail: MailDetail?
    @State private var failed = false
    @State private var showRecipients = false
    /// Attachment currently downloading (its chip swaps icon → spinner).
    @State private var downloadingAttachmentId: String?
    /// Small red footnote under the chips; cleared on the next tap.
    @State private var attachmentError = ""
    /// ONE sheet for the reader — the Reply drafting window OR a QuickLook
    /// attachment preview. Two stacked `.sheet` modifiers on one view crash Mac
    /// Catalyst; a single enum-driven sheet is safe.
    enum ReaderSheet: Identifiable {
        case draft, preview(PreviewFile)
        var id: String {
            switch self {
            case .draft: return "draft"
            case .preview(let f): return "preview-\(f.id)"
            }
        }
    }
    @State private var activeSheet: ReaderSheet?
    /// Display name of the attachment being previewed — feeds the viewer's
    /// [FOCUS] line so Scarlet knows exactly which file is on screen.
    @State private var previewName = ""
    /// The per-open temp folder holding the downloaded attachment; deleted when
    /// the viewer closes so temp bytes don't accumulate across a session.
    @State private var lastAttachmentDir: URL?
    /// The focus line that was active before the attachment viewer opened
    /// (normally this email's own emailFocus); restored on dismiss.
    @State private var focusBeforeAttachment: String?
    /// The attachment focus line the viewer set — the stale-guard comparator:
    /// restore on dismiss ONLY if focus is still ours (another screen may
    /// have claimed it while the viewer was up).
    @State private var attachmentFocusLine: String?

    private let scarletRose = Color(red: 1, green: 0.35, blue: 0.42)

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(OutlookStyle.separator)
            // Outlook puts attachments right under the header, above the
            // body. A fixed-height horizontal strip: it never joins the
            // web view's vertical scroll surface.
            if let detail, !detail.attachments.isEmpty {
                attachmentsRow(detail.attachments)
                Divider().overlay(OutlookStyle.separator)
            }
            bodyPane
            Divider().overlay(OutlookStyle.separator)
            actionBar
        }
        .background(OutlookStyle.background.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        // (No overflow menu — "Ask Scarlet" already lives in the action bar; a
        // single-item ellipsis menu was pure duplication.)
        // ONE sheet drives BOTH the Reply drafting window and the QuickLook
        // attachment viewer. Two stacked `.sheet` modifiers on one view crash
        // Mac Catalyst; the enum keeps a single presentation surface.
        // `onDismiss` runs the attachment-focus restore for every case — it's a
        // no-op when the draft closes (no attachment focus was set).
        .reportsModalPresence(activeSheet != nil)
        .sheet(item: $activeSheet, onDismiss: attachmentViewerClosed) { sheet in
            switch sheet {
            case .draft:
                // The loaded detail carries the original's To/Cc; Reply is only
                // reachable once it's up, but fall back to empty gracefully.
                DraftView(seed: DraftSeed(
                    messageId: message.id,
                    fromName: message.fromName,
                    fromEmail: message.fromEmail,
                    subject: message.subject,
                    preview: message.preview,
                    toLine: detail?.to ?? "",
                    ccLine: detail?.cc ?? ""
                ))
                .environmentObject(convo)   // DraftView hard-requires it; match every other call site
                .preferredColorScheme(.dark)
            case .preview(let file):
                // QuickLook: pinch-zoom, paging, share — the Outlook attachment
                // experience, straight from the system viewer. Full-height dark
                // sheet with a floating ✕ (a bare QLPreviewController draws no
                // Done button, and its zoom/scroll gestures can eat the
                // swipe-down, so the ✕ is the guaranteed way out).
                attachmentViewer(file)
            }
        }
        .task {
            // Crash breadcrumb: if the app dies while an email is open, the next
            // launch reports last_screen="email-reader" so we can locate it.
            FlightRecorder.note(screen: "email-reader")
            model.markRead(message.id)
            await fetch()
        }
        // Ambient focus: this email while the reader is up; back to the list
        // on the way out — unless another screen (say, the Talk tab) already
        // claimed focus during the transition.
        .onAppear {
            convo.setFocus(emailFocus)
        }
        .onDisappear {
            if convo.currentFocus == emailFocus {
                convo.setFocus(inboxBrowsingFocus(model.tab))
            }
        }
    }

    @MainActor
    private func fetch() async {
        do {
            detail = try await model.read(id: message.id)
        } catch {
            failed = true
        }
    }

    // MARK: attachments (Outlook-style chip strip under the header)

    private func attachmentsRow(_ attachments: [MailAttachment]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(attachments) { att in
                        attachmentChip(att)
                    }
                }
                .padding(.horizontal, 16)
            }
            if !attachmentError.isEmpty {
                Text(attachmentError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 8)
    }

    private func attachmentChip(_ att: MailAttachment) -> some View {
        Button {
            openAttachment(att)
        } label: {
            HStack(spacing: 8) {
                if downloadingAttachmentId == att.id {
                    ProgressView()
                        .frame(width: 24, height: 24)
                } else {
                    Image(systemName: Self.attachmentStyle(for: att).icon)
                        .font(.system(size: 22))
                        .foregroundStyle(Self.attachmentStyle(for: att).color)
                        .frame(width: 24, height: 24)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(att.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 170, alignment: .leading)
                    Text(Self.sizeFormat.string(fromByteCount: Int64(att.size)))
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
    }

    /// Tap → download → QuickLook (bytes), Safari (reference link), or a
    /// footnote error. One download at a time; errors clear on the next tap.
    @MainActor
    private func openAttachment(_ att: MailAttachment) {
        attachmentError = ""
        guard downloadingAttachmentId == nil else { return }
        downloadingAttachmentId = att.id
        Task {
            defer { downloadingAttachmentId = nil }
            do {
                let result = try await model.fetchAttachment(messageId: message.id,
                                                             attachmentId: att.id)
                switch result {
                case .file(let data):
                    let url = Self.tempFileURL(for: att.name)
                    try data.write(to: url, options: .atomic)
                    previewName = att.name
                    lastAttachmentDir = url.deletingLastPathComponent()
                    activeSheet = .preview(PreviewFile(url: url))
                case .link(let url):
                    UIApplication.shared.open(url, options: [:], completionHandler: nil)
                case .failure(let text):
                    attachmentError = text
                }
            } catch {
                attachmentError = "Couldn't open that attachment — try again."
            }
        }
    }

    // MARK: attachment viewer (full-height QuickLook + floating ✕ + focus)

    /// The attachment sheet's content: the system QuickLook viewer (pinch
    /// zoom, Word/PDF/image rendering) under a floating close button. The ✕
    /// is always visible and always works; swipe-down remains available too.
    private func attachmentViewer(_ file: PreviewFile) -> some View {
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
        .onAppear { attachmentViewerOpened() }
    }

    /// The viewer is up: remember whatever focus was active (normally this
    /// email's emailFocus) and point Scarlet at the attachment itself.
    private func attachmentViewerOpened() {
        let focus = attachmentFocus(filename: previewName)
        focusBeforeAttachment = convo.currentFocus
        attachmentFocusLine = focus
        convo.setFocus(focus)
    }

    /// The viewer closed (✕ or swipe): hand focus back to the email reader —
    /// but only if the attachment focus is still the live one; if another
    /// screen claimed focus while the viewer was up, leave it alone. State
    /// fully resets so the same or another attachment reopens cleanly.
    private func attachmentViewerClosed() {
        if let mine = attachmentFocusLine, convo.currentFocus == mine {
            convo.setFocus(focusBeforeAttachment ?? emailFocus)
        }
        attachmentFocusLine = nil
        focusBeforeAttachment = nil
        previewName = ""
        // Remove this open's temp folder (best-effort) so downloaded bytes
        // don't pile up in the temp directory over a long session.
        if let dir = lastAttachmentDir {
            try? FileManager.default.removeItem(at: dir)
            lastAttachmentDir = nil
        }
    }

    /// The ambient-focus line while an attachment is full-screen: names the
    /// exact file, its email, and the tool call that reads it, so "read this
    /// to me" acts on THIS attachment with no follow-up question.
    private func attachmentFocus(filename: String) -> String {
        let sender = message.fromName.isEmpty ? message.fromEmail : message.fromName
        return "[FOCUS] Ido is viewing an email ATTACHMENT full-screen: "
            + "'\(filename)' — from the email '\(message.subject)' "
            + "from \(sender) (message_id: \(message.id)).\n"
            + "Any request like 'read this', 'summarize what I'm looking at', "
            + "'what does it say about X', 'תקריאי לי' refers to THIS attachment — "
            + "call read_email_attachment with message_id '\(message.id)' "
            + "and attachment_match '\(filename)' and the question. "
            + "Never ask which attachment he means."
    }

    /// Temp destination that keeps the real filename (extension included —
    /// that's what makes QuickLook pick the right renderer) but strips path
    /// separators so a hostile name can't escape the temp directory. Each open
    /// gets its OWN unique subfolder: corporate mail routinely reuses display
    /// names ("image001.png", "ATT00001"), and writing over a file QuickLook is
    /// still previewing hands it a swapped item. The subfolder isolates every
    /// preview while preserving the real name+extension for type detection.
    private static func tempFileURL(for name: String) -> URL {
        var clean = name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty || clean == "." || clean == ".." { clean = "attachment" }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("att-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(clean)
    }

    /// Outlook's file-type iconography, decided by extension with a
    /// contentType fallback for extension-less image names.
    private static func attachmentStyle(for att: MailAttachment)
        -> (icon: String, color: Color) {
        let ext = (att.name as NSString).pathExtension.lowercased()
        switch ext {
        case "doc", "docx": return ("doc.fill", .blue)
        case "xls", "xlsx", "csv": return ("tablecells.fill", .green)
        case "ppt", "pptx": return ("play.rectangle.fill", .orange)
        case "pdf": return ("doc.richtext.fill", .red)
        case "png", "jpg", "jpeg", "gif", "heic": return ("photo.fill", .purple)
        case "zip": return ("archivebox.fill", .gray)
        default:
            if att.contentType.lowercased().hasPrefix("image/") {
                return ("photo.fill", .purple)
            }
            return ("paperclip", .gray)
        }
    }

    private static let sizeFormat: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    // MARK: header (compact, Outlook-style: avatar + name + address + Details)

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(subjectText)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(3)
                .truncationMode(.tail)
            HStack(alignment: .center, spacing: 10) {
                SenderAvatar(name: senderDisplayName, email: senderAddress, size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(senderDisplayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if !senderAddress.isEmpty && senderAddress != senderDisplayName {
                        Text(senderAddress)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    if !receivedText.isEmpty {
                        Text(receivedText)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if detail != nil {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { showRecipients.toggle() }
                    } label: {
                        HStack(spacing: 3) {
                            Text("Details").font(.caption)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                                .rotationEffect(.degrees(showRecipients ? 180 : 0))
                        }
                        .foregroundStyle(.secondary)
                    }
                }
            }
            if showRecipients, let detail {
                VStack(alignment: .leading, spacing: 3) {
                    if !detail.to.isEmpty {
                        Text("To: \(detail.to)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                    if !detail.cc.isEmpty {
                        Text("Cc: \(detail.cc)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: body (the WebView is THE scrolling element — smooth like Outlook)

    @ViewBuilder
    private var bodyPane: some View {
        if let detail {
            MailBodyView(html: detail.html)
        } else if failed {
            VStack(spacing: 12) {
                Text("Couldn't open this message.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Try again") {
                    failed = false
                    Task { await fetch() }
                }
                .buttonStyle(.bordered)
                .tint(OutlookStyle.accentBlue)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: action bar (Reply keeps the native DraftView flow)

    /// Outlook-blue action row: Reply is the filled primary; the rest sit as
    /// quiet raised chips. Same three behaviors as always.
    private var actionBar: some View {
        HStack(spacing: 10) {
            // "Reply All" — the draft is a true threaded Reply-All (every
            // original recipient), so the button says exactly that.
            actionButton("Reply All", icon: "arrowshape.turn.up.left.2.fill",
                         tint: OutlookStyle.primaryBlue, filled: true) {
                activeSheet = .draft
            }
            // Archive is GREEN here too, matching the list swipe — one color per
            // concept.
            actionButton("Archive", icon: "archivebox.fill",
                         tint: OutlookStyle.archiveGreen) {
                model.archive(message)
                dismiss()
            }
            actionButton("Ask Scarlet", icon: "sparkles", tint: scarletRose) {
                askScarlet()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func actionButton(_ label: String, icon: String, tint: Color,
                              filled: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                Text(label).font(.footnote.weight(.semibold))
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(filled ? tint : OutlookStyle.surface, in: Capsule())
            .overlay(Capsule().stroke(
                filled ? Color.clear : OutlookStyle.separator, lineWidth: 1))
            .foregroundStyle(filled ? Color.white : tint)
        }
    }

    /// "All Scarlet capabilities" in the reader: hand this email to the live
    /// conversation (Talk tab) with enough context to act on it.
    private func askScarlet() {
        let sender = message.fromName.isEmpty ? message.fromEmail : message.fromName
        let text = "Regarding the email from \(sender) about '\(message.subject)': "
            + "summarize it and suggest how to handle it."
        NotificationCenter.default.post(name: .scarletAskAboutEmail, object: nil,
                                        userInfo: ["text": text])
    }

    // MARK: derived strings

    private var subjectText: String {
        if let s = detail?.subject, !s.isEmpty { return s }
        return message.subject
    }

    /// `detail.from` arrives as "Name <address>"; the list row's fields are
    /// the fallback while the detail loads.
    private var senderDisplayName: String {
        if let f = detail?.from, !f.isEmpty {
            let name = f.components(separatedBy: "<").first?
                .trimmingCharacters(in: .whitespaces) ?? ""
            if !name.isEmpty { return name }
        }
        if !message.fromName.isEmpty { return message.fromName }
        return message.fromEmail
    }

    private var senderAddress: String {
        if let f = detail?.from,
           let open = f.firstIndex(of: "<"), let close = f.lastIndex(of: ">"),
           open < close {
            let addr = String(f[f.index(after: open)..<close])
                .trimmingCharacters(in: .whitespaces)
            if !addr.isEmpty { return addr }
        }
        return message.fromEmail
    }

    private static let stampFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private var receivedText: String {
        if let date = MailDates.parse(detail?.received) ?? message.received {
            return Self.stampFormat.string(from: date)
        }
        return detail?.received ?? ""
    }

    /// The ambient-focus line for this message. Built from the list row alone
    /// (never the loaded detail) so it's byte-identical on appear and
    /// disappear — the disappear handler compares against it.
    private var emailFocus: String {
        let received = message.received.map { Self.stampFormat.string(from: $0) } ?? ""
        return "[FOCUS] Ido is viewing a work email in his Amwell inbox.\n"
            + "from: \(message.fromName) <\(message.fromEmail)>\n"
            + "subject: \(message.subject)\n"
            + "received: \(received)\n"
            + "message_id: \(message.id)\n"
            + "preview: \(String(message.preview.prefix(280)))"
    }
}

/// Renders the message HTML dark, like Outlook mobile's dark reading pane.
/// Mail is authored for light backgrounds, so instead of guessing at inline
/// colors the frame uses the classic soft-invert transform (invert +
/// hue-rotate on the page, re-inverted on images/video) — whites land near
/// Outlook's #1B1A19, text lands near-white, hues survive, pictures stay
/// true. JavaScript is off, tapped links open in Safari, and the page is
/// wrapped in a responsive frame so fixed-width newsletters shrink instead
/// of overflow.
struct MailBodyView: UIViewRepresentable {
    let html: String

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedHTML: String?      // change-detection key (the raw source html)
        var renderedPage: String?    // exactly what was loaded (capped + framed)

        // If the web content process is jetsam-killed under memory pressure, the
        // view goes blank rather than taking the whole app down. Reload the same
        // capped page into the fresh process so the reader recovers on its own —
        // never the full uncapped source, which could re-trigger the kill.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            if let page = renderedPage {
                webView.loadHTMLString(page, baseURL: nil)
            }
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Taps leave for Safari; the webview itself never navigates away.
            if navigationAction.navigationType == .linkActivated {
                if let url = navigationAction.request.url,
                   let scheme = url.scheme?.lowercased(),
                   ["http", "https", "mailto", "tel"].contains(scheme) {
                    UIApplication.shared.open(url, options: [:], completionHandler: nil)
                }
                decisionHandler(.cancel)
                return
            }
            // The only allowed frame load is our own loadHTMLString
            // (about:blank); meta-refresh and friends are blocked.
            let scheme = navigationAction.request.url?.scheme?.lowercased() ?? "about"
            decisionHandler(scheme == "about" ? .allow : .cancel)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = false
        config.defaultWebpagePreferences = prefs
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.isOpaque = true
        // The message body renders on a clean light page (see page(for:)), so the
        // frame and overscroll match it — a white ground, not the old dark frame.
        web.backgroundColor = .white
        web.scrollView.backgroundColor = .white
        web.scrollView.bounces = true
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        guard context.coordinator.loadedHTML != html else { return }
        context.coordinator.loadedHTML = html
        // Corporate/Amwell mail can be hundreds of KB of nested tables and
        // inline base64 images. Combined with the full-page invert filter (a
        // single large composited layer), a huge message can spike memory hard
        // on Mac Catalyst and get the app jetsam-killed ("quit unexpectedly").
        // Cap the body so an enormous message still renders its top without the
        // memory blow-up. Cut on a tag boundary when possible so we don't slice
        // mid-element.
        let cap = 700_000
        var safe = html
        if safe.count > cap {
            let head = String(safe.prefix(cap))
            if let lt = head.range(of: "<", options: .backwards) {
                safe = String(head[..<lt.lowerBound])
            } else {
                safe = head
            }
            safe += "\n<p style=\"opacity:.6;font-style:italic\">… message truncated for display — open in Outlook to see the rest.</p>"
        }
        let page = Self.page(for: safe)
        context.coordinator.renderedPage = page
        web.loadHTMLString(page, baseURL: nil)
    }

    /// Outlook-style dark reading frame: responsive viewport, fluid images
    /// and tables, long words wrapped, and the soft-invert dark transform.
    /// The page is authored light (white ground, #111 text, 16px body) and
    /// the filter flips it: 0.94 invert keeps blacks off pure-white glare,
    /// hue-rotate(180deg) puts brand colors back near their real hue, and
    /// media elements get the same filter again to cancel it out.
    static func page(for html: String) -> String {
        """
        <!DOCTYPE html><html><head>\
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=3">\
        <style>\
        /* NO whole-page CSS filter: a page-wide filter forces the entire
           message into one large composited layer, which on Mac Catalyst
           spikes memory on heavy corporate mail and gets the app jetsam-killed
           ("quit unexpectedly"). Render the message on a clean light page —
           stability first; a dark re-theme can return once verified safe. */
        html,body{margin:0;padding:12px;background:#fff;color:#111;\
        font:16px -apple-system,system-ui,sans-serif;\
        -webkit-text-size-adjust:100%;word-wrap:break-word;overflow-wrap:break-word}\
        img{max-width:100%!important;height:auto!important}\
        table{max-width:100%!important;table-layout:auto}\
        td,th{word-break:break-word}\
        a{color:#0f6cbd}\
        </style>\
        </head><body>\(html)</body></html>
        """
    }
}

// MARK: - QuickLook attachment preview

/// Identifiable wrapper so `.sheet(item:)` can drive the QuickLook sheet
/// from a plain file URL.
struct PreviewFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// The system QuickLook viewer — the same renderer Outlook hands attachments
/// to: Word/Excel/PowerPoint, PDF and images with pinch-zoom, paging and the
/// share button, all built in.
struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController,
                               previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        // `.sheet(item:)` recreates the representable per PreviewFile, so the
        // coordinator's URL is always current; nothing to refresh here.
    }
}
