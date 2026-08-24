import Foundation

/// The WRIST half of the conversation ledger (INCIDENT 2026-08-24, twice in
/// two days: a request made on the watch died with ZERO server-side trace —
/// `conversation_turns` had never held a single watch row, because
/// TurnLogger.swift lives only in the phone target and WatchConversation
/// never uploaded anything. When the Realtime model acked a request without
/// firing its tool, nothing server-side could ever rescue it. The backend
/// reconciler can only rescue what reaches the journal — so the watch now
/// journals, same endpoint, same auth, tagged surface "watch").
///
/// Same app-api `op=log_turns` contract as the phone's TurnLogger, with the
/// timing flipped for the wrist: watchOS suspends/kills the app abruptly and
/// background time is scarce, so turns are posted near-IMMEDIATELY (1.5s
/// coalesce window, or instantly once a user+assistant pair is queued)
/// instead of the phone's 8-turn/20s batches. A request turn and its ack
/// should be durably server-side within seconds of being spoken — that is
/// the whole point.
///
/// Fire-and-forget: logging must NEVER slow or break the live call. One
/// re-queue on a failed POST, then the batch is let go (the ledger is
/// recall + rescue material, not the conversation itself).
@MainActor
final class WatchTurnLogger {
    static let shared = WatchTurnLogger()

    /// One id per conversation, set by WatchConversation, so the ledger can
    /// group a walk's worth of turns back into one thread (reconnects keep
    /// the id; a genuinely new conversation mints a new one).
    var sessionId = UUID().uuidString

    private struct Turn {
        let role: String     // "user" | "assistant"
        let text: String
        let at: Date
    }

    private var queue: [Turn] = []
    private var flushTask: Task<Void, Never>?
    private var retriedOnce = false

    /// Same wrist-transport lesson as every other POST the watch makes
    /// (mint/tools/beacons): a default session fails INSTANTLY on a link
    /// that is still coming up at wrist-raise — wait for connectivity.
    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.waitsForConnectivity = true
        c.timeoutIntervalForResource = 30
        return URLSession(configuration: c)
    }()

    private init() {}

    func log(role: String, text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        queue.append(Turn(role: role, text: String(t.prefix(8000)), at: Date()))
        if queue.count >= 2 {
            flushSoon(after: 0)      // a request + its ack never wait
        } else if flushTask == nil {
            flushSoon(after: 1.5)    // lone turn: tiny coalesce, then post
        }
    }

    /// Session teardown / app leaving the foreground: push whatever is queued
    /// NOW — the wrist dies abruptly and the last words must not die with it.
    func flushNow() { flushSoon(after: 0) }

    private func flushSoon(after seconds: Double) {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            if seconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    private func flush() async {
        flushTask = nil
        guard !queue.isEmpty, let token = TokenStore.token else { return }
        let batch = queue
        queue = []
        let iso = ISO8601DateFormatter()
        let body: [String: Any] = [
            "session_id": sessionId,
            "surface": "watch",
            "turns": batch.map { ["role": $0.role, "text": $0.text, "at": iso.string(from: $0.at)] },
        ]
        do {
            var comps = URLComponents(url: AppConfig.appAPIURL, resolvingAgainstBaseURL: false)!
            var qItems = comps.queryItems ?? []
            qItems.append(URLQueryItem(name: "op", value: "log_turns"))
            comps.queryItems = qItems
            var req = URLRequest(url: comps.url ?? AppConfig.appAPIURL)
            req.httpMethod = "POST"
            req.setValue(token, forHTTPHeaderField: "x-scarlet-token")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, resp) = try await Self.session.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            retriedOnce = false
        } catch {
            // One re-queue (10s — the wrist may not live to see 30), then let
            // go: recall is best-effort by design, same as the phone.
            if !retriedOnce {
                retriedOnce = true
                queue = batch + queue
                flushSoon(after: 10)
            } else {
                retriedOnce = false
            }
        }
    }
}
