import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

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
    /// True only when a live Spotify Connect device exists right now. When false,
    /// nothing can actually play — any `nowPlaying` is a stale "ghost" track from
    /// a past session, so the page must not fake live audio.
    var hasActiveDevice: Bool = false
    /// How many Spotify apps are currently open to play to (0 → prompt "Open
    /// Spotify"). Informational alongside `hasActiveDevice`.
    var availableDevices: Int = 0
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
            note: (obj["note"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            hasActiveDevice: (obj["hasActiveDevice"] as? Bool) ?? false,
            availableDevices: (obj["availableDevices"] as? Int) ?? Int((obj["availableDevices"] as? Double) ?? 0)
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
    /// Set when a play/control action failed because Spotify Connect has no
    /// active device. Unlike `flash`, this is a *persistent* inline state that
    /// stays until a play succeeds — it drives the calm "Open Spotify" recovery
    /// affordance instead of a toast that vanishes and dead-ends him.
    @Published var needsDevice = false
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
            // Proactively surface the calm "Open Spotify" card whenever nothing
            // can actually play — but only when the library otherwise loaded
            // (connected, has content). Don't trip it on an empty/not-connected
            // page, whose own empty state already guides him.
            needsDevice = !isEmpty && !snapshot.hasActiveDevice
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
                // Playback started → there's an active device now; clear recovery.
                needsDevice = false
                flash = ""
                // Give the device a beat, then refresh the now-playing card.
                try? await Task.sleep(nanoseconds: 700_000_000)
                snapshot = (try? await provider.fetchLibrary()) ?? snapshot
            } catch {
                // Connect can only play to an already-open Spotify app. Surface a
                // calm, persistent "Open Spotify" affordance rather than a toast —
                // and, because that card sits at the top of the scroll far from a
                // tapped track, also flash a short message near the action so the
                // tap never looks silently ignored.
                needsDevice = true
                flash = "Open Spotify on a device to play"
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
}

// MARK: - View

struct MusicView: View {
    @StateObject private var model = MusicModel()
    @EnvironmentObject private var convo: Conversation

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
        // Ambient focus: the page reports itself on appearance and again after
        // each load, so the now-playing line reflects what's actually on screen.
        .onAppear { convo.setFocus(pageFocus()) }
        .onChange(of: model.snapshot) { _, _ in convo.setFocus(pageFocus()) }
    }

    /// The page-level ambient-focus line — what's playing (or last played) and
    /// what the shelf shows, so "pause it", "add this to a playlist", "play
    /// something like this" need no explanation.
    private func pageFocus() -> String {
        let s = model.snapshot
        var line = "[FOCUS] Ido is on his Music page (\(model.provider.displayName))."
        if let np = s.nowPlaying {
            let byArtist = np.artist.isEmpty ? "" : " by \(np.artist)"
            if s.hasActiveDevice {
                line += " \(np.isPlaying ? "Now playing" : "Paused"): \"\(np.title)\"\(byArtist)."
            } else {
                line += " Last played: \"\(np.title)\"\(byArtist) — no active Spotify device right now."
            }
        }
        line += " \(s.playlists.count) playlists and \(s.saved.count) saved tracks on the shelf."
            + " He can ask you to play, queue, or find music (spotify tools)."
        return line
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
                    // Only surface the standalone recovery card when there's no
                    // now-playing bar. The LAST PLAYED bar already carries an
                    // Open-Spotify affordance (it routes its tap to openSpotify()),
                    // so showing both is a redundant double prompt.
                    if model.needsDevice && model.snapshot.nowPlaying == nil {
                        deviceRecovery
                    }
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
                            .font(.scarletDetail)
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
                .font(.scarletCaptionEmph)
                .foregroundStyle(scarletRose)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(scarletRose.opacity(0.16)))
        }
    }

    // -- Now-playing bar

    private func nowPlayingBar(_ np: MusicNowPlaying) -> some View {
        // With no active Connect device, `np` is a stale "ghost" from a past
        // session — not live audio. Be honest: label it "LAST PLAYED", show a
        // play (▶) affordance (never a pause implying live sound), and route the
        // tap to openSpotify() since there's nothing to actually resume.
        let live = model.snapshot.hasActiveDevice
        return HStack(spacing: 14) {
            artwork(np.imageURL, size: 58, corner: 10)
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
                    openSpotify()
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

    // -- No-active-device recovery (one tap back into playback)

    /// Spotify Connect can only start playback on an already-open Spotify app.
    /// When there's no active device, this calm inline card explains it in one
    /// line and hands Ido a single "Open Spotify" tap — after which the app
    /// registers as a device and his next play tap just works. It clears itself
    /// the moment a play succeeds (`model.needsDevice`), so it never dead-ends.
    private var deviceRecovery: some View {
        let accent = ScarletTheme.accent(for: .music)
        return HStack(spacing: 12) {
            Image(systemName: "hifispeaker.2.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("No active \(model.provider.displayName) device")
                    .font(.scarletBodyEmph)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("Open \(model.provider.displayName) once so Scarlet can play to it.")
                    .font(.scarletDetail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button {
                openSpotify()
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

    /// Deep-link into the Spotify app so it registers as an active Connect
    /// device. Tries the `spotify:` scheme first (opens straight into the app),
    /// then the `https://open.spotify.com` universal link as a fallback. We just
    /// attempt `open(_:)` — it succeeds without an `LSApplicationQueriesSchemes`
    /// entry even when `canOpenURL` would return false. If neither opens, the
    /// honest inline text above simply stays put.
    private func openSpotify() {
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

    // -- Voice hint

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

    // -- Shared pieces

    private func sectionTitle(_ text: String) -> some View {
        // Shared in-screen grouping idiom: accent bar + section-size label.
        ScarletSectionHeader(text, accent: scarletRose)
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

    @ViewBuilder
    private var flashToast: some View {
        if !model.flash.isEmpty {
            Text(model.flash)
                .font(.scarletDetailEmph)
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
