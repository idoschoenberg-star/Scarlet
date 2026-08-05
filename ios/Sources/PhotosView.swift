import Photos
import SwiftUI
import UIKit

/// Photos — a native, on-device recent-photos grid. Ido's own camera roll,
/// read straight from the Photos library on the phone/iPad/Mac, shown as a
/// scrollable grid of square thumbnails; tapping one pushes a full-screen
/// viewer IN THE SAME COLUMN (a NavigationStack push — never a `.sheet`, which
/// is the sidebar-covering bug we're killing elsewhere).
///
/// SOURCE — why on-device and not the server: the backend's `get_photos` is an
/// asynchronous Mac-agent relay (it filters Apple Photos on the Mac and files
/// results into Drive / app chat / the Gallery over ~a minute); there is no
/// synchronous app-api op that returns a recent-photos grid. The honest,
/// instant, offline-capable source for "show me my recent photos" is therefore
/// `PHPhotoLibrary` / `PHAsset` on the device itself.
///
/// PERMISSION CAVEAT: reading the library directly needs
/// `NSPhotoLibraryUsageDescription` in Info.plist (unlike the `PHPickerView`
/// used by AttachToScarlet, which needs no permission). That key must be added
/// to `ios/project.yml` under `info.properties` before this screen can load
/// photos — until then it lands honestly on the no-permission state. This view
/// requests read authorization on appear and handles every authorization
/// outcome (not-determined, denied/restricted, limited, full) plainly.
///
/// Self-contained `NavigationStack` (mirrors InboxView / LibraryView) so it
/// renders full-width inside SplitShell's detail column, and its grid→viewer
/// push IS the list-pane→reading-pane flow at iPad/Mac width.

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
    /// warm as the grid scrolls, and is the same handle the detail viewer uses
    /// for the full-size fetch.
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
            }
        }
    }
}

// MARK: - Photos page

struct PhotosView: View {
    @StateObject private var model = PhotosModel()
    @EnvironmentObject private var convo: Conversation

    private let scarletRose = Color(red: 1, green: 0.35, blue: 0.42)

    /// Three columns of square thumbnails, a hair of breathing room between —
    /// the familiar camera-roll density, native on every width.
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                headerBar
                content
            }
            .background(ScarletBackground().ignoresSafeArea())
            // Scarlet lives at the bottom of the LIST screen only — part of its
            // layout, so the pushed viewer structurally replaces it (same as
            // InboxView / LibraryView / ChatsView).
            .safeAreaInset(edge: .bottom) {
                ScarletPresenceView(convo: convo)
                    .padding(.vertical, 6)
            }
            .toolbar(.hidden, for: .navigationBar)
            // Ambient focus: the grid reports itself on appearance and after
            // every successful load (count changes).
            .onAppear { convo.setFocus(browsingFocus) }
            .onChange(of: model.loadStamp) { _, _ in
                convo.setFocus(browsingFocus)
            }
        }
        // .task re-runs each time this section is selected → refresh on appear;
        // foreground return re-checks authorization + reloads.
        .task { model.requestAndLoad() }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.willEnterForegroundNotification)) { _ in
            model.requestAndLoad()
        }
    }

    // MARK: header (big heavy title + refresh, matching LibraryView)

    private var headerBar: some View {
        HStack(spacing: 12) {
            Text("Photos")
                .font(.system(size: 34, weight: .heavy))
                .foregroundStyle(.white)
            Spacer()
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
            let scene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
            if let root = scene?.keyWindow?.rootViewController {
                PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: root)
            }
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
                    let scene = UIApplication.shared.connectedScenes
                        .compactMap { $0 as? UIWindowScene }
                        .first { $0.activationState == .foregroundActive }
                    if let root = scene?.keyWindow?.rootViewController {
                        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: root)
                    }
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
                ForEach(model.assets, id: \.localIdentifier) { asset in
                    NavigationLink {
                        PhotoFullView(asset: asset, imageManager: model.imageManager)
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
            .padding(.horizontal, 2)
        }
        .scrollContentBackground(.hidden)
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

/// One grid cell: a square that fills with the asset's thumbnail once the
/// image manager delivers it. Mirrors WAPhotoView's load-states (placeholder →
/// image → error) but for a LOCAL PHAsset via PHImageManager rather than a
/// remote URL via AsyncImage.
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
            if let result { self.image = result }
        }
    }
}

// MARK: - Full-screen viewer (in-column push, NEVER a sheet)

/// The reading pane for one photo: full-size image on black, pinch-to-zoom,
/// its own drawn Back button (the list root hides the nav bar and Mac Catalyst
/// has no edge-swipe-back, so — app-wide rule — a reader must carry its own
/// way out). Loads the high-quality image via the shared caching manager.
struct PhotoFullView: View {
    let asset: PHAsset
    let imageManager: PHCachingImageManager

    @EnvironmentObject private var convo: Conversation
    @Environment(\.dismiss) private var dismiss

    @State private var image: UIImage?
    @State private var failed = false
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1

    private let scarletRose = Color(red: 1, green: 0.35, blue: 0.42)

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                scale = min(max(lastScale * value, 1), 5)
                            }
                            .onEnded { _ in lastScale = scale }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            scale = scale > 1 ? 1 : 2.5
                            lastScale = scale
                        }
                    }
                    .ignoresSafeArea()
            } else if failed {
                VStack(spacing: 8) {
                    Image(systemName: "photo")
                        .font(.system(size: 36))
                    Text("Couldn't load this photo")
                        .font(.footnote)
                }
                .foregroundStyle(.white.opacity(0.55))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Own Back button — the guaranteed way out (see doc above).
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
            .padding(.top, 12)
            .padding(.leading, 12)
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .task { load() }
        .onAppear { convo.setFocus(photoFocus) }
        .onDisappear {
            if convo.currentFocus == photoFocus {
                convo.setFocus("[FOCUS] Ido is browsing his on-device Photos grid. No single photo is open.")
            }
        }
    }

    private func load() {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.resizeMode = .exact
        // Cap the fetch to a screen-sized render — full 12MP originals are
        // needless memory for on-screen viewing, and PhotosKit downsamples for us.
        let bound = UIScreen.main.bounds
        let scaleFactor = UIScreen.main.scale
        let target = CGSize(width: bound.width * scaleFactor,
                            height: bound.height * scaleFactor)
        imageManager.requestImage(
            for: asset, targetSize: target, contentMode: .aspectFit, options: options
        ) { result, info in
            if let result {
                self.image = result
            } else if (info?[PHImageErrorKey]) != nil {
                self.failed = true
            }
        }
    }

    /// Ambient focus while a single photo is open — dated so Scarlet can speak
    /// to "this photo" meaningfully.
    private var photoFocus: String {
        let when = Self.dateFormat.string(from: asset.creationDate ?? Date())
        return "[FOCUS] Ido is viewing a single photo full-screen, taken \(when). "
            + "Any request like 'what's in this', 'describe it', 'תתארי' refers to THIS photo on his screen."
    }

    private static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
