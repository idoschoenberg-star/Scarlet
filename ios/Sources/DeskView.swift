import Foundation
import SwiftUI
import UIKit

/// The Desk: Ido's reminders (his real Apple Reminders, two-way synced
/// server-side) and his Apple Notes (read on demand through the Mac agent),
/// in the house dark-scarlet look. Local-first: the last fetched lists are
/// cached to Documents/desk-cache.json and render instantly on open while a
/// background refresh brings the truth in.

// MARK: - Leaf (segment)

/// Which side of the Desk is showing: Reminders or Notes.
enum DeskLeaf: String, CaseIterable, Identifiable {
    case reminders
    case notes

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .reminders: return "Reminders"
        case .notes: return "Notes"
        }
    }

    var icon: String {
        switch self {
        case .reminders: return "checklist"
        case .notes: return "note.text"
        }
    }
}

/// The list-level ambient-focus line, shared by appearance and segment
/// switches so both report the exact same thing.
private func deskBrowsingFocus(leaf: DeskLeaf) -> String {
    "[FOCUS] Ido is on his Desk — the " + leaf.displayName + " list. "
        + "Reminders sync with Apple Reminders (list_reminders/create_reminder/"
        + "manage_reminder tools); Notes come from his Mac (apple notes tools)."
}

// MARK: - Wire types

/// One reminder, as `op=reminders_list` returns it. `done` is mutable for
/// the optimistic checkbox flip.
struct DeskReminder: Identifiable {
    let id: String
    let title: String
    let notes: String
    let dueAt: Date?
    let remindAt: Date?
    let priority: Int
    var done: Bool
    let updatedAt: Date?

    /// Apple priority: 0 = none, 1–3 = the high band that earns the dot.
    var isHighPriority: Bool { priority >= 1 && priority <= 3 }
}

/// One Apple Note title from the Mac agent's `list_notes`. The body arrives
/// only when the note is opened (`op=note_read`).
struct DeskNote: Identifiable {
    let id: String
    let title: String
    let modified: Date?
    let modifiedRaw: String?

    /// "2 days ago" when the modified stamp parses as a date, the raw string
    /// when it doesn't, nothing when the agent sent nothing.
    var modifiedText: String? {
        if let modified {
            return DeskDates.relative.localizedString(for: modified, relativeTo: Date())
        }
        if let modifiedRaw, !modifiedRaw.isEmpty { return modifiedRaw }
        return nil
    }
}

/// The four due buckets of the Reminders list.
enum DeskDueSection: String, Hashable {
    case overdue
    case today
    case upcoming
    case someday

    var title: String {
        switch self {
        case .overdue: return "Overdue"
        case .today: return "Today"
        case .upcoming: return "Upcoming"
        case .someday: return "Someday"
        }
    }
}

// MARK: - Dates

/// Desk-local date formatting. File-scope (no actor) so any view can format
/// synchronously — same shape as InboxView's MailDates.
enum DeskDates {
    static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    static let weekday: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f
    }()

    static let dayMonth: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return f
    }()

    /// Relative due chip: "Today 14:00", "Tomorrow", "Thu 09:30", "12 Sep".
    /// A midnight due time reads as all-day, so the clock part is dropped.
    static func dueChip(_ d: Date) -> String {
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute], from: d)
        let allDay = (comps.hour == 0 && comps.minute == 0)
        let clock = allDay ? "" : " " + time.string(from: d)
        if cal.isDateInToday(d) { return "Today" + clock }
        if cal.isDateInTomorrow(d) { return "Tomorrow" + clock }
        if cal.isDateInYesterday(d) { return "Yesterday" + clock }
        let days = cal.dateComponents([.day],
                                      from: cal.startOfDay(for: Date()),
                                      to: cal.startOfDay(for: d)).day ?? 0
        if days > 1 && days < 7 { return weekday.string(from: d) + clock }
        return dayMonth.string(from: d) + clock
    }

    /// The data-doctrine stamp under the header: "updated 3m ago".
    static func updatedStamp(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        if s < 60 { return "updated just now" }
        if s < 3600 { return "updated \(s / 60)m ago" }
        if s < 86400 { return "updated \(s / 3600)h ago" }
        return "updated " + relative.localizedString(for: d, relativeTo: Date())
    }
}

// MARK: - Model

@MainActor
final class DeskModel: ObservableObject {
    @Published var leaf: DeskLeaf = .reminders
    @Published var reminders: [DeskReminder] = []
    @Published var notes: [DeskNote] = []
    /// The Mac agent answered queued/error — the home Mac is asleep. Cached
    /// notes (if any) keep rendering under an asleep banner.
    @Published var macAsleep = false
    @Published var loading = false
    @Published var errorText = ""
    @Published var remindersUpdated: Date?
    @Published var notesUpdated: Date?

    /// The raw wire rows behind the parsed lists — what desk-cache.json
    /// stores, so cache and network go through the same parsers.
    private var rawReminders: [[String: Any]] = []
    private var rawNotes: [[String: Any]] = []

    /// Monotonic load token: a slow fetch landing after a segment switch is
    /// dropped (LibraryModel / InboxModel discipline).
    private var loadGeneration = 0

    init() {
        loadCache()
    }

    /// The freshness stamp for whichever leaf is showing.
    var activeUpdated: Date? {
        leaf == .reminders ? remindersUpdated : notesUpdated
    }

    /// Segment tap: swap the leaf and refresh it. Cached rows stay on screen
    /// (local-first) while the network catches up.
    func setLeaf(_ newLeaf: DeskLeaf) {
        guard newLeaf != leaf else { return }
        leaf = newLeaf
        errorText = ""
        Task { await load() }
    }

    func load() async {
        switch leaf {
        case .reminders: await loadReminders()
        case .notes: await loadNotes()
        }
    }

    // MARK: reminders

    func loadReminders() async {
        guard TokenStore.token != nil else {
            errorText = "Locked — unlock Scarlet to see your Desk."
            return
        }
        if reminders.isEmpty { loading = true }
        loadGeneration += 1
        let generation = loadGeneration
        defer { if generation == loadGeneration { loading = false } }
        do {
            let data = try await Self.request([
                "op": "reminders_list",
                "include_done": false,
            ])
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let raw = (obj["reminders"] as? [[String: Any]]) ?? []
            guard generation == loadGeneration else { return }
            rawReminders = raw
            reminders = Self.parseReminders(raw)
            remindersUpdated = Date()
            errorText = ""
            saveCache()
        } catch {
            guard generation == loadGeneration else { return }
            errorText = "Couldn't reach your reminders — check your connection."
        }
    }

    /// Checkbox tap: flip `done` locally right away (and allow flipping it
    /// straight back — the row stays put until the next refresh), then tell
    /// the server. A failure reverts the flip.
    func toggle(_ reminder: DeskReminder) {
        guard let idx = reminders.firstIndex(where: { $0.id == reminder.id }) else { return }
        let newDone = !reminders[idx].done
        withAnimation(.easeInOut(duration: 0.15)) {
            reminders[idx].done = newDone
        }
        if let ri = rawReminders.firstIndex(where: { ($0["id"] as? String) == reminder.id }) {
            rawReminders[ri]["done"] = newDone
            saveCache()
        }
        // A just-added row that hasn't reloaded yet has no server id.
        guard !reminder.id.hasPrefix("local-") else { return }
        Task {
            do {
                let data = try await Self.request([
                    "op": "reminder_toggle",
                    "id": reminder.id,
                    "done": newDone,
                ])
                let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                guard (obj?["ok"] as? Bool) == true else {
                    throw URLError(.badServerResponse)
                }
            } catch {
                if let i = self.reminders.firstIndex(where: { $0.id == reminder.id }) {
                    self.reminders[i].done = !newDone
                }
                self.errorText = "Couldn't update \"\(reminder.title)\" — try again."
            }
        }
    }

    /// Quick-add: optimistic insert at the top of Someday (no due date yet),
    /// then `reminder_add`; on success a quiet reload swaps in the server id,
    /// on failure the row leaves and the bar apologizes.
    func add(_ title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let localId = "local-" + UUID().uuidString
        let optimistic = DeskReminder(id: localId, title: t, notes: "",
                                      dueAt: nil, remindAt: nil, priority: 0,
                                      done: false, updatedAt: Date())
        withAnimation(.easeInOut(duration: 0.15)) {
            reminders.insert(optimistic, at: 0)
        }
        Task {
            do {
                let data = try await Self.request([
                    "op": "reminder_add",
                    "title": t,
                ])
                let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                guard (obj?["ok"] as? Bool) == true else {
                    throw URLError(.badServerResponse)
                }
                await self.loadReminders()
            } catch {
                withAnimation(.easeInOut(duration: 0.15)) {
                    self.reminders.removeAll { $0.id == localId }
                }
                self.errorText = "Couldn't add \"\(t)\" — try again."
            }
        }
    }

    // MARK: notes

    func loadNotes() async {
        guard TokenStore.token != nil else {
            errorText = "Locked — unlock Scarlet to see your Desk."
            return
        }
        if notes.isEmpty { loading = true }
        loadGeneration += 1
        let generation = loadGeneration
        defer { if generation == loadGeneration { loading = false } }
        do {
            let data = try await Self.request(["op": "notes_list"])
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let payload = (obj["result"] as? [String: Any]) ?? obj
            guard generation == loadGeneration else { return }
            if let parsed = Self.parseNotes(payload) {
                rawNotes = parsed.raw
                notes = parsed.notes
                macAsleep = false
                notesUpdated = Date()
                errorText = ""
                saveCache()
            } else {
                // queued / error / unrecognized → the home Mac is asleep.
                macAsleep = true
            }
        } catch {
            guard generation == loadGeneration else { return }
            errorText = "Couldn't reach the notes bridge — check your connection."
        }
    }

    // MARK: parsing (defensive — the notes payload is the Mac agent's JSON)

    static func parseReminders(_ raw: [[String: Any]]) -> [DeskReminder] {
        raw.compactMap { r in
            guard let id = r["id"] as? String, !id.isEmpty else { return nil }
            let title = ((r["title"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return DeskReminder(
                id: id,
                title: title.isEmpty ? "Untitled" : title,
                notes: (r["notes"] as? String) ?? "",
                dueAt: MailDates.parse(r["due_at"] as? String),
                remindAt: MailDates.parse(r["remind_at"] as? String),
                priority: intValue(r["priority"]),
                done: (r["done"] as? Bool) ?? false,
                updatedAt: MailDates.parse(r["updated_at"] as? String)
            )
        }
    }

    /// The `notes_list` result, inspected defensively. Success needs a
    /// `notes` array (of dicts with `title`, or bare title strings) at the
    /// top level or one nesting down; queued/error/anything else returns nil
    /// so the view shows the Mac-asleep state. Entries are normalized to
    /// `{"title": ..., "modified": ...}` — the cache's on-disk shape.
    static func parseNotes(_ payload: [String: Any]) -> (raw: [[String: Any]], notes: [DeskNote])? {
        let queued = (payload["queued"] as? Bool) ?? (payload["queued"] != nil)
        if queued { return nil }
        if let err = payload["error"] as? String, !err.isEmpty { return nil }
        var list = payload["notes"] as? [Any]
        if list == nil, let inner = payload["result"] as? [String: Any] {
            list = inner["notes"] as? [Any]
        }
        guard let entries = list else { return nil }
        var raw: [[String: Any]] = []
        for entry in entries {
            if let s = entry as? String {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { raw.append(["title": t]) }
            } else if let d = entry as? [String: Any] {
                let t = ((d["title"] as? String) ?? (d["name"] as? String) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { continue }
                var norm: [String: Any] = ["title": t]
                if let m = (d["modified"] as? String)
                    ?? (d["modified_at"] as? String)
                    ?? (d["updated_at"] as? String) {
                    norm["modified"] = m
                }
                raw.append(norm)
            }
        }
        return (raw, buildNotes(raw))
    }

    static func buildNotes(_ raw: [[String: Any]]) -> [DeskNote] {
        raw.enumerated().map { i, d in
            let title = (d["title"] as? String) ?? "Untitled"
            let modified = d["modified"] as? String
            return DeskNote(id: "\(i)-" + title,
                            title: title,
                            modified: MailDates.parse(modified),
                            modifiedRaw: modified)
        }
    }

    private static func intValue(_ v: Any?) -> Int {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String { return Int(s) ?? 0 }
        return 0
    }

    // MARK: cache — Documents/desk-cache.json, the local-first snapshot

    static var cacheURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return docs.appendingPathComponent("desk-cache.json")
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: Self.cacheURL),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }
        rawReminders = (obj["reminders"] as? [[String: Any]]) ?? []
        rawNotes = (obj["notes"] as? [[String: Any]]) ?? []
        reminders = Self.parseReminders(rawReminders)
        notes = Self.buildNotes(rawNotes)
        remindersUpdated = MailDates.parse(obj["reminders_updated"] as? String)
        notesUpdated = MailDates.parse(obj["notes_updated"] as? String)
    }

    private func saveCache() {
        var obj: [String: Any] = [
            "reminders": rawReminders,
            "notes": rawNotes,
        ]
        if let d = remindersUpdated {
            obj["reminders_updated"] = MailDates.isoPlain.string(from: d)
        }
        if let d = notesUpdated {
            obj["notes_updated"] = MailDates.isoPlain.string(from: d)
        }
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj)
        else { return }
        try? data.write(to: Self.cacheURL, options: .atomic)
    }

    // MARK: plumbing — the op rides the QUERY STRING (app-wide convention:
    // the server dispatches on ?op=...); the JSON body carries the params.
    // Internal (not private) so DeskNoteSheet fetches through the same pipe.

    static func request(_ body: [String: Any]) async throws -> Data {
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
}

// MARK: - Desk page

struct DeskView: View {
    @StateObject private var model = DeskModel()
    @EnvironmentObject var convo: Conversation

    @State private var quickAdd = ""
    @FocusState private var addFocused: Bool
    /// Tapped note → the reading sheet.
    @State private var openNote: DeskNote?
    /// The exact focus line last claimed for an open note; the sheet's
    /// dismissal restores the browsing focus only if this still owns it
    /// (InboxView's stale-guard pattern).
    @State private var openedFocus: String?

    private let scarletRose = Color(red: 1, green: 0.35, blue: 0.42)
    /// Solid card surface, matching the presence capsule — translucency over
    /// a scrolling list reads as broken overlap.
    private let surface = Color(red: 0.16, green: 0.055, blue: 0.085)
    private let noteTint = Color(red: 0.95, green: 0.78, blue: 0.35)
    private let priorityTint = Color(red: 0.98, green: 0.62, blue: 0.28)

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                headerBar
                leafSwitcher
                content
            }
            .background(ScarletBackground().ignoresSafeArea())
            // Quick-add rides pinned above Scarlet's capsule; both are part
            // of the screen's layout (safeAreaInset), never floating overlays.
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if model.leaf == .reminders {
                        quickAddBar
                    }
                    ScarletPresenceView(convo: convo)
                        .padding(.vertical, 6)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            // Ambient focus: the Desk reports itself on appearance and on
            // every segment switch.
            .onAppear { convo.setFocus(browsingFocus) }
            .onChange(of: model.leaf) { _, _ in
                convo.setFocus(browsingFocus)
            }
            // Dictation etiquette: her ears close while Ido types into the
            // quick-add row (Conversation's beginTyping/endTyping pattern).
            .onChange(of: addFocused) { _, focused in
                if focused { convo.beginTyping() } else { convo.endTyping() }
            }
            .sheet(item: $openNote, onDismiss: { restoreBrowsingFocus() }) { note in
                DeskNoteSheet(note: note)
                    .preferredColorScheme(.dark)
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

    // MARK: header (big heavy title + refresh + freshness stamp)

    private var headerBar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 12) {
                Text("Desk")
                    .font(.system(size: 34, weight: .heavy))
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    Task { await model.load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.white)
                }
                .disabled(model.loading)
            }
            if let stamp = model.activeUpdated {
                Text(DeskDates.updatedStamp(stamp))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    // MARK: segment switcher (two-segment capsule, Library's shelfSwitcher)

    private var leafSwitcher: some View {
        HStack(spacing: 4) {
            ForEach(DeskLeaf.allCases) { l in
                segment(l)
            }
        }
        .padding(4)
        .background(Capsule().fill(.white.opacity(0.06)))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func segment(_ l: DeskLeaf) -> some View {
        Button {
            model.setLeaf(l)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: l.icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(l.displayName)
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(model.leaf == l ? scarletRose : .white.opacity(0.55))
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
                Capsule().fill(model.leaf == l
                    ? scarletRose.opacity(0.18) : Color.clear)
            )
            .overlay(
                Capsule().stroke(model.leaf == l
                    ? scarletRose.opacity(0.45) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: content

    @ViewBuilder
    private var content: some View {
        switch model.leaf {
        case .reminders: remindersContent
        case .notes: notesContent
        }
    }

    // MARK: reminders

    @ViewBuilder
    private var remindersContent: some View {
        if model.loading && model.reminders.isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                Text("Fetching your reminders…")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.reminders.isEmpty && !model.errorText.isEmpty {
            retryState(model.errorText)
        } else if model.reminders.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "checklist")
                    .font(.title2).foregroundStyle(.secondary)
                Text("Nothing on the list — add one below, or ask Scarlet.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            remindersList
        }
    }

    /// Overdue / Today / Upcoming / Someday, empty buckets skipped. Grouping
    /// looks only at the due date, so a just-checked row stays put (briefly
    /// strikethrough, un-toggleable) until the next refresh sweeps it.
    private var grouped: [(DeskDueSection, [DeskReminder])] {
        let now = Date()
        let cal = Calendar.current
        var overdue: [DeskReminder] = []
        var today: [DeskReminder] = []
        var upcoming: [DeskReminder] = []
        var someday: [DeskReminder] = []
        for r in model.reminders {
            if let d = r.dueAt {
                if d < now {
                    overdue.append(r)
                } else if cal.isDateInToday(d) {
                    today.append(r)
                } else {
                    upcoming.append(r)
                }
            } else {
                someday.append(r)
            }
        }
        let byDue: (DeskReminder, DeskReminder) -> Bool = {
            ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture)
        }
        overdue.sort(by: byDue)
        today.sort(by: byDue)
        upcoming.sort(by: byDue)
        let all: [(DeskDueSection, [DeskReminder])] = [
            (.overdue, overdue), (.today, today),
            (.upcoming, upcoming), (.someday, someday),
        ]
        return all.filter { !$0.1.isEmpty }
    }

    private var remindersList: some View {
        List {
            if !model.errorText.isEmpty {
                errorRow
            }
            ForEach(grouped, id: \.0) { section, rows in
                Section {
                    ForEach(rows) { r in
                        DeskReminderRow(
                            reminder: r,
                            overdue: section == .overdue,
                            rose: scarletRose,
                            priorityTint: priorityTint
                        ) {
                            model.toggle(r)
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(.white.opacity(0.12))
                    }
                } header: {
                    Text(section.title)
                        .font(.system(size: 12, weight: .bold))
                        .tracking(1.2)
                        .textCase(.uppercase)
                        .foregroundStyle(section == .overdue
                            ? scarletRose : .white.opacity(0.45))
                }
            }
            // Subtle provenance footer.
            HStack {
                Spacer()
                Label("Synced with Apple Reminders",
                      systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.3))
                Spacer()
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { await model.loadReminders() }
    }

    // MARK: quick-add (pinned above the presence capsule)

    private var trimmedQuickAdd: String {
        quickAdd.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var quickAddBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
            TextField("Add a reminder…", text: $quickAdd)
                .textFieldStyle(.plain)
                .foregroundStyle(.white)
                .submitLabel(.done)
                .focused($addFocused)
                .onSubmit { submitQuickAdd() }
            Button {
                submitQuickAdd()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(trimmedQuickAdd.isEmpty
                        ? Color.white.opacity(0.25) : scarletRose)
            }
            .buttonStyle(.plain)
            .disabled(trimmedQuickAdd.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 16).fill(surface))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        )
        .frame(maxWidth: 360)
        .padding(.horizontal, 14)
    }

    private func submitQuickAdd() {
        let t = trimmedQuickAdd
        guard !t.isEmpty else { return }
        model.add(t)
        quickAdd = ""
    }

    // MARK: notes

    @ViewBuilder
    private var notesContent: some View {
        if model.loading && model.notes.isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                Text("Asking your Mac…")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.notes.isEmpty && model.macAsleep {
            VStack(spacing: 12) {
                Image(systemName: "moon.zzz.fill")
                    .font(.title2).foregroundStyle(.secondary)
                Text("Your home Mac is asleep — notes will load when it wakes.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try again") { Task { await model.loadNotes() } }
                    .buttonStyle(.bordered)
                    .tint(scarletRose)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.notes.isEmpty && !model.errorText.isEmpty {
            retryState(model.errorText)
        } else if model.notes.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "note.text")
                    .font(.title2).foregroundStyle(.secondary)
                Text("No notes found on your Mac.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            notesList
        }
    }

    private var notesList: some View {
        List {
            if model.macAsleep {
                Text("Your home Mac is asleep — showing the last snapshot; notes will refresh when it wakes.")
                    .font(.footnote)
                    .foregroundStyle(Color(red: 0.91, green: 0.69, blue: 0.31))
                    .listRowBackground(Color.clear)
            }
            if !model.errorText.isEmpty {
                errorRow
            }
            ForEach(model.notes) { note in
                Button {
                    open(note)
                } label: {
                    DeskNoteRow(note: note, tint: noteTint)
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .listRowSeparatorTint(.white.opacity(0.12))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { await model.loadNotes() }
    }

    // MARK: shared bits

    private var errorRow: some View {
        Text(model.errorText)
            .font(.footnote)
            .foregroundStyle(Color(red: 0.91, green: 0.69, blue: 0.31))
            .listRowBackground(Color.clear)
    }

    private func retryState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.title2).foregroundStyle(.secondary)
            Text(message)
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try again") { Task { await model.load() } }
                .buttonStyle(.bordered)
                .tint(scarletRose)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Scarlet focus

    private var browsingFocus: String {
        deskBrowsingFocus(leaf: model.leaf)
    }

    private func noteFocus(_ note: DeskNote) -> String {
        "[FOCUS] Ido opened an Apple Note from his Mac on his Desk: "
            + "\"\(note.title)\". He is reading it now."
    }

    private func open(_ note: DeskNote) {
        let f = noteFocus(note)
        openedFocus = f
        convo.setFocus(f)
        openNote = note
    }

    /// Stale-guard (InboxView's MailDetailView pattern): restore the Desk
    /// focus only if the closed sheet still owns it — another screen may
    /// have claimed focus while the sheet was up.
    private func restoreBrowsingFocus() {
        if let f = openedFocus, convo.currentFocus == f {
            convo.setFocus(browsingFocus)
        }
        openedFocus = nil
    }
}

// MARK: - Reminder row

/// One reminder: tappable circle checkbox, title (strikethrough when done),
/// notes line, relative due chip (rose when overdue), priority dot.
struct DeskReminderRow: View {
    let reminder: DeskReminder
    let overdue: Bool
    let rose: Color
    let priorityTint: Color
    let onToggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: reminder.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(reminder.done ? rose : .white.opacity(0.35))
                    // A comfortable 44pt-ish target without inflating the row.
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 3) {
                Text(reminder.title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(reminder.done ? Color.white.opacity(0.4) : Color.white)
                    .strikethrough(reminder.done, color: .white.opacity(0.5))
                    .lineLimit(2)
                    .truncationMode(.tail)
                if !reminder.notes.isEmpty {
                    Text(reminder.notes)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if reminder.dueAt != nil || reminder.isHighPriority {
                    HStack(spacing: 6) {
                        if let due = reminder.dueAt {
                            Text(DeskDates.dueChip(due))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(overdue ? rose : .white.opacity(0.55))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule().fill(overdue
                                        ? rose.opacity(0.16) : .white.opacity(0.07))
                                )
                        }
                        if reminder.isHighPriority {
                            Circle()
                                .fill(priorityTint)
                                .frame(width: 6, height: 6)
                        }
                    }
                    .padding(.top, 1)
                }
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - Note row

/// One note title: doc tile, title, modified stamp, trailing chevron.
struct DeskNoteRow: View {
    let note: DeskNote
    let tint: Color

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(tint.opacity(0.18))
                Image(systemName: "note.text")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(tint)
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(note.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .truncationMode(.tail)
                if let stamp = note.modifiedText {
                    Text(stamp)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.35))
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - Note reading sheet

/// The reader: fetches the note body on appearance (`op=note_read` with the
/// title as the query) and shows it in a quiet serif reading column. Queued
/// or error from the Mac agent becomes the friendly asleep state.
struct DeskNoteSheet: View {
    let note: DeskNote
    @Environment(\.dismiss) private var dismiss

    @State private var loading = true
    @State private var text = ""
    @State private var shownTitle = ""
    @State private var alsoMatched: [String] = []
    @State private var asleep = false
    @State private var errorText = ""

    private let scarletRose = Color(red: 1, green: 0.35, blue: 0.42)

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Asking your Mac…")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if asleep {
                    stateView(icon: "moon.zzz.fill",
                              message: "Your home Mac is asleep — notes will load when it wakes.")
                } else if !errorText.isEmpty {
                    stateView(icon: "wifi.exclamationmark", message: errorText)
                } else {
                    reader
                }
            }
            .background(ScarletBackground().ignoresSafeArea())
            .navigationTitle(shownTitle.isEmpty ? note.title : shownTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await load() }
    }

    private var reader: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !alsoMatched.isEmpty {
                    Text("Also matched: " + alsoMatched.joined(separator: ", "))
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.4))
                }
                Text(text)
                    .font(.system(.body, design: .serif))
                    .lineSpacing(5)
                    .foregroundStyle(.white.opacity(0.92))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(20)
        }
    }

    private func stateView(icon: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2).foregroundStyle(.secondary)
            Text(message)
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try again") {
                Task { await load() }
            }
            .buttonStyle(.bordered)
            .tint(scarletRose)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        loading = true
        asleep = false
        errorText = ""
        defer { loading = false }
        do {
            let data = try await DeskModel.request([
                "op": "note_read",
                "query": note.title,
            ])
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let result = (obj["result"] as? [String: Any]) ?? obj
            let queued = (result["queued"] as? Bool) ?? (result["queued"] != nil)
            if queued {
                asleep = true
                return
            }
            if let err = result["error"] as? String, !err.isEmpty {
                asleep = true
                return
            }
            if (result["found"] as? Bool) == false {
                errorText = "Your Mac couldn't find a note matching \"\(note.title)\"."
                return
            }
            shownTitle = (result["title"] as? String) ?? note.title
            alsoMatched = (result["also_matched"] as? [String]) ?? []
            let body = ((result["text"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            text = body.isEmpty ? "(This note is empty.)" : body
        } catch {
            errorText = "Couldn't reach the notes bridge — check your connection and try again."
        }
    }
}
