import SwiftUI
import WebKit

/// Native inbox: the same mailbox the web app shows, read on the phone with
/// Outlook's anatomy — unread accent bar, sender/subject/preview rows, and
/// swipe-left to archive. Reading pane renders on white, like real mail.

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

    func load() async {
        if messages.isEmpty { loading = true }
        errorText = ""
        defer { loading = false }
        do {
            let data = try await Self.request("op=mailinbox", method: "GET")
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            messages = ((obj["messages"] as? [[String: Any]]) ?? []).compactMap { m in
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
        } catch {
            errorText = "Couldn't reach the inbox — check your connection."
        }
    }

    /// Optimistic archive: the row leaves the list immediately; if the server
    /// says no, it comes back where it was.
    func archive(_ message: MailMessage) {
        let index = messages.firstIndex { $0.id == message.id }
        if let index { messages.remove(at: index) }
        Task {
            do {
                let data = try await Self.request("op=mailarchive", method: "POST",
                                                  body: ["id": message.id])
                let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                guard (obj?["ok"] as? Bool) == true else { throw URLError(.badServerResponse) }
            } catch {
                let at = min(index ?? messages.count, messages.count)
                messages.insert(message, at: at)
                errorText = "Couldn't archive that one — it's back in the list."
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
    func markRead(_ id: String) {
        if let i = messages.firstIndex(where: { $0.id == id }) { messages[i].unread = false }
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

// MARK: - Inbox list

struct InboxView: View {
    @StateObject private var model = InboxModel()

    private let outlookBlue = Color(red: 0.16, green: 0.6, blue: 0.96)
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
                        Button {
                            Task { await model.load() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(model.loading)
                    }
                }
        }
        .task { await model.load() }
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
                        InboxRow(message: message, accent: outlookBlue)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(.white.opacity(0.12))
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button {
                            model.archive(message)
                        } label: {
                            Label("Archive", systemImage: "archivebox.fill")
                        }
                        .tint(outlookBlue)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .refreshable { await model.load() }
        }
    }
}

/// One row, Outlook-anatomy on dark: unread accent bar, sender, subject,
/// one-line preview, trailing time, paperclip and high-importance marks.
struct InboxRow: View {
    let message: MailMessage
    let accent: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(accent)
                .frame(width: 3)
                .opacity(message.unread ? 1 : 0)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(senderName)
                        .font(.subheadline.weight(message.unread ? .bold : .regular))
                        .foregroundStyle(message.unread ? .white : .white.opacity(0.75))
                        .lineLimit(1)
                    if message.importance == "high" {
                        Text("!")
                            .font(.subheadline.bold())
                            .foregroundStyle(.red)
                    }
                    if message.attachments {
                        Image(systemName: "paperclip")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text(timeLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(message.subject)
                    .font(.subheadline.weight(message.unread ? .semibold : .regular))
                    .foregroundStyle(Color(red: 0.96, green: 0.94, blue: 0.94))
                    .lineLimit(1)
                Text(message.preview)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }

    private var senderName: String {
        message.fromName.isEmpty ? message.fromEmail : message.fromName
    }

    private static let todayFormat: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
    private static let dayFormat: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d"; return f
    }()

    private var timeLabel: String {
        guard let d = message.received else { return "" }
        return Calendar.current.isDateInToday(d)
            ? Self.todayFormat.string(from: d)
            : Self.dayFormat.string(from: d)
    }
}

// MARK: - Detail

struct MailDetailView: View {
    let message: MailMessage
    @ObservedObject var model: InboxModel
    @Environment(\.dismiss) private var dismiss

    @State private var detail: MailDetail?
    @State private var failed = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(.white.opacity(0.15))
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
                    .tint(Color(red: 1, green: 0.35, blue: 0.42))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(ScarletBackground().ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    model.archive(message)
                    dismiss()
                } label: {
                    Image(systemName: "archivebox.fill")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                // The drafting studio lives in the full app; native reply later.
                Link(destination: AppConfig.fullAppURL) {
                    Text("Reply in Scarlet")
                        .font(.footnote.weight(.semibold))
                }
            }
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(subjectText)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color(red: 0.98, green: 0.92, blue: 0.92))
            if let detail {
                if !detail.from.isEmpty {
                    Text("From: \(detail.from)")
                        .font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                }
                if !detail.to.isEmpty {
                    Text("To: \(detail.to)")
                        .font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                }
                if !detail.cc.isEmpty {
                    Text("Cc: \(detail.cc)")
                        .font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            if !receivedText.isEmpty {
                Text(receivedText)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var subjectText: String {
        if let s = detail?.subject, !s.isEmpty { return s }
        return message.subject
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
struct MailBodyView: UIViewRepresentable {
    let html: String

    final class Coordinator {
        var loadedHTML: String?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let web = WKWebView()
        web.isOpaque = true
        web.backgroundColor = .white
        web.scrollView.backgroundColor = .white
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        guard context.coordinator.loadedHTML != html else { return }
        context.coordinator.loadedHTML = html
        let page = """
        <html><head><meta name="viewport" content="width=device-width,initial-scale=1"></head>\
        <body style="background:#fff;color:#111;font-family:-apple-system;padding:12px">\(html)</body></html>
        """
        web.loadHTMLString(page, baseURL: nil)
    }
}
