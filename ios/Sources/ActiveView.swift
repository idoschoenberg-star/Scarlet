import SwiftUI
import UIKit

// The Active board (Ido 2026-08-22): "I need a way to know that what I asked
// Scarlet is understood and see what the status is." Three lists:
//   ACTIVE    — assignments in flight (research, delegated requests,
//               commissions), each showing the INTERPRETED request so he can
//               verify Scarlet understood, with Stop / Amend where honest.
//   DONE      — the checkmarked archive (last 30 days). Finished rows can be
//               ARCHIVED away (Ido 2026-08-23): per-row swipe, or Select →
//               checkmarks → one-tap "Archive n" (LibraryView's pattern).
//               Archiving is a soft server-side state (assignment_action
//               "archive"), never a delete; archived rows just leave the list.
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
    let archived: Bool

    /// Terminal rows (the Finished list) are the only ones archive applies
    /// to — the server 409s on anything still in flight.
    var isFinished: Bool { ["done", "failed", "cancelled"].contains(status) }
}

/// The deliverable quick-links op=assignment_detail returns for a finished
/// assignment. EVERY link is optional — only the chips whose link the
/// backend actually supplied are rendered; an older backend (no op yet)
/// yields no links at all and the detail page simply shows no chips.
struct AssignmentLinks: Equatable {
    var libraryItemID: String?
    var webURL: URL?
    var pdfURL: URL?
    var notebookURL: URL?
    var hasAny: Bool {
        libraryItemID != nil || webURL != nil || pdfURL != nil || notebookURL != nil
    }
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
                canAmend: (r["can_amend"] as? Bool) ?? false,
                archived: (r["archived"] as? Bool) ?? false)
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
            // Archived rows leave the Finished list. The server already
            // excludes them unless include_archived is asked for; the filter
            // is belt-and-braces for rows that carry archived:true anyway.
            done = Self.parse((obj["done"] as? [[String: Any]]) ?? [])
                .filter { !$0.archived }
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

    /// Archive one finished row — soft state, never a delete. Optimistic
    /// removal (the row leaves the Finished list at once); a refusal (older
    /// backend, or 409 on a non-terminal row) shows verbatim on the board's
    /// existing error line and the reload brings the truth back.
    func archive(_ a: Assignment) {
        done.removeAll { $0.id == a.id }
        Task {
            let obj = (try? await AWire.request(
                "op=assignment_action", method: "POST",
                body: ["id": a.id, "source": a.source, "action": "archive"])) ?? [:]
            if (obj["ok"] as? Bool) == true {
                errorText = ""
            } else {
                errorText = (obj["error"] as? String) ?? "Couldn't archive it — try again."
            }
            await load()
        }
    }

    /// Multi-select archive: every checked row leaves the Finished list at
    /// once; the per-row calls run concurrently and any failure reloads the
    /// truth with an honest count (LibraryModel.setArchivedMany discipline).
    func archiveMany(_ ids: Set<String>) {
        let targets = done.filter { ids.contains($0.id) }
        guard !targets.isEmpty else { return }
        done.removeAll { ids.contains($0.id) }
        Task {
            var failedCount = 0
            await withTaskGroup(of: Bool.self) { group in
                for t in targets {
                    group.addTask {
                        let obj = (try? await AWire.request(
                            "op=assignment_action", method: "POST",
                            body: ["id": t.id, "source": t.source, "action": "archive"])) ?? [:]
                        return (obj["ok"] as? Bool) == true
                    }
                }
                for await ok in group where !ok { failedCount += 1 }
            }
            if failedCount > 0 {
                errorText = "Couldn't archive \(failedCount) of \(targets.count) — the board refreshed."
            } else {
                errorText = ""
            }
            await load()
        }
    }

    /// Fetch a finished assignment's deliverable links + archived state
    /// (NEW op=assignment_detail). Returns nil on an older backend that
    /// doesn't know the op (or any failure) — the caller then renders no
    /// chips and no archive button; degrade, never shout.
    func fetchDetail(_ a: Assignment) async -> (links: AssignmentLinks, archived: Bool)? {
        guard let obj = try? await AWire.request(
            "op=assignment_detail", method: "POST",
            body: ["id": a.id, "source": a.source]) else { return nil }
        if let _ = obj["error"] as? String, (obj["ok"] as? Bool) != true { return nil }
        let linksObj = (obj["links"] as? [String: Any]) ?? [:]
        func url(_ key: String) -> URL? {
            guard let s = linksObj[key] as? String, !s.isEmpty else { return nil }
            return URL(string: s)
        }
        let itemID = (linksObj["library_item_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let links = AssignmentLinks(
            libraryItemID: itemID,
            webURL: url("web_url"),
            pdfURL: url("pdf_url"),
            notebookURL: url("notebooklm_url"))
        return (links, (obj["archived"] as? Bool) ?? a.archived)
    }
}

// MARK: - screen

struct ActiveView: View {
    @StateObject private var model = ActiveModel()
    @State private var amending: Assignment?
    @State private var amendText = ""
    @State private var showSystemJobs = false
    /// Multi-select over the FINISHED list (Select in the toolbar):
    /// checkmark rows + a one-tap "Archive n" bar at the bottom — the same
    /// flow as the Library's Select, so the two screens feel like one app.
    @State private var selecting = false
    @State private var selectedIDs: Set<String> = []

    private let scarletRose = Color(red: 1, green: 0.35, blue: 0.42)

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
            .toolbar {
                // Select lives in the nav bar (Edit-button convention);
                // it only appears once there is a Finished list to act on.
                ToolbarItem(placement: .topBarTrailing) {
                    if !model.done.isEmpty {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                selecting.toggle()
                                if !selecting { selectedIDs.removeAll() }
                            }
                        } label: {
                            Text(selecting ? "Done" : "Select")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(selecting ? scarletRose : .white)
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if selecting { selectionBar }
            }
            // The Finished list emptied under an open selection (last rows
            // archived, or a refresh) — nothing left to select; stand down.
            .onChange(of: model.done.isEmpty) { _, empty in
                if empty {
                    selecting = false
                    selectedIDs = []
                }
            }
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
                if selecting {
                    // Select mode: the whole row toggles its checkmark;
                    // navigation and swipes stand down until Done.
                    Button {
                        toggleSelection(a)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selectedIDs.contains(a.id)
                                ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 22))
                                .foregroundStyle(selectedIDs.contains(a.id)
                                    ? scarletRose : .white.opacity(0.35))
                            AssignmentRow(a: a)
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.white.opacity(0.04))
                } else {
                    NavigationLink { AssignmentDetail(a: a, model: model) } label: {
                        AssignmentRow(a: a)
                    }
                    .listRowBackground(Color.white.opacity(0.04))
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button {
                            model.archive(a)
                        } label: {
                            Label("Archive", systemImage: "archivebox")
                        }
                        .tint(Color(red: 0.85, green: 0.55, blue: 0.15))
                    }
                    .contextMenu {
                        Button {
                            model.archive(a)
                        } label: {
                            Label("Archive", systemImage: "archivebox")
                        }
                    }
                }
            }
        } header: {
            header("Done", count: model.done.count)
        }
    }

    private func toggleSelection(_ a: Assignment) {
        if selectedIDs.contains(a.id) {
            selectedIDs.remove(a.id)
        } else {
            selectedIDs.insert(a.id)
        }
    }

    /// The one-tap bulk bar (LibraryView's selectionBar, Finished-list
    /// flavor): Select All on the leading side, "Archive n" capsule trailing.
    private var selectionBar: some View {
        HStack(spacing: 12) {
            Button(selectedIDs.count == model.done.count ? "Deselect All" : "Select All") {
                if selectedIDs.count == model.done.count {
                    selectedIDs.removeAll()
                } else {
                    selectedIDs = Set(model.done.map(\.id))
                }
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white.opacity(0.85))
            Spacer()
            Button {
                let ids = selectedIDs
                selecting = false
                selectedIDs = []
                model.archiveMany(ids)
            } label: {
                Label(
                    "Archive\(selectedIDs.isEmpty ? "" : " \(selectedIDs.count)")",
                    systemImage: "archivebox.fill"
                )
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(Capsule().fill(selectedIDs.isEmpty
                    ? Color.white.opacity(0.12) : scarletRose))
            }
            .disabled(selectedIDs.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
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

    /// Deliverable quick-links from op=assignment_detail. `detailLoaded`
    /// flips only on a successful fetch — an older backend (no op yet)
    /// leaves it false, so no chips and no Archive button render at all.
    @State private var links = AssignmentLinks()
    @State private var detailLoaded = false
    @State private var detailArchived = false
    /// Chip currently resolving (its icon swaps to a spinner) — the Mobile
    /// chip looks the item up in the Library, the PDF chip downloads bytes.
    @State private var resolvingChip: String?

    /// ONE sheet for every deliverable viewer (Catalyst one-sheet rule —
    /// LibraryView's enum-driven slot pattern). The `.alert` below is not a
    /// sheet and coexists fine.
    enum DeliverableSheet: Identifiable {
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
    @State private var deliverableSheet: DeliverableSheet?

    private let scarletRose = Color(red: 1, green: 0.35, blue: 0.42)

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

                // Deliverables (Ido 2026-08-23): one-tap chips to where the
                // result actually lives — rendered ONLY for the links the
                // backend supplied. Absent links, absent chips; an older
                // backend supplies none and this whole card never appears.
                if detailLoaded && links.hasAny {
                    deliverablesCard
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

                // Archive from the page (finished rows only). Rendered only
                // when the detail op answered — an older backend hides it
                // instead of offering a button that can only fail.
                if a.isFinished && detailLoaded && !detailArchived {
                    Button {
                        model.archive(a)
                        dismiss()
                    } label: {
                        Label("Archive", systemImage: "archivebox")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
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
        .task {
            guard a.isFinished else { return }
            if let d = await model.fetchDetail(a) {
                links = d.links
                detailArchived = d.archived
                detailLoaded = true
            }
        }
        // The ONE sheet on this view (Catalyst rule): every chip's viewer
        // rides it — the Library item's own surface, the downloaded PDF's
        // QuickLook, the web artifact's in-app browser.
        .sheet(item: $deliverableSheet) { sheet in
            switch sheet {
            case .photo(let item):
                WAPhotoView(item: item)
            case .video(let item):
                WAVideoView(item: item)
            case .web(let item):
                LibraryWebSheet(item: item)
                    .preferredColorScheme(.dark)
            case .file(let file):
                // InboxView/LibraryView's attachment pattern: the document
                // scroll swallows swipe-down, so a floating ✕ must always
                // work; Share mirrors it — a deliverable is never a dead end.
                ZStack(alignment: .top) {
                    QuickLookPreview(url: file.url)
                        .ignoresSafeArea()
                    HStack {
                        Button {
                            deliverableSheet = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 30, height: 30)
                                .background(Circle().fill(Color.black.opacity(0.5)))
                        }
                        .accessibilityLabel("Close document")
                        Spacer()
                        ShareLink(item: file.url) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 30, height: 30)
                                .background(Circle().fill(Color.black.opacity(0.5)))
                        }
                        .accessibilityLabel("Share document")
                    }
                    .padding(.top, 12)
                    .padding(.horizontal, 12)
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
    }

    // MARK: deliverable chips

    private var deliverablesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("DELIVERABLES")
                .font(.system(size: 12, weight: .semibold)).kerning(0.8)
                .foregroundStyle(.white.opacity(0.5))
            // Horizontal scroll so four chips never crush on an iPhone;
            // at regular width they simply sit in a row.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    if let itemID = links.libraryItemID {
                        chip("Mobile", icon: "iphone") { openLibraryItem(itemID) }
                    }
                    if let url = links.pdfURL {
                        chip("PDF", icon: "doc.richtext") { openPDF(url) }
                    }
                    if let url = links.webURL {
                        chip("Web", icon: "safari") {
                            deliverableSheet = .web(LibraryWebItem(url: url, title: chipTitle))
                        }
                    }
                    if let url = links.notebookURL {
                        chip("NotebookLM", icon: "text.book.closed") {
                            UIApplication.shared.open(url)
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
    }

    /// Sheet/viewer title: the interpreted request, trimmed to a headline.
    private var chipTitle: String {
        let t = a.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Deliverable" : String(t.prefix(60))
    }

    private func chip(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if resolvingChip == title {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(scarletRose)
                }
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Capsule().fill(Color.white.opacity(0.10)))
            .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(resolvingChip != nil)
    }

    /// "Mobile": open the Library deliverable IN-APP — look the item up in
    /// the Library (live shelf, then Archived) and present it with the same
    /// per-kind viewer surfaces LibraryView uses.
    @MainActor
    private func openLibraryItem(_ itemID: String) {
        guard resolvingChip == nil else { return }
        resolvingChip = "Mobile"
        Task {
            defer { resolvingChip = nil }
            guard let item = await fetchLibraryItem(itemID) else {
                model.errorText = "Couldn't find that Library item — it may still be uploading."
                return
            }
            guard let url = item.url else {
                model.errorText = "\"\(item.title)\" has no link yet — try again shortly."
                return
            }
            switch item.kind {
            case "image":
                deliverableSheet = .photo(WAPhotoItem(url: url))
            case "video", "audio":
                deliverableSheet = .video(WAVideoItem(url: url))
            case "html", "link":
                // Force text/html for html artifacts — LibraryView's rule
                // (object storage often stamps text/plain on uploaded .html).
                deliverableSheet = .web(LibraryWebItem(
                    url: url, title: item.title, forceHTML: item.kind == "html"))
            default:   // pdf / file
                await downloadAndPreview(url: url, title: item.title,
                                         ext: item.kind == "pdf" ? "pdf" : url.pathExtension)
            }
        }
    }

    /// One Library row by id, straight off op=artifacts_list — the live
    /// shelf first, then Archived (an archived deliverable is still his).
    private func fetchLibraryItem(_ itemID: String)
        async -> (kind: String, title: String, url: URL?)? {
        for shelfArchived in [false, true] {
            guard let obj = try? await AWire.request(
                "op=artifacts_list", method: "POST",
                body: ["archived": shelfArchived]) else { continue }
            let raw = (obj["items"] as? [[String: Any]]) ?? []
            if let hit = raw.first(where: { ($0["id"] as? String) == itemID }) {
                let urlString = (hit["url"] as? String) ?? ""
                let title = (hit["title"] as? String) ?? ""
                return (((hit["kind"] as? String) ?? "file").lowercased(),
                        title.isEmpty ? "Deliverable" : title,
                        urlString.isEmpty ? nil : URL(string: urlString))
            }
        }
        return nil
    }

    /// "PDF": fetch the signed URL's bytes and hand them to QuickLook; if
    /// the download fails, fall back to opening the link in Safari — either
    /// way the chip goes somewhere real.
    @MainActor
    private func openPDF(_ url: URL) {
        guard resolvingChip == nil else { return }
        resolvingChip = "PDF"
        Task {
            defer { resolvingChip = nil }
            await downloadAndPreview(url: url, title: chipTitle, ext: "pdf")
        }
    }

    /// Download to a temp file named for QuickLook's renderer choice, then
    /// present. Path separators are stripped so a hostile title can't escape
    /// the temp directory (LibraryView's rule). Safari is the fallback.
    @MainActor
    private func downloadAndPreview(url: URL, title: String, ext: String) async {
        do {
            let (data, resp) = try await URLSession.shared.data(from: url)
            if let http = resp as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            guard !data.isEmpty else { throw URLError(.zeroByteResource) }
            var clean = title
                .replacingOccurrences(of: "[/\\\\:]", with: "_", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.isEmpty || clean == "." || clean == ".." { clean = "deliverable" }
            clean = String(clean.prefix(60))
            let extLower = ext.lowercased()
            if !extLower.isEmpty && extLower.count <= 5
                && !clean.lowercased().hasSuffix(".\(extLower)") {
                clean += ".\(extLower)"
            }
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent(clean)
            try data.write(to: dest, options: .atomic)
            deliverableSheet = .file(PreviewFile(url: dest))
        } catch {
            _ = await UIApplication.shared.open(url)
        }
    }
}
