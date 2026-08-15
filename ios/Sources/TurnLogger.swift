import Foundation
import UIKit

/// The conversation ledger's app-side half (Ido 2026-08-15: "everything that
/// took place in our interactions... full context on everything").
///
/// Every finalized spoken turn — his words as the server heard them, her
/// words as she actually said them — is queued here and batched to
/// app-api `op=log_turns`, which appends to `conversation_turns`. The
/// 30-minute distill sweep reads that ledger into memories and the brief, so
/// what was said in the car in the morning is part of what she knows in the
/// evening.
///
/// Design rules:
/// - Fire-and-forget: logging must NEVER slow or break the live call. A
///   failed flush re-queues once; a second failure drops the batch (the
///   ledger is recall, not the conversation itself).
/// - Batched: flushes when 8 turns accumulate or ~20s after the first
///   queued turn, whichever comes first — one small POST per beat of
///   conversation, not one per sentence.
/// - Only real dialogue: callers log the user/assistant transcript events,
///   never tool/status bubbles (📻/🎵/🧭 lines are UI, not conversation).
@MainActor
final class TurnLogger {
    static let shared = TurnLogger()

    /// One id per live session, set by Conversation.connect(), so the ledger
    /// can group a drive's worth of turns back into one conversation.
    var sessionId = UUID().uuidString

    private struct Turn {
        let role: String     // "user" | "assistant"
        let text: String
        let at: Date
    }

    private var queue: [Turn] = []
    private var flushTask: Task<Void, Never>?
    private var retriedOnce = false

    private init() {}

    func log(role: String, text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        queue.append(Turn(role: role, text: String(t.prefix(8000)), at: Date()))
        if queue.count >= 8 {
            flushSoon(after: 0)
        } else if flushTask == nil {
            flushSoon(after: 20)
        }
    }

    /// Session teardown: push whatever is queued without waiting for the
    /// batch window (the last words of a call must not die with the socket).
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
        guard !queue.isEmpty, TokenStore.token != nil else { return }
        let batch = queue
        queue = []
        let surface: String = {
            switch UIDevice.current.userInterfaceIdiom {
            case .pad: return "ipad"
            case .mac: return "mac"
            default: return "phone"
            }
        }()
        let iso = ISO8601DateFormatter()
        let body: [String: Any] = [
            "session_id": sessionId,
            "surface": surface,
            "turns": batch.map { ["role": $0.role, "text": $0.text, "at": iso.string(from: $0.at)] },
        ]
        do {
            var comps = URLComponents(url: AppConfig.appAPIURL, resolvingAgainstBaseURL: false)!
            var qItems = comps.queryItems ?? []
            qItems.append(URLQueryItem(name: "op", value: "log_turns"))
            comps.queryItems = qItems
            var req = URLRequest(url: comps.url ?? AppConfig.appAPIURL)
            req.httpMethod = "POST"
            req.setValue(TokenStore.token ?? "", forHTTPHeaderField: "x-scarlet-token")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            retriedOnce = false
        } catch {
            // One re-queue, then let go — recall is best-effort by design.
            if !retriedOnce {
                retriedOnce = true
                queue = batch + queue
                flushSoon(after: 30)
            } else {
                retriedOnce = false
            }
        }
    }
}
