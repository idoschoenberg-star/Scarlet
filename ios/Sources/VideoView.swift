import AVKit
import Foundation
import SwiftUI
import WebKit

/// Videos — a curated, offline-first clip library. Ido tells Scarlet a topic or
/// instruction ("the 10 most popular Claude Code clips, ranked by popularity")
/// and how many he wants; that queues a fetch job on his Mac (yt-dlp), the
/// downloaded clips land in his Gallery→Clips and surface here through the same
/// REST ops the legacy web app uses. He can play any clip, keep the ones he
/// wants for offline (downloaded to the device), or delete them.
///
/// OPS (all pre-existing — reused verbatim from index.html's clip library):
///   • GET  op=clips        → { clips:[{id,title,channel,duration_s,views,thumb_url,url}] }
///   • POST op=clip_fetch_now {query,count} → queues a Mac fetch_clips job. THIS
///     IS the "video_curate" contract: a natural-language query that already
///     carries the ranking ("most popular …") + how many to pull. Reused rather
///     than adding a duplicate op.
///   • POST op=clip_delete  {id}  → removes the clip server-side.
///   • POST op=clip_played  {id}  → marks a clip watched (fire-and-forget).
///
/// STANDING FETCHES — Ido's "keep the list at ten" flow. The server tops the
/// list back up on clip_played / clip_delete; the app only shows the
/// accumulation (ready/target) and the on/off switch per fetch:
///   • GET  op=clip_rules       → { rules:[{id,query,mode,target,criteria,
///                                  enabled,ready_count,pending_count,last_run_at}] }
///   • POST op=clip_rule_save   {id?,query,mode,target} → { ok, rule:{…} } —
///     the server starts filling immediately. `mode` is one of two DIFFERENT
///     functions: "download" (files fetched on the Mac, kept offline for
///     flights) or "online" (stream-only rows: youtube_id set, storage_path
///     absent — nothing to save locally).
///   • POST op=clip_rule_toggle {id,enabled}      → { ok }
///   • POST op=clip_rule_remove {id,delete_clips} → { ok }
///
/// OFFLINE is client-side, exactly like the web app: "Save offline" downloads
/// the clip's `url` into an app-private folder so it plays with no network; the
/// metadata is cached so the library still renders offline. `ClipStore` (below)
/// is the single owner of that local folder and is also read by StorageView.

// MARK: - Local clip storage (owned here; also read by StorageView)

/// The device-side store for downloaded clips: an app-private folder holding the
/// video files, excluded from iCloud backup. Pure file-system + networking, so
/// every method is nonisolated and safe to call off the main actor.
enum ClipStore {
    private static let folderName = "ScarletClips"

    /// The clips folder, created on first use (best-effort — a failure just
    /// means nothing is cached, never a crash).
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent(folderName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // Downloaded clips are re-fetchable — keep them out of iCloud backup.
            var mutable = dir
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? mutable.setResourceValues(values)
        }
        return dir
    }

    /// A filesystem-safe filename for a clip id (ids can contain "/" etc.).
    private static func safeName(_ id: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = id.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let name = String(scalars)
        return name.isEmpty ? "clip" : name
    }

    static func localURL(for id: String) -> URL {
        directory.appendingPathComponent(safeName(id) + ".mp4")
    }

    static func isOffline(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: localURL(for: id).path)
    }

    /// Download a remote clip URL into the store. Throws on a bad URL / HTTP
    /// error so the caller can surface an honest message.
    static func download(id: String, from remote: String) async throws {
        guard let url = URL(string: remote) else { throw URLError(.badURL) }
        let (tmp, resp) = try await URLSession.shared.download(from: url)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        let dest = localURL(for: id)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
    }

    static func deleteLocal(_ id: String) {
        try? FileManager.default.removeItem(at: localURL(for: id))
    }

    /// Total bytes of every downloaded clip — for StorageView. Off-main safe.
    static func totalBytes() -> Int64 {
        let keys: [URLResourceKey] = [.fileSizeKey]
        let items = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys)) ?? []
        var sum: Int64 = 0
        for item in items {
            if let size = (try? item.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                sum += Int64(size)
            }
        }
        return sum
    }

    static func count() -> Int {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return items.filter { $0.hasSuffix(".mp4") }.count
    }

    /// Delete every downloaded clip. Returns how many files were removed.
    @discardableResult
    static func deleteAll() -> Int {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        var removed = 0
        for item in items where item.pathExtension == "mp4" {
            if (try? FileManager.default.removeItem(at: item)) != nil { removed += 1 }
        }
        return removed
    }
}

/// Tiny metadata cache so the offline library still renders titles/thumbs with
/// no network (mirrors the web app's `scarletClipMeta` localStorage cache).
enum ClipMetaCache {
    private static let key = "scarletClipMeta"

    static func put(_ clip: VideoModel.Clip) {
        var all = read()
        all[clip.id] = [
            "id": clip.id, "title": clip.title, "channel": clip.channel,
            "duration_s": clip.durationS, "views": clip.views,
            "thumb_url": clip.thumbURL ?? "", "url": clip.url ?? "",
            "storage_path": clip.storagePath ?? "", "youtube_id": clip.youtubeID ?? "",
        ]
        write(all)
    }

    static func remove(_ id: String) {
        var all = read()
        all.removeValue(forKey: id)
        write(all)
    }

    /// Reconstruct clips for whatever is downloaded offline — the offline view.
    static func offlineClips() -> [VideoModel.Clip] {
        let all = read()
        return all.values.compactMap { VideoModel.parseClip($0) }
            .filter { ClipStore.isOffline($0.id) }
            .sorted { $0.title < $1.title }
    }

    private static func read() -> [String: [String: Any]] {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: [String: Any]]) ?? [:]
    }
    private static func write(_ dict: [String: [String: Any]]) {
        UserDefaults.standard.set(dict, forKey: key)
    }
}

// MARK: - Model

@MainActor
final class VideoModel: ObservableObject {

    /// One clip, as `op=clips` returns it.
    struct Clip: Identifiable, Equatable {
        let id: String
        let title: String
        let channel: String
        let durationS: Int
        let views: Int
        let thumbURL: String?
        let url: String?     // remote stream/download URL; nil until the Mac finishes
        let storagePath: String?  // server-side file path; absent for online clips
        let youtubeID: String?    // set for stream-only ("online") clips

        /// Stream-only clip from an ONLINE fetch: no file anywhere — it plays
        /// by streaming YouTube and there is nothing to save for offline.
        var isOnlineStream: Bool { storagePath == nil && youtubeID != nil }

        /// Playable if it has a remote source, a stream, or a downloaded copy.
        var hasSource: Bool { url != nil || isOnlineStream || ClipStore.isOffline(id) }
    }

    /// One standing fetch, as `op=clip_rules` returns it.
    struct FetchRule: Identifiable, Equatable {
        let id: String
        let query: String
        let mode: String       // "download" | "online" — two different functions
        let target: Int
        let criteria: String
        var enabled: Bool      // mutable for the optimistic toggle flip
        let readyCount: Int
        let pendingCount: Int
        let lastRunAt: String?

        var isDownload: Bool { mode == "download" }
    }

    @Published var clips: [Clip] = []
    @Published var offlineIDs: Set<String> = []
    @Published var downloading: Set<String> = []
    @Published var loading = false
    @Published var errorText = ""
    /// A curate/fetch job is running on the Mac; drives the "downloading N…" banner.
    @Published var fetching = false
    @Published var fetchNote = ""

    // Standing fetches.
    @Published var rules: [FetchRule] = []
    @Published var rulesError = ""
    /// The last `op=clips` load failed (URLError) — the device looks offline.
    @Published var networkDown = false
    /// Honest stall line when a download fetch has pending items but nothing
    /// has arrived after ~3 minutes of polling (the Mac looks offline).
    @Published var macStallNote = ""

    /// How many freshly-fetched clips still to auto-download for offline.
    private var autoOfflineRemaining = 0
    private var pollTask: Task<Void, Never>?
    private var rulesPollTask: Task<Void, Never>?

    // MARK: load

    func load() async {
        if clips.isEmpty { loading = true }
        defer { loading = false }
        do {
            let data = try await Self.request("op=clips", method: "GET")
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let arr = (obj["clips"] as? [[String: Any]]) ?? []
            let parsed = arr.compactMap(Self.parseClip)
            clips = parsed
            errorText = ""
            networkDown = false
            // Keep the offline metadata cache warm for anything already saved.
            for c in parsed where ClipStore.isOffline(c.id) { ClipMetaCache.put(c) }
        } catch {
            networkDown = true
            // Offline: fall back to the downloaded library from the metadata cache.
            if clips.isEmpty {
                let cached = ClipMetaCache.offlineClips()
                clips = cached
                errorText = cached.isEmpty
                    ? "Couldn't reach your clip library — check your connection."
                    : ""
            }
        }
        recomputeOffline()
    }

    private func recomputeOffline() {
        offlineIDs = clips.reduce(into: Set<String>()) {
            if ClipStore.isOffline($1.id) { $0.insert($1.id) }
        }
    }

    // MARK: curate (queue a Mac fetch) — the "video_curate" flow

    /// Queue a popularity-ranked fetch on the Mac, then poll for the arrivals and
    /// auto-download the first `count` of them for offline (Ido's exact ask:
    /// "download the first N to my phone for offline").
    func curate(query: String, count: Int) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !fetching else { return }
        let n = min(max(count, 1), 25)
        fetching = true
        fetchNote = "Scarlet is fetching \(n) clip\(n == 1 ? "" : "s")…"
        errorText = ""
        autoOfflineRemaining = n
        let known = Set(clips.map { $0.id })
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await VideoModel.request("op=clip_fetch_now", method: "POST",
                                                 body: ["query": q, "count": n])
            } catch {
                // The Mac job may still run even if the queue call hiccuped;
                // keep polling rather than declaring failure prematurely.
            }
            await self.pollForArrivals(known: known, want: n)
        }
    }

    /// Poll `op=clips` for up to ~3 minutes; as new clips appear, auto-save the
    /// first `want` for offline. Stops early once enough new clips have landed.
    private func pollForArrivals(known: Set<String>, want: Int) async {
        var elapsed = 0
        while !Task.isCancelled && elapsed < 180 {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if Task.isCancelled { break }
            elapsed += 5
            await load()
            let fresh = clips.filter { !known.contains($0.id) }
            for c in fresh where c.url != nil && !ClipStore.isOffline(c.id) {
                if autoOfflineRemaining <= 0 { break }
                autoOfflineRemaining -= 1
                await saveOffline(c)
            }
            if !fresh.isEmpty {
                fetchNote = "Downloaded \(fresh.count) new clip\(fresh.count == 1 ? "" : "s")…"
            }
            if fresh.count >= want { break }
        }
        fetching = false
        fetchNote = ""
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        rulesPollTask?.cancel()
        rulesPollTask = nil
    }

    // MARK: standing fetches (the "keep the list at ten" rules)

    /// Load the standing fetches. Offline is calm (the view greys online rows
    /// and says so); any real server error is surfaced honestly.
    func loadRules() async {
        do {
            _ = try await fetchRules()
            rulesError = ""
            restartRulesPollIfNeeded()
        } catch {
            if !(error is URLError) {
                rulesError = Self.honestMessage(error, fallback: "Couldn't load your fetches.")
            }
        }
    }

    /// Create a standing fetch. The server starts filling immediately; the new
    /// row appears at 0/N and the poll watches it fill up. Throws the server's
    /// own message so the editor can show it.
    func saveRule(query: String, mode: String, target: Int) async throws {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { throw ClipAPIError(message: "Give the fetch a topic first.") }
        let body: [String: Any] = ["query": q, "mode": mode, "target": min(max(target, 1), 10)]
        let data = try await Self.requestChecked("op=clip_rule_save", method: "POST", body: body)
        try Self.ensureOK(data, fallback: "The server couldn't save that fetch.")
        await loadRules()
    }

    /// Turn a fetch on/off. Optimistic: the switch flips immediately and is
    /// reverted (with an honest message) if the server says no.
    func setRule(_ id: String, enabled: Bool) {
        guard let idx = rules.firstIndex(where: { $0.id == id }),
              rules[idx].enabled != enabled else { return }
        let previous = rules[idx].enabled
        rules[idx].enabled = enabled
        Task {
            do {
                let data = try await Self.requestChecked(
                    "op=clip_rule_toggle", method: "POST",
                    body: ["id": id, "enabled": enabled])
                try Self.ensureOK(data, fallback: "The server couldn't switch that fetch.")
                rulesError = ""
                restartRulesPollIfNeeded()
            } catch {
                if let j = rules.firstIndex(where: { $0.id == id }) {
                    rules[j].enabled = previous
                }
                rulesError = Self.honestMessage(
                    error,
                    fallback: "Couldn't turn that fetch \(enabled ? "on" : "off") — it's back the way it was.")
            }
        }
    }

    /// Remove a fetch, optionally deleting the clips it accumulated.
    func removeRule(_ rule: FetchRule, deleteClips: Bool) {
        Task {
            do {
                let data = try await Self.requestChecked(
                    "op=clip_rule_remove", method: "POST",
                    body: ["id": rule.id, "delete_clips": deleteClips])
                try Self.ensureOK(data, fallback: "The server couldn't remove that fetch.")
                rules.removeAll { $0.id == rule.id }
                rulesError = ""
                if deleteClips { await load() }
                restartRulesPollIfNeeded()
            } catch {
                rulesError = Self.honestMessage(error, fallback: "Couldn't remove that fetch.")
            }
        }
    }

    /// GET + parse `op=clip_rules`, replacing `rules`. Shared by the initial
    /// load and the pending-items poll loop.
    @discardableResult
    private func fetchRules() async throws -> [FetchRule] {
        let data = try await Self.requestChecked("op=clip_rules", method: "GET")
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let arr = (obj["rules"] as? [[String: Any]]) ?? []
        let parsed = arr.compactMap(Self.parseRule)
        rules = parsed
        return parsed
    }

    /// While any enabled fetch has pending items, re-check every 15s so the
    /// accumulation counts fill in live. If a DOWNLOAD fetch stays pending for
    /// ~3 minutes with nothing arriving, say honestly that the Mac looks
    /// offline (downloads run there, not on this device).
    private func restartRulesPollIfNeeded() {
        rulesPollTask?.cancel()
        macStallNote = ""
        guard rules.contains(where: { $0.enabled && $0.pendingCount > 0 }) else { return }
        rulesPollTask = Task { [weak self] in
            guard let self else { return }
            var lastProgress = Date()
            var lastReady = self.rules.reduce(0) { $0 + $1.readyCount }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if Task.isCancelled { break }
                guard let updated = try? await self.fetchRules() else { continue }
                let ready = updated.reduce(0) { $0 + $1.readyCount }
                if ready > lastReady {
                    lastReady = ready
                    lastProgress = Date()
                    self.macStallNote = ""
                    await self.load()   // fresh clips have landed — show them
                }
                guard updated.contains(where: { $0.enabled && $0.pendingCount > 0 }) else {
                    self.macStallNote = ""
                    break
                }
                let downloadStalled = updated.contains { $0.enabled && $0.isDownload && $0.pendingCount > 0 }
                if downloadStalled && Date().timeIntervalSince(lastProgress) > 180 {
                    self.macStallNote = "Downloads run on Ido's Mac — it looks offline right now."
                }
            }
        }
    }

    // MARK: offline + delete

    /// Download a clip into the on-device store so it plays with no network.
    func saveOffline(_ clip: Clip) async {
        guard let url = clip.url, !ClipStore.isOffline(clip.id) else {
            offlineIDs.insert(clip.id)
            return
        }
        downloading.insert(clip.id)
        defer { downloading.remove(clip.id) }
        do {
            try await ClipStore.download(id: clip.id, from: url)
            ClipMetaCache.put(clip)
            offlineIDs.insert(clip.id)
        } catch {
            errorText = "Couldn't download that clip for offline — try again."
        }
    }

    /// Remove only the downloaded copy; the clip stays in the library.
    func removeOffline(_ clip: Clip) {
        ClipStore.deleteLocal(clip.id)
        ClipMetaCache.remove(clip.id)
        offlineIDs.remove(clip.id)
    }

    /// Delete the clip everywhere: the local copy and the server-side library row.
    func deleteClip(_ clip: Clip) {
        ClipStore.deleteLocal(clip.id)
        ClipMetaCache.remove(clip.id)
        offlineIDs.remove(clip.id)
        clips.removeAll { $0.id == clip.id }
        Task {
            _ = try? await Self.request("op=clip_delete", method: "POST", body: ["id": clip.id])
        }
    }

    /// Fire-and-forget "watched" ping (drives daily-rule cleanup server-side).
    func markPlayed(_ clip: Clip) {
        Task {
            _ = try? await Self.request("op=clip_played", method: "POST", body: ["id": clip.id])
        }
    }

    // MARK: parsing + plumbing

    /// Parse one clip dict (from the server OR the offline cache). nonisolated so
    /// the cache can build clips off the main actor.
    nonisolated static func parseClip(_ d: [String: Any]) -> Clip? {
        guard let id = d["id"] as? String, !id.isEmpty else { return nil }
        func intVal(_ any: Any?) -> Int {
            if let i = any as? Int { return i }
            if let dd = any as? Double { return Int(dd) }
            if let s = any as? String { return Int(s) ?? 0 }
            return 0
        }
        func strOrNil(_ any: Any?) -> String? {
            guard let s = any as? String, !s.isEmpty else { return nil }
            return s
        }
        return Clip(
            id: id,
            title: (d["title"] as? String) ?? "Clip",
            channel: (d["channel"] as? String) ?? "",
            durationS: intVal(d["duration_s"]),
            views: intVal(d["views"]),
            thumbURL: strOrNil(d["thumb_url"]),
            url: strOrNil(d["url"]),
            storagePath: strOrNil(d["storage_path"]),
            youtubeID: strOrNil(d["youtube_id"])
        )
    }

    /// Parse one standing-fetch dict from `op=clip_rules`.
    nonisolated static func parseRule(_ d: [String: Any]) -> FetchRule? {
        func str(_ any: Any?) -> String? {
            if let s = any as? String, !s.isEmpty { return s }
            if let i = any as? Int { return String(i) }
            return nil
        }
        func intVal(_ any: Any?) -> Int {
            if let i = any as? Int { return i }
            if let dd = any as? Double { return Int(dd) }
            if let s = any as? String { return Int(s) ?? 0 }
            return 0
        }
        guard let id = str(d["id"]), let query = str(d["query"]) else { return nil }
        return FetchRule(
            id: id,
            query: query,
            mode: (d["mode"] as? String) == "online" ? "online" : "download",
            target: max(1, intVal(d["target"])),
            criteria: (d["criteria"] as? String) ?? "",
            enabled: (d["enabled"] as? Bool) ?? true,
            readyCount: intVal(d["ready_count"]),
            pendingCount: intVal(d["pending_count"]),
            lastRunAt: str(d["last_run_at"])
        )
    }

    /// Same shape as DraftModel: apiBase + v=2 + x-scarlet-token.
    static func request(_ query: String, method: String,
                        body: [String: Any]? = nil) async throws -> Data {
        guard let url = URL(string: "\(AppConfig.apiBase)/app-api?v=2&\(query)") else {
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

    /// Like `request`, but reads an `{error}` JSON body on a failed status so
    /// the caller can surface the server's honest message — never silent.
    static func requestChecked(_ query: String, method: String,
                               body: [String: Any]? = nil) async throws -> Data {
        guard let url = URL(string: "\(AppConfig.apiBase)/app-api?v=2&\(query)") else {
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
            if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let msg = obj["error"] as? String, !msg.isEmpty {
                throw ClipAPIError(message: msg)
            }
            throw URLError(.badServerResponse)
        }
        return data
    }

    /// A 200 body must still say `ok:true`; otherwise throw its `{error}`.
    nonisolated static func ensureOK(_ data: Data, fallback: String) throws {
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if (obj["ok"] as? Bool) == true { return }
        let msg = (obj["error"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        throw ClipAPIError(message: msg ?? fallback)
    }

    /// The server's own words when it gave any; the honest fallback otherwise.
    nonisolated static func honestMessage(_ error: Error, fallback: String) -> String {
        (error as? ClipAPIError)?.message ?? fallback
    }
}

/// A server-reported error carrying the `{error}` body's message verbatim.
struct ClipAPIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - View

struct VideoView: View {
    @StateObject private var model = VideoModel()
    @EnvironmentObject private var convo: Conversation

    private let scarletRose = Color(red: 1, green: 0.35, blue: 0.42)
    private let paper = Color(red: 0.96, green: 0.94, blue: 0.94)

    // Curate bar.
    @State private var query = ""
    @State private var count = 10
    @FocusState private var queryFocused: Bool

    // Standing-fetch editor (INLINE, not a sheet — the one sheet stays the player).
    @State private var showingRuleEditor = false
    @State private var newQuery = ""
    @State private var newMode = "download"
    @State private var newTarget = 5
    @State private var editorSaving = false
    @State private var editorError = ""
    @FocusState private var newQueryFocused: Bool

    /// Both removals (a clip, a fetch) share the view's ONE confirmationDialog.
    private enum PendingRemoval {
        case clip(VideoModel.Clip)
        case rule(VideoModel.FetchRule)
    }

    // One sheet (Mac-Catalyst rule) for playback; confirmationDialog for removals.
    @State private var playing: VideoModel.Clip?
    @State private var pendingRemoval: PendingRemoval?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    fetchesSection
                    curateCard
                    if model.fetching { fetchingBanner }
                    libraryHeader
                    libraryContent
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .scarletScreen()   // shared near-black ink ground; red accent stays as chrome
            .scrollDismissesKeyboard(.interactively)
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom) {
                ScarletPresenceView(convo: convo).padding(.vertical, 6)
            }
            .onAppear { convo.setFocus(browsingFocus) }
            .onChange(of: model.clips.count) { _, _ in convo.setFocus(browsingFocus) }
            .confirmationDialog(
                removalTitle,
                isPresented: Binding(get: { pendingRemoval != nil },
                                     set: { if !$0 { pendingRemoval = nil } }),
                titleVisibility: .visible
            ) {
                switch pendingRemoval {
                case .some(.clip(let c)):
                    Button("Delete", role: .destructive) {
                        model.deleteClip(c)
                        pendingRemoval = nil
                    }
                    Button("Cancel", role: .cancel) { pendingRemoval = nil }
                case .some(.rule(let r)):
                    Button("Remove fetch, keep its clips") {
                        model.removeRule(r, deleteClips: false)
                        pendingRemoval = nil
                    }
                    Button("Remove fetch and delete its clips", role: .destructive) {
                        model.removeRule(r, deleteClips: true)
                        pendingRemoval = nil
                    }
                    Button("Cancel", role: .cancel) { pendingRemoval = nil }
                case .none:
                    EmptyView()
                }
            } message: {
                Text(removalMessage)
            }
            // One .sheet only — the video player (Mac-Catalyst one-sheet rule).
            // Downloaded clips and ONLINE (stream) clips both ride this sheet;
            // clipPlayer(for:) picks the engine.
            .sheet(item: $playing) { clip in
                clipPlayer(for: clip)
            }
        }
        .task {
            await model.load()
            await model.loadRules()
        }
        .onDisappear { model.stopPolling() }
    }

    private var removalTitle: String {
        switch pendingRemoval {
        case .some(.clip): return "Delete this clip?"
        case .some(.rule): return "Remove this fetch?"
        case .none: return ""
        }
    }

    private var removalMessage: String {
        switch pendingRemoval {
        case .some(.clip(let c)):
            return "“\(c.title)” will be removed from your library and this phone."
        case .some(.rule(let r)):
            return "“\(r.query)” will stop fetching. You can keep the clips it brought, or delete them too."
        case .none:
            return ""
        }
    }

    // MARK: standing fetches

    /// The section only takes over the top of the page when there are rules or
    /// the editor is open; otherwise just the compact "+ New fetch" affordance.
    @ViewBuilder
    private var fetchesSection: some View {
        if model.rules.isEmpty && !showingRuleEditor {
            Button {
                openRuleEditor()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 14, weight: .semibold))
                    Text("New fetch")
                        .font(.scarletCaptionEmph)
                }
                .foregroundStyle(scarletRose)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(.white.opacity(0.05), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.08), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Fetches")
                        .font(.system(size: 13, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(.white.opacity(0.55))
                    Spacer()
                    if !showingRuleEditor {
                        Button {
                            openRuleEditor()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "plus.circle")
                                    .font(.system(size: 13, weight: .semibold))
                                Text("New fetch")
                                    .font(.scarletCaptionEmph)
                            }
                            .foregroundStyle(scarletRose)
                        }
                        .buttonStyle(.plain)
                    }
                }
                ForEach(model.rules) { rule in
                    ruleRow(rule)
                }
                if showingRuleEditor { ruleEditor }
                if model.networkDown && model.rules.contains(where: { !$0.isDownload }) {
                    Text("Online fetches need internet — your downloaded clips are ready below.")
                        .font(.scarletCaption)
                        .foregroundStyle(.white.opacity(0.5))
                }
                if !model.macStallNote.isEmpty {
                    Text(model.macStallNote)
                        .font(.scarletCaption)
                        .foregroundStyle(.white.opacity(0.5))
                }
                if !model.rulesError.isEmpty {
                    Text(model.rulesError)
                        .font(.scarletDetail)
                        .foregroundStyle(Color(red: 1, green: 0.5, blue: 0.5))
                }
            }
        }
    }

    /// One standing fetch: mode glyph, query, accumulation ("3/10 · +2 coming"),
    /// and the on/off switch. Remove lives in the context menu (confirmed).
    private func ruleRow(_ rule: VideoModel.FetchRule) -> some View {
        // Offline, an online-mode fetch can't do anything — grey it calmly.
        let dimmed = model.networkDown && !rule.isDownload
        return HStack(spacing: 12) {
            Image(systemName: rule.isDownload ? "arrow.down.circle" : "play.circle")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(rule.enabled ? scarletRose : .white.opacity(0.35))
            VStack(alignment: .leading, spacing: 3) {
                Text(rule.query)
                    .font(.scarletDetailEmph)
                    .foregroundStyle(paper)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Text("\(rule.readyCount)/\(rule.target)")
                        .font(.scarletCaptionEmph)
                        .foregroundStyle(rule.readyCount >= rule.target
                                         ? scarletRose : .white.opacity(0.65))
                    if rule.pendingCount > 0 {
                        Text("+\(rule.pendingCount) coming")
                            .font(.scarletCaption)
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    if !rule.enabled {
                        Text("Off")
                            .font(.scarletCaption)
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { rule.enabled },
                set: { model.setRule(rule.id, enabled: $0) }
            ))
            .labelsHidden()
            .tint(scarletRose)
            .disabled(dimmed)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.08), lineWidth: 1))
        .opacity(dimmed ? 0.45 : 1)
        .contextMenu {
            Button(role: .destructive) {
                pendingRemoval = .rule(rule)
            } label: {
                Label("Remove fetch", systemImage: "trash")
            }
        }
    }

    /// Inline editor — deliberately NOT a sheet (the view's one sheet is the
    /// player). Topic, the two clearly-labeled functions, target, save.
    private var ruleEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New fetch")
                .font(.scarletDetailEmph)
                .foregroundStyle(paper)
            TextField("A topic Scarlet keeps stocked — e.g. Claude Code clips",
                      text: $newQuery, axis: .vertical)
                .lineLimit(1...3)
                .textInputAutocapitalization(.sentences)
                .padding(12)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
                .focused($newQueryFocused)
            modeOption("download", icon: "arrow.down.circle",
                       title: "Fetch & download",
                       subtitle: "Kept offline on this device — ready for flights")
            modeOption("online", icon: "play.circle",
                       title: "Fetch online",
                       subtitle: "Watch now by streaming — needs internet")
            HStack(spacing: 10) {
                Text("Keep ready")
                    .font(.scarletDetail)
                    .foregroundStyle(.secondary)
                Text("\(newTarget)")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(paper)
                    .frame(minWidth: 26)
                Stepper("", value: $newTarget, in: 1...10)
                    .labelsHidden()
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
            if !editorError.isEmpty {
                Text(editorError)
                    .font(.scarletDetail)
                    .foregroundStyle(Color(red: 1, green: 0.5, blue: 0.5))
            }
            HStack {
                Button("Cancel") {
                    showingRuleEditor = false
                    editorError = ""
                    newQueryFocused = false
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .buttonStyle(.plain)
                Spacer()
                Button {
                    Task { await saveNewRule() }
                } label: {
                    HStack(spacing: 6) {
                        if editorSaving {
                            ProgressView().controlSize(.mini).tint(.white)
                        } else {
                            Image(systemName: "plus.circle.fill")
                        }
                        Text(editorSaving ? "Starting…" : "Start fetch")
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(Capsule().fill(canSaveRule ? scarletRose : scarletRose.opacity(0.35)))
                }
                .buttonStyle(.plain)
                .disabled(!canSaveRule)
            }
        }
        .padding(14)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.08), lineWidth: 1))
    }

    private func modeOption(_ mode: String, icon: String,
                            title: String, subtitle: String) -> some View {
        let selected = newMode == mode
        return Button {
            newMode = mode
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(selected ? scarletRose : .white.opacity(0.5))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.scarletDetailEmph)
                        .foregroundStyle(paper)
                    Text(subtitle)
                        .font(.scarletCaption)
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(selected ? scarletRose : .white.opacity(0.3))
            }
            .padding(10)
            .background(.white.opacity(selected ? 0.08 : 0.03),
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .stroke(selected ? scarletRose.opacity(0.5) : .white.opacity(0.06), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var canSaveRule: Bool {
        !newQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !editorSaving
    }

    private func openRuleEditor() {
        newQuery = ""
        newMode = "download"
        newTarget = 5
        editorError = ""
        showingRuleEditor = true
    }

    private func saveNewRule() async {
        guard canSaveRule else { return }
        editorSaving = true
        do {
            try await model.saveRule(query: newQuery, mode: newMode, target: newTarget)
            showingRuleEditor = false
            editorError = ""
            newQueryFocused = false
        } catch {
            editorError = VideoModel.honestMessage(
                error, fallback: "Couldn't start that fetch — try again.")
        }
        editorSaving = false
    }

    // MARK: curate bar

    private var curateCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(scarletRose)
                Text("Curate")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(paper)
            }
            TextField("A topic or instruction — e.g. 10 most popular Claude Code clips",
                      text: $query, axis: .vertical)
                .lineLimit(1...3)
                .textInputAutocapitalization(.sentences)
                .padding(12)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
                .focused($queryFocused)
            HStack(spacing: 12) {
                HStack(spacing: 10) {
                    Text("How many")
                        .font(.scarletDetail)
                        .foregroundStyle(.secondary)
                    Text("\(count)")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(paper)
                        .frame(minWidth: 26)
                    Stepper("", value: $count, in: 1...25)
                        .labelsHidden()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
                Spacer()
                Button {
                    fetch()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("Fetch")
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(Capsule().fill(canFetch ? scarletRose : scarletRose.opacity(0.35)))
                }
                .buttonStyle(.plain)
                .disabled(!canFetch)
            }
            // Voice hint — the voice-first path to the very same place.
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .font(.system(size: 11, weight: .semibold))
                Text("Or ask Scarlet to bring you videos about something.")
                    .font(.scarletDetail)
            }
            .foregroundStyle(scarletRose.opacity(0.9))
        }
        .padding(16)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.09), lineWidth: 1))
    }

    private var canFetch: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !model.fetching
    }

    private func fetch() {
        guard canFetch else { return }
        model.curate(query: query, count: count)
        query = ""
        queryFocused = false
    }

    private var fetchingBanner: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small).tint(scarletRose)
            Text(model.fetchNote.isEmpty ? "Downloading…" : model.fetchNote)
                .font(.scarletDetail)
                .foregroundStyle(scarletRose.opacity(0.95))
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(scarletRose.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: library

    private var libraryHeader: some View {
        HStack {
            Text("Library" + (model.clips.isEmpty ? "" : " · \(model.clips.count)"))
                .font(.system(size: 13, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.white.opacity(0.55))
            Spacer()
            Button {
                Task { await model.load() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(scarletRose)
            }
            .buttonStyle(.plain)
            .disabled(model.loading)
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private var libraryContent: some View {
        if model.loading && model.clips.isEmpty {
            VStack(spacing: 10) {
                ProgressView().tint(scarletRose)
                Text("Opening your clip library…")
                    .font(.scarletDetail).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        } else if model.clips.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "play.rectangle.on.rectangle")
                    .font(.title2).foregroundStyle(.secondary)
                Text(model.errorText.isEmpty
                     ? "No clips yet — ask above, or tell Scarlet what to bring you."
                     : model.errorText)
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        } else {
            if !model.errorText.isEmpty {
                Text(model.errorText)
                    .font(.scarletDetail)
                    .foregroundStyle(Color(red: 1, green: 0.5, blue: 0.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            LazyVStack(spacing: 14) {
                ForEach(model.clips) { clip in
                    clipCard(clip)
                }
            }
        }
    }

    private func clipCard(_ clip: VideoModel.Clip) -> some View {
        let isOffline = model.offlineIDs.contains(clip.id)
        let isDownloading = model.downloading.contains(clip.id)
        return VStack(alignment: .leading, spacing: 0) {
            thumbnail(clip, isOffline: isOffline)
            VStack(alignment: .leading, spacing: 8) {
                // Title in its own reading direction (Hebrew RTL, English LTR).
                Text(clip.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(paper)
                    .lineLimit(2)
                    .multilineTextAlignment(clip.title.isRTLDominant ? .trailing : .leading)
                    .frame(maxWidth: .infinity,
                           alignment: clip.title.isRTLDominant ? .trailing : .leading)
                    .environment(\.layoutDirection,
                                 clip.title.isRTLDominant ? .rightToLeft : .leftToRight)
                if !metaLine(clip).isEmpty {
                    Text(metaLine(clip))
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
                clipActions(clip, isOffline: isOffline, isDownloading: isDownloading)
            }
            .padding(14)
        }
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.08), lineWidth: 1))
    }

    private func thumbnail(_ clip: VideoModel.Clip, isOffline: Bool) -> some View {
        Button {
            if clip.hasSource { playing = clip }
        } label: {
            ZStack {
                Rectangle().fill(Color.black.opacity(0.55))
                if let t = clip.thumbURL, let u = URL(string: t) {
                    AsyncImage(url: u) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().scaledToFill()
                        case .failure:
                            placeholderArt
                        case .empty:
                            ProgressView().tint(.white.opacity(0.6))
                        @unknown default:
                            placeholderArt
                        }
                    }
                } else {
                    placeholderArt
                }
                // Play glyph, only when there's something to play.
                if clip.hasSource {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 46))
                        .foregroundStyle(.white.opacity(0.92))
                        .shadow(color: .black.opacity(0.5), radius: 6)
                }
                // Duration + offline/stream badges. An ONLINE clip streams and
                // never shows the offline checkmark.
                VStack {
                    HStack {
                        Spacer()
                        if isOffline {
                            badge("arrow.down.circle.fill", "Offline", tint: scarletRose)
                        } else if clip.isOnlineStream {
                            badge("antenna.radiowaves.left.and.right", "Stream",
                                  tint: .black.opacity(0.6))
                        }
                    }
                    Spacer()
                    HStack {
                        Spacer()
                        if clip.durationS > 0 {
                            Text(Self.durationString(clip.durationS))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(.black.opacity(0.6), in: Capsule())
                        }
                    }
                }
                .padding(8)
            }
            .frame(height: 176)
            .frame(maxWidth: .infinity)
            .clipped()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private var placeholderArt: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.2, green: 0.05, blue: 0.1),
                                    Color(red: 0.08, green: 0.03, blue: 0.06)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "film")
                .font(.system(size: 30))
                .foregroundStyle(.white.opacity(0.25))
        }
    }

    private func badge(_ icon: String, _ text: String, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 10, weight: .bold))
            Text(text).font(.system(size: 10, weight: .bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(tint.opacity(0.9), in: Capsule())
    }

    private func clipActions(_ clip: VideoModel.Clip, isOffline: Bool, isDownloading: Bool) -> some View {
        HStack(spacing: 10) {
            if clip.isOnlineStream && !isOffline {
                // Stream-only clip — there is no file to keep on the phone;
                // that's what a "Fetch & download" rule is for.
                HStack(spacing: 5) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Streams online")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.45))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.white.opacity(0.04), in: Capsule())
            } else {
                // Save offline / Saved toggle.
                Button {
                    if isOffline { model.removeOffline(clip) }
                    else { Task { await model.saveOffline(clip) } }
                } label: {
                    HStack(spacing: 5) {
                        if isDownloading {
                            ProgressView().controlSize(.mini).tint(scarletRose)
                        } else {
                            Image(systemName: isOffline ? "checkmark.circle.fill" : "arrow.down.circle")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        Text(isDownloading ? "Saving…" : (isOffline ? "Saved offline" : "Save offline"))
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(isOffline ? scarletRose : .white.opacity(0.85))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.white.opacity(0.06), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isDownloading || (!isOffline && clip.url == nil))
            }
            Spacer()
            // Delete (confirmed).
            Button {
                pendingRemoval = .clip(clip)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 2)
    }

    // MARK: player sheet (plain view — reads no @EnvironmentObject)

    @ViewBuilder
    private func clipPlayer(for clip: VideoModel.Clip) -> some View {
        if ClipStore.isOffline(clip.id) {
            ClipPlayerView(title: clip.title, url: ClipStore.localURL(for: clip.id)) {
                model.markPlayed(clip)
            }
        } else if clip.isOnlineStream, let ytID = clip.youtubeID {
            // ONLINE clip — stream the YouTube embed; played on dismissal
            // (there's no reliable end-of-playback signal from the embed).
            ClipStreamView(youtubeID: ytID)
                .onDisappear { model.markPlayed(clip) }
        } else if let remote = clip.url.flatMap({ URL(string: $0) }) {
            ClipPlayerView(title: clip.title, url: remote) { model.markPlayed(clip) }
        } else {
            ZStack {
                Color.black.ignoresSafeArea()
                Text("This clip has no playable source yet.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    // MARK: helpers

    private func metaLine(_ clip: VideoModel.Clip) -> String {
        var parts: [String] = []
        if !clip.channel.isEmpty { parts.append(clip.channel) }
        if clip.views > 0 { parts.append(Self.viewsString(clip.views)) }
        return parts.joined(separator: " · ")
    }

    private var browsingFocus: String {
        let n = model.clips.count
        return "[FOCUS] Ido is on the Videos screen (\(n) clip\(n == 1 ? "" : "s") in his library). "
            + "He can ask you to bring videos about a topic — that queues a Mac fetch (clip_fetch_now); "
            + "to keep one for offline he taps Save offline. No single clip is open."
    }

    static func durationString(_ s: Int) -> String {
        let sec = max(0, s)
        let h = sec / 3600, m = (sec % 3600) / 60, r = sec % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, r) }
        return String(format: "%d:%02d", m, r)
    }

    static func viewsString(_ v: Int) -> String {
        if v >= 1_000_000 { return String(format: "%.1fM views", Double(v) / 1_000_000) }
        if v >= 1_000 { return "\(Int((Double(v) / 1000).rounded()))K views" }
        return "\(v) views"
    }
}

// MARK: - Player (self-contained; no @EnvironmentObject to re-inject)

/// Full-bleed AVKit player on black, with its own close affordance. Reports the
/// end of playback so the library can mark the clip watched.
struct ClipPlayerView: View {
    let title: String
    let url: URL
    var onEnded: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var endObserver: NSObjectProtocol?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            } else {
                ProgressView().tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Color.black.opacity(0.55)))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.top, 14)
        }
        .onAppear {
            let p = AVPlayer(url: url)
            player = p
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: p.currentItem, queue: .main
            ) { _ in onEnded() }
            p.play()
        }
        .onDisappear {
            player?.pause()
            if let endObserver {
                NotificationCenter.default.removeObserver(endObserver)
            }
        }
    }
}

// MARK: - Stream player (ONLINE clips; self-contained, no @EnvironmentObject)

/// Full-bleed YouTube-embed streaming for ONLINE clips (no file anywhere),
/// with the same black ground and close affordance as ClipPlayerView. Rides
/// the library's single player sheet.
struct ClipStreamView: View {
    let youtubeID: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            YouTubeEmbedWebView(youtubeID: youtubeID)
                .ignoresSafeArea()
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Color.black.opacity(0.55)))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.top, 14)
        }
    }
}

/// The WKWebView host for the YouTube embed (AVPlayer can't stream YouTube).
private struct YouTubeEmbedWebView: UIViewRepresentable {
    let youtubeID: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.isScrollEnabled = false
        web.scrollView.backgroundColor = .black
        if let url = URL(string: "https://www.youtube.com/embed/\(youtubeID)?playsinline=1") {
            web.load(URLRequest(url: url))
        }
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
