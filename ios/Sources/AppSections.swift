import Combine
import SwiftUI

/// The single source of truth for every top-level section in the app. Both
/// shells — the iPhone `TabView` (RootView) and the iPad/Mac sidebar
/// (SplitShell) — render FROM this list, in the order Ido chose (see
/// `SectionOrderStore`). Adding a section = one case here + one line in the
/// `destination` builder; both surfaces pick it up automatically.
///
/// `settings` is deliberately NOT in `reorderable` — it is pinned (bottom of
/// the sidebar / always in More on the phone), and Preferences lives inside it.
enum AppSection: String, CaseIterable, Identifiable {
    case talk
    case inbox
    case calendar
    case chats
    case reminders
    case notes
    case remarkable
    case news
    case amwell
    case music
    case video
    case photos
    case health
    case food
    case library
    case settings

    var id: String { rawValue }

    /// The sections Ido can reorder. Settings is pinned and excluded.
    static var reorderable: [AppSection] { allCases.filter { $0 != .settings } }

    var title: String {
        switch self {
        case .talk: return "Talk"
        case .inbox: return "Inbox"
        case .calendar: return "Calendar"
        case .chats: return "Chats"
        case .reminders: return "Reminders"
        case .notes: return "Notes"
        case .remarkable: return "reMarkable"
        case .news: return "News"
        case .amwell: return "Amwell"
        case .music: return "Music"
        case .video: return "Video"
        case .photos: return "Photos"
        case .health: return "Health"
        case .food: return "Food"
        case .library: return "Library"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .talk: return "waveform"
        case .inbox: return "envelope.fill"
        case .calendar: return "calendar"
        case .chats: return "bubble.left.and.bubble.right.fill"
        case .reminders: return "checklist"
        case .notes: return "note.text"
        case .remarkable: return "pencil.and.outline"
        case .news: return "newspaper.fill"
        case .amwell: return "chart.line.uptrend.xyaxis"
        case .music: return "music.note"
        case .video: return "play.rectangle.fill"
        case .photos: return "photo.on.rectangle.angled"
        case .health: return "heart.fill"
        case .food: return "fork.knife"
        case .library: return "books.vertical.fill"
        case .settings: return "gearshape.fill"
        }
    }

    /// The section's screen, with `convo` injected at the construction site so
    /// every convo-reading view is Mac-Catalyst-safe on its own (Catalyst does
    /// NOT propagate an ancestor-injected @EnvironmentObject — a reader traps
    /// with SIGTRAP unless convo is re-injected right where it's built; this is
    /// the crash class that hit builds 147–149). Injecting on every case is
    /// harmless for the views that don't read it and makes the dependency
    /// impossible to forget when a new section is added. One place, one rule.
    @ViewBuilder
    func destination(convo: Conversation) -> some View {
        switch self {
        case .talk:      TalkView(convo: convo).environmentObject(convo)
        case .inbox:     InboxView().environmentObject(convo)
        case .calendar:  CalendarView().environmentObject(convo)
        case .chats:     ChatsView().environmentObject(convo)
        case .reminders: RemindersView().environmentObject(convo)
        case .notes:     NotesView().environmentObject(convo)
        case .remarkable: RemarkableView().environmentObject(convo)
        case .news:      NewsView().environmentObject(convo)
        case .amwell:    AmwellView().environmentObject(convo)
        case .music:     MusicView().environmentObject(convo)
        case .video:     VideoView().environmentObject(convo)
        case .photos:    PhotosView().environmentObject(convo)
        case .health:    HealthView().environmentObject(convo)
        case .food:      FoodView().environmentObject(convo)
        case .library:   LibraryView().environmentObject(convo)
        case .settings:  SettingsView(presentedAsSheet: false).environmentObject(convo)
        }
    }
}

/// Ido's chosen section order, cache-first so it paints instantly, then
/// refreshed from the server (`section_order`) behind the paint. Owned once by
/// RootView and handed to whichever shell is on screen — the same instance, so
/// a reorder is reflected everywhere at once.
///
/// Agility: the order is read from `@AppStorage` synchronously in `init()` so
/// the first frame is already correct; the network refresh only ever reconciles.
@MainActor
final class SectionOrderStore: ObservableObject {
    /// The reorderable sections in Ido's order. `settings` is appended by the
    /// shells themselves (pinned), never part of this array.
    @Published var order: [AppSection]

    private static let cacheKey = "scarlet.sectionOrder.v1"

    /// A sensible default: the daily-driver surfaces first.
    static let defaultOrder: [AppSection] = [
        .talk, .inbox, .calendar, .chats, .reminders, .notes, .remarkable,
        .news, .amwell, .music, .video, .photos, .health, .food, .library,
    ]

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.cacheKey) {
            order = Self.sanitize(raw.split(separator: ",").map(String.init))
        } else {
            order = Self.defaultOrder
        }
    }

    /// Merge a server-provided key list into a complete, valid order:
    /// known keys in the server's order first, then any section the server
    /// omitted (e.g. a newly shipped one) appended in its default position, so
    /// a new build never hides a section just because the saved order predates
    /// it. `settings` is always stripped.
    static func sanitize(_ keys: [String]) -> [AppSection] {
        var seen = Set<AppSection>()
        var result: [AppSection] = []
        for k in keys {
            if let s = AppSection(rawValue: k), s != .settings, !seen.contains(s) {
                result.append(s); seen.insert(s)
            }
        }
        for s in defaultOrder where !seen.contains(s) {
            result.append(s); seen.insert(s)
        }
        return result
    }

    private func persist() {
        UserDefaults.standard.set(order.map(\.rawValue).joined(separator: ","),
                                  forKey: Self.cacheKey)
    }

    /// Apply a new order locally (instant) and push it to the server. Used if
    /// reordering ever happens inside this store; PreferencesView writes its
    /// own copy too, and `refresh()` reconciles.
    func apply(_ newOrder: [AppSection]) {
        order = Self.sanitize(newOrder.map(\.rawValue))
        persist()
        Task { await push() }
    }

    /// Pull the saved order from the server and reconcile the local copy.
    /// Never throws; on any failure the cached order simply stands.
    func refresh() async {
        guard let keys = await Self.fetchOrder() else { return }
        let merged = Self.sanitize(keys)
        if merged != order {
            order = merged
            persist()
        }
    }

    private func push() async {
        guard var comps = URLComponents(url: AppConfig.appAPIURL, resolvingAgainstBaseURL: false) else { return }
        var items = comps.queryItems ?? []
        items.append(URLQueryItem(name: "op", value: "section_order"))
        comps.queryItems = items
        guard let url = comps.url else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(TokenStore.token ?? "", forHTTPHeaderField: "x-scarlet-token")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(
            withJSONObject: ["order": order.map(\.rawValue)])
        _ = try? await URLSession.shared.data(for: req)
    }

    private static func fetchOrder() async -> [String]? {
        guard var comps = URLComponents(url: AppConfig.appAPIURL, resolvingAgainstBaseURL: false) else { return nil }
        var items = comps.queryItems ?? []
        items.append(URLQueryItem(name: "op", value: "section_order"))
        comps.queryItems = items
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(TokenStore.token ?? "", forHTTPHeaderField: "x-scarlet-token")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let order = obj["order"] as? [String] else { return nil }
        return order
    }
}
