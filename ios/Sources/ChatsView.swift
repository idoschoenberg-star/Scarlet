import AVKit
import Foundation
import SwiftUI
import UIKit

/// The Chats hub: three real messaging channels — Teams, WhatsApp, iMessage —
/// each list and thread mirroring its native app's dark-mode look. One shared
/// generic model + row layer, parameterized per channel; the same edge-function
/// plumbing as the rest of the app (app-api?v=2 + x-scarlet-token).

// MARK: - Channel

/// Which messenger is showing. Raw values double as the focus-line channel key.
enum ChatChannel: String, CaseIterable, Identifiable {
    case teams
    case whatsapp
    case imessage

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .teams: return "Teams"
        case .whatsapp: return "WhatsApp"
        case .imessage: return "iMessage"
        }
    }

    var icon: String {
        switch self {
        case .teams: return "person.2.fill"
        case .whatsapp: return "phone.fill"
        case .imessage: return "message.fill"
        }
    }

    /// The channel's page accent. Teams' #6264A7 is brightened for the dark
    /// background; WhatsApp is its phone-green; iMessage is Messages blue.
    var accent: Color {
        switch self {
        case .teams: return Color(red: 0.55, green: 0.56, blue: 0.85)
        case .whatsapp: return Color(red: 0.14, green: 0.80, blue: 0.44)
        case .imessage: return Color(red: 0.04, green: 0.52, blue: 1.0)
        }
    }

    var emptyText: String {
        switch self {
        case .teams: return "No Teams chats yet"
        case .whatsapp: return "No WhatsApp chats yet"
        case .imessage: return "No iMessage chats yet"
        }
    }

    var listQuery: String {
        switch self {
        case .teams: return "op=teams_chats"
        case .whatsapp: return "op=wa_chats"
        case .imessage: return "op=im_chats"
        }
    }

    func threadQuery(id: String) -> String {
        let encoded = ChatsAPI.encode(id)
        switch self {
        case .teams: return "op=teams_thread&id=\(encoded)"
        case .whatsapp: return "op=wa_thread&jid=\(encoded)"
        case .imessage: return "op=im_thread&handle=\(encoded)"
        }
    }
}

/// The list-level ambient-focus line, shared by the list's own appearance and
/// each thread's dismissal so both report the exact same thing.
private func chatsBrowsingFocus(_ channel: ChatChannel) -> String {
    "[FOCUS] Ido is browsing his \(channel.displayName) chats list."
}

// MARK: - Wire types

/// One chat-list row, shape-normalized across teams_chats / wa_chats / im_chats.
struct ChatSummary: Identifiable {
    /// Teams chat id, WhatsApp jid, or iMessage handle.
    let id: String
    let name: String
    let last: String
    let fromMe: Bool
    let ts: Date?
    /// Data URI (Teams), https URL (WhatsApp), or nil (iMessage / absent).
    let avatar: String?
    let isGroup: Bool
}

/// One thread message, oldest-first, shape-normalized across the three ops.
struct ChatMessage: Identifiable {
    let id: Int
    let ts: Date?
    let fromMe: Bool
    /// Teams `from` / WhatsApp `sender`; empty for iMessage and own messages.
    let sender: String
    let text: String
    /// WhatsApp photo messages: signed https image URL from `media_url`
    /// (valid ~1h). Always nil for Teams / iMessage.
    let mediaURL: URL?
    /// WhatsApp media MIME type from `media_type` (e.g. "image/jpeg",
    /// "video/mp4", "audio/ogg"). nil when absent — text messages, legacy
    /// payloads, other channels.
    let mediaType: String?
    /// WhatsApp outgoing delivery state: "sent" | "delivered" | "read".
    /// nil when absent — all incoming messages and other channels.
    let status: String?
}

// MARK: - Dates

/// Defensive timestamp parsing: ISO-8601 with and without fractional seconds,
/// plus unix-seconds numbers (WhatsApp sends either shape).
enum ChatDates {
    static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let isoPlain = ISO8601DateFormatter()

    static func parse(_ value: Any?) -> Date? {
        if let n = value as? NSNumber {
            return Date(timeIntervalSince1970: n.doubleValue)
        }
        if let s = value as? String, !s.isEmpty {
            if let d = isoPlain.date(from: s) ?? isoFractional.date(from: s) { return d }
            if let secs = Double(s) { return Date(timeIntervalSince1970: secs) }
        }
        return nil
    }
}

/// Display formatters, built once. List ladder: today → "14:05", this week →
/// "Tue", older → "12/7". Separators: today → time, else day + time.
enum ChatTimeFormat {
    static let time: DateFormatter = {
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none; return f
    }()
    static let weekday: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE"; return f
    }()
    static let shortDate: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d/M"; return f
    }()
    static let dayAndTime: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE d MMM, HH:mm"; return f
    }()

    static func listLabel(_ d: Date?) -> String {
        guard let d else { return "" }
        let cal = Calendar.current
        if cal.isDateInToday(d) { return time.string(from: d) }
        let days = cal.dateComponents([.day],
                                      from: cal.startOfDay(for: d),
                                      to: cal.startOfDay(for: Date())).day ?? 99
        if days >= 0 && days < 7 { return weekday.string(from: d) }
        return shortDate.string(from: d)
    }

    static func separatorLabel(_ d: Date) -> String {
        if Calendar.current.isDateInToday(d) { return time.string(from: d) }
        return dayAndTime.string(from: d)
    }
}

// MARK: - Plumbing (same shape as DraftModel: apiBase + v=2 + x-scarlet-token)

enum ChatsAPI {
    static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }

    static func request(_ query: String, method: String,
                        body: [String: Any]? = nil) async throws -> Data {
        guard let url = URL(string: "\(AppConfig.apiBase)/app-api?v=2&\(query)") else {
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
}

// MARK: - List model

@MainActor
final class ChatListModel: ObservableObject {
    @Published var channel: ChatChannel = .teams
    @Published var chats: [ChatSummary] = []
    @Published var loading = false
    @Published var errorText = ""

    /// Monotonic load token: a slow fetch landing after a channel switch is
    /// dropped (same discipline as InboxModel).
    private var loadGeneration = 0

    /// Segment tap: swap the channel and refetch. The old channel's rows
    /// clear right away so a slow network never shows Teams rows under
    /// "WhatsApp".
    func setChannel(_ newChannel: ChatChannel) {
        guard newChannel != channel else { return }
        channel = newChannel
        chats = []
        errorText = ""
        Task { await load() }
    }

    func load() async {
        guard TokenStore.token != nil else {
            chats = []
            errorText = "Locked — unlock Scarlet to see your chats."
            return
        }
        if chats.isEmpty { loading = true }
        errorText = ""
        loadGeneration += 1
        let generation = loadGeneration
        defer { if generation == loadGeneration { loading = false } }
        let want = channel
        do {
            let data = try await ChatsAPI.request(want.listQuery, method: "GET")
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let fetched = Self.parseChats(obj, channel: want)
            guard generation == loadGeneration, want == channel else { return }
            chats = fetched
        } catch {
            guard generation == loadGeneration, want == channel else { return }
            errorText = "Couldn't reach \(want.displayName) — check your connection."
        }
    }

    private static func parseChats(_ obj: [String: Any],
                                   channel: ChatChannel) -> [ChatSummary] {
        let raw = (obj["chats"] as? [[String: Any]]) ?? []
        return raw.compactMap { c in
            let idField: String?
            switch channel {
            case .teams: idField = c["id"] as? String
            case .whatsapp: idField = c["jid"] as? String
            case .imessage: idField = c["handle"] as? String
            }
            guard let id = idField, !id.isEmpty else { return nil }
            let name = (c["name"] as? String) ?? ""
            return ChatSummary(
                id: id,
                name: name.isEmpty ? id : name,
                last: (c["last"] as? String) ?? "",
                fromMe: (c["from_me"] as? Bool) ?? false,
                ts: ChatDates.parse(c["ts"]),
                avatar: c["avatar"] as? String,
                isGroup: (c["group"] as? Bool) ?? false
            )
        }
    }
}

// MARK: - Thread model

@MainActor
final class ChatThreadModel: ObservableObject {
    let channel: ChatChannel
    let chat: ChatSummary

    @Published var messages: [ChatMessage] = []
    @Published var loading = false
    @Published var errorText = ""
    @Published var sending = false
    /// Teams only: a stage landed — show the inline confirmation card.
    @Published var stagedNote = false
    /// "Open Teams" deep link, when teams_stage returned a url/link string.
    @Published var stagedURL: URL?
    /// Bumps on every successful load (and optimistic append) so the view can
    /// re-set the thread focus and scroll to the newest message.
    @Published var loadStamp = 0

    private var timer: Timer?
    private var loadGeneration = 0

    nonisolated init(channel: ChatChannel, chat: ChatSummary) {
        self.channel = channel
        self.chat = chat
    }

    func load() async {
        if messages.isEmpty { loading = true }
        loadGeneration += 1
        let generation = loadGeneration
        defer { if generation == loadGeneration { loading = false } }
        do {
            let data = try await ChatsAPI.request(channel.threadQuery(id: chat.id),
                                                  method: "GET")
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let raw = (obj["messages"] as? [[String: Any]]) ?? []
            let fetched: [ChatMessage] = raw.enumerated().map { index, m in
                let sender: String
                switch channel {
                case .teams: sender = (m["from"] as? String) ?? ""
                case .whatsapp: sender = (m["sender"] as? String) ?? ""
                case .imessage: sender = ""
                }
                // Photo messages (WhatsApp today): tolerate absence — the key
                // simply isn't there for text messages or other channels.
                let mediaString = (m["media_url"] as? String) ?? ""
                // Media MIME type (WhatsApp media only): tolerate absence.
                let mediaTypeString = (m["media_type"] as? String) ?? ""
                // Delivery state (WhatsApp outgoing only): tolerate absence.
                let statusString = (m["status"] as? String) ?? ""
                return ChatMessage(
                    id: index,
                    ts: ChatDates.parse(m["ts"]),
                    fromMe: (m["from_me"] as? Bool) ?? false,
                    sender: sender,
                    text: (m["text"] as? String) ?? "",
                    mediaURL: mediaString.isEmpty ? nil : URL(string: mediaString),
                    mediaType: mediaTypeString.isEmpty ? nil : mediaTypeString,
                    status: statusString.isEmpty ? nil : statusString
                )
            }
            guard generation == loadGeneration else { return }
            errorText = ""
            messages = fetched
            loadStamp += 1
        } catch {
            guard generation == loadGeneration else { return }
            if messages.isEmpty {
                errorText = "Couldn't open this conversation — check your connection."
            }
        }
    }

    /// WhatsApp / iMessage direct send. Ido typed the text and tapped the send
    /// button — that IS the explicit approval (standing security rule, same as
    /// the web app). Returns true so the view clears the field only on success.
    func send(_ text: String) async -> Bool {
        guard channel != .teams, !sending else { return false }
        sending = true
        errorText = ""
        defer { sending = false }
        let op: String
        let body: [String: Any]
        if channel == .whatsapp {
            op = "op=wa_send"
            body = ["jid": chat.id, "text": text]
        } else {
            op = "op=im_send"
            body = ["to": chat.id, "text": text]
        }
        do {
            let data = try await ChatsAPI.request(op, method: "POST", body: body)
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if let err = obj["error"] as? String, !err.isEmpty {
                errorText = "Couldn't send — \(err)"
                return false
            }
            appendLocal(text)
            Task { await load() }
            return true
        } catch {
            errorText = "Couldn't send — check your connection. Your text is still here."
            return false
        }
    }

    /// Teams NEVER sends directly — standing security decision. teams_stage
    /// plants the message in the Teams composer; Ido taps Send inside Teams
    /// itself, so the final send always happens under his own finger.
    func stage(_ text: String) async -> Bool {
        guard channel == .teams, !sending else { return false }
        sending = true
        errorText = ""
        stagedNote = false
        stagedURL = nil
        defer { sending = false }
        do {
            let data = try await ChatsAPI.request("op=teams_stage", method: "POST",
                                                  body: ["chat": chat.id, "text": text])
            // Response shape is loose: maybe {ok}, maybe a url/link, maybe both.
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if let ok = obj["ok"] as? Bool, ok == false {
                errorText = (obj["error"] as? String) ?? "Couldn't stage that in Teams."
                return false
            }
            if let link = (obj["url"] as? String) ?? (obj["link"] as? String),
               let url = URL(string: link) {
                stagedURL = url
            }
            stagedNote = true
            return true
        } catch {
            errorText = "Couldn't stage that in Teams — check your connection."
            return false
        }
    }

    private func appendLocal(_ text: String) {
        messages.append(ChatMessage(id: messages.count, ts: Date(),
                                    fromMe: true, sender: "", text: text,
                                    mediaURL: nil, mediaType: nil, status: "sent"))
        loadStamp += 1
    }

    // MARK: 20s heartbeat — only while THIS thread is visible
    // (DraftModel's timer hygiene: build once, RunLoop .common, invalidate on
    // disappear so a closed thread never keeps polling.)

    func startPolling() {
        stopPolling()
        let t = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.load()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - Avatar

/// Stable hashed color for a chat sender name (WhatsApp group senders).
/// djb2 over UTF-8, bright palette that reads on dark bubbles.
private let chatSenderPalette: [Color] = [
    Color(red: 0.98, green: 0.55, blue: 0.45),
    Color(red: 0.45, green: 0.80, blue: 0.98),
    Color(red: 0.65, green: 0.85, blue: 0.45),
    Color(red: 0.95, green: 0.75, blue: 0.35),
    Color(red: 0.80, green: 0.60, blue: 0.98),
    Color(red: 0.40, green: 0.88, blue: 0.75),
    Color(red: 0.98, green: 0.60, blue: 0.80),
    Color(red: 0.70, green: 0.78, blue: 0.98),
]

private func chatSenderColor(_ name: String) -> Color {
    var h: UInt32 = 5381
    for b in name.lowercased().utf8 { h = h &* 33 &+ UInt32(b) }
    return chatSenderPalette[Int(h % UInt32(chatSenderPalette.count))]
}

/// 44pt chat avatar: Teams data-URI → decoded UIImage, WhatsApp https URL →
/// AsyncImage, anything else → the house initials circle (SenderAvatar).
struct ChatAvatarView: View {
    let name: String
    let avatar: String?
    var size: CGFloat = 44

    private static let dataImageCache = NSCache<NSString, UIImage>()

    var body: some View {
        if let avatar, avatar.hasPrefix("data:"), let img = Self.decoded(avatar) {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else if let avatar, avatar.hasPrefix("http"), let url = URL(string: avatar) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    SenderAvatar(name: name, email: "", size: size)
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
        } else {
            SenderAvatar(name: name, email: "", size: size)
        }
    }

    /// Base64 after the comma → UIImage, cached per URI so list scrolling
    /// doesn't re-decode.
    private static func decoded(_ uri: String) -> UIImage? {
        let key = uri as NSString
        if let hit = dataImageCache.object(forKey: key) { return hit }
        guard let comma = uri.firstIndex(of: ","),
              let data = Data(base64Encoded: String(uri[uri.index(after: comma)...]),
                              options: .ignoreUnknownCharacters),
              let img = UIImage(data: data) else { return nil }
        dataImageCache.setObject(img, forKey: key)
        return img
    }
}

// MARK: - Chats hub (list level)

struct ChatsView: View {
    @StateObject private var model = ChatListModel()
    @EnvironmentObject private var convo: Conversation

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                headerBar
                channelSwitcher
                content
            }
            .background(ScarletBackground().ignoresSafeArea())
            // Custom header on the list screen; pushed threads keep the
            // system bar for Back (same pattern as InboxView).
            .toolbar(.hidden, for: .navigationBar)
            // Ambient focus: the list reports itself on appearance and again
            // on every channel switch.
            .onAppear { convo.setFocus(chatsBrowsingFocus(model.channel)) }
            .onChange(of: model.channel) { _, newChannel in
                convo.setFocus(chatsBrowsingFocus(newChannel))
            }
        }
        // .task re-runs every time this tab is selected → refresh on appear.
        .task { await model.load() }
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            Text("Chats")
                .font(.system(size: 34, weight: .heavy))
                .foregroundStyle(.white)
            Spacer()
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

    /// Slim three-segment switcher; the selected segment tints in its
    /// channel's accent and restyles the whole page.
    private var channelSwitcher: some View {
        HStack(spacing: 4) {
            ForEach(ChatChannel.allCases) { ch in
                segment(ch)
            }
        }
        .padding(4)
        .background(Capsule().fill(.white.opacity(0.06)))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func segment(_ ch: ChatChannel) -> some View {
        Button {
            model.setChannel(ch)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: ch.icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(ch.displayName)
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(model.channel == ch ? ch.accent : .white.opacity(0.55))
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
                Capsule().fill(model.channel == ch
                    ? ch.accent.opacity(0.18) : Color.clear)
            )
            .overlay(
                Capsule().stroke(model.channel == ch
                    ? ch.accent.opacity(0.45) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var content: some View {
        if model.loading && model.chats.isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                Text("Fetching \(model.channel.displayName)…")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.chats.isEmpty && !model.errorText.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.title2).foregroundStyle(.secondary)
                Text(model.errorText)
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try again") { Task { await model.load() } }
                    .buttonStyle(.bordered)
                    .tint(model.channel.accent)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.chats.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: model.channel.icon)
                    .font(.title2).foregroundStyle(.secondary)
                Text(model.channel.emptyText)
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            chatList
        }
    }

    private var chatList: some View {
        List {
            if !model.errorText.isEmpty {
                Text(model.errorText)
                    .font(.footnote)
                    .foregroundStyle(Color(red: 0.91, green: 0.69, blue: 0.31))
                    .listRowBackground(Color.clear)
            }
            ForEach(model.chats) { chat in
                NavigationLink {
                    ChatThreadView(channel: model.channel, chat: chat)
                } label: {
                    ChatListRow(chat: chat, channel: model.channel)
                }
                .listRowBackground(Color.clear)
                .listRowSeparatorTint(.white.opacity(0.12))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { await model.load() }
    }
}

/// One chat row: 44pt avatar, name 17pt semibold, 2-line preview ("You: "
/// when the last message is Ido's), right-aligned relative time; WhatsApp
/// groups get a tiny person.3.fill glyph before the name.
struct ChatListRow: View {
    let chat: ChatSummary
    let channel: ChatChannel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ChatAvatarView(name: chat.name, avatar: chat.avatar, size: 44)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if channel == .whatsapp && chat.isGroup {
                        Image(systemName: "person.3.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Text(chat.name)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    Text(ChatTimeFormat.listLabel(chat.ts))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Text(preview)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
        }
        .padding(.vertical, 4)
    }

    private var preview: String {
        chat.fromMe ? "You: \(chat.last)" : chat.last
    }
}

// MARK: - Thread items (messages + >1h-gap time separators)

/// One rendered row: either a centered time separator or a message with its
/// pre-computed grouping (sender label on a run's first bubble, tighter
/// spacing inside a run — most iMessage-like, shared by all three threads).
private struct ChatThreadItem: Identifiable {
    let id: Int
    let message: ChatMessage?
    let separator: Date?
    let showSender: Bool
    let topSpacing: CGFloat
}

// MARK: - Thread view

struct ChatThreadView: View {
    let channel: ChatChannel
    let chat: ChatSummary

    @StateObject private var model: ChatThreadModel
    @EnvironmentObject private var convo: Conversation
    @State private var composeText = ""
    @FocusState private var composeFocused: Bool
    /// WhatsApp photo bubbles: tapped image → full-screen viewer sheet.
    @State private var photoItem: WAPhotoItem?
    /// WhatsApp video bubbles: tapped card → full-screen player sheet.
    /// (Parallel to photoItem on purpose — keeps the photo path untouched.)
    @State private var videoItem: WAVideoItem?
    /// WhatsApp voice notes: inline playback, one at a time. playingVoiceID
    /// is the ChatMessage.id currently playing (nil when idle/paused).
    @State private var voicePlayer: AVPlayer?
    @State private var playingVoiceID: Int?
    /// "Draft with Scarlet": non-nil presents the drafting studio seeded with
    /// this chat, its recent lines, and whatever was typed in the compose bar.
    @State private var scarletDraft: ChannelDraftSeed?

    init(channel: ChatChannel, chat: ChatSummary) {
        self.channel = channel
        self.chat = chat
        _model = StateObject(wrappedValue: ChatThreadModel(channel: channel, chat: chat))
    }

    var body: some View {
        VStack(spacing: 0) {
            messagesPane
            composeArea
        }
        .background(ScarletBackground().ignoresSafeArea())
        .navigationTitle(chat.name)
        .navigationBarTitleDisplayMode(.inline)
        // Refresh on appear, then the 20s heartbeat — only while visible.
        .task {
            await model.load()
            model.startPolling()
        }
        // Ambient focus: this thread on appear, then RE-set after each load so
        // the "recent messages" lines reflect what's actually on screen.
        .onAppear {
            convo.setFocus(threadFocus)
            // This screen owns the bottom edge (compose bar) — the presence
            // capsule must never float over it.
            NotificationCenter.default.post(name: .scarletBottomOwned,
                                            object: nil,
                                            userInfo: ["owned": true])
        }
        .onChange(of: model.loadStamp) { _, _ in
            convo.setFocus(threadFocus)
        }
        .onDisappear {
            NotificationCenter.default.post(name: .scarletBottomOwned,
                                            object: nil,
                                            userInfo: ["owned": false])
            model.stopPolling()
            // Voice-note hygiene: a closed thread never keeps playing audio.
            voicePlayer?.pause()
            voicePlayer = nil
            playingVoiceID = nil
            if composeFocused { convo.endTyping() }
            // Stale-guard (MailDetailView pattern): restore the list focus
            // only if this thread still owns it — another screen may have
            // claimed focus during the transition.
            if convo.currentFocus == threadFocus {
                convo.setFocus(chatsBrowsingFocus(channel))
            }
        }
        // Dictation etiquette, same as TalkView's type row: her live ears
        // close while Ido types/dictates into the compose field.
        .onChange(of: composeFocused) { _, focused in
            if focused { convo.beginTyping() } else { convo.endTyping() }
        }
        // WhatsApp photo bubbles: tap → full-screen viewer.
        .sheet(item: $photoItem) { item in
            WAPhotoView(item: item)
        }
        // WhatsApp video bubbles: tap → full-screen player.
        .sheet(item: $videoItem) { item in
            WAVideoView(item: item)
        }
        // "Draft with Scarlet" (compose-bar sparkles): the drafting studio,
        // seeded with this chat. On dismiss, reload once — an approved send
        // appears via the mirror shortly.
        .sheet(item: $scarletDraft, onDismiss: {
            Task { await model.load() }
        }) { seed in
            DraftView(seed: nil, channelSeed: seed)
                .environmentObject(convo)
                .preferredColorScheme(.dark)
        }
    }

    // MARK: messages pane

    @ViewBuilder
    private var messagesPane: some View {
        if model.loading && model.messages.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.messages.isEmpty && !model.errorText.isEmpty {
            VStack(spacing: 12) {
                Text(model.errorText)
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try again") { Task { await model.load() } }
                    .buttonStyle(.bordered)
                    .tint(channel.accent)
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            itemView(item)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .onChange(of: model.loadStamp) { _, _ in
                    if let last = items.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func itemView(_ item: ChatThreadItem) -> some View {
        if let date = item.separator {
            Text(ChatTimeFormat.separatorLabel(date))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .id(item.id)
        } else if let m = item.message {
            messageRow(m, item: item)
                .padding(.top, item.topSpacing)
                .id(item.id)
        }
    }

    @ViewBuilder
    private func messageRow(_ m: ChatMessage, item: ChatThreadItem) -> some View {
        switch channel {
        case .teams:
            TeamsMessageCell(message: m, accent: channel.accent)
        case .whatsapp:
            WhatsAppBubble(message: m,
                           showSender: item.showSender && chat.isGroup,
                           isVoicePlaying: playingVoiceID == m.id,
                           onImageTap: { url in photoItem = WAPhotoItem(url: url) },
                           onVideoTap: { url in videoItem = WAVideoItem(url: url) },
                           onVoiceTap: { url in toggleVoice(url, messageID: m.id) })
        case .imessage:
            IMessageBubble(message: m)
        }
    }

    /// Voice-note play/pause: one player at a time. Tapping the playing row
    /// pauses and clears; tapping another row replaces the current player.
    /// iOS AVPlayer can't decode ogg/opus — those taps set state but stay
    /// silent (acceptable v1); m4a/mp3/aac play fine.
    private func toggleVoice(_ url: URL, messageID: Int) {
        if playingVoiceID == messageID {
            voicePlayer?.pause()
            voicePlayer = nil
            playingVoiceID = nil
        } else {
            voicePlayer?.pause()
            let p = AVPlayer(url: url)
            voicePlayer = p
            playingVoiceID = messageID
            p.play()
        }
    }

    /// Messages interleaved with >1h-gap separators, plus grouping: a run's
    /// first bubble carries the sender and 8pt of air; the rest sit tight.
    private var items: [ChatThreadItem] {
        var out: [ChatThreadItem] = []
        var prev: ChatMessage?
        var nextId = 0
        for m in model.messages {
            if let p = prev, let a = p.ts, let b = m.ts,
               b.timeIntervalSince(a) > 3600 {
                out.append(ChatThreadItem(id: nextId, message: nil, separator: b,
                                          showSender: false, topSpacing: 0))
                nextId += 1
            } else if prev == nil, let b = m.ts {
                // Top-of-thread stamp, like Messages.
                out.append(ChatThreadItem(id: nextId, message: nil, separator: b,
                                          showSender: false, topSpacing: 0))
                nextId += 1
            }
            let changed = prev == nil
                || prev?.fromMe != m.fromMe
                || prev?.sender != m.sender
            out.append(ChatThreadItem(id: nextId, message: m, separator: nil,
                                      showSender: changed && !m.fromMe,
                                      topSpacing: changed ? 8 : 3))
            nextId += 1
            prev = m
        }
        return out
    }

    // MARK: compose bar

    private var composeArea: some View {
        VStack(spacing: 8) {
            if !model.errorText.isEmpty && !model.messages.isEmpty {
                Text(model.errorText)
                    .font(.footnote)
                    .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.45))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if channel == .teams && model.stagedNote {
                stagedCard
            }
            HStack(alignment: .bottom, spacing: 10) {
                scarletDraftButton
                TextField(composePlaceholder, text: $composeText, axis: .vertical)
                    .lineLimit(1...4)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(.white.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 18))
                    .focused($composeFocused)
                    .disabled(model.sending)
                sendButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var composePlaceholder: String {
        channel == .teams ? "Stage a Teams message…" : "Message"
    }

    private var canSend: Bool {
        !model.sending &&
        !composeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private var sendButton: some View {
        if channel == .teams {
            // Teams stages only — the actual send is Ido's tap inside Teams.
            Button {
                sendTapped()
            } label: {
                VStack(spacing: 1) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(channel.accent
                            .opacity(canSend ? 1 : 0.4)))
                    Text("Stage")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(channel.accent)
                }
                // Pin the button to the row's 36pt control height so the
                // circle centers against the Scarlet pill and field instead
                // of riding ~12pt high; the tiny caption overhangs evenly
                // into the bar's paddings (never clipped, never overlapped).
                .frame(height: 36)
            }
            .disabled(!canSend)
        } else {
            Button {
                sendTapped()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(channel.accent
                        .opacity(canSend ? 1 : 0.4)))
            }
            .disabled(!canSend)
        }
    }

    /// "Scarlet" — the ONE Scarlet control on this screen: a compact labeled
    /// pill at the bar's left, channel-tinted. Whatever is typed rides along
    /// as the instruction (and the field clears); nothing typed → the studio
    /// asks first. The last ~6 thread lines ride along too so the draft never
    /// loses its context.
    private var scarletDraftButton: some View {
        Button {
            scarletDraft = ChannelDraftSeed(
                channel: channel.rawValue,
                recipient: chat.name,
                contextLines: recentLines.joined(separator: "\n"),
                instruction: composeText.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            composeText = ""
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "waveform")
                    .font(.system(size: 12, weight: .semibold))
                Text("Scarlet")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(channel.accent)
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(Capsule().fill(channel.accent.opacity(0.18)))
            .overlay(Capsule().stroke(channel.accent.opacity(0.45), lineWidth: 1))
        }
        .disabled(model.sending)
    }

    private var stagedCard: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(channel.accent)
            Text("Staged in Teams — one tap to send there")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.85))
            Spacer(minLength: 6)
            if let url = model.stagedURL {
                Link("Open Teams", destination: url)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(channel.accent)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(channel.accent.opacity(0.15),
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(channel.accent.opacity(0.4), lineWidth: 1))
    }

    private func sendTapped() {
        let text = composeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !model.sending else { return }
        Task {
            // On failure the field keeps the text (only cleared on success).
            let ok: Bool
            if channel == .teams {
                ok = await model.stage(text)
            } else {
                ok = await model.send(text)
            }
            if ok { composeText = "" }
        }
    }

    // MARK: Scarlet capabilities

    /// Last up-to-6 messages as "Name: text" lines, each trimmed to 120 chars.
    /// Built deterministically from loaded state so the focus string is
    /// byte-identical between setFocus and the disappear stale-guard.
    private var recentLines: [String] {
        model.messages.suffix(6).map { m in
            let who = m.fromMe ? "Ido" : (m.sender.isEmpty ? chat.name : m.sender)
            let flat = m.text.replacingOccurrences(of: "\n", with: " ")
            return String("\(who): \(flat)".prefix(120))
        }
    }

    private var threadFocus: String {
        "[FOCUS] Ido is viewing his \(channel.displayName) conversation with \(chat.name).\n"
            + "recipient: \(chat.name)\n"
            + "channel: \(channel.rawValue)\n"
            + "recent messages:\n"
            + recentLines.joined(separator: "\n")
    }
}

// MARK: - Teams message cell

/// Teams mobile look: flat, LEFT-aligned, full-width cells. Sender 13pt
/// semibold in channel purple ("You" for Ido's), text 16pt on a subtle card
/// (my messages get a purple-tinted card but stay left-aligned, Teams style),
/// timestamp 11pt secondary beside the name.
struct TeamsMessageCell: View {
    let message: ChatMessage
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(message.fromMe ? "You"
                     : (message.sender.isEmpty ? "—" : message.sender))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accent)
                    .lineLimit(1)
                if let ts = message.ts {
                    Text(ChatTimeFormat.time.string(from: ts))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Text(message.text)
                .font(.system(size: 16))
                .foregroundStyle(.white.opacity(0.92))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            message.fromMe ? accent.opacity(0.18) : Color.white.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }
}

// MARK: - WhatsApp bubble

/// Classic WhatsApp dark mode: incoming dark-grey left, outgoing deep green
/// right; 18pt corners with the asymmetric 4pt tail corner; ~75% max width;
/// tiny time inside the bubble's bottom-trailing; sender name (stable hashed
/// color) atop incoming bubbles in groups.
struct WhatsAppBubble: View {
    let message: ChatMessage
    let showSender: Bool
    /// Voice notes only: whether THIS message is the one currently playing
    /// (drives the play/pause glyph). The thread view owns the player.
    var isVoicePlaying: Bool = false
    /// Photo bubbles only: the thread view presents the full-screen viewer.
    var onImageTap: ((URL) -> Void)? = nil
    /// Video bubbles only: the thread view presents the full-screen player.
    var onVideoTap: ((URL) -> Void)? = nil
    /// Voice notes only: the thread view toggles inline playback.
    var onVoiceTap: ((URL) -> Void)? = nil

    private static let outgoing = Color(red: 0.0, green: 0.36, blue: 0.25)
    private static let incoming = Color.white.opacity(0.10)

    var body: some View {
        HStack(spacing: 0) {
            if message.fromMe { Spacer(minLength: 48) }
            bubble
                .frame(maxWidth: 290,
                       alignment: message.fromMe ? .trailing : .leading)
            if !message.fromMe { Spacer(minLength: 48) }
        }
        .frame(maxWidth: .infinity,
               alignment: message.fromMe ? .trailing : .leading)
    }

    /// The asymmetric-tail WhatsApp corner treatment, shared by the bubble
    /// background and the photo clip so the image hugs the same shape.
    private var bubbleShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 18,
            bottomLeadingRadius: message.fromMe ? 18 : 4,
            bottomTrailingRadius: message.fromMe ? 4 : 18,
            topTrailingRadius: 18
        )
    }

    @ViewBuilder
    private var bubble: some View {
        if let url = message.mediaURL {
            if let type = message.mediaType, type.hasPrefix("video/") {
                videoBubble(url)
            } else if let type = message.mediaType, type.hasPrefix("audio/") {
                voiceBubble(url)
            } else {
                // image/* or nil media_type: the original photo bubble.
                mediaBubble(url)
            }
        } else {
            textBubble
        }
    }

    private var textBubble: some View {
        VStack(alignment: .leading, spacing: 2) {
            senderLine
            Text(message.text)
                .font(.system(size: 16))
                .foregroundStyle(.white)
            timeLine
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(message.fromMe ? Self.outgoing : Self.incoming,
                    in: bubbleShape)
    }

    /// Photo bubble: tight 3pt padding around the image; optional caption
    /// under it in the same bubble; same background/corner treatment.
    private func mediaBubble(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            senderLine
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: 230, maxHeight: 300)
                        .clipped()
                        .clipShape(bubbleShape)
                } else if phase.error != nil {
                    mediaPlaceholder(height: 80, loading: false)
                } else {
                    mediaPlaceholder(height: 200, loading: true)
                }
            }
            if !message.text.isEmpty {
                Text(message.text)
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
                    .padding(.top, 2)
                    .padding(.horizontal, 4)
            }
            timeLine
        }
        .padding(3)
        .background(message.fromMe ? Self.outgoing : Self.incoming,
                    in: bubbleShape)
        .contentShape(bubbleShape)
        .onTapGesture { onImageTap?(url) }
    }

    private func mediaPlaceholder(height: CGFloat, loading: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.08))
            if loading {
                ProgressView()
                    .tint(.white.opacity(0.7))
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .frame(width: 230, height: height)
    }

    /// Video bubble: 230×160 dark card with a centered play glyph; optional
    /// caption under it (same treatment as photo captions); tap → the thread
    /// view's full-screen player sheet.
    private func videoBubble(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            senderLine
            ZStack {
                bubbleShape
                    .fill(Color.black.opacity(0.35))
                VStack(spacing: 6) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.white)
                    Text("Video")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            .frame(width: 230, height: 160)
            if !message.text.isEmpty {
                Text(message.text)
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
                    .padding(.top, 2)
                    .padding(.horizontal, 4)
            }
            timeLine
        }
        .padding(3)
        .background(message.fromMe ? Self.outgoing : Self.incoming,
                    in: bubbleShape)
        .contentShape(bubbleShape)
        .onTapGesture { onVideoTap?(url) }
    }

    /// Voice-note bubble: compact row — 30pt play/pause circle in WhatsApp
    /// green, static waveform glyph, "Voice note" label. Playback is inline,
    /// owned by the thread view (one player at a time).
    private func voiceBubble(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            senderLine
            HStack(spacing: 10) {
                Button {
                    onVoiceTap?(url)
                } label: {
                    Image(systemName: isVoicePlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(ChatChannel.whatsapp.accent))
                }
                .buttonStyle(.plain)
                Image(systemName: "waveform")
                    .font(.system(size: 18))
                    .foregroundStyle(.white.opacity(0.7))
                Text("Voice note")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .frame(minWidth: 150, alignment: .leading)
            timeLine
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(message.fromMe ? Self.outgoing : Self.incoming,
                    in: bubbleShape)
    }

    @ViewBuilder
    private var senderLine: some View {
        if showSender && !message.sender.isEmpty {
            Text(message.sender)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(chatSenderColor(message.sender))
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var timeLine: some View {
        if let ts = message.ts {
            HStack(spacing: 3) {
                Text(ChatTimeFormat.time.string(from: ts))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                if message.fromMe {
                    waTicks(message.status)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    /// WhatsApp check marks: single tick (sent), double tick (delivered),
    /// blue double tick (read). nil → nothing (incoming / unknown).
    @ViewBuilder
    private func waTicks(_ status: String?) -> some View {
        switch status {
        case "sent":
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
        case "delivered":
            waDoubleCheck(.white.opacity(0.55))
        case "read":
            waDoubleCheck(Color(red: 0.20, green: 0.60, blue: 0.86))
        default:
            EmptyView()
        }
    }

    /// Two overlapped checkmarks, the second nudged 4pt right, in a fixed
    /// 15pt frame so the time row's layout stays stable.
    private func waDoubleCheck(_ color: Color) -> some View {
        ZStack(alignment: .leading) {
            Image(systemName: "checkmark")
            Image(systemName: "checkmark")
                .offset(x: 4)
        }
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(color)
        .frame(width: 15, alignment: .leading)
    }
}

// MARK: - WhatsApp full-screen photo viewer

/// Identifiable wrapper so `.sheet(item:)` can drive the viewer off a URL.
/// (Distinct from InboxView's PreviewFile/QuickLookPreview attachment names.)
struct WAPhotoItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// Full-screen photo sheet: image scaledToFit on black, xmark to dismiss.
struct WAPhotoView: View {
    let item: WAPhotoItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            AsyncImage(url: item.url) { phase in
                if let image = phase.image {
                    image
                        .resizable()
                        .scaledToFit()
                } else if phase.error != nil {
                    VStack(spacing: 8) {
                        Image(systemName: "photo")
                            .font(.system(size: 36))
                        Text("Couldn't load this photo")
                            .font(.footnote)
                    }
                    .foregroundStyle(.white.opacity(0.55))
                } else {
                    ProgressView()
                        .tint(.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(.white.opacity(0.15)))
            }
            .padding(.top, 12)
            .padding(.trailing, 16)
        }
    }
}

// MARK: - WhatsApp full-screen video player

/// Identifiable wrapper so `.sheet(item:)` can drive the player off a URL.
/// (Parallel to WAPhotoItem — kept separate so the photo path is untouched.)
struct WAVideoItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// Full-screen video sheet: VideoPlayer on black, autoplays on appear,
/// pauses on dismiss; same top-trailing xmark as the photo viewer.
struct WAVideoView: View {
    let item: WAVideoItem
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer? = nil

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            }
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(.white.opacity(0.15)))
            }
            .padding(.top, 12)
            .padding(.trailing, 16)
        }
        .onAppear {
            let p = AVPlayer(url: item.url)
            player = p
            p.play()
        }
        .onDisappear { player?.pause() }
    }
}

// MARK: - iMessage bubble

/// Messages look: outgoing iMessage-blue right, incoming grey left, 17pt
/// text, 18pt radius, ~75% max width. No per-message timestamps — the shared
/// >1h separators carry the time.
struct IMessageBubble: View {
    let message: ChatMessage

    private static let outgoing = Color(red: 0.04, green: 0.52, blue: 1.0)
    private static let incoming = Color(white: 0.22)

    var body: some View {
        HStack(spacing: 0) {
            if message.fromMe { Spacer(minLength: 48) }
            Text(message.text)
                .font(.system(size: 17))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    message.fromMe ? Self.outgoing : Self.incoming,
                    in: RoundedRectangle(cornerRadius: 18)
                )
                .frame(maxWidth: 290,
                       alignment: message.fromMe ? .trailing : .leading)
            if !message.fromMe { Spacer(minLength: 48) }
        }
        .frame(maxWidth: .infinity,
               alignment: message.fromMe ? .trailing : .leading)
    }
}
