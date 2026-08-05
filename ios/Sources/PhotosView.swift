import CoreLocation
import Photos
import SwiftUI
import UIKit

/// Photos — a native, on-device camera-roll grid with a full-screen swipe
/// slideshow, forward-to-Scarlet, multi-select, "ask Scarlet about this photo",
/// and offline-robust rendering.
///
/// NAVIGATION (the shape Ido asked for — no bare-nav-bar middle stage):
///   • Grid of square thumbnails (this view). Full-width inside SplitShell's
///     detail column, like InboxView / LibraryView.
///   • Tap a thumbnail → an in-column PAGED slideshow (`PhotoPagerView`): the
///     photo edge-to-edge, swipe LEFT/RIGHT to the next/previous, its own Back
///     capsule (nav bar hidden — never a lone toolbar over the picture). Back →
///     thumbnails. This is close #1 when you came straight from the grid.
///   • Expand → a true full-screen cover (`FullScreenPager`) that covers the
///     sidebar too, for landscape 16:9 viewing; swipe L/R; Close → the in-column
///     pager. So from full screen: Close (→ pager) then Back (→ thumbnails) is
///     "close it, then close it again to be in the thumbnails."
///
/// ACTIONS on the focused photo (and on a multi-selection from the grid):
///   • Forward → uploads the photo(s) and opens the drafting studio on the
///     chosen channel (Amwell email / Gmail) with them attached; WhatsApp is
///     shown but disabled (its Mac bridge can't carry media yet — honest).
///   • Ask Scarlet → uploads the photo and tells her (focus + spoken nudge) to
///     analyze_document, so she can actually see the pixels and talk about it.
///
/// SOURCE — why on-device: the backend's `get_photos` is an async Mac-agent
/// relay; there is no synchronous app-api op that returns a recent-photos grid.
/// `PHPhotoLibrary` / `PHAsset` is the instant, offline-capable source. Reading
/// the library directly needs `NSPhotoLibraryUsageDescription` (in project.yml);
/// until granted, the screen lands honestly on the no-permission state.

// MARK: - Model

@MainActor
final class PhotosModel: ObservableObject {
    /// Authorization outcome that drives which state the screen shows.
    enum Access: Equatable {
        case unknown      // haven't asked yet
        case denied       // denied or restricted — needs Settings
        case limited      // user granted a hand-picked subset
        case full         // full library access
    }

    @Published var assets: [PHAsset] = []
    @Published var access: Access = .unknown
    @Published var loading = false

    /// Bumps on every successful load so the view can re-report ambient focus
    /// with the real photo count (InboxModel / LibraryModel discipline).
    @Published var loadStamp = 0

    /// One caching manager for the whole screen: it keeps decoded thumbnails
    /// warm as the grid scrolls, and is the same handle the viewer uses for the
    /// full-size fetch.
    let imageManager = PHCachingImageManager()

    /// How many recent stills to surface. Bounded on purpose — a grid, not the
    /// entire multi-thousand-photo roll.
    private let fetchLimit = 300

    /// Ask for read authorization, then (if granted) fetch. Safe to call every
    /// time the screen appears — it re-syncs `access` and reloads.
    func requestAndLoad() {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch current {
        case .authorized:
            access = .full
            load()
        case .limited:
            access = .limited
            load()
        case .denied, .restricted:
            access = .denied
            assets = []
        case .notDetermined:
            loading = true
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
                Task { @MainActor in
                    guard let self else { return }
                    switch status {
                    case .authorized: self.access = .full;   self.load()
                    case .limited:    self.access = .limited; self.load()
                    default:          self.access = .denied;  self.loading = false; self.assets = []
                    }
                }
            }
        @unknown default:
            access = .denied
            assets = []
        }
    }

    /// Fetch the most-recent images (stills only), newest first, capped at
    /// `fetchLimit`. Runs the enumeration off the main actor; publishes back on it.
    func load() {
        loading = true
        let limit = fetchLimit
        Task.detached(priority: .userInitiated) {
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            // Stills only — no screenshots filter (Ido wants his actual roll);
            // videos are excluded so the grid stays a photo grid.
            options.predicate = NSPredicate(format: "mediaType == %d",
                                            PHAssetMediaType.image.rawValue)
            options.fetchLimit = limit
            let result = PHAsset.fetchAssets(with: options)
            var out: [PHAsset] = []
            out.reserveCapacity(result.count)
            result.enumerateObjects { asset, _, _ in out.append(asset) }
            await MainActor.run {
                self.assets = out
                self.loading = false
                self.loadStamp += 1
                self.startPrefetch(for: out)
            }
        }
    }

    /// Warm the grid's thumbnails so scrolling stays smooth even offline (and so
    /// a subsequent open has bytes on hand). Bounded to the thumbnail size — the
    /// full-res fetch is separate and on demand.
    func startPrefetch(for assets: [PHAsset]) {
        guard !assets.isEmpty else { return }
        let scale = UIScreen.main.scale
        let side = max(1, UIScreen.main.bounds.width / 3) * scale
        let o = PHImageRequestOptions()
        o.deliveryMode = .opportunistic
        o.isNetworkAccessAllowed = true
        imageManager.startCachingImages(
            for: assets, targetSize: CGSize(width: side, height: side),
            contentMode: .aspectFill, options: o)
    }

    func stopPrefetch() {
        imageManager.stopCachingImagesForAllAssets()
    }

    /// High-quality still for upload (forward / ask). iCloud-optimized originals
    /// are pulled over the network; nil if the bytes truly can't be reached.
    static func fullImage(for asset: PHAsset, manager: PHImageManager) async -> UIImage? {
        await withCheckedContinuation { (cont: CheckedContinuation<UIImage?, Never>) in
            let o = PHImageRequestOptions()
            o.deliveryMode = .highQualityFormat   // single final callback
            o.isNetworkAccessAllowed = true
            o.resizeMode = .exact
            o.isSynchronous = false
            var resumed = false
            manager.requestImage(
                for: asset, targetSize: CGSize(width: 2048, height: 2048),
                contentMode: .aspectFit, options: o
            ) { img, _ in
                if resumed { return }
                resumed = true
                cont.resume(returning: img)
            }
        }
    }
}

/// A pending forward: which channel and which already-uploaded photos. Drives
/// the `.sheet(item:)` that opens the drafting studio.
struct ForwardRequest: Identifiable {
    let id = UUID()
    let channel: String        // "email_outlook" | "email_gmail"
    let uploadIDs: [String]
}

// MARK: - Upload helper (self-contained; mirrors AttachToScarlet's op=doc_upload)

enum PhotoUploader {
    struct UploadError: Error { let text: String }

    /// Downscale → JPEG → op=doc_upload(source:"photos"); returns the upload id
    /// the draft pipeline attaches by. Reuses AttachToScarletButton's static
    /// downscale/JPEG so both paths produce identical bytes.
    static func upload(image: UIImage, source: String = "photos") async throws -> (id: String, title: String) {
        guard let jpeg = AttachToScarletButton.downscaledJPEG(image) else {
            throw UploadError(text: "Couldn't read that photo — try another one.")
        }
        guard jpeg.count <= 15 * 1024 * 1024 else {
            throw UploadError(text: "Too large — up to 15MB.")
        }
        let stamp = AttachToScarletButton.stampFormatter.string(from: Date())
        var comps = URLComponents(url: AppConfig.appAPIURL, resolvingAgainstBaseURL: false)!
        var q = comps.queryItems ?? []
        q.append(URLQueryItem(name: "op", value: "doc_upload"))
        comps.queryItems = q
        var req = URLRequest(url: comps.url ?? AppConfig.appAPIURL)
        req.httpMethod = "POST"
        req.setValue(TokenStore.token ?? "", forHTTPHeaderField: "x-scarlet-token")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "filename": "photo-\(stamp).jpg",
            "mime": "image/jpeg",
            "content_b64": jpeg.base64EncodedString(),
            "source": source,
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let httpOK: Bool = {
            guard let http = resp as? HTTPURLResponse else { return true }
            return (200...299).contains(http.statusCode)
        }()
        guard httpOK, (obj?["ok"] as? Bool) == true, let id = obj?["upload_id"] as? String else {
            throw UploadError(text: (obj?["error"] as? String) ?? "The upload was rejected — try again.")
        }
        return (id, (obj?["title"] as? String) ?? "photo")
    }
}

// MARK: - Photos page (grid)

struct PhotosView: View {
    @StateObject private var model = PhotosModel()
    @EnvironmentObject private var convo: Conversation

    private let scarletRose = Color(red: 1, green: 0.35, blue: 0.42)

    /// Three columns of square thumbnails, a hair of breathing room between —
    /// the familiar camera-roll density, native on every width.
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    // Multi-select (grid) state.
    @State private var selecting = false
    @State private var selection = Set<String>()   // localIdentifiers

    // Forward (from a multi-selection) state.
    @State private var showChannelDialog = false
    @State private var forwardRequest: ForwardRequest?
    @State private var busy = false
    @State private var errorText: String?
    @State private var showError = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                headerBar
                content
            }
            .background(ScarletBackground().ignoresSafeArea())
            // Scarlet lives at the bottom of the LIST screen only — part of its
            // layout, so the pushed viewer structurally replaces it (same as
            // InboxView / LibraryView / ChatsView). Hidden in select mode, where
            // the action bar takes the bottom.
            .safeAreaInset(edge: .bottom) {
                if selecting {
                    selectionActionBar
                } else {
                    ScarletPresenceView(convo: convo)
                        .padding(.vertical, 6)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            // Ambient focus: the grid reports itself on appearance and after
            // every successful load (count changes).
            .onAppear { convo.setFocus(browsingFocus) }
            .onChange(of: model.loadStamp) { _, _ in
                convo.setFocus(browsingFocus)
            }
            // Channel picker for a multi-select forward.
            .confirmationDialog("Forward \(selection.count) photo\(selection.count == 1 ? "" : "s")",
                                isPresented: $showChannelDialog, titleVisibility: .visible) {
                Button("Amwell email") { beginForward(channel: "email_outlook") }
                Button("Gmail") { beginForward(channel: "email_gmail") }
                Button("WhatsApp — not yet", role: .none) {}
                    .disabled(true)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("WhatsApp photo send isn't wired through the Mac bridge yet — use email for now.")
            }
            .sheet(item: $forwardRequest) { req in
                DraftView(seed: nil, forwardChannel: req.channel,
                          attachmentUploadIDs: req.uploadIDs)
                    .environmentObject(convo)
            }
            .overlay {
                if busy {
                    ZStack {
                        Color.black.opacity(0.35).ignoresSafeArea()
                        VStack(spacing: 10) {
                            ProgressView().tint(.white)
                            Text("Uploading…").font(.footnote).foregroundStyle(.white.opacity(0.8))
                        }
                        .padding(22)
                        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
            .alert("Couldn't forward", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorText ?? "Something went wrong — try again.")
            }
        }
        // .task re-runs each time this section is selected → refresh on appear;
        // foreground return re-checks authorization + reloads.
        .task { model.requestAndLoad() }
        .onDisappear { model.stopPrefetch() }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.willEnterForegroundNotification)) { _ in
            model.requestAndLoad()
        }
    }

    // MARK: header (title + Select + refresh)

    private var headerBar: some View {
        HStack(spacing: 12) {
            Text("Photos")
                .font(.system(size: 34, weight: .heavy))
                .foregroundStyle(.white)
            Spacer()
            if !model.assets.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selecting.toggle()
                        if !selecting { selection.removeAll() }
                    }
                } label: {
                    Text(selecting ? "Cancel" : "Select")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(scarletRose)
                }
                .buttonStyle(.plain)
            }
            Button {
                model.requestAndLoad()
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

    // MARK: content states (loading / no-permission / empty / grid)

    @ViewBuilder
    private var content: some View {
        if model.access == .denied {
            noPermission
        } else if model.loading && model.assets.isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                Text("Opening your photos…")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.assets.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.title2).foregroundStyle(.secondary)
                Text(model.access == .limited
                    ? "No photos in the set you shared. Tap Manage to add more."
                    : "No photos yet.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if model.access == .limited {
                    manageLimitedButton
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            grid
        }
    }

    /// Denied / restricted: honest dead-end with the one real fix — Settings.
    private var noPermission: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.rectangle.on.rectangle")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("Scarlet doesn't have access to your photos.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text("Open Settings")
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(Capsule().fill(scarletRose.opacity(0.18)))
                    .overlay(Capsule().stroke(scarletRose.opacity(0.45), lineWidth: 1))
                    .foregroundStyle(scarletRose)
            }
            .buttonStyle(.plain)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Limited-access affordance: reopen the system picker to widen the set.
    private var manageLimitedButton: some View {
        Button {
            presentLimitedPicker()
        } label: {
            Text("Manage")
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Capsule().fill(scarletRose.opacity(0.18)))
                .overlay(Capsule().stroke(scarletRose.opacity(0.45), lineWidth: 1))
                .foregroundStyle(scarletRose)
        }
        .buttonStyle(.plain)
    }

    private var grid: some View {
        ScrollView {
            // "Limited" banner so it's obvious the grid is a subset, with a way
            // to widen it — never a silent partial roll.
            if model.access == .limited {
                Button {
                    presentLimitedPicker()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "photo.stack")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Showing the photos you shared · Manage")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(scarletRose)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(scarletRose.opacity(0.10))
                }
                .buttonStyle(.plain)
            }
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(Array(model.assets.enumerated()), id: \.element.localIdentifier) { pair in
                    let asset = pair.element
                    if selecting {
                        Button {
                            toggle(asset.localIdentifier)
                        } label: {
                            selectableCell(asset)
                        }
                        .buttonStyle(.plain)
                    } else {
                        NavigationLink {
                            PhotoPagerView(assets: model.assets, startIndex: pair.offset,
                                           imageManager: model.imageManager)
                                // Mac Catalyst drops @EnvironmentObject across the
                                // NavigationLink→destination boundary; re-inject like
                                // every other push site in the app.
                                .environmentObject(convo)
                        } label: {
                            PhotoThumbnail(asset: asset, imageManager: model.imageManager)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        .scrollContentBackground(.hidden)
    }

    /// A grid cell in select mode: the thumbnail with a check overlay.
    private func selectableCell(_ asset: PHAsset) -> some View {
        let picked = selection.contains(asset.localIdentifier)
        return PhotoThumbnail(asset: asset, imageManager: model.imageManager)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(picked ? scarletRose : .white.opacity(0.85))
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .padding(6)
            }
            .overlay(picked ? scarletRose.opacity(0.22) : Color.clear)
    }

    /// The bottom bar shown in select mode: Forward (N).
    private var selectionActionBar: some View {
        HStack {
            Text("\(selection.count) selected")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
            Spacer()
            Button {
                showChannelDialog = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrowshape.turn.up.right.fill")
                    Text("Forward")
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18).padding(.vertical, 10)
                .background(Capsule().fill(selection.isEmpty ? Color.white.opacity(0.12)
                                                             : scarletRose.opacity(0.9)))
            }
            .buttonStyle(.plain)
            .disabled(selection.isEmpty || busy)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private func toggle(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    private func presentLimitedPicker() {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        if let root = scene?.keyWindow?.rootViewController {
            PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: root)
        }
    }

    /// Upload every selected photo, then open the drafting studio with them
    /// attached. Bounded concurrency keeps memory sane on a big selection.
    private func beginForward(channel: String) {
        let chosen = model.assets.filter { selection.contains($0.localIdentifier) }
        guard !chosen.isEmpty else { return }
        busy = true
        // @MainActor: this Task mutates @State and drives .sheet presentation
        // after its awaits — those MUST land on the main thread (the heavy JPEG
        // encode still runs off-main inside the nonisolated PhotoUploader.upload).
        Task { @MainActor in
            var ids: [String] = []
            var firstError: String?
            for asset in chosen {
                guard let img = await PhotosModel.fullImage(for: asset, manager: model.imageManager) else {
                    firstError = firstError ?? "One photo's original couldn't be downloaded (it may be in iCloud and offline)."
                    continue
                }
                do {
                    let up = try await PhotoUploader.upload(image: img)
                    ids.append(up.id)
                } catch let e as PhotoUploader.UploadError {
                    firstError = firstError ?? e.text
                } catch {
                    firstError = firstError ?? "Upload failed — check your connection."
                }
            }
            busy = false
            if ids.isEmpty {
                errorText = firstError ?? "Couldn't upload the photos."
                showError = true
                return
            }
            // Leave select mode; open the draft on the chosen channel.
            selecting = false
            selection.removeAll()
            forwardRequest = ForwardRequest(channel: channel, uploadIDs: ids)
        }
    }

    // MARK: ambient focus

    private var browsingFocus: String {
        let count = model.assets.count
        if model.access == .denied {
            return "[FOCUS] Ido is on the Photos screen, but Scarlet has no photo-library access yet. No photo is open."
        }
        return "[FOCUS] Ido is browsing his on-device Photos grid (\(count) recent photo\(count == 1 ? "" : "s")). No single photo is open."
    }
}

// MARK: - Thumbnail (square, async-loaded from the asset)

/// One grid cell: a square that fills with the asset's thumbnail once the image
/// manager delivers it. Local PHAsset via PHImageManager (not a remote URL).
struct PhotoThumbnail: View {
    let asset: PHAsset
    let imageManager: PHCachingImageManager

    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.white.opacity(0.04)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ProgressView()
                        .tint(.white.opacity(0.5))
                        .scaleEffect(0.7)
                }
            }
            .frame(width: geo.size.width, height: geo.size.width)
            .clipped()
            .contentShape(Rectangle())
            .task(id: asset.localIdentifier) {
                load(side: geo.size.width)
            }
        }
        // Square cells: pin the aspect so GeometryReader gives a real height.
        .aspectRatio(1, contentMode: .fit)
    }

    private func load(side: CGFloat) {
        // Cancel a stale request if the cell got recycled to a new asset.
        if let requestID { imageManager.cancelImageRequest(requestID) }
        let scale = UIScreen.main.scale
        let target = CGSize(width: max(1, side) * scale, height: max(1, side) * scale)
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic   // fast low-res first, sharp follows
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true    // pull iCloud-optimized originals
        requestID = imageManager.requestImage(
            for: asset, targetSize: target, contentMode: .aspectFill, options: options
        ) { result, _ in
            // PHImageManager doesn't guarantee a main-thread callback — hop before
            // touching @State.
            if let result { DispatchQueue.main.async { self.image = result } }
        }
    }
}

// MARK: - Zoomable, offline-robust single photo (used by both pagers)

/// One page in the slideshow: the full photo on black, best-available-first
/// then upgraded to full quality, pinch/double-tap zoom, and an honest chip when
/// only a lower-quality (iCloud-unreachable) copy is on hand.
struct PhotoPage: View {
    let asset: PHAsset
    let imageManager: PHCachingImageManager

    @State private var image: UIImage?
    @State private var degraded = false     // showing a fast/low-res copy
    @State private var hiResUnavailable = false  // original couldn't be reached
    @State private var failed = false
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in scale = min(max(lastScale * value, 1), 5) }
                            .onEnded { _ in lastScale = scale }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            scale = scale > 1 ? 1 : 2.5
                            lastScale = scale
                        }
                    }
                if degraded && hiResUnavailable {
                    VStack {
                        Spacer()
                        Text("Showing a lower-quality copy — the original is in iCloud")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(.black.opacity(0.5), in: Capsule())
                            .padding(.bottom, 24)
                    }
                }
            } else if failed {
                VStack(spacing: 8) {
                    Image(systemName: "photo")
                        .font(.system(size: 36))
                    Text("Couldn't load this photo")
                        .font(.footnote)
                }
                .foregroundStyle(.white.opacity(0.55))
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: asset.localIdentifier) { await load() }
    }

    private func load() async {
        // Reset for a recycled page.
        scale = 1; lastScale = 1; degraded = false; hiResUnavailable = false; failed = false
        let bound = UIScreen.main.bounds
        let s = UIScreen.main.scale
        let target = CGSize(width: bound.width * s, height: bound.height * s)

        // Step 1 — instant local copy, no network — may be degraded or absent.
        let fast = PHImageRequestOptions()
        fast.deliveryMode = .fastFormat
        fast.isNetworkAccessAllowed = false
        fast.resizeMode = .fast
        imageManager.requestImage(for: asset, targetSize: target,
                                  contentMode: .aspectFit, options: fast) { result, info in
            // PHImageManager may call back off-main — hop before touching @State.
            DispatchQueue.main.async {
                if let result, self.image == nil {
                    self.image = result
                    self.degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? true
                }
            }
        }

        // Step 2 — full quality, network allowed — replaces the fast copy when it lands.
        let hi = PHImageRequestOptions()
        hi.deliveryMode = .highQualityFormat
        hi.isNetworkAccessAllowed = true
        hi.resizeMode = .exact
        imageManager.requestImage(for: asset, targetSize: target,
                                  contentMode: .aspectFit, options: hi) { result, info in
            let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            // PHImageManager may call back off-main — hop before touching @State.
            DispatchQueue.main.async {
                if let result {
                    self.image = result
                    if !isDegraded { self.degraded = false; self.hiResUnavailable = false }
                } else if info?[PHImageErrorKey] != nil {
                    // The original couldn't be reached. If we have the fast copy,
                    // keep showing it and say so; otherwise it's a hard failure.
                    if self.image == nil { self.failed = true }
                    else { self.hiResUnavailable = true }
                }
            }
        }
    }
}

// MARK: - In-column paged slideshow (level 1 — pushed from the grid)

/// The photo, edge-to-edge, in the detail column. Swipe LEFT/RIGHT to move
/// through the roll (a real slideshow). Its own Back capsule returns to the
/// thumbnails (nav bar hidden — never a lone toolbar over the picture). Expand
/// goes to a true full-screen cover; Forward / Ask act on the current photo.
struct PhotoPagerView: View {
    let assets: [PHAsset]
    let startIndex: Int
    let imageManager: PHCachingImageManager

    @EnvironmentObject private var convo: Conversation
    @Environment(\.dismiss) private var dismiss

    @State private var currentID: String = ""
    @State private var showFullScreen = false

    // Forward / ask / progress.
    @State private var showChannelDialog = false
    @State private var forwardRequest: ForwardRequest?
    @State private var busy = false
    @State private var busyLabel = "Uploading…"
    @State private var errorText: String?
    @State private var showError = false
    /// Set when Forward was invoked from full screen — after the cover closes we
    /// open the channel picker on the parent (never a sheet over a cover).
    @State private var forwardAfterFullScreen = false

    private let scarletRose = Color(red: 1, green: 0.35, blue: 0.42)

    private var currentAsset: PHAsset {
        assets.first { $0.localIdentifier == currentID } ?? assets[min(startIndex, assets.count - 1)]
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            TabView(selection: $currentID) {
                ForEach(assets, id: \.localIdentifier) { asset in
                    PhotoPage(asset: asset, imageManager: imageManager)
                        .tag(asset.localIdentifier)
                        .ignoresSafeArea()
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            controlsOverlay
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            if currentID.isEmpty { currentID = assets[min(startIndex, assets.count - 1)].localIdentifier }
            convo.setFocus(photoFocus(currentAsset))
        }
        .onChange(of: currentID) { _, _ in
            convo.setFocus(photoFocus(currentAsset))
        }
        .onDisappear {
            if convo.currentFocus?.hasPrefix("[FOCUS] Ido is viewing a single photo") == true {
                convo.setFocus("[FOCUS] Ido is browsing his on-device Photos grid. No single photo is open.")
            }
        }
        // True full-screen cover (covers the sidebar too, for 16:9 landscape).
        .fullScreenCover(isPresented: $showFullScreen, onDismiss: {
            if forwardAfterFullScreen {
                forwardAfterFullScreen = false
                showChannelDialog = true
            }
        }) {
            FullScreenPager(assets: assets, currentID: $currentID,
                            imageManager: imageManager,
                            onForward: {
                                forwardAfterFullScreen = true
                                showFullScreen = false
                            })
        }
        .confirmationDialog("Forward this photo", isPresented: $showChannelDialog,
                            titleVisibility: .visible) {
            Button("Amwell email") { beginForward(channel: "email_outlook") }
            Button("Gmail") { beginForward(channel: "email_gmail") }
            Button("WhatsApp — not yet", role: .none) {}.disabled(true)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("WhatsApp photo send isn't wired through the Mac bridge yet — use email for now.")
        }
        .sheet(item: $forwardRequest) { req in
            DraftView(seed: nil, forwardChannel: req.channel,
                      attachmentUploadIDs: req.uploadIDs)
                .environmentObject(convo)
        }
        .overlay {
            if busy {
                ZStack {
                    Color.black.opacity(0.4).ignoresSafeArea()
                    VStack(spacing: 10) {
                        ProgressView().tint(.white)
                        Text(busyLabel).font(.footnote).foregroundStyle(.white.opacity(0.85))
                    }
                    .padding(22)
                    .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
        .alert("Something went wrong", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "Try again.")
        }
    }

    // MARK: overlay controls (Back · Ask · Forward · Expand)

    private var controlsOverlay: some View {
        HStack(spacing: 10) {
            // Own Back button — the guaranteed way out (list root hides the nav
            // bar; Mac Catalyst has no edge-swipe-back).
            Button { dismiss() } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Photos").font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Capsule().fill(Color.black.opacity(0.5)))
            }
            Spacer()
            circleButton("bubble.left.and.text.bubble.right") { askScarlet() }
            circleButton("arrowshape.turn.up.right") { showChannelDialog = true }
            circleButton("arrow.up.left.and.arrow.down.right") { showFullScreen = true }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }

    private func circleButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(Circle().fill(Color.black.opacity(0.5)))
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    // MARK: actions

    private func beginForward(channel: String) {
        let asset = currentAsset
        busy = true; busyLabel = "Uploading…"
        // @MainActor: mutates @State + drives .sheet after awaits — must be main.
        Task { @MainActor in
            guard let img = await PhotosModel.fullImage(for: asset, manager: imageManager) else {
                busy = false
                errorText = "That photo's original couldn't be downloaded (it may be in iCloud and offline)."
                showError = true
                return
            }
            do {
                let up = try await PhotoUploader.upload(image: img)
                busy = false
                forwardRequest = ForwardRequest(channel: channel, uploadIDs: [up.id])
            } catch let e as PhotoUploader.UploadError {
                busy = false; errorText = e.text; showError = true
            } catch {
                busy = false; errorText = "Upload failed — check your connection."; showError = true
            }
        }
    }

    /// Give Scarlet the actual pixels: upload the photo, then tell her (focus +
    /// spoken nudge) to analyze_document — the same contract AttachToScarlet uses.
    private func askScarlet() {
        let asset = currentAsset
        busy = true; busyLabel = "Sharing with Scarlet…"
        // @MainActor: mutates @State + calls convo (main-actor) after awaits.
        Task { @MainActor in
            guard let img = await PhotosModel.fullImage(for: asset, manager: imageManager) else {
                busy = false
                errorText = "That photo's original couldn't be downloaded (it may be in iCloud and offline)."
                showError = true
                return
            }
            do {
                let up = try await PhotoUploader.upload(image: img)
                busy = false
                convo.setFocus("[FOCUS] Ido opened a photo and shared it with you (uploaded as \(up.title)). Use analyze_document to see it — it is ALREADY uploaded; do not ask him to send it again.")
                convo.sendSystemNudge("[SYSTEM] Ido shared the photo he's viewing (\(up.title)). Call analyze_document to look at it, then say what you see in a few words and ask what he'd like to do with it.", ensureLive: true)
            } catch let e as PhotoUploader.UploadError {
                busy = false; errorText = e.text; showError = true
            } catch {
                busy = false; errorText = "Upload failed — check your connection."; showError = true
            }
        }
    }

    private func photoFocus(_ asset: PHAsset) -> String {
        let when = Self.dateFormat.string(from: asset.creationDate ?? Date())
        return "[FOCUS] Ido is viewing a single photo full-screen, taken \(when). "
            + "Any request like 'what's in this', 'describe it', 'תתארי', 'forward it' refers to THIS photo on his screen."
    }

    private static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

// MARK: - True full-screen slideshow (level 2 — cover over the whole window)

/// The immersive slideshow: the photo over the entire window (sidebar included),
/// swipe LEFT/RIGHT, pinch to zoom. Close returns to the in-column pager — so
/// from here, Close then Back lands on the thumbnails. Forward hands off to the
/// parent (which opens the channel picker after this cover closes) rather than
/// stacking a sheet on a cover — Mac Catalyst can present only one at a time.
struct FullScreenPager: View {
    let assets: [PHAsset]
    @Binding var currentID: String
    let imageManager: PHCachingImageManager
    var onForward: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            TabView(selection: $currentID) {
                ForEach(assets, id: \.localIdentifier) { asset in
                    PhotoPage(asset: asset, imageManager: imageManager)
                        .tag(asset.localIdentifier)
                        .ignoresSafeArea()
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Color.black.opacity(0.5)))
                }
                .buttonStyle(.plain)
                Spacer()
                Button { onForward() } label: {
                    Image(systemName: "arrowshape.turn.up.right")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Color.black.opacity(0.5)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
        }
    }
}

// MARK: - Natural-language photo dispatch
// "send the photos from Jerusalem this week to Phyllis" — from any screen, by
// voice or chat. The voice agent resolves the phrase into {place, since, until,
// recipient, channel} and calls the send_photos client tool; Conversation.runTool
// routes it here. Selection runs ON-DEVICE (that's where the library is), the
// matches upload, and they ride the same photo-attachment draft pipeline the
// Photos "Forward" button uses. Email works today; WhatsApp/iMessage media is
// still blocked at the Mac bridge and is refused honestly (never faked).

enum PhotoDispatch {
    struct Query { var since: Date?; var until: Date?; var place: String?; var limit: Int }

    /// Select images by date range + optional place. One forward-geocode of the
    /// place → a radius filter over each asset's GPS. Newest first, capped.
    /// Returns `placeResolved=false` when a place was given but couldn't be
    /// geocoded (so the caller refuses rather than sending the wrong photos).
    static func select(_ q: Query) async -> (assets: [PHAsset], placeResolved: Bool) {
        if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined {
            _ = await withCheckedContinuation { (c: CheckedContinuation<PHAuthorizationStatus, Never>) in
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { c.resume(returning: $0) }
            }
        }
        let opts = PHFetchOptions()
        var preds: [NSPredicate] = [NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)]
        if let s = q.since { preds.append(NSPredicate(format: "creationDate >= %@", s as NSDate)) }
        if let u = q.until { preds.append(NSPredicate(format: "creationDate <= %@", u as NSDate)) }
        opts.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: preds)
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: opts)
        var assets: [PHAsset] = []
        result.enumerateObjects { a, _, _ in assets.append(a) }

        var placeResolved = true
        if let place = q.place, !place.trimmingCharacters(in: .whitespaces).isEmpty {
            if let center = await geocode(place) {
                let radius: CLLocationDistance = 30_000   // ~30 km around the place
                assets = assets.filter { $0.location.map { $0.distance(from: center) <= radius } ?? false }
            } else {
                placeResolved = false
                assets = []   // can't honor a place we couldn't resolve — empty beats wrong
            }
        }
        return (Array(assets.prefix(max(1, q.limit))), placeResolved)
    }

    static func geocode(_ place: String) async -> CLLocation? {
        await withCheckedContinuation { (c: CheckedContinuation<CLLocation?, Never>) in
            CLGeocoder().geocodeAddressString(place) { marks, _ in
                c.resume(returning: marks?.first?.location)
            }
        }
    }
}

/// Execute the send_photos tool on-device and return a compact JSON result the
/// voice agent reads back. Never sends anything itself — it opens a draft
/// (email) with the photos attached; Ido approves it like any other draft.
@MainActor
func handleSendPhotos(_ params: [String: Any]) async -> String {
    func j(_ o: [String: Any]) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: o) else { return "{}" }
        return String(data: d, encoding: .utf8) ?? "{}"
    }
    let recipient = (params["recipient"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    var channel = (params["channel"] as? String ?? "email_outlook").lowercased()
    if ["email", "outlook", "amwell"].contains(channel) { channel = "email_outlook" }
    if channel == "gmail" { channel = "email_gmail" }
    let place = (params["place"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let limitRaw = (params["limit"] as? Int) ?? Int((params["limit"] as? String) ?? "") ?? 20
    let limit = min(max(limitRaw, 1), 30)
    let iso = ISO8601DateFormatter()
    func parse(_ v: Any?) -> Date? { (v as? String).flatMap { iso.date(from: $0) } }
    let since = parse(params["since"]); let until = parse(params["until"])

    guard !recipient.isEmpty else {
        return j(["ok": false, "reason": "no_recipient", "note": "Ask Ido who to send them to."])
    }

    let (assets, placeResolved) = await PhotoDispatch.select(
        .init(since: since, until: until, place: place, limit: limit))
    if let place, !place.isEmpty, !placeResolved {
        return j(["ok": false, "reason": "place_unresolved",
                  "note": "Couldn't locate '\(place)'. Ask Ido to name the place differently, or drop it."])
    }
    if assets.isEmpty {
        return j(["ok": false, "reason": "no_matches", "found": 0,
                  "note": "No photos matched that place/time. Tell Ido nothing was found."])
    }
    if channel == "whatsapp" || channel == "imessage" {
        let ch = channel == "whatsapp" ? "WhatsApp" : "iMessage"
        return j(["ok": false, "reason": "channel_media_unsupported", "found": assets.count, "channel": channel,
                  "note": "Found \(assets.count) photos, but \(ch) photo sending isn't wired yet. Offer to EMAIL them to \(recipient) — call send_photos again with channel email_outlook or email_gmail."])
    }

    var ids: [String] = []
    for a in assets {
        if let img = await PhotosModel.fullImage(for: a, manager: PHImageManager.default()),
           let up = try? await PhotoUploader.upload(image: img) {
            ids.append(up.id)
        }
    }
    if ids.isEmpty {
        return j(["ok": false, "reason": "upload_failed",
                  "note": "Couldn't upload the photos — check the connection and try again."])
    }

    guard let draftId = await composePhotoDraft(channel: channel, recipient: recipient, uploadIDs: ids) else {
        return j(["ok": false, "reason": "compose_failed", "note": "Couldn't open the draft — try again."])
    }
    // Open the draft window now (the app's backstop poll is the fallback).
    NotificationCenter.default.post(name: .scarletVoiceDraftIntent,
        object: ["channel": channel, "recipient": recipient, "instruction": ""])
    NotificationCenter.default.post(name: .scarletVoiceDraftStarted, object: draftId)

    let n = ids.count
    let tail = channel == "email_outlook"
        ? "Amwell is drafts-only — he taps Send in the window."
        : "He says 'send it' or taps Send."
    return j(["ok": true, "found": n, "channel": channel, "recipient": recipient,
              "note": "Drafted \(n) photo\(n == 1 ? "" : "s") to \(recipient) with them attached; the window is open. \(tail)"])
}

/// POST op=draft_compose with the uploaded photos as attachments → draft id.
private func composePhotoDraft(channel: String, recipient: String, uploadIDs: [String]) async -> String? {
    var comps = URLComponents(url: AppConfig.appAPIURL, resolvingAgainstBaseURL: false)!
    var q = comps.queryItems ?? []
    q.append(URLQueryItem(name: "op", value: "draft_compose"))
    comps.queryItems = q
    var req = URLRequest(url: comps.url ?? AppConfig.appAPIURL)
    req.httpMethod = "POST"
    req.setValue(TokenStore.token ?? "", forHTTPHeaderField: "x-scarlet-token")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let body: [String: Any] = [
        "channel": channel, "recipient": recipient,
        "instruction": "Write a brief, warm cover note from Ido to accompany the attached photos.",
        "attachment_upload_ids": uploadIDs,
    ]
    req.httpBody = try? JSONSerialization.data(withJSONObject: body)
    guard let (data, _) = try? await URLSession.shared.data(for: req),
          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let id = obj["draft_id"] as? String, !id.isEmpty else { return nil }
    return id
}
