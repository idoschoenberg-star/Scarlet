import SwiftUI
import UIKit

/// Native Music — a mirror of the real Spotify app's structure inside the
/// Music tab. Four top-level segments (the house capsule switcher):
///
///   For You   — Spotify Home: horizontal rails (Recently played, Your top
///               tracks, Fresh from your artists, New releases, Your top
///               artists as round avatars). Every card taps to play.
///   Library   — Your Library: filter chips (Playlists / Liked / Podcasts),
///               playlist rows → pushed playlist detail with a green circular
///               Play, Liked with a Play-all.
///   Podcasts  — show subscriptions → pushed show detail with newest-first
///               episodes (progress bar when Spotify grants resume points).
///   Search    — the existing debounced search across tracks / artists /
///               albums / playlists.
///
/// Playback always happens on a real Spotify device (Connect) — the server
/// verifies sound is actually coming out before claiming success, and its
/// `note`/`error` strings are shown verbatim rather than an invented "done".
/// A `need_device` answer raises the device picker (op=music_devices) and the
/// chosen device retries the same play — never a dead end.
///
/// Catalyst rules respected: ONE enum-driven `.sheet(item:)` on the root view
/// (track detail + device picker); playlist/show detail are NavigationStack
/// pushes with a drawn back button; only the root reads `convo` (re-injected
/// at both construction sites: ScarletTalkApp and SplitShell).

// MARK: - Wire types

/// One playable track, as the music ops return it (library `saved` /
/// `recentlyPlayed`, playlist tracks, search tracks, For-You top tracks).
/// `durationMs` is 0 when the source op doesn't carry it (library `saved`).
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

/// A search artist or a For-You top artist — tap plays the artist context.
struct MusicArtistItem: Identifiable, Equatable {
    let id: String
    let uri: String
    let name: String
    let image: String?
}

/// One album/single from `music_foryou.freshFromArtists` / `newReleases`.
struct MusicReleaseItem: Identifiable, Equatable {
    let id: String
    let uri: String
    let name: String
    let artist: String
    let image: String?
    let releaseDate: String
}

/// One podcast subscription from `music_podcasts.shows`.
struct MusicShowItem: Identifiable, Equatable {
    let id: String
    let uri: String
    let name: String
    let publisher: String
    let image: String?
    let totalEpisodes: Int
    let blurb: String
}

/// One episode (saved rail or a show's list). `progressMs` is nil when the
/// resume scope isn't granted yet — the progress bar renders only when the
/// value is actually present (honest optionality).
struct MusicEpisodeItem: Identifiable, Equatable {
    let id: String
    let uri: String
    let title: String
    let show: String
    let image: String?
    let durationMs: Int
    let releaseDate: String
    let progressMs: Int?
    let fullyPlayed: Bool
    let blurb: String
}

/// One Spotify Connect device from `op=music_devices`.
struct MusicDeviceItem: Identifiable, Equatable {
    let id: String
    let name: String
    let type: String
    let isActive: Bool
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
    /// The remote device's current volume (0-100); nil when the device
    /// doesn't report one. Drives the in-app volume slider.
    var volumePercent: Int?
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

/// `op=music_show&id=` result: refreshed show header + its episodes.
enum MusicShowFetch {
    case loaded(MusicShowItem?, [MusicEpisodeItem])
    case failed(String)
}

enum MusicDevicesFetch {
    case loaded([MusicDeviceItem])
    case failed(String)
}

/// The play that hit `need_device` — carried into the device picker so the
/// chosen device retries the exact same uri.
struct MusicPendingPlay: Identifiable, Equatable {
    let uri: String
    let label: String
    var id: String { uri }
}

/// The ONE sheet this tab ever presents (Catalyst allows a single `.sheet`
/// per view — enum-driven, like LibraryView's LibrarySheet). Lives on the
/// model so pushed screens (playlist/show detail) can raise it too.
enum MusicSheet: Identifiable {
    case track(MusicTrackItem)
    case devices(MusicPendingPlay)

    var id: String {
        switch self {
        case .track(let t): return "track-\(t.id)"
        case .devices(let p): return "devices-\(p.id)"
        }
    }
}

// MARK: - Palette

/// Spotify's own dark design language inside this tab: near-black surfaces
/// and #1DB954 green for play buttons / active states. File-scoped so nothing
/// leaks into sibling views.
private enum MusicStyle {
    /// Spotify green #1DB954.
    static let green = Color(red: 29.0 / 255.0, green: 185.0 / 255.0, blue: 84.0 / 255.0)
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

/// "54 min" from milliseconds — the podcast-episode form Spotify uses.
private func musicMinutes(_ ms: Int) -> String {
    let m = Int((Double(max(0, ms)) / 60_000.0).rounded())
    return m > 0 ? "\(m) min" : musicDuration(ms)
}

/// "2026-08-01" → "Aug 1, 2026"; anything unparseable passes through.
private enum MusicReleaseDate {
    static let wire: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    static let display: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f
    }()

    static func label(_ raw: String) -> String {
        guard let d = wire.date(from: raw) else { return raw }
        return display.string(from: d)
    }
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

    // For You (op=music_foryou)
    @Published var topTracks: [MusicTrackItem] = []
    @Published var topArtists: [MusicArtistItem] = []
    @Published var freshReleases: [MusicReleaseItem] = []
    @Published var newReleases: [MusicReleaseItem] = []
    @Published var forYouNote = ""
    @Published var forYouError = ""
    @Published var loadingForYou = false

    // Podcasts (op=music_podcasts)
    @Published var shows: [MusicShowItem] = []
    @Published var savedEpisodes: [MusicEpisodeItem] = []
    @Published var podcastsNote = ""
    @Published var podcastsError = ""
    @Published var loadingPodcasts = false

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

    /// The ONE sheet (track detail / device picker). On the model so the
    /// pushed playlist and show screens can raise it (Catalyst rule: a single
    /// `.sheet` per view, owned by the root MusicView).
    @Published var activeSheet: MusicSheet?

    private var pollTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var libraryGeneration = 0
    private var forYouGeneration = 0
    private var podcastsGeneration = 0
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
            let obj = try await Self.getWithRetry("op=music_library")
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

    // MARK: For You

    func loadForYou() async {
        guard TokenStore.token != nil else { return }
        if topTracks.isEmpty && topArtists.isEmpty && freshReleases.isEmpty
            && newReleases.isEmpty { loadingForYou = true }
        forYouError = ""
        forYouGeneration += 1
        let generation = forYouGeneration
        defer { if generation == forYouGeneration { loadingForYou = false } }
        do {
            let obj = try await Self.getWithRetry("op=music_foryou")
            guard generation == forYouGeneration else { return }
            if let err = obj["error"] as? String {
                forYouError = err
                return
            }
            let tracks = Self.dedup(((obj["topTracks"] as? [[String: Any]]) ?? [])
                .compactMap { Self.track(from: $0) })
            let artists = Self.dedup(((obj["topArtists"] as? [[String: Any]]) ?? [])
                .compactMap { Self.artist(from: $0) })
            let fresh = Self.dedup(((obj["freshFromArtists"] as? [[String: Any]]) ?? [])
                .compactMap { Self.release(from: $0) })
            let releases = Self.dedup(((obj["newReleases"] as? [[String: Any]]) ?? [])
                .compactMap { Self.release(from: $0) })
            withAnimation(.snappy) {
                topTracks = tracks
                topArtists = artists
                freshReleases = fresh
                newReleases = releases
            }
            forYouNote = (obj["note"] as? String) ?? ""
        } catch {
            guard generation == forYouGeneration else { return }
            forYouError = "Couldn't load your Spotify picks — check your connection."
        }
    }

    // MARK: Podcasts

    func loadPodcasts() async {
        guard TokenStore.token != nil else { return }
        if shows.isEmpty && savedEpisodes.isEmpty { loadingPodcasts = true }
        podcastsError = ""
        podcastsGeneration += 1
        let generation = podcastsGeneration
        defer { if generation == podcastsGeneration { loadingPodcasts = false } }
        do {
            let obj = try await Self.getWithRetry("op=music_podcasts")
            guard generation == podcastsGeneration else { return }
            if let err = obj["error"] as? String {
                podcastsError = err
                return
            }
            let newShows = Self.dedup(((obj["shows"] as? [[String: Any]]) ?? [])
                .compactMap { Self.show(from: $0) })
            let newEpisodes = Self.dedup(((obj["savedEpisodes"] as? [[String: Any]]) ?? [])
                .compactMap { Self.episode(from: $0) })
            withAnimation(.snappy) {
                shows = newShows
                savedEpisodes = newEpisodes
            }
            podcastsNote = (obj["note"] as? String) ?? ""
        } catch {
            guard generation == podcastsGeneration else { return }
            podcastsError = "Couldn't load your podcasts — check your connection."
        }
    }

    /// One show's episodes (pushed show-detail screen). Newest first.
    func fetchShow(id: String) async -> MusicShowFetch {
        do {
            let encoded = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
            let obj = try await Self.getWithRetry("op=music_show&id=\(encoded)")
            if let err = obj["error"] as? String { return .failed(err) }
            let header = (obj["show"] as? [String: Any]).flatMap { Self.show(from: $0) }
            let episodes = Self.dedup(((obj["episodes"] as? [[String: Any]]) ?? [])
                .compactMap { Self.episode(from: $0) })
                .sorted { $0.releaseDate > $1.releaseDate }
            return .loaded(header, episodes)
        } catch {
            return .failed("Couldn't load this show — check your connection.")
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
                    volumePercent: (obj["device"] as? [String: Any])?["volume_percent"] as? Int,
                    queue: queue
                )
            }
            player = next
        } catch {
            // Transient network wobble mid-poll: keep the last snapshot.
        }
    }

    // MARK: Playback

    /// Play any Spotify uri (track/episode = one-off item; playlist / album /
    /// artist / show = context). The toast is the SERVER's verdict — including
    /// its retry notes. A `need_device` answer raises the device picker with
    /// this exact play pending, so choosing a device finishes the job.
    func play(uri: String, label: String, device: String? = nil) {
        Task {
            do {
                var body: [String: Any] = ["uri": uri]
                if let device, !device.isEmpty { body["device"] = device }
                let data = try await Self.request("op=music_play", method: "POST",
                                                  body: body)
                let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                let note = obj["note"] as? String
                if (obj["ok"] as? Bool) == true {
                    let onDevice = (obj["on_device"] as? String)
                        ?? (obj["device"] as? String) ?? ""
                    var line = onDevice.isEmpty
                        ? "Playing \(label)"
                        : "Playing \(label) on \(onDevice)"
                    if let note, !note.isEmpty { line += " — \(note)" }
                    showToast(line)
                } else if let err = obj["error"] as? String {
                    if (obj["need_device"] as? Bool) == true {
                        // No active Spotify device — the picker takes over and
                        // retries this same play on whatever Ido chooses.
                        showToast(err)
                        activeSheet = .devices(MusicPendingPlay(uri: uri, label: label))
                    } else {
                        var line = err
                        if let note, !note.isEmpty { line += " — \(note)" }
                        showToast(line)
                    }
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

    /// The volume the slider is showing mid-drag; nil = trust the poll.
    @Published var volumeDraft: Double?
    private var volumeSendTask: Task<Void, Never>?

    /// Remote-speaker volume via music_control {action:'volume'} — the same
    /// Spotify Connect call Spotify's own slider makes, so the app and the
    /// Spotify app stay in sync. Sends are debounced so a drag lands as one
    /// or two API calls; the state poll re-syncs truth afterwards.
    func setVolume(_ percent: Double) {
        volumeDraft = percent
        volumeSendTask?.cancel()
        volumeSendTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            do {
                let data = try await Self.request("op=music_control", method: "POST",
                                                  body: ["action": "volume", "volume": Int(percent)])
                let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                if let err = obj["error"] as? String { showToast(err) }
            } catch {
                showToast("This speaker doesn't allow remote volume.")
            }
            try? await Task.sleep(nanoseconds: 900_000_000)
            if !Task.isCancelled {
                volumeDraft = nil
                await refreshState()
            }
        }
    }

    /// Spotify Connect devices for the picker (op=music_devices).
    func fetchDevices() async -> MusicDevicesFetch {
        do {
            let obj = try await Self.getWithRetry("op=music_devices")
            if let err = obj["error"] as? String { return .failed(err) }
            let raw = (obj["devices"] as? [[String: Any]]) ?? []
            var seen = Set<String>()
            let devices: [MusicDeviceItem] = raw.compactMap { d in
                let name = (d["name"] as? String) ?? ""
                guard !name.isEmpty else { return nil }
                let id = (d["id"] as? String) ?? name
                guard seen.insert(id).inserted else { return nil }
                return MusicDeviceItem(
                    id: id,
                    name: name,
                    type: (d["type"] as? String) ?? "",
                    isActive: (d["is_active"] as? Bool) ?? (d["isActive"] as? Bool) ?? false
                )
            }
            return .loaded(devices)
        } catch {
            return .failed("Couldn't list your Spotify devices — check your connection.")
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

    private static func release(from m: [String: Any]) -> MusicReleaseItem? {
        guard let id = m["id"] as? String, !id.isEmpty else { return nil }
        return MusicReleaseItem(
            id: id,
            uri: (m["uri"] as? String) ?? "spotify:album:\(id)",
            name: (m["name"] as? String) ?? "Release",
            artist: (m["artist"] as? String) ?? "",
            image: m["image"] as? String,
            releaseDate: (m["releaseDate"] as? String) ?? ""
        )
    }

    private static func show(from m: [String: Any]) -> MusicShowItem? {
        guard let id = m["id"] as? String, !id.isEmpty else { return nil }
        return MusicShowItem(
            id: id,
            uri: (m["uri"] as? String) ?? "spotify:show:\(id)",
            name: (m["name"] as? String) ?? "Show",
            publisher: (m["publisher"] as? String) ?? "",
            image: m["image"] as? String,
            totalEpisodes: (m["totalEpisodes"] as? Int) ?? 0,
            blurb: (m["description"] as? String) ?? ""
        )
    }

    private static func episode(from m: [String: Any]) -> MusicEpisodeItem? {
        guard let id = m["id"] as? String, !id.isEmpty else { return nil }
        return MusicEpisodeItem(
            id: id,
            uri: (m["uri"] as? String) ?? "spotify:episode:\(id)",
            title: (m["title"] as? String) ?? "Episode",
            show: (m["show"] as? String) ?? "",
            image: m["image"] as? String,
            durationMs: (m["durationMs"] as? Int) ?? (m["duration_ms"] as? Int) ?? 0,
            releaseDate: (m["releaseDate"] as? String) ?? "",
            // Present only when Spotify granted the resume scope — the row's
            // progress bar renders only off a real value.
            progressMs: (m["progressMs"] as? Int) ?? (m["progress_ms"] as? Int),
            fullyPlayed: (m["fullyPlayed"] as? Bool) ?? false,
            blurb: (m["description"] as? String) ?? ""
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

    /// GET with the house two-attempt retry (ChatsView pattern): flaky
    /// hotel/roaming links drop single requests while the server is perfectly
    /// healthy — one quiet pause, one more try, THEN the honest error.
    private static func getWithRetry(_ query: String) async throws -> [String: Any] {
        var lastError: Error = URLError(.unknown)
        for attempt in 1...2 {
            do {
                let data = try await request(query, method: "GET")
                return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            } catch {
                lastError = error
                if attempt == 1 {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                }
            }
        }
        throw lastError
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

/// Round artist portrait (Spotify's artist form), honest mic placeholder.
private struct MusicArtistPortrait: View {
    let url: String?
    var size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(MusicStyle.surface)
            Image(systemName: "music.mic")
                .font(.system(size: size * 0.34))
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
        .clipShape(Circle())
    }
}

/// The Spotify-green circular play button (black glyph on green, the real
/// app's exact affordance). One component, three sizes.
private struct MusicPlayCircle: View {
    var size: CGFloat = 52
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(MusicStyle.green)
                Image(systemName: "play.fill")
                    .font(.system(size: size * 0.38, weight: .bold))
                    .foregroundStyle(.black)
                    .offset(x: size * 0.03)
            }
            .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Play")
    }
}

// MARK: - Segments (the Spotify information architecture)

/// Top-level segments, mirroring the real app: Home ("For You"), Your
/// Library, Podcasts (subscriptions), Search.
private enum MusicSegment: String, CaseIterable, Identifiable {
    case forYou
    case library
    case podcasts
    case search

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .forYou: return "For You"
        case .library: return "Library"
        case .podcasts: return "Podcasts"
        case .search: return "Search"
        }
    }

    var icon: String {
        switch self {
        case .forYou: return "house.fill"
        case .library: return "books.vertical.fill"
        case .podcasts: return "dot.radiowaves.left.and.right"
        case .search: return "magnifyingglass"
        }
    }
}

/// Library filter chips (Spotify's Your Library filters). "Podcasts" is a
/// jump to the Podcasts segment, so it never renders as selected here.
private enum MusicLibraryFilter: String, CaseIterable, Identifiable {
    case playlists
    case liked
    case podcasts

    var id: String { rawValue }

    var label: String {
        switch self {
        case .playlists: return "Playlists"
        case .liked: return "Liked"
        case .podcasts: return "Podcasts"
        }
    }
}

/// The segment-level ambient-focus line (house pattern: every screen reports
/// what Ido is looking at).
private func musicBrowsingFocus(_ segment: MusicSegment) -> String {
    switch segment {
    case .forYou:
        return "[FOCUS] Ido is browsing Music — For You (his Spotify home: recently played, top tracks, fresh releases, top artists)."
    case .library:
        return "[FOCUS] Ido is browsing Music — his Spotify Library (playlists, liked songs)."
    case .podcasts:
        return "[FOCUS] Ido is browsing Music — his podcast subscriptions on Spotify."
    case .search:
        return "[FOCUS] Ido is searching Spotify inside the Music tab."
    }
}

// MARK: - Root view

struct MusicView: View {
    @StateObject private var model = MusicModel()
    @EnvironmentObject private var convo: Conversation
    @State private var segment: MusicSegment = .forYou
    @State private var libraryFilter: MusicLibraryFilter = .playlists

    var body: some View {
        NavigationStack {
            ZStack {
                MusicBackdrop()
                VStack(spacing: 0) {
                    headerBar
                    segmentSwitcher
                    content
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            // The dock (toast + now-playing bar) is part of the HOME screen's
            // layout; pushed playlist/show screens mount their own, same
            // anatomy (exactly where the previous MusicView kept it).
            .safeAreaInset(edge: .bottom) { MusicBottomDock(model: model) }
        }
        // ONE sheet on this view (Catalyst rule) — the full track detail or
        // the device picker, raised from anywhere via model.activeSheet.
        .sheet(item: $model.activeSheet) { sheet in
            switch sheet {
            case .track(let track):
                MusicTrackDetailView(seed: track, model: model)
            case .devices(let pending):
                MusicDevicePickerView(pending: pending, model: model)
            }
        }
        // Poll the live player only while the Music screen is actually up:
        // these fire on tab switch in/out; the poll task dies on disappear.
        .onAppear {
            model.startPolling()
            convo.setFocus(musicBrowsingFocus(segment))
        }
        .onDisappear { model.stopPolling() }
        .onChange(of: segment) { _, newSegment in
            convo.setFocus(musicBrowsingFocus(newSegment))
        }
        // .task re-runs on each tab selection → auto-refresh, like the inbox.
        .task { await loadAll() }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.willEnterForegroundNotification)) { _ in
            Task { await loadAll() }
        }
        .preferredColorScheme(.dark)
    }

    /// The three GET ops load in parallel; each section fails independently
    /// (its own error string) so one bad answer never blanks the others.
    private func loadAll() async {
        async let library: Void = model.loadLibrary()
        async let forYou: Void = model.loadForYou()
        async let podcasts: Void = model.loadPodcasts()
        _ = await (library, forYou, podcasts)
    }

    // MARK: header (house anatomy: big heavy title + refresh, like Chats)

    private var headerBar: some View {
        HStack(spacing: 12) {
            Text("Music")
                .font(.system(size: 34, weight: .heavy))
                .foregroundStyle(.white)
            Spacer()
            Button {
                Task { await loadAll() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white)
            }
            .disabled(model.loadingLibrary || model.loadingForYou || model.loadingPodcasts)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    // MARK: segment switcher (the house capsule idiom, Spotify-green accent)

    private var segmentSwitcher: some View {
        HStack(spacing: 4) {
            ForEach(MusicSegment.allCases) { s in
                segmentButton(s)
            }
        }
        .padding(4)
        .background(Capsule().fill(.white.opacity(0.06)))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func segmentButton(_ s: MusicSegment) -> some View {
        Button {
            withAnimation(.snappy) { segment = s }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: s.icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(s.displayName)
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(segment == s ? MusicStyle.green : Color.white.opacity(0.55))
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
                Capsule().fill(segment == s
                    ? MusicStyle.green.opacity(0.18) : Color.clear)
            )
            .overlay(
                Capsule().stroke(segment == s
                    ? MusicStyle.green.opacity(0.45) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: content

    @ViewBuilder
    private var content: some View {
        switch segment {
        case .forYou: forYouScreen
        case .library: libraryScreen
        case .podcasts: podcastsScreen
        case .search: searchScreen
        }
    }

    // MARK: For You (Spotify Home — horizontal rails)

    private var forYouEmpty: Bool {
        model.recent.isEmpty && model.topTracks.isEmpty && model.topArtists.isEmpty
            && model.freshReleases.isEmpty && model.newReleases.isEmpty
    }

    @ViewBuilder
    private var forYouScreen: some View {
        if (model.loadingForYou || model.loadingLibrary) && forYouEmpty {
            VStack(spacing: 10) {
                ProgressView()
                Text("Loading your Spotify picks…")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if forYouEmpty {
            VStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.title2).foregroundStyle(.secondary)
                Text(emptyForYouLine)
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Button("Try again") { Task { await loadAll() } }
                    .buttonStyle(.bordered)
                    .tint(MusicStyle.green)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !model.forYouError.isEmpty {
                        noteLine(model.forYouError)
                    } else if !model.forYouNote.isEmpty {
                        noteLine(model.forYouNote)
                    }
                    if !model.recent.isEmpty {
                        railHeader("Recently played")
                        trackRail(model.recent)
                    }
                    if !model.topTracks.isEmpty {
                        railHeader("Your top tracks")
                        trackRail(model.topTracks)
                    }
                    if !model.freshReleases.isEmpty {
                        railHeader("Fresh from your artists")
                        releaseRail(model.freshReleases)
                    }
                    if !model.newReleases.isEmpty {
                        railHeader("New releases")
                        releaseRail(model.newReleases)
                    }
                    if !model.topArtists.isEmpty {
                        railHeader("Your top artists")
                        artistRail(model.topArtists)
                    }
                    Color.clear.frame(height: 12)
                }
            }
            .refreshable {
                await loadAll()
                await model.refreshState()
            }
        }
    }

    private var emptyForYouLine: String {
        if !model.forYouError.isEmpty { return model.forYouError }
        if !model.forYouNote.isEmpty { return model.forYouNote }
        if !model.errorText.isEmpty { return model.errorText }
        return "No Spotify suggestions yet — play some music and this fills in."
    }

    // MARK: Library (Spotify Your Library — chips + rows)

    private var libraryScreen: some View {
        VStack(spacing: 0) {
            libraryChips
            switch libraryFilter {
            case .playlists: playlistScreen
            case .liked: likedScreen
            case .podcasts:
                // Never reached — the chip jumps straight to the Podcasts
                // segment (see libraryChips) — but never a blank screen.
                podcastsScreen
            }
        }
    }

    /// Spotify's filter chips: small capsules, the active one solid green
    /// with black text (the real app's exact treatment).
    private var libraryChips: some View {
        HStack(spacing: 8) {
            ForEach(MusicLibraryFilter.allCases) { f in
                Button {
                    if f == .podcasts {
                        withAnimation(.snappy) { segment = .podcasts }
                    } else {
                        withAnimation(.snappy) { libraryFilter = f }
                    }
                } label: {
                    Text(f.label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(libraryFilter == f && f != .podcasts
                            ? .black : .white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(
                            Capsule().fill(libraryFilter == f && f != .podcasts
                                ? MusicStyle.green : MusicStyle.surface)
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var playlistScreen: some View {
        if model.loadingLibrary && model.playlists.isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                Text("Loading your playlists…")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.playlists.isEmpty && !model.errorText.isEmpty {
            libraryErrorView(model.errorText)
        } else if model.playlists.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "music.note.list")
                    .font(.title2).foregroundStyle(.secondary)
                Text(model.libraryNote.isEmpty
                     ? "No playlists yet, or Spotify isn't connected."
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
                    ForEach(model.playlists) { p in
                        NavigationLink {
                            MusicPlaylistDetailView(playlist: p, model: model)
                        } label: {
                            MusicPlaylistRow(playlist: p)
                        }
                        .buttonStyle(.plain)
                    }
                    Color.clear.frame(height: 12)
                }
            }
            .refreshable { await model.loadLibrary() }
        }
    }

    @ViewBuilder
    private var likedScreen: some View {
        if model.loadingLibrary && model.saved.isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                Text("Loading Liked Songs…")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.saved.isEmpty && !model.errorText.isEmpty {
            libraryErrorView(model.errorText)
        } else if model.saved.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "heart.fill")
                    .font(.title2).foregroundStyle(.secondary)
                Text("No liked songs yet.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    likedHeader
                    ForEach(model.saved) { t in
                        MusicTrackRow(track: t, model: model)
                    }
                    Color.clear.frame(height: 12)
                }
            }
            .refreshable { await model.loadLibrary() }
        }
    }

    /// The Liked Songs header: Spotify's purple-gradient heart tile, count,
    /// and a green Play-all (starts from the first liked track — liked songs
    /// have no public context uri, so the first track leads the session).
    private var likedHeader: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(LinearGradient(
                        colors: [Color(red: 0.27, green: 0.20, blue: 0.90),
                                 Color(red: 0.68, green: 0.78, blue: 0.95)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "heart.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.white)
            }
            .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 3) {
                Text("Liked Songs")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                Text("Playlist • \(model.saved.count) songs")
                    .font(.system(size: 13))
                    .foregroundStyle(MusicStyle.secondary)
            }
            Spacer(minLength: 8)
            MusicPlayCircle(size: 48) {
                if let first = model.saved.first {
                    model.play(uri: first.uri, label: "Liked Songs")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private func libraryErrorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.title2).foregroundStyle(.secondary)
            Text(message)
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try again") { Task { await model.loadLibrary() } }
                .buttonStyle(.bordered)
                .tint(MusicStyle.green)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Podcasts (subscriptions + saved-episodes rail)

    @ViewBuilder
    private var podcastsScreen: some View {
        if model.loadingPodcasts && model.shows.isEmpty && model.savedEpisodes.isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                Text("Loading your podcasts…")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.shows.isEmpty && model.savedEpisodes.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.title2).foregroundStyle(.secondary)
                Text(emptyPodcastsLine)
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                if !model.podcastsError.isEmpty {
                    Button("Try again") { Task { await model.loadPodcasts() } }
                        .buttonStyle(.bordered)
                        .tint(MusicStyle.green)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !model.podcastsError.isEmpty {
                        noteLine(model.podcastsError)
                    } else if !model.podcastsNote.isEmpty {
                        noteLine(model.podcastsNote)
                    }
                    if !model.savedEpisodes.isEmpty {
                        railHeader("Saved episodes")
                        episodeRail(model.savedEpisodes)
                    }
                    if !model.shows.isEmpty {
                        railHeader("Your shows")
                        ForEach(model.shows) { s in
                            NavigationLink {
                                MusicShowDetailView(show: s, model: model)
                            } label: {
                                MusicShowRow(show: s)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Color.clear.frame(height: 12)
                }
            }
            .refreshable { await model.loadPodcasts() }
        }
    }

    private var emptyPodcastsLine: String {
        if !model.podcastsError.isEmpty { return model.podcastsError }
        if !model.podcastsNote.isEmpty { return model.podcastsNote }
        return "No podcast subscriptions yet — follow a show on Spotify and it appears here."
    }

    // MARK: Search (the existing debounced search, as its own segment)

    private var searchScreen: some View {
        VStack(spacing: 0) {
            searchField
            if isSearchMode {
                searchResults
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.title2).foregroundStyle(.secondary)
                    Text("Search Spotify — songs, artists, albums, playlists.")
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// The search field itself follows the typed text's direction (Hebrew
    /// queries read RTL) — per control, never the whole screen.
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(MusicStyle.secondary)
            TextField("Search songs, artists, albums, playlists", text: $model.searchText)
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .tint(MusicStyle.green)
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
                    railHeader("Songs")
                    ForEach(model.searchTracks) { t in
                        MusicTrackRow(track: t, model: model)
                    }
                }
                if !model.searchPlaylists.isEmpty {
                    railHeader("Playlists")
                    playlistRail(model.searchPlaylists)
                }
                if !model.searchAlbums.isEmpty {
                    railHeader("Albums")
                    albumRail(model.searchAlbums)
                }
                if !model.searchArtists.isEmpty {
                    railHeader("Artists")
                    ForEach(model.searchArtists) { a in
                        MusicArtistRow(artist: a, model: model)
                    }
                }
                Color.clear.frame(height: 12)
            }
        }
    }

    // MARK: shelf pieces

    /// Spotify's bold white section header.
    private func railHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 8)
    }

    private func noteLine(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Color(red: 0.91, green: 0.69, blue: 0.31))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
    }

    private func trackRail(_ items: [MusicTrackItem]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(items) { t in
                    MusicTrackCard(track: t, model: model)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func releaseRail(_ items: [MusicReleaseItem]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(items) { r in
                    MusicReleaseCard(release: r, model: model)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func artistRail(_ items: [MusicArtistItem]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(items) { a in
                    MusicArtistCard(artist: a, model: model)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func episodeRail(_ items: [MusicEpisodeItem]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(items) { e in
                    MusicEpisodeCard(episode: e, model: model)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func playlistRail(_ items: [MusicPlaylistItem]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(items) { p in
                    NavigationLink {
                        MusicPlaylistDetailView(playlist: p, model: model)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            MusicArt(url: p.image, size: 120, corner: 6)
                            Text(p.name)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(2)
                                .multilineTextAlignment(p.name.readingAlignment)
                            Text(p.count > 0 ? "\(p.count) songs" : (p.owner ?? ""))
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
                            MusicArt(url: a.image, size: 120, corner: 6)
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

// MARK: - Backdrop

/// Near-black Spotify-style ground over the house silk — the tab keeps the
/// app's dark design underneath but reads as the real Spotify surface.
private struct MusicBackdrop: View {
    var body: some View {
        ZStack {
            ScarletBackground()
            Color.black.opacity(0.45)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Cards (For You rails)

/// Square track card: tap plays; long-press offers Play + Details.
private struct MusicTrackCard: View {
    let track: MusicTrackItem
    @ObservedObject var model: MusicModel

    var body: some View {
        Button {
            model.play(uri: track.uri, label: track.title)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                MusicArt(url: track.image, size: 120, corner: 6)
                Text(track.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(track.title.readingAlignment)
                Text(track.artist)
                    .font(.system(size: 11))
                    .foregroundStyle(MusicStyle.secondary)
                    .lineLimit(1)
            }
            .frame(width: 120, alignment: .leading)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                model.play(uri: track.uri, label: track.title)
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            Button {
                model.activeSheet = .track(track)
            } label: {
                Label("Track details", systemImage: "info.circle")
            }
        }
    }
}

/// Album/single card (Fresh from your artists / New releases): tap plays the
/// whole release as a context.
private struct MusicReleaseCard: View {
    let release: MusicReleaseItem
    @ObservedObject var model: MusicModel

    var body: some View {
        Button {
            model.play(uri: release.uri, label: release.name)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                MusicArt(url: release.image, size: 120, corner: 6)
                Text(release.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(release.name.readingAlignment)
                Text(releaseSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(MusicStyle.secondary)
                    .lineLimit(1)
            }
            .frame(width: 120, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    private var releaseSubtitle: String {
        if release.artist.isEmpty { return MusicReleaseDate.label(release.releaseDate) }
        if release.releaseDate.isEmpty { return release.artist }
        return "\(release.artist) · \(MusicReleaseDate.label(release.releaseDate))"
    }
}

/// Round artist card (Spotify's artist form): portrait + centered name;
/// tap plays the artist context.
private struct MusicArtistCard: View {
    let artist: MusicArtistItem
    @ObservedObject var model: MusicModel

    var body: some View {
        Button {
            model.play(uri: artist.uri, label: artist.name)
        } label: {
            VStack(spacing: 6) {
                MusicArtistPortrait(url: artist.image, size: 96)
                Text(artist.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(width: 104)
        }
        .buttonStyle(.plain)
    }
}

/// Saved-episode card for the Podcasts rail: tap plays the episode.
private struct MusicEpisodeCard: View {
    let episode: MusicEpisodeItem
    @ObservedObject var model: MusicModel

    var body: some View {
        Button {
            model.play(uri: episode.uri, label: episode.title)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                MusicArt(url: episode.image, size: 120, corner: 8)
                Text(episode.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(episode.title.readingAlignment)
                Text(episode.show)
                    .font(.system(size: 11))
                    .foregroundStyle(MusicStyle.secondary)
                    .lineLimit(1)
            }
            .frame(width: 120, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Rows

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
                model.activeSheet = .track(track)
            } label: {
                Label("Track details", systemImage: "info.circle")
            }
        }
    }
}

/// One playlist row (Spotify's Your Library form): square art, name,
/// "Playlist • N songs".
private struct MusicPlaylistRow: View {
    let playlist: MusicPlaylistItem

    var body: some View {
        HStack(spacing: 12) {
            MusicArt(url: playlist.image, size: 56, corner: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .multilineTextAlignment(playlist.name.readingAlignment)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(MusicStyle.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.35))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        if playlist.count > 0 { return "Playlist • \(playlist.count) songs" }
        if let owner = playlist.owner, !owner.isEmpty { return "Playlist • \(owner)" }
        return "Playlist"
    }
}

/// One subscription row: show artwork, name, publisher, N episodes.
private struct MusicShowRow: View {
    let show: MusicShowItem

    var body: some View {
        HStack(spacing: 12) {
            MusicArt(url: show.image, size: 56, corner: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(show.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .multilineTextAlignment(show.name.readingAlignment)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(MusicStyle.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.35))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        var parts: [String] = []
        if !show.publisher.isEmpty { parts.append(show.publisher) }
        if show.totalEpisodes > 0 { parts.append("\(show.totalEpisodes) episodes") }
        return parts.isEmpty ? "Podcast" : parts.joined(separator: " • ")
    }
}

/// One episode row (show detail / anywhere episodes list vertically):
/// title, date • duration, description snippet, a small green play circle,
/// a thin progress bar when Spotify reports a resume point, and a "Played"
/// state when the episode is finished.
private struct MusicEpisodeRow: View {
    let episode: MusicEpisodeItem
    @ObservedObject var model: MusicModel

    var body: some View {
        Button {
            model.play(uri: episode.uri, label: episode.title)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                MusicArt(url: episode.image, size: 56, corner: 8)
                VStack(alignment: .leading, spacing: 3) {
                    Text(episode.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(episode.title.readingAlignment)
                    if !episode.blurb.isEmpty {
                        Text(episode.blurb)
                            .font(.system(size: 12))
                            .foregroundStyle(MusicStyle.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(episode.blurb.readingAlignment)
                    }
                    metaLine
                    // Resume-point bar: rendered ONLY when Spotify actually
                    // sent progressMs (scope may not be granted yet).
                    if let progress = episode.progressMs,
                       episode.durationMs > 0, !episode.fullyPlayed {
                        ProgressView(value: min(1, max(0, Double(progress) / Double(episode.durationMs))))
                            .progressViewStyle(.linear)
                            .tint(MusicStyle.green)
                            .scaleEffect(x: 1, y: 0.5, anchor: .center)
                            .frame(maxWidth: 180)
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 8)
                MusicPlayCircle(size: 34) {
                    model.play(uri: episode.uri, label: episode.title)
                }
                .padding(.top, 10)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var metaLine: some View {
        HStack(spacing: 5) {
            if episode.fullyPlayed {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(MusicStyle.green)
                Text("Played")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MusicStyle.green)
                if !episode.releaseDate.isEmpty {
                    Text("• \(MusicReleaseDate.label(episode.releaseDate))")
                        .font(.system(size: 12))
                        .foregroundStyle(MusicStyle.tertiary)
                }
            } else {
                Text(plainMeta)
                    .font(.system(size: 12))
                    .foregroundStyle(MusicStyle.tertiary)
            }
        }
    }

    private var plainMeta: String {
        var parts: [String] = []
        if !episode.releaseDate.isEmpty { parts.append(MusicReleaseDate.label(episode.releaseDate)) }
        if episode.durationMs > 0 {
            if let progress = episode.progressMs, progress > 0 {
                let left = max(0, episode.durationMs - progress)
                parts.append("\(musicMinutes(left)) left")
            } else {
                parts.append(musicMinutes(episode.durationMs))
            }
        }
        return parts.joined(separator: " • ")
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
                MusicArtistPortrait(url: artist.image, size: 44)
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

/// The screen's status ribbon: the toast (the backend's honest verdicts)
/// above the now-playing bar. Mounted by the home screen AND the pushed
/// playlist/show screens so a play started anywhere answers where Ido is
/// looking — exactly the placement the previous MusicView had.
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
                    .tint(MusicStyle.green)
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
                        .foregroundStyle(MusicStyle.green)
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
        .onTapGesture { model.activeSheet = .track(t) }
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
            MusicBackdrop()
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
                                .tint(MusicStyle.green)
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
                                    .foregroundStyle(MusicStyle.green)
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

    /// Spotify's playlist header: big artwork, bold name, count, and the
    /// green circular Play (the playlist uri as a context).
    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Explicit way back — Mac Catalyst has no edge-swipe and the root
            // hides the system bar, so the exit is drawn, like the mail reader.
            Button { dismiss() } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Library").font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(MusicStyle.green)
            }
            .buttonStyle(.plain)
            HStack(alignment: .bottom, spacing: 14) {
                MusicArt(url: playlist.image, size: 128, corner: 8)
                    .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
                VStack(alignment: .leading, spacing: 6) {
                    Text(playlist.name)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(3)
                        .multilineTextAlignment(playlist.name.readingAlignment)
                    Text(trackCountLine)
                        .font(.system(size: 12))
                        .foregroundStyle(MusicStyle.secondary)
                    MusicPlayCircle(size: 52) {
                        model.play(uri: playlist.uri, label: playlist.name)
                    }
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
        if n > 0 { return "Playlist • \(n) songs" }
        return playlist.owner.map { "Playlist • \($0)" } ?? "Playlist"
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

// MARK: - Show detail (pushed)

/// One podcast's page: header (artwork, name, publisher, episode count, green
/// Play for the whole show) + the episode list, newest first.
private struct MusicShowDetailView: View {
    let show: MusicShowItem
    @ObservedObject var model: MusicModel
    @Environment(\.dismiss) private var dismiss

    private enum LoadState {
        case loading
        case failed(String)
        case loaded
    }
    @State private var state: LoadState = .loading
    @State private var episodes: [MusicEpisodeItem] = []
    /// Refreshed header from music_show (falls back to the row's seed).
    @State private var freshShow: MusicShowItem?

    var body: some View {
        ZStack {
            MusicBackdrop()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    header
                    switch state {
                    case .loading:
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Loading episodes…").font(.footnote).foregroundStyle(.secondary)
                        }
                        .padding(16)
                    case .failed(let message):
                        VStack(alignment: .leading, spacing: 10) {
                            Text(message)
                                .font(.callout).foregroundStyle(.secondary)
                            Button("Try again") { Task { await load() } }
                                .buttonStyle(.bordered)
                                .tint(MusicStyle.green)
                        }
                        .padding(16)
                    case .loaded:
                        if episodes.isEmpty {
                            Text("No episodes found for this show.")
                                .font(.callout).foregroundStyle(.secondary)
                                .padding(16)
                        } else {
                            Text("Episodes")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16)
                                .padding(.top, 14)
                                .padding(.bottom, 4)
                            ForEach(episodes) { e in
                                MusicEpisodeRow(episode: e, model: model)
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

    private var current: MusicShowItem { freshShow ?? show }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Explicit way back (Catalyst has no edge-swipe; the exit is drawn).
            Button { dismiss() } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Podcasts").font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(MusicStyle.green)
            }
            .buttonStyle(.plain)
            HStack(alignment: .bottom, spacing: 14) {
                MusicArt(url: current.image, size: 128, corner: 12)
                    .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
                VStack(alignment: .leading, spacing: 6) {
                    Text(current.name)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(3)
                        .multilineTextAlignment(current.name.readingAlignment)
                    Text(headerMeta)
                        .font(.system(size: 12))
                        .foregroundStyle(MusicStyle.secondary)
                        .lineLimit(2)
                    MusicPlayCircle(size: 52) {
                        model.play(uri: current.uri, label: current.name)
                    }
                }
                Spacer(minLength: 0)
            }
            if !current.blurb.isEmpty {
                Text(current.blurb)
                    .font(.system(size: 13))
                    .foregroundStyle(MusicStyle.secondary)
                    .lineLimit(3)
                    .multilineTextAlignment(current.blurb.readingAlignment)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private var headerMeta: String {
        var parts: [String] = []
        if !current.publisher.isEmpty { parts.append(current.publisher) }
        if current.totalEpisodes > 0 { parts.append("\(current.totalEpisodes) episodes") }
        return parts.isEmpty ? "Podcast" : parts.joined(separator: " • ")
    }

    @MainActor
    private func load() async {
        state = .loading
        switch await model.fetchShow(id: show.id) {
        case .loaded(let header, let fetched):
            freshShow = header
            episodes = fetched
            state = .loaded
        case .failed(let message):
            state = .failed(message)
        }
    }
}

// MARK: - Device picker (sheet)

/// Raised when music_play answers `need_device`: lists the Spotify Connect
/// devices and retries the SAME pending play on whichever one Ido taps —
/// the no-active-device answer is a fork in the road, never a dead end.
private struct MusicDevicePickerView: View {
    let pending: MusicPendingPlay
    @ObservedObject var model: MusicModel
    @Environment(\.dismiss) private var dismiss

    private enum LoadState {
        case loading
        case failed(String)
        case loaded([MusicDeviceItem])
    }
    @State private var state: LoadState = .loading

    var body: some View {
        ZStack(alignment: .topLeading) {
            MusicBackdrop()
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Play on…")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                    Text("\"\(pending.label)\" needs a Spotify device. Pick one:")
                        .font(.system(size: 13))
                        .foregroundStyle(MusicStyle.secondary)
                        .lineLimit(2)
                }
                .padding(.top, 48)
                switch state {
                case .loading:
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Finding your Spotify devices…")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                case .failed(let message):
                    VStack(alignment: .leading, spacing: 10) {
                        Text(message)
                            .font(.callout).foregroundStyle(.secondary)
                        Button("Try again") { Task { await load() } }
                            .buttonStyle(.bordered)
                            .tint(MusicStyle.green)
                    }
                case .loaded(let devices):
                    if devices.isEmpty {
                        Text("No Spotify devices are online. Open Spotify on your phone, Mac, or a speaker and try again.")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("Refresh") { Task { await load() } }
                            .buttonStyle(.bordered)
                            .tint(MusicStyle.green)
                    } else {
                        ScrollView {
                            VStack(spacing: 4) {
                                ForEach(devices) { d in
                                    deviceRow(d)
                                }
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
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
            .accessibilityLabel("Close device picker")
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
        .task { await load() }
    }

    private func deviceRow(_ d: MusicDeviceItem) -> some View {
        Button {
            // Retry the same play, aimed at the chosen device; the dock's
            // toast reports the server's verdict.
            model.play(uri: pending.uri, label: pending.label, device: d.name)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: deviceGlyph(d.type))
                    .font(.system(size: 18))
                    .foregroundStyle(d.isActive ? MusicStyle.green : .white)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(d.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(d.isActive ? "Active now" : d.type.capitalized)
                        .font(.system(size: 12))
                        .foregroundStyle(d.isActive ? MusicStyle.green : MusicStyle.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "play.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(MusicStyle.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12).fill(MusicStyle.surface))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func deviceGlyph(_ type: String) -> String {
        switch type.lowercased() {
        case "computer": return "laptopcomputer"
        case "smartphone": return "iphone"
        case "speaker": return "hifispeaker.fill"
        case "tv": return "tv"
        case "tablet": return "ipad"
        default: return "hifispeaker"
        }
    }

    @MainActor
    private func load() async {
        state = .loading
        switch await model.fetchDevices() {
        case .loaded(let devices):
            // Active device first, then alphabetical — the likely tap on top.
            state = .loaded(devices.sorted {
                if $0.isActive != $1.isActive { return $0.isActive }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            })
        case .failed(let message):
            state = .failed(message)
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
                            .foregroundStyle(.black)
                            .padding(.horizontal, 34)
                            .padding(.vertical, 11)
                            .background(Capsule().fill(MusicStyle.green))
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
                        .tint(MusicStyle.green)
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
                        .foregroundStyle(MusicStyle.green)
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
            // Remote-speaker volume — mirrors Spotify's own slider through
            // Spotify Connect, so changes here move the speaker for real.
            if p.volumePercent != nil || model.volumeDraft != nil {
                HStack(spacing: 10) {
                    Image(systemName: "speaker.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(MusicStyle.secondary)
                    Slider(
                        value: Binding(
                            get: { model.volumeDraft ?? Double(p.volumePercent ?? 50) },
                            set: { model.setVolume($0) }
                        ),
                        in: 0...100
                    )
                    .tint(MusicStyle.green)
                    .accessibilityLabel("Speaker volume")
                    Image(systemName: "speaker.wave.3.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(MusicStyle.secondary)
                }
                .padding(.horizontal, 8)
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
