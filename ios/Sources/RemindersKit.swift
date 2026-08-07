import Foundation
import EventKit

/// One Apple Reminder as read straight off this device via EventKit.
/// `id` is the EventKit `calendarItemIdentifier` — stable per device, and the
/// external key (`ext_id`) the server sync op matches on.
struct LocalReminder: Identifiable {
    let id: String
    let title: String
    let notes: String
    let dueAt: Date?
    /// Apple scale: 0 none, 1–4 high, 5 medium, 6–9 low.
    let priority: Int
    /// The Reminders list ("calendar") the item lives in.
    let listName: String
}

/// The "embedded Reminders server": direct on-device access to Apple
/// Reminders via EventKit. iPhone / iPad / Mac Catalyst all read the SAME
/// local store the Reminders app uses, so the list is live — no Mac-bridge
/// hop, no staleness. Mutations write back through the store immediately.
///
/// Errors are RETURNED as user-readable strings (nil = success), never
/// thrown — callers surface them in their existing error lines.
@MainActor
final class RemindersKit: ObservableObject {
    static let shared = RemindersKit()

    /// True once Ido has granted (full) Reminders access.
    @Published var authorized: Bool = false
    /// Ido explicitly denied / OS-restricted access — callers should fall
    /// back to the server path and never re-prompt.
    @Published var denied: Bool = false

    private let store = EKEventStore()

    private init() {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if #available(iOS 17.0, *) {
            switch status {
            case .fullAccess:
                authorized = true
            case .denied, .restricted, .writeOnly:
                denied = true
            default:
                break
            }
        } else {
            switch status {
            case .authorized:
                authorized = true
            case .denied, .restricted:
                denied = true
            default:
                break
            }
        }
    }

    // MARK: access

    /// Ask for Reminders access (full access on iOS 17+, legacy otherwise).
    /// Publishes the result on `authorized` / `denied`.
    func requestAccess() async {
        let granted: Bool
        if #available(iOS 17.0, *) {
            granted = (try? await store.requestFullAccessToReminders()) ?? false
        } else {
            granted = await withCheckedContinuation { cont in
                store.requestAccess(to: .reminder) { ok, _ in
                    cont.resume(returning: ok)
                }
            }
        }
        authorized = granted
        denied = !granted
    }

    // MARK: read

    /// All incomplete reminders across every Reminders list, sorted by due
    /// date (undated last) then title.
    func fetchOpen() async -> [LocalReminder] {
        guard authorized else { return [] }
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: nil, calendars: nil)
        let found: [EKReminder] = await withCheckedContinuation { cont in
            store.fetchReminders(matching: predicate) { reminders in
                cont.resume(returning: reminders ?? [])
            }
        }
        let mapped = found.map { r -> LocalReminder in
            let title = (r.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return LocalReminder(
                id: r.calendarItemIdentifier,
                title: title.isEmpty ? "Untitled" : title,
                notes: r.notes ?? "",
                dueAt: r.dueDateComponents.flatMap { Calendar.current.date(from: $0) },
                priority: r.priority,
                listName: r.calendar?.title ?? ""
            )
        }
        return mapped.sorted { a, b in
            switch (a.dueAt, b.dueAt) {
            case let (da?, db?):
                if da != db { return da < db }
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                break
            }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }

    // MARK: write

    /// Complete (or un-complete) one reminder. Returns an error line, or nil.
    @discardableResult
    func complete(id: String, done: Bool = true) -> String? {
        guard let item = store.calendarItem(withIdentifier: id) as? EKReminder else {
            return "Reminder not found on this device."
        }
        item.isCompleted = done
        do {
            try store.save(item, commit: true)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Create a reminder in the default Reminders list. Returns an error
    /// line, or nil on success.
    @discardableResult
    func create(title: String, notes: String? = nil, dueAt: Date? = nil) -> String? {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "Empty title." }
        guard let list = store.defaultCalendarForNewReminders()
            ?? store.calendars(for: .reminder).first else {
            return "No Reminders list is available on this device."
        }
        let r = EKReminder(eventStore: store)
        r.title = t
        if let notes, !notes.isEmpty { r.notes = notes }
        if let dueAt {
            r.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: dueAt)
        }
        r.calendar = list
        do {
            try store.save(r, commit: true)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Edit title / notes / due / priority. `dueAt` and `priority` nil mean
    /// "leave unchanged" (the edit sheet doesn't touch dates). Returns an
    /// error line, or nil on success.
    @discardableResult
    func update(id: String, title: String, notes: String,
                dueAt: Date? = nil, priority: Int? = nil) -> String? {
        guard let item = store.calendarItem(withIdentifier: id) as? EKReminder else {
            return "Reminder not found on this device."
        }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { item.title = t }
        item.notes = notes.isEmpty ? nil : notes
        if let dueAt {
            item.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: dueAt)
        }
        if let priority { item.priority = priority }
        do {
            try store.save(item, commit: true)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
