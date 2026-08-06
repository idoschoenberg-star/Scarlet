import Foundation
import SwiftUI
import UIKit
import WebKit
import PDFKit

// =============================================================================
// MARK: - reMarkable — Ido's cloud notebooks, read inside Scarlet
// =============================================================================
//
// Everything Ido wrote on his reMarkable, browsable here: his cloud folders and
// notebooks, his handwriting rendered page-by-page, PDFs and ePubs opened in
// place — and any notebook pulled into Scarlet's Apple Notes with one tap.
//
// House style: the app's shared near-black chrome (`.scarletScreen()` /
// `.scarletCard()`, ScarletTheme tokens, the ScarletType ramp) with a tasteful
// VIOLET accent — the same "library" idiom, since reMarkable is a reading room.
// The PAGE content itself renders on WHITE (that is how handwriting reads), sat
// cleanly on the dark chrome.
//
// Self-contained: it reads NO `@EnvironmentObject` (no `convo`). Send-to-Notes
// posts the backend `note_create` op directly — the same Mac-agent path
// NotesView uses — so this view drops into the section catalog with no
// re-injection ceremony and no Mac-Catalyst environment-drop risk.
//
// Catalyst discipline: the reader is a PUSH (`navigationDestination(item:)`),
// pairing is an inline empty-state, and the Send-to-Notes result is an `.alert`.
// No `.sheet` / `.fullScreenCover` at all — trivially inside the one-sheet rule.

// =============================================================================
// MARK: - House style (violet-accented, on the shared dark chrome)
// =============================================================================

enum RmTheme {
    /// This section's accent — the theme's "library" violet. Chrome only
    /// (titles, glyphs, active states), never behind reading text.
    static let accent = Color(red: 0.78, green: 0.62, blue: 1.0)
    /// The page surface — handwriting and documents read on white.
    static let page = Color.white
}

// =============================================================================
// MARK: - Wire types
// =============================================================================

/// One row in a reMarkable folder — a folder to open, or a document to read.
/// Hashable + Identifiable so a document can drive `navigationDestination(item:)`.
struct RmItem: Identifiable, Hashable {
    let id: String
    let name: String
    /// "folder" | "document"
    let type: String
    /// "notebook" | "pdf" | "epub" (documents only)
    let kind: String?
    let modified: String?

    var isFolder: Bool { type == "folder" }

    /// SF Symbol for the row's leading glyph.
    var glyph: String {
        if isFolder { return "folder.fill" }
        switch (kind ?? "").lowercased() {
        case "pdf":   return "doc.richtext"
        case "epub":  return "book.closed"
        default:      return "scribble.variable"   // a handwritten notebook
        }
    }

    var modifiedText: String? { RmFormat.relative(modified) }
}

/// One folder step in the breadcrumb (root is the empty id "").
struct RmFolderRef: Identifiable, Hashable {
    let id: String
    let name: String
}

/// A fetched document, ready to render. A notebook carries self-contained SVG
/// page strings; a PDF/ePub carries the source file as base64.
struct RmDoc {
    let name: String
    let kind: String
    let pages: [String]        // SVG strings, one per page (notebooks)
    let pdfBase64: String?     // source file (PDF/ePub)
}

// =============================================================================
// MARK: - Formatting
// =============================================================================

enum RmFormat {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let rel: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    static func parse(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        if let d = iso.date(from: s) { return d }
        if let d = isoPlain.date(from: s) { return d }
        return nil
    }

    /// "3h ago" — nil when there's no usable timestamp.
    static func relative(_ s: String?) -> String? {
        guard let d = parse(s) else { return nil }
        if Date().timeIntervalSince(d) < 60 { return "just now" }
        return rel.localizedString(for: d, relativeTo: Date())
    }
}

// =============================================================================
// MARK: - Model
// =============================================================================

@MainActor
final class RemarkableModel: ObservableObject {

    enum Phase { case loading, loaded, empty, error, notConnected }

    @Published var items: [RmItem] = []
    @Published var phase: Phase = .loading
    @Published var errorText = ""
    /// Breadcrumb from root (root itself is implicit; "" = root folder id).
    @Published var folderStack: [RmFolderRef] = []

    // Pairing state (drives the not-connected empty-state form).
    @Published var connecting = false
    @Published var connectError = ""

    private var rawRoot: [[String: Any]] = []   // cached root listing (raw)

    var currentFolderId: String { folderStack.last?.id ?? "" }

    init() { loadCache() }

    // MARK: navigation

    func openFolder(_ item: RmItem) {
        folderStack.append(RmFolderRef(id: item.id, name: item.name))
        items = []
        phase = .loading
        Task { await load() }
    }

    func goBack() {
        guard !folderStack.isEmpty else { return }
        folderStack.removeLast()
        items = []
        phase = .loading
        Task { await load() }
    }

    /// Jump to a breadcrumb crumb. `index == -1` is the root.
    func goToCrumb(_ index: Int) {
        if index < 0 {
            folderStack = []
        } else if index < folderStack.count {
            folderStack = Array(folderStack.prefix(index + 1))
        }
        items = []
        phase = .loading
        Task { await load() }
    }

    // MARK: loading

    /// Fetch the current folder's listing. A failed refresh keeps whatever's
    /// already on screen rather than blanking it.
    func load() async {
        if items.isEmpty { phase = .loading }
        errorText = ""
        let folderId = currentFolderId
        do {
            let data = try await Self.request(op: "rm_list", body: ["folderId": folderId])
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if let err = obj["error"] as? String, !err.isEmpty {
                if Self.isNotConnected(err) {
                    items = []
                    phase = .notConnected
                    return
                }
                errorText = err
                if items.isEmpty { phase = .error }
                return
            }
            let raw = (obj["items"] as? [[String: Any]]) ?? []
            let parsed = raw.compactMap { Self.item(from: $0) }.sorted(by: Self.order)
            items = parsed
            phase = parsed.isEmpty ? .empty : .loaded
            if folderId.isEmpty {
                rawRoot = raw
                saveCache()
            }
        } catch {
            if items.isEmpty {
                phase = .error
                errorText = "Couldn't reach reMarkable — pull to refresh."
            }
            // A failed refresh with items already up: keep them, stay silent.
        }
    }

    // MARK: pairing

    /// Pair with reMarkable's cloud using the 8-char one-time code from
    /// my.remarkable.com/device/desktop/connect. On success, reload the list.
    func connect(code: String) async {
        let c = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty else { return }
        connecting = true
        connectError = ""
        defer { connecting = false }
        do {
            let data = try await Self.request(op: "rm_connect", body: ["code": c])
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let ok = ((obj["ok"] as? Bool) == true) || ((obj["connected"] as? Bool) == true)
            if ok {
                folderStack = []
                items = []
                phase = .loading
                await load()
            } else {
                connectError = (obj["error"] as? String) ?? "That code didn't work — grab a fresh one and try again."
            }
        } catch {
            connectError = "Couldn't reach Scarlet — check your connection and try again."
        }
    }

    // MARK: parsing / helpers

    static func isNotConnected(_ err: String) -> Bool {
        err.lowercased().contains("not connected")
    }

    private static func item(from d: [String: Any]) -> RmItem? {
        let id = (d["id"] as? String) ?? ""
        let name = ((d["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !name.isEmpty else { return nil }
        let type = (d["type"] as? String) ?? "document"
        return RmItem(id: id,
                      name: name,
                      type: type,
                      kind: d["kind"] as? String,
                      modified: d["modified"] as? String)
    }

    /// Folders first, then alphabetical (case-insensitive), matching reMarkable.
    private static func order(_ a: RmItem, _ b: RmItem) -> Bool {
        if a.isFolder != b.isFolder { return a.isFolder && !b.isFolder }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }

    // MARK: cache — Documents/remarkable-root-cache.json (root listing only)

    private static var cacheURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return docs.appendingPathComponent("remarkable-root-cache.json")
    }

    private func loadCache() {
        guard folderStack.isEmpty,
              let data = try? Data(contentsOf: Self.cacheURL),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let raw = obj["items"] as? [[String: Any]]
        else { return }
        rawRoot = raw
        let parsed = raw.compactMap { Self.item(from: $0) }.sorted(by: Self.order)
        items = parsed
        if !parsed.isEmpty { phase = .loaded }
    }

    private func saveCache() {
        let obj: [String: Any] = ["items": rawRoot]
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj)
        else { return }
        try? data.write(to: Self.cacheURL, options: .atomic)
    }

    // MARK: plumbing — op rides the query string, params ride the JSON body.
    // Same shape as NotesModel.request: apiBase (?v=2) + x-scarlet-token + 2xx.

    static func request(op: String, body: [String: Any] = [:]) async throws -> Data {
        guard var comps = URLComponents(url: AppConfig.appAPIURL, resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        var q = comps.queryItems ?? []
        q.append(URLQueryItem(name: "op", value: op))
        comps.queryItems = q
        guard let url = comps.url else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
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
}

// =============================================================================
// MARK: - RemarkableView — the browser
// =============================================================================

struct RemarkableView: View {
    @StateObject private var model = RemarkableModel()

    /// The document being read — drives a PUSH into the detail column (never a
    /// window-covering sheet), consistent with News/Notes.
    @State private var openDoc: RmItem?
    /// Inline pairing code (only used in the not-connected empty-state).
    @State private var pairCode = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                headerBar
                content
            }
            .scarletScreen()
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $openDoc) { doc in
                RmReaderView(item: doc)
                    .preferredColorScheme(.dark)
            }
        }
        .tint(RmTheme.accent)
        .task {
            // Cache-first, refresh-behind. loadCache() paints the last-known root
            // instantly in init; we then ALWAYS refresh from the reMarkable cloud
            // so a stale on-disk cache can never keep showing old notebooks while
            // hiding the actual current ones (the "only old notebooks" bug).
            // load() keeps the cached items if the refresh fails and only shows a
            // spinner when nothing is cached yet, so this never blanks or flickers.
            if model.phase != .notConnected { await model.load() }
        }
    }

    // MARK: header (title + breadcrumb + back + refresh)

    private var headerBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                if !model.folderStack.isEmpty {
                    Button { model.goBack() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(RmTheme.accent)
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back")
                }
                Text(model.folderStack.last?.name ?? "reMarkable")
                    .font(.scarletHero)
                    .foregroundStyle(ScarletTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Button { Task { await model.load() } } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(RmTheme.accent)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .disabled(model.phase == .loading)
                .accessibilityLabel("Refresh")
            }
            if !model.folderStack.isEmpty { breadcrumb }
        }
        .padding(.horizontal, ScarletTheme.screenPadding)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(ScarletTheme.hairline).frame(height: 1)
        }
    }

    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                crumb(title: "reMarkable", index: -1)
                ForEach(Array(model.folderStack.enumerated()), id: \.element.id) { idx, ref in
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(ScarletTheme.textTertiary)
                    crumb(title: ref.name, index: idx)
                }
            }
        }
    }

    private func crumb(title: String, index: Int) -> some View {
        let isLast = index == model.folderStack.count - 1
        return Button { if !isLast { model.goToCrumb(index) } } label: {
            Text(title)
                .font(.scarletDetailEmph)
                .foregroundStyle(isLast ? ScarletTheme.textSecondary : RmTheme.accent)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .disabled(isLast)
    }

    // MARK: content

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading where model.items.isEmpty:
            loadingState
        case .notConnected:
            connectState
        case .error where model.items.isEmpty:
            errorState
        case .empty:
            emptyState
        default:
            listState
        }
    }

    private var listState: some View {
        List {
            ForEach(model.items) { item in
                Button { open(item) } label: { RmRow(item: item) }
                    .buttonStyle(.plain)
                    .listRowBackground(ScarletTheme.card)
                    .listRowSeparatorTint(ScarletTheme.hairline)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .refreshable { await model.load() }
    }

    private func open(_ item: RmItem) {
        if item.isFolder {
            model.openFolder(item)
        } else {
            openDoc = item
        }
    }

    // MARK: states

    private var loadingState: some View {
        VStack(spacing: 14) {
            ProgressView().tint(RmTheme.accent).controlSize(.large)
            Text("Opening your reMarkable…")
                .font(.scarletBody)
                .foregroundStyle(ScarletTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 34))
                .foregroundStyle(ScarletTheme.textSecondary)
            Text("This folder is empty")
                .font(.scarletTitle)
                .foregroundStyle(ScarletTheme.textPrimary)
            Text("Pull to refresh.")
                .font(.scarletBody)
                .foregroundStyle(ScarletTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private var errorState: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 34))
                .foregroundStyle(ScarletTheme.textSecondary)
            Text(model.errorText.isEmpty ? "Couldn't load your reMarkable." : model.errorText)
                .font(.scarletBody)
                .foregroundStyle(ScarletTheme.textSecondary)
                .multilineTextAlignment(.center)
            Button { Task { await model.load() } } label: {
                Text("Try again")
                    .font(.scarletBodyEmph)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22).padding(.vertical, 11)
                    .background(RmTheme.accent, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    // The "Connect your reMarkable" empty-state — pairing lives inline here
    // (no sheet). A code from my.remarkable.com/device/desktop/connect pairs
    // the cloud; on success the list loads.
    private var connectState: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "pencil.and.scribble")
                    .font(.system(size: 46, weight: .regular))
                    .foregroundStyle(RmTheme.accent)
                    .padding(.top, 24)
                Text("Connect your reMarkable")
                    .font(.scarletSection)
                    .foregroundStyle(ScarletTheme.textPrimary)
                    .multilineTextAlignment(.center)
                VStack(alignment: .leading, spacing: 10) {
                    Text("1.  On any browser, open **my.remarkable.com/device/desktop/connect** and sign in.")
                    Text("2.  Enter the **8-character code** it shows below, then tap Connect.")
                }
                .font(.scarletBody)
                .foregroundStyle(ScarletTheme.textSecondary)
                .scarletReadingLineSpacing()
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 12) {
                    TextField("8-character code", text: $pairCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled(true)
                        .font(.system(size: 22, weight: .semibold, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(ScarletTheme.textPrimary)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity)
                        .background(ScarletTheme.inkRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(ScarletTheme.hairline, lineWidth: 1))

                    Button {
                        Task { await model.connect(code: pairCode) }
                    } label: {
                        HStack(spacing: 8) {
                            if model.connecting { ProgressView().tint(.white) }
                            Text(model.connecting ? "Connecting…" : "Connect")
                                .font(.scarletBodyEmph)
                        }
                        .foregroundStyle(.white)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity)
                        .background(RmTheme.accent.opacity(canConnect ? 1 : 0.4),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canConnect)

                    if !model.connectError.isEmpty {
                        Text(model.connectError)
                            .font(.scarletDetail)
                            .foregroundStyle(Color(red: 1.0, green: 0.45, blue: 0.45))
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(16)
                .scarletCard()
            }
            .padding(.horizontal, ScarletTheme.screenPadding)
            .padding(.bottom, 40)
            .frame(maxWidth: 460)
            .frame(maxWidth: .infinity)
        }
    }

    private var canConnect: Bool {
        !model.connecting &&
        pairCode.trimmingCharacters(in: .whitespacesAndNewlines).count >= 6
    }
}

// =============================================================================
// MARK: - Row
// =============================================================================

/// One folder/document row — glyph, name (RTL-aware for Hebrew titles), a kind
/// label + modified date, and a chevron for folders.
struct RmRow: View {
    let item: RmItem

    private var subtitle: String {
        var parts: [String] = []
        switch (item.kind ?? "").lowercased() {
        case "pdf":  parts.append("PDF")
        case "epub": parts.append("ePub")
        case "notebook": parts.append("Notebook")
        default: break
        }
        if let m = item.modifiedText { parts.append(m) }
        return parts.joined(separator: "  ·  ")
    }

    var body: some View {
        let rtl = item.name.isRTLDominant
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(item.isFolder ? RmTheme.accent.opacity(0.16) : Color.white.opacity(0.06))
                    .frame(width: 40, height: 40)
                Image(systemName: item.glyph)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(item.isFolder ? RmTheme.accent : ScarletTheme.textSecondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.scarletBodyEmph)
                    .foregroundStyle(ScarletTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: rtl ? .trailing : .leading)
                    .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.scarletDetail)
                        .foregroundStyle(ScarletTheme.textTertiary)
                        .lineLimit(1)
                }
            }
            if item.isFolder {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ScarletTheme.textTertiary)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

// =============================================================================
// MARK: - Reader — handwriting (SVG) or a document (PDF/ePub)
// =============================================================================

/// Opens one document: fetches `rm_pages`, then renders SVG handwriting pages
/// (WKWebView, swipeable) or a PDF/ePub (PDFKit). Toolbar "Send to Notes"
/// creates an Apple Note via the `note_create` op — no `convo` needed.
/// Self-contained; pushed into the browser's NavigationStack.
struct RmReaderView: View {
    let item: RmItem
    @Environment(\.dismiss) private var dismiss

    @State private var loading = true
    @State private var doc: RmDoc?
    @State private var pdfData: Data?
    @State private var errorText = ""
    @State private var currentPage = 0

    // Send-to-Notes (result via an alert — Catalyst-safe, no sheet).
    @State private var sending = false
    @State private var showSendAlert = false
    @State private var sendMessage = ""

    private var pageCount: Int { doc?.pages.count ?? 0 }
    private var isNotebook: Bool { (doc?.pdfBase64 == nil) && pageCount > 0 }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Group {
                if loading {
                    loadingState
                } else if !errorText.isEmpty {
                    errorState
                } else if let data = pdfData {
                    RmPDFKitView(data: data)
                        .background(Color.black)
                } else if isNotebook {
                    notebookPager
                } else {
                    // No pages and no document — honest empty reader.
                    emptyReader
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .scarletScreen()
        .toolbar(.hidden, for: .navigationBar)
        .task { await load() }
        .alert("Send to Notes", isPresented: $showSendAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(sendMessage)
        }
    }

    // MARK: top bar (drawn — nav bar is hidden app-wide; Catalyst has no
    // edge-swipe-back, so we draw the way back + the Send action ourselves).

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                    Text("reMarkable").font(.system(size: 16, weight: .semibold))
                }
                .foregroundStyle(RmTheme.accent)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)

            if isNotebook {
                Text("\(min(currentPage + 1, pageCount)) / \(pageCount)")
                    .font(.scarletDetailEmph)
                    .foregroundStyle(ScarletTheme.textSecondary)
                    .monospacedDigit()
            }

            Button { Task { await sendToNotes() } } label: {
                HStack(spacing: 6) {
                    if sending {
                        ProgressView().tint(RmTheme.accent).controlSize(.small)
                    } else {
                        Image(systemName: "note.text.badge.plus")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    Text("Send to Notes").font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(RmTheme.accent)
            }
            .buttonStyle(.plain)
            .disabled(sending || loading || !errorText.isEmpty)
        }
        .padding(.horizontal, ScarletTheme.screenPadding)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(ScarletTheme.hairline).frame(height: 1)
        }
    }

    // MARK: notebook pager (windowed — one live WKWebView per visible page only)
    //
    // A paged TabView is NOT lazy: a plain ForEach over every page builds one
    // `RmSVGWebView` → one `WKWebView` per page UP FRONT. On a large notebook
    // that spins up dozens–hundreds of web content processes and the app gets
    // jetsam-killed ("quit unexpectedly"). Fix: keep ALL page slots in the
    // TabView — so selection, swipe paging and the "n / N" indicator stay
    // correct across the whole notebook — but only the pages within a ±1 window
    // of `currentPage` actually HOST a WKWebView. Every other slot is a cheap
    // white placeholder (a Color, no web process). As `currentPage` moves, the
    // window follows: an entering page builds its web view, a leaving page tears
    // its web view down, so at most ~3 WKWebViews are ever alive at once. The
    // visible page and its immediate swipe neighbours are always real, so paging
    // never reveals a placeholder.
    private var notebookPager: some View {
        let pages = doc?.pages ?? []
        return TabView(selection: $currentPage) {
            ForEach(Array(pages.enumerated()), id: \.offset) { idx, svg in
                pageSlot(idx: idx, svg: svg)
                    .tag(idx)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .indexViewStyle(.page(backgroundDisplayMode: .never))
    }

    /// One page slot at a fixed index. Inside the ±1 window it renders the real
    /// handwriting (`RmSVGWebView` → `WKWebView`); outside it, a lightweight
    /// white placeholder with identical frame/chrome, so paging geometry and the
    /// page indicator are byte-identical whether or not the web view is live.
    @ViewBuilder
    private func pageSlot(idx: Int, svg: String) -> some View {
        let inWindow = abs(idx - currentPage) <= 1
        Group {
            if inWindow {
                RmSVGWebView(svg: svg)
            } else {
                // Placeholder: just the white page surface — no web process.
                RmTheme.page
            }
        }
        .background(RmTheme.page)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(ScarletTheme.hairline, lineWidth: 1))
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
    }

    // MARK: states

    private var loadingState: some View {
        VStack(spacing: 14) {
            ProgressView().tint(RmTheme.accent).controlSize(.large)
            Text("Rendering your pages…")
                .font(.scarletBody)
                .foregroundStyle(ScarletTheme.textSecondary)
        }
    }

    private var errorState: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(ScarletTheme.textSecondary)
            Text(errorText)
                .font(.scarletBody)
                .foregroundStyle(ScarletTheme.textSecondary)
                .multilineTextAlignment(.center)
            Button { Task { await load() } } label: {
                Text("Try again")
                    .font(.scarletBodyEmph)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22).padding(.vertical, 11)
                    .background(RmTheme.accent, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(32)
    }

    private var emptyReader: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc")
                .font(.system(size: 32))
                .foregroundStyle(ScarletTheme.textSecondary)
            Text("Nothing to show for this document yet.")
                .font(.scarletBody)
                .foregroundStyle(ScarletTheme.textSecondary)
                .multilineTextAlignment(.center)
            Button { Task { await load() } } label: {
                Text("Try again")
                    .font(.scarletBodyEmph)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22).padding(.vertical, 11)
                    .background(RmTheme.accent, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(32)
    }

    // MARK: fetch

    private func load() async {
        loading = true
        errorText = ""
        defer { loading = false }
        do {
            let data = try await RemarkableModel.request(op: "rm_pages", body: ["id": item.id])
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if let err = obj["error"] as? String, !err.isEmpty {
                errorText = RemarkableModel.isNotConnected(err)
                    ? "Your reMarkable isn't connected anymore — reconnect from the library."
                    : err
                return
            }
            let name = (obj["name"] as? String) ?? item.name
            let kind = (obj["kind"] as? String) ?? (item.kind ?? "notebook")
            let pages = (obj["pages"] as? [String]) ?? []
            let pdfB64 = obj["pdfBase64"] as? String
            doc = RmDoc(name: name, kind: kind, pages: pages, pdfBase64: pdfB64)

            // Open where he left off, not at page 1: the server reports the last
            // page with actual handwriting (last_page); if it's absent, the very
            // last page. Only on the initial open (currentPage still 0) — a
            // retry/refresh must never yank the page from under his fingers.
            if currentPage == 0, !pages.isEmpty {
                let last = (obj["last_page"] as? Int) ?? (pages.count - 1)
                currentPage = min(max(last, 0), pages.count - 1)
            }

            // Decode a PDF/ePub source up front (guarded — never force-unwrap).
            if let pdfB64, !pdfB64.isEmpty {
                if let decoded = Data(base64Encoded: pdfB64, options: .ignoreUnknownCharacters) {
                    pdfData = decoded
                } else {
                    errorText = "This document couldn't be decoded."
                }
            }
        } catch {
            errorText = "Couldn't load this document — check your connection and try again."
        }
    }

    // MARK: Send to Notes — via the `note_create` op (same Mac-agent path as
    // NotesView). Pulls typed text (`rm_text`); when it's pure handwriting we
    // still create a titled reference note, honest about what was captured.

    private func sendToNotes() async {
        guard !sending else { return }
        sending = true
        defer { sending = false }

        let title = (doc?.name ?? item.name)

        // Typed text (empty for pure handwriting).
        var typed = ""
        if let data = try? await RemarkableModel.request(op: "rm_text", body: ["id": item.id]),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            typed = ((obj["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let noteBody: String
        if !typed.isEmpty {
            noteBody = typed
        } else if isNotebook {
            let n = pageCount
            noteBody = "Handwritten notebook — \(n) page\(n == 1 ? "" : "s") from reMarkable. "
                + "(Handwriting not yet transcribed.)"
        } else {
            noteBody = "From reMarkable: \"\(title)\"."
        }

        do {
            let data = try await RemarkableModel.request(op: "note_create",
                                                         body: ["title": title, "body": noteBody])
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if let err = obj["error"] as? String, !err.isEmpty {
                sendMessage = err
            } else if (obj["queued"] as? Bool) == true {
                sendMessage = "Queued — “\(title)” will land in Apple Notes when your home Mac wakes."
            } else {
                sendMessage = typed.isEmpty
                    ? "Saved a reference to “\(title)” in Apple Notes."
                    : "Saved “\(title)” to Apple Notes."
            }
        } catch {
            sendMessage = "Couldn't reach Scarlet — the note wasn't saved. Try again."
        }
        showSendAlert = true
    }
}

// =============================================================================
// MARK: - SVG page (WKWebView) — one self-contained SVG on a white page
// =============================================================================

/// Renders a self-contained SVG string centered on a white page, scaled to fit
/// the width with pinch-to-zoom. Works on iOS/iPad and Mac Catalyst.
struct RmSVGWebView: UIViewRepresentable {
    let svg: String

    /// Remembers the SVG last handed to `loadHTMLString`, so a repeat SwiftUI
    /// update with the same content is a no-op instead of a full reload.
    final class Coordinator {
        var loadedSVG: String?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .white
        web.scrollView.backgroundColor = .white
        web.scrollView.bouncesZoom = true
        web.scrollView.maximumZoomScale = 6
        web.scrollView.minimumZoomScale = 1
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        // SwiftUI calls updateUIView on every surrounding state change (page
        // swipes, layout passes). Reloading the same SVG each time causes a
        // white reload flash and needless churn — only reload when it changes.
        guard context.coordinator.loadedSVG != svg else { return }
        context.coordinator.loadedSVG = svg
        web.loadHTMLString(Self.html(for: svg), baseURL: nil)
    }

    /// Wrap the SVG in a minimal white page. `user-scalable=yes` gives
    /// pinch-zoom; the SVG scales to the page width and stays centered.
    static func html(for svg: String) -> String {
        let head = "<!doctype html><html><head><meta charset=\"utf-8\">"
            + "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1, minimum-scale=1, maximum-scale=6, user-scalable=yes\">"
        let css = "<style>html,body{margin:0;padding:0;height:100%;background:#ffffff;}"
            + ".wrap{display:flex;align-items:center;justify-content:center;min-height:100%;padding:10px;box-sizing:border-box;}"
            + "svg{max-width:100%;height:auto;display:block;}"
            + "img{max-width:100%;height:auto;}</style></head>"
        let bodyHTML = "<body><div class=\"wrap\">" + svg + "</div></body></html>"
        return head + css + bodyHTML
    }
}

// =============================================================================
// MARK: - PDF / ePub (PDFKit)
// =============================================================================

/// Renders a PDF (or ePub source served as PDF) from in-memory Data with
/// PDFKit — continuous vertical pages, auto-scaled, pinch-zoom built in.
struct RmPDFKitView: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .black
        if let document = PDFDocument(data: data) {
            view.document = document
        }
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document == nil, let document = PDFDocument(data: data) {
            view.document = document
        }
    }
}
