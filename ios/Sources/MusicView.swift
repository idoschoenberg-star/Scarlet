import Foundation
import SwiftUI

/// The Music section: Ido's own streaming library on a dynamic, dark page, plus
/// one-tap playback onto his active device — and the reminder that he can always
/// just *say* "play <something>" and Scarlet will start it by voice.
///
/// Backend: the same edge-function plumbing as the rest of the app
/// (`app-api?v=2` + `x-scarlet-token`). Three ops power this page —
/// `op=music_library` (GET), `op=music_play` (POST {uri|query}), and
/// `op=music_control` (POST {action}) for the now-playing play/pause.
///
/// Provider seam: everything the page needs is expressed through
/// `MusicProvider`, so a second service (Tidal) can be dropped in later without
/// touching the view. Only Spotify is implemented today.

// MARK: - Wire model (provider-neutral)

/// One playlist tile on the shelf.
struct MusicPlaylist: Identifiable, Equatable {
    let id: String
    let name: String
    let imageURL: URL?
    let count: Int
    let uri: String
}

/// One saved/liked track row.
struct MusicTrack: Identifiable, Equatable {
    let id: String
    let title: String
    let artist: String
    let imageURL: URL?
    let uri: String
}

/// The now-playing card, when something is on a device.
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
}

// MARK: - Provider seam (Spotify today, Tidal later)

/// The thin contract the Music page is written against. Add Tidal by writing a
/// second `MusicProvider`; the view and model never change.
protocol MusicProvider {
    /// Human label for the source ("Spotify"), used in copy and empty states.
    var displayName: String { get }
    /// Fetch the whole page in one shot. Must not throw for an *empty* library —
    /// it returns an empty snapshot (optionally with a `note`); it throws only
    /// on a real transport/auth failure so the view can show a retry.
    func fetchLibrary() async throws -> MusicLibrarySnapshot
    /// Start playback of an exact provider URI (a tapped playlist or track).
    func play(uri: String) async throws
    /// Resume / pause whatever is currently loaded (the now-playing button).
    func setPlaying(_ playing: Bool) async throws
}

/// Spotify implementation over `app-api`. Holds no secret — the edge function
/// owns the OAuth token; the app only carries the device token.
struct SpotifyMusicProvider: MusicProvider {
    let displayName = "Spotify"

    func fetchLibrary() async throws -> MusicLibrarySnapshot {
        let data = try await MusicAPI.get("music_library")
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return MusicLibrarySnapshot(
            playlists: Self.parsePlaylists(obj["playlists"]),
            saved: Self.parseTracks(obj["saved"]),
            nowPlaying: Self.parseNowPlaying(obj["nowPlaying"]),
            note: (obj["note"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    func play(uri: String) async throws {
        _ = try await MusicAPI.post("music_play", body: ["uri": uri])
    }

    func setPlaying(_ playing: Bool) async throws {
        _ = try await MusicAPI.post("music_control", body: ["action": playing ? "resume" : "pause"])
    }

    // -- parsing (defensive: every field optional, art URLs never force-unwrapped)

    private static func url(_ any: Any?) -> URL? {
        guard let s = any as? String, !s.isEmpty else { return nil }
        return URL(string: s)
    }

    private static func parsePlaylists(_ any: Any?) -> [MusicPlaylist] {
        let raw = (any as? [[String: Any]]) ?? []
        var seen = Set<String>()
        return raw.compactMap { p in
            guard let id = p["id"] as? String, !id.isEmpty,
                  let uri = p["uri"] as? String, !uri.isEmpty,
                  seen.insert(id).inserted else { return nil }
            return MusicPlaylist(
                id: id,
                name: (p["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Playlist",
                imageURL: url(p["image"]),
                count: (p["count"] as? Int) ?? Int((p["count"] as? Double) ?? 0),
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
}

/// Tiny app-api client for the Music page — GET reads and POST actions on
/// `app-api?v=2`, carrying only the device token. Mirrors DraftView/LibraryView
/// plumbing (200-check, JSON body).
enum MusicAPI {
    static func get(_ op: String) async throws -> Data {
        guard let url = URL(string: "\(AppConfig.apiBase)/app-api?v=2&op=\(op)") else {
            throw URLError(.badURL)
        }
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

// MARK: - Model

@MainActor
final class MusicModel: ObservableObject {
    @Published var snapshot = MusicLibrarySnapshot()
    @Published var loading = false
    @Published var errorText = ""
    /// A short transient toast shown when a play action fails ("Couldn't start
    /// — open Spotify on a device first"), cleared on the next successful tap.
    @Published var flash = ""
    /// The uri currently being started, to show a spinner on the tapped tile.
    @Published var startingURI: String?

    let provider: MusicProvider

    init(provider: MusicProvider = SpotifyMusicProvider()) {
        self.provider = provider
    }

    var isEmpty: Bool {
        snapshot.playlists.isEmpty && snapshot.saved.isEmpty && snapshot.nowPlaying == nil
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
        } catch {
            errorText = "Couldn't reach \(provider.displayName) — check your connection."
        }
    }

    /// Tap a playlist/track → start it on his active device.
    func play(uri: String) {
        guard !uri.isEmpty, startingURI == nil else { return }
        flash = ""
        startingURI = uri
        Task { @MainActor in
            defer { startingURI = nil }
            do {
                try await provider.play(uri: uri)
                // Give the device a beat, then refresh the now-playing card.
                try? await Task.sleep(nanoseconds: 700_000_000)
                snapshot = (try? await provider.fetchLibrary()) ?? snapshot
            } catch {
                flash = "Couldn't start playback — open \(provider.displayName) on a device first."
            }
        }
    }

    /// Now-playing play/pause toggle.
    func togglePlayPause() {
        guard let np = snapshot.nowPlaying else { return }
        let want = !np.isPlaying
        // Optimistic flip so the button responds instantly.
        snapshot.nowPlaying = MusicNowPlaying(
            title: np.title, artist: np.artist, imageURL: np.imageURL, isPlaying: want
        )
        Task { @MainActor in
            do {
                try await provider.setPlaying(want)
            } catch {
                // Revert on failure.
                snapshot.nowPlaying = np
                flash = "Couldn't \(want ? "resume" : "pause") — open \(provider.displayName) on a device first."
            }
        }
    }
}

// MARK: - View

struct MusicView: View {
    @StateObject private var model = MusicModel()

    // House dark-scarlet palette (matches LibraryView / DraftView).
    private let scarletRose = Color(red: 1, green: 0.35, blue: 0.42)
    private let cardBG = Color(white: 0.12)

    var body: some View {
        ZStack {
            ScarletTheme.ink.ignoresSafeArea()   // shared near-black ink ground; green accent stays as chrome
            content
        }
        .task { await model.load() }
        .refreshable { await model.load() }
    }

    @ViewBuilder
    private var content: some View {
        if model.loading && model.isEmpty {
            loadingState
        } else if !model.errorText.isEmpty && model.isEmpty {
            errorState(model.errorText)
        } else if model.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    header
                    if let np = model.snapshot.nowPlaying {
                        nowPlayingBar(np)
                    }
                    voiceHint
                    if !model.snapshot.playlists.isEmpty {
                        playlistShelf
                    }
                    if !model.snapshot.saved.isEmpty {
                        savedList
                    }
                    if let note = model.snapshot.note, !note.isEmpty {
                        Text(note)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 4)
                    }
                    Color.clear.frame(height: 24)
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
            }
            .overlay(alignment: .bottom) { flashToast }
        }
    }

    // -- Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Music")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Spacer()
            Text(model.provider.displayName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(scarletRose)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(scarletRose.opacity(0.16)))
        }
    }

    // -- Now-playing bar

    private func nowPlayingBar(_ np: MusicNowPlaying) -> some View {
        HStack(spacing: 14) {
            artwork(np.imageURL, size: 58, corner: 10)
            VStack(alignment: .leading, spacing: 3) {
                Text("NOW PLAYING")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(scarletRose)
                Text(np.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if !np.artist.isEmpty {
                    Text(np.artist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button {
                model.togglePlayPause()
            } label: {
                Image(systemName: np.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(np.isPlaying ? "Pause" : "Play")
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

    // -- Voice hint

    private var voiceHint: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(scarletRose)
            Text("Or just say \u{201C}play \u{2026}\u{201D} to Scarlet \u{2014} she\u{2019}ll start it here.")
                .font(.subheadline)
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

    // -- Playlist shelf (horizontal artwork cards)

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

    private func playlistCard(_ pl: MusicPlaylist) -> some View {
        Button {
            model.play(uri: pl.uri)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    artwork(pl.imageURL, size: 148, corner: 14)
                    if model.startingURI == pl.uri {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.black.opacity(0.45))
                            .frame(width: 148, height: 148)
                        ProgressView().tint(.white)
                    }
                }
                Text(pl.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(pl.count == 1 ? "1 track" : "\(pl.count) tracks")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 148, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    // -- Saved tracks list

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
            artwork(tr.imageURL, size: 46, corner: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(tr.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if !tr.artist.isEmpty {
                    Text(tr.artist)
                        .font(.caption)
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

    // -- Shared pieces

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.title3.weight(.bold))
            .foregroundStyle(.white)
    }

    /// Artwork with a graceful placeholder — never force-unwraps a URL, and
    /// draws a music-note tile when there's no art or the load fails.
    @ViewBuilder
    private func artwork(_ url: URL?, size: CGFloat, corner: CGFloat) -> some View {
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

    // -- Whole-page states

    private var loadingState: some View {
        VStack(spacing: 14) {
            ProgressView().tint(scarletRose)
            Text("Loading your music\u{2026}")
                .font(.subheadline)
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
                .font(.subheadline)
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
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Refresh") { Task { await model.load() } }
                .buttonStyle(.bordered)
                .tint(scarletRose)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var flashToast: some View {
        if !model.flash.isEmpty {
            Text(model.flash)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(
                    Capsule().fill(Color(white: 0.18))
                        .overlay(Capsule().stroke(scarletRose.opacity(0.5), lineWidth: 1))
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
