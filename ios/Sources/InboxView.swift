import Combine
import SwiftUI
import UIKit
import WebKit

/// Native inbox: the same mailbox the web app shows, read on the phone with
/// Outlook mobile's anatomy — sender avatars, unread accent, green full-swipe
/// Archive, blue Read/Unread swipe, and a reading pane that renders on white
/// with responsive HTML, exactly like real mail.

// MARK: - Cross-tab wiring

extension Notification.Name {
    /// Posted by the mail reader's "Ask Scarlet" action; RootView (which owns
    /// the live Conversation) observes it, switches to Talk, and delivers the
    /// question.
    static let scarletAskAboutEmail = Notification.Name("scarletAskAboutEmail")
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
}

/// A fully opened message, as `op=mailread` returns it.
struct MailDetail {
    let subject: String
    let from: String
    let to: String
    let cc: String
    let received: String
    let html: String
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

    /// Rows archived locally: a refresh must not resurrect them while the
    /// Graph move is still settling.
    private var pendingArchiveIds: Set<String> = []
    /// Local read/unread flips that win over a stale server snapshot until
    /// the server catches up.
    private var unreadOverrides: [String: Bool] = [:]

    func load() async {
        guard TokenStore.token != nil else {
            messages = []
            errorText = "Locked — unlock Scarlet to see the inbox."
            return
        }
        if messages.isEmpty { loading = true }
        errorText = ""
        defer { loading = false }
        do {
            let data = try await Self.request("op=mailinbox", method: "GET")
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
                    importance: (m["importance"] as? String) ?? "normal"
                )
            }
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
        return MailDetail(
            subject: Self.stringy(obj["subject"]),
            from: Self.stringy(obj["from"]),
            to: Self.stringy(obj["to"]),
            cc: Self.stringy(obj["cc"]),
            received: Self.stringy(obj["received"]),
            html: Self.stringy(obj["html"])
        )
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
    @State private var showCompose = false

    private let scarletRose = Color(red: 1, green: 0.35, blue: 0.42)

    var body: some View {
        NavigationStack {
            content
                .background(ScarletBackground().ignoresSafeArea())
                .navigationTitle("Inbox")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Link(destination: AppConfig.fullAppURL) {
                            Image("ScarletMark")
                                .resizable()
                                .scaledToFill()
                                .frame(width: 30, height: 30)
                                .clipShape(Circle())
                                .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        // New mail: Scarlet drafts it in the native studio.
                        Button {
                            showCompose = true
                        } label: {
                            Image(systemName: "square.and.pencil")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            Task { await model.load() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(model.loading)
                    }
                }
                .sheet(isPresented: $showCompose) {
                    DraftView(seed: nil)
                        .preferredColorScheme(.dark)
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
                ForEach(model.messages) { message in
                    NavigationLink {
                        MailDetailView(message: message, model: model)
                    } label: {
                        InboxRow(message: message, accent: OutlookStyle.accentBlue)
                    }
                    .listRowBackground(Color.clear)
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
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .refreshable { await model.load() }
        }
    }
}

/// One row, Outlook-mobile anatomy on dark: unread accent bar, initials
/// avatar, sender / subject / one-line preview, trailing time, paperclip on
/// the subject line, high-importance mark.
struct InboxRow: View {
    let message: MailMessage
    let accent: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(accent)
                .frame(width: 3)
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
                        .font(.system(size: 13))
                        .foregroundStyle(message.unread ? accent : .secondary)
                }
                HStack(spacing: 5) {
                    Text(message.subject)
                        .font(.system(size: 15, weight: message.unread ? .semibold : .regular))
                        .foregroundStyle(Color(red: 0.96, green: 0.94, blue: 0.94)
                            .opacity(message.unread ? 1 : 0.85))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    if message.attachments {
                        Image(systemName: "paperclip")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(message.preview)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
        let f = DateFormatter(); f.dateFormat = "EEE"; return f
    }()
    private static let dayFormat: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d"; return f
    }()
    private static let yearFormat: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d, yyyy"; return f
    }()

    /// Outlook's ladder: today → time, this week → weekday, this year →
    /// "MMM d", older → "MMM d, yyyy".
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
    @Environment(\.dismiss) private var dismiss

    @State private var detail: MailDetail?
    @State private var failed = false
    @State private var showDraft = false
    @State private var showRecipients = false

    private let scarletRose = Color(red: 1, green: 0.35, blue: 0.42)

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(.white.opacity(0.15))
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
            DraftView(seed: DraftSeed(
                messageId: message.id,
                fromName: message.fromName,
                fromEmail: message.fromEmail,
                subject: message.subject,
                preview: message.preview
            ))
            .preferredColorScheme(.dark)
        }
        .task {
            model.markRead(message.id)
            await fetch()
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
