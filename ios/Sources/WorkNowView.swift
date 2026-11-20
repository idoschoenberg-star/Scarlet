import SwiftUI

/// "Scarlet is working on": the one card for every order she has taken and
/// not finished, from both queues (the backend runner's tasks and the orders
/// a Claude session does). The speed design's front door, deploy C: an order
/// shows here the moment it is taken, with where it stands in the worker's
/// own words, what it waits on, the promised time when one was given, the
/// thread to watch, and a stop.
///
/// Server: `app-api op=work_now` (read) and `op=assignment_action` (stop).
/// A stop of a queued order answers `cancelled`; a stop of a running one
/// answers `stopping`, because the work ends at its next step, not within a
/// second. The card says exactly that and never "stopped" early.
///
/// Embedded in the Talk screen's layout (not a root overlay, so it can never
/// sit on another screen's buttons) and expanded in place (not a sheet, per
/// the Catalyst one-sheet rule). It draws nothing while nothing is open.
@MainActor
final class WorkNowModel: ObservableObject {
    static let shared = WorkNowModel()
    private init() {}

    struct Row: Identifiable, Equatable {
        let id: String
        let source: String          // "commission" | "task"
        let title: String
        let status: String          // "queued" | "running"
        let stage: String?
        let waitingOn: String?
        let eta: Date?
        let sessionURL: URL?
        let stopping: Bool
    }

    @Published private(set) var rows: [Row] = []
    /// Per-row transient state so a slow network cannot double-fire a stop.
    @Published private(set) var stoppingId: String?
    /// The server's own sentence when a stop was refused, shown under the row.
    @Published private(set) var refusal: [String: String] = [:]

    private var pollTask: Task<Void, Never>?
    private var visible = false

    /// Called when the card appears, when the app returns to the foreground,
    /// and the moment an order goes through this device.
    func refresh() {
        Task { await self.fetch() }
        startPolling()
    }

    func setVisible(_ v: Bool) {
        visible = v
        if v { refresh() } else { pollTask?.cancel(); pollTask = nil }
    }

    /// While the card is on screen: every 15 s with work open, every 60 s
    /// with none. Off screen nothing polls.
    private func startPolling() {
        guard visible, pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let busy = !(self?.rows.isEmpty ?? true)
                try? await Task.sleep(nanoseconds: busy ? 15_000_000_000 : 60_000_000_000)
                if Task.isCancelled { return }
                guard let self else { return }
                await self.fetch()
            }
        }
    }

    private func fetch() async {
        guard let data = try? await Self.request("op=work_now", method: "GET"),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["rows"] as? [[String: Any]] else { return }
        let iso = ISO8601DateFormatter()
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let parsed: [Row] = list.compactMap { r in
            guard let id = r["id"] as? String, let source = r["source"] as? String else { return nil }
            let eta = (r["eta_at"] as? String).flatMap { isoFrac.date(from: $0) ?? iso.date(from: $0) }
            // Only a claude.ai address is ever opened from this card.
            let url = (r["session_url"] as? String).flatMap { s -> URL? in
                guard s.hasPrefix("https://claude.ai/") else { return nil }
                return URL(string: s)
            }
            return Row(id: id, source: source,
                       title: (r["title"] as? String) ?? "",
                       status: (r["status"] as? String) ?? "queued",
                       stage: r["stage"] as? String,
                       waitingOn: r["waiting_on"] as? String,
                       eta: eta, sessionURL: url,
                       stopping: (r["stopping"] as? Bool) ?? false)
        }
        rows = parsed
        refusal = refusal.filter { entry in parsed.contains { $0.id == entry.key } }
    }

    func stop(_ row: Row) {
        guard stoppingId == nil, !row.stopping else { return }
        stoppingId = row.id
        Task { @MainActor in
            defer { self.stoppingId = nil }
            let body: [String: Any] = ["id": row.id, "source": row.source, "action": "stop"]
            // A refusal arrives as a 409 with the server's own sentence, so
            // read the body whatever the status.
            guard let data = try? await Self.request("op=assignment_action", method: "POST",
                                                     body: body, acceptAnyStatus: true),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                self.refusal[row.id] = "The stop did not reach Scarlet. Try again."
                return
            }
            if (obj["ok"] as? Bool) == true {
                self.refusal[row.id] = nil
            } else {
                self.refusal[row.id] = (obj["error"] as? String) ?? "It could not be stopped."
            }
            await self.fetch()
        }
    }

    // Same plumbing shape as SecretApprovalsModel: apiBase + x-scarlet-token.
    private static func request(_ query: String, method: String, body: [String: Any]? = nil,
                                acceptAnyStatus: Bool = false) async throws -> Data {
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
        if !acceptAnyStatus, let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

/// The strip on the Talk screen. Collapsed: one line with the count and the
/// newest order's stage. Tapped: the rows, in place.
struct WorkNowStrip: View {
    @ObservedObject private var model = WorkNowModel.shared
    @State private var expanded = false

    private let scarlet = Color(red: 1, green: 0.35, blue: 0.42)
    /// Opaque, like the presence capsule: translucent fills over the
    /// transcript read as broken overlap.
    private let surface = Color(red: 0.16, green: 0.055, blue: 0.085)

    var body: some View {
        // Nothing open: no view at all, so the screen's own spacing is
        // untouched. The polling lifecycle hangs on the host screen
        // (`workNowLifecycle()`), which is always there.
        if !model.rows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                header
                if expanded {
                    Divider().overlay(Color.white.opacity(0.12))
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(model.rows) { row in
                                WorkNowRowView(row: row, scarlet: scarlet)
                                if row.id != model.rows.last?.id {
                                    Divider().overlay(Color.white.opacity(0.08))
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 260)
                }
            }
            .frame(maxWidth: 560)
            .background(surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.12)))
            .onChange(of: model.rows.count) { _, count in if count == 0 { expanded = false } }
        }
    }

    private var header: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "gearshape.2.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(scarlet)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.rows.count == 1 ? "Scarlet is working on 1 thing"
                                               : "Scarlet is working on \(model.rows.count) things")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.92))
                    if !expanded, let first = model.rows.first {
                        Text(WorkNowRowView.statusLine(first))
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Scarlet is working on \(model.rows.count) items. \(expanded ? "Collapse" : "Expand")")
    }
}

private struct WorkNowRowView: View {
    let row: WorkNowModel.Row
    let scarlet: Color
    @ObservedObject private var model = WorkNowModel.shared

    /// Where the order stands, in one honest line. A finishing time appears
    /// only when the worker promised one.
    static func statusLine(_ row: WorkNowModel.Row) -> String {
        if row.stopping { return "Stopping at its next step" }
        if let w = row.waitingOn, !w.isEmpty { return "Waiting on you: \(w)" }
        var line: String
        if let s = row.stage, !s.isEmpty {
            line = s.prefix(1).uppercased() + String(s.dropFirst())
        } else {
            line = row.status == "running" ? "Running" : "Taken, not started yet"
        }
        if let eta = row.eta {
            let f = DateFormatter()
            f.dateStyle = Calendar.current.isDateInToday(eta) ? .none : .short
            f.timeStyle = .short
            line += " · promised for \(f.string(from: eta))"
        }
        return line
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Each paragraph takes its own direction: a Hebrew order reads
            // right to left, an English one left to right.
            Text(row.title)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(3)
                .multilineTextAlignment(row.title.readingAlignment)
                .frame(maxWidth: .infinity, alignment: row.title.readingFrameAlignment)
                .environment(\.layoutDirection, row.title.layoutDir)
            Text(Self.statusLine(row))
                .font(.caption)
                .foregroundStyle(row.waitingOn?.isEmpty == false ? scarlet : Color.white.opacity(0.6))
                .frame(maxWidth: .infinity, alignment: .leading)
            if let why = model.refusal[row.id] {
                Text(why)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                if let url = row.sessionURL {
                    Button { UIApplication.shared.open(url) } label: {
                        Label("Open the thread", systemImage: "arrow.up.right.square")
                            .font(.caption.weight(.semibold))
                            .frame(minHeight: 40)
                    }
                    .buttonStyle(.bordered)
                }
                Spacer(minLength: 0)
                if row.stopping {
                    Text("Stop requested")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                } else {
                    Button(role: .destructive) { model.stop(row) } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .font(.caption.weight(.semibold))
                            .frame(minHeight: 40)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.stoppingId != nil)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

extension View {
    /// The host screen of `WorkNowStrip` attaches this once: the card's
    /// polling runs only while that screen is showing, and a return to the
    /// foreground refreshes it at once.
    func workNowLifecycle() -> some View {
        self
            .onAppear { WorkNowModel.shared.setVisible(true) }
            .onDisappear { WorkNowModel.shared.setVisible(false) }
            .onReceive(NotificationCenter.default.publisher(
                for: UIApplication.willEnterForegroundNotification)) { _ in WorkNowModel.shared.refresh() }
    }
}
