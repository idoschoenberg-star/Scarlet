import SwiftUI
import UIKit

/// Native Music (Spotify) — the app's mirror of the web Music section: library
/// shelves (playlists / liked / recently played), search across tracks,
/// playlists, albums and artists, tap-to-play on Ido's Spotify devices with
/// the backend's own honest success/failure line surfaced as a toast, a
/// now-playing dock that polls `music_state` only while the screen is visible,
/// and a full track sheet (art, album, stats, transport) via `music_track`.
///
/// Playback always happens on a real Spotify device (Connect) — the server
/// verifies sound is actually coming out before claiming success, and its
/// `note`/`error` strings are shown verbatim rather than an invented "done".

// MARK: - Wire types

/// One playable track, as the music ops return it (library `saved` /
/// `recentlyPlayed`, playlist tracks, search tracks). `durationMs` is 0 when
/// the source op doesn't carry it (library `saved`).
struct MusicTrackItem: Identifiable, Equatable {
    let id: String
    let uri: String
    let title: String
    let artist: String
    let image: String?
    let durationMs: Int
}

/// One of Ido's playlists (`music_library.playlists`) or a search playlist.
struct MusicPlaylistItem: Identifiable, Equatable {
    let id: String
    let uri: String
    let name: String
    let image: String?
    let count: Int
    let owner: String?
}

/// A search album — tap plays the whole album as a context.
struct MusicAlbumItem: Identifiable, Equatable {
    let id: String
    let uri: String
    let name: String
    let artist: String
    let image: String?
}

/// A search artist — tap plays the artist context.
struct MusicArtistItem: Identifiable, Equatable {
    let id: String
    let uri: String
    let name: String
    let image: String?
}

/// "Up next" row from `music_state.queue`. The queue can legally repeat a
/// track, so identity is position-scoped — never the bare uri.
struct MusicQueueItem: Identifiable, Equatable {
    let id: String
    let title: String
    let artist: String
    let image: String?
}

/// The live player snapshot from `op=music_state` (200 with a nil track when
/// nothing is playing).
struct MusicPlayerState: Equatable {
    var track: MusicTrackItem?
    var album: String?
    var progressMs: Int
    var durationMs: Int
    var isPlaying: Bool
    var deviceName: String?
    var queue: [MusicQueueItem]
}

/// Full track detail from `op=music_track` (album/popularity always attempted;
/// audio features only when Spotify still serves them — honest optionality).
struct MusicTrackDetailData {
    let track: MusicTrackItem
    let artists: [String]
    let album: String?
    let popularity: Int?
    let tempo: Double?
    let energy: Double?
}

enum MusicDetailPhase {
    case loading
    case failed(String)
    case loaded(MusicTrackDetailData)
}

/// One page of a playlist (`op=music_playlist`): header + tracks + paging.
struct MusicPlaylistPage {
    let name: String
    let image: String?
    let tracks: [MusicTrackItem]
    let total: Int
    let nextOffset: Int?
}

enum MusicPlaylistFetch {
    case loaded(MusicPlaylistPage)
    case failed(String)
}

// MARK: - Palette

/// Scarlet rose on the silk background — the Music accent, matching the web
/// app's tint. File-scoped so nothing leaks into sibling views.
private enum MusicStyle {
    static let rose = Color(red: 1, green: 0.35, blue: 0.42)
    static let surface = Color.white.opacity(0.08)
    static let stroke = Color.white.opacity(0.12)
    static let secondary = Color.white.opacity(0.62)
    static let tertiary = Color.white.opacity(0.4)
}

/// "3:41" from milliseconds.
private func musicDuration(_ ms: Int) -> String {
    let s = max(0, ms / 1000)
    return "\(s / 60):" + String(format: "%02d", s % 60)
}

// MARK: - Model

@MainActor
final class MusicModel: ObservableObject {
    // Library (op=music_library)
    @Published var playlists: [MusicPlaylistItem] = []
    @Published var saved: [MusicTrackItem] = []
    @Published var recent: [MusicTrackItem] = []
    /// The server's own honest status line ("Spotify isn't connected yet.").
    @Published var libraryNote = ""
    @Published var loadingLibrary = false
    @Published var errorText = ""

    // Live player (op=music_state, polled only while the screen is visible)
    @Published var player: MusicPlayerState?

    // Search (op=music_search)
    @Published var searchText = ""
    @Published var searching = false
    @Published var searchTracks: [MusicTrackItem] = []
    @Published var searchPlaylists: [MusicPlaylistItem] = []
    @Published var searchAlbums: [MusicAlbumItem] = []
    @Published var searchArtists: [MusicArtistItem] = []
    @Published var searchError = ""
    /// A search has answered for the current text (drives the honest
    /// "No results" vs "still typing" distinction).
    @Published var searchAnswered = false

    /// Transient status line (play results, control failures) — the backend's
    /// own words, auto-cleared. Rendered by the dock and the track sheet.
    @Published var toast = ""

    /// The track sheet's subject. Lives on the model so the pushed playlist
    /// screen can raise the ONE sheet owned by MusicView (Catalyst rule:
    /// a single `.sheet` per view).
    @Published var detail: MusicTrackItem?

    private var pollTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var libraryGeneration = 0
    private var searchGeneration = 0

    // MARK: Library

    func loadLibrary() async {
        guard TokenStore.token != nil else {
            errorText = "Locked — unlock Scarlet to see your music."
            return
        }
        if playlists.isEmpty && saved.isEmpty && recent.isEmpty { loadingLibrary = true }
        errorText = ""
        libraryGeneration += 1
        let generation = libraryGeneration
        defer { if generation == libraryGeneration { loadingLibrary = false } }
        do {
            let data = try await Self.request("op=music_library", method: "GET")
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            guard generation == libraryGeneration else { return }
            let newPlaylists = Self.dedup(((obj["playlists"] as? [[String: Any]]) ?? [])
                .compactMap { Self.playlist(from: $0) })
            let newSaved = Self.dedup(((obj["saved"] as? [[String: Any]]) ?? [])
                .compactMap { Self.track(from: $0) })
            let newRecent = Self.dedup(((obj["recentlyPlayed"] as? [[String: Any]]) ?? [])
                .compactMap { Self.track(from: $0) })
            withAnimation(.snappy) {
                playlists = newPlaylists
                saved = newSaved
                recent = newRecent
            }
            libraryNote = (obj["note"] as? String) ?? ""
        } catch {
            guard generation == libraryGeneration else { return }
            errorText = "Couldn't reach your music — check your connection."
        }
    }

    // MARK: Live player state (visible-only polling)

    /// Gentle 8s cadence, started on appear and CANCELED on disappear — the
    /// screen never polls in the background.
    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshState()
                try? await Task.sleep(nanoseconds: 8_000_000_000)
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        searchTask?.cancel()
        searchTask = nil
    }

    func refreshState() async {
        guard TokenStore.token != nil else { return }
        do {
            let data = try await Self.request("op=music_state", method: "GET")
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            // A typed {error} (token trouble) keeps the last honest snapshot;
            // a 200 with a nil track honestly means "nothing playing".
            if obj["error"] is String { return }
            var next: MusicPlayerState? = nil
            if let t = obj["track"] as? [String: Any],
               let uri = t["uri"] as? String, !uri.isEmpty {
                let id = uri.components(separatedBy: ":").last ?? uri
                let track = MusicTrackItem(
                    id: id,
                    uri: uri,
                    title: (t["title"] as? String) ?? "",
                    artist: (t["artist"] as? String) ?? "",
                    image: t["image"] as? String,
                    durationMs: (obj["duration_ms"] as? Int) ?? 0
                )
                var queue: [MusicQueueItem] = []
                for (i, q) in (((obj["queue"] as? [[String: Any]]) ?? []).enumerated()) {
                    let quri = (q["uri"] as? String) ?? ""
                    queue.append(MusicQueueItem(
                        id: "\(i)-\(quri)",
                        title: (q["title"] as? String) ?? "",
                        artist: (q["artist"] as? String) ?? "",
                        image: q["image"] as? String
                    ))
                }
                next = MusicPlayerState(
                    track: track,
                    album: (t["album"] as? String),
                    progressMs: (obj["progress_ms"] as? Int) ?? 0,
                    durationMs: (obj["duration_ms"] as? Int) ?? 0,
                    isPlaying: (obj["is_playing"] as? Bool) ?? false,
                    deviceName: (obj["device"] as? [String: Any])?["name"] as? String,
                    queue: queue
                )
            }
            player = next
        } catch {
            // Transient network wobble mid-poll: keep the last snapshot.
        }
    }

    // MARK: Playback

    /// Play a Spotify uri (track = one-off, playlist/album/artist = context).
    /// The toast is the SERVER's verdict — including its "opening Spotify will
    /// start it automatically" retry note and the fixed-device warning.
    func play(uri: String, label: String) {
        Task {
            do {
                let data = try await Self.request("op=music_play", method: "POST",
                                                  body: ["uri": uri])
                let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                let note = obj["note"] as? String
                if (obj["ok"] as? Bool) == true {
                    let device = (obj["on_device"] as? String)
                        ?? (obj["device"] as? String) ?? ""
                    var line = device.isEmpty
                        ? "Playing \(label)"
                        : "Playing \(label) on \(device)"
                    if let note, !note.isEmpty { line += " — \(note)" }
                    showToast(line)
                } else if let err = obj["error"] as? String {
                    var line = err
                    if let note, !note.isEmpty { line += " — \(note)" }
                    showToast(line)
                } else {
                    showToast("Couldn't start playback — is Spotify open on a device?")
                }
            } catch {
                showToast("Couldn't reach Spotify — check your connection.")
            }
            try? await Task.sleep(nanoseconds: 900_000_000)
            await refreshState()
        }
    }

    /// pause | resume | next | previous, via op=music_control. Pause/resume
    /// flip locally first so the button answers instantly; the state poll
    /// right after is the truth.
    func control(_ action: String) {
        if action == "pause" { player?.isPlaying = false }
        if action == "resume" { player?.isPlaying = true }
        Task {
            do {
                let data = try await Self.request("op=music_control", method: "POST",
                                                  body: ["action": action])
                let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                if let err = obj["error"] as? String { showToast(err) }
            } catch {
                showToast("Playback control needs Spotify open on a device.")
            }
            try? await Task.sleep(nanoseconds: 700_000_000)
            await refreshState()
        }
    }

    // MARK: Search

    /// Debounced (350ms) like the web app; canceled by newer keystrokes and
    /// by the screen disappearing.
    func scheduleSearch() {
        searchTask?.cancel()
        searchAnswered = false
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            clearSearchResults()
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await self?.runSearch(q)
        }
    }

    func runSearch(_ q: String) async {
        searching = true
        searchError = ""
        searchGeneration += 1
        let generation = searchGeneration
        defer { if generation == searchGeneration { searching = false } }
        do {
            let encoded = q.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? q
            let data = try await Self.request(
                "op=music_search&q=\(encoded)&type=track,artist,album,playlist&limit=10",
                method: "GET")
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            guard generation == searchGeneration else { return }
            if let err = obj["error"] as? String {
                searchError = err
                searchAnswered = true
                return
            }
            searchTracks = Self.dedup(((obj["tracks"] as? [[String: Any]]) ?? [])
                .compactMap { Self.track(from: $0) })
            searchPlaylists = Self.dedup(((obj["playlists"] as? [[String: Any]]) ?? [])
                .compactMap { Self.playlist(from: $0) })
            searchAlbums = Self.dedup(((obj["albums"] as? [[String: Any]]) ?? [])
                .compactMap { Self.album(from: $0) })
            searchArtists = Self.dedup(((obj["artists"] as? [[String: Any]]) ?? [])
                .compactMap { Self.artist(from: $0) })
            searchAnswered = true
        } catch {
            guard generation == searchGeneration else { return }
            searchError = "Search failed — check your connection."
            searchAnswered = true
        }
    }

    func clearSearchResults() {
        searchTracks = []
        searchPlaylists = []
        searchAlbums = []
        searchArtists = []
        searchError = ""
        searching = false
        searchAnswered = false
    }

    // MARK: Track detail / playlist pages

    func fetchTrackDetail(uri: String) async -> MusicDetailPhase {
        do {
            let encoded = uri.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? uri
            let data = try await Self.request("op=music_track&uri=\(encoded)", method: "GET")
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failed("Couldn't read that track.")
            }
            if let err = obj["error"] as? String { return .failed(err) }
            guard let t = obj["track"] as? [String: Any],
                  let card = Self.track(from: t) else {
                return .failed("Couldn't read that track.")
            }
            let features = t["features"] as? [String: Any]
            return .loaded(MusicTrackDetailData(
                track: card,
                artists: (t["artists"] as? [String]) ?? [],
                album: t["album"] as? String,
                popularity: t["popularity"] as? Int,
                tempo: features?["tempo"] as? Double,
                energy: features?["energy"] as? Double
            ))
        } catch {
            return .failed("Couldn't reach Spotify — check your connection.")
        }
    }

    func fetchPlaylist(id: String, offset: Int) async -> MusicPlaylistFetch {
        do {
            let encoded = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
            let data = try await Self.request(
                "op=music_playlist&id=\(encoded)&limit=100&offset=\(offset)", method: "GET")
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failed("Couldn't load this playlist.")
            }
            if let err = obj["error"] as? String { return .failed(err) }
            let tracks = Self.dedup(((obj["tracks"] as? [[String: Any]]) ?? [])
                .compactMap { Self.track(from: $0) })
            return .loaded(MusicPlaylistPage(
                name: (obj["name"] as? String) ?? "Playlist",
                image: obj["image"] as? String,
                tracks: tracks,
                total: (obj["total"] as? Int) ?? tracks.count,
                nextOffset: obj["next_offset"] as? Int
            ))
        } catch {
            return .failed("Couldn't load this playlist — check your connection.")
        }
    }

    // MARK: Toast

    func showToast(_ text: String) {
        toastTask?.cancel()
        withAnimation(.snappy) { toast = text }
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) { self?.toast = "" }
        }
    }

    // MARK: Parsers (exact op shapes; every miss fails closed to nil)

    private static func track(from m: [String: Any]) -> MusicTrackItem? {
        guard let id = m["id"] as? String, !id.isEmpty else { return nil }
        let uri = (m["uri"] as? String) ?? "spotify:track:\(id)"
        return MusicTrackItem(
            id: id,
            uri: uri,
            title: (m["title"] as? String) ?? "Untitled",
            artist: (m["artist"] as? String) ?? "",
            image: m["image"] as? String,
            durationMs: (m["durationMs"] as? Int) ?? (m["duration_ms"] as? Int) ?? 0
        )
    }

    private static func playlist(from m: [String: Any]) -> MusicPlaylistItem? {
        guard let id = m["id"] as? String, !id.isEmpty else { return nil }
        return MusicPlaylistItem(
            id: id,
            uri: (m["uri"] as? String) ?? "spotify:playlist:\(id)",
            name: (m["name"] as? String) ?? "Playlist",
            image: m["image"] as? String,
            count: (m["count"] as? Int) ?? 0,
            owner: m["owner"] as? String
        )
    }

    private static func album(from m: [String: Any]) -> MusicAlbumItem? {
        guard let id = m["id"] as? String, !id.isEmpty else { return nil }
        return MusicAlbumItem(
            id: id,
            uri: (m["uri"] as? String) ?? "spotify:album:\(id)",
            name: (m["name"] as? String) ?? "Album",
            artist: (m["artist"] as? String) ?? "",
            image: m["image"] as? String
        )
    }

    private static func artist(from m: [String: Any]) -> MusicArtistItem? {
        guard let id = m["id"] as? String, !id.isEmpty else { return nil }
        return MusicArtistItem(
            id: id,
            uri: (m["uri"] as? String) ?? "spotify:artist:\(id)",
            name: (m["name"] as? String) ?? "Artist",
            image: m["image"] as? String
        )
    }

    /// Duplicate ids crash diffable lists at regular width — same class of
    /// crash already fixed in Chats/Inbox. Keep the first of any repeat.
    private static func dedup<Item: Identifiable>(_ items: [Item]) -> [Item] {
        var seen = Set<Item.ID>()
        return items.filter { seen.insert($0.id).inserted }
    }

    // MARK: Plumbing (mirrors InboxView/ChatsView exactly)

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
}

// MARK: - Artwork

/// Album/playlist art with an honest placeholder (surface + faint note glyph)
/// under the async load — never a blank hole, never a spinner per cell.
private struct MusicArt: View {
    let url: String?
    var size: CGFloat
    var corner: CGFloat = 6

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner).fill(MusicStyle.surface)
            Image(systemName: "music.note")
                .font(.system(size: size * 0.36))
                .foregroundStyle(MusicStyle.tertiary)
            if let u = url.flatMap({ URL(string: $0) }) {
                AsyncImage(url: u) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        Color.clear
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner))
    }
}

// MARK: - Root view

struct MusicView: View {
    @StateObject private var model = MusicModel()

    var body: some View {
        NavigationStack {
            ZStack {
                ScarletBackground().ignoresSafeArea()
                VStack(spacing: 0) {
                    header
                    searchField
                    content
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            // The dock (toast + now-playing bar) is part of the HOME screen's
            // layout; a pushed playlist screen mounts its own, same anatomy.
            .safeAreaInset(edge: .bottom) { MusicBottomDock(model: model) }
        }
        // ONE sheet on this view (Catalyst rule) — the full track detail,
        // raised from the dock, any row's context menu, or the playlist screen.
        .sheet(item: $model.detail) { track in
            MusicTrackDetailView(seed: track, model: model)
        }
        // Poll the live player only while the Music screen is actually up:
        // these fire on tab switch in/out; the poll task dies on disappear.
        .onAppear { model.startPolling() }
        .onDisappear { model.stopPolling() }
        // .task re-runs on each tab selection → auto-refresh, like the inbox.
        .task { await model.loadLibrary() }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.willEnterForegroundNotification)) { _ in
            Task { await model.loadLibrary() }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: header (house anatomy: big title, rose glyph)

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(MusicStyle.rose.opacity(0.18))
                Image(systemName: "music.note")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(MusicStyle.rose)
            }
            .frame(width: 36, height: 36)
            Text("Music")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    /// Search across tracks / playlists / albums / artists. The field itself
    /// follows the typed text's direction (Hebrew queries read RTL) — per
    /// control, never the whole screen.
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(MusicStyle.secondary)
            TextField("Search songs, artists, albums, playlists", text: $model.searchText)
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .tint(MusicStyle.rose)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .environment(\.layoutDirection, model.searchText.layoutDir)
                .onSubmit {
                    let q = model.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !q.isEmpty { Task { await model.runSearch(q) } }
                }
            if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                    model.clearSearchResults()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(MusicStyle.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12).fill(MusicStyle.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(MusicStyle.stroke, lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .onChange(of: model.searchText) { _, _ in model.scheduleSearch() }
    }

    private var isSearchMode: Bool {
        !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: content

    @ViewBuilder
    private var content: some View {
        if isSearchMode {
            searchResults
        } else {
            library
        }
    }

    @ViewBuilder
    private var library: some View {
        let empty = model.playlists.isEmpty && model.saved.isEmpty && model.recent.isEmpty
        if model.loadingLibrary && empty {
            VStack(spacing: 10) {
                ProgressView()
                Text("Loading your music…")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if empty && !model.errorText.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.title2).foregroundStyle(.secondary)
                Text(model.errorText)
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try again") { Task { await model.loadLibrary() } }
                    .buttonStyle(.bordered)
                    .tint(MusicStyle.rose)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if empty {
            VStack(spacing: 8) {
                Image(systemName: "music.note.list")
                    .font(.title2).foregroundStyle(.secondary)
                Text(model.libraryNote.isEmpty
                     ? "Your Spotify library is empty here, or Spotify isn't connected yet."
                     : model.libraryNote)
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !model.errorText.isEmpty {
                        noteLine(model.errorText)
                    } else if !model.libraryNote.isEmpty {
                        noteLine(model.libraryNote)
                    }
                    if !model.playlists.isEmpty {
                        shelfLabel("Your Playlists")
                        playlistRail(model.playlists)
                    }
                    if !model.saved.isEmpty {
                        shelfLabel("Liked Songs")
                        ForEach(model.saved.prefix(30)) { t in
                            MusicTrackRow(track: t, model: model)
                        }
                    }
                    if !model.recent.isEmpty {
                        shelfLabel("Recently Played")
                        ForEach(model.recent.prefix(30)) { t in
                            MusicTrackRow(track: t, model: model)
                        }
                    }
                    Color.clear.frame(height: 12)
                }
            }
            .refreshable {
                await model.loadLibrary()
                await model.refreshState()
            }
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        let noResults = model.searchTracks.isEmpty && model.searchPlaylists.isEmpty
            && model.searchAlbums.isEmpty && model.searchArtists.isEmpty
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if model.searching {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Searching…").font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                } else if !model.searchError.isEmpty {
                    noteLine(model.searchError)
                } else if noResults && model.searchAnswered {
                    noteLine("No results for “\(model.searchText.trimmingCharacters(in: .whitespacesAndNewlines))”.")
                }
                if !model.searchTracks.isEmpty {
                    shelfLabel("Songs")
                    ForEach(model.searchTracks) { t in
                        MusicTrackRow(track: t, model: model)
                    }
                }
                if !model.searchPlaylists.isEmpty {
                    shelfLabel("Playlists")
                    playlistRail(model.searchPlaylists)
                }
                if !model.searchAlbums.isEmpty {
                    shelfLabel("Albums")
                    albumRail(model.searchAlbums)
                }
                if !model.searchArtists.isEmpty {
                    shelfLabel("Artists")
                    ForEach(model.searchArtists) { a in
                        MusicArtistRow(artist: a, model: model)
                    }
                }
                Color.clear.frame(height: 12)
            }
        }
    }

    // MARK: shelf pieces

    private func shelfLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 12, weight: .semibold))
            .kerning(0.5)
            .foregroundStyle(MusicStyle.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 6)
    }

    private func noteLine(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Color(red: 0.91, green: 0.69, blue: 0.31))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
    }

    private func playlistRail(_ items: [MusicPlaylistItem]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(items) { p in
                    NavigationLink {
                        MusicPlaylistDetailView(playlist: p, model: model)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            MusicArt(url: p.image, size: 120, corner: 10)
                            Text(p.name)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(2)
                                .multilineTextAlignment(p.name.readingAlignment)
                            Text(p.count > 0 ? "\(p.count) tracks" : (p.owner ?? ""))
                                .font(.system(size: 11))
                                .foregroundStyle(MusicStyle.secondary)
                                .lineLimit(1)
                        }
                        .frame(width: 120, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func albumRail(_ items: [MusicAlbumItem]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(items) { a in
                    Button {
                        model.play(uri: a.uri, label: a.name)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            MusicArt(url: a.image, size: 120, corner: 10)
                            Text(a.name)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(2)
                                .multilineTextAlignment(a.name.readingAlignment)
                            Text(a.artist)
                                .font(.system(size: 11))
                                .foregroundStyle(MusicStyle.secondary)
                                .lineLimit(1)
                        }
                        .frame(width: 120, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

// MARK: - Track / artist rows

/// One track row: art, title/artist, duration. Tap plays (the web behavior);
/// long-press offers Play + Details (Details raises the shared sheet).
private struct MusicTrackRow: View {
    let track: MusicTrackItem
    @ObservedObject var model: MusicModel

    var body: some View {
        Button {
            model.play(uri: track.uri, label: track.title)
        } label: {
            HStack(spacing: 10) {
                MusicArt(url: track.image, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.system(size: 12))
                        .foregroundStyle(MusicStyle.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if track.durationMs > 0 {
                    Text(musicDuration(track.durationMs))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(MusicStyle.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                model.play(uri: track.uri, label: track.title)
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            Button {
                model.detail = track
            } label: {
                Label("Track details", systemImage: "info.circle")
            }
        }
    }
}

/// A search artist row — tap plays the artist context on Spotify.
private struct MusicArtistRow: View {
    let artist: MusicArtistItem
    @ObservedObject var model: MusicModel

    var body: some View {
        Button {
            model.play(uri: artist.uri, label: artist.name)
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(MusicStyle.surface)
                    Image(systemName: "music.mic")
                        .font(.system(size: 16))
                        .foregroundStyle(MusicStyle.tertiary)
                    if let u = artist.image.flatMap({ URL(string: $0) }) {
                        AsyncImage(url: u) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().scaledToFill()
                            default:
                                Color.clear
                            }
                        }
                    }
                }
                .frame(width: 44, height: 44)
                .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(artist.name)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("Artist")
                        .font(.system(size: 12))
                        .foregroundStyle(MusicStyle.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "play.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(MusicStyle.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Bottom dock (toast + now-playing bar)

/// The screen's status ribbon: the toast (the backend's honest verdicts) above
/// the now-playing bar. Mounted by both the home screen and the playlist
/// screen so a play started anywhere answers where Ido is looking.
private struct MusicBottomDock: View {
    @ObservedObject var model: MusicModel

    var body: some View {
        VStack(spacing: 8) {
            if !model.toast.isEmpty {
                Text(model.toast)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.black.opacity(0.72)))
                    .overlay(Capsule().stroke(MusicStyle.stroke, lineWidth: 1))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let p = model.player, let t = p.track {
                nowPlayingBar(p, t)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .animation(.snappy, value: model.toast)
        .animation(.snappy, value: model.player)
    }

    private func nowPlayingBar(_ p: MusicPlayerState, _ t: MusicTrackItem) -> some View {
        VStack(spacing: 0) {
            if p.durationMs > 0 {
                ProgressView(value: min(1, max(0, Double(p.progressMs) / Double(p.durationMs))))
                    .progressViewStyle(.linear)
                    .tint(MusicStyle.rose)
                    .scaleEffect(x: 1, y: 0.6, anchor: .center)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
            }
            HStack(spacing: 10) {
                MusicArt(url: t.image, size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(p.deviceName.map { "\(t.artist) · \($0)" } ?? t.artist)
                        .font(.system(size: 11))
                        .foregroundStyle(MusicStyle.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button { model.control("previous") } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Previous track")
                Button { model.control(p.isPlaying ? "pause" : "resume") } label: {
                    Image(systemName: p.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(MusicStyle.rose)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(p.isPlaying ? "Pause" : "Play")
                Button { model.control("next") } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Next track")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(MusicStyle.stroke, lineWidth: 1))
        .contentShape(Rectangle())
        // Tap anywhere outside the buttons → the full track sheet (the
        // "tap now-playing → full track view" parity item).
        .onTapGesture { model.detail = t }
    }
}

// MARK: - Playlist detail (pushed)

private struct MusicPlaylistDetailView: View {
    let playlist: MusicPlaylistItem
    @ObservedObject var model: MusicModel
    @Environment(\.dismiss) private var dismiss

    private enum LoadState {
        case loading
        case failed(String)
        case loaded
    }
    @State private var state: LoadState = .loading
    @State private var tracks: [MusicTrackItem] = []
    @State private var total = 0
    @State private var nextOffset: Int?
    @State private var loadingMore = false

    var body: some View {
        ZStack {
            ScarletBackground().ignoresSafeArea()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    header
                    switch state {
                    case .loading:
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Loading tracks…").font(.footnote).foregroundStyle(.secondary)
                        }
                        .padding(16)
                    case .failed(let message):
                        VStack(alignment: .leading, spacing: 10) {
                            Text(message)
                                .font(.callout).foregroundStyle(.secondary)
                            Button("Try again") { Task { await load() } }
                                .buttonStyle(.bordered)
                                .tint(MusicStyle.rose)
                        }
                        .padding(16)
                    case .loaded:
                        if tracks.isEmpty {
                            Text("No tracks in this playlist.")
                                .font(.callout).foregroundStyle(.secondary)
                                .padding(16)
                        } else {
                            ForEach(tracks) { t in
                                MusicTrackRow(track: t, model: model)
                            }
                            if nextOffset != nil {
                                Button {
                                    Task { await loadMore() }
                                } label: {
                                    HStack(spacing: 8) {
                                        if loadingMore { ProgressView() }
                                        Text(loadingMore
                                             ? "Loading…"
                                             : "Show more (\(tracks.count) of \(total))")
                                            .font(.system(size: 14, weight: .semibold))
                                    }
                                    .foregroundStyle(MusicStyle.rose)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                }
                                .buttonStyle(.plain)
                                .disabled(loadingMore)
                            }
                        }
                    }
                    Color.clear.frame(height: 12)
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        // Same dock as home: plays started here answer here.
        .safeAreaInset(edge: .bottom) { MusicBottomDock(model: model) }
        .task { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Explicit way back — Mac Catalyst has no edge-swipe and the root
            // hides the system bar, so the exit is drawn, like the mail reader.
            Button { dismiss() } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Music").font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(MusicStyle.rose)
            }
            .buttonStyle(.plain)
            HStack(alignment: .top, spacing: 14) {
                MusicArt(url: playlist.image, size: 96, corner: 12)
                VStack(alignment: .leading, spacing: 6) {
                    Text(playlist.name)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(3)
                        .multilineTextAlignment(playlist.name.readingAlignment)
                    Text(trackCountLine)
                        .font(.system(size: 12))
                        .foregroundStyle(MusicStyle.secondary)
                    Button {
                        model.play(uri: playlist.uri, label: playlist.name)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill")
                            Text("Play")
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(MusicStyle.rose))
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private var trackCountLine: String {
        let n = total > 0 ? total : playlist.count
        return n > 0 ? "\(n) tracks" : (playlist.owner ?? "")
    }

    @MainActor
    private func load() async {
        state = .loading
        switch await model.fetchPlaylist(id: playlist.id, offset: 0) {
        case .loaded(let page):
            tracks = page.tracks
            total = page.total
            nextOffset = page.nextOffset
            state = .loaded
        case .failed(let message):
            state = .failed(message)
        }
    }

    @MainActor
    private func loadMore() async {
        guard let offset = nextOffset, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        switch await model.fetchPlaylist(id: playlist.id, offset: offset) {
        case .loaded(let page):
            // Append with the dedup rule intact: a repeated id would crash the
            // ForEach diff at regular width.
            let known = Set(tracks.map { $0.id })
            tracks.append(contentsOf: page.tracks.filter { !known.contains($0.id) })
            total = page.total
            nextOffset = page.nextOffset
        case .failed(let message):
            model.showToast(message)
        }
    }
}

// MARK: - Track detail sheet

/// The full track screen: big art, title/artists/album, honest stats, Play,
/// and — when this IS the current track — live transport + Up Next. Seed data
/// paints instantly; `music_track` fills in album/popularity/features.
private struct MusicTrackDetailView: View {
    let seed: MusicTrackItem
    @ObservedObject var model: MusicModel
    @Environment(\.dismiss) private var dismiss
    @State private var phase: MusicDetailPhase = .loading

    private var isCurrent: Bool {
        model.player?.track?.uri == seed.uri
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ScarletBackground().ignoresSafeArea()
            ScrollView {
                VStack(spacing: 14) {
                    MusicArt(url: art, size: 232, corner: 16)
                        .padding(.top, 40)
                        .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
                    VStack(spacing: 4) {
                        Text(title)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                        Text(subtitle)
                            .font(.system(size: 15))
                            .foregroundStyle(MusicStyle.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                    .padding(.horizontal, 24)
                    statsRow
                    if isCurrent, let p = model.player {
                        transport(p)
                    } else {
                        Button {
                            model.play(uri: seed.uri, label: seed.title)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "play.fill")
                                Text("Play")
                            }
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 34)
                            .padding(.vertical, 11)
                            .background(Capsule().fill(MusicStyle.rose))
                        }
                        .buttonStyle(.plain)
                    }
                    if case .loading = phase {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Loading details…").font(.footnote).foregroundStyle(.secondary)
                        }
                        .padding(.top, 2)
                    }
                    if case .failed(let message) = phase {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(Color(red: 0.91, green: 0.69, blue: 0.31))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                    if isCurrent, let queue = model.player?.queue, !queue.isEmpty {
                        upNext(queue)
                    }
                    if !model.toast.isEmpty {
                        Text(model.toast)
                            .font(.footnote)
                            .foregroundStyle(.white)
                            .lineLimit(3)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(Color.black.opacity(0.72)))
                            .overlay(Capsule().stroke(MusicStyle.stroke, lineWidth: 1))
                    }
                    Color.clear.frame(height: 24)
                }
                .frame(maxWidth: .infinity)
            }
            // Guaranteed exit (sheet gestures can be flaky on Catalyst).
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.black.opacity(0.5)))
            }
            .buttonStyle(.plain)
            .padding(.top, 12)
            .padding(.leading, 12)
            .accessibilityLabel("Close track details")
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
        .animation(.snappy, value: model.toast)
        .task { phase = await model.fetchTrackDetail(uri: seed.uri) }
    }

    // Loaded detail wins; the seed keeps the screen honest until it lands.
    private var loaded: MusicTrackDetailData? {
        if case .loaded(let d) = phase { return d }
        return nil
    }
    private var art: String? { loaded?.track.image ?? seed.image }
    private var title: String { loaded?.track.title ?? seed.title }
    private var subtitle: String {
        let artist = loaded.map { $0.artists.isEmpty ? $0.track.artist : $0.artists.joined(separator: ", ") }
            ?? seed.artist
        if let album = loaded?.album, !album.isEmpty { return "\(artist) · \(album)" }
        return artist
    }

    /// One stat chip's data. Labels are unique per row ("Length",
    /// "Popularity", "BPM", "Energy") so the label is the honest identity.
    private struct Stat: Identifiable {
        let value: String
        let label: String
        var id: String { label }
    }

    @ViewBuilder
    private var statsRow: some View {
        let duration = (loaded?.track.durationMs ?? seed.durationMs)
        let stats: [Stat] = {
            var out: [Stat] = []
            if duration > 0 { out.append(Stat(value: musicDuration(duration), label: "Length")) }
            if let pop = loaded?.popularity { out.append(Stat(value: "\(pop)", label: "Popularity")) }
            if let tempo = loaded?.tempo { out.append(Stat(value: "\(Int(tempo.rounded()))", label: "BPM")) }
            if let energy = loaded?.energy { out.append(Stat(value: "\(Int((energy * 100).rounded()))%", label: "Energy")) }
            return out
        }()
        if !stats.isEmpty {
            HStack(spacing: 10) {
                ForEach(stats) { stat in
                    VStack(spacing: 2) {
                        Text(stat.value)
                            .font(.system(size: 15, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                        Text(stat.label)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(MusicStyle.secondary)
                    }
                    .frame(minWidth: 62)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 6)
                    .background(RoundedRectangle(cornerRadius: 10).fill(MusicStyle.surface))
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func transport(_ p: MusicPlayerState) -> some View {
        VStack(spacing: 10) {
            if p.durationMs > 0 {
                VStack(spacing: 3) {
                    ProgressView(value: min(1, max(0, Double(p.progressMs) / Double(p.durationMs))))
                        .progressViewStyle(.linear)
                        .tint(MusicStyle.rose)
                    HStack {
                        Text(musicDuration(p.progressMs))
                        Spacer()
                        Text(musicDuration(p.durationMs))
                    }
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(MusicStyle.tertiary)
                }
                .padding(.horizontal, 36)
            }
            HStack(spacing: 34) {
                Button { model.control("previous") } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Previous track")
                Button { model.control(p.isPlaying ? "pause" : "resume") } label: {
                    Image(systemName: p.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 62))
                        .foregroundStyle(MusicStyle.rose)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(p.isPlaying ? "Pause" : "Play")
                Button { model.control("next") } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Next track")
            }
            if let device = p.deviceName {
                HStack(spacing: 5) {
                    Image(systemName: "hifispeaker")
                        .font(.system(size: 11))
                    Text(device)
                        .font(.system(size: 12))
                }
                .foregroundStyle(MusicStyle.secondary)
            }
        }
    }

    private func upNext(_ queue: [MusicQueueItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("UP NEXT")
                .font(.system(size: 12, weight: .semibold))
                .kerning(0.5)
                .foregroundStyle(MusicStyle.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 8)
            ForEach(queue) { q in
                HStack(spacing: 10) {
                    MusicArt(url: q.image, size: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(q.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(q.artist)
                            .font(.system(size: 11))
                            .foregroundStyle(MusicStyle.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
