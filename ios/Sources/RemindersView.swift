import Foundation
import SwiftUI
import UIKit

/// Reminders — Ido's real Apple Reminders (two-way synced server-side through
/// the `tasks` table), on their OWN focused page. Split out of the old Desk so
/// Reminders and Notes each stand alone with a clear name. Local-first: the
/// last fetched list is cached to Documents/reminders-cache.json and renders
/// instantly on open while a background refresh brings the truth in.
///
/// Reuses the exact backend ops the Desk used — nothing new was invented:
///   • `reminders_list`   read the open reminders
///   • `reminder_add`     add one (title + optional due_at, synced to Apple)
///   • `reminder_toggle`  complete / undo
///   • `reminder_update`  edit title / notes / priority
///
/// Self-contained (its own palette, model, and request pipe) so it survives the
/// removal of DeskView.swift.

// MARK: - Native dark palette (Apple Reminders design language)

private enum RemUI {
    static let background = Color.black
    static let card = Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255)
    static let separator = Color(red: 56 / 255, green: 56 / 255, blue: 58 / 255)
    static let gray = Color(red: 142 / 255, green: 142 / 255, blue: 147 / 255)
    /// Reminders accent — iOS blue #0A84FF.
    static let blue = Color(red: 10 / 255, green: 132 / 255, blue: 255 / 255)
    static let red = Color(red: 1, green: 69 / 255, blue: 58 / 255)
    static let orange = Color(red: 1, green: 159 / 255, blue: 10 / 255)
}

// MARK: - Wire type

/// One reminder, as `reminders_list` returns it. `done` is mutable for the
/// optimistic checkbox flip.
struct RemItem: Identifiable {
    let id: String
    var title: String
    var notes: String
    let dueAt: Date?
    let remindAt: Date?
    var priority: Int
    var done: Bool
    let updatedAt: Date?

    var isHighPriority: Bool { priority >= 1 && priority <= 3 }

    /// Apple's convention: lower number = higher priority (1 = "!!!", 3 = "!").
    var priorityMarks: String {
        switch priority {
        case 1: return "!!!"
        case 2: return "!!"
        case 3: return "!"
        default: return ""
        }
    }
}

/// The four due buckets of the list.
enum RemSection: String, Hashable {
    case overdue, today, upcoming, someday

    var title: String {
        switch self {
        case .overdue: return "Overdue"
        case .today: return "Today"
        case .upcoming: return "Upcoming"
        case .someday: return "Someday"
        }
    }

    var headerColor: Color {
        switch self {
        case .overdue: return RemUI.red
        case .today, .upcoming: return Color.white
        case .someday: return RemUI.gray
        }
    }
}

// MARK: - Dates

/// File-scope date formatting so any view can format synchronously.
enum RemDates {
    static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .short; return f
    }()
    static let time: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
    static let weekday: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE"; return f
    }()
    static let dayMonth: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d MMM"; return f
    }()

    /// "Today 14:00", "Tomorrow", "Thu 09:30", "12 Sep". A midnight due time
    /// reads as all-day, so the clock part is dropped.
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
final class RemindersModel: ObservableObject {
    @Published var reminders: [RemItem] = []
    @Published var loading = false
    @Published var errorText = ""
    /// Quick-add failures surface right under the add bar, never as an alert.
    @Published var addErrorText = ""
    /// The just-added row's id: briefly tinted so the optimistic insert is
    /// unmissable.
    @Published var highlightId: String?
    @Published var updatedAt: Date?

    private var rawReminders: [[String: Any]] = []
    /// Monotonic load token: a slow fetch landing after a newer one is dropped.
    private var loadGeneration = 0

    init() { loadCache() }

    // MARK: read

    func load() async {
        guard TokenStore.token != nil else {
            errorText = "Locked — unlock Scarlet to see your reminders."
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
            reminders = Self.parse(raw)
            updatedAt = Date()
            errorText = ""
            saveCache()
        } catch {
            guard generation == loadGeneration else { return }
            errorText = "Couldn't reach your reminders — check your connection."
        }
    }

    // MARK: complete / undo

    /// Flip `done` locally right away (and allow flipping straight back — the
    /// row stays put until the next refresh), then tell the server. A failure
    /// reverts the flip.
    func toggle(_ reminder: RemItem) {
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

    // MARK: add

    /// Optimistic insert (at the top of its bucket) with a brief highlight,
    /// then `reminder_add`. On success a silent reload swaps in the server's
    /// row; on failure the row leaves and a small red line says so.
    func add(_ title: String, due: Date? = nil) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        addErrorText = ""
        let localId = "local-" + UUID().uuidString
        let optimistic = RemItem(id: localId, title: t, notes: "",
                                 dueAt: due, remindAt: nil, priority: 0,
                                 done: false, updatedAt: Date())
        withAnimation(.snappy(duration: 0.2)) {
            reminders.insert(optimistic, at: 0)
            highlightId = localId
        }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if self.highlightId == localId {
                withAnimation(.easeOut(duration: 0.6)) { self.highlightId = nil }
            }
        }
        Task {
            do {
                var body: [String: Any] = ["op": "reminder_add", "title": t]
                if let due { body["due_at"] = MailDates.isoPlain.string(from: due) }
                let data = try await Self.request(body)
                let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                guard (obj?["ok"] as? Bool) == true else {
                    let serverError = (obj?["error"] as? String) ?? ""
                    throw RemError.rejected(serverError)
                }
                await self.load()
            } catch {
                withAnimation(.snappy(duration: 0.2)) {
                    self.reminders.removeAll { $0.id == localId }
                    if self.highlightId == localId { self.highlightId = nil }
                }
                if let rejected = error as? RemError,
                   case .rejected(let msg) = rejected, !msg.isEmpty {
                    self.addErrorText = "Couldn't add \"\(t)\" — \(msg)"
                } else {
                    self.addErrorText = "Couldn't add \"\(t)\" — try again."
                }
            }
        }
    }

    // MARK: edit — title / notes / priority via reminder_update

    /// Optimistic edit: apply the new fields locally, then `reminder_update`.
    /// A failure reverts and surfaces a line at the list top.
    func edit(_ id: String, title: String, notes: String, priority: Int) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let idx = reminders.firstIndex(where: { $0.id == id }) else { return }
        let previous = reminders[idx]
        withAnimation(.snappy(duration: 0.2)) {
            reminders[idx].title = t
            reminders[idx].notes = notes
            reminders[idx].priority = priority
        }
        if let ri = rawReminders.firstIndex(where: { ($0["id"] as? String) == id }) {
            rawReminders[ri]["title"] = t
            rawReminders[ri]["notes"] = notes
            rawReminders[ri]["priority"] = priority
            saveCache()
        }
        guard !id.hasPrefix("local-") else { return }
        Task {
            do {
                let data = try await Self.request([
                    "op": "reminder_update",
                    "id": id,
                    "title": t,
                    "notes": notes,
                    "priority": priority,
                ])
                let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                guard (obj?["ok"] as? Bool) == true else {
                    throw URLError(.badServerResponse)
                }
            } catch {
                if let i = self.reminders.firstIndex(where: { $0.id == id }) {
                    self.reminders[i] = previous
                }
                self.errorText = "Couldn't save your edit — try again."
            }
        }
    }

    private enum RemError: Error { case rejected(String) }

    // MARK: parse

    static func parse(_ raw: [[String: Any]]) -> [RemItem] {
        var seen = Set<String>()
        return raw.compactMap { r in
            guard let id = r["id"] as? String, !id.isEmpty else { return nil }
            guard seen.insert(id).inserted else { return nil }
            let title = ((r["title"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return RemItem(
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

    private static func intValue(_ v: Any?) -> Int {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String { return Int(s) ?? 0 }
        return 0
    }

    // MARK: cache — Documents/reminders-cache.json

    static var cacheURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return docs.appendingPathComponent("reminders-cache.json")
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: Self.cacheURL),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }
        rawReminders = (obj["reminders"] as? [[String: Any]]) ?? []
        reminders = Self.parse(rawReminders)
        updatedAt = MailDates.parse(obj["updated"] as? String)
    }

    private func saveCache() {
        var obj: [String: Any] = ["reminders": rawReminders]
        if let d = updatedAt { obj["updated"] = MailDates.isoPlain.string(from: d) }
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj)
        else { return }
        try? data.write(to: Self.cacheURL, options: .atomic)
    }

    // MARK: plumbing — op rides the query string, params ride the JSON body
    // (identical shape to the app-wide DraftView.Self.request pipe).

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

// MARK: - Page

struct RemindersView: View {
    @StateObject private var model = RemindersModel()
    @EnvironmentObject var convo: Conversation

    @State private var quickAdd = ""
    @FocusState private var addFocused: Bool

    /// ONE `.sheet(item:)` driver (Mac Catalyst allows only one sheet per
    /// view): either the add-with-a-date panel or the edit panel.
    enum RemSheet: Identifiable {
        case addWithDate(String)   // carries the pre-typed title
        case edit(RemItem)
        var id: String {
            switch self {
            case .addWithDate: return "add"
            case .edit(let r): return "edit-\(r.id)"
            }
        }
    }
    @State private var activeSheet: RemSheet?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                headerBar
                content
            }
            .background(RemUI.background.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    quickAddRow
                    ScarletPresenceView(convo: convo)
                        .padding(.vertical, 6)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .onAppear { convo.setFocus(browsingFocus) }
            // Her ears close while Ido types into the quick-add row.
            .onChange(of: addFocused) { _, focused in
                if focused { convo.beginTyping() } else { convo.endTyping() }
            }
            .reportsModalPresence(activeSheet != nil)
            .sheet(item: $activeSheet, onDismiss: {
                Task { await model.load() }
            }) { sheet in
                switch sheet {
                case .addWithDate(let title):
                    RemAddSheet(initialTitle: title) { t, due in
                        model.add(t, due: due)
                    }
                    .preferredColorScheme(.dark)
                case .edit(let reminder):
                    RemEditSheet(reminder: reminder) { title, notes, priority in
                        model.edit(reminder.id, title: title,
                                   notes: notes, priority: priority)
                    }
                    .preferredColorScheme(.dark)
                }
            }
        }
        .task { await model.load() }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.willEnterForegroundNotification)) { _ in
            Task { await model.load() }
        }
    }

    // MARK: header

    private var headerBar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 12) {
                Text("Reminders")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Button { Task { await model.load() } } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(RemUI.blue)
                }
                .disabled(model.loading)
            }
            if let stamp = model.updatedAt {
                Text(RemDates.updatedStamp(stamp))
                    .font(.system(size: 12))
                    .foregroundStyle(RemUI.gray)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    // MARK: content

    @ViewBuilder
    private var content: some View {
        if model.loading && model.reminders.isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                Text("Fetching your reminders…")
                    .font(.system(size: 15)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.reminders.isEmpty && !model.errorText.isEmpty {
            retryState(model.errorText)
        } else if model.reminders.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "checklist")
                    .font(.title2).foregroundStyle(.secondary)
                Text("Nothing on the list — add one below, or ask Scarlet.")
                    .font(.system(size: 17)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            list
        }
    }

    /// Overdue / Today / Upcoming / Someday — a STABLE partition of the flat
    /// list (the server already orders it), empty buckets skipped. A just-added
    /// optimistic row (local- id, no due) shows at the top of Today.
    private var grouped: [(RemSection, [RemItem])] {
        let now = Date()
        let cal = Calendar.current
        var overdue: [RemItem] = []
        var today: [RemItem] = []
        var upcoming: [RemItem] = []
        var someday: [RemItem] = []
        for r in model.reminders {
            if r.id.hasPrefix("local-") && r.dueAt == nil {
                today.append(r)
            } else if let d = r.dueAt {
                if d < now { overdue.append(r) }
                else if cal.isDateInToday(d) { today.append(r) }
                else { upcoming.append(r) }
            } else {
                someday.append(r)
            }
        }
        let all: [(RemSection, [RemItem])] = [
            (.overdue, overdue), (.today, today),
            (.upcoming, upcoming), (.someday, someday),
        ]
        return all.filter { !$0.1.isEmpty }
    }

    private var list: some View {
        List {
            if !model.errorText.isEmpty { errorRow }
            ForEach(grouped, id: \.0) { section, rows in
                Section {
                    ForEach(rows) { r in
                        RemRow(reminder: r, overdue: section == .overdue) {
                            model.toggle(r)
                        }
                        .contentShape(Rectangle())
                        // A tap on the body (not the checkbox) opens the editor.
                        .onTapGesture { activeSheet = .edit(r) }
                        .listRowBackground(r.id == model.highlightId
                            ? RemUI.blue.opacity(0.25) : RemUI.card)
                        .listRowSeparatorTint(RemUI.separator)
                        .alignmentGuide(.listRowSeparatorLeading) { d in
                            d[.leading] + 44
                        }
                    }
                } header: {
                    Text(section.title)
                        .font(.system(size: 22, weight: .bold))
                        .textCase(nil)
                        .foregroundStyle(section.headerColor)
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(18)
        .scrollContentBackground(.hidden)
        .refreshable { await model.load() }
    }

    // MARK: quick-add

    private var trimmedQuickAdd: String {
        quickAdd.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The typed quick-add bar (fast one-liners) with a small calendar button
    /// that opens the add-with-a-date panel; an add failure shows a small red
    /// line right under the bar.
    private var quickAddRow: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                quickAddBar
                dateAddButton
            }
            if !model.addErrorText.isEmpty {
                Text(model.addErrorText)
                    .font(.system(size: 13))
                    .foregroundStyle(RemUI.red)
                    .frame(maxWidth: 360, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
    }

    /// Opens the add-with-a-date panel, carrying whatever is already typed.
    private var dateAddButton: some View {
        Button {
            activeSheet = .addWithDate(trimmedQuickAdd)
        } label: {
            Image(systemName: "calendar.badge.plus")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(RemUI.blue)
                .frame(width: 44, height: 44)
                .background(Circle().fill(RemUI.card))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add a reminder with a date")
    }

    private var quickAddBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(RemUI.blue)
            ZStack(alignment: .leading) {
                if quickAdd.isEmpty {
                    Text("New Reminder")
                        .font(.system(size: 18))
                        .foregroundStyle(RemUI.blue)
                        .allowsHitTesting(false)
                }
                TextField("", text: $quickAdd)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18))
                    .foregroundStyle(.white)
                    .tint(RemUI.blue)
                    .submitLabel(.done)
                    .focused($addFocused)
                    .onSubmit { submitQuickAdd() }
            }
            // Embedded dictation: tap and speak the reminder — no keyboard.
            DictationMicButton(onText: { words in
                quickAdd = DictationField.merge(existing: quickAdd, adding: words)
            }, tint: RemUI.blue, size: 32)
            Button { submitQuickAdd() } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(trimmedQuickAdd.isEmpty
                        ? RemUI.gray.opacity(0.5) : RemUI.blue)
            }
            .buttonStyle(.plain)
            .disabled(trimmedQuickAdd.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(RemUI.card)
        )
        .frame(maxWidth: 360)
    }

    private func submitQuickAdd() {
        let t = trimmedQuickAdd
        guard !t.isEmpty else { return }
        model.add(t)
        quickAdd = ""
    }

    // MARK: shared bits

    private var errorRow: some View {
        Text(model.errorText)
            .font(.system(size: 14))
            .foregroundStyle(RemUI.red)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    private func retryState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.title2).foregroundStyle(.secondary)
            Text(message)
                .font(.system(size: 17)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try again") { Task { await model.load() } }
                .buttonStyle(.bordered)
                .tint(RemUI.blue)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Scarlet focus

    private var browsingFocus: String {
        "[FOCUS] Ido is on his Reminders page — his real Apple Reminders, "
            + "two-way synced (list_reminders/create_reminder/manage_reminder tools). "
            + "He can add, complete, and edit them here."
    }
}

// MARK: - Reminder row

/// One reminder, Apple Reminders dark style: 22pt circle checkbox, orange "!"
/// priority prefix, white 18pt title that FADES to gray when done (no
/// strikethrough, like the real app), gray notes line, red due line when
/// overdue.
struct RemRow: View {
    let reminder: RemItem
    let overdue: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onToggle) {
                checkbox
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 3) {
                titleLine
                    .font(.system(size: 18, weight: .regular))
                    .lineLimit(2)
                    .truncationMode(.tail)
                if !reminder.notes.isEmpty {
                    Text(reminder.notes)
                        .font(.system(size: 15))
                        .foregroundStyle(RemUI.gray)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let due = reminder.dueAt {
                    Text(RemDates.dueChip(due))
                        .font(.system(size: 15))
                        .foregroundStyle(overdue ? RemUI.red : RemUI.gray)
                }
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var checkbox: some View {
        ZStack {
            if reminder.done {
                Circle().fill(RemUI.blue)
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            } else {
                Circle().strokeBorder(RemUI.gray, lineWidth: 1.5)
            }
        }
        .frame(width: 22, height: 22)
    }

    private var titleLine: Text {
        let titleColor: Color = reminder.done ? RemUI.gray : Color.white
        let title = Text(reminder.title).foregroundStyle(titleColor)
        let marks = reminder.priorityMarks
        if marks.isEmpty { return title }
        return Text(marks + " ").foregroundStyle(RemUI.orange) + title
    }
}

// MARK: - Add-with-a-date sheet

/// Self-contained (no @EnvironmentObject) add panel: a title field plus a
/// date/time picker, so the one case that needs a date has an obvious home.
/// The plain quick-add bar covers the common no-date case in a single tap.
struct RemAddSheet: View {
    let initialTitle: String
    /// (title, due) — due is nil when Ido leaves the date off.
    let onAdd: (String, Date?) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var includeDate = true
    @State private var due = Calendar.current.date(
        bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    @FocusState private var titleFocused: Bool

    init(initialTitle: String, onAdd: @escaping (String, Date?) -> Void) {
        self.initialTitle = initialTitle
        self.onAdd = onAdd
        _title = State(initialValue: initialTitle)
    }

    private var trimmed: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Reminder", text: $title, axis: .vertical)
                        .font(.system(size: 18))
                        .focused($titleFocused)
                }
                Section {
                    Toggle(isOn: $includeDate) {
                        Label("Date & time", systemImage: "calendar")
                            .font(.system(size: 17))
                    }
                    .tint(RemUI.blue)
                    if includeDate {
                        DatePicker("When", selection: $due,
                                   displayedComponents: [.date, .hourAndMinute])
                            .font(.system(size: 17))
                            .tint(RemUI.blue)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(RemUI.background.ignoresSafeArea())
            .navigationTitle("New Reminder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .tint(RemUI.blue)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onAdd(trimmed, includeDate ? due : nil)
                        dismiss()
                    }
                    .font(.system(size: 17, weight: .semibold))
                    .tint(RemUI.blue)
                    .disabled(trimmed.isEmpty)
                }
            }
            .onAppear { if trimmed.isEmpty { titleFocused = true } }
        }
    }
}

// MARK: - Edit sheet

/// Self-contained (no @EnvironmentObject) editor for an existing reminder:
/// title, notes, and priority — the three fields `reminder_update` accepts.
struct RemEditSheet: View {
    let reminder: RemItem
    /// (title, notes, priority) — Apple scale: 0 none, 1 high, 5 medium, 9 low.
    let onSave: (String, String, Int) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var notes: String
    @State private var priority: Int
    @FocusState private var titleFocused: Bool

    init(reminder: RemItem, onSave: @escaping (String, String, Int) -> Void) {
        self.reminder = reminder
        self.onSave = onSave
        _title = State(initialValue: reminder.title)
        _notes = State(initialValue: reminder.notes)
        _priority = State(initialValue: reminder.priority)
    }

    private var trimmed: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Map the Apple priority scale to a 0…3 picker index and back.
    private var priorityIndex: Int {
        switch priority {
        case 1...3: return 3   // High
        case 4...6: return 2   // Medium
        case 7...: return 1    // Low
        default: return 0      // None
        }
    }

    private func priorityValue(for index: Int) -> Int {
        switch index {
        case 3: return 1
        case 2: return 5
        case 1: return 9
        default: return 0
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title, axis: .vertical)
                        .font(.system(size: 18))
                        .focused($titleFocused)
                }
                Section("Notes") {
                    TextField("Notes", text: $notes, axis: .vertical)
                        .font(.system(size: 17))
                        .lineLimit(3...8)
                }
                Section("Priority") {
                    Picker("Priority", selection: Binding(
                        get: { priorityIndex },
                        set: { priority = priorityValue(for: $0) }
                    )) {
                        Text("None").tag(0)
                        Text("!").tag(1)
                        Text("!!").tag(2)
                        Text("!!!").tag(3)
                    }
                    .pickerStyle(.segmented)
                }
            }
            .scrollContentBackground(.hidden)
            .background(RemUI.background.ignoresSafeArea())
            .navigationTitle("Edit Reminder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .tint(RemUI.blue)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(trimmed, notes, priority)
                        dismiss()
                    }
                    .font(.system(size: 17, weight: .semibold))
                    .tint(RemUI.blue)
                    .disabled(trimmed.isEmpty)
                }
            }
        }
    }
}
