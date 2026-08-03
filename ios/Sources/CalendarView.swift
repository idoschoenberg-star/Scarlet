import SwiftUI
import UIKit

/// Native calendar: Ido's Amwell (Outlook) calendar with Outlook mobile's
/// dark design language — #1B1A19 canvas, #252423 event cards with a 4pt
/// category bar, blue #479EF5 accents, a week strip with today/selection
/// circles and event dots, an agenda grouped by day, and a detail sheet with
/// Join / RSVP / attendees / Ask Scarlet / Delete.
///
/// Local-first: fetched events persist to Documents/calendar-cache.json and
/// are loaded synchronously in the model's init, so the agenda paints
/// instantly from the last snapshot while a background refresh runs. When a
/// cache exists there is no spinner — just a quiet "updated Xm ago" stamp.

// MARK: - Ambient focus

/// The agenda-level focus line, shared by the list's own appearance and the
/// detail sheet's dismissal so both report the exact same thing.
private let calendarAgendaFocus = "[FOCUS] Ido is viewing his Amwell calendar (agenda)."

/// Start of the week containing `date`, per the current calendar.
private func calStartOfWeek(_ date: Date) -> Date {
    let cal = CalDates.cal
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

    /// "11:00 – 11:30" — the agenda row's time line.
    var timeRange: String {
        "\(CalDates.time.string(from: start)) – \(CalDates.time.string(from: end))"
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
/// Israel-time strings like "2026-08-01T09:00:00.0000000". The whole calendar
/// is an Israel-wall-clock view: we parse AND display AND bucket days in
/// Asia/Jerusalem, so it stays correct when Ido's device is on Boston (or any
/// other) time — otherwise every absolute instant is off by the offset and the
/// wrong event highlights, the Join button gates on the wrong day, and events
/// near midnight land in the wrong bucket.
enum CalDates {
    static let zone = TimeZone(identifier: "Asia/Jerusalem") ?? .current
    /// The Israel-pinned calendar every day-boundary check uses (today,
    /// same-day, start-of-week, add-day). Used in place of Calendar.current
    /// everywhere in this view so device timezone never skews the grid.
    static let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return c
    }()
    static let parseFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.timeZone = zone
        return f
    }()
    /// "2026-08-01" — query-string dates, day grouping keys, strip dots.
    static let dayKey: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = zone
        return f
    }()
    /// "9:00"
    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "H:mm"
        f.timeZone = zone
        return f
    }()
    /// "August 2026"
    static let monthTitle: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        f.timeZone = zone
        return f
    }()
    /// "Friday, August 1"
    static let dayHeader: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d"
        f.timeZone = zone
        return f
    }()
    /// "Friday, Aug 1"
    static let detailDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMM d"
        f.timeZone = zone
        return f
    }()
    /// "F" — single-letter weekday for the strip.
    static let weekdayLetter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEEE"
        f.timeZone = zone
        return f
    }()

    static func parse(_ s: String?) -> Date? {
        guard let s, s.count >= 19 else { return nil }
        return parseFormat.date(from: String(s.prefix(19)))
    }
}

// MARK: - Palette

/// In-file hex helper — 0xRRGGBB, sRGB.
private extension Color {
    init(calHex hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }
}

/// Outlook mobile's dark calendar palette.
enum CalStyle {
    /// Page canvas — Outlook dark background.
    static let bg = Color(calHex: 0x1B1A19)
    /// Event card / sheet surface.
    static let surface = Color(calHex: 0x252423)
    /// Slightly lifted surface for the ongoing / up-next card.
    static let surfaceBright = Color(calHex: 0x2E2D2C)
    /// Hairlines and dividers.
    static let separator = Color(calHex: 0x3B3A39)
    /// Microsoft blue — today marker, selection, primary buttons, default
    /// category bar.
    static let accent = Color(calHex: 0x479EF5)
    static let oofPurple = Color(calHex: 0x8764B8)
    static let freeGreen = Color(calHex: 0x218C55)
    static let acceptGreen = Color(calHex: 0x2A8C52)
    static let declineRed = Color(calHex: 0xE8485A)
    /// Scarlet's own brand rose — kept for the Ask Scarlet action only.
    static let rose = Color(calHex: 0xFF596B)

    /// Row accent bar by Outlook's show-as state (default category blue).
    static func bar(for showAs: String) -> Color {
        switch showAs {
        case "tentative": return accent.opacity(0.45)
        case "oof": return oofPurple
        case "free": return freeGreen
        default: return accent
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
    /// When the events on screen were last fetched from the server — drives
    /// the "updated Xm ago" stamp. Survives restarts via the cache.
    @Published var lastUpdated: Date?

    /// The raw wire dicts behind `days` — what calendar-cache.json stores,
    /// so cache and network go through the same parser.
    private var rawEvents: [[String: Any]] = []

    /// One load at a time; pull-to-refresh during a `.task` load is a no-op.
    private var inFlight = false

    /// Local-first: paint from the cache synchronously, before any network.
    init() {
        loadCache()
    }

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
        let cal = CalDates.cal
        let today = cal.startOfDay(for: Date())
        guard let rangeStart = cal.date(byAdding: .day, value: -7, to: today),
              let rangeEnd = cal.date(byAdding: .day, value: 21, to: today) else { return }
        let query = "op=cal_range"
            + "&start=\(CalDates.dayKey.string(from: rangeStart))"
            + "&end=\(CalDates.dayKey.string(from: rangeEnd))"
        do {
            let data = try await Self.request(query, method: "GET")
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let raws = (obj["events"] as? [[String: Any]]) ?? []
            rawEvents = raws
            lastUpdated = Date()
            withAnimation(.snappy) {
                rebuild(Self.parseEvents(raws))
            }
            saveCache()
        } catch {
            errorText = "Couldn't reach the calendar — check your connection."
        }
    }

    /// Wire dicts → events. Shared by the network path and the disk cache.
    static func parseEvents(_ raws: [[String: Any]]) -> [CalEvent] {
        var seen = Set<String>()
        return raws.compactMap { e in
            guard let id = e["id"] as? String,
                  let start = CalDates.parse(e["start"] as? String),
                  let end = CalDates.parse(e["end"] as? String) else { return nil }
            // A repeated Graph id traps the diffable List at regular width — keep first.
            guard seen.insert(id).inserted else { return nil }
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
    }

    /// Group by local start day. Empty days are skipped except today and
    /// tomorrow, which always appear (they carry the "No events" rows).
    private func rebuild(_ events: [CalEvent]) {
        let cal = CalDates.cal
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

    // MARK: cache — Documents/calendar-cache.json, the local-first snapshot

    static var cacheURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return docs.appendingPathComponent("calendar-cache.json")
    }

    /// Synchronous read at init — the snapshot is small (≤42 days of rows),
    /// so this is a single fast disk hit that buys an instant first paint.
    private func loadCache() {
        guard let data = try? Data(contentsOf: Self.cacheURL),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }
        rawEvents = (obj["events"] as? [[String: Any]]) ?? []
        if let t = obj["fetched_at"] as? Double {
            lastUpdated = Date(timeIntervalSince1970: t)
        }
        rebuild(Self.parseEvents(rawEvents))
    }

    private func saveCache() {
        var obj: [String: Any] = ["events": rawEvents]
        if let d = lastUpdated {
            obj["fetched_at"] = d.timeIntervalSince1970
        }
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj)
        else { return }
        try? data.write(to: Self.cacheURL, options: .atomic)
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

    /// RSVP: POST, then mirror the new state into the agenda rows (and the
    /// cache, so a relaunch paints the same state).
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
            for ri in rawEvents.indices where (rawEvents[ri]["id"] as? String) == id {
                rawEvents[ri]["response"] = newResponse
            }
            saveCache()
            return true
        } catch {
            return false
        }
    }

    /// Delete: POST, drop the row locally (and from the cache), then refresh
    /// in the background.
    func delete(id: String) async -> Bool {
        do {
            let data = try await Self.request("op=cal_delete", method: "POST",
                                              body: ["id": id])
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard (obj?["ok"] as? Bool) == true else { return false }
            let cal = CalDates.cal
            for di in days.indices {
                days[di].events.removeAll { $0.id == id }
            }
            days.removeAll { day in
                day.events.isEmpty
                    && !cal.isDateInToday(day.date)
                    && !cal.isDateInTomorrow(day.date)
            }
            eventDayKeys = Set(days.filter { !$0.events.isEmpty }.map { $0.id })
            rawEvents.removeAll { ($0["id"] as? String) == id }
            saveCache()
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

    @State private var selectedDay = CalDates.cal.startOfDay(for: Date())
    @State private var weekAnchor = calStartOfWeek(Date())
    @State private var sheetEvent: CalEvent?
    /// One jump-to-today per tab appearance — re-armed in onAppear.
    @State private var didInitialJump = false

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                headerBar(proxy)
                monthStrip(proxy)
                Rectangle()
                    .fill(CalStyle.separator)
                    .frame(height: 0.5)
                content
            }
            .background(CalStyle.bg.ignoresSafeArea())
            // Scarlet lives at the bottom of the agenda — the event detail
            // sheet covers the whole screen, so it never collides with the
            // sheet's own footer buttons.
            .safeAreaInset(edge: .bottom) {
                ScarletPresenceView(convo: convo)
                    .padding(.vertical, 6)
            }
            // .task re-runs on tab select; foreground return refreshes too.
            // Every open lands the agenda on TODAY — the range starts a week
            // back, so without this jump the list opens on past days. The
            // jump retries after layout settles AND re-fires when the data
            // lands (List rows aren't scrollable the instant state updates).
            .task {
                await model.load()
                for delayMs in [80, 400, 1000] where !didInitialJump {
                    try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                    if !model.days.isEmpty {
                        goToToday(proxy, animated: false)
                        didInitialJump = true
                    }
                }
            }
            .onChange(of: model.days.count) { _, count in
                guard !didInitialJump, count > 0 else { return }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    goToToday(proxy, animated: false)
                    didInitialJump = true
                }
            }
            .onReceive(NotificationCenter.default.publisher(
                for: UIApplication.willEnterForegroundNotification)) { _ in
                Task { await model.load() }
            }
        }
        // Ambient focus: the agenda reports itself whenever it's on screen —
        // and each re-entry re-arms the jump-to-today.
        .onAppear {
            didInitialJump = false
            convo.setFocus(calendarAgendaFocus)
        }
        .reportsModalPresence(sheetEvent != nil)
        .sheet(item: $sheetEvent) { event in
            CalEventDetailView(event: event, model: model)
                .preferredColorScheme(.dark)
        }
    }

    /// The ongoing event, else the next upcoming one — Outlook's "up next"
    /// emphasis. All-day events never take it.
    private var upNextID: String? {
        let now = Date()
        var next: (Date, String)?
        for day in model.days {
            for e in day.events where !e.allDay {
                if e.start <= now && now < e.end { return e.id }
                if e.start > now && (next == nil || e.start < (next?.0 ?? .distantFuture)) {
                    next = (e.start, e.id)
                }
            }
        }
        return next?.1
    }

    // MARK: header (avatar · big Calendar title · Today jump)

    private func headerBar(_ proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 12) {
            // Account avatar — visual anchor only on this screen.
            ZStack {
                Circle().fill(Color(calHex: 0x4A4948))
                Text("IS")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 38, height: 38)
            Text("Calendar")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.white)
            Spacer()
            // Unambiguous "jump to today" — a bare calendar glyph reads as
            // "add/settings"; the word is clear.
            Button {
                goToToday(proxy)
            } label: {
                Text("Today")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(CalStyle.accent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private func goToToday(_ proxy: ScrollViewProxy, animated: Bool = true) {
        let today = CalDates.cal.startOfDay(for: Date())
        selectedDay = today
        weekAnchor = calStartOfWeek(today)
        scrollToDay(today, proxy: proxy, animated: animated)
    }

    /// Jump the agenda to a day's anchor — or the nearest following loaded
    /// day (empty past/future days have no row), else the last one.
    private func scrollToDay(_ date: Date, proxy: ScrollViewProxy, animated: Bool = true) {
        let key = CalDates.dayKey.string(from: date)
        let target = model.days.first(where: { $0.id >= key })?.id ?? model.days.last?.id
        if let target {
            if animated {
                withAnimation(.snappy(duration: 0.25)) {
                    proxy.scrollTo(target, anchor: .top)
                }
            } else {
                proxy.scrollTo(target, anchor: .top)
            }
        }
    }

    // MARK: month strip (Outlook's week row)

    private var weekDays: [Date] {
        (0..<7).compactMap { CalDates.cal.date(byAdding: .day, value: $0, to: weekAnchor) }
    }

    private var monthTitle: String {
        let ref = weekDays.count > 3 ? weekDays[3] : weekAnchor
        return CalDates.monthTitle.string(from: ref)
    }

    private func monthStrip(_ proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(monthTitle)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                // Quiet freshness stamp — the cache paints instantly, this
                // says how old that paint is. Re-renders once a minute.
                if let updated = model.lastUpdated {
                    TimelineView(.everyMinute) { _ in
                        Text(Self.agoStamp(updated))
                            .font(.system(size: 11))
                            .foregroundStyle(Color(calHex: 0x8A8886))
                    }
                }
            }
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

    /// "updated just now" / "updated 5m ago" / "updated 2h ago" / "updated 3d ago".
    static func agoStamp(_ date: Date) -> String {
        let s = max(0, Int(Date().timeIntervalSince(date)))
        if s < 90 { return "updated just now" }
        let m = s / 60
        if m < 60 { return "updated \(m)m ago" }
        let h = m / 60
        if h < 24 { return "updated \(h)h ago" }
        return "updated \(h / 24)d ago"
    }

    private func weekChevron(_ icon: String, byDays: Int) -> some View {
        Button {
            if let moved = CalDates.cal.date(byAdding: .day, value: byDays, to: weekAnchor) {
                withAnimation(.snappy(duration: 0.2)) {
                    weekAnchor = moved
                }
            }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(calHex: 0x8A8886))
                .frame(width: 22, height: 44)
        }
        .buttonStyle(.plain)
    }

    /// One strip day: weekday initial small gray, 17pt number — today is a
    /// filled Microsoft-blue circle with a white number, the selected day an
    /// outlined pill — with an event-presence dot underneath.
    private func dayCell(_ day: Date, proxy: ScrollViewProxy) -> some View {
        let cal = CalDates.cal
        let isToday = cal.isDateInToday(day)
        let isSelected = cal.isDate(day, inSameDayAs: selectedDay)
        let hasEvents = model.eventDayKeys.contains(CalDates.dayKey.string(from: day))
        return Button {
            withAnimation(.snappy(duration: 0.2)) {
                selectedDay = cal.startOfDay(for: day)
            }
            scrollToDay(day, proxy: proxy)
        } label: {
            VStack(spacing: 3) {
                Text(CalDates.weekdayLetter.string(from: day))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(calHex: 0x8A8886))
                ZStack {
                    if isToday {
                        Circle().fill(CalStyle.accent)
                    } else if isSelected {
                        Circle().fill(CalStyle.surface)
                        Circle().stroke(CalStyle.accent, lineWidth: 1.5)
                    }
                    Text("\(cal.component(.day, from: day))")
                        .font(.system(size: 17, weight: isToday ? .semibold : .regular))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                }
                .frame(width: 34, height: 34)
                Circle()
                    .fill(hasEvents ? Color(calHex: 0x8A8886) : Color.clear)
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
            // First run only — once a cache exists this never shows again.
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
                    .tint(CalStyle.accent)
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
                    .foregroundStyle(Color(calHex: 0xE8B04F))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            ForEach(model.days) { day in
                dayHeader(day)
                if day.events.isEmpty {
                    noEventsRow
                }
                let allDayEvents = day.events.filter { $0.allDay }
                if !allDayEvents.isEmpty {
                    allDayChips(allDayEvents)
                }
                ForEach(day.events.filter { !$0.allDay }) { event in
                    CalEventRow(event: event, isUpNext: event.id == upNextID) {
                        sheetEvent = event
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 3, leading: 16, bottom: 3, trailing: 16))
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { await model.load() }
    }

    /// "TODAY · FRIDAY, AUGUST 1" — Outlook's small-caps gray day header.
    /// The row carries the day's scroll anchor id.
    private func dayHeader(_ day: CalendarModel.Day) -> some View {
        Text(dayTitle(day.date))
            .font(.system(size: 13, weight: .semibold).smallCaps())
            .kerning(0.4)
            .foregroundStyle(CalDates.cal.isDateInToday(day.date)
                ? CalStyle.accent : Color(calHex: 0x8A8886))
            .padding(.top, 16)
            .padding(.bottom, 2)
            .id(day.id)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    private func dayTitle(_ date: Date) -> String {
        let cal = CalDates.cal
        let name = CalDates.dayHeader.string(from: date)
        if cal.isDateInToday(date) { return "Today · " + name }
        if cal.isDateInTomorrow(date) { return "Tomorrow · " + name }
        return name
    }

    private var noEventsRow: some View {
        Text("No events")
            .font(.system(size: 14))
            .italic()
            .foregroundStyle(Color(calHex: 0x797774))
            .padding(.leading, 4)
            .padding(.vertical, 4)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    /// Compact all-day chips at the top of a day, Outlook style.
    private func allDayChips(_ events: [CalEvent]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(events) { e in
                    Button {
                        sheetEvent = e
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(CalStyle.bar(for: e.showAs))
                                .frame(width: 7, height: 7)
                            Text(e.subject)
                                .font(.system(size: 13, weight: .semibold))
                                .strikethrough(e.response == "declined")
                                .foregroundStyle(e.response == "declined"
                                    ? Color(calHex: 0x8A8886) : Color.white)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(CalStyle.surface, in: Capsule())
                        .overlay(Capsule().stroke(CalStyle.separator, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 3, leading: 16, bottom: 3, trailing: 16))
    }
}

// MARK: - Agenda row

/// Outlook mobile's event card: #252423 surface, 4pt category bar on the
/// leading edge, white semibold title, gray time range and location, and a
/// Join capsule for today's Teams meetings. The ongoing / next-up event gets
/// a brighter card with a soft blue glow on its bar.
struct CalEventRow: View {
    let event: CalEvent
    let isUpNext: Bool
    let onOpen: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(CalStyle.bar(for: event.showAs))
                .frame(width: 4)
                .shadow(color: isUpNext ? CalStyle.accent.opacity(0.75) : Color.clear,
                        radius: isUpNext ? 5 : 0)
                .padding(.vertical, 10)
                .padding(.leading, 10)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.subject)
                    .font(.system(size: 15, weight: .semibold))
                    .strikethrough(event.response == "declined")
                    .foregroundStyle(event.response == "declined"
                        ? Color(calHex: 0x8A8886) : Color.white)
                    .lineLimit(2)
                    .truncationMode(.tail)
                Text(event.timeRange)
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(isUpNext
                        ? Color(calHex: 0xA8CEF5) : Color(calHex: 0x9E9C9A))
                if !event.location.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.system(size: 10))
                        Text(event.location)
                            .font(.system(size: 13))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .foregroundStyle(Color(calHex: 0x8A8886))
                }
            }
            .padding(.vertical, 10)
            Spacer(minLength: 8)
            if let joinURL, CalDates.cal.isDateInToday(event.start) {
                Button {
                    UIApplication.shared.open(joinURL, options: [:], completionHandler: nil)
                } label: {
                    Text("Join")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(CalStyle.accent, in: Capsule())
                }
                .buttonStyle(.borderless)
                .padding(.trailing, 10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isUpNext ? CalStyle.surfaceBright : CalStyle.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isUpNext ? CalStyle.accent.opacity(0.4) : Color.clear,
                        lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture { onOpen() }
    }

    private var joinURL: URL? {
        guard let join = event.join else { return nil }
        return URL(string: join)
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
                    HStack(alignment: .top, spacing: 10) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(CalStyle.bar(for: event.showAs))
                            .frame(width: 4)
                            .padding(.vertical, 3)
                        Text(event.subject)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        // Delete is a rare, destructive action — a quiet icon in
                        // the corner, not a co-primary button. Confirmation-guarded.
                        Menu {
                            Button("Delete event", systemImage: "trash",
                                   role: .destructive) { confirmDelete = true }
                        } label: {
                            Image(systemName: deleting ? "hourglass" : "ellipsis.circle")
                                .font(.system(size: 18))
                                .foregroundStyle(.secondary)
                                .frame(width: 34, height: 34)
                        }
                        .disabled(deleting)
                    }
                    infoBlock
                    joinButton
                    rsvpSection
                    attendeesSection
                    previewSection
                }
                .padding(20)
            }
            Divider().overlay(CalStyle.separator)
            footer
        }
        .background(CalStyle.bg.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task { await fetch() }
        // Ambient focus: this event while the sheet is up; back to the agenda
        // on the way out — unless another screen already claimed focus.
        .onAppear {
            convo.setFocus(eventFocus)
        }
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

    // MARK: when / where / who — an Outlook-style dark card

    private var infoBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
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
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CalStyle.surface, in: RoundedRectangle(cornerRadius: 12))
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
                .foregroundStyle(Color(calHex: 0x8A8886))
                .frame(width: 18)
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.92))
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
                .background(CalStyle.accent, in: RoundedRectangle(cornerRadius: 14))
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
                               wants: "tentativelyAccepted", tint: Color(calHex: 0x9E9C9A))
                    rsvpButton("Decline", icon: "xmark", action: "decline",
                               wants: "declined", tint: CalStyle.declineRed)
                }
                if !actionError.isEmpty {
                    Text(actionError)
                        .font(.footnote)
                        .foregroundStyle(Color(calHex: 0xF57373))
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
            .background(selected ? tint.opacity(0.28) : CalStyle.surface,
                        in: Capsule())
            .overlay(Capsule().stroke(selected ? tint : CalStyle.separator,
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
                    withAnimation(.snappy(duration: 0.18)) { showAttendees.toggle() }
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
        case "tentativelyAccepted": return ("questionmark", Color(calHex: 0x9E9C9A))
        case "declined": return ("xmark", CalStyle.declineRed)
        default: return ("minus", Color(calHex: 0x797774))
        }
    }

    // MARK: body preview

    @ViewBuilder
    private var previewSection: some View {
        if let d = detail, !d.preview.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Divider().overlay(CalStyle.separator)
                Text(d.preview)
                    .font(.system(size: 15))
                    .lineSpacing(3)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: footer (Ask Scarlet — the one primary action; Delete lives in the
    // header overflow menu so it isn't a co-equal destructive button)

    private var footer: some View {
        footerButton("Ask Scarlet", icon: "sparkles", tint: CalStyle.rose) {
            askScarlet()
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
