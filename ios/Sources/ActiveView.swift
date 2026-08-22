import SwiftUI

// The Active board (Ido 2026-08-22): "I need a way to know that what I asked
// Scarlet is understood and see what the status is." Three lists:
//   ACTIVE    — assignments in flight (research, delegated requests,
//               commissions), each showing the INTERPRETED request so he can
//               verify Scarlet understood, with Stop / Amend where honest.
//   DONE      — the checkmarked archive (last 30 days).
//   RECURRING — his standing schedule (system heartbeats tucked behind a
//               disclosure, per the readability doctrine).
// Regular width designed first (doctrine §11): a List (free hover/pointer on
// Catalyst) with dense-but-17pt rows, keyboard-reachable actions via context
// menus, pushed detail on the same stack (Catalyst one-sheet rule).

// MARK: - wire

private enum AWire {
    static func request(_ query: String, method: String = "GET",
                        body: [String: Any]? = nil) async throws -> [String: Any] {
        guard let url = URL(string: "\(AppConfig.apiBase)/app-api?\(query)") else {
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
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        // Non-2xx still carries the server's honest error text — surface it.
        if !(200...299).contains(status), (obj["error"] as? String) == nil {
            throw URLError(.badServerResponse)
        }
        return obj
    }
}

// MARK: - model

struct Assignment: Identifiable, Equatable {
    let id: String
    let source: String      // task | research | commission
    let title: String       // the interpreted request — what Scarlet understood
    let status: String      // queued | running | done | failed | cancelled
    let at: Date?
    let note: String?
    let canStop: Bool
    let canAmend: Bool
}

struct RecurringJob: Identifiable, Equatable {
    let id: String
    let label: String
    let schedule: String
    let active: Bool
    let userFacing: Bool
}

@MainActor
final class ActiveModel: ObservableObject {
    @Published private(set) var active: [Assignment] = []
    @Published private(set) var done: [Assignment] = []
    @Published private(set) var recurring: [RecurringJob] = []
    @Published var errorText = ""
    @Published private(set) var loaded = false

    private static func parse(_ raw: [[String: Any]]) -> [Assignment] {
        raw.compactMap { r in
            guard let id = r["id"] as? String else { return nil }
            return Assignment(
                id: id,
                source: (r["source"] as? String) ?? "task",
                title: (r["title"] as? String) ?? "",
                status: (r["status"] as? String) ?? "",
                at: MailDates.parse(r["at"] as? String),
                note: r["note"] as? String,
                canStop: (r["can_stop"] as? Bool) ?? false,
                canAmend: (r["can_amend"] as? Bool) ?? false)
        }
    }

    func load() async {
        do {
            let obj = try await AWire.request("op=assignments")
            if let err = obj["error"] as? String, (obj["ok"] as? Bool) != true {
                // An older backend without the op: say so honestly, keep calm.
                errorText = err.lowercased().contains("unknown op")
                    ? "The Active board is deploying — minutes away."
                    : err
                return
            }
            active = Self.parse((obj["active"] as? [[String: Any]]) ?? [])
            done = Self.parse((obj["done"] as? [[String: Any]]) ?? [])
            recurring = ((obj["recurring"] as? [[String: Any]]) ?? []).compactMap { r in
                guard let id = r["id"] as? String else { return nil }
                return RecurringJob(
                    id: id,
                    label: (r["label"] as? String) ?? id,
                    schedule: (r["schedule"] as? String) ?? "",
                    active: (r["active"] as? Bool) ?? true,
                    userFacing: (r["user_facing"] as? Bool) ?? false)
            }
            errorText = ""
            loaded = true
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            // Keep whatever is on screen; only shout when there is nothing.
            if !loaded { errorText = "Couldn't load the Active board — pull to retry." }
        }
    }

    /// Stop a queued assignment. The server refuses (with the reason) once a
    /// row is running — that refusal is shown verbatim, never papered over.
    func stop(_ a: Assignment) {
        Task {
            let obj = (try? await AWire.request(
                "op=assignment_action", method: "POST",
                body: ["id": a.id, "source": a.source, "action": "stop"])) ?? [:]
            if (obj["ok"] as? Bool) == true {
                errorText = ""
            } else {
                errorText = (obj["error"] as? String) ?? "Couldn't stop it — try again."
            }
            await load()
        }
    }

    func amend(_ a: Assignment, text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        Task {
            let obj = (try? await AWire.request(
                "op=assignment_action", method: "POST",
                body: ["id": a.id, "source": a.source, "action": "amend", "text": t])) ?? [:]
            if (obj["ok"] as? Bool) == true {
                errorText = ""
            } else {
                errorText = (obj["error"] as? String) ?? "Couldn't amend it — try again."
            }
            await load()
        }
    }
}

// MARK: - screen

struct ActiveView: View {
    @StateObject private var model = ActiveModel()
    @State private var amending: Assignment?
    @State private var amendText = ""
    @State private var showSystemJobs = false

    var body: some View {
        NavigationStack {
            List {
                if !model.errorText.isEmpty {
                    Section {
                        Label(model.errorText, systemImage: "exclamationmark.bubble")
                            .font(.system(size: 15))
                            .foregroundStyle(.orange)
                            .listRowBackground(Color.white.opacity(0.05))
                    }
                }
                activeSection
                doneSection
                recurringSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(ScarletBackground().ignoresSafeArea())
            .navigationTitle("Active")
            .refreshable { await model.load() }
            .task {
                // Live board: refresh every 15s while on screen.
                while !Task.isCancelled {
                    await model.load()
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                }
            }
            .alert("Amend this assignment", isPresented: Binding(
                get: { amending != nil },
                set: { if !$0 { amending = nil; amendText = "" } })) {
                TextField("What should change?", text: $amendText)
                Button("Send") {
                    if let a = amending { model.amend(a, text: amendText) }
                    amending = nil; amendText = ""
                }
                Button("Cancel", role: .cancel) { amending = nil; amendText = "" }
            } message: {
                Text("The change is appended to the request before it runs.")
            }
        }
    }

    // MARK: sections

    private var activeSection: some View {
        Section {
            if model.active.isEmpty && model.loaded {
                Text("Nothing in flight — everything you asked for is done.")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.white.opacity(0.04))
            }
            ForEach(model.active) { a in
                NavigationLink { AssignmentDetail(a: a, model: model) } label: {
                    AssignmentRow(a: a)
                }
                .listRowBackground(Color.white.opacity(0.05))
                .swipeActions(edge: .trailing) {
                    if a.canStop {
                        Button(role: .destructive) { model.stop(a) } label: {
                            Label("Stop", systemImage: "stop.circle")
                        }
                    }
                }
                .contextMenu {
                    if a.canAmend {
                        Button { amending = a } label: { Label("Amend…", systemImage: "pencil") }
                    }
                    if a.canStop {
                        Button(role: .destructive) { model.stop(a) } label: {
                            Label("Stop", systemImage: "stop.circle")
                        }
                    }
                }
            }
        } header: {
            header("In flight", count: model.active.count)
        }
    }

    private var doneSection: some View {
        Section {
            ForEach(model.done) { a in
                NavigationLink { AssignmentDetail(a: a, model: model) } label: {
                    AssignmentRow(a: a)
                }
                .listRowBackground(Color.white.opacity(0.04))
            }
        } header: {
            header("Done", count: model.done.count)
        }
    }

    private var recurringSection: some View {
        Section {
            ForEach(model.recurring.filter(\.userFacing)) { j in
                RecurringRow(j: j)
                    .listRowBackground(Color.white.opacity(0.04))
            }
            let system = model.recurring.filter { !$0.userFacing }
            if !system.isEmpty {
                DisclosureGroup(isExpanded: $showSystemJobs) {
                    ForEach(system) { j in RecurringRow(j: j) }
                } label: {
                    Text("System heartbeats (\(system.count))")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.white.opacity(0.03))
            }
        } header: {
            header("Recurring", count: model.recurring.filter(\.userFacing).count)
        }
    }

    private func header(_ title: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold)).kerning(0.8)
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .padding(.horizontal, 7).padding(.vertical, 1)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
            }
        }
        .foregroundStyle(.white.opacity(0.6))
        .textCase(.uppercase)
    }
}

// MARK: - rows

private struct AssignmentRow: View {
    let a: Assignment

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            statusBadge
                .frame(width: 24)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(a.title.isEmpty ? "(empty request)" : a.title)
                    .font(.system(size: 17))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(3)
                    .multilineTextAlignment(a.title.readingAlignment)
                    .frame(maxWidth: .infinity, alignment: a.title.readingFrameAlignment)
                    .environment(\.layoutDirection, a.title.layoutDir)
                HStack(spacing: 6) {
                    Text(statusLabel)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(statusColor)
                    if let d = a.at {
                        Text(d.formatted(.relative(presentation: .named)))
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    Text(sourceLabel)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                }
                if let note = a.note, !note.isEmpty {
                    Text(note)
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(2)
                        .multilineTextAlignment(note.readingAlignment)
                        .frame(maxWidth: .infinity, alignment: note.readingFrameAlignment)
                        .environment(\.layoutDirection, note.layoutDir)
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var statusBadge: some View {
        switch a.status {
        case "running":
            ProgressView().controlSize(.small).tint(Color(red: 1, green: 0.35, blue: 0.42))
        case "queued":
            Image(systemName: "clock").font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
        case "done":
            Image(systemName: "checkmark.circle.fill").font(.system(size: 18))
                .foregroundStyle(Color(red: 0.55, green: 0.85, blue: 0.62))
        case "cancelled":
            Image(systemName: "slash.circle").font(.system(size: 17))
                .foregroundStyle(.white.opacity(0.45))
        default:   // failed
            Image(systemName: "exclamationmark.circle.fill").font(.system(size: 18))
                .foregroundStyle(.orange)
        }
    }

    private var statusLabel: String {
        switch a.status {
        case "queued": return "Waiting to start"
        case "running": return "Working on it"
        case "done": return "Done"
        case "failed": return "Didn't finish"
        case "cancelled": return "Stopped"
        default: return a.status
        }
    }

    private var statusColor: Color {
        switch a.status {
        case "running": return Color(red: 1, green: 0.35, blue: 0.42)
        case "done": return Color(red: 0.55, green: 0.85, blue: 0.62)
        case "failed": return .orange
        default: return .white.opacity(0.55)
        }
    }

    private var sourceLabel: String {
        switch a.source {
        case "research": return "· Research"
        case "commission": return "· Deep work"
        default: return "· Task"
        }
    }
}

private struct RecurringRow: View {
    let j: RecurringJob

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "repeat")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(j.active ? Color(red: 1, green: 0.35, blue: 0.42).opacity(0.85)
                                          : .white.opacity(0.3))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(j.label)
                    .font(.system(size: 17))
                    .foregroundStyle(.white.opacity(j.active ? 0.9 : 0.5))
                Text(Self.human(j.schedule) + (j.active ? "" : " — paused"))
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    /// A cron expression, in words a person reads at a glance.
    static func human(_ cron: String) -> String {
        let p = cron.split(separator: " ").map(String.init)
        guard p.count == 5 else { return cron }
        let (m, h, dom, _, dow) = (p[0], p[1], p[2], p[3], p[4])
        if m.hasPrefix("*/") { return "Every \(m.dropFirst(2)) min" }
        if h == "*" { return "Hourly" }
        if h.hasPrefix("*/") { return "Every \(h.dropFirst(2)) hours" }
        if let hh = Int(h), let mm = Int(m) {
            // Stored in UTC — show Israel wall-clock (his primary timezone).
            let localH = (hh + 3) % 24
            let time = String(format: "%02d:%02d", localH, mm)
            if dow != "*" {
                let days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
                let names = dow.split(separator: ",").compactMap { Int($0) }.map { days[$0 % 7] }
                if !names.isEmpty { return "\(names.joined(separator: ", ")) at \(time)" }
            }
            if dom == "*" { return "Daily at \(time)" }
            return "Day \(dom) at \(time)"
        }
        return cron
    }
}

// MARK: - detail

private struct AssignmentDetail: View {
    let a: Assignment
    @ObservedObject var model: ActiveModel
    @State private var amendText = ""
    @State private var showAmend = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                AssignmentRow(a: a)
                    .padding(14)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))

                VStack(alignment: .leading, spacing: 8) {
                    Text("WHAT SCARLET UNDERSTOOD")
                        .font(.system(size: 12, weight: .semibold)).kerning(0.8)
                        .foregroundStyle(.white.opacity(0.5))
                    Text(a.title)
                        .font(.system(size: 17))
                        .foregroundStyle(.white.opacity(0.92))
                        .multilineTextAlignment(a.title.readingAlignment)
                        .frame(maxWidth: .infinity, alignment: a.title.readingFrameAlignment)
                        .environment(\.layoutDirection, a.title.layoutDir)
                        .textSelection(.enabled)
                }
                .padding(14)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))

                if let note = a.note, !note.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("OUTCOME / LATEST")
                            .font(.system(size: 12, weight: .semibold)).kerning(0.8)
                            .foregroundStyle(.white.opacity(0.5))
                        Text(note)
                            .font(.system(size: 17))
                            .foregroundStyle(.white.opacity(0.85))
                            .multilineTextAlignment(note.readingAlignment)
                            .frame(maxWidth: .infinity, alignment: note.readingFrameAlignment)
                            .environment(\.layoutDirection, note.layoutDir)
                            .textSelection(.enabled)
                    }
                    .padding(14)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
                }

                if a.canAmend || a.canStop {
                    HStack(spacing: 12) {
                        if a.canAmend {
                            Button { showAmend = true } label: {
                                Label("Amend", systemImage: "pencil")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                        if a.canStop {
                            Button(role: .destructive) {
                                model.stop(a); dismiss()
                            } label: {
                                Label("Stop", systemImage: "stop.circle")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                } else if a.status == "running" {
                    Text("Already executing — it can't be stopped mid-run; the result will land shortly and can be ignored if no longer needed.")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .padding(16)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .background(ScarletBackground().ignoresSafeArea())
        .navigationTitle(a.status == "running" || a.status == "queued" ? "In flight" : "Finished")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Amend this assignment", isPresented: $showAmend) {
            TextField("What should change?", text: $amendText)
            Button("Send") { model.amend(a, text: amendText); amendText = ""; dismiss() }
            Button("Cancel", role: .cancel) { amendText = "" }
        }
    }
}
