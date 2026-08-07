import Foundation
import SwiftUI
import UIKit
import WebKit

/// The Library: an in-app shelf of deliverables — PDFs, HTML pages, images,
/// video/audio clips, external links — that Scarlet produces for Ido, so
/// nothing has to ride out via email or Telegram. Two shelves (Library and
/// Archived), the same edge-function plumbing as the rest of the app
/// (app-api?v=2 + x-scarlet-token), and the house dark-scarlet look.

// MARK: - Shelf

/// Which shelf is showing: the live Library or the Archived stack.
enum LibraryShelf: String, CaseIterable, Identifiable {
    case library
    case archived

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .library: return "Library"
        case .archived: return "Archived"
        }
    }

    var icon: String {
        switch self {
        case .library: return "books.vertical.fill"
        case .archived: return "archivebox.fill"
        }
    }
}

/// The list-level ambient-focus line, shared by the list's own appearance and
/// each viewer's dismissal so both report the exact same thing.
private func libraryBrowsingFocus(shelf: LibraryShelf, count: Int) -> String {
    let shelfNote = shelf == .archived ? " He is on the Archived shelf." : ""
    return "[FOCUS] Ido is browsing his Library — the in-app shelf of "
        + "deliverables (PDFs, pages, clips) Scarlet has produced for him."
        + shelfNote
        + " \(count) items on the current shelf."
}

// MARK: - Wire types

/// One deliverable's kind, as `artifacts_list` returns it. Unknown strings
/// fall back to `.file` so a new server-side kind never breaks the list.
enum LibraryKind: String {
    case pdf
    case html
    case image
    case video
    case audio
    case link
    case file

    init(wire: String) {
        self = LibraryKind(rawValue: wire.lowercased()) ?? .file
    }

    var icon: String {
        switch self {
        case .pdf: return "doc.richtext"
        case .html: return "globe"
        case .image: return "photo"
        case .video: return "play.rectangle.fill"
        case .audio: return "waveform"
        case .link: return "link"
        case .file: return "doc"
        }
    }

    /// Per-kind tile tint on the dark background.
    var tint: Color {
        switch self {
        case .pdf: return Color(red: 0.95, green: 0.35, blue: 0.32)
        case .html: return Color(red: 0.35, green: 0.65, blue: 0.98)
        case .image: return Color(red: 0.75, green: 0.55, blue: 0.98)
        case .video: return Color(red: 0.98, green: 0.62, blue: 0.28)
        case .audio: return Color(red: 0.30, green: 0.82, blue: 0.60)
        case .link: return Color(red: 0.40, green: 0.78, blue: 0.90)
        case .file: return Color(white: 0.65)
        }
    }
}

/// One shelf row, as `op=artifacts_list` returns it.
struct LibraryItem: Identifiable {
    let id: String
    let title: String
    let kind: LibraryKind
    let description: String
    let mime: String
    let createdAt: Date?
    let archived: Bool
    let url: URL?
    let tags: [String]
}

// MARK: - Model

@MainActor
final class LibraryModel: ObservableObject {
    /// One instance for the app: the fetched shelves survive the section view
    /// being destroyed (iPad/Mac sidebar switches).
    static let shared = LibraryModel()

    @Published var shelf: LibraryShelf = .library
    @Published var items: [LibraryItem] = []
    @Published var loading = false
    @Published var errorText = ""
    /// Bumps on every successful load so the view can re-report focus with
    /// the actual item count.
    @Published var loadStamp = 0

    /// Monotonic load token: a slow fetch landing after a shelf switch is
    /// dropped (same discipline as InboxModel / ChatListModel).
    private var loadGeneration = 0
    /// Staleness gate: re-appearing within the TTL paints what's already
    /// loaded instead of refetching. Forced by pull-to-refresh and mutations.
    private let fresh = Freshness(ttl: 60)

    /// Segment tap: swap the shelf and refetch. The old shelf's rows clear
    /// right away so a slow network never shows Library rows under
    /// "Archived".
    func setShelf(_ newShelf: LibraryShelf) {
        guard newShelf != shelf else { return }
        shelf = newShelf
        items = []
        errorText = ""
        Task { await load() }
    }

    func load(force: Bool = false) async {
        // Freshness gate: with rows already on screen, a re-appearance within
        // the TTL is a no-op. An empty shelf always fetches.
        if !items.isEmpty, !fresh.shouldFetch(force: force) { return }
        guard TokenStore.token != nil else {
            items = []
            errorText = "Locked — unlock Scarlet to see your Library."
            return
        }
        if items.isEmpty { loading = true }
        errorText = ""
        loadGeneration += 1
        let generation = loadGeneration
        defer { if generation == loadGeneration { loading = false } }
        let want = shelf
        do {
            let data = try await Self.request([
                "op": "artifacts_list",
                "archived": want == .archived,
            ])
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let fetched = Self.parseItems(obj)
            guard generation == loadGeneration, want == shelf else { return }
            items = fetched
            loadStamp += 1
            fresh.markFetched()
        } catch {
            guard generation == loadGeneration, want == shelf else { return }
            errorText = "Couldn't reach the Library — check your connection."
        }
    }

    /// Optimistic archive/restore: the row leaves the shelf immediately; if
    /// the server says no, a reload brings the truth back.
    func setArchived(_ item: LibraryItem, archived: Bool) {
        items.removeAll { $0.id == item.id }
        Task {
            do {
                let data = try await Self.request([
                    "op": "artifact_archive",
                    "id": item.id,
                    "archived": archived,
                ])
                let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                guard (obj?["ok"] as? Bool) == true else {
                    throw URLError(.badServerResponse)
                }
            } catch {
                errorText = archived
                    ? "Couldn't archive \"\(item.title)\" — refreshed the shelf."
                    : "Couldn't restore \"\(item.title)\" — refreshed the shelf."
                await load(force: true)
            }
        }
    }

    /// Permanent delete (Archived shelf only, after the confirmation dialog).
    /// Optimistic removal; a failure reloads the truth.
    func delete(_ item: LibraryItem) {
        items.removeAll { $0.id == item.id }
        Task {
            do {
                let data = try await Self.request([
                    "op": "artifact_delete",
                    "id": item.id,
                ])
                let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                guard (obj?["ok"] as? Bool) == true else {
                    throw URLError(.badServerResponse)
                }
            } catch {
                errorText = "Couldn't delete \"\(item.title)\" — refreshed the shelf."
                await load(force: true)
            }
        }
    }

    // MARK: plumbing — the op rides the QUERY STRING (app-wide convention:
    // the server dispatches on ?op=...); the JSON body carries the params.

    private static func request(_ body: [String: Any]) async throws -> Data {
        var body = body
        let op = (body.removeValue(forKey: "op") as? String) ?? ""
        var comps = URLComponents(url: AppConfig.appAPIURL, resolvingAgainstBaseURL: false)!
        var qItems = comps.queryItems ?? []
        qItems.append(URLQueryItem(name: "op", value: op))
        comps.queryItems = qItems
        var req = URLRequest(url: comps.url ?? AppConfig.appAPIURL)
        req.httpMethod = "POST"
        req.setValue(TokenStore.token ?? "", forHTTPHeaderField: "x-scarlet-token")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private static func parseItems(_ obj: [String: Any]) -> [LibraryItem] {
        let raw = (obj["items"] as? [[String: Any]]) ?? []
        var seen = Set<String>()
        return raw.compactMap { a in
            guard let id = a["id"] as? String, !id.isEmpty else { return nil }
            // A duplicate id traps the diffable List at regular width — keep first.
            guard seen.insert(id).inserted else { return nil }
            let title = (a["title"] as? String) ?? ""
            let urlString = (a["url"] as? String) ?? ""
            return LibraryItem(
                id: id,
                title: title.isEmpty ? "Untitled" : title,
                kind: LibraryKind(wire: (a["kind"] as? String) ?? "file"),
                description: (a["description"] as? String) ?? "",
                mime: (a["mime"] as? String) ?? "",
                createdAt: MailDates.parse(a["created_at"] as? String),
                archived: (a["archived"] as? Bool) ?? false,
                url: urlString.isEmpty ? nil : URL(string: urlString),
                tags: (a["tags"] as? [String]) ?? []
            )
        }
    }
}

// MARK: - Library page

struct LibraryView: View {
    @ObservedObject private var model = LibraryModel.shared
    @EnvironmentObject private var convo: Conversation

    /// ONE presentation driver for every viewer. The photo, video/audio, and
    /// web viewers now PUSH into the detail column (navigationDestination) so
    /// the Scarlet sidebar stays reachable; QuickLook (`.file`) is inherently
    /// modal and stays the SINGLE `.sheet`. SwiftUI/Mac Catalyst supports only
    /// one sheet per view — stacking sheets crashes the Mac — so exactly one
    /// case stays a sheet and the rest become pushes. Enum-driven.
    enum LibrarySheet: Identifiable {
        case photo(WAPhotoItem), video(WAVideoItem), file(PreviewFile), web(LibraryWebItem)
        var id: String {
            switch self {
            case .photo(let i): return "photo-\(i.id)"
            case .video(let i): return "video-\(i.id)"
            case .file(let f): return "file-\(f.id)"
            case .web(let w): return "web-\(w.id)"
            }
        }
    }
    @State private var activeSheet: LibrarySheet?
    /// Row currently downloading (its chevron swaps to a spinner).
    @State private var downloadingID: String?
    /// The exact focus line last claimed for an open artifact; the sheets'
    /// dismissal restores the browsing focus only if this still owns it
    /// (InboxView's stale-guard pattern).
    @State private var openedFocus: String?
    /// Archived-shelf delete flow: candidate + dialog visibility.
    @State private var deleteCandidate: LibraryItem?
    @State private var confirmingDelete = false

    private let scarletRose = Color(red: 1, green: 0.35, blue: 0.42)

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                headerBar
                shelfSwitcher
                content
            }
            .scarletScreen()
            // Scarlet lives at the bottom of the list screen, part of its
            // layout — same pattern as ChatsView / InboxView.
            .safeAreaInset(edge: .bottom) {
                ScarletPresenceView(convo: convo)
                    .padding(.vertical, 6)
            }
            .toolbar(.hidden, for: .navigationBar)
            // Ambient focus: the shelf reports itself on appearance, after
            // every successful load (count changes), and on shelf switches.
            .onAppear { convo.setFocus(browsingFocus) }
            .onChange(of: model.loadStamp) { _, _ in
                convo.setFocus(browsingFocus)
            }
            .onChange(of: model.shelf) { _, _ in
                convo.setFocus(browsingFocus)
            }
            // Photo / video / web viewers PUSH into the detail column (not
            // window-covering sheets) so the Scarlet sidebar stays reachable
            // while a deliverable is open — the CalendarView fix, applied here.
            // On pop, restore the browsing focus. isPresented (not item:)
            // because the viewer items aren't Hashable and this stays
            // iOS-16-safe.
            .reportsModalPresence(activeSheet != nil)
            .navigationDestination(isPresented: Binding(
                get: {
                    switch activeSheet {
                    case .photo, .video, .web: return true
                    default: return false
                    }
                },
                set: { if !$0 {
                    restoreBrowsingFocus()
                    activeSheet = nil
                } }
            )) {
                switch activeSheet {
                case .photo(let item):
                    WAPhotoView(item: item)
                case .video(let item):
                    WAVideoView(item: item)
                case .web(let item):
                    LibraryWebSheet(item: item)
                        .preferredColorScheme(.dark)
                default:
                    EmptyView()
                }
            }
            // QuickLook is inherently modal — it stays the SINGLE `.sheet` on
            // this view (Mac Catalyst allows only one). A derived binding
            // surfaces only the `.file` case; every other case drives the push
            // above instead of ever reaching this sheet.
            .sheet(item: Binding<LibrarySheet?>(
                get: { if case .file = activeSheet { return activeSheet } else { return nil } },
                set: { newValue in
                    if newValue == nil, case .file = activeSheet { activeSheet = nil }
                }
            ), onDismiss: { restoreBrowsingFocus() }) { sheet in
                if case .file(let file) = sheet {
                    QuickLookPreview(url: file.url)
                        .ignoresSafeArea()
                }
            }
            .confirmationDialog(
                "Delete permanently?",
                isPresented: $confirmingDelete,
                titleVisibility: .visible,
                presenting: deleteCandidate
            ) { item in
                Button("Delete \"\(item.title)\"", role: .destructive) {
                    model.delete(item)
                    deleteCandidate = nil
                }
                Button("Cancel", role: .cancel) {
                    deleteCandidate = nil
                }
            } message: { item in
                Text("\"\(item.title)\" will be removed from the Library for good.")
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

    // MARK: header (big heavy title + refresh, like ChatsView)

    private var headerBar: some View {
        HStack(spacing: 12) {
            Text("Library")
                .font(.system(size: 34, weight: .heavy))
                .foregroundStyle(.white)
            Spacer()
            Button {
                Task { await model.load(force: true) }
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

    // MARK: shelf switcher (two-segment capsule, ChatsView's channelSwitcher)

    private var shelfSwitcher: some View {
        HStack(spacing: 4) {
            ForEach(LibraryShelf.allCases) { s in
                segment(s)
            }
        }
        .padding(4)
        .background(Capsule().fill(.white.opacity(0.06)))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func segment(_ s: LibraryShelf) -> some View {
        Button {
            model.setShelf(s)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: s.icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(s.displayName)
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(model.shelf == s ? scarletRose : .white.opacity(0.55))
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
                Capsule().fill(model.shelf == s
                    ? scarletRose.opacity(0.18) : Color.clear)
            )
            .overlay(
                Capsule().stroke(model.shelf == s
                    ? scarletRose.opacity(0.45) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: content

    @ViewBuilder
    private var content: some View {
        if model.loading && model.items.isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                Text("Fetching the shelf…")
                    .font(.scarletDetail).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.items.isEmpty && !model.errorText.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.title2).foregroundStyle(.secondary)
                Text(model.errorText)
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try again") { Task { await model.load(force: true) } }
                    .buttonStyle(.bordered)
                    .tint(scarletRose)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.items.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: model.shelf.icon)
                    .font(.title2).foregroundStyle(.secondary)
                Text(model.shelf == .archived
                    ? "Nothing archived."
                    : "Nothing here yet — ask Scarlet for a PDF, a page, a clip… deliverables land here.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            shelfList
        }
    }

    private var shelfList: some View {
        List {
            if !model.errorText.isEmpty {
                Text(model.errorText)
                    .font(.scarletDetail)
                    .foregroundStyle(Color(red: 0.91, green: 0.69, blue: 0.31))
                    .listRowBackground(Color.clear)
            }
            ForEach(model.items) { item in
                Button {
                    open(item)
                } label: {
                    LibraryRow(item: item, downloading: downloadingID == item.id)
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .listRowSeparatorTint(.white.opacity(0.12))
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    swipeButtons(item)
                }
                .contextMenu {
                    menuButtons(item)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { await model.load(force: true) }
    }

    @ViewBuilder
    private func swipeButtons(_ item: LibraryItem) -> some View {
        if model.shelf == .library {
            Button {
                model.setArchived(item, archived: true)
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .tint(Color(red: 0.85, green: 0.55, blue: 0.15))
        } else {
            Button(role: .destructive) {
                deleteCandidate = item
                confirmingDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                model.setArchived(item, archived: false)
            } label: {
                Label("Restore", systemImage: "arrow.uturn.backward")
            }
            .tint(Color(red: 0.06, green: 0.5, blue: 0.24))
        }
    }

    @ViewBuilder
    private func menuButtons(_ item: LibraryItem) -> some View {
        if model.shelf == .library {
            Button {
                model.setArchived(item, archived: true)
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
        } else {
            Button {
                model.setArchived(item, archived: false)
            } label: {
                Label("Restore", systemImage: "arrow.uturn.backward")
            }
            Button(role: .destructive) {
                deleteCandidate = item
                confirmingDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: opening (per-kind viewers)

    private func open(_ item: LibraryItem) {
        guard let url = item.url else {
            model.errorText = "\"\(item.title)\" has no link yet — refresh and try again."
            return
        }
        switch item.kind {
        case .image:
            claimFocus(item)
            activeSheet = .photo(WAPhotoItem(url: url))
        case .video, .audio:
            claimFocus(item)
            activeSheet = .video(WAVideoItem(url: url))
        case .html, .link:
            claimFocus(item)
            // For an HTML artifact, FORCE text/html rendering — object storage
            // often serves uploaded .html as text/plain (raw source shows) or
            // octet-stream (blank/download). A plain link keeps normal loading.
            activeSheet = .web(LibraryWebItem(url: url, title: item.title, forceHTML: item.kind == .html))
        case .pdf, .file:
            openDocument(item, url: url)
        }
    }

    /// pdf/file: download to a temp file (title-derived name + proper
    /// extension so QuickLook picks the right renderer), then present the
    /// system previewer — InboxView's attachment pattern.
    @MainActor
    private func openDocument(_ item: LibraryItem, url: URL) {
        model.errorText = ""
        guard downloadingID == nil else { return }
        downloadingID = item.id
        Task {
            defer { downloadingID = nil }
            do {
                let (data, resp) = try await URLSession.shared.data(from: url)
                if let http = resp as? HTTPURLResponse,
                   !(200...299).contains(http.statusCode) {
                    throw URLError(.badServerResponse)
                }
                guard !data.isEmpty else { throw URLError(.zeroByteResource) }
                let dest = Self.tempFileURL(for: item)
                try data.write(to: dest, options: .atomic)
                claimFocus(item)
                activeSheet = .file(PreviewFile(url: dest))
            } catch {
                model.errorText = "Couldn't download \"\(item.title)\" — try again."
            }
        }
    }

    /// Temp destination named after the title (path separators stripped so a
    /// hostile title can't escape the temp directory) with the extension the
    /// MIME type implies — that extension is what makes QuickLook render
    /// PDFs as PDFs, spreadsheets as spreadsheets, and so on.
    private static func tempFileURL(for item: LibraryItem) -> URL {
        var clean = item.title
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty || clean == "." || clean == ".." { clean = "deliverable" }
        let ext = fileExtension(for: item)
        if !ext.isEmpty && !clean.lowercased().hasSuffix(".\(ext)") {
            clean += ".\(ext)"
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent(clean)
    }

    /// MIME → extension for the common deliverable types; falls back to the
    /// URL's own extension, then to "pdf" for pdf-kind items, then nothing.
    private static func fileExtension(for item: LibraryItem) -> String {
        let mimeMap: [String: String] = [
            "application/pdf": "pdf",
            "text/html": "html",
            "text/plain": "txt",
            "text/csv": "csv",
            "application/json": "json",
            "image/png": "png",
            "image/jpeg": "jpg",
            "image/gif": "gif",
            "image/heic": "heic",
            "image/webp": "webp",
            "video/mp4": "mp4",
            "video/quicktime": "mov",
            "audio/mpeg": "mp3",
            "audio/mp4": "m4a",
            "audio/x-m4a": "m4a",
            "audio/wav": "wav",
            "application/zip": "zip",
            "application/msword": "doc",
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document": "docx",
            "application/vnd.ms-excel": "xls",
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": "xlsx",
            "application/vnd.ms-powerpoint": "ppt",
            "application/vnd.openxmlformats-officedocument.presentationml.presentation": "pptx",
        ]
        let mime = item.mime.lowercased()
            .components(separatedBy: ";").first?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if let hit = mimeMap[mime] { return hit }
        if let url = item.url {
            let urlExt = url.pathExtension.lowercased()
            if !urlExt.isEmpty && urlExt.count <= 5 { return urlExt }
        }
        if item.kind == .pdf { return "pdf" }
        return ""
    }

    // MARK: Scarlet focus

    private var browsingFocus: String {
        libraryBrowsingFocus(shelf: model.shelf, count: model.items.count)
    }

    private func itemFocus(_ item: LibraryItem) -> String {
        "[FOCUS] Ido opened a Library deliverable: \"\(item.title)\" "
            + "(\(item.kind.rawValue)) — one of the items Scarlet produced for him.\n"
            + "artifact_id: \(item.id)"
    }

    private func claimFocus(_ item: LibraryItem) {
        let f = itemFocus(item)
        openedFocus = f
        convo.setFocus(f)
    }

    /// Stale-guard (InboxView's MailDetailView pattern): restore the shelf
    /// focus only if the closed viewer still owns it — another screen may
    /// have claimed focus while the sheet was up.
    private func restoreBrowsingFocus() {
        if let f = openedFocus, convo.currentFocus == f {
            convo.setFocus(browsingFocus)
        }
        openedFocus = nil
    }
}

// MARK: - Row

/// One shelf row: 44pt kind tile, two-line title, two-line description,
/// relative date, trailing chevron (spinner while its file downloads).
struct LibraryRow: View {
    let item: LibraryItem
    var downloading: Bool = false

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(item.kind.tint.opacity(0.18))
                Image(systemName: item.kind.icon)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(item.kind.tint)
            }
            .frame(width: 44, height: 44)
            .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .truncationMode(.tail)
                if !item.description.isEmpty {
                    Text(item.description)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
                if let date = item.createdAt {
                    Text(Self.relative.localizedString(for: date, relativeTo: Date()))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            Spacer(minLength: 8)
            if downloading {
                ProgressView()
                    .frame(width: 16, height: 16)
                    .padding(.top, 14)
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.35))
                    .padding(.top, 15)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - In-app web sheet (html / link deliverables)

/// Identifiable wrapper so `.sheet(item:)` can drive the web sheet off a URL.
/// (Distinct from ChatsView's WAPhotoItem/WAVideoItem and InboxView's
/// PreviewFile on purpose.)
struct LibraryWebItem: Identifiable {
    let url: URL
    let title: String
    var forceHTML: Bool = false
    var id: String { url.absoluteString }
}

/// The in-app browser: a WKWebView pushed into the Library's NavigationStack
/// with a drawn Back button and a Share link — html pages and external links
/// stay in the app instead of bouncing out to Safari.
struct LibraryWebSheet: View {
    let item: LibraryWebItem
    @Environment(\.dismiss) private var dismiss

    private let scarletRose = Color(red: 1, green: 0.35, blue: 0.42)

    var body: some View {
        // Pushed into the Library's NavigationStack (not a sheet): the list
        // root hides the system nav bar app-wide and Mac Catalyst has no
        // edge-swipe-back, so we draw the way back (and the Share action)
        // ourselves — the app-wide reader pattern.
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { dismiss() } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Library").font(.scarletDetailEmph)
                    }
                    .foregroundStyle(scarletRose)
                }
                Spacer(minLength: 8)
                Text(item.title)
                    .font(.scarletBodyEmph)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                ShareLink(item: item.url) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(scarletRose)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
            LibraryWebView(url: item.url, forceHTML: item.forceHTML)
                .ignoresSafeArea(edges: .bottom)
        }
        .background(Color.black.ignoresSafeArea())
    }
}

/// Plain WKWebView wrapper for the web sheet. Loads the page once per URL;
/// navigation inside the page is allowed (it's a browser sheet, not a mail
/// body), so no delegate gymnastics are needed.
struct LibraryWebView: UIViewRepresentable {
    let url: URL
    var forceHTML: Bool = false

    final class Coordinator {
        var loadedURL: URL?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let web = WKWebView(frame: .zero)
        web.isOpaque = true
        web.backgroundColor = .white
        web.scrollView.backgroundColor = .white
        web.allowsBackForwardNavigationGestures = true
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        guard context.coordinator.loadedURL != url else { return }
        context.coordinator.loadedURL = url
        guard forceHTML else { web.load(URLRequest(url: url)); return }
        // Fetch the bytes and render them AS text/html, ignoring whatever
        // Content-Type object storage stamped on the file — otherwise a
        // text/plain header shows raw source and octet-stream shows a blank page.
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                await MainActor.run { web.load(data, mimeType: "text/html", characterEncodingName: "UTF-8", baseURL: url) }
            } catch {
                await MainActor.run { web.load(URLRequest(url: url)) }   // fall back to a normal load
            }
        }
    }
}
