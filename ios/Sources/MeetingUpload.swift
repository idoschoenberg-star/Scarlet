import Foundation

/// The phone recorder's pipe to the `meeting-capture` door (base- backend,
/// commission 2026-11-07 "the capture layer"). Shared by the iPhone and the
/// Watch (Foundation only).
///
/// A recording is a folder on disk, `Application Support/MeetingRecordings/<sid>/`,
/// holding one `000001.m4a` per minute plus `meta.json`. The uploader sends
/// the minutes in order, deletes each one the server has stored, and calls
/// finish once the folder holds only `meta.json` with `stopped` set. A folder
/// left behind by a crash, a dead battery or a lost network is picked up again
/// at the next launch, so a minute is lost only if the phone itself is.
enum MeetingAPI {
    static var base: String { "\(AppConfig.apiBase)/meeting-capture" }
    static func url(_ op: String, _ extra: [URLQueryItem] = []) -> URL {
        var c = URLComponents(string: base)!
        c.queryItems = [URLQueryItem(name: "op", value: op)] + extra
        return c.url!
    }

    /// `20261114T091500Z-a1b2c3d4`: the UTC start and a random tail (the
    /// server ages audio by the stamp).
    static func newSessionID(at date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let tail = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8)
        return "\(f.string(from: date))-\(tail)"
    }

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    @discardableResult
    static func post(_ op: String, _ body: [String: Any], token: String) async throws -> [String: Any] {
        var req = URLRequest(url: url(op), timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(token, forHTTPHeaderField: "x-scarlet-token")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw MeetingUploadError.http(code) }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    static func putChunk(sid: String, seq: Int, t0: Int, file: URL, token: String) async throws {
        var req = URLRequest(url: url("chunk", [
            URLQueryItem(name: "sid", value: sid),
            URLQueryItem(name: "seq", value: String(seq)),
            URLQueryItem(name: "t0", value: String(t0)),
        ]), timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        req.setValue(token, forHTTPHeaderField: "x-scarlet-token")
        let (_, resp) = try await URLSession.shared.upload(for: req, fromFile: file)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw MeetingUploadError.http(code) }
    }
}

extension Notification.Name {
    /// userInfo: sid (String), uploaded (Int), pending (Int), finished (Bool).
    static let meetingUploadProgress = Notification.Name("meetingUploadProgress")
}

enum MeetingUploadError: Error { case http(Int), noToken }

/// What a recording folder says about itself.
struct MeetingMeta: Codable {
    var sid: String
    var startedAt: Date
    var stoppedAt: Date?
    var device: String
    var titleHint: String?
    var consent: String?
    var tz: String
    var chunks: Int            // minutes written so far (the last seq)
    var started: Bool          // op=start acknowledged by the server
    var finished: Bool         // op=finish acknowledged by the server
}

/// The disk-backed queue. One upload at a time, minutes in order.
actor MeetingUploader {
    static let shared = MeetingUploader()


    private var running = false
    private var uploaded: [String: Int] = [:]

    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("MeetingRecordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Kept off iCloud backups: the server is the copy.
        var u = dir
        var rv = URLResourceValues(); rv.isExcludedFromBackup = true
        try? u.setResourceValues(rv)
        return dir
    }
    static func folder(_ sid: String) -> URL {
        let d = root.appendingPathComponent(sid, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static func chunkURL(_ sid: String, _ seq: Int) -> URL {
        folder(sid).appendingPathComponent(String(format: "%06d.m4a", seq))
    }
    static func metaURL(_ sid: String) -> URL { folder(sid).appendingPathComponent("meta.json") }

    static func readMeta(_ sid: String) -> MeetingMeta? {
        guard let d = try? Data(contentsOf: metaURL(sid)) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(MeetingMeta.self, from: d)
    }
    static func writeMeta(_ m: MeetingMeta) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(m) { try? d.write(to: metaURL(m.sid), options: .atomic) }
    }

    /// Wake the queue (after a minute is written, at Stop, at launch).
    func kick() {
        guard !running else { return }
        running = true
        Task { await self.drain() }
    }

    private func drain() async {
        defer { running = false }
        var backoff: UInt64 = 2
        while true {
            guard let token = TokenStore.token else { return }
            let sids = (try? FileManager.default.contentsOfDirectory(atPath: Self.root.path))?.sorted() ?? []
            var didWork = false
            for sid in sids {
                guard var meta = Self.readMeta(sid) else { continue }
                do {
                    if !meta.started {
                        var body: [String: Any] = ["sid": sid, "started_at": MeetingAPI.iso.string(from: meta.startedAt),
                                                   "tz": meta.tz, "device": meta.device]
                        if let t = meta.titleHint { body["title_hint"] = t }
                        if let c = meta.consent { body["consent"] = c }
                        try await MeetingAPI.post("start", body, token: token)
                        meta.started = true; Self.writeMeta(meta); didWork = true
                    }
                    let files = ((try? FileManager.default.contentsOfDirectory(atPath: Self.folder(sid).path)) ?? [])
                        .filter { $0.hasSuffix(".m4a") }.sorted()
                    for name in files {
                        guard let seq = Int(name.prefix(6)) else { continue }
                        // A minute still being written is the highest seq while recording.
                        if meta.stoppedAt == nil && seq >= meta.chunks + 1 { continue }
                        let url = Self.folder(sid).appendingPathComponent(name)
                        try await MeetingAPI.putChunk(sid: sid, seq: seq, t0: (seq - 1) * 60, file: url, token: token)
                        try? FileManager.default.removeItem(at: url)
                        uploaded[sid, default: 0] += 1
                        didWork = true
                        report(sid, meta)
                    }
                    if let stopped = meta.stoppedAt, !meta.finished {
                        let left = ((try? FileManager.default.contentsOfDirectory(atPath: Self.folder(sid).path)) ?? []).filter { $0.hasSuffix(".m4a") }
                        if left.isEmpty {
                            try await MeetingAPI.post("finish", [
                                "sid": sid, "ended_at": MeetingAPI.iso.string(from: stopped), "chunks": meta.chunks,
                                "duration_s": Int(stopped.timeIntervalSince(meta.startedAt)),
                            ], token: token)
                            meta.finished = true; Self.writeMeta(meta); didWork = true
                            report(sid, meta)
                            try? FileManager.default.removeItem(at: Self.folder(sid))
                        }
                    }
                    backoff = 2
                } catch {
                    // Network or server trouble: wait and try the same folder again.
                    try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
                    backoff = min(backoff * 2, 60)
                    didWork = true
                    break
                }
            }
            if !didWork { return }
        }
    }

    private func report(_ sid: String, _ meta: MeetingMeta) {
        let pending = ((try? FileManager.default.contentsOfDirectory(atPath: Self.folder(sid).path)) ?? []).filter { $0.hasSuffix(".m4a") }.count
        let up = uploaded[sid] ?? 0
        let finished = meta.finished
        Task { @MainActor in
            NotificationCenter.default.post(name: .meetingUploadProgress, object: nil, userInfo: [
                "sid": sid, "uploaded": up, "pending": pending, "finished": finished,
            ])
        }
    }
}
