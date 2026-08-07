import Foundation
import SwiftUI

/// The Music page's two destination screens, kept out of `MusicView.swift` so
/// the page stays readable:
///
/// - `MusicPlayerView` — the full Now Playing screen (big art, scrubbable
///   progress, transport, device line, up-next queue). Presented as the page's
///   SINGLE `.sheet` (Catalyst one-sheet rule).
/// - `PlaylistDetailView` — a browsable playlist (artwork header, Play /
///   Shuffle, pageable track list). PUSHED via `navigationDestination` so the
///   Scarlet sidebar stays reachable.
///
/// Both re-inject `convo` at their construction sites in `MusicView` (Catalyst
/// drops @EnvironmentObject across sheet/push boundaries) and follow the
/// ambient-focus discipline with the `MusicFocus` stale-guard prefixes.

// MARK: - Full Now Playing screen

struct MusicPlayerView: View {
    @ObservedObject var model: MusicModel
    @EnvironmentObject private var convo: Conversation
    @Environment(\.dismiss) private var dismiss

    /// Non-nil while a scrub drag is in flight — the bar shows the finger's
    /// position instead of the live tick, and seeks on release.
    @State private var scrubFraction: Double?

    /// Drives the device picker — the player's SINGLE sheet (Catalyst allows one
    /// per view). "Connect to a device", like Spotify's own now-playing screen.
    @State private var showDevices = false

    private let rose = MusicUI.rose

    var body: some View {
        ZStack {
            ScarletTheme.ink.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                if let st = model.playerState, let tr = st.track {
                    playerBody(st, tr)
                } else {
                    nothingPlaying
                }
            }
        }
        .overlay(alignment: .bottom) { MusicFlashToast(model: model) }
        // The device picker — the player's SINGLE sheet (Catalyst: one per view).
        .sheet(isPresented: $showDevices) { devicePickerSheet }
        // Resync the progress/queue every ~5s while the player is open (the
        // 1s tick between polls is local).
        .task {
            await model.refreshState()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await model.refreshState()
            }
        }
        .onAppear { claimFocus() }
        .onChange(of: model.playerState?.track?.uri) { _, _ in claimFocus() }
    }

    // MARK: focus

    /// Claim the player's ambient focus (stale-guarded restore happens in
    /// `MusicView` via the `MusicFocus.playerPrefix` token).
    private func claimFocus() {
        guard let tr = model.playerState?.track else {
            convo.setFocus(MusicFocus.playerPrefix
                + " screen, but nothing is playing right now — he needs Spotify open on a device.")
            return
        }
        let byArtist = tr.artist.isEmpty ? "" : " by \(tr.artist)"
        var line = MusicFocus.playerPrefix + " screen — \"\(tr.title)\"\(byArtist)"
        if let st = model.playerState {
            if let dev = st.device { line += ", \(st.isPlaying ? "playing" : "paused") on \(dev.name)" }
            if !st.queue.isEmpty { line += ". \(st.queue.count) tracks are up next" }
        }
        line += ". He sees the progress bar, transport controls, and the queue —"
            + " he can ask you to pause, skip, seek, shuffle, or queue something (spotify tools)."
        convo.setFocus(line)
    }

    // MARK: chrome

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close player")
            Spacer()
            Text("NOW PLAYING")
                .font(.system(size: 13, weight: .bold))
                .tracking(1.5)
                .foregroundStyle(rose)
            Spacer()
            // Connect to a device — opens the room/speaker picker.
            Button {
                Task { await model.loadDevices() }
                showDevices = true
            } label: {
                Image(systemName: "hifispeaker.and.homepod")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Choose a device")
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
    }

    // MARK: device picker (the player's single sheet)

    private var devicePickerSheet: some View {
        ZStack {
            ScarletTheme.ink.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Play on")
                        .font(.scarletTitle)
                        .foregroundStyle(.white)
                    Spacer()
                    Button { showDevices = false } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }
                ScrollView {
                    // Tapping a device dismisses the picker; the chooser starts
                    // playback on that room via the shared model.
                    MusicDeviceChooser(model: model) { showDevices = false }
                }
                Spacer(minLength: 0)
            }
            .padding(20)
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: player body

    private func playerBody(_ st: MusicPlayerState, _ tr: MusicPlayerTrack) -> some View {
        ScrollView {
            VStack(spacing: 22) {
                MusicArtwork(url: tr.imageURL, size: 300, corner: 20)
                    .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
                    .padding(.top, 12)

                VStack(spacing: 5) {
                    Text(tr.title)
                        .font(.scarletTitle)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    if !tr.artist.isEmpty {
                        Text(tr.artist)
                            .font(.scarletBody)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if !tr.album.isEmpty && tr.album != tr.title {
                        Text(tr.album)
                            .font(.scarletDetail)
                            .foregroundStyle(.secondary.opacity(0.8))
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 24)

                progressSection(st)
                transport(st)
                deviceLine(st)
                upNext(st)

                Color.clear.frame(height: 24)
            }
            .padding(.horizontal, 24)
        }
    }

    // MARK: progress (real bar: local 1s tick, 5s resync, drag to seek)

    private func progressSection(_ st: MusicPlayerState) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let duration = max(st.durationMs, 1)
            let liveFraction = Double(model.displayedProgressMs(at: context.date) ?? 0) / Double(duration)
            let fraction = min(max(scrubFraction ?? liveFraction, 0), 1)
            VStack(spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.18))
                            .frame(height: 5)
                        Capsule().fill(rose)
                            .frame(width: max(geo.size.width * fraction, 5), height: 5)
                        Circle()
                            .fill(.white)
                            .frame(width: scrubFraction != nil ? 18 : 12,
                                   height: scrubFraction != nil ? 18 : 12)
                            .offset(x: geo.size.width * fraction - (scrubFraction != nil ? 9 : 6))
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard st.durationMs > 0 else { return }
                                scrubFraction = min(max(value.location.x / max(geo.size.width, 1), 0), 1)
                            }
                            .onEnded { value in
                                let f = min(max(value.location.x / max(geo.size.width, 1), 0), 1)
                                scrubFraction = nil
                                guard st.durationMs > 0 else { return }
                                model.seek(toMs: Int(f * Double(st.durationMs)))
                            }
                    )
                }
                .frame(height: 30)
                HStack {
                    Text(MusicUI.time(ms: Int(fraction * Double(st.durationMs))))
                    Spacer()
                    Text(MusicUI.time(ms: st.durationMs))
                }
                .font(.scarletCaption)
                .foregroundStyle(.secondary)
            }
        }
        .frame(height: 56)
    }

    // MARK: transport

    private func transport(_ st: MusicPlayerState) -> some View {
        HStack {
            Button {
                model.toggleShuffle()
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(st.shuffle ? rose : .white.opacity(0.55))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(st.shuffle ? "Shuffle on" : "Shuffle off")

            Spacer()

            Button {
                model.skip(forward: false)
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Previous track")

            Spacer()

            Button {
                model.togglePlayPause()
            } label: {
                Image(systemName: st.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 74))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(st.isPlaying ? "Pause" : "Play")

            Spacer()

            Button {
                model.skip(forward: true)
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Next track")

            Spacer()

            // Passive repeat indicator — the server exposes no repeat setter
            // yet, so this reports state without pretending to be a control.
            Image(systemName: st.repeatMode == "track" ? "repeat.1" : "repeat")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(st.repeatMode == "off" ? .white.opacity(0.25) : rose)
                .frame(width: 44, height: 44)
                .accessibilityLabel("Repeat \(st.repeatMode)")
        }
    }

    // MARK: device line

    @ViewBuilder
    private func deviceLine(_ st: MusicPlayerState) -> some View {
        if let dev = st.device {
            // Tap to switch rooms — opens the device picker.
            Button {
                Task { await model.loadDevices() }
                showDevices = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "hifispeaker.2.fill")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Playing on \(dev.name)")
                        .font(.scarletDetail)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .opacity(0.7)
                }
                .foregroundStyle(rose)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Switch device — playing on \(dev.name)")
        } else {
            Button {
                Task { await model.loadDevices() }
                showDevices = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "hifispeaker.and.homepod")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Choose a device")
                        .font(.scarletDetailEmph)
                }
                .foregroundStyle(ScarletTheme.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Capsule().fill(ScarletTheme.accent(for: .music)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Choose a device")
        }
    }

    // MARK: up next

    @ViewBuilder
    private func upNext(_ st: MusicPlayerState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ScarletSectionHeader("Up Next", accent: rose)
            if st.queue.isEmpty {
                Text("Nothing queued after this.")
                    .font(.scarletDetail)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(st.queue.enumerated()), id: \.element.id) { idx, item in
                        Button {
                            if !item.uri.isEmpty { model.play(uri: item.uri) }
                        } label: {
                            queueRow(item)
                        }
                        .buttonStyle(.plain)
                        if idx < st.queue.count - 1 {
                            Divider().overlay(Color.white.opacity(0.06))
                                .padding(.leading, 60)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(MusicUI.cardBG)
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 6)
    }

    private func queueRow(_ item: MusicQueueItem) -> some View {
        HStack(spacing: 12) {
            MusicArtwork(url: item.imageURL, size: 40, corner: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.scarletBodyEmph)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if !item.artist.isEmpty {
                    Text(item.artist)
                        .font(.scarletDetail)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if model.startingURI == item.uri {
                ProgressView().tint(rose)
            } else {
                Image(systemName: "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    // MARK: empty state

    private var nothingPlaying: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note")
                .font(.system(size: 46))
                .foregroundStyle(rose)
            Text("Nothing playing right now")
                .font(.headline)
                .foregroundStyle(.white)
            Text("Start something from a playlist, search, or just say \u{201C}play \u{2026}\u{201D} to Scarlet.")
                .font(.scarletBody)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                MusicUI.openSpotify()
            } label: {
                Text("Open Spotify")
                    .font(.scarletDetailEmph)
                    .foregroundStyle(ScarletTheme.ink)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(ScarletTheme.accent(for: .music)))
            }
            .buttonStyle(.plain)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Playlist detail (pushed)

/// Loads a playlist page by page (`op=music_playlist`, `next_offset` paging).
@MainActor
final class PlaylistDetailModel: ObservableObject {
    @Published var name: String
    @Published var imageURL: URL?
    @Published var tracks: [MusicPlaylistTrack] = []
    @Published var total: Int
    @Published var loading = false
    @Published var loadingMore = false
    @Published var errorText = ""

    private var nextOffset: Int?
    private let playlist: MusicPlaylist
    private let provider: MusicProvider

    init(playlist: MusicPlaylist, provider: MusicProvider) {
        self.playlist = playlist
        self.provider = provider
        self.name = playlist.name
        self.imageURL = playlist.imageURL
        self.total = playlist.count
    }

    var canLoadMore: Bool { nextOffset != nil }

    func load() async {
        guard !loading else { return }
        loading = true
        errorText = ""
        defer { loading = false }
        do {
            let page = try await provider.fetchPlaylist(id: playlist.id, offset: 0)
            apply(page, reset: true)
        } catch {
            let msg = (error as? MusicPlayError)?.message ?? ""
            errorText = msg.isEmpty
                ? "Couldn\u{2019}t load this playlist \u{2014} check your connection."
                : String(msg.prefix(180))
        }
    }

    /// Called from the last visible row — fetches the next page, if any.
    func loadMore() {
        guard let offset = nextOffset, !loadingMore, !loading else { return }
        loadingMore = true
        Task { @MainActor in
            defer { loadingMore = false }
            do {
                let page = try await provider.fetchPlaylist(id: playlist.id, offset: offset)
                apply(page, reset: false)
            } catch {
                // Quiet: the row's reappearance on the next scroll retries.
            }
        }
    }

    private func apply(_ page: MusicPlaylistDetailPage, reset: Bool) {
        if reset {
            tracks = page.tracks
        } else {
            let seen = Set(tracks.map(\.id))
            tracks += page.tracks.filter { !seen.contains($0.id) }
        }
        if !page.name.isEmpty { name = page.name }
        if let img = page.imageURL { imageURL = img }
        if page.total > 0 { total = page.total }
        // Provider already guarantees next_offset strictly advances; also stop
        // if a page came back empty (nothing further to fetch).
        nextOffset = page.tracks.isEmpty ? nil : page.nextOffset
    }
}

/// Spotify-style playlist screen: artwork header, Play / Shuffle, then the
/// track list with tap-to-play and load-more paging.
struct PlaylistDetailView: View {
    let playlist: MusicPlaylist
    @ObservedObject var model: MusicModel
    @StateObject private var detail: PlaylistDetailModel
    @EnvironmentObject private var convo: Conversation
    @Environment(\.dismiss) private var dismiss

    private let rose = MusicUI.rose

    init(playlist: MusicPlaylist, model: MusicModel) {
        self.playlist = playlist
        self.model = model
        _detail = StateObject(wrappedValue:
            PlaylistDetailModel(playlist: playlist, provider: model.provider))
    }

    var body: some View {
        ZStack {
            ScarletTheme.ink.ignoresSafeArea()
            VStack(spacing: 0) {
                backBar
                content
            }
        }
        .overlay(alignment: .bottom) { MusicFlashToast(model: model) }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .task { await detail.load() }
        .onAppear { claimFocus() }
        .onChange(of: detail.tracks.count) { _, _ in claimFocus() }
    }

    // MARK: focus

    /// Claim the playlist's ambient focus (stale-guarded restore happens in
    /// `MusicView` via the `MusicFocus.playlistPrefix` token).
    private func claimFocus() {
        var line = MusicFocus.playlistPrefix + " \"\(detail.name)\""
        if detail.total > 0 {
            line += " (\(detail.total) track\(detail.total == 1 ? "" : "s"))"
        }
        line += " on the Music page. He can tap a track to play it, hit Play or"
            + " Shuffle for the whole playlist, or ask you to play or queue"
            + " something from it (spotify tools)."
        convo.setFocus(line)
    }

    // MARK: chrome

    /// The list root hides the system nav bar app-wide and Mac Catalyst has no
    /// edge-swipe-back, so the only reliable exit is one we draw ourselves —
    /// the app-wide reader pattern.
    private var backBar: some View {
        HStack {
            Button { dismiss() } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Music")
                        .font(.system(size: 17, weight: .semibold))
                }
                .foregroundStyle(rose)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to Music")
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    // MARK: content

    @ViewBuilder
    private var content: some View {
        if detail.loading && detail.tracks.isEmpty {
            VStack(spacing: 14) {
                ProgressView().tint(rose)
                Text("Loading \u{201C}\(detail.name)\u{201D}\u{2026}")
                    .font(.scarletBody)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !detail.errorText.isEmpty && detail.tracks.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 42))
                    .foregroundStyle(.secondary)
                Text(detail.errorText)
                    .font(.scarletBody)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try Again") { Task { await detail.load() } }
                    .buttonStyle(.borderedProminent)
                    .tint(rose)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if detail.tracks.isEmpty {
            VStack(spacing: 14) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 42))
                    .foregroundStyle(rose)
                Text("This playlist is empty.")
                    .font(.scarletBody)
                    .foregroundStyle(.secondary)
                Button("Refresh") { Task { await detail.load() } }
                    .buttonStyle(.bordered)
                    .tint(rose)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            trackList
        }
    }

    private var trackList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                playlistHeader
                VStack(spacing: 0) {
                    ForEach(Array(detail.tracks.enumerated()), id: \.element.id) { idx, tr in
                        Button {
                            model.play(uri: tr.uri)
                        } label: {
                            trackRow(tr)
                        }
                        .buttonStyle(.plain)
                        .onAppear {
                            // Load-more when the tail scrolls into view.
                            if idx >= detail.tracks.count - 5 { detail.loadMore() }
                        }
                        if idx < detail.tracks.count - 1 {
                            Divider().overlay(Color.white.opacity(0.06))
                                .padding(.leading, 66)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(MusicUI.cardBG)
                )
                if detail.loadingMore {
                    HStack(spacing: 10) {
                        ProgressView().tint(rose)
                        Text("Loading more\u{2026}")
                            .font(.scarletDetail)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                } else if detail.canLoadMore {
                    // Fallback affordance in case the scroll-end onAppear was
                    // missed (fast fling) — never a dead end.
                    Button("Load more") { detail.loadMore() }
                        .font(.scarletDetailEmph)
                        .buttonStyle(.bordered)
                        .tint(rose)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                Color.clear.frame(height: 24)
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
        }
    }

    // MARK: header (artwork + name + Play/Shuffle)

    private var playlistHeader: some View {
        VStack(spacing: 14) {
            MusicArtwork(url: detail.imageURL, size: 200, corner: 16)
                .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
            VStack(spacing: 4) {
                Text(detail.name)
                    .font(.scarletTitle)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                if detail.total > 0 {
                    Text(detail.total == 1 ? "1 track" : "\(detail.total) tracks")
                        .font(.scarletDetail)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 12) {
                Button {
                    model.play(uri: playlist.uri)
                } label: {
                    HStack(spacing: 7) {
                        if model.startingURI == playlist.uri {
                            ProgressView().tint(ScarletTheme.ink)
                        } else {
                            Image(systemName: "play.fill")
                                .font(.system(size: 15, weight: .bold))
                        }
                        Text("Play")
                            .font(.scarletBodyEmph)
                    }
                    .foregroundStyle(ScarletTheme.ink)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 11)
                    .background(Capsule().fill(rose))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Play \(detail.name)")

                Button {
                    model.playShuffled(uri: playlist.uri)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "shuffle")
                            .font(.system(size: 15, weight: .bold))
                        Text("Shuffle")
                            .font(.scarletBodyEmph)
                    }
                    .foregroundStyle(rose)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 11)
                    .background(
                        Capsule().fill(rose.opacity(0.16))
                            .overlay(Capsule().stroke(rose.opacity(0.5), lineWidth: 1))
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Shuffle \(detail.name)")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
    }

    // MARK: rows

    private func trackRow(_ tr: MusicPlaylistTrack) -> some View {
        // Highlight the row that's actually loaded on the player right now.
        let isCurrent = model.playerState?.track?.uri == tr.uri && !tr.uri.isEmpty
        return HStack(spacing: 12) {
            MusicArtwork(url: tr.imageURL, size: 46, corner: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(tr.title)
                    .font(.scarletBodyEmph)
                    .foregroundStyle(isCurrent ? rose : .white)
                    .lineLimit(1)
                if !tr.artist.isEmpty {
                    Text(tr.artist)
                        .font(.scarletDetail)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if tr.durationMs > 0 {
                Text(MusicUI.time(ms: tr.durationMs))
                    .font(.scarletCaption)
                    .foregroundStyle(.secondary)
            }
            if model.startingURI == tr.uri {
                ProgressView().tint(rose)
            } else if isCurrent && model.playerState?.isPlaying == true {
                Image(systemName: "waveform")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(rose)
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
}
