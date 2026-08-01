import SwiftUI
import UIKit

/// Native calendar: Ido's Amwell (Outlook) calendar with Outlook mobile's
/// anatomy on the app's dark Scarlet look — big header, week strip with
/// today/selection circles and event dots, an agenda grouped by day, and a
/// detail sheet with Join / RSVP / attendees / Ask Scarlet / Delete.

// MARK: - Ambient focus

/// The agenda-level focus line, shared by the list's own appearance and the
/// detail sheet's dismissal so both report the exact same thing.
private let calendarAgendaFocus = "[FOCUS] Ido is viewing his Amwell calendar (agenda)."

/// Start of the week containing `date`, per the current calendar.
private func calStartOfWeek(_ date: Date) -> Date {
    let cal = Calendar.current
    return cal.dateInterval(of: .weekOfYear, for: date)?.start ?? cal.startOfDay(for: date)
}

// MARK: - Wire types

/// One event row, as `op=cal_range` returns it.
struct CalEvent: Identifiable {
    let id: String
    let subject: String
    let start: Date
    let end: Date
    let allDay: Bool
    let location: String
    let organizer: String
    /// Teams meeting URL, when the event has one.
    let join: String?
    /// Ido's own RSVP: none|organizer|accepted|tentativelyAccepted|declined|notResponded.
    var response: String
    /// busy|tentative|oof|free — drives the row's accent bar.
    let showAs: String

    /// "Friday, Aug 1 · 9:00 – 9:30" (or "· All day"). Built purely from
    /// list-row data so the detail sheet's focus string is byte-identical on
    /// appear and disappear.
    var whenLine: String {
        let day = CalDates.detailDay.string(from: start)
        if allDay { return "\(day) · All day" }
        return "\(day) · \(CalDates.time.string(from: start)) – \(CalDates.time.string(from: end))"
    }
}

/// One attendee, as `op=cal_event` returns it.
struct CalAttendee: Identifiable {
    let id = UUID()
    let name: String
    let email: String
    let response: String
    let required: Bool
}

/// Full event detail, as `op=cal_event` returns it (adds what the range
/// listing doesn't carry).
struct CalEventDetail {
    let organizer: String
    let organizerEmail: String
    let isOrganizer: Bool
    let myResponse: String
    let attendees: [CalAttendee]
    let preview: String
}

// MARK: - Date plumbing

/// Formatters, static so they're built once. The server sends local
/// Israel-time strings like "2026-08-01T09:00:00.0000000" — the first 19
/// characters parse with a fixed pattern in the device's current zone.
enum CalDates {
    static let parseFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.timeZone = .current
        return f
    }()
    /// "2026-08-01" — query-string dates, day grouping keys, strip dots.
    static let dayKey: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()
    /// "9:00"
    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "H:mm"
        return f
    }()
    /// "August 2026"
    static let monthTitle: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f
    }()
    /// "Friday, August 1"
    static let dayHeader: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d"
        return f
    }()
    /// "Friday, Aug 1"
    static let detailDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMM d"
        return f
    }()
    /// "F" — single-letter weekday for the strip.
    static let weekdayLetter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEEE"
        return f
    }()

    static func parse(_ s: String?) -> Date? {
        guard let s, s.count >= 19 else { return nil }
        return parseFormat.date(from: String(s.prefix(19)))
    }
}

// MARK: - Palette

/// Outlook mobile's calendar colors on dark.
enum CalStyle {
    static let busyBlue = Color(red: 0.0, green: 0.47, blue: 0.83)
    static let oofPurple = Color(red: 0.53, green: 0.34, blue: 0.65)
    static let freeGreen = Color(red: 0.06, green: 0.5, blue: 0.24)
    static let acceptGreen = Color(red: 0.16, green: 0.55, blue: 0.32)
    static let declineRed = Color(red: 0.91, green: 0.28, blue: 0.34)
    static let rose = Color(red: 1, green: 0.35, blue: 0.42)

    /// Row accent bar by Outlook's show-as state.
    static func bar(for showAs: String) -> Color {
        switch showAs {
        case "tentative": return busyBlue.opacity(0.45)
        case "oof": return oofPurple
        case "free": return freeGreen
        default: return busyBlue
        }
    }
}

// MARK: - Model

@MainActor
final class CalendarModel: ObservableObject {

    /// One agenda day: its events, keyed by "yyyy-MM-dd" for scroll anchors.
    struct Day: Identifiable {
        let id: String
        let date: Date
        var events: [CalEvent]
    }

    @Published var days: [Day] = []
    @Published var loading = false
    @Published var errorText = ""
    /// Days that have at least one event — the month strip's presence dots.
    @Published var eventDayKeys: Set<String> = []

    /// One load at a time; pull-to-refresh during a `.task` load is a no-op.
    private var inFlight = false

    /// One `cal_range` call: 7 days back through 21 days forward (≤42 days).
    func load() async {
        guard !inFlight else { return }
        guard TokenStore.token != nil else {
            days = []
            errorText = "Locked — unlock Scarlet to see the calendar."
            return
        }
        inFlight = true
        if days.isEmpty { loading = true }
        errorText = ""
        defer {
            inFlight = false
            loading = false
        }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let rangeStart = cal.date(byAdding: .day, value: -7, to: today),
              let rangeEnd = cal.date(byAdding: .day, value: 21, to: today) else { return }
        let query = "op=cal_range"
            + "&start=\(CalDates.dayKey.string(from: rangeStart))"
            + "&end=\(CalDates.dayKey.string(from: rangeEnd))"
        do {
            let data = try await Self.request(query, method: "GET")
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let events: [CalEvent] = ((obj["events"] as? [[String: Any]]) ?? []).compactMap { e in
                guard let id = e["id"] as? String,
                      let start = CalDates.parse(e["start"] as? String),
                      let end = CalDates.parse(e["end"] as? String) else { return nil }
                let subject = (e["subject"] as? String) ?? ""
                return CalEvent(
                    id: id,
                    subject: subject.isEmpty ? "(no title)" : subject,
                    start: start,
                    end: end,
                    allDay: (e["all_day"] as? Bool) ?? false,
                    location: (e["location"] as? String) ?? "",
                    organizer: (e["organizer"] as? String) ?? "",
                    join: (e["join"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                    response: (e["response"] as? String) ?? "none",
                    showAs: (e["show_as"] as? String) ?? "busy"
                )
            }
            rebuild(events)
        } catch {
            errorText = "Couldn't reach the calendar — check your connection."
        }
    }

    /// Group by local start day. Empty days are skipped except today and
    /// tomorrow, which always appear (they carry the "No events" rows).
    private func rebuild(_ events: [CalEvent]) {
        let cal = Calendar.current
        var byDay: [String: [CalEvent]] = [:]
        for e in events {
            byDay[CalDates.dayKey.string(from: e.start), default: []].append(e)
        }
        eventDayKeys = Set(byDay.keys)
        let today = cal.startOfDay(for: Date())
        var anchors = [today]
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: today) {
            anchors.append(tomorrow)
        }
        for d in anchors {
            let key = CalDates.dayKey.string(from: d)
            if byDay[key] == nil { byDay[key] = [] }
        }
        // "yyyy-MM-dd" keys sort correctly as strings.
        days = byDay.keys.sorted().compactMap { key in
            guard let date = CalDates.dayKey.date(from: key) else { return nil }
            let sorted = (byDay[key] ?? []).sorted {
                if $0.allDay != $1.allDay { return $0.allDay }
                return $0.start < $1.start
            }
            return Day(id: key, date: date, events: sorted)
        }
    }

    /// Full detail for the sheet. Graph ids carry `+ / =` and friends, so
    /// the id is percent-encoded down to alphanumerics first.
    func detail(id: String) async throws -> CalEventDetail {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
        let data = try await Self.request("op=cal_event&id=\(encoded)", method: "GET")
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let attendees: [CalAttendee] = ((obj["attendees"] as? [[String: Any]]) ?? []).map { a in
            CalAttendee(
                name: (a["name"] as? String) ?? "",
                email: (a["email"] as? String) ?? "",
                response: (a["response"] as? String) ?? "none",
                required: (a["required"] as? Bool) ?? true
            )
        }
        return CalEventDetail(
            organizer: (obj["organizer"] as? String) ?? "",
            organizerEmail: (obj["organizer_email"] as? String) ?? "",
            isOrganizer: (obj["is_organizer"] as? Bool) ?? false,
            myResponse: (obj["my_response"] as? String) ?? "none",
            attendees: attendees,
            preview: (obj["preview"] as? String) ?? ""
        )
    }

    /// The RSVP state a successful action lands on.
    static func response(for action: String) -> String {
        switch action {
        case "accept": return "accepted"
        case "tentativelyAccept": return "tentativelyAccepted"
        case "decline": return "declined"
        default: return action
        }
    }

    /// RSVP: POST, then mirror the new state into the agenda rows.
    func respond(id: String, action: String) async -> Bool {
        do {
            let data = try await Self.request("op=cal_respond", method: "POST",
                                              body: ["id": id, "action": action])
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard (obj?["ok"] as? Bool) == true else { return false }
            let newResponse = Self.response(for: action)
            for di in days.indices {
                for ei in days[di].events.indices where days[di].events[ei].id == id {
                    days[di].events[ei].response = newResponse
                }
            }
            return true
        } catch {
            return false
        }
    }

    /// Delete: POST, drop the row locally, then refresh in the background.
    func delete(id: String) async -> Bool {
        do {
            let data = try await Self.request("op=cal_delete", method: "POST",
                                              body: ["id": id])
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard (obj?["ok"] as? Bool) == true else { return false }
            let cal = Calendar.current
            for di in days.indices {
                days[di].events.removeAll { $0.id == id }
            }
            days.removeAll { day in
                day.events.isEmpty
                    && !cal.isDateInToday(day.date)
                    && !cal.isDateInTomorrow(day.date)
            }
            eventDayKeys = Set(days.filter { !$0.events.isEmpty }.map { $0.id })
            Task { await self.load() }
            return true
        } catch {
            return false
        }
    }

    // MARK: plumbing (same shape as DraftModel: apiBase + x-scarlet-token)

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

// MARK: - Calendar page

struct CalendarView: View {
    @StateObject private var model = CalendarModel()
    @EnvironmentObject private var convo: Conversation

    @State private var selectedDay = Calendar.current.startOfDay(for: Date())
    @State private var weekAnchor = calStartOfWeek(Date())
    @State private var sheetEvent: CalEvent?

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                headerBar(proxy)
                monthStrip(proxy)
                content
            }
            .background(ScarletBackground().ignoresSafeArea())
        }
        // .task re-runs on tab select; foreground return refreshes too.
        .task { await model.load() }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.willEnterForegroundNotification)) { _ in
            Task { await model.load() }
        }
        // Ambient focus: the agenda reports itself whenever it's on screen.
        .onAppear { convo.setFocus(calendarAgendaFocus) }
        .sheet(item: $sheetEvent) { event in
            CalEventDetailView(event: event, model: model)
                .preferredColorScheme(.dark)
        }
    }

    // MARK: header (avatar · big Calendar title · Today jump)

    private func headerBar(_ proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 12) {
            // Account avatar — visual anchor only on this screen.
            ZStack {
                Circle().fill(Color(white: 0.30))
                Text("IS")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 38, height: 38)
            Text("Calendar")
                .font(.system(size: 34, weight: .heavy))
                .foregroundStyle(.white)
            Spacer()
            Button {
                goToToday(proxy)
            } label: {
                Image(systemName: "calendar.circle")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private func goToToday(_ proxy: ScrollViewProxy) {
        let today = Calendar.current.startOfDay(for: Date())
        selectedDay = today
        weekAnchor = calStartOfWeek(today)
        scrollToDay(today, proxy: proxy)
    }

    /// Jump the agenda to a day's anchor — or the nearest following loaded
    /// day (empty past/future days have no row), else the last one.
    private func scrollToDay(_ date: Date, proxy: ScrollViewProxy) {
        let key = CalDates.dayKey.string(from: date)
        let target = model.days.first(where: { $0.id >= key })?.id ?? model.days.last?.id
        if let target {
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(target, anchor: .top)
            }
        }
    }

    // MARK: month strip (Outlook's week row)

    private var weekDays: [Date] {
        (0..<7).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: weekAnchor) }
    }

    private var monthTitle: String {
        let ref = weekDays.count > 3 ? weekDays[3] : weekAnchor
        return CalDates.monthTitle.string(from: ref)
    }

    private func monthStrip(_ proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(monthTitle)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
            HStack(spacing: 2) {
                weekChevron("chevron.left", byDays: -7)
                ForEach(weekDays, id: \.self) { day in
                    dayCell(day, proxy: proxy)
                }
                weekChevron("chevron.right", byDays: 7)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func weekChevron(_ icon: String, byDays: Int) -> some View {
        Button {
            if let moved = Calendar.current.date(byAdding: .day, value: byDays, to: weekAnchor) {
                weekAnchor = moved
            }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 22, height: 44)
        }
        .buttonStyle(.plain)
    }

    /// One strip day: weekday letter, number in a circle (today filled blue,
    /// selected ringed), event-presence dot underneath.
    private func dayCell(_ day: Date, proxy: ScrollViewProxy) -> some View {
        let cal = Calendar.current
        let isToday = cal.isDateInToday(day)
        let isSelected = cal.isDate(day, inSameDayAs: selectedDay)
        let hasEvents = model.eventDayKeys.contains(CalDates.dayKey.string(from: day))
        return Button {
            selectedDay = cal.startOfDay(for: day)
            scrollToDay(day, proxy: proxy)
        } label: {
            VStack(spacing: 3) {
                Text(CalDates.weekdayLetter.string(from: day))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                ZStack {
                    if isToday {
                        Circle().fill(CalStyle.busyBlue)
                    } else if isSelected {
                        Circle().stroke(CalStyle.busyBlue, lineWidth: 1.5)
                    }
                    Text("\(cal.component(.day, from: day))")
                        .font(.system(size: 15, weight: isToday ? .bold : .regular))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                }
                .frame(width: 32, height: 32)
                Circle()
                    .fill(Color.white.opacity(hasEvents ? 0.55 : 0))
                    .frame(width: 4, height: 4)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    // MARK: agenda

    @ViewBuilder
    private var content: some View {
        if model.loading && model.days.isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                Text("Checking the calendar…").font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.days.isEmpty && !model.errorText.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.title2).foregroundStyle(.secondary)
                Text(model.errorText)
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try again") { Task { await model.load() } }
                    .buttonStyle(.bordered)
                    .tint(CalStyle.rose)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            agendaList
        }
    }

    private var agendaList: some View {
        List {
            if !model.errorText.isEmpty {
                Text(model.errorText)
                    .font(.footnote)
                    .foregroundStyle(Color(red: 0.91, green: 0.69, blue: 0.31))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            ForEach(model.days) { day in
                dayHeader(day)
                if day.events.isEmpty {
                    noEventsRow
                }
                ForEach(day.events) { event in
                    CalEventRow(event: event) { sheetEvent = event }
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(.white.opacity(0.12))
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { await model.load() }
    }

    /// "Today · Friday, August 1" / "Tomorrow · …" / "Friday, August 1".
    /// The row carries the day's scroll anchor id.
    private func dayHeader(_ day: CalendarModel.Day) -> some View {
        Text(dayTitle(day.date))
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 14)
            .padding(.bottom, 2)
            .id(day.id)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    private func dayTitle(_ date: Date) -> String {
        let cal = Calendar.current
        let name = CalDates.dayHeader.string(from: date)
        if cal.isDateInToday(date) { return "Today · " + name }
        if cal.isDateInTomorrow(date) { return "Tomorrow · " + name }
        return name
    }

    private var noEventsRow: some View {
        Text("No events")
            .font(.system(size: 14))
            .foregroundStyle(.white.opacity(0.35))
            .padding(.leading, 10)
            .padding(.vertical, 4)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

// MARK: - Agenda row

/// Outlook mobile's event row: show-as accent bar, start-over-end time
/// column, subject (struck through when declined), location, and a Join
/// capsule for today's Teams meetings.
struct CalEventRow: View {
    let event: CalEvent
    let onOpen: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(CalStyle.bar(for: event.showAs))
                .frame(width: 4)
                .frame(maxHeight: .infinity)
            timeColumn
            VStack(alignment: .leading, spacing: 2) {
                Text(event.subject)
                    .font(.system(size: 16, weight: .semibold))
                    .strikethrough(event.response == "declined")
                    .foregroundStyle(event.response == "declined"
                        ? Color.white.opacity(0.5) : Color.white)
                    .lineLimit(2)
                    .truncationMode(.tail)
                if !event.location.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.system(size: 11))
                        Text(event.location)
                            .font(.system(size: 13))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if let joinURL, Calendar.current.isDateInToday(event.start) {
                Button {
                    UIApplication.shared.open(joinURL, options: [:], completionHandler: nil)
                } label: {
                    Text("Join")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(CalStyle.busyBlue, in: Capsule())
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { onOpen() }
    }

    private var joinURL: URL? {
        guard let join = event.join else { return nil }
        return URL(string: join)
    }

    private var timeColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            if event.allDay {
                Text("All day")
                    .foregroundStyle(.white.opacity(0.85))
            } else {
                Text(CalDates.time.string(from: event.start))
                    .foregroundStyle(.white.opacity(0.9))
                Text(CalDates.time.string(from: event.end))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 13).monospacedDigit())
        .frame(width: 48, alignment: .leading)
    }
}

// MARK: - Event detail sheet

struct CalEventDetailView: View {
    let event: CalEvent
    @ObservedObject var model: CalendarModel
    @EnvironmentObject private var convo: Conversation
    @Environment(\.dismiss) private var dismiss

    @State private var detail: CalEventDetail?
    @State private var failed = false
    @State private var myResponse: String
    @State private var actionError = ""
    @State private var showAttendees = false
    @State private var confirmDelete = false
    @State private var deleting = false

    init(event: CalEvent, model: CalendarModel) {
        self.event = event
        _model = ObservedObject(wrappedValue: model)
        _myResponse = State(initialValue: event.response)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(event.subject)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Color(red: 0.98, green: 0.92, blue: 0.92))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    infoBlock
                    joinButton
                    rsvpSection
                    attendeesSection
                    previewSection
                }
                .padding(20)
            }
            Divider().overlay(.white.opacity(0.15))
            footer
        }
        .background(ScarletBackground().ignoresSafeArea())
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task { await fetch() }
        // Ambient focus: this event while the sheet is up; back to the agenda
        // on the way out — unless another screen already claimed focus.
        .onAppear { convo.setFocus(eventFocus) }
        .onDisappear {
            if convo.currentFocus == eventFocus {
                convo.setFocus(calendarAgendaFocus)
            }
        }
        .confirmationDialog("Delete this event?", isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button("Delete event", role: .destructive) { performDelete() }
            Button("Cancel", role: .cancel) {}
        }
    }

    @MainActor
    private func fetch() async {
        do {
            let d = try await model.detail(id: event.id)
            detail = d
            // Adopt the server's RSVP unless Ido already tapped a button.
            if myResponse == event.response { myResponse = d.myResponse }
        } catch {
            failed = true
        }
    }

    // MARK: when / where / who

    private var infoBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            infoRow("clock", event.whenLine)
            if !event.location.isEmpty {
                infoRow("mappin.and.ellipse", event.location)
            }
            if !organizerLine.isEmpty {
                infoRow("person.crop.circle", organizerLine)
            }
            if failed {
                Text("Couldn't load full details.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if detail == nil {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("Loading details…").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var organizerLine: String {
        if let d = detail, !d.organizer.isEmpty {
            if !d.organizerEmail.isEmpty && d.organizerEmail != d.organizer {
                return "\(d.organizer) <\(d.organizerEmail)>"
            }
            return d.organizer
        }
        return event.organizer
    }

    private func infoRow(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.9))
        }
    }

    // MARK: join

    @ViewBuilder
    private var joinButton: some View {
        if let join = event.join, let url = URL(string: join) {
            Button {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "video.fill")
                    Text("Join Teams meeting")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(14)
                .background(CalStyle.busyBlue, in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(.white)
            }
        }
    }

    // MARK: RSVP

    private var isOrganizer: Bool {
        if let d = detail { return d.isOrganizer }
        return event.response == "organizer"
    }

    @ViewBuilder
    private var rsvpSection: some View {
        if !isOrganizer {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    rsvpButton("Accept", icon: "checkmark", action: "accept",
                               wants: "accepted", tint: CalStyle.acceptGreen)
                    rsvpButton("Tentative", icon: "questionmark", action: "tentativelyAccept",
                               wants: "tentativelyAccepted", tint: Color(white: 0.6))
                    rsvpButton("Decline", icon: "xmark", action: "decline",
                               wants: "declined", tint: CalStyle.declineRed)
                }
                if !actionError.isEmpty {
                    Text(actionError)
                        .font(.footnote)
                        .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.45))
                }
            }
        }
    }

    private func rsvpButton(_ label: String, icon: String, action: String,
                            wants: String, tint: Color) -> some View {
        let selected = myResponse == wants
        return Button {
            respond(action, wants: wants)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                Text(label)
                    .font(.footnote.weight(.semibold))
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(selected ? tint.opacity(0.28) : Color.white.opacity(0.06),
                        in: Capsule())
            .overlay(Capsule().stroke(selected ? tint : Color.white.opacity(0.12),
                                      lineWidth: 1))
            .foregroundStyle(selected ? tint : Color.white.opacity(0.85))
        }
        .buttonStyle(.plain)
    }

    /// Optimistic RSVP: highlight moves immediately, reverts on failure.
    private func respond(_ action: String, wants: String) {
        guard myResponse != wants else { return }
        let old = myResponse
        myResponse = wants
        actionError = ""
        Task {
            let ok = await model.respond(id: event.id, action: action)
            if !ok {
                myResponse = old
                actionError = "Couldn't send that response — try again."
            }
        }
    }

    // MARK: attendees (collapsible, like the mail reader's Details)

    @ViewBuilder
    private var attendeesSection: some View {
        if let d = detail, !d.attendees.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { showAttendees.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Text("Attendees (\(d.attendees.count))")
                            .font(.footnote.weight(.semibold))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(showAttendees ? 180 : 0))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                if showAttendees {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(d.attendees) { a in
                            attendeeRow(a)
                        }
                    }
                }
            }
        }
    }

    private func attendeeRow(_ a: CalAttendee) -> some View {
        HStack(spacing: 8) {
            Image(systemName: responseGlyph(a.response).0)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(responseGlyph(a.response).1)
                .frame(width: 16)
            Text(a.name.isEmpty ? a.email : a.name)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
            if !a.required {
                Text("optional")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func responseGlyph(_ response: String) -> (String, Color) {
        switch response {
        case "accepted", "organizer": return ("checkmark", CalStyle.acceptGreen)
        case "tentativelyAccepted": return ("questionmark", Color(white: 0.6))
        case "declined": return ("xmark", CalStyle.declineRed)
        default: return ("minus", Color(white: 0.45))
        }
    }

    // MARK: body preview

    @ViewBuilder
    private var previewSection: some View {
        if let d = detail, !d.preview.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Divider().overlay(.white.opacity(0.15))
                Text(d.preview)
                    .font(.system(size: 15))
                    .lineSpacing(3)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: footer (Ask Scarlet + Delete, like the mail reader)

    private var footer: some View {
        HStack(spacing: 10) {
            footerButton("Ask Scarlet", icon: "sparkles", tint: CalStyle.rose) {
                askScarlet()
            }
            footerButton(deleting ? "Deleting…" : "Delete", icon: "trash.fill",
                         tint: CalStyle.declineRed) {
                confirmDelete = true
            }
            .disabled(deleting)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func footerButton(_ label: String, icon: String, tint: Color,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                Text(label).font(.footnote.weight(.semibold))
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(tint.opacity(0.22), in: Capsule())
            .overlay(Capsule().stroke(tint.opacity(0.5), lineWidth: 1))
            .foregroundStyle(.white)
        }
    }

    /// Hand this event to the live conversation (Talk tab) — same bridge the
    /// mail reader uses; RootView observes and delivers the question.
    private func askScarlet() {
        let organizer = event.organizer.isEmpty ? "an unknown organizer" : event.organizer
        let text = "Ido is asking about a calendar event: '\(event.subject)' "
            + "on \(event.whenLine) with \(organizer). He wants to know: "
        NotificationCenter.default.post(name: .scarletAskAboutEmail, object: nil,
                                        userInfo: ["text": text])
        dismiss()
    }

    private func performDelete() {
        guard !deleting else { return }
        deleting = true
        actionError = ""
        Task {
            let ok = await model.delete(id: event.id)
            deleting = false
            if ok {
                dismiss()
            } else {
                actionError = "Couldn't delete this event — try again."
            }
        }
    }

    /// The ambient-focus line for this event. Built from list-row data alone
    /// so it's byte-identical on appear and disappear — the disappear
    /// handler compares against it.
    private var eventFocus: String {
        "[FOCUS] Ido is viewing a calendar event.\n"
            + "subject: \(event.subject)\n"
            + "when: \(event.whenLine)\n"
            + "where: \(event.location)\n"
            + "organizer: \(event.organizer)\n"
            + "event_id: \(event.id)"
    }
}
