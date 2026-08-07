import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The Music section: a real music app, not a shelf of dead tiles.
///
/// - Browse: playlists PUSH into a full `PlaylistDetailView` (artwork header,
///   Play / Shuffle, pageable track list, tap-to-play a specific track).
/// - Now Playing: the bar carries art + a live progress line and opens the full
///   `MusicPlayerView` (big art, scrubbable progress, transport, up-next queue).
/// - Search: one field over tracks / playlists / albums / artists, debounced.
/// - And still: he can just *say* "play <something>" and Scarlet starts it.
///
/// Backend: the same edge-function plumbing as the rest of the app
/// (`app-api?v=2` + `x-scarlet-token`). Ops used here: `music_library`,
/// `music_state`, `music_playlist`, `music_search` (GET) and `music_play`,
/// `music_control`, `music_seek`, `music_shuffle` (POST).
///
/// Provider seam: everything the page needs is expressed through
/// `MusicProvider`, so a second service (Tidal) can be dropped in later without
/// touching the views. Only Spotify is implemented today.
///
/// Catalyst discipline: `PlaylistDetailView` is a PUSH (`navigationDestination`)
/// and `MusicPlayerView` is the SINGLE `.sheet` on this view — never two
/// sheets. Both re-inject `convo` at the construction site (Catalyst drops
/// @EnvironmentObject across those boundaries).

// MARK: - Wire model (provider-neutral)

/// One playlist tile on the shelf (also a search result row). Hashable so it
/// can drive `navigationDestination(item:)`.
struct MusicPlaylist: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let imageURL: URL?
    let count: Int
    let uri: String
}

/// One saved/liked track row (also a search result row).
struct MusicTrack: Identifiable, Equatable {
    let id: String
    let title: String
    let artist: String
    let imageURL: URL?
    let uri: String
}

/// The legacy now-playing card from `music_library` — kept as the honest
/// fallback until the richer `music_state` snapshot has loaded.
struct MusicNowPlaying: Equatable {
    let title: String
    let artist: String
    let imageURL: URL?
    let isPlaying: Bool
}

/// A full snapshot of the library, as one provider returns it.
struct MusicLibrarySnapshot: Equatable {
    var playlists: [MusicPlaylist] = []
    var saved: [MusicTrack] = []
    var nowPlaying: MusicNowPlaying? = nil
    /// A gentle provider note ("Connect Spotify", "Nothing saved yet") — shown
    /// only when there's nothing else to render.
    var note: String? = nil
    /// True only when a live Spotify Connect device exists right now. When false,
    /// nothing can actually play — any `nowPlaying` is a stale "ghost" track from
    /// a past session, so the page must not fake live audio.
    var hasActiveDevice: Bool = false
    /// How many Spotify apps are currently open to play to (0 → prompt "Open
    /// Spotify"). Informational alongside `hasActiveDevice`.
    var availableDevices: Int = 0
}

/// The track currently loaded on the player (from `music_state`).
struct MusicPlayerTrack: Equatable {
    let uri: String
    let title: String
    let artist: String
    let album: String
    let imageURL: URL?
}

/// Where the sound is coming out (from `music_state`). `nil` device = nothing
/// can actually play right now.
struct MusicDevice: Equatable {
    let name: String
    let type: String
}

/// One "up next" row from the live queue.
struct MusicQueueItem: Identifiable, Equatable {
    let id: String
    let uri: String
    let title: String
    let artist: String
    let imageURL: URL?
}

/// The live player snapshot — `op=music_state`, polled while the page (10s)
/// or the full player (5s) is on screen. Progress ticks locally between polls.
struct MusicPlayerState: Equatable {
    var track: MusicPlayerTrack?
    var progressMs: Int
    var durationMs: Int
    var isPlaying: Bool
    var device: MusicDevice?
    var shuffle: Bool
    /// Spotify repeat state ("off" / "context" / "track"). Displayed passively —
    /// the server exposes no repeat setter yet.
    var repeatMode: String
    var queue: [MusicQueueItem]
}

/// One page of a playlist's tracks — `op=music_playlist`.
struct MusicPlaylistTrack: Identifiable, Equatable {
    let id: String
    let uri: String
    let title: String
    let artist: String
    let imageURL: URL?
    let durationMs: Int
}

struct MusicPlaylistDetailPage: Equatable {
    var name: String
    var imageURL: URL?
    var tracks: [MusicPlaylistTrack]
    var total: Int
    var nextOffset: Int?
}

/// An album or artist search hit (they share a shape).
struct MusicSearchEntity: Identifiable, Equatable {
    let id: String
    let uri: String
    let name: String
    let subtitle: String
    let imageURL: URL?
}

/// Sectioned results from `op=music_search`.
struct MusicSearchResults: Equatable {
    var tracks: [MusicTrack] = []
    var playlists: [MusicPlaylist] = []
    var albums: [MusicSearchEntity] = []
    var artists: [MusicSearchEntity] = []
    var isEmpty: Bool {
        tracks.isEmpty && playlists.isEmpty && albums.isEmpty && artists.isEmpty
    }
}

// MARK: - Provider seam (Spotify today, Tidal later)

/// The thin contract the Music screens are written against. Add Tidal by
/// writing a second `MusicProvider`; the views and model never change.
protocol MusicProvider {
    /// Human label for the source ("Spotify"), used in copy and empty states.
    var displayName: String { get }
    /// Fetch the whole page in one shot. Must not throw for an *empty* library —
    /// it returns an empty snapshot (optionally with a `note`); it throws only
    /// on a real transport/auth failure so the view can show a retry.
    func fetchLibrary() async throws -> MusicLibrarySnapshot
    /// The live player snapshot (track, progress, device, queue).
    func fetchState() async throws -> MusicPlayerState
    /// One page of a playlist's tracks, starting at `offset`.
    func fetchPlaylist(id: String, offset: Int) async throws -> MusicPlaylistDetailPage
    /// Sectioned search across the catalog.
    func search(query: String) async throws -> MusicSearchResults
    /// Start playback of an exact provider URI (a tapped playlist or track).
    /// Returns where sound is ACTUALLY coming out — the server verifies real
    /// playback before reporting ok, so a success here means audio is rolling.
    func play(uri: String) async throws -> MusicPlayOutcome
    /// pause / resume / next / previous.
    func control(_ action: String) async throws
    /// Jump to a position in the current track.
    func seek(positionMs: Int) async throws
    /// Turn shuffle on/off.
    func setShuffle(_ on: Bool) async throws
}

extension MusicProvider {
    /// Resume / pause whatever is currently loaded (the now-playing button).
    func setPlaying(_ playing: Bool) async throws {
        try await control(playing ? "resume" : "pause")
    }
}

/// Verified playback destination (device name + type, e.g. "Ido's iPhone",
/// "Smartphone"). Lets the UI say honestly when music went to a speaker or
/// Mac instead of the phone in his hand.
struct MusicPlayOutcome {
    let device: String?
    let deviceType: String?
}

/// The server's honest playback failure ("Spotify isn't open near you — …"),
/// carried verbatim so the flash message never lies about what went wrong.
/// Without this, a 200 response whose BODY was {error: …} read as success and
/// the page showed "now playing" over silence.
///
/// `retrying` = the server accepted the request and keeps retrying for ~24s
/// while Spotify registers as a device — the UI should say "Open Spotify —
/// it'll start by itself" and watch `music_state` for the auto-start.
struct MusicPlayError: LocalizedError {
    let message: String
    var retrying: Bool = false
    var errorDescription: String? { message }
}

/// Spotify implementation over `app-api`. Holds no secret — the edge function
/// owns the OAuth token; the app only carries the device token.
struct SpotifyMusicProvider: MusicProvider {
    let displayName = "Spotify"

    func fetchLibrary() async throws -> MusicLibrarySnapshot {
        let data = try await MusicAPI.get("music_library")
        let obj = Self.json(data)
        return MusicLibrarySnapshot(
            playlists: Self.parsePlaylists(obj["playlists"]),
            saved: Self.parseTracks(obj["saved"]),
            nowPlaying: Self.parseNowPlaying(obj["nowPlaying"]),
            note: (obj["note"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            hasActiveDevice: (obj["hasActiveDevice"] as? Bool) ?? false,
            availableDevices: Self.intVal(obj["availableDevices"])
        )
    }

    func fetchState() async throws -> MusicPlayerState {
        let data = try await MusicAPI.get("music_state")
        let obj = Self.json(data)
        try Self.throwIfError(obj)
        return Self.parseState(obj)
    }

    func fetchPlaylist(id: String, offset: Int) async throws -> MusicPlaylistDetailPage {
        let data = try await MusicAPI.get(
            "music_playlist", params: ["id": id, "offset": String(offset)])
        let obj = Self.json(data)
        try Self.throwIfError(obj)
        let raw = (obj["tracks"] as? [[String: Any]]) ?? []
        let tracks = raw.enumerated().compactMap { idx, t -> MusicPlaylistTrack? in
            guard let uri = t["uri"] as? String, !uri.isEmpty else { return nil }
            return MusicPlaylistTrack(
                // Index-qualified id: the same track can appear twice in one
                // playlist, and rows must stay unique across pages.
                id: "\(offset + idx):\(uri)",
                uri: uri,
                title: (t["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled",
                artist: (t["artist"] as? String) ?? "",
                imageURL: Self.url(t["image"]),
                durationMs: Self.intVal(t["duration_ms"])
            )
        }
        // next_offset must strictly advance or paging stops — never loop.
        let next = Self.optIntVal(obj["next_offset"]).flatMap { $0 > offset ? $0 : nil }
        return MusicPlaylistDetailPage(
            name: (obj["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "",
            imageURL: Self.url(obj["image"]),
            tracks: tracks,
            total: Self.intVal(obj["total"]),
            nextOffset: next
        )
    }

    func search(query: String) async throws -> MusicSearchResults {
        let data = try await MusicAPI.get("music_search", params: ["q": query])
        let obj = Self.json(data)
        try Self.throwIfError(obj)
        return MusicSearchResults(
            tracks: Self.parseSearchTracks(obj["tracks"]),
            playlists: Self.parsePlaylists(obj["playlists"], allowDerivedID: true),
            albums: Self.parseEntities(obj["albums"], subtitleKey: "artist"),
            artists: Self.parseEntities(obj["artists"], subtitleKey: nil)
        )
    }

    func play(uri: String) async throws -> MusicPlayOutcome {
        let data = try await MusicAPI.post("music_play", body: ["uri": uri])
        let obj = Self.json(data)
        // The edge function returns failures as 200s with an `error` body —
        // surface them as real errors so the UI never paints success over one.
        if let err = obj["error"] as? String, !err.isEmpty {
            throw MusicPlayError(message: err, retrying: (obj["retrying"] as? Bool) ?? false)
        }
        return MusicPlayOutcome(
            device: obj["device"] as? String,
            deviceType: obj["device_type"] as? String
        )
    }

    func control(_ action: String) async throws {
        let data = try await MusicAPI.post("music_control", body: ["action": action])
        try Self.throwIfError(Self.json(data))
    }

    func seek(positionMs: Int) async throws {
        let data = try await MusicAPI.post("music_seek", body: ["position_ms": positionMs])
        try Self.throwIfError(Self.json(data))
    }

    func setShuffle(_ on: Bool) async throws {
        let data = try await MusicAPI.post("music_shuffle", body: ["on": on])
        try Self.throwIfError(Self.json(data))
    }

    // -- parsing (defensive: every field optional, art URLs never force-unwrapped)

    private static func json(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private static func throwIfError(_ obj: [String: Any]) throws {
        if let err = obj["error"] as? String, !err.isEmpty {
            throw MusicPlayError(message: err, retrying: (obj["retrying"] as? Bool) ?? false)
        }
    }

    private static func url(_ any: Any?) -> URL? {
        guard let s = any as? String, !s.isEmpty else { return nil }
        return URL(string: s)
    }

    private static func intVal(_ any: Any?) -> Int {
        (any as? Int) ?? Int((any as? Double) ?? 0)
    }

    /// Like `intVal` but distinguishes "absent/null" from a real number, and
    /// treats 0 as absent (a next_offset of 0 can never follow a first page).
    private static func optIntVal(_ any: Any?) -> Int? {
        let v = (any as? Int) ?? (any as? Double).map(Int.init)
        guard let v, v > 0 else { return nil }
        return v
    }

    /// The tail of a spotify URI ("spotify:playlist:abc" → "abc") — the id
    /// fallback for search rows that carry only a uri.
    private static func uriTail(_ uri: String) -> String {
        uri.split(separator: ":").last.map(String.init) ?? uri
    }

    private static func parsePlaylists(_ any: Any?, allowDerivedID: Bool = false) -> [MusicPlaylist] {
        let raw = (any as? [[String: Any]]) ?? []
        var seen = Set<String>()
        return raw.compactMap { p in
            guard let uri = p["uri"] as? String, !uri.isEmpty else { return nil }
            let id = (p["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (allowDerivedID ? uriTail(uri) : nil)
            guard let id, seen.insert(id).inserted else { return nil }
            return MusicPlaylist(
                id: id,
                name: (p["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Playlist",
                imageURL: url(p["image"]),
                count: intVal(p["count"] ?? p["total"]),
                uri: uri
            )
        }
    }

    private static func parseTracks(_ any: Any?) -> [MusicTrack] {
        let raw = (any as? [[String: Any]]) ?? []
        var seen = Set<String>()
        return raw.compactMap { t in
            guard let id = t["id"] as? String, !id.isEmpty,
                  let uri = t["uri"] as? String, !uri.isEmpty,
                  seen.insert(id).inserted else { return nil }
            return MusicTrack(
                id: id,
                title: (t["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled",
                artist: (t["artist"] as? String) ?? "",
                imageURL: url(t["image"]),
                uri: uri
            )
        }
    }

    /// Search track rows follow the `music_state` track shape (uri/title/artist/
    /// image, no `id`) — derive the id from the uri.
    private static func parseSearchTracks(_ any: Any?) -> [MusicTrack] {
        let raw = (any as? [[String: Any]]) ?? []
        var seen = Set<String>()
        return raw.compactMap { t in
            guard let uri = t["uri"] as? String, !uri.isEmpty else { return nil }
            let id = (t["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? uri
            guard seen.insert(id).inserted else { return nil }
            return MusicTrack(
                id: id,
                title: (t["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? (t["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled",
                artist: (t["artist"] as? String) ?? "",
                imageURL: url(t["image"]),
                uri: uri
            )
        }
    }

    private static func parseEntities(_ any: Any?, subtitleKey: String?) -> [MusicSearchEntity] {
        let raw = (any as? [[String: Any]]) ?? []
        var seen = Set<String>()
        return raw.compactMap { e in
            guard let uri = e["uri"] as? String, !uri.isEmpty,
                  seen.insert(uri).inserted else { return nil }
            let name = (e["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (e["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled"
            let subtitle = subtitleKey.flatMap { e[$0] as? String } ?? ""
            return MusicSearchEntity(
                id: uri, uri: uri, name: name, subtitle: subtitle, imageURL: url(e["image"]))
        }
    }

    private static func parseNowPlaying(_ any: Any?) -> MusicNowPlaying? {
        guard let n = any as? [String: Any] else { return nil }
        let title = (n["title"] as? String) ?? ""
        if title.isEmpty { return nil }
        return MusicNowPlaying(
            title: title,
            artist: (n["artist"] as? String) ?? "",
            imageURL: url(n["image"]),
            isPlaying: (n["isPlaying"] as? Bool) ?? false
        )
    }

    private static func parseState(_ obj: [String: Any]) -> MusicPlayerState {
        var track: MusicPlayerTrack?
        if let t = obj["track"] as? [String: Any] {
            let title = (t["title"] as? String) ?? ""
            if !title.isEmpty {
                track = MusicPlayerTrack(
                    uri: (t["uri"] as? String) ?? "",
                    title: title,
                    artist: (t["artist"] as? String) ?? "",
                    album: (t["album"] as? String) ?? "",
                    imageURL: url(t["image"])
                )
            }
        }
        var device: MusicDevice?
        if let d = obj["device"] as? [String: Any],
           let name = d["name"] as? String, !name.isEmpty {
            device = MusicDevice(name: name, type: (d["type"] as? String) ?? "")
        }
        let queue = ((obj["queue"] as? [[String: Any]]) ?? []).enumerated()
            .compactMap { idx, q -> MusicQueueItem? in
                let title = (q["title"] as? String) ?? ""
                guard !title.isEmpty else { return nil }
                let uri = (q["uri"] as? String) ?? ""
                return MusicQueueItem(
                    id: "\(idx):\(uri.isEmpty ? title : uri)",
                    uri: uri,
                    title: title,
                    artist: (q["artist"] as? String) ?? "",
                    imageURL: url(q["image"])
                )
            }
        // `repeat` arrives as a string ("off"/"context"/"track") — tolerate a
        // bool too, defensively.
        let repeatMode = (obj["repeat"] as? String)
            ?? ((obj["repeat"] as? Bool).map { $0 ? "context" : "off" })
            ?? "off"
        return MusicPlayerState(
            track: track,
            progressMs: intVal(obj["progress_ms"]),
            durationMs: intVal(obj["duration_ms"]),
            isPlaying: (obj["is_playing"] as? Bool) ?? false,
            device: device,
            shuffle: (obj["shuffle"] as? Bool) ?? false,
            repeatMode: repeatMode,
            queue: queue
        )
    }
}

/// Tiny app-api client for the Music screens — GET reads and POST actions on
/// `app-api?v=2`, carrying only the device token. Mirrors DraftView/LibraryView
/// plumbing (200-check, JSON body).
enum MusicAPI {
    static func get(_ op: String, params: [String: String] = [:]) async throws -> Data {
        var comps = URLComponents(string: "\(AppConfig.apiBase)/app-api")
        var items = [URLQueryItem(name: "v", value: "2"), URLQueryItem(name: "op", value: op)]
        for key in params.keys.sorted() {
            items.append(URLQueryItem(name: key, value: params[key]))
        }
        comps?.queryItems = items
        guard let url = comps?.url else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(TokenStore.token ?? "", forHTTPHeaderField: "x-scarlet-token")
        return try await run(req)
    }

    static func post(_ op: String, body: [String: Any]) async throws -> Data {
        guard let url = URL(string: "\(AppConfig.apiBase)/app-api?v=2&op=\(op)") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(TokenStore.token ?? "", forHTTPHeaderField: "x-scarlet-token")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await run(req)
    }

    private static func run(_ req: URLRequest) async throws -> Data {
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

// MARK: - Shared UI vocabulary (palette, artwork, time, focus prefixes)

/// House styling + tiny helpers shared by the Music screens.
enum MusicUI {
    /// House dark-scarlet palette (matches LibraryView / DraftView).
    static let rose = Color(red: 1, green: 0.35, blue: 0.42)
    static let cardBG = Color(white: 0.12)

    /// "3:45" (or "1:02:07") from milliseconds.
    static func time(ms: Int) -> String {
        let totalSec = max(0, ms / 1000)
        let h = totalSec / 3600
        let m = (totalSec % 3600) / 60
        let s = totalSec % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }

    /// Deep-link into the Spotify app so it registers as an active Connect
    /// device. Tries the `spotify:` scheme first (opens straight into the app),
    /// then the `https://open.spotify.com` universal link as a fallback. We just
    /// attempt `open(_:)` — it succeeds without an `LSApplicationQueriesSchemes`
    /// entry even when `canOpenURL` would return false. If neither opens, the
    /// honest inline text simply stays put.
    static func openSpotify() {
        #if canImport(UIKit)
        let app = UIApplication.shared
        let scheme = URL(string: "spotify://")
        let web = URL(string: "https://open.spotify.com")
        if let scheme {
            app.open(scheme, options: [:]) { ok in
                if !ok, let web { app.open(web, options: [:], completionHandler: nil) }
            }
        } else if let web {
            app.open(web, options: [:], completionHandler: nil)
        }
        #endif
    }
}

/// Ambient-focus line prefixes — the stale-guard tokens: the page only
/// restores its own focus if the current focus still belongs to one of its
/// child screens (another section may have claimed focus meanwhile).
enum MusicFocus {
    static let playlistPrefix = "[FOCUS] Ido opened his playlist"
    static let playerPrefix = "[FOCUS] Ido is on the full Music player"
}

/// Artwork with a graceful placeholder — never force-unwraps a URL, and draws
/// a music-note tile when there's no art or the load fails.
struct MusicArtwork: View {
    let url: URL?
    var size: CGFloat
    var corner: CGFloat

    var body: some View {
        let placeholder = RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(Color(white: 0.2))
            .overlay(
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.32, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
            )
        if let url {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .empty:
                    ZStack { placeholder; ProgressView().tint(.white.opacity(0.6)) }
                default:
                    placeholder
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        } else {
            placeholder.frame(width: size, height: size)
        }
    }
}

/// The transient bottom toast ("Playing on Kitchen", the server's honest play
/// failure). Shared by the page, the playlist detail, and the full player.
struct MusicFlashToast: View {
    @ObservedObject var model: MusicModel

    var body: some View {
        if !model.flash.isEmpty {
            Text(model.flash)
                .font(.scarletDetailEmph)
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(
                    Capsule().fill(Color(white: 0.18))
                        .overlay(Capsule().stroke(MusicUI.rose.opacity(0.5), lineWidth: 1))
                )
                .padding(.bottom, 18)
                .shadow(radius: 8, y: 3)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onAppear {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 3_500_000_000)
                        model.flash = ""
                    }
                }
        }
    }
}

// MARK: - Model

@MainActor
final class MusicModel: ObservableObject {
    @Published var snapshot = MusicLibrarySnapshot()
    @Published var loading = false
    @Published var errorText = ""
    /// A short transient toast shown when a play action fails ("Couldn't start
    /// — open Spotify on a device first"), cleared on the next successful tap.
    @Published var flash = ""
    /// Set when a play/control action failed because Spotify Connect has no
    /// active device. Unlike `flash`, this is a *persistent* inline state that
    /// stays until a play succeeds — it drives the calm "Open Spotify" recovery
    /// affordance instead of a toast that vanishes and dead-ends him.
    @Published var needsDevice = false
    /// The uri currently being started, to show a spinner on the tapped row.
    @Published var startingURI: String?

    /// The live player snapshot (`music_state`) and when it arrived — the
    /// arrival stamp lets the progress bar tick locally between polls.
    @Published var playerState: MusicPlayerState?
    @Published var stateReceivedAt = Date()
    /// True while we're watching `music_state` for the server's auto-start
    /// after a "no device, retrying" play (~30s). Drives the "Open Spotify —
    /// it'll start by itself" recovery copy.
    @Published var retryWatchActive = false

    // Search
    @Published var searchText = ""
    @Published var searchResults: MusicSearchResults?
    @Published var searching = false
    @Published var searchError = ""

    let provider: MusicProvider
    private var retryWatch: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?

    init(provider: MusicProvider = SpotifyMusicProvider()) {
        self.provider = provider
    }

    var isEmpty: Bool {
        snapshot.playlists.isEmpty && snapshot.saved.isEmpty && snapshot.nowPlaying == nil
    }

    /// Something is verifiably loaded on a real device right now.
    var isLive: Bool {
        playerState?.track != nil && playerState?.device != nil
    }

    func load() async {
        guard TokenStore.token != nil else {
            snapshot = MusicLibrarySnapshot()
            errorText = "Locked — unlock Scarlet to see your music."
            return
        }
        if isEmpty { loading = true }
        errorText = ""
        defer { loading = false }
        do {
            snapshot = try await provider.fetchLibrary()
            // Proactively surface the calm "Open Spotify" card whenever nothing
            // can actually play — but only when the library otherwise loaded
            // (connected, has content). Don't trip it on an empty/not-connected
            // page, whose own empty state already guides him.
            needsDevice = !isEmpty && !snapshot.hasActiveDevice
        } catch {
            errorText = "Couldn't reach \(provider.displayName) — check your connection."
        }
    }

    /// One `music_state` poll. Quiet on failure — the last honest snapshot
    /// stays put and the next poll retries; progress only ever ticks locally
    /// while the last *fetched* state said `is_playing`.
    func refreshState() async {
        guard TokenStore.token != nil else { return }
        if let s = try? await provider.fetchState() {
            playerState = s
            stateReceivedAt = Date()
            // Something is audibly playing → the device recovery is moot.
            if s.isPlaying { needsDevice = false }
        }
    }

    /// The progress the UI should show at `date`: last polled position, plus
    /// local elapsed time while playing, clamped to the track length.
    func displayedProgressMs(at date: Date) -> Int? {
        guard let s = playerState, s.track != nil, s.durationMs > 0 else { return nil }
        guard s.isPlaying else { return min(s.progressMs, s.durationMs) }
        let elapsed = Int(date.timeIntervalSince(stateReceivedAt) * 1000)
        return min(s.progressMs + max(0, elapsed), s.durationMs)
    }

    /// Tap a playlist/track/album → start it on his active device.
    func play(uri: String) {
        guard !uri.isEmpty, startingURI == nil else { return }
        flash = ""
        startingURI = uri
        retryWatch?.cancel()
        retryWatchActive = false
        Task { @MainActor in
            defer { startingURI = nil }
            do {
                let outcome = try await provider.play(uri: uri)
                // Playback VERIFIED rolling (the server checks before ok) →
                // clear recovery. If sound went somewhere other than the phone
                // in his hand (a speaker, the Mac), say so — silence with a
                // "playing" card is the one thing this page must never show.
                needsDevice = false
                if let type = outcome.deviceType, type.lowercased() != "smartphone",
                   let dev = outcome.device {
                    flash = "Playing on \(dev)"
                } else {
                    flash = ""
                }
                // Give the device a beat, then reflect reality everywhere.
                try? await Task.sleep(nanoseconds: 700_000_000)
                await refreshState()
                snapshot = (try? await provider.fetchLibrary()) ?? snapshot
            } catch {
                // Connect can only play to an already-open Spotify app. Surface a
                // calm, persistent "Open Spotify" affordance, plus the SERVER'S
                // honest reason near the action when it gave one — it names the
                // real situation ("only registered device is Mac Studio…"),
                // which a generic line would hide.
                needsDevice = true
                let playError = error as? MusicPlayError
                if playError?.retrying == true {
                    // The server keeps retrying for ~24s once Spotify registers
                    // — one tap on Open Spotify and the music starts by itself.
                    flash = "Open Spotify — it'll start by itself"
                    startAutoStartWatch()
                } else {
                    let msg = playError?.message ?? ""
                    flash = msg.isEmpty ? "Open Spotify on a device to play" : String(msg.prefix(140))
                }
            }
        }
    }

    /// After a "retrying" play failure: watch `music_state` for ~30s so the UI
    /// flips to playing BY ITSELF the moment Spotify registers and the server's
    /// queued play lands — no second tap.
    private func startAutoStartWatch() {
        retryWatch?.cancel()
        retryWatchActive = true
        retryWatch = Task { @MainActor in
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { return }
                await refreshState()
                if let s = playerState, s.isPlaying {
                    needsDevice = false
                    retryWatchActive = false
                    if let d = s.device, d.type.lowercased() != "smartphone" {
                        flash = "Playing on \(d.name)"
                    }
                    snapshot = (try? await provider.fetchLibrary()) ?? snapshot
                    return
                }
            }
            retryWatchActive = false
        }
    }

    /// Shuffle-play a whole playlist: turn shuffle on (best effort — `play`
    /// still reports the honest outcome), then start the context.
    func playShuffled(uri: String) {
        Task { @MainActor in
            try? await provider.setShuffle(true)
            play(uri: uri)
        }
    }

    /// Now-playing play/pause toggle — prefers the live `music_state`; falls
    /// back to the legacy library card until the first state poll lands.
    func togglePlayPause() {
        if var s = playerState, s.track != nil {
            let want = !s.isPlaying
            // Freeze/extend the local progress base so ticking stays honest
            // across the flip, then apply optimistically for an instant button.
            s.progressMs = displayedProgressMs(at: Date()) ?? s.progressMs
            s.isPlaying = want
            playerState = s
            stateReceivedAt = Date()
            Task { @MainActor in
                do {
                    try await provider.setPlaying(want)
                    needsDevice = false
                } catch {
                    needsDevice = true
                    let msg = (error as? MusicPlayError)?.message ?? ""
                    flash = msg.isEmpty ? "Open Spotify on a device to play" : String(msg.prefix(140))
                    await refreshState()
                }
            }
            return
        }
        guard let np = snapshot.nowPlaying else { return }
        let want = !np.isPlaying
        // Optimistic flip so the button responds instantly.
        snapshot.nowPlaying = MusicNowPlaying(
            title: np.title, artist: np.artist, imageURL: np.imageURL, isPlaying: want
        )
        Task { @MainActor in
            do {
                try await provider.setPlaying(want)
                needsDevice = false
            } catch {
                // Revert the optimistic flip and surface the same calm recovery,
                // plus a short flash near the button so the failed tap is visible.
                snapshot.nowPlaying = np
                needsDevice = true
                flash = "Open Spotify on a device to play"
            }
        }
    }

    /// Next / previous track.
    func skip(forward: Bool) {
        Task { @MainActor in
            do {
                try await provider.control(forward ? "next" : "previous")
                try? await Task.sleep(nanoseconds: 600_000_000)
                await refreshState()
            } catch {
                let msg = (error as? MusicPlayError)?.message ?? ""
                flash = msg.isEmpty ? "Couldn't skip — is Spotify open?" : String(msg.prefix(140))
                await refreshState()
            }
        }
    }

    /// Jump to a position (the player's drag-to-seek).
    func seek(toMs ms: Int) {
        guard var s = playerState, s.durationMs > 0 else { return }
        let clamped = max(0, min(ms, s.durationMs))
        s.progressMs = clamped
        playerState = s
        stateReceivedAt = Date()
        Task { @MainActor in
            do {
                try await provider.seek(positionMs: clamped)
            } catch {
                let msg = (error as? MusicPlayError)?.message ?? ""
                flash = msg.isEmpty ? "Couldn't seek" : String(msg.prefix(140))
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
            await refreshState()
        }
    }

    /// The player's shuffle toggle (optimistic, resynced on failure).
    func toggleShuffle() {
        guard var s = playerState else { return }
        let want = !s.shuffle
        s.shuffle = want
        playerState = s
        Task { @MainActor in
            do {
                try await provider.setShuffle(want)
            } catch {
                let msg = (error as? MusicPlayError)?.message ?? ""
                flash = msg.isEmpty ? "Couldn't change shuffle" : String(msg.prefix(140))
                await refreshState()
            }
        }
    }

    /// Debounced (~400ms) sectioned search. An empty query clears results.
    func updateSearch(_ query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = nil
            searching = false
            searchError = ""
            return
        }
        searching = true
        searchError = ""
        searchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            do {
                let results = try await provider.search(query: trimmed)
                guard !Task.isCancelled else { return }
                searchResults = results
                searching = false
            } catch {
                guard !Task.isCancelled else { return }
                searching = false
                let msg = (error as? MusicPlayError)?.message ?? ""
                searchError = msg.isEmpty
                    ? "Couldn't search \(provider.displayName) — check your connection."
                    : String(msg.prefix(140))
            }
        }
    }
}

// MARK: - View (the Music page)

struct MusicView: View {
    @StateObject private var model = MusicModel()
    @EnvironmentObject private var convo: Conversation

    /// The pushed playlist (navigationDestination — Catalyst-safe, sidebar
    /// stays reachable).
    @State private var openPlaylist: MusicPlaylist?
    /// The full player — the SINGLE `.sheet` on this view (Catalyst allows
    /// only one). One `.sheet` + one push is the sanctioned combination.
    @State private var showPlayer = false

    private let scarletRose = MusicUI.rose
    private let cardBG = MusicUI.cardBG

    var body: some View {
        NavigationStack {
            ZStack {
                ScarletTheme.ink.ignoresSafeArea()   // shared near-black ink ground; green accent stays as chrome
                content
            }
            .toolbar(.hidden, for: .navigationBar)
            // Playlist browsing PUSHES (like Notes/Library readers); convo is
            // re-injected — Catalyst drops @EnvironmentObject across the push.
            .navigationDestination(item: $openPlaylist) { pl in
                PlaylistDetailView(playlist: pl, model: model)
                    .environmentObject(convo)
                    .preferredColorScheme(.dark)
            }
            // The full player — the single `.sheet` on this view.
            .sheet(isPresented: $showPlayer) {
                MusicPlayerView(model: model)
                    .environmentObject(convo)
                    .preferredColorScheme(.dark)
            }
            .reportsModalPresence(showPlayer)
            .onChange(of: openPlaylist) { _, newValue in
                if newValue == nil { restorePageFocus() }
            }
            .onChange(of: showPlayer) { _, isUp in
                if !isUp { restorePageFocus() }
            }
        }
        .task {
            await model.load()
            await model.refreshState()
        }
        // Keep the bar honest while the page is up: `music_state` every ~10s.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                await model.refreshState()
            }
        }
        .refreshable {
            await model.load()
            await model.refreshState()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.willEnterForegroundNotification)) { _ in
            Task {
                await model.refreshState()
                await model.load()
            }
        }
        // Ambient focus: the page reports itself on appearance and again as
        // reality changes — but never while a child screen owns the focus.
        .onAppear { convo.setFocus(pageFocus()) }
        .onChange(of: model.snapshot) { _, _ in maybeSetPageFocus() }
        .onChange(of: model.playerState) { _, _ in maybeSetPageFocus() }
        .onChange(of: model.searchResults) { _, _ in maybeSetPageFocus() }
    }

    // MARK: Scarlet focus

    /// The page-level ambient-focus line — what's playing (or last played) and
    /// what the shelf shows, so "pause it", "add this to a playlist", "play
    /// something like this" need no explanation.
    private func pageFocus() -> String {
        let s = model.snapshot
        var line = "[FOCUS] Ido is on his Music page (\(model.provider.displayName))."
        if let st = model.playerState, let tr = st.track, st.device != nil {
            let byArtist = tr.artist.isEmpty ? "" : " by \(tr.artist)"
            let dev = st.device.map { " on \($0.name)" } ?? ""
            line += " \(st.isPlaying ? "Now playing" : "Paused"): \"\(tr.title)\"\(byArtist)\(dev)."
        } else if let np = s.nowPlaying {
            let byArtist = np.artist.isEmpty ? "" : " by \(np.artist)"
            if s.hasActiveDevice {
                line += " \(np.isPlaying ? "Now playing" : "Paused"): \"\(np.title)\"\(byArtist)."
            } else {
                line += " Last played: \"\(np.title)\"\(byArtist) — no active Spotify device right now."
            }
        }
        let query = model.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            line += " He is searching his music for \"\(query)\"."
        }
        line += " \(s.playlists.count) playlists and \(s.saved.count) saved tracks on the shelf."
            + " He can open a playlist to browse it, search, tap the now-playing bar for the"
            + " full player, or just ask you to play, queue, or find music (spotify tools)."
        return line
    }

    /// Re-assert the page focus only while no child (playlist push / player
    /// sheet) is on screen — their claims must not be stomped by a poll.
    private func maybeSetPageFocus() {
        guard openPlaylist == nil, !showPlayer else { return }
        convo.setFocus(pageFocus())
    }

    /// Restore the page focus after a child closes — but only if that child
    /// still owns it (another section may have claimed focus meanwhile).
    private func restorePageFocus() {
        let current = convo.currentFocus ?? ""
        if current.hasPrefix(MusicFocus.playlistPrefix)
            || current.hasPrefix(MusicFocus.playerPrefix) {
            convo.setFocus(pageFocus())
        }
    }

    // MARK: content

    private var searchActive: Bool {
        !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasNowPlayingBar: Bool {
        model.playerState?.track != nil || model.snapshot.nowPlaying != nil
    }

    /// The standalone recovery card earns its place when there's no bar to
    /// carry the Open-Spotify affordance — or while the auto-start watch runs
    /// (its "it'll start by itself" promise deserves the prominent card).
    private var showsRecoveryCard: Bool {
        model.needsDevice && (!hasNowPlayingBar || model.retryWatchActive)
    }

    @ViewBuilder
    private var content: some View {
        if model.loading && model.isEmpty {
            loadingState
        } else if !model.errorText.isEmpty && model.isEmpty {
            errorState(model.errorText)
        } else if model.isEmpty && !searchActive {
            emptyState
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    header
                    searchField
                    if showsRecoveryCard {
                        deviceRecovery
                    }
                    nowPlayingSection
                    if searchActive {
                        searchResultsSection
                    } else {
                        voiceHint
                        if !model.snapshot.playlists.isEmpty {
                            playlistShelf
                        }
                        if !model.snapshot.saved.isEmpty {
                            savedList
                        }
                        if let note = model.snapshot.note, !note.isEmpty {
                            Text(note)
                                .font(.scarletDetail)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, 4)
                        }
                    }
                    Color.clear.frame(height: 24)
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
            }
            .overlay(alignment: .bottom) { MusicFlashToast(model: model) }
        }
    }

    // MARK: header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Music")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Spacer()
            // The provider pill IS the door to the real app — always available,
            // so Ido can hop between Spotify and this page at any moment (not
            // only when the no-device recovery card happens to be showing).
            Button {
                MusicUI.openSpotify()
            } label: {
                HStack(spacing: 5) {
                    Text(model.provider.displayName)
                        .font(.scarletCaptionEmph)
                    Image(systemName: "arrow.up.forward")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(scarletRose)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(scarletRose.opacity(0.16)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(model.provider.displayName)")
        }
    }

    // MARK: search

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("Search songs, playlists, artists\u{2026}", text: $model.searchText)
                .font(.scarletBody)
                .foregroundStyle(.white)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
            if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
        .onChange(of: model.searchText) { _, query in
            model.updateSearch(query)
        }
    }

    @ViewBuilder
    private var searchResultsSection: some View {
        if model.searching && model.searchResults == nil {
            HStack(spacing: 10) {
                ProgressView().tint(scarletRose)
                Text("Searching\u{2026}")
                    .font(.scarletBody)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 12)
        } else if !model.searchError.isEmpty {
            VStack(spacing: 10) {
                Text(model.searchError)
                    .font(.scarletBody)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try Again") { model.updateSearch(model.searchText) }
                    .buttonStyle(.bordered)
                    .tint(scarletRose)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 12)
        } else if let results = model.searchResults {
            if results.isEmpty {
                Text("Nothing found for \u{201C}\(model.searchText.trimmingCharacters(in: .whitespacesAndNewlines))\u{201D}.")
                    .font(.scarletBody)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 12)
            } else {
                if !results.tracks.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        sectionTitle("Tracks")
                        resultCard(rows: results.tracks) { tr in
                            Button { model.play(uri: tr.uri) } label: {
                                trackRow(tr)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if !results.playlists.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        sectionTitle("Playlists")
                        resultCard(rows: results.playlists) { pl in
                            Button { openPlaylist = pl } label: {
                                searchPlaylistRow(pl)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if !results.albums.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        sectionTitle("Albums")
                        resultCard(rows: results.albums) { al in
                            Button { model.play(uri: al.uri) } label: {
                                entityRow(al, round: false)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if !results.artists.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        sectionTitle("Artists")
                        resultCard(rows: results.artists) { ar in
                            Button { model.play(uri: ar.uri) } label: {
                                entityRow(ar, round: true)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    /// A card of result rows with the house divider treatment.
    private func resultCard<Row: Identifiable, Content: View>(
        rows: [Row], @ViewBuilder content: @escaping (Row) -> Content
    ) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                content(row)
                if idx < rows.count - 1 {
                    Divider().overlay(Color.white.opacity(0.06))
                        .padding(.leading, 66)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(cardBG)
        )
    }

    private func searchPlaylistRow(_ pl: MusicPlaylist) -> some View {
        HStack(spacing: 12) {
            MusicArtwork(url: pl.imageURL, size: 46, corner: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(pl.name)
                    .font(.scarletBodyEmph)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if pl.count > 0 {
                    Text(pl.count == 1 ? "1 track" : "\(pl.count) tracks")
                        .font(.scarletDetail)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func entityRow(_ entity: MusicSearchEntity, round: Bool) -> some View {
        HStack(spacing: 12) {
            MusicArtwork(url: entity.imageURL, size: 46, corner: round ? 23 : 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(entity.name)
                    .font(.scarletBodyEmph)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if !entity.subtitle.isEmpty {
                    Text(entity.subtitle)
                        .font(.scarletDetail)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if model.startingURI == entity.uri {
                ProgressView().tint(scarletRose)
            } else {
                Image(systemName: "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    // MARK: now-playing bar

    @ViewBuilder
    private var nowPlayingSection: some View {
        if let st = model.playerState, let tr = st.track, st.device != nil {
            liveNowPlayingBar(st, tr)
        } else if let st = model.playerState, let tr = st.track {
            // State loaded but no device — the freshest honest "ghost".
            nowPlayingBar(
                MusicNowPlaying(title: tr.title, artist: tr.artist,
                                imageURL: tr.imageURL, isPlaying: false),
                live: false)
        } else if let np = model.snapshot.nowPlaying {
            // Legacy fallback until the first `music_state` poll lands.
            nowPlayingBar(np, live: model.snapshot.hasActiveDevice)
        }
    }

    /// The upgraded bar: art, title/artist, a thin live progress line, and
    /// play/pause — honest to `music_state`. Tapping the bar opens the full
    /// player; the button keeps its own tap.
    private func liveNowPlayingBar(_ st: MusicPlayerState, _ tr: MusicPlayerTrack) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                MusicArtwork(url: tr.imageURL, size: 58, corner: 10)
                VStack(alignment: .leading, spacing: 3) {
                    Text(st.isPlaying ? "NOW PLAYING" : "PAUSED")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(scarletRose)
                    Text(tr.title)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if !tr.artist.isEmpty {
                        Text(tr.artist)
                            .font(.scarletDetail)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Button {
                    model.togglePlayPause()
                } label: {
                    Image(systemName: st.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 42))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(st.isPlaying ? "Pause" : "Play")
            }
            if st.durationMs > 0 {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let progress = model.displayedProgressMs(at: context.date) ?? 0
                    let fraction = min(max(Double(progress) / Double(st.durationMs), 0), 1)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.15))
                            Capsule().fill(scarletRose)
                                .frame(width: max(geo.size.width * fraction, 3))
                        }
                    }
                    .frame(height: 3)
                }
                .frame(height: 3)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [scarletRose.opacity(0.28), cardBG],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture { showPlayer = true }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Open full player")
    }

    /// The pre-state bar (and the honest ghost). With no active Connect device,
    /// `np` is a stale "ghost" from a past session — not live audio. Be honest:
    /// label it "LAST PLAYED", show a play (▶) affordance (never a pause
    /// implying live sound), and route the tap to Open Spotify since there's
    /// nothing to actually resume.
    private func nowPlayingBar(_ np: MusicNowPlaying, live: Bool) -> some View {
        HStack(spacing: 14) {
            MusicArtwork(url: np.imageURL, size: 58, corner: 10)
            VStack(alignment: .leading, spacing: 3) {
                Text(live ? "NOW PLAYING" : "LAST PLAYED")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(scarletRose)
                Text(np.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if !np.artist.isEmpty {
                    Text(np.artist)
                        .font(.scarletDetail)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button {
                if live {
                    model.togglePlayPause()
                } else {
                    MusicUI.openSpotify()
                }
            } label: {
                Image(systemName: (live && np.isPlaying) ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(live ? (np.isPlaying ? "Pause" : "Play") : "Open \(model.provider.displayName)")
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [scarletRose.opacity(0.28), cardBG],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
        )
    }

    // MARK: no-active-device recovery (one tap back into playback)

    /// Spotify Connect can only start playback on an already-open Spotify app.
    /// When there's no active device, this calm inline card explains it in one
    /// line and hands Ido a single "Open Spotify" tap — after which the app
    /// registers as a device and (while the server's retry window is live) his
    /// pick starts BY ITSELF. It clears itself the moment a play succeeds
    /// (`model.needsDevice`), so it never dead-ends.
    private var deviceRecovery: some View {
        let accent = ScarletTheme.accent(for: .music)
        let retrying = model.retryWatchActive
        return HStack(spacing: 12) {
            Image(systemName: "hifispeaker.2.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(retrying
                     ? "Open \(model.provider.displayName) — it\u{2019}ll start by itself"
                     : "No active \(model.provider.displayName) device")
                    .font(.scarletBodyEmph)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text(retrying
                     ? "Your pick is queued — it plays the moment \(model.provider.displayName) wakes up."
                     : "Open \(model.provider.displayName) once so Scarlet can play to it.")
                    .font(.scarletDetail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button {
                MusicUI.openSpotify()
            } label: {
                Text("Open \(model.provider.displayName)")
                    .font(.scarletDetailEmph)
                    .foregroundStyle(ScarletTheme.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(accent))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(model.provider.displayName)")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(cardBG)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(accent.opacity(0.45), lineWidth: 1)
                )
        )
    }

    // MARK: voice hint

    private var voiceHint: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(scarletRose)
            Text("Or just say \u{201C}play \u{2026}\u{201D} to Scarlet \u{2014} she\u{2019}ll start it here.")
                .font(.scarletBody)
                .foregroundStyle(.white.opacity(0.9))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }

    // MARK: playlist shelf (horizontal artwork cards → push to browse)

    private var playlistShelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Your Playlists")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(model.snapshot.playlists) { pl in
                        playlistCard(pl)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.bottom, 4)
            }
        }
    }

    /// A tile now OPENS the playlist (browse-first, like a real music app);
    /// Play/Shuffle live inside the detail screen.
    private func playlistCard(_ pl: MusicPlaylist) -> some View {
        Button {
            openPlaylist = pl
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                MusicArtwork(url: pl.imageURL, size: 148, corner: 14)
                Text(pl.name)
                    .font(.scarletBodyEmph)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(pl.count == 1 ? "1 track" : "\(pl.count) tracks")
                    .font(.scarletCaption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 148, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open playlist \(pl.name)")
    }

    // MARK: saved tracks list

    private var savedList: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Saved Tracks")
            VStack(spacing: 0) {
                ForEach(Array(model.snapshot.saved.enumerated()), id: \.element.id) { idx, tr in
                    Button {
                        model.play(uri: tr.uri)
                    } label: {
                        trackRow(tr)
                    }
                    .buttonStyle(.plain)
                    if idx < model.snapshot.saved.count - 1 {
                        Divider().overlay(Color.white.opacity(0.06))
                            .padding(.leading, 66)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(cardBG)
            )
        }
    }

    private func trackRow(_ tr: MusicTrack) -> some View {
        HStack(spacing: 12) {
            MusicArtwork(url: tr.imageURL, size: 46, corner: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(tr.title)
                    .font(.scarletBodyEmph)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if !tr.artist.isEmpty {
                    Text(tr.artist)
                        .font(.scarletDetail)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if model.startingURI == tr.uri {
                ProgressView().tint(scarletRose)
            } else {
                Image(systemName: "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    // MARK: shared pieces

    private func sectionTitle(_ text: String) -> some View {
        // Shared in-screen grouping idiom: accent bar + section-size label.
        ScarletSectionHeader(text, accent: scarletRose)
    }

    // MARK: whole-page states

    private var loadingState: some View {
        VStack(spacing: 14) {
            ProgressView().tint(scarletRose)
            Text("Loading your music\u{2026}")
                .font(.scarletBody)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ text: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.scarletBody)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try Again") { Task { await model.load() } }
                .buttonStyle(.borderedProminent)
                .tint(scarletRose)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.list")
                .font(.system(size: 46))
                .foregroundStyle(scarletRose)
            Text(model.snapshot.note ?? "Connect \(model.provider.displayName) to see your music.")
                .font(.headline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text("Once it\u{2019}s connected, your playlists and saved tracks show up here \u{2014} and you can just say \u{201C}play \u{2026}\u{201D} to Scarlet.")
                .font(.scarletBody)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Refresh") { Task { await model.load() } }
                .buttonStyle(.bordered)
                .tint(scarletRose)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
