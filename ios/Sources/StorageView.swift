import Photos
import SwiftUI
import UIKit

/// Storage — an on-device usage manager, opened from Settings. It shows how much
/// space each media category is using (Photos, device Videos, and the app's
/// downloaded clips), and lets Ido reclaim space:
///
///   • "Move photos to online mode" — the SAFE, non-destructive path. It never
///     deletes from the library (deleting a photo removes it from iCloud too,
///     which is NOT "keep it online"). Instead it explains that iOS's own
///     "Optimize iPhone Storage" keeps full-res originals in iCloud and shrinks
///     the local copies, and points at Settings. A backend op is described in
///     the integrator notes if Scarlet should ever guarantee an online backup
///     before eviction (op=storage_mode) — but nothing here can lose a photo.
///
///   • "Delete downloaded clips" — fully implemented and safe: it removes only
///     the app's own downloaded clip files (ClipStore), never the user's Photos.
///
/// Everything destructive is gated behind a confirmation. Photo/asset size
/// summation walks PHAssetResource on a background queue and hops to the main
/// actor to publish — never on the main thread.

// MARK: - Model

@MainActor
final class StorageModel: ObservableObject {
    @Published var photosBytes: Int64 = 0
    @Published var photosCount = 0
    @Published var videosBytes: Int64 = 0
    @Published var videosCount = 0
    @Published var clipsBytes: Int64 = 0
    @Published var clipsCount = 0

    @Published var computing = false
    /// Whether the photo library is readable (drives the "grant access" hint on
    /// the Photos row without blocking the clip totals, which are always local).
    @Published var photoAccess = false

    /// Compute all category sizes. Local clip totals are cheap; the photo/video
    /// walk is heavy, so it runs off the main actor and publishes back on it.
    func compute() {
        computing = true
        Task.detached(priority: .utility) {
            // 1) Local downloaded clips — fast, always available.
            let cBytes = ClipStore.totalBytes()
            let cCount = ClipStore.count()
            await MainActor.run {
                self.clipsBytes = cBytes
                self.clipsCount = cCount
            }

            // 2) Photo library — needs authorization.
            var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            if status == .notDetermined {
                status = await withCheckedContinuation { cont in
                    PHPhotoLibrary.requestAuthorization(for: .readWrite) { cont.resume(returning: $0) }
                }
            }
            let authorized = status == .authorized || status == .limited
            await MainActor.run { self.photoAccess = authorized }
            guard authorized else {
                await MainActor.run { self.computing = false }
                return
            }
            let sums = Self.sumLibrary()
            await MainActor.run {
                self.photosBytes = sums.photoBytes
                self.photosCount = sums.photoCount
                self.videosBytes = sums.videoBytes
                self.videosCount = sums.videoCount
                self.computing = false
            }
        }
    }

    /// Refresh only the clip totals after a delete (no need to re-walk photos).
    func refreshClips() {
        Task.detached(priority: .utility) {
            let cBytes = ClipStore.totalBytes()
            let cCount = ClipStore.count()
            await MainActor.run {
                self.clipsBytes = cBytes
                self.clipsCount = cCount
            }
        }
    }

    /// Delete the app's downloaded clips; returns count for the caller's message.
    @discardableResult
    func deleteDownloadedClips() -> Int {
        let removed = ClipStore.deleteAll()
        refreshClips()
        return removed
    }

    struct LibrarySums {
        var photoBytes: Int64 = 0
        var photoCount = 0
        var videoBytes: Int64 = 0
        var videoCount = 0
    }

    /// Best-effort byte size of a single PHAssetResource. `fileSize` is a
    /// KVC-only key with no public accessor; on an OS where it isn't
    /// KVC-accessible, `value(forKey:)` throws an uncatchable
    /// NSUnknownKeyException rather than returning nil. Guard with
    /// `responds(to:)` so an unavailable key contributes 0 instead of crashing.
    nonisolated static func resourceFileSize(_ res: PHAssetResource) -> Int64 {
        guard res.responds(to: NSSelectorFromString("fileSize")) else { return 0 }
        if let n = res.value(forKey: "fileSize") as? NSNumber {
            return n.int64Value
        }
        return 0
    }

    /// Sum PHAssetResource file sizes for images and videos. Runs OFF the main
    /// actor (nonisolated static) — the enumeration can touch thousands of assets.
    nonisolated static func sumLibrary() -> LibrarySums {
        func sum(_ mediaType: PHAssetMediaType) -> (Int64, Int) {
            let opts = PHFetchOptions()
            opts.predicate = NSPredicate(format: "mediaType == %d", mediaType.rawValue)
            let result = PHAsset.fetchAssets(with: opts)
            var bytes: Int64 = 0
            var count = 0
            result.enumerateObjects { asset, _, _ in
                count += 1
                for res in PHAssetResource.assetResources(for: asset) {
                    // `fileSize` is a PRIVATE, KVC-only key on PHAssetResource —
                    // it has no public property. Calling value(forKey:) blindly
                    // raises an uncatchable NSUnknownKeyException on any OS where
                    // the key isn't KVC-accessible (it does NOT return nil), which
                    // would crash the whole size sweep. Probe responds(to:) first
                    // and treat the size as best-effort (contribute 0 on failure).
                    bytes += resourceFileSize(res)
                }
            }
            return (bytes, count)
        }
        var out = LibrarySums()
        let images = sum(.image)
        out.photoBytes = images.0; out.photoCount = images.1
        let videos = sum(.video)
        out.videoBytes = videos.0; out.videoCount = videos.1
        return out
    }
}

// MARK: - View

struct StorageView: View {
    @StateObject private var model = StorageModel()

    private let scarletRose = Color(red: 1, green: 0.35, blue: 0.42)
    private let paper = Color(red: 0.96, green: 0.94, blue: 0.94)

    // Confirmations (alerts/dialogs — never sheets, so the one-.sheet rule is moot).
    @State private var showClearClips = false
    @State private var showPhotosOnline = false
    @State private var toast: String?

    /// Bar colors per category, so the proportions read at a glance.
    private let photoColor = Color(red: 0.36, green: 0.62, blue: 1.0)
    private let videoColor = Color(red: 0.85, green: 0.45, blue: 0.30)
    private let clipColor = Color(red: 1, green: 0.35, blue: 0.42)

    private var total: Int64 {
        max(0, model.photosBytes + model.videosBytes + model.clipsBytes)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                title
                if model.computing && total == 0 {
                    loadingRow
                }
                categorySection
                actionsSection
                footnote
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scarletScreen()   // shared near-black ink ground; category accents stay as chrome
        // NOTE: do NOT hide the navigation bar here. Storage is PUSHED onto
        // Settings' NavigationStack and has no stack of its own, so the automatic
        // "‹ Settings" back button is the only way out — hiding the bar would
        // strip it and leave a hard dead-end. The .scarletScreen() ink ground
        // already supplies the dark surface; the sibling PreferencesView keeps
        // its bar for the same reason.
        .task { model.compute() }
        // Destructive clip deletion — confirmed.
        .confirmationDialog("Delete downloaded clips?",
                            isPresented: $showClearClips, titleVisibility: .visible) {
            Button("Delete \(model.clipsCount) clip\(model.clipsCount == 1 ? "" : "s")",
                   role: .destructive) {
                let n = model.deleteDownloadedClips()
                toast = "Freed up \(n) downloaded clip\(n == 1 ? "" : "s")."
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes only the videos Scarlet downloaded to this phone (\(Self.human(model.clipsBytes))). Your Photos are not touched, and any clip can be downloaded again.")
        }
        // Photos "online mode" — non-destructive explanation, never a deletion.
        .alert("Move photos to online mode", isPresented: $showPhotosOnline) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Not now", role: .cancel) {}
        } message: {
            Text("Nothing is deleted here. iPhone keeps full-quality originals safe in iCloud and shrinks the copies stored on the device when you turn on “Optimize iPhone Storage” under iCloud → Photos. Open Settings to switch it on.")
        }
        .alert("Storage", isPresented: Binding(get: { toast != nil },
                                               set: { if !$0 { toast = nil } })) {
            Button("OK", role: .cancel) { toast = nil }
        } message: {
            Text(toast ?? "")
        }
    }

    // MARK: pieces

    private var title: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Storage")
                .font(.system(size: 30, weight: .heavy))
                .foregroundStyle(.white)
            Text("Manage what Scarlet keeps on this phone.")
                .font(.scarletDetail)
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    private var loadingRow: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small).tint(scarletRose)
            Text("Measuring on-device usage…")
                .font(.scarletDetail).foregroundStyle(.secondary)
        }
    }

    private var categorySection: some View {
        VStack(spacing: 12) {
            categoryRow(title: "Photos",
                        subtitle: model.photoAccess
                            ? "\(model.photosCount) image\(model.photosCount == 1 ? "" : "s")"
                            : "Grant photo access to measure",
                        bytes: model.photosBytes, color: photoColor,
                        icon: "photo.on.rectangle.angled")
            categoryRow(title: "Videos in library",
                        subtitle: model.photoAccess
                            ? "\(model.videosCount) movie\(model.videosCount == 1 ? "" : "s") · your recordings"
                            : "Grant photo access to measure",
                        bytes: model.videosBytes, color: videoColor,
                        icon: "video.fill")
            categoryRow(title: "Downloaded clips",
                        subtitle: "\(model.clipsCount) clip\(model.clipsCount == 1 ? "" : "s") · saved for offline",
                        bytes: model.clipsBytes, color: clipColor,
                        icon: "arrow.down.circle.fill")
        }
    }

    private func categoryRow(title: String, subtitle: String, bytes: Int64,
                             color: Color, icon: String) -> some View {
        let fraction: CGFloat = total > 0 ? CGFloat(Double(bytes) / Double(total)) : 0
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(paper)
                    Text(subtitle)
                        .font(.scarletCaption)
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
                Spacer()
                Text(Self.human(bytes))
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(paper)
            }
            // Proportion bar.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08))
                    Capsule().fill(color.opacity(0.9))
                        .frame(width: max(0, min(geo.size.width, geo.size.width * fraction)))
                }
            }
            .frame(height: 8)
        }
        .padding(14)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.08), lineWidth: 1))
    }

    private var actionsSection: some View {
        VStack(spacing: 12) {
            actionRow(
                icon: "icloud.and.arrow.up",
                title: "Move photos to online mode",
                detail: "Keep originals in iCloud, reclaim local space. Nothing is deleted.",
                tint: photoColor,
                destructive: false
            ) { showPhotosOnline = true }

            actionRow(
                icon: "trash",
                title: "Delete downloaded clips",
                detail: model.clipsCount == 0
                    ? "No clips are downloaded right now."
                    : "Remove the \(model.clipsCount) offline clip\(model.clipsCount == 1 ? "" : "s") (\(Self.human(model.clipsBytes))). Your Photos stay put.",
                tint: clipColor,
                destructive: true,
                disabled: model.clipsCount == 0
            ) { showClearClips = true }
        }
    }

    private func actionRow(icon: String, title: String, detail: String,
                           tint: Color, destructive: Bool, disabled: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(disabled ? .gray : tint)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(disabled ? Color.white.opacity(0.4) : paper)
                    Text(detail)
                        .font(.scarletDetail)
                        .foregroundStyle(.white.opacity(0.5))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.3))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((destructive ? Color(red: 0.5, green: 0.12, blue: 0.16) : Color.white.opacity(0.05))
                        .opacity(destructive ? 0.35 : 1),
                        in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16)
                .stroke((destructive ? tint : .white).opacity(0.14), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private var footnote: some View {
        Text("Total on-device media: \(Self.human(total)).")
            .font(.scarletDetail)
            .foregroundStyle(.white.opacity(0.45))
            .padding(.top, 4)
    }

    // MARK: format

    static func human(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 MB" }
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useMB, .useGB]
        return f.string(fromByteCount: bytes)
    }
}
