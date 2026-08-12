import LocalAuthentication
import SwiftUI

/// The missing half of the 1Password approval loop (2026-08-12, SWISS
/// check-in: "she said she will surface some kind of acceptance cards …
/// but that never surfaced"). The server side existed end-to-end — her
/// `request_secret` tool files a row, `op=secrets_pending` lists it,
/// `op=secret_action` records the decision — but no native surface ever
/// rendered the card, so every credential-gated flow died at a promise.
///
/// This is that surface: a floating card (NOT a sheet — Catalyst allows one
/// sheet per view and the card must ride over a live call without tearing
/// anything down), Face-ID-gated Approve, one-tap Deny, honest expiry.
/// The secret VALUE never reaches this app or the conversation — approval
/// only flips the request row; the executor reads 1Password directly.
@MainActor
final class SecretApprovalsModel: ObservableObject {
    static let shared = SecretApprovalsModel()
    private init() {}

    struct SecretRequest: Identifiable, Equatable {
        let id: String
        let item: String
        let field: String?
        let purpose: String
        let expiresAt: Date?
    }

    @Published private(set) var pending: [SecretRequest] = []
    /// Transient per-card state so a slow network can't double-fire a decision.
    @Published private(set) var decidingId: String?

    private var pollTask: Task<Void, Never>?

    /// Called when her `request_secret` tool goes through this device (the
    /// instant path) and on app-foreground (the catch-up path for requests
    /// minted from Telegram or the Mac).
    func refresh() {
        Task { await self.fetchPending() }
        // While anything is pending, keep it honest: cards expire server-side
        // in ~3 minutes, so poll until the stack is empty again.
        if pollTask == nil {
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    guard let self else { return }
                    await self.fetchPending()
                    if self.pending.isEmpty { break }
                }
                self?.pollTask = nil
            }
        }
    }

    private func fetchPending() async {
        guard let data = try? await Self.request("op=secrets_pending", method: "GET"),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = obj["requests"] as? [[String: Any]] else { return }
        let iso = ISO8601DateFormatter()
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        pending = rows.compactMap { r in
            guard let id = r["id"] as? String else { return nil }
            let exp = (r["expires_at"] as? String).flatMap { isoFrac.date(from: $0) ?? iso.date(from: $0) }
            return SecretRequest(id: id,
                                 item: (r["item_query"] as? String) ?? "?",
                                 field: r["field_hint"] as? String,
                                 purpose: (r["purpose"] as? String) ?? "",
                                 expiresAt: exp)
        }
    }

    func approve(_ req: SecretRequest) {
        guard decidingId == nil else { return }
        decidingId = req.id
        let ctx = LAContext()
        ctx.localizedFallbackTitle = "Use passcode"
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            // No biometrics/passcode available: fail CLOSED — never approve
            // a credential release without an owner check.
            decidingId = nil
            return
        }
        ctx.evaluatePolicy(.deviceOwnerAuthentication,
                           localizedReason: "Approve using “\(req.item)” for: \(req.purpose)") { ok, _ in
            Task { @MainActor in
                if ok { await self.decide(req.id, action: "approve") }
                self.decidingId = nil
            }
        }
    }

    func deny(_ req: SecretRequest) {
        guard decidingId == nil else { return }
        decidingId = req.id
        Task { @MainActor in
            await self.decide(req.id, action: "deny")
            self.decidingId = nil
        }
    }

    private func decide(_ id: String, action: String) async {
        _ = try? await Self.request("op=secret_action", method: "POST",
                                    body: ["id": id, "action": action])
        pending.removeAll { $0.id == id }
    }

    // Same plumbing shape as DraftView/InboxModel: apiBase + x-scarlet-token.
    private static func request(_ query: String, method: String,
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
}

/// Root-level overlay: shows the oldest pending card; the stack drains one
/// decision at a time (server caps at 5, expiry sweeps the rest).
struct SecretApprovalCardOverlay: View {
    @ObservedObject private var model = SecretApprovalsModel.shared

    var body: some View {
        Group {
            if let req = model.pending.first {
                SecretApprovalCard(req: req)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.spring(duration: 0.35), value: model.pending)
            }
        }
        // Catch-up path: requests minted while backgrounded, or from surfaces
        // other than this device (Telegram, the Mac agent).
        .onAppear { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.willEnterForegroundNotification)) { _ in model.refresh() }
    }
}

private struct SecretApprovalCard: View {
    let req: SecretApprovalsModel.SecretRequest
    @ObservedObject private var model = SecretApprovalsModel.shared
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var secondsLeft: Int? {
        guard let e = req.expiresAt else { return nil }
        return max(0, Int(e.timeIntervalSince(now)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(.tint)
                Text("1Password approval")
                    .font(.headline)
                Spacer()
                if let s = secondsLeft {
                    Text("\(s / 60):\(String(format: "%02d", s % 60))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(s < 30 ? .red : .secondary)
                }
            }
            Text(req.item + (req.field.map { " · \($0)" } ?? ""))
                .font(.subheadline.weight(.semibold))
            Text(req.purpose)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("The value goes straight from 1Password to the task — it never appears here or in the conversation.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            HStack(spacing: 12) {
                Button(role: .cancel) { model.deny(req) } label: {
                    Text("Deny").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button { model.approve(req) } label: {
                    Label("Approve", systemImage: "faceid").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .disabled(model.decidingId != nil || secondsLeft == 0)
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.12)))
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .shadow(radius: 18, y: 8)
        .onReceive(tick) { now = $0 }
        .onAppear { now = Date() }
    }
}
