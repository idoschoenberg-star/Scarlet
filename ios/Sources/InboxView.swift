import Combine
import QuickLook
import SwiftUI
import UIKit
import WebKit

/// Native inbox: the same mailbox the web app shows, read on the phone with
/// Outlook mobile's anatomy — Focused|Other pill, date section buckets,
/// sender avatars, unread blue dot, flagged-row tint, green full-swipe
/// Archive, blue Read/Unread swipe, and a reading pane that renders on white
/// with responsive HTML, exactly like real mail.

// MARK: - Cross-tab wiring

extension Notification.Name {
    /// Posted by the mail reader's "Ask Scarlet" action; RootView (which owns
    /// the live Conversation) observes it, switches to Talk, and delivers the
    /// question.
    static let scarletAskAboutEmail = Notification.Name("scarletAskAboutEmail")
    /// Posted by Conversation when the compose_draft voice tool starts a
    /// draft; RootView presents the drafting sheet in attach mode.
    static let scarletVoiceDraftStarted = Notification.Name("scarletVoiceDraftStarted")
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
    let flagged: Bool
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

// MARK: - Model

@MainActor
final class InboxModel: ObservableObject {
    @Published var messages: [MailMessage] = []
    @Published var loading = false
    @Published var errorText = ""
    /// Focused | Other pill. Switch via `setTab`, which reloads.
    @Published var tab: MailTab = .focused

    /// Rows archived locally: a refresh must not resurrect them while the
    /// Graph move is still settling.
    private var pendingArchiveIds: Set<String> = []
    /// Local read/unread flips that win over a stale server snapshot until
    /// the server catches up.
    private var unreadOverrides: [String: Bool] = [:]
    /// Monotonic load token: a load that finishes after a newer one started
    /// (e.g. a slow Focused fetch landing after a switch to Other) is dropped.
    private var loadGeneration = 0

    /// Pill tap: swap the tab and refetch. The old tab's rows clear right
    /// away so a slow network never shows Focused rows under "Other".
    func setTab(_ newTab: MailTab) {
        guard newTab != tab else { return }
        tab = newTab
        messages = []
        Task { await load() }
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
            var fetched: [MailMessage] = ((obj["messages"] as? [[String: Any]]) ?? []).compactMap { m in
                guard let id = m["id"] as? String else { return nil }
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
            }
            unreadOverrides = unreadOverrides.filter { listed.contains($0.key) }
            messages = fetched
        } catch {
            guard generation == loadGeneration else { return }
            errorText = "Couldn't reach the inbox — check your connection."
        }
    }

    /// Optimistic archive: the row leaves the list immediately; if the server
    /// says no, it comes back where it was.
    func archive(_ message: MailMessage) {
        let index = messages.firstIndex { $0.id == message.id }
        if let index { messages.remove(at: index) }
        pendingArchiveIds.insert(message.id)
        Task {
            do {
                let data = try await Self.request("op=mailarchive", method: "POST",
                                                  body: ["id": message.id])
                let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                guard (obj?["ok"] as? Bool) == true else { throw URLError(.badServerResponse) }
            } catch {
                pendingArchiveIds.remove(message.id)
                let at = min(index ?? messages.count, messages.count)
                messages.insert(message, at: at)
                errorText = "Couldn't archive that one — it's back in the list."
            }
        }
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

/// Outlook mobile's action colors, shared by list and reader.
enum OutlookStyle {
    static let archiveGreen = Color(red: 0.06, green: 0.5, blue: 0.24)
    static let accentBlue = Color(red: 0.0, green: 0.47, blue: 0.83)
    /// The red follow-up flag glyph on a row's subject line.
    static let flagRed = Color(red: 0.91, green: 0.28, blue: 0.34)
    /// Flagged rows sit on a subtle dark-yellow wash, like Outlook mobile.
    static let flaggedRowTint = Color(red: 0.25, green: 0.20, blue: 0.02).opacity(0.55)
    /// Focused | Other pill: darker track, lighter capsule for the selection.
    static let pillTrack = Color(white: 0.16)
    static let pillSelected = Color(white: 0.33)
}

// MARK: - Sender avatar

/// Outlook-style initials circle: deterministic color from the address, so a
/// sender keeps the same color across launches.
struct SenderAvatar: View {
    let name: String
    let email: String
    var size: CGFloat = 40

    private static let palette: [Color] = [
        Color(red: 0.00, green: 0.47, blue: 0.83),
        Color(red: 0.53, green: 0.34, blue: 0.65),
        Color(red: 0.80, green: 0.29, blue: 0.16),
        Color(red: 0.06, green: 0.50, blue: 0.24),
        Color(red: 0.75, green: 0.21, blue: 0.47),
        Color(red: 0.09, green: 0.45, blue: 0.50),
        Color(red: 0.85, green: 0.48, blue: 0.09),
        Color(red: 0.35, green: 0.38, blue: 0.71),
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

    private var seed: String {
        email.isEmpty ? name.lowercased() : email.lowercased()
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

    private let scarletRose = Color(red: 1, green: 0.35, blue: 0.42)

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                headerBar
                tabPills
                content
            }
            .background(ScarletBackground().ignoresSafeArea())
            // The Outlook-style header row replaces the system bar on the
            // list screen; pushed screens (reader) keep theirs for Back.
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showCompose) {
                DraftView(seed: nil)
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
            // Account avatar placeholder ("IS" — no photo available); taps
            // through to the full web app, as the ScarletMark used to.
            Link(destination: AppConfig.fullAppURL) {
                ZStack {
                    Circle().fill(Color(white: 0.30))
                    Text("IS")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 38, height: 38)
            }
            Text("Inbox")
                .font(.system(size: 34, weight: .heavy))
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
            Button {
                Task { await model.load() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white)
            }
            .disabled(model.loading)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    /// Focused | Other, Outlook's pill-in-a-track toggle.
    private var tabPills: some View {
        HStack {
            HStack(spacing: 0) {
                ForEach(MailTab.allCases, id: \.self) { t in
                    Button {
                        model.setTab(t)
                    } label: {
                        Text(t.title)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 7)
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
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var content: some View {
        if model.loading && model.messages.isEmpty {
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
                    .tint(scarletRose)
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
                    // Today's rows lead with no header, like Outlook; older
                    // buckets get a big bold section title.
                    if let title = group.title {
                        Text(title)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.top, 18)
                            .padding(.bottom, 2)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                    ForEach(group.messages) { message in
                        NavigationLink {
                            MailDetailView(message: message, model: model)
                        } label: {
                            InboxRow(message: message, accent: OutlookStyle.accentBlue)
                        }
                        .listRowBackground(message.flagged
                            ? OutlookStyle.flaggedRowTint : Color.clear)
                        .listRowSeparatorTint(.white.opacity(0.12))
                        // Outlook's swipes: long-swipe left = green Archive,
                        // long-swipe right = blue Read/Unread flip.
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
                                model.toggleRead(message)
                            } label: {
                                Label(message.unread ? "Read" : "Unread",
                                      systemImage: message.unread
                                          ? "envelope.open.fill" : "envelope.badge.fill")
                            }
                            .tint(OutlookStyle.accentBlue)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .refreshable { await model.load() }
        }
    }

    // MARK: date buckets (Outlook grouping: today headerless, then named)

    private struct MailGroup: Identifiable {
        let id: String
        let title: String?
        let messages: [MailMessage]
    }

    private var groups: [MailGroup] {
        let cal = Calendar.current
        let now = Date()
        var today: [MailMessage] = []
        var yesterday: [MailMessage] = []
        var thisWeek: [MailMessage] = []
        var earlier: [MailMessage] = []
        for m in model.messages {
            guard let d = m.received else {
                earlier.append(m)
                continue
            }
            if cal.isDateInToday(d) {
                today.append(m)
            } else if cal.isDateInYesterday(d) {
                yesterday.append(m)
            } else {
                let days = cal.dateComponents([.day],
                                              from: cal.startOfDay(for: d),
                                              to: cal.startOfDay(for: now)).day ?? 99
                if days >= 0 && days < 7 {
                    thisWeek.append(m)
                } else {
                    earlier.append(m)
                }
            }
        }
        var out: [MailGroup] = []
        if !today.isEmpty { out.append(MailGroup(id: "today", title: nil, messages: today)) }
        if !yesterday.isEmpty {
            out.append(MailGroup(id: "yesterday", title: "Yesterday", messages: yesterday))
        }
        if !thisWeek.isEmpty {
            out.append(MailGroup(id: "thisweek", title: "This Week", messages: thisWeek))
        }
        if !earlier.isEmpty {
            out.append(MailGroup(id: "earlier", title: "Earlier", messages: earlier))
        }
        return out
    }
}

/// One row, Outlook-mobile anatomy on dark: unread blue dot at the left
/// edge, initials avatar, sender / subject / two-line preview, trailing
/// date, red flag + paperclip on the subject line, high-importance mark.
struct InboxRow: View {
    let message: MailMessage
    let accent: Color

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
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
                HStack(spacing: 5) {
                    Text(senderName)
                        .font(.system(size: 17, weight: message.unread ? .bold : .semibold))
                        .foregroundStyle(message.unread ? .white : .white.opacity(0.8))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if message.importance == "high" {
                        Text("!")
                            .font(.subheadline.bold())
                            .foregroundStyle(.red)
                    }
                    Spacer(minLength: 8)
                    Text(timeLabel)
                        .font(.system(size: 15))
                        .foregroundStyle(message.unread ? accent : .secondary)
                }
                HStack(spacing: 6) {
                    Text(message.subject)
                        .font(.system(size: 15, weight: message.unread ? .semibold : .regular))
                        .foregroundStyle(Color(red: 0.96, green: 0.94, blue: 0.94)
                            .opacity(message.unread ? 1 : 0.85))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    if message.flagged {
                        Image(systemName: "flag.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(OutlookStyle.flagRed)
                    }
                    if message.attachments {
                        Image(systemName: "paperclip")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(message.preview)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
        }
        .padding(.vertical, 5)
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
    @State private var showDraft = false
    @State private var showRecipients = false
    /// Attachment currently downloading (its chip swaps icon → spinner).
    @State private var downloadingAttachmentId: String?
    /// Small red footnote under the chips; cleared on the next tap.
    @State private var attachmentError = ""
    /// Non-nil drives the QuickLook sheet.
    @State private var previewFile: PreviewFile?

    private let scarletRose = Color(red: 1, green: 0.35, blue: 0.42)

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(.white.opacity(0.15))
            // Outlook puts attachments right under the header, above the
            // body. A fixed-height horizontal strip: it never joins the
            // web view's vertical scroll surface.
            if let detail, !detail.attachments.isEmpty {
                attachmentsRow(detail.attachments)
                Divider().overlay(.white.opacity(0.15))
            }
            bodyPane
            Divider().overlay(.white.opacity(0.15))
            actionBar
        }
        .background(ScarletBackground().ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        askScarlet()
                    } label: {
                        Label("Ask Scarlet about this email", systemImage: "sparkles")
                    }
                    Link(destination: AppConfig.fullAppURL) {
                        Label("Open full app", systemImage: "arrow.up.forward.app")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showDraft) {
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
            .preferredColorScheme(.dark)
        }
        // QuickLook: pinch-zoom, paging, share — the Outlook attachment
        // experience, straight from the system viewer.
        .sheet(item: $previewFile) { file in
            QuickLookPreview(url: file.url)
                .ignoresSafeArea()
        }
        .task {
            model.markRead(message.id)
            await fetch()
        }
        // Ambient focus: this email while the reader is up; back to the list
        // on the way out — unless another screen (say, the Talk tab) already
        // claimed focus during the transition.
        .onAppear { convo.setFocus(emailFocus) }
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
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.10), lineWidth: 1))
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
                    previewFile = PreviewFile(url: url)
                case .link(let url):
                    UIApplication.shared.open(url)
                case .failure(let text):
                    attachmentError = text
                }
            } catch {
                attachmentError = "Couldn't open that attachment — try again."
            }
        }
    }

    /// Temp destination that keeps the real filename (extension included —
    /// that's what makes QuickLook pick the right renderer) but strips path
    /// separators so a hostile name can't escape the temp directory.
    private static func tempFileURL(for name: String) -> URL {
        var clean = name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty || clean == "." || clean == ".." { clean = "attachment" }
        return FileManager.default.temporaryDirectory.appendingPathComponent(clean)
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
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color(red: 0.98, green: 0.92, blue: 0.92))
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
                .tint(scarletRose)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: action bar (Reply keeps the native DraftView flow)

    private var actionBar: some View {
        HStack(spacing: 10) {
            actionButton("Reply", icon: "arrowshape.turn.up.left.fill",
                         tint: OutlookStyle.accentBlue) {
                showDraft = true
            }
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
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                Text(label).font(.footnote.weight(.semibold))
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(tint.opacity(0.22), in: Capsule())
            .overlay(Capsule().stroke(tint.opacity(0.5), lineWidth: 1))
            .foregroundStyle(.white)
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

/// Renders the message HTML on white, like Outlook — mail is written for
/// light backgrounds, so the reading pane stays light inside the dark app.
/// JavaScript is off, tapped links open in Safari, and the page is wrapped in
/// a responsive frame so fixed-width newsletters shrink instead of overflow.
struct MailBodyView: UIViewRepresentable {
    let html: String

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedHTML: String?

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Taps leave for Safari; the webview itself never navigates away.
            if navigationAction.navigationType == .linkActivated {
                if let url = navigationAction.request.url,
                   let scheme = url.scheme?.lowercased(),
                   ["http", "https", "mailto", "tel"].contains(scheme) {
                    UIApplication.shared.open(url)
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
        web.backgroundColor = .white
        web.scrollView.backgroundColor = .white
        web.scrollView.bounces = true
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        guard context.coordinator.loadedHTML != html else { return }
        context.coordinator.loadedHTML = html
        web.loadHTMLString(Self.page(for: html), baseURL: nil)
    }

    /// Outlook-style reading frame: responsive viewport, fluid images and
    /// tables, long words wrapped — the classic newsletter-overflow fix.
    static func page(for html: String) -> String {
        """
        <!DOCTYPE html><html><head>\
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=3">\
        <style>\
        html,body{margin:0;padding:12px;background:#fff;color:#111;font:-apple-system-body;\
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
