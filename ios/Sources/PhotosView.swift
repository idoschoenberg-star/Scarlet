import Foundation
import SwiftUI
import UIKit

/// Photos: the native gallery of photos & creations Scarlet has gathered for
/// Ido — an Apple-Photos-style grid (newest first, endless scroll), a
/// full-screen lightbox with swipe-paging and pinch/double-tap zoom, and a
/// Forward action that hands off to the EXISTING drafting studio (DraftView),
/// so nothing sends until Ido approves. Same edge-function plumbing as the
/// rest of the app (app-api?v=2 + x-scarlet-token via ChatsAPI), same
/// dark-scarlet look. Mirrors the web app's Photos tab (`op=gallery` /
/// `op=gallery_archive`): archive only HIDES a photo from the gallery —
/// nothing is deleted anywhere.

// MARK: - Wire type

/// One gallery photo, as `op=gallery` returns it:
/// `{ id, created_at, text, media_url }` from `app_messages`
/// (kind='image', not gallery-archived), media_url already signed server-side.
private struct GalleryPhoto: Identifiable {
    let id: String
    /// Raw `created_at` string — the server's `before` cursor compares this
    /// exact value, so it is kept verbatim for paging.
    let createdAtRaw: String
    let createdAt: Date?
    /// Caption with the web app's leading "📷 " marker stripped.
    let caption: String
    let url: URL
}

// MARK: - Model

@MainActor
private final class PhotosModel: ObservableObject {
    @Published var photos: [GalleryPhoto] = []
    @Published var loading = false
    @Published var loadingMore = false
    @Published var errorText = ""
    /// Bumps on every successful fresh load so the view re-reports focus with
    /// the actual photo count (LibraryModel's pattern).
    @Published var loadStamp = 0

    /// True once an older-page fetch comes back empty — stops the endless
    /// scroll from hammering the server (web app's `gDone`).
    private var reachedEnd = false
    /// Oldest `created_at` seen, verbatim — the next page's `before` cursor.
    private var oldestRaw: String?
    /// Ids already on screen. A duplicate id traps the diffable grid — the
    /// fresh page and the `before` pages can overlap, so every insert dedups.
    private var seen = Set<String>()
    /// Monotonic load token: a slow fetch landing after a newer one is
    /// dropped (InboxModel / LibraryModel discipline).
    private var loadGeneration = 0

    /// Fresh load: replaces the grid with the newest page.
    func load() async {
        guard TokenStore.token != nil else {
            photos = []
            errorText = "Locked — unlock Scarlet to see your photos."
            return
        }
        if photos.isEmpty { loading = true }
        errorText = ""
        loadGeneration += 1
        let generation = loadGeneration
        defer { if generation == loadGeneration { loading = false } }
        do {
            let fetched = try await Self.fetchPage(before: nil)
            guard generation == loadGeneration else { return }
            seen = []
            oldestRaw = nil
            reachedEnd = false
            photos = merge(fetched, into: [])
            loadStamp += 1
        } catch {
            guard generation == loadGeneration else { return }
            errorText = "Couldn't reach your photos — check your connection."
        }
    }

    /// Endless scroll: fetch the page older than everything on screen.
    func loadMore() async {
        guard !loading, !loadingMore, !reachedEnd,
              let cursor = oldestRaw, !cursor.isEmpty,
              TokenStore.token != nil else { return }
        loadingMore = true
        let generation = loadGeneration
        defer { loadingMore = false }
        do {
            let fetched = try await Self.fetchPage(before: cursor)
            guard generation == loadGeneration else { return }
            if fetched.isEmpty { reachedEnd = true; return }
            let countBefore = photos.count
            photos = merge(fetched, into: photos)
            // A page of pure duplicates means the cursor can't advance —
            // stop rather than refetch the same page forever.
            if photos.count == countBefore { reachedEnd = true }
        } catch {
            // Older-page miss is silent (web app behavior) — the next scroll
            // nudge retries; the grid already on screen stays honest.
        }
    }

    /// Archive = hide from the Gallery only; nothing is deleted anywhere.
    /// Optimistic removal (the web card fades instantly); a server refusal
    /// reloads the truth.
    func archive(_ photo: GalleryPhoto) {
        photos.removeAll { $0.id == photo.id }
        Task {
            do {
                let data = try await ChatsAPI.request(
                    "op=gallery_archive", method: "POST",
                    body: ["ids": [photo.id]])
                let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                guard (obj?["ok"] as? Bool) == true else {
                    throw URLError(.badServerResponse)
                }
            } catch {
                errorText = "Couldn't remove that photo — refreshed the gallery."
                await load()
            }
        }
    }

    /// Dedup + append, keeping the `before` cursor at the oldest raw value.
    private func merge(_ fetched: [GalleryPhoto], into current: [GalleryPhoto]) -> [GalleryPhoto] {
        var out = current
        for p in fetched {
            guard seen.insert(p.id).inserted else { continue }
            out.append(p)
            if oldestRaw == nil || p.createdAtRaw < oldestRaw! {
                oldestRaw = p.createdAtRaw
            }
        }
        return out
    }

    // MARK: plumbing — GET like the web app (`op=gallery&before=…` rides the
    // query string; the server reads url.searchParams, not the body).

    private static func fetchPage(before: String?) async throws -> [GalleryPhoto] {
        var query = "op=gallery"
        if let before, !before.isEmpty {
            query += "&before=\(ChatsAPI.encode(before))"
        }
        let data = try await ChatsAPI.request(query, method: "GET")
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let raw = (obj["photos"] as? [[String: Any]]) ?? []
        return raw.compactMap { p in
            guard let id = p["id"] as? String, !id.isEmpty,
                  let urlString = p["media_url"] as? String,
                  let url = URL(string: urlString) else { return nil }
            let createdRaw = (p["created_at"] as? String) ?? ""
            var caption = ((p["text"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if caption.hasPrefix("📷") {
                caption = String(caption.dropFirst())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return GalleryPhoto(
                id: id,
                createdAtRaw: createdRaw,
                createdAt: MailDates.parse(createdRaw),
                caption: caption,
                url: url
            )
        }
    }
}

// MARK: - Photos page

struct PhotosView: View {
    @StateObject private var model = PhotosModel()
    @EnvironmentObject private var convo: Conversation

    /// Full-screen lightbox target (`.fullScreenCover(item:)`).
    /// One `.sheet` + one `.fullScreenCover` on this view — the allowed
    /// Mac Catalyst maximum; never a second `.sheet`.
    private struct LightboxTarget: Identifiable {
        let id: String   // the photo id the lightbox opens on
    }
    @State private var lightboxTarget: LightboxTarget?
    /// The ONE sheet on this view: the forward flow (chooser → DraftView in
    /// place — content swaps inside a single presentation, so a second sheet
    /// never races the first on Catalyst).
    @State private var forwardPhoto: GalleryPhoto?
    /// The exact focus line last claimed for an open lightbox; dismissal
    /// restores the browsing focus only if this still owns it (the
    /// InboxView / LibraryView stale-guard pattern).
    @State private var openedFocus: String?

    private let scarletRose = Color(red: 1, green: 0.35, blue: 0.42)

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                headerBar
                content
            }
            .background(ScarletBackground().ignoresSafeArea())
            // Scarlet lives at the bottom of the list screen, part of its
            // layout — same pattern as ChatsView / InboxView / LibraryView.
            .safeAreaInset(edge: .bottom) {
                ScarletPresenceView(convo: convo)
                    .padding(.vertical, 6)
            }
            .toolbar(.hidden, for: .navigationBar)
            // Ambient focus: the gallery reports itself on appearance and
            // after every successful load (count changes).
            .onAppear { convo.setFocus(browsingFocus) }
            .onChange(of: model.loadStamp) { _, _ in
                convo.setFocus(browsingFocus)
            }
            .reportsModalPresence(forwardPhoto != nil || lightboxTarget != nil)
            .sheet(item: $forwardPhoto) { photo in
                PhotoForwardFlow(photo: photo)
                    .environmentObject(convo)
                    .preferredColorScheme(.dark)
            }
            .fullScreenCover(item: $lightboxTarget,
                             onDismiss: { restoreBrowsingFocus() }) { target in
                PhotoLightboxView(model: model, startID: target.id)
                    .environmentObject(convo)
                    .preferredColorScheme(.dark)
            }
        }
        // .task re-runs every time this tab is selected → refresh on appear;
        // foreground return refreshes too (InboxView pattern).
        .task { await model.load() }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.willEnterForegroundNotification)) { _ in
            Task { await model.load() }
        }
    }

    // MARK: header (big heavy title + refresh, like ChatsView / LibraryView)

    private var headerBar: some View {
        HStack(spacing: 12) {
            Text("Photos")
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

    // MARK: content

    @ViewBuilder
    private var content: some View {
        if model.loading && model.photos.isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                Text("Fetching your photos…")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.photos.isEmpty && !model.errorText.isEmpty {
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
        } else if model.photos.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.title2).foregroundStyle(.secondary)
                Text("No photos yet.\nAsk Scarlet — \"show me my last photos\" — and they'll gather here.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            photoGrid
        }
    }

    // MARK: grid (Apple-Photos look: square thumbs, hairline gutters)

    private var photoGrid: some View {
        ScrollView {
            if !model.errorText.isEmpty {
                Text(model.errorText)
                    .font(.footnote)
                    .foregroundStyle(Color(red: 0.91, green: 0.69, blue: 0.31))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
            }
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 110, maximum: 220), spacing: 2)],
                spacing: 2
            ) {
                ForEach(model.photos) { photo in
                    thumb(photo)
                        .onAppear {
                            // Endless scroll: nearing the tail fetches the
                            // next `before` page (web app's scroll sentinel).
                            if photo.id == model.photos.last?.id {
                                Task { await model.loadMore() }
                            }
                        }
                }
            }
            if model.loadingMore {
                ProgressView()
                    .padding(.vertical, 16)
            }
        }
        .refreshable { await model.load() }
    }

    private func thumb(_ photo: GalleryPhoto) -> some View {
        Button {
            claimFocus(photo)
            lightboxTarget = LightboxTarget(id: photo.id)
        } label: {
            Color.white.opacity(0.06)
                .overlay(
                    AsyncImage(url: photo.url) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else if phase.error != nil {
                            Image(systemName: "photo")
                                .font(.system(size: 22))
                                .foregroundStyle(.white.opacity(0.3))
                        } else {
                            ProgressView().tint(.white.opacity(0.5))
                        }
                    }
                )
                .aspectRatio(1, contentMode: .fit)
                .clipped()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                forwardPhoto = photo
            } label: {
                Label("Forward…", systemImage: "paperplane")
            }
            Button {
                model.archive(photo)
            } label: {
                Label("Remove from Gallery", systemImage: "archivebox")
            }
        }
        .accessibilityLabel(photo.caption.isEmpty ? "Photo" : photo.caption)
    }

    // MARK: Scarlet focus

    private var browsingFocus: String {
        "[FOCUS] Ido is browsing his Photos — the gallery of photos & "
            + "creations Scarlet has gathered for him. "
            + "\(model.photos.count) photos on the grid."
    }

    private func claimFocus(_ photo: GalleryPhoto) {
        var f = "[FOCUS] Ido opened a photo full-screen in his Photos gallery."
        if !photo.caption.isEmpty { f += " Caption: \(photo.caption.prefix(200))" }
        openedFocus = f
        convo.setFocus(f)
    }

    /// Stale-guard: restore the grid focus only if the closed lightbox still
    /// owns it — another screen may have claimed focus while it was up.
    private func restoreBrowsingFocus() {
        if let f = openedFocus, convo.currentFocus == f {
            convo.setFocus(browsingFocus)
        }
        openedFocus = nil
    }
}

// MARK: - Lightbox (full-screen, swipe between photos, pinch/double-tap zoom)

private struct PhotoLightboxView: View {
    @ObservedObject var model: PhotosModel
    let startID: String
    @EnvironmentObject private var convo: Conversation
    @Environment(\.dismiss) private var dismiss

    @State private var currentID: String
    /// The ONE sheet on this view (Catalyst rule): the forward flow.
    @State private var forwardPhoto: GalleryPhoto?

    private let scarletRose = Color(red: 1, green: 0.35, blue: 0.42)

    init(model: PhotosModel, startID: String) {
        self.model = model
        self.startID = startID
        _currentID = State(initialValue: startID)
    }

    private var current: GalleryPhoto? {
        model.photos.first { $0.id == currentID }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if model.photos.isEmpty {
                // Everything got archived out from under the lightbox.
                Text("No photos left")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.55))
            } else {
                TabView(selection: $currentID) {
                    ForEach(model.photos) { photo in
                        ZoomablePhotoPage(photo: photo)
                            .tag(photo.id)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .ignoresSafeArea()
            }
            VStack {
                topBar
                Spacer()
                bottomBar
            }
        }
        .sheet(item: $forwardPhoto) { photo in
            PhotoForwardFlow(photo: photo)
                .environmentObject(convo)
                .preferredColorScheme(.dark)
        }
        // Paging near the tail keeps the endless scroll flowing here too.
        .onChange(of: currentID) { _, newID in
            let idx = model.photos.firstIndex { $0.id == newID } ?? 0
            if model.photos.count - idx <= 5 {
                Task { await model.loadMore() }
            }
        }
    }

    private var topBar: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(.white.opacity(0.15)))
            }
            Spacer(minLength: 8)
            if let photo = current {
                VStack(alignment: .trailing, spacing: 2) {
                    if !photo.caption.isEmpty {
                        // Per-paragraph bidi (TextDirection.swift): the
                        // caption picks its own direction; the screen never
                        // flips layout direction wholesale.
                        Text(photo.caption)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .multilineTextAlignment(photo.caption.readingAlignment)
                            .environment(\.layoutDirection, photo.caption.layoutDir)
                    }
                    if let date = photo.createdAt {
                        Text(date.formatted(.dateTime.month(.abbreviated).day()))
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
            }
        }
        .padding(.top, 12)
        .padding(.horizontal, 16)
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            if current != nil {
                Button {
                    forwardPhoto = current
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Forward")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(height: 40)
                    .background(Capsule().fill(scarletRose.opacity(0.85)))
                }
                Button {
                    archiveCurrent()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "archivebox")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Remove")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(height: 40)
                    .background(Capsule().fill(.white.opacity(0.14)))
                    .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 1))
                }
            }
        }
        .padding(.bottom, 24)
    }

    /// Archive the photo on screen, then land on its neighbor — or close the
    /// lightbox when it was the last one. Nothing is deleted anywhere.
    private func archiveCurrent() {
        guard let photo = current,
              let idx = model.photos.firstIndex(where: { $0.id == photo.id })
        else { return }
        let neighbor = model.photos.indices.contains(idx + 1)
            ? model.photos[idx + 1].id
            : (idx > 0 ? model.photos[idx - 1].id : nil)
        model.archive(photo)
        if let neighbor {
            currentID = neighbor
        } else {
            dismiss()
        }
    }
}

// MARK: - One zoomable page

/// A single lightbox page: scaledToFit on black, pinch to zoom, double-tap
/// toggles 1x/2.5x, drag pans only while zoomed (so TabView's swipe-paging
/// keeps working at 1x).
private struct ZoomablePhotoPage: View {
    let photo: GalleryPhoto

    @State private var zoom: CGFloat = 1
    @State private var gestureZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var panStart: CGSize = .zero

    var body: some View {
        AsyncImage(url: photo.url) { phase in
            if let image = phase.image {
                image
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(max(zoom * gestureZoom, 1))
                    .offset(offset)
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
        .contentShape(Rectangle())
        .gesture(
            MagnificationGesture()
                .onChanged { value in gestureZoom = value }
                .onEnded { value in
                    zoom = min(max(zoom * value, 1), 5)
                    gestureZoom = 1
                    if zoom <= 1 { withAnimation(.easeOut(duration: 0.15)) { offset = .zero; panStart = .zero } }
                }
        )
        // Pan only while zoomed: the `.subviews` mask disables this gesture at
        // 1x so the TabView's own page-swipe wins.
        .gesture(
            DragGesture()
                .onChanged { g in
                    offset = CGSize(width: panStart.width + g.translation.width,
                                    height: panStart.height + g.translation.height)
                }
                .onEnded { _ in panStart = offset },
            including: zoom > 1 ? .all : .subviews
        )
        .onTapGesture(count: 2) {
            withAnimation(.easeInOut(duration: 0.2)) {
                if zoom > 1 {
                    zoom = 1
                    offset = .zero
                    panStart = .zero
                } else {
                    zoom = 2.5
                }
            }
        }
    }
}

// MARK: - Forward flow (chooser → the existing drafting studio, in ONE sheet)

/// Channel chips — the same four the web forward chooser offers, with its
/// exact wire values and dot colors.
private enum PhotoForwardChannel: String, CaseIterable, Identifiable {
    case email = "email_gmail"
    case whatsapp
    case teams
    case imessage

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .email: return "Email"
        case .whatsapp: return "WhatsApp"
        case .teams: return "Teams"
        case .imessage: return "iMessage"
        }
    }

    var dot: Color {
        switch self {
        case .email: return Color(red: 0.92, green: 0.26, blue: 0.21)      // #ea4335
        case .whatsapp: return Color(red: 0.15, green: 0.83, blue: 0.40)   // #25d366
        case .teams: return Color(red: 0.48, green: 0.51, blue: 0.92)      // #7b83eb
        case .imessage: return Color(red: 0.04, green: 0.58, blue: 0.96)   // #0b93f6
        }
    }
}

/// The forward flow inside ONE sheet presentation: first the chooser
/// (channel + recipient + optional note), then — in place, no second sheet —
/// the existing DraftView drives compose → revise → approve. Content swap
/// instead of dismiss-and-re-present keeps Mac Catalyst's single presenting
/// controller happy. Nothing sends until Ido approves in the draft window.
private struct PhotoForwardFlow: View {
    let photo: GalleryPhoto
    @EnvironmentObject private var convo: Conversation

    /// Set on "Forward" — swaps the chooser for the drafting studio.
    @State private var seed: ChannelDraftSeed?

    var body: some View {
        if let seed {
            DraftView(seed: nil, channelSeed: seed)
                .environmentObject(convo)
        } else {
            PhotoForwardChooser(photo: photo) { channel, recipient, note in
                seed = ChannelDraftSeed(
                    channel: channel.rawValue,
                    recipient: recipient,
                    contextLines: "",
                    instruction: forwardInstruction(
                        recipient: recipient, note: note)
                )
            }
        }
    }

    /// Mirrors the web lightbox's forward instruction word-for-word, plus the
    /// caption (the web carries it in `original`; channel drafts carry
    /// everything in the instruction).
    private func forwardInstruction(recipient: String, note: String) -> String {
        var s = "Forward this photo to \(recipient)."
        if !photo.caption.isEmpty {
            s += " The photo's caption: \(photo.caption)."
        }
        if !note.isEmpty {
            s += " Note from Ido: \(note)"
        }
        s += " Include the image link: \(photo.url.absoluteString)"
        return s
    }
}

/// The chooser card: channel chips, To field, optional note, Forward.
/// Same fields, same gating (channel + recipient required) as the web's
/// shared forward chooser.
private struct PhotoForwardChooser: View {
    let photo: GalleryPhoto
    let onSubmit: (PhotoForwardChannel, String, String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var channel: PhotoForwardChannel?
    @State private var recipient = ""
    @State private var note = ""

    private let scarletRose = Color(red: 1, green: 0.35, blue: 0.42)

    private var canGo: Bool {
        channel != nil
            && !recipient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Forward photo")
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(.white.opacity(0.12)))
                }
            }
            if !photo.caption.isEmpty {
                Text(photo.caption)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(photo.caption.readingAlignment)
                    .environment(\.layoutDirection, photo.caption.layoutDir)
            }
            // Channel chips — horizontally scrollable so all four stay
            // reachable on the narrowest iPhone (the web chooser wraps).
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(PhotoForwardChannel.allCases) { c in
                        chip(c)
                    }
                }
            }
            TextField("To — name, email or number", text: $recipient)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 42)
                .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.07)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.15), lineWidth: 1))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.words)
            TextField("Add a note (optional)…", text: $note, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .lineLimit(2...4)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.07)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.15), lineWidth: 1))
            Button {
                guard let channel else { return }
                onSubmit(channel, recipient.trimmingCharacters(in: .whitespacesAndNewlines),
                         note.trimmingCharacters(in: .whitespacesAndNewlines))
            } label: {
                Text("Forward")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(Capsule().fill(scarletRose.opacity(canGo ? 0.9 : 0.3)))
            }
            .disabled(!canGo)
            Text("Scarlet drafts it first — you review and approve before anything sends.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(ScarletBackground().ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func chip(_ c: PhotoForwardChannel) -> some View {
        Button {
            channel = c
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(c.dot)
                    .frame(width: 8, height: 8)
                Text(c.displayName)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(channel == c
                ? Color(red: 1, green: 0.85, blue: 0.87)
                : .white.opacity(0.65))
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(Capsule().fill(channel == c
                ? scarletRose.opacity(0.18) : .white.opacity(0.06)))
            .overlay(Capsule().stroke(channel == c
                ? scarletRose.opacity(0.55) : .white.opacity(0.14), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
