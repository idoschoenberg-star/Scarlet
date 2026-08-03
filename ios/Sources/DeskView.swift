import Foundation
import SwiftUI
import UIKit

/// The Desk: Ido's reminders (his real Apple Reminders, two-way synced
/// server-side) and his Apple Notes (read on demand through the Mac agent),
/// styled to match the REAL Apple Reminders and Apple Notes apps in dark
/// mode. Local-first: the last fetched lists are cached to
/// Documents/desk-cache.json and render instantly on open while a
/// background refresh brings the truth in.

// MARK: - Native dark palette (Apple Reminders / Notes design language)

/// The system dark-mode colors both leaves draw from. Reminders' accent is
/// iOS blue; Notes' accent is the yellow-amber; everything else is the
/// shared grouped-dark vocabulary.
private enum DeskUI {
    /// Pure black page background (both apps in dark mode).
    static let background = Color.black
    /// Grouped inset card surface — #1C1C1E.
    static let card = Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255)
    /// Row separators — #38383A.
    static let separator = Color(red: 56 / 255, green: 56 / 255, blue: 58 / 255)
    /// Secondary text / empty checkbox ring — #8E8E93.
    static let gray = Color(red: 142 / 255, green: 142 / 255, blue: 147 / 255)
    /// Reminders accent — iOS blue #0A84FF.
    static let blue = Color(red: 10 / 255, green: 132 / 255, blue: 255 / 255)
    /// Notes accent — yellow-amber #FFD60A.
    static let yellow = Color(red: 1, green: 214 / 255, blue: 10 / 255)
    /// Overdue / destructive — #FF453A.
    static let red = Color(red: 1, green: 69 / 255, blue: 58 / 255)
    /// Priority "!" marks — #FF9F0A.
    static let orange = Color(red: 1, green: 159 / 255, blue: 10 / 255)
    /// Segmented control bed — #767680 at 24% (dark tertiary fill).
    static let segmentBed = Color(red: 118 / 255, green: 118 / 255, blue: 128 / 255)
        .opacity(0.24)
    /// Segmented control selected pill — #636366.
    static let segmentPill = Color(red: 99 / 255, green: 99 / 255, blue: 102 / 255)
}

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

    /// The leaf's native accent: iOS blue for Reminders, Notes yellow.
    var accent: Color {
        switch self {
        case .reminders: return DeskUI.blue
        case .notes: return DeskUI.yellow
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
    /// Manual position from `reminders_list` (`sort_order`, may be null).
    /// Mutable so drag-to-reorder can assign a fresh fractional order.
    var sortOrder: Double? = nil

    /// Apple priority: 0 = none, 1–3 = the high band that earns the marks.
    var isHighPriority: Bool { priority >= 1 && priority <= 3 }

    /// Reminders-style exclamation prefix. Apple's convention: the lower the
    /// number, the higher the priority — 1 is "!!!", 3 is "!". Anything
    /// outside the 1–3 band shows nothing (same visibility rule as before).
    var priorityMarks: String {
        switch priority {
        case 1: return "!!!"
        case 2: return "!!"
        case 3: return "!"
        default: return ""
        }
    }
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

    /// Reminders-style header color: Overdue red, Today/Upcoming white,
    /// Someday gray.
    var headerColor: Color {
        switch self {
        case .overdue: return DeskUI.red
        case .today: return Color.white
        case .upcoming: return Color.white
        case .someday: return DeskUI.gray
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

    /// Relative due line: "Today 14:00", "Tomorrow", "Thu 09:30", "12 Sep".
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
    /// Quick-add failures surface HERE — a small red line under the add bar,
    /// right where Ido is looking — never as an alert.
    @Published var addErrorText = ""
    /// The just-added row's id: briefly tinted so the optimistic insert is
    /// unmissable at the top of Today.
    @Published var highlightId: String?
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
        withAnimation(.snappy(duration: 0.25)) {
            leaf = newLeaf
        }
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
        withAnimation(.snappy(duration: 0.2)) {
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

    /// Quick-add: optimistic insert at the TOP of Today — where Ido is
    /// looking — with a brief highlight, then `reminder_add`. On success a
    /// silent background reload swaps in the server's row (wherever the
    /// server files it); on failure the row leaves and a small red line
    /// under the bar says so.
    func add(_ title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        addErrorText = ""
        let localId = "local-" + UUID().uuidString
        let optimistic = DeskReminder(id: localId, title: t, notes: "",
                                      dueAt: nil, remindAt: nil, priority: 0,
                                      done: false, updatedAt: Date(),
                                      sortOrder: nil)
        withAnimation(.snappy(duration: 0.2)) {
            reminders.insert(optimistic, at: 0)
            highlightId = localId
        }
        // The highlight is a moment, not a state — fade it after ~2s.
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if self.highlightId == localId {
                withAnimation(.easeOut(duration: 0.6)) { self.highlightId = nil }
            }
        }
        Task {
            do {
                let data = try await Self.request([
                    "op": "reminder_add",
                    "title": t,
                ])
                let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                guard (obj?["ok"] as? Bool) == true else {
                    let serverError = (obj?["error"] as? String) ?? ""
                    throw DeskAddError.rejected(serverError)
                }
                // Server confirmed — silent refresh (loadReminders only
                // spins when the list is empty, so nothing flashes).
                await self.loadReminders()
            } catch {
                withAnimation(.snappy(duration: 0.2)) {
                    self.reminders.removeAll { $0.id == localId }
                    if self.highlightId == localId { self.highlightId = nil }
                }
                if let rejected = error as? DeskAddError,
                   case .rejected(let msg) = rejected, !msg.isEmpty {
                    self.addErrorText = "Couldn't add \"\(t)\" — \(msg)"
                } else {
                    self.addErrorText = "Couldn't add \"\(t)\" — try again."
                }
            }
        }
    }

    /// The one failure `add` can name precisely: the server said {ok:false}.
    private enum DeskAddError: Error {
        case rejected(String)
    }

    // MARK: reorder — fractional sort_order, optimistic, revert on failure

    /// Drag-to-reorder within one due section. The moved row gets a
    /// fractional `sort_order` from its new neighbors, the flat list (and
    /// the desk-cache) reorders instantly, and `reminder_reorder` fires in
    /// the background — a failure puts everything back.
    func move(in section: DeskDueSection, rows: [DeskReminder],
              from source: IndexSet, to destination: Int) {
        guard let first = source.first, rows.indices.contains(first) else { return }
        let movedId = rows[first].id
        var newRows = rows
        newRows.move(fromOffsets: source, toOffset: destination)
        // A drop back onto the same spot is a no-op.
        guard newRows.map(\.id) != rows.map(\.id),
              let newIndex = newRows.firstIndex(where: { $0.id == movedId })
        else { return }
        let newOrder = Self.fractionalOrder(rows: newRows, index: newIndex)
        newRows[newIndex].sortOrder = newOrder

        let previousReminders = reminders
        let previousRaw = rawReminders

        // Rebuild the flat list: this section's slots take the new order,
        // every other row stays put (grouping is a stable partition).
        let sectionIds = Set(rows.map(\.id))
        var queue = newRows
        reminders = reminders.map { r in
            guard sectionIds.contains(r.id), !queue.isEmpty else { return r }
            return queue.removeFirst()
        }
        // Mirror into the raw cache rows so a relaunch shows the same order.
        // Optimistic local- rows have no raw twin, so match on what exists.
        let rawIds = Set(rawReminders.compactMap { $0["id"] as? String })
        var rawByOrder: [[String: Any]] = []
        for row in newRows where rawIds.contains(row.id) {
            if var raw = rawReminders.first(where: { ($0["id"] as? String) == row.id }) {
                if row.id == movedId { raw["sort_order"] = newOrder }
                rawByOrder.append(raw)
            }
        }
        var rawQueue = rawByOrder
        rawReminders = rawReminders.map { raw in
            guard let id = raw["id"] as? String, sectionIds.contains(id),
                  !rawQueue.isEmpty else { return raw }
            return rawQueue.removeFirst()
        }
        saveCache()

        // A just-added row that hasn't reloaded yet has no server id — keep
        // its local position and let the next refresh settle it.
        guard !movedId.hasPrefix("local-") else { return }
        Task {
            do {
                let data = try await Self.request([
                    "op": "reminder_reorder",
                    "id": movedId,
                    "sort_order": newOrder,
                ])
                let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                guard (obj?["ok"] as? Bool) == true else {
                    throw URLError(.badServerResponse)
                }
            } catch {
                withAnimation(.snappy(duration: 0.2)) {
                    self.reminders = previousReminders
                }
                self.rawReminders = previousRaw
                self.saveCache()
                self.errorText = "Couldn't save the new order — try again."
            }
        }
    }

    /// The dropped row's fractional order: midpoint of its new neighbors.
    /// A null neighbor order means "bottom" (+infinity); both neighbors
    /// null (or absent) falls back to (index+1)*1024.
    static func fractionalOrder(rows: [DeskReminder], index: Int) -> Double {
        let fallback = Double(index + 1) * 1024
        let prevVal: Double? = index > 0
            ? (rows[index - 1].sortOrder ?? Double.infinity) : nil
        let nextVal: Double = index + 1 < rows.count
            ? (rows[index + 1].sortOrder ?? Double.infinity) : Double.infinity
        if let p = prevVal {
            if p.isFinite && nextVal.isFinite { return (p + nextVal) / 2 }
            if p.isFinite { return p + 1024 }
            return fallback
        }
        if nextVal.isFinite { return nextVal / 2 }
        return fallback
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
        var seen = Set<String>()
        return raw.compactMap { r in
            guard let id = r["id"] as? String, !id.isEmpty else { return nil }
            // A repeated reminder id (recurring/duplicated sync) traps the
            // drag-reorder diffable List at regular width — keep the first.
            guard seen.insert(id).inserted else { return nil }
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
                updatedAt: MailDates.parse(r["updated_at"] as? String),
                sortOrder: doubleValue(r["sort_order"])
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

    /// `sort_order` arrives as a JSON number (or null, or — defensively — a
    /// string); nil means "no manual position".
    private static func doubleValue(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s) }
        return nil
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
    /// Non-nil presents the standard drafting window (DraftView) seeded for
    /// a Desk channel: "apple_note" from the Notes compose button,
    /// "reminder" from the dictate button beside the quick-add bar.
    /// ONE sheet driver — the note reader OR the drafting window. Two stacked
    /// `.sheet(item:)` modifiers crash Mac Catalyst; a single enum-driven sheet
    /// is safe.
    enum DeskSheet: Identifiable {
        case note(DeskNote), draft(ChannelDraftSeed)
        var id: String {
            switch self {
            case .note(let n): return "note-\(n.id)"
            case .draft(let s): return "draft-\(s.id)"
            }
        }
    }
    @State private var activeSheet: DeskSheet?
    /// Drag handles for the reminders list — flipped by the small Reorder
    /// toggle in the header (no EditButton needed).
    @State private var remindersEditMode: EditMode = .inactive
    /// The exact focus line last claimed for an open note; the sheet's
    /// dismissal restores the browsing focus only if this still owns it
    /// (InboxView's stale-guard pattern).
    @State private var openedFocus: String?

    /// The active leaf's accent — blue in Reminders, yellow in Notes.
    private var leafAccent: Color {
        model.leaf.accent
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                headerBar
                leafSwitcher
                content
            }
            .background(DeskUI.background.ignoresSafeArea())
            // Quick-add rides pinned above Scarlet's capsule; both are part
            // of the screen's layout (safeAreaInset), never floating overlays.
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if model.leaf == .reminders {
                        quickAddRow
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
                // Reorder mode belongs to the Reminders leaf alone.
                remindersEditMode = .inactive
            }
            // Dictation etiquette: her ears close while Ido types into the
            // quick-add row (Conversation's beginTyping/endTyping pattern).
            .onChange(of: addFocused) { _, focused in
                if focused { convo.beginTyping() } else { convo.endTyping() }
            }
            // ONE sheet (see DeskSheet): the note reader or the drafting window.
            // On dismiss, restore focus and refresh so an approved note/reminder
            // shows right away.
            .sheet(item: $activeSheet, onDismiss: {
                restoreBrowsingFocus()
                Task { await model.load() }
            }) { sheet in
                switch sheet {
                case .note(let note):
                    DeskNoteSheet(note: note)
                        .preferredColorScheme(.dark)
                case .draft(let seed):
                    DraftView(seed: nil, channelSeed: seed)
                        .environmentObject(convo)
                        .preferredColorScheme(.dark)
                }
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

    // MARK: header (big bold title + refresh + freshness stamp)

    private var headerBar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 12) {
                Text("Desk")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                if model.leaf == .reminders && !model.reminders.isEmpty {
                    reorderToggle
                }
                if model.leaf == .notes {
                    newNoteButton
                }
                Button {
                    Task { await model.load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(leafAccent)
                }
                .disabled(model.loading)
            }
            if let stamp = model.activeUpdated {
                Text(DeskDates.updatedStamp(stamp))
                    .font(.system(size: 11))
                    .foregroundStyle(DeskUI.gray)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    /// Small header toggle that flips the reminders list into edit mode so
    /// the drag handles appear — "Reorder" to start, "Done" to finish.
    private var reorderToggle: some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) {
                remindersEditMode = remindersEditMode == .active
                    ? .inactive : .active
            }
        } label: {
            Text(remindersEditMode == .active ? "Done" : "Reorder")
                .font(.system(size: 15,
                              weight: remindersEditMode == .active
                                  ? .semibold : .regular))
                .foregroundStyle(DeskUI.blue)
        }
        .buttonStyle(.plain)
    }

    /// Apple-Notes-style compose (square-and-pencil, Notes yellow) — opens
    /// the standard drafting window on the "apple_note" channel: dictate or
    /// type the ask, Scarlet tidies it into a note, Approve saves it to
    /// Apple Notes.
    private var newNoteButton: some View {
        Button {
            activeSheet = .draft(ChannelDraftSeed(channel: "apple_note",
                                                  recipient: "Notes"))
        } label: {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(DeskUI.yellow)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New Note")
    }

    // MARK: segment switcher (native segmented-control look)

    private var leafSwitcher: some View {
        HStack(spacing: 2) {
            ForEach(DeskLeaf.allCases) { l in
                segment(l)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(DeskUI.segmentBed)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func segment(_ l: DeskLeaf) -> some View {
        let selected = model.leaf == l
        return Button {
            model.setLeaf(l)
        } label: {
            Text(l.displayName)
                .font(.system(size: 13, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? l.accent : Color.white)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selected ? DeskUI.segmentPill : Color.clear)
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
    /// faded, still toggleable) until the next refresh sweeps it.
    ///
    /// Each bucket is a STABLE partition of the flat list — no client
    /// re-sort. The server already orders by sort_order (nulls last), then
    /// due_at, and drag-to-reorder edits the flat list directly, so the
    /// array order IS the display order.
    ///
    /// One exception: a just-added optimistic row (local- id, no due date
    /// yet) shows at the top of TODAY — where Ido is looking when he adds —
    /// not buried in Someday. The server's next refresh files it properly.
    private var grouped: [(DeskDueSection, [DeskReminder])] {
        let now = Date()
        let cal = Calendar.current
        var overdue: [DeskReminder] = []
        var today: [DeskReminder] = []
        var upcoming: [DeskReminder] = []
        var someday: [DeskReminder] = []
        for r in model.reminders {
            if r.id.hasPrefix("local-") {
                today.append(r)
            } else if let d = r.dueAt {
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
        // Optimistic rows sit at the array head (inserted at 0), so the
        // stable partition already leaves them at the top of Today.
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
                            overdue: section == .overdue
                        ) {
                            model.toggle(r)
                        }
                        // A just-added row glows briefly so the optimistic
                        // insert is unmissable; everyone else keeps the card.
                        .listRowBackground(r.id == model.highlightId
                            ? DeskUI.blue.opacity(0.25) : DeskUI.card)
                        .listRowSeparatorTint(DeskUI.separator)
                        // Separator starts at the leading TEXT edge, past
                        // the 32pt checkbox frame + 12pt gap (Reminders style).
                        .alignmentGuide(.listRowSeparatorLeading) { d in
                            d[.leading] + 44
                        }
                    }
                    // Drag-to-reorder within the section: local order flips
                    // instantly; reminder_reorder lands in the background.
                    .onMove { source, destination in
                        model.move(in: section, rows: rows,
                                   from: source, to: destination)
                    }
                } header: {
                    // Reminders-style bold colored section title, not a chip.
                    Text(section.title)
                        .font(.system(size: 20, weight: .bold))
                        .textCase(nil)
                        .foregroundStyle(section.headerColor)
                }
            }
            // (No permanent "Synced with Apple Reminders" footer — the header's
            // "updated Xm ago" stamp already conveys freshness.)
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(18)
        .scrollContentBackground(.hidden)
        // The Reorder header toggle drives edit mode directly (no
        // EditButton) — iOS 17's List shows the drag handles when active.
        .environment(\.editMode, $remindersEditMode)
        .refreshable { await model.loadReminders() }
    }

    // MARK: quick-add — Reminders' "＋ New Reminder" affordance, pinned
    // above the presence capsule (same add flow and dictation etiquette).

    private var trimmedQuickAdd: String {
        quickAdd.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The pinned add area: the typed quick-add bar (fast one-liners) with a
    /// small dictate button beside it (the full draft window: dictate →
    /// Scarlet polishes → Approve adds the reminder), and — when an add
    /// fails — a small red line right under the bar.
    private var quickAddRow: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                quickAddBar
                dictateReminderButton
            }
            if !model.addErrorText.isEmpty {
                Text(model.addErrorText)
                    .font(.system(size: 12))
                    .foregroundStyle(DeskUI.red)
                    .frame(maxWidth: 360, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
    }

    /// Beside the quick-add bar → the drafting window on the "reminder"
    /// channel, to dictate-and-polish instead of typing a bare line. A sparkles
    /// glyph (not a mic) so it reads as "draft with Scarlet", not inline STT.
    private var dictateReminderButton: some View {
        Button {
            activeSheet = .draft(ChannelDraftSeed(channel: "reminder",
                                                  recipient: "Reminders"))
        } label: {
            Image(systemName: "sparkles")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(DeskUI.blue)
                .frame(width: 44, height: 44)
                .background(Circle().fill(DeskUI.card))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Draft a reminder with Scarlet")
    }

    private var quickAddBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(DeskUI.blue)
            ZStack(alignment: .leading) {
                if quickAdd.isEmpty {
                    // Reminders paints "New Reminder" in the accent blue.
                    Text("New Reminder")
                        .font(.system(size: 17))
                        .foregroundStyle(DeskUI.blue)
                        .allowsHitTesting(false)
                }
                TextField("", text: $quickAdd)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .foregroundStyle(.white)
                    .tint(DeskUI.blue)
                    .submitLabel(.done)
                    .focused($addFocused)
                    .onSubmit { submitQuickAdd() }
            }
            Button {
                submitQuickAdd()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(trimmedQuickAdd.isEmpty
                        ? DeskUI.gray.opacity(0.5) : DeskUI.blue)
            }
            .buttonStyle(.plain)
            .disabled(trimmedQuickAdd.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(DeskUI.card)
        )
        .frame(maxWidth: 360)
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
                    .tint(DeskUI.yellow)
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
                    .foregroundStyle(DeskUI.yellow)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            if !model.errorText.isEmpty {
                errorRow
            }
            Section {
                ForEach(model.notes) { note in
                    Button {
                        open(note)
                    } label: {
                        DeskNoteRow(note: note)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(DeskUI.card)
                    .listRowSeparatorTint(DeskUI.separator)
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(18)
        .scrollContentBackground(.hidden)
        .refreshable { await model.loadNotes() }
    }

    // MARK: shared bits

    private var errorRow: some View {
        Text(model.errorText)
            .font(.footnote)
            .foregroundStyle(DeskUI.red)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
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
                .tint(leafAccent)
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
        activeSheet = .note(note)
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

/// One reminder, Apple Reminders dark style: 22pt circle checkbox (gray
/// ring → filled blue circle with a white check), orange "!" priority
/// prefix, white 17pt title that FADES to gray when done (no strikethrough,
/// like the real app), gray notes line, and a due line that goes red when
/// overdue.
struct DeskReminderRow: View {
    let reminder: DeskReminder
    let overdue: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onToggle) {
                checkbox
                    // A comfortable 44pt-ish target without inflating the row.
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                titleLine
                    .font(.system(size: 17, weight: .regular))
                    .lineLimit(2)
                    .truncationMode(.tail)
                if !reminder.notes.isEmpty {
                    Text(reminder.notes)
                        .font(.system(size: 15))
                        .foregroundStyle(DeskUI.gray)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let due = reminder.dueAt {
                    Text(DeskDates.dueChip(due))
                        .font(.system(size: 15))
                        .foregroundStyle(overdue ? DeskUI.red : DeskUI.gray)
                }
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    /// Empty: 1.5pt gray ring. Done: filled accent circle, white check.
    @ViewBuilder
    private var checkbox: some View {
        ZStack {
            if reminder.done {
                Circle()
                    .fill(DeskUI.blue)
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            } else {
                Circle()
                    .strokeBorder(DeskUI.gray, lineWidth: 1.5)
            }
        }
        .frame(width: 22, height: 22)
    }

    /// Orange "!!!" / "!!" / "!" prefix, then the title — white while open,
    /// faded #8E8E93 once done (Reminders fades, it does not strike).
    private var titleLine: Text {
        let titleColor: Color = reminder.done ? DeskUI.gray : Color.white
        let title = Text(reminder.title).foregroundStyle(titleColor)
        let marks = reminder.priorityMarks
        if marks.isEmpty { return title }
        return Text(marks + " ").foregroundStyle(DeskUI.orange) + title
    }
}

// MARK: - Note row

/// One note, Apple Notes dark style: white semibold title over a gray
/// date line — no doc tile, no chevron.
struct DeskNoteRow: View {
    let note: DeskNote

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(note.title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
            if let stamp = note.modifiedText {
                Text(stamp)
                    .font(.system(size: 15))
                    .foregroundStyle(DeskUI.gray)
            }
        }
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

// MARK: - Note reading sheet

/// The reader: fetches the note body on appearance (`op=note_read` with the
/// title as the query) and shows it Apple-Notes style — black page, bold
/// title as the first line, white 17pt system body. Queued or error from
/// the Mac agent becomes the friendly asleep state.
struct DeskNoteSheet: View {
    let note: DeskNote
    @Environment(\.dismiss) private var dismiss

    @State private var loading = true
    @State private var text = ""
    @State private var shownTitle = ""
    @State private var alsoMatched: [String] = []
    @State private var asleep = false
    @State private var errorText = ""

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
            .background(DeskUI.background.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                        .tint(DeskUI.yellow)
                }
            }
        }
        .task { await load() }
    }

    private var reader: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Notes puts the title as the bold first line of the page.
                Text(shownTitle.isEmpty ? note.title : shownTitle)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                if !alsoMatched.isEmpty {
                    Text("Also matched: " + alsoMatched.joined(separator: ", "))
                        .font(.system(size: 12))
                        .foregroundStyle(DeskUI.gray)
                }
                Text(text)
                    .font(.system(size: 17))
                    .lineSpacing(6)
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
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
            .tint(DeskUI.yellow)
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
