import SwiftUI
import UIKit
import MapKit

// MARK: - The LIVE Journal (Ido's commission, 2026-08-21)
//
// "It should also be available in the Journal section on the Scarlet
// application. There, I can view day by day, but I can also see a month
// review and navigate between days… a beautiful way to follow up on
// everything that is happening."
//
// This file is the browser. The day page reads by IMPORTANCE (2026-08-21):
// header (date/place/weather) → narrative → KEY MOMENTS (one chronological
// thread of summarized meetings + walks/workouts, walks carrying route
// snapshot maps) → health grid + meals → pins → a muted APPENDIX for the
// thin and speculative (no-summary episodes, unmatched calendar rows, the
// missing-axes line). Then a month grid with compact per-day signals, and
// free-text search over the whole journal. TODAY is alive — it refreshes
// while he looks at it, so a busy morning is visible at noon.
//
// The review lane (staged actions + storyline verifications) that used to BE
// this tab still exists — see JournalView.swift (`JournalReviewScreen`) —
// reachable from a quiet banner whenever anything waits for his ruling.
//
// Server truth (fixes-journal-live.md — the authoritative wire contract):
//   op=journal_day&date=YYYY-MM-DD&tz=  → {date, narrative|null,
//       data{place, weather{icon,words,tmin,tmax}, stays, moves, movement,
//       episodes (planned = matched calendar event | null), calendar
//       (attended flag; attended ones ARE the episodes), pins, docs, meals,
//       health|null, workouts, missing, failures}, updated_at}
//   op=journal_month&month=YYYY-MM&tz=  → {days:[{date, steps, km,
//       episodes, meetings, meals, has_pins, weather{icon,tmin,tmax}, place}]}
//       (only days WITH data appear — absent days render quietly dimmed)
//   op=journal_search {q, tz}           → {answer, days (newest-first, ≤30),
//       evidence:[{date, kind: episode|narrative|segment|weather, title}]}
// Older backend without these ops → the honest "journal engine is deploying"
// placeholder, never a crash.

// MARK: - Style

private enum JStyle {
    static let rose = Color(red: 1, green: 0.35, blue: 0.42)
    static let amber = Color(red: 1, green: 0.72, blue: 0.30)
    static let pink = Color(red: 0.96, green: 0.42, blue: 0.75)
    static let sky = Color(red: 0.45, green: 0.72, blue: 0.98)
    static let mint = Color(red: 0.40, green: 0.85, blue: 0.62)
    static let card = Color.white.opacity(0.06)

    /// Workout kinds that happen OUT THERE — the ones whose row earns a map.
    static func isOutdoor(_ kind: String) -> Bool {
        ["walking", "running", "cycling", "hiking"].contains(kind.lowercased())
    }

    static func workoutIcon(_ kind: String) -> String {
        switch kind.lowercased() {
        case "walking": return "figure.walk"
        case "running": return "figure.run"
        case "cycling": return "figure.outdoor.cycle"
        case "swimming": return "figure.pool.swim"
        case "hiking": return "figure.hiking"
        case "yoga": return "figure.yoga"
        case "strength", "weights": return "dumbbell.fill"
        case "hiit": return "figure.highintensity.intervaltraining"
        case "core": return "figure.core.training"
        default: return "figure.mixed.cardio"
        }
    }
}

// MARK: - Date plumbing (device-local wall clock: the journal follows Ido)

enum JDates {
    static let cal = Calendar.current

    /// "2026-08-21" — query keys and cache keys.
    static let dayKey: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    /// "2026-08" — month query keys.
    static let monthKey: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM"
        return f
    }()
    /// "Thursday, Aug 21"
    static let dayTitle: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMM d"
        return f
    }()
    /// "August 2026"
    static let monthTitle: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f
    }()
    /// "Thu 21" — search-result day chips.
    static let chip: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d"
        return f
    }()
    /// "14:32" — timeline times and the freshness stamp.
    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "H:mm"
        return f
    }()

    static func title(for day: Date) -> String {
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        return dayTitle.string(from: day)
    }

    /// Parse the wire's timestamps: ISO8601 (fractional or not), Postgres
    /// "2026-08-21 05:30:38+00", or a bare "2026-08-21".
    static func parseWhen(_ s: String) -> Date? {
        if s.isEmpty { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        let pg = DateFormatter()
        pg.locale = Locale(identifier: "en_US_POSIX")
        pg.timeZone = TimeZone(secondsFromGMT: 0)
        for fmt in ["yyyy-MM-dd HH:mm:ss.SSSSSSZ", "yyyy-MM-dd HH:mm:ssZ",
                    "yyyy-MM-dd HH:mm:ss.SSSSSS'+00'", "yyyy-MM-dd HH:mm:ss'+00'",
                    "yyyy-MM-dd'T'HH:mm:ss"] {
            pg.dateFormat = fmt
            if let d = pg.date(from: s) { return d }
        }
        pg.dateFormat = "yyyy-MM-dd"
        pg.timeZone = .current
        return pg.date(from: s)
    }

    static func parseDayKey(_ s: String) -> Date? {
        dayKey.date(from: s).map { cal.startOfDay(for: $0) }
    }
}

// MARK: - Wire (same token plumbing as every other app-api model)

private enum JWireError: Error {
    case badStatus(Int)
    /// The op isn't on the deployed backend yet — the honest placeholder case.
    case opMissing
}

private enum JWire {
    static func request(_ query: String, method: String = "GET",
                        body: [String: Any]? = nil) async throws -> [String: Any] {
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
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if !(200...299).contains(status) {
            // An older backend answers unknown ops with 400 {"error":"unknown
            // op"} — that is "the engine is deploying", not an error. A 404
            // here is a REAL answer (journal_day: future date), so it stays
            // an ordinary error.
            let errText = ((obj["error"] as? String) ?? "").lowercased()
            if errText.contains("unknown op") || errText.contains("unsupported op") {
                throw JWireError.opMissing
            }
            throw JWireError.badStatus(status)
        }
        return obj
    }
}

// Tolerant field readers — the wire shapes live in fixes-journal-live.md;
// these accept the documented names first and near-synonyms defensively.
private func jStr(_ r: [String: Any], _ keys: [String]) -> String {
    for k in keys {
        if let v = r[k] as? String, !v.isEmpty { return v }
        if let n = r[k] as? NSNumber { return n.stringValue }
    }
    return ""
}
private func jNum(_ r: [String: Any], _ keys: [String]) -> Double? {
    for k in keys {
        if let n = r[k] as? NSNumber { return n.doubleValue }
        if let s = r[k] as? String, let d = Double(s) { return d }
    }
    return nil
}
private func jInt(_ r: [String: Any], _ keys: [String]) -> Int? {
    jNum(r, keys).map { Int($0.rounded()) }
}

// MARK: - Day payload

struct JDayWeather {
    let emoji: String
    let words: String
    let highC: Double?
    let lowC: Double?

    var strip: String {
        var bits: [String] = []
        if let h = highC { bits.append("H \(Int(h.rounded()))°") }
        if let l = lowC { bits.append("L \(Int(l.rounded()))°") }
        return bits.joined(separator: " · ")
    }
}

struct JDayHealth {
    let steps: Int?
    let distanceKm: Double?
    let exerciseMin: Int?
    let hrvMs: Int?
    let restingHR: Int?
    let activeKcal: Int?
    let sleepMin: Int?

    var isEmpty: Bool {
        steps == nil && distanceKm == nil && exerciseMin == nil
            && hrvMs == nil && restingHR == nil && activeKcal == nil && sleepMin == nil
    }
}

/// A dwell from the wire (data.stays{start,end,lat,lng,place}) — the anchors
/// a walk stretches between.
struct JStay {
    let start: Date
    let end: Date
    let coord: CLLocationCoordinate2D
    let place: String
}

/// What a walk's map can honestly draw. The wire ships `route` on both moves
/// and workouts: an array of [lat,lng] pairs (≤120 points, Douglas-Peucker
/// simplified), or null when there were under 4 fixes. A real trace draws
/// solid with `approximate` false; a null route falls back to the straight
/// line between the dwells that bracket the window — dashed, and the caption
/// says so.
struct JRoute {
    let coords: [CLLocationCoordinate2D]   // full trace, or 1–2 dwell anchors
    let startPlace: String
    let endPlace: String
    let approximate: Bool                  // endpoints only, not the true path

    /// Left from a place and came back to it (or only one anchor was found).
    var isLoop: Bool { coords.count < 2 }
}

/// One row on the day timeline — every item type flattened to what the row
/// renders, each kind keeping its own visual identity.
struct JDayItem: Identifiable {
    enum Kind {
        case walk, transit, workout, meeting, calendar, pin, meal
    }
    let id: String
    let kind: Kind
    let when: Date?          // sort key; nil sorts last
    let timeLabel: String    // "9:15" or "9:15 – 10:00"
    let title: String
    let subtitle: String     // summary / excerpt / detail line
    let place: String
    let chip: String?        // planned-vs-actual on meetings
    let chipGood: Bool
    let icon: String
    let tint: Color
    /// Thin/speculative (an episode with no summary and nobody named) — sinks
    /// to the appendix, never the key-moments thread.
    var thin: Bool = false
    /// Walks and outdoor workouts carry their route snapshot.
    var route: JRoute? = nil
    /// Server-side identity for drill-down (op=journal_item): pins and
    /// episodes carry their row id so tapping the card opens the full
    /// conversation/detail (Ido 2026-08-21). nil = the row is all there is.
    var sourceId: String? = nil
    var sourceKind: String? = nil   // "pin" | "episode"

    var accessLabel: String { "\(timeLabel) \(title)" }
}

struct JDayPayload {
    let dateKey: String
    let narrative: String
    let place: String
    let weather: JDayWeather?
    let health: JDayHealth
    let items: [JDayItem]
    let missing: [String]
    let updatedAt: Date?
    let fetchedAt: Date

    var isEmpty: Bool { narrative.isEmpty && items.isEmpty && health.isEmpty }
}

// MARK: - Day payload parsing (wire shapes: fixes-journal-live.md)

private enum JDayParser {
    static func parse(_ obj: [String: Any], dateKey: String) -> JDayPayload {
        let data = (obj["data"] as? [String: Any]) ?? [:]
        var items: [JDayItem] = []

        // 🛏 stays — the day's dwells, each a single validated coordinate.
        // They are not rows themselves; they anchor the walk maps. Invalid
        // pairs are dropped BEFORE MapKit ever sees them (a lat 999 fed to
        // MapPolyline/MKCoordinateRegion asserts and takes the app down —
        // same guard as HealthView's route parser).
        let stays: [JStay] = ((data["stays"] as? [[String: Any]]) ?? []).compactMap { s in
            guard let start = JDates.parseWhen(jStr(s, ["start"])),
                  let end = JDates.parseWhen(jStr(s, ["end"])),
                  let lat = jNum(s, ["lat"]), let lng = jNum(s, ["lng"]) else { return nil }
            let c = CLLocationCoordinate2D(latitude: lat, longitude: lng)
            guard CLLocationCoordinate2DIsValid(c),
                  abs(lat) > 0.0001 || abs(lng) > 0.0001 else { return nil }
            return JStay(start: start, end: end, coord: c, place: jStr(s, ["place"]))
        }

        // 🚶 moves — walks and transit hops between dwells
        // (wire: data.moves[{start,end,km,kind:"walk"|"transit",
        //  route:[[lat,lng],…]|null — present for walks, ≤120 DP points})
        for (i, m) in ((data["moves"] as? [[String: Any]]) ?? []).enumerated() {
            let mode = jStr(m, ["kind", "mode"]).lowercased()
            let isWalk = mode != "transit"
            let km = jNum(m, ["km"])
            let start = JDates.parseWhen(jStr(m, ["start", "start_at"]))
            let end = JDates.parseWhen(jStr(m, ["end", "end_at"]))
            var bits: [String] = []
            if let s = start, let e = end {
                bits.append(HealthMin.text(max(1, Int(e.timeIntervalSince(s) / 60))))
            }
            if let km, km > 0 { bits.append(String(format: "%.1f km", km)) }
            items.append(JDayItem(
                id: "move-\(i)",
                kind: isWalk ? .walk : .transit,
                when: start,
                timeLabel: rangeLabel(start, end),
                title: isWalk ? "Walk" : "On the move",
                subtitle: bits.joined(separator: " · "),
                place: "",
                chip: nil, chipGood: false,
                icon: isWalk ? "figure.walk" : "arrow.right.circle",
                tint: isWalk ? JStyle.pink : JStyle.sky,
                route: isWalk
                    // Wire contract (lifegraph-sweep a47cc12): moves carry the
                    // trace under `points`; `route` kept as a fallback key.
                    ? (traceRoute(m["points"]) ?? traceRoute(m["route"])
                        ?? routeBetween(stays: stays, start: start, end: end))
                    : nil))
        }

        // 💪 workouts (wire: {start_at,end_at,kind,distance_m,kcal,avg_hr,
        // elevation_gain_m, route:[[lat,lng],…]|null} — duration computed
        // from the range; route prefers the device-recorded trail, falling
        // back server-side to location fixes over the workout window)
        for (i, w) in ((data["workouts"] as? [[String: Any]]) ?? []).enumerated() {
            let kind = jStr(w, ["kind", "type"])
            let start = JDates.parseWhen(jStr(w, ["start_at", "start"]))
            let end = JDates.parseWhen(jStr(w, ["end_at", "end"]))
            var bits: [String] = []
            if let s = start, let e = end {
                bits.append(HealthMin.text(max(1, Int(e.timeIntervalSince(s) / 60))))
            }
            if let km = jNum(w, ["distance_m"]).map({ $0 / 1000 }), km >= 0.1 {
                bits.append(String(format: "%.1f km", km))
            }
            if let el = jInt(w, ["elevation_gain_m"]), el > 0 { bits.append("+\(el) m") }
            if let kc = jInt(w, ["kcal"]), kc > 0 { bits.append("\(kc) kcal") }
            if let hr = jInt(w, ["avg_hr"]), hr > 0 { bits.append("avg HR \(hr)") }
            items.append(JDayItem(
                id: "workout-\(i)",
                kind: .workout,
                when: start,
                timeLabel: start.map { JDates.time.string(from: $0) } ?? "",
                title: kind.isEmpty ? "Workout" : kind.capitalized,
                subtitle: bits.joined(separator: " · "),
                place: "",
                chip: nil, chipGood: false,
                icon: JStyle.workoutIcon(kind),
                tint: JStyle.rose,
                // A real trail wins whatever the kind (the server only ships
                // one when there were fixes); the dwell fallback stays gated
                // to outdoor kinds so a gym session never grows a fake map.
                route: traceRoute(w["route"])
                    ?? (JStyle.isOutdoor(kind)
                        ? routeBetween(stays: stays, start: start, end: end) : nil)))
        }

        // 📅 episodes — what actually happened (wire: planned = the matched
        // calendar event object or null; actual_delta_min = start slip)
        for (i, e) in ((data["episodes"] as? [[String: Any]]) ?? []).enumerated() {
            let start = JDates.parseWhen(jStr(e, ["started_at", "start_at", "start"]))
            let end = JDates.parseWhen(jStr(e, ["ended_at", "end_at", "end"]))
            let people = (e["people"] as? [String])?.filter { !$0.isEmpty } ?? []
            // Planned-vs-actual chip: linked to a calendar event → "planned"
            // (with the start slip when it's meaningful); otherwise the day
            // held something the calendar never knew about.
            var chip: String?
            var good = true
            if e["planned"] as? [String: Any] != nil {
                if let delta = jInt(e, ["actual_delta_min"]), abs(delta) >= 10 {
                    chip = delta > 0 ? "planned · \(delta)m late" : "planned · \(-delta)m early"
                } else {
                    chip = "planned"
                }
            } else {
                chip = "unplanned"
                good = false
            }
            var sub = jStr(e, ["summary"])
            if !people.isEmpty {
                sub = sub.isEmpty ? people.joined(separator: ", ")
                                  : people.joined(separator: ", ") + " — " + sub
            }
            let epKind = jStr(e, ["kind"]).lowercased()
            // No summary AND nobody named = thin evidence — the appendix's
            // material, never a key moment.
            let thin = jStr(e, ["summary"]).isEmpty && people.isEmpty
            items.append(JDayItem(
                id: "ep-" + (jStr(e, ["id"]).isEmpty ? "\(i)" : jStr(e, ["id"])),
                kind: .meeting,
                when: start,
                timeLabel: rangeLabel(start, end),
                title: jStr(e, ["title"]),
                subtitle: sub,
                place: jStr(e, ["place"]),
                chip: chip, chipGood: good,
                icon: episodeIcon(epKind),
                tint: JStyle.sky,
                thin: thin,
                sourceId: jStr(e, ["id"]).isEmpty ? nil : jStr(e, ["id"]),
                sourceKind: "episode"))
        }

        // 📅 calendar events that never became episodes (attended ones ARE
        // the episodes above — listing both would double every meeting)
        for (i, c) in ((data["calendar"] as? [[String: Any]]) ?? []).enumerated() {
            if (c["attended"] as? Bool) == true { continue }
            let allDay = (c["all_day"] as? Bool) == true
            let online = (c["is_online"] as? Bool) == true
            let start = JDates.parseWhen(jStr(c, ["scheduled_start"]))
            let end = JDates.parseWhen(jStr(c, ["scheduled_end"]))
            items.append(JDayItem(
                id: "cal-\(i)",
                kind: .calendar,
                when: allDay ? nil : start,
                timeLabel: allDay ? "All day" : rangeLabel(start, end),
                title: jStr(c, ["title"]),
                subtitle: jStr(c, ["organizer"]),
                place: jStr(c, ["location"]),
                chip: nil, chipGood: false,
                icon: online ? "video" : "calendar",
                tint: Color.white.opacity(0.45)))
        }

        // 🎙 pin conversations
        for (i, p) in ((data["pins"] as? [[String: Any]]) ?? []).enumerated() {
            let at = JDates.parseWhen(jStr(p, ["started_at", "start_at", "at"]))
            items.append(JDayItem(
                id: "pin-\(i)",
                kind: .pin,
                when: at,
                timeLabel: at.map { JDates.time.string(from: $0) } ?? "",
                title: jStr(p, ["title"]),
                subtitle: jStr(p, ["excerpt"]),
                place: "",
                chip: nil, chipGood: false,
                icon: "waveform",
                tint: JStyle.rose,
                sourceId: jStr(p, ["id"]).isEmpty ? nil : jStr(p, ["id"]),
                sourceKind: "pin"))
        }

        // 🎙 synced recorder/Plaud documents (no timestamp on the wire —
        // they settle at the end of the day)
        for (i, d) in ((data["docs"] as? [[String: Any]]) ?? []).enumerated() {
            items.append(JDayItem(
                id: "doc-\(i)",
                kind: .pin,
                when: nil,
                timeLabel: "",
                title: jStr(d, ["title"]),
                subtitle: jStr(d, ["source"]),
                place: "",
                chip: nil, chipGood: false,
                icon: "doc.text.fill",
                tint: JStyle.rose))
        }

        // 🍽 meals (wire: {at, title, calories, protein_g})
        for (i, m) in ((data["meals"] as? [[String: Any]]) ?? []).enumerated() {
            let at = JDates.parseWhen(jStr(m, ["at"]))
            var bits: [String] = []
            if let kcal = jInt(m, ["calories", "kcal"]), kcal > 0 { bits.append("\(kcal) kcal") }
            if let pr = jInt(m, ["protein_g"]), pr > 0 { bits.append("\(pr)g protein") }
            items.append(JDayItem(
                id: "meal-\(i)",
                kind: .meal,
                when: at,
                timeLabel: at.map { JDates.time.string(from: $0) } ?? "",
                title: jStr(m, ["title"]),
                subtitle: bits.joined(separator: " · "),
                place: "",
                chip: nil, chipGood: false,
                icon: "fork.knife",
                tint: JStyle.amber))
        }

        // Sort chronologically; time-less items sink to the end of the day.
        items.sort {
            ($0.when ?? .distantFuture) < ($1.when ?? .distantFuture)
        }

        // wire: weather {tmin, tmax, precip_mm, code, words, icon, rain_hours}
        var weather: JDayWeather?
        if let w = data["weather"] as? [String: Any] {
            let emoji = jStr(w, ["icon", "emoji"])
            let words = jStr(w, ["words"])
            let hi = jNum(w, ["tmax"])
            let lo = jNum(w, ["tmin"])
            if !(emoji.isEmpty && words.isEmpty && hi == nil && lo == nil) {
                weather = JDayWeather(emoji: emoji, words: words, highC: hi, lowC: lo)
            }
        }

        // wire: health {steps, distance_m, active_kcal, exercise_min,
        // stand_hours, resting_hr, hrv_ms, sleep_min, …} | null
        let h = (data["health"] as? [String: Any]) ?? [:]
        let health = JDayHealth(
            steps: jInt(h, ["steps"]),
            distanceKm: jNum(h, ["distance_m"]).map { $0 / 1000 },
            exerciseMin: jInt(h, ["exercise_min"]),
            hrvMs: jInt(h, ["hrv_ms"]),
            restingHR: jInt(h, ["resting_hr"]),
            activeKcal: jInt(h, ["active_kcal"]),
            sleepMin: jInt(h, ["sleep_min"]))

        // `missing` = axes with no data; `failures` = axes whose fetch broke.
        // Both surface in the one honest footer line.
        var missing = ((data["missing"] as? [String]) ?? []).filter { !$0.isEmpty }
        let failures = ((data["failures"] as? [String]) ?? []).filter { !$0.isEmpty }
        if !failures.isEmpty {
            missing.append(contentsOf: failures.map { "\($0) (fetch failed)" })
        }

        return JDayPayload(
            dateKey: jStr(obj, ["date"]).isEmpty ? dateKey : jStr(obj, ["date"]),
            narrative: jStr(obj, ["narrative"]),
            place: jStr(data, ["place"]),
            weather: weather,
            health: health,
            items: items,
            missing: missing,
            updatedAt: JDates.parseWhen(jStr(obj, ["updated_at", "updatedAt"])),
            fetchedAt: Date())
    }

    /// The REAL trace off the wire: `route` = [[lat,lng],…] (≤120 points,
    /// Douglas-Peucker simplified) or null. Every pair is validated before
    /// MapKit sees it (the lat-999 assert class — same guard as HealthView);
    /// under 2 sane points it's no trace at all, and the caller falls back
    /// to the dwell-anchored straight line.
    private static func traceRoute(_ raw: Any?) -> JRoute? {
        guard let pairs = raw as? [[Any]] else { return nil }
        let coords: [CLLocationCoordinate2D] = pairs.compactMap { pair in
            guard pair.count >= 2,
                  let lat = (pair[0] as? NSNumber)?.doubleValue,
                  let lng = (pair[1] as? NSNumber)?.doubleValue else { return nil }
            let c = CLLocationCoordinate2D(latitude: lat, longitude: lng)
            guard CLLocationCoordinate2DIsValid(c),
                  abs(lat) > 0.0001 || abs(lng) > 0.0001 else { return nil }
            return c
        }
        guard coords.count >= 2 else { return nil }
        return JRoute(coords: coords, startPlace: "", endPlace: "", approximate: false)
    }

    /// FALLBACK when `route` is null (under 4 fixes): the dwells that bracket
    /// the movement window → the straight line "left HERE, arrived THERE" —
    /// approximate by construction. An anchor is only trusted within 45
    /// minutes of the move's edge; a loop (left home, came back) collapses
    /// to a single marker.
    private static func routeBetween(stays: [JStay], start: Date?, end: Date?) -> JRoute? {
        guard let start, let end, !stays.isEmpty else { return nil }
        let tolerance: TimeInterval = 45 * 60
        let slack: TimeInterval = 10 * 60   // dwell edges and move edges jitter
        let from = stays
            .filter { $0.end <= start.addingTimeInterval(slack) }
            .min { abs($0.end.timeIntervalSince(start)) < abs($1.end.timeIntervalSince(start)) }
        let to = stays
            .filter { $0.start >= end.addingTimeInterval(-slack) }
            .min { abs($0.start.timeIntervalSince(end)) < abs($1.start.timeIntervalSince(end)) }
        let a = from.flatMap { abs($0.end.timeIntervalSince(start)) <= tolerance ? $0 : nil }
        let b = to.flatMap { abs($0.start.timeIntervalSince(end)) <= tolerance ? $0 : nil }

        func close(_ x: CLLocationCoordinate2D, _ y: CLLocationCoordinate2D) -> Bool {
            abs(x.latitude - y.latitude) < 0.0005 && abs(x.longitude - y.longitude) < 0.0005
        }

        switch (a, b) {
        case let (aa?, bb?) where close(aa.coord, bb.coord):
            // Round trip — one anchor, same place both ends.
            return JRoute(coords: [aa.coord], startPlace: aa.place,
                          endPlace: bb.place, approximate: true)
        case let (aa?, bb?):
            return JRoute(coords: [aa.coord, bb.coord], startPlace: aa.place,
                          endPlace: bb.place, approximate: true)
        case let (aa?, nil):
            return JRoute(coords: [aa.coord], startPlace: aa.place,
                          endPlace: "", approximate: true)
        case let (nil, bb?):
            return JRoute(coords: [bb.coord], startPlace: "",
                          endPlace: bb.place, approximate: true)
        default:
            return nil
        }
    }

    private static func rangeLabel(_ start: Date?, _ end: Date?) -> String {
        guard let start else { return "" }
        guard let end else { return JDates.time.string(from: start) }
        return "\(JDates.time.string(from: start)) – \(JDates.time.string(from: end))"
    }

    /// Episode kinds carry their own icon (wire: meeting|visit|conversation|
    /// travel|meal|other).
    private static func episodeIcon(_ kind: String) -> String {
        switch kind {
        case "visit": return "mappin.and.ellipse"
        case "conversation": return "bubble.left.and.bubble.right.fill"
        case "travel": return "airplane"
        case "meal": return "fork.knife"
        case "meeting": return "person.2.fill"
        default: return "sparkles"
        }
    }
}

/// "6h 52m" / "42m" — local twin of HealthView's private formatter.
private enum HealthMin {
    static func text(_ min: Int) -> String {
        min >= 60 ? "\(min / 60)h \(min % 60)m" : "\(min)m"
    }
}

// MARK: - Month payload

struct JMonthDay: Identifiable {
    let dateKey: String
    let day: Date
    let steps: Int
    let km: Double
    let episodes: Int
    let meetings: Int
    let meals: Int
    let hasPins: Bool
    let weatherEmoji: String
    let place: String

    var id: String { dateKey }
    var hasData: Bool {
        steps > 0 || km > 0 || episodes > 0 || meetings > 0 || meals > 0
            || hasPins || !weatherEmoji.isEmpty
    }
}

// MARK: - Models

@MainActor
final class JournalDayModel: ObservableObject {
    /// Cache by day key — navigating back is instant; refreshes are deltas.
    @Published private(set) var days: [String: JDayPayload] = [:]
    @Published private(set) var loadingKey: String?
    @Published private(set) var engineDeploying = false
    @Published var error: String?

    func payload(for key: String) -> JDayPayload? { days[key] }

    /// Fetch one day. Cached content keeps painting while the refresh runs.
    func load(dateKey: String) async {
        guard loadingKey != dateKey else { return }
        loadingKey = dateKey
        // Scoped, not blanket: .task(id:) cancels this load when he swipes to
        // the NEXT day — a blanket `loadingKey = nil` here killed the new
        // day's own spinner state.
        defer { if loadingKey == dateKey { loadingKey = nil } }
        do {
            let tz = TimeZone.current.secondsFromGMT() / 60
            let obj = try await JWire.request("op=journal_day&date=\(dateKey)&tz=\(tz)")
            days[dateKey] = JDayParser.parse(obj, dateKey: dateKey)
            engineDeploying = false
            error = nil
        } catch JWireError.opMissing {
            engineDeploying = true
            error = nil
        } catch {
            // A swipe-cancelled fetch is not a failure — surfacing it painted
            // a phantom "Couldn't load this day" over a perfectly fine day.
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            // Keep whatever is on screen; only surface the failure when there
            // is nothing cached to show.
            self.error = days[dateKey] == nil
                ? "Couldn't load this day. Pull down to try again."
                : nil
        }
    }
}

@MainActor
final class JournalMonthModel: ObservableObject {
    @Published private(set) var months: [String: [JMonthDay]] = [:]
    @Published private(set) var loadingKey: String?
    @Published private(set) var engineDeploying = false
    @Published var error: String?

    func days(for key: String) -> [JMonthDay]? { months[key] }

    func load(monthKey: String) async {
        guard loadingKey != monthKey else { return }
        loadingKey = monthKey
        defer { if loadingKey == monthKey { loadingKey = nil } }
        do {
            let tz = TimeZone.current.secondsFromGMT() / 60
            let obj = try await JWire.request("op=journal_month&month=\(monthKey)&tz=\(tz)")
            // wire: one row per day WITH data — absent days render empty.
            // {date, steps|null, km|null, episodes, meetings, meals,
            //  has_pins, weather{icon,tmin,tmax}|null, place|null}
            let rows = (obj["days"] as? [[String: Any]]) ?? []
            months[monthKey] = rows.compactMap { r in
                let key = jStr(r, ["date"])
                guard let day = JDates.parseDayKey(key) else { return nil }
                let weather = r["weather"] as? [String: Any]
                return JMonthDay(
                    dateKey: key,
                    day: day,
                    steps: jInt(r, ["steps"]) ?? 0,
                    km: jNum(r, ["km"]) ?? 0,
                    episodes: jInt(r, ["episodes"]) ?? 0,
                    meetings: jInt(r, ["meetings"]) ?? 0,
                    meals: jInt(r, ["meals"]) ?? 0,
                    hasPins: (r["has_pins"] as? Bool) ?? false,
                    weatherEmoji: weather.map { jStr($0, ["icon", "emoji"]) } ?? "",
                    place: jStr(r, ["place"]))
            }
            engineDeploying = false
            error = nil
        } catch JWireError.opMissing {
            engineDeploying = true
            error = nil
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            self.error = months[monthKey] == nil
                ? "Couldn't load the month. Try again."
                : nil
        }
    }
}

struct JSearchEvidence: Identifiable {
    let id = UUID()
    let dateKey: String
    let kind: String
    let title: String
}

struct JSearchResult {
    let answer: String
    let days: [String]
    let evidence: [JSearchEvidence]
}

@MainActor
final class JournalSearchModel: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var result: JSearchResult?
    @Published private(set) var lastQuery = ""
    @Published private(set) var engineDeploying = false
    @Published var error: String?

    /// Fires on SUBMIT only (the query includes a model call server-side).
    func search(_ q: String) async {
        let query = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !running else { return }
        running = true
        lastQuery = query
        defer { running = false }
        do {
            let tz = TimeZone.current.secondsFromGMT() / 60
            let obj = try await JWire.request("op=journal_search", method: "POST",
                                              body: ["q": query, "tz": tz])
            let evidence = ((obj["evidence"] as? [[String: Any]]) ?? []).map { e in
                JSearchEvidence(dateKey: jStr(e, ["date", "day"]),
                                kind: jStr(e, ["kind", "type"]),
                                title: jStr(e, ["title", "summary", "name"]))
            }
            result = JSearchResult(
                answer: jStr(obj, ["answer"]),
                days: (obj["days"] as? [String]) ?? [],
                evidence: evidence)
            engineDeploying = false
            error = nil
        } catch JWireError.opMissing {
            engineDeploying = true
            error = nil
        } catch {
            self.error = "The search didn't go through — try again."
        }
    }

    func clear() {
        result = nil
        lastQuery = ""
        error = nil
    }
}

// MARK: - Root: the Journal section

/// The Journal tab / sidebar pane. Day browser by default; the date header
/// opens the month grid; search sits on top of both; the review lane pushes
/// from its banner. One NavigationStack, NO stacked sheets anywhere.
struct JournalView: View {
    @StateObject private var dayModel = JournalDayModel()
    @StateObject private var monthModel = JournalMonthModel()
    @StateObject private var searchModel = JournalSearchModel()
    /// The review lane's model lives here so the banner count and the pushed
    /// screen share one source of truth.
    @StateObject private var review = JournalModel()
    @EnvironmentObject private var convo: Conversation

    private enum Screen { case day, month, search }
    /// iPad/Mac = the MAIN work platform (doctrine §11): regular width gets
    /// a persistent two-pane layout — month grid on the left, the day (or
    /// search results) on the right — instead of full-screen mode swaps.
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var screen: Screen = .day
    @State private var selectedDay = JDates.cal.startOfDay(for: Date())
    /// First-of-month anchor for the month grid.
    @State private var monthAnchor = JDates.cal.startOfDay(for: Date())
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                headerBar
                searchBar
                if hSize == .regular {
                    regularSplit
                } else {
                    content
                }
            }
            .background(ScarletBackground().ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom) {
                ScarletPresenceView(convo: convo)
                    .padding(.vertical, 6)
            }
            // Work-surface keys: ←/→ walk days, T jumps to today, ⌘F focuses
            // search — silent twins of the visible controls (SignalReadView's
            // hidden-button pattern). The bare keys VANISH while the search
            // field has focus, or they would swallow his typing and the
            // text cursor's arrow keys.
            .background {
                Group {
                    if !searchFocused {
                        Button("") { step(-1) }
                            .keyboardShortcut(.leftArrow, modifiers: [])
                        Button("") { step(1) }
                            .keyboardShortcut(.rightArrow, modifiers: [])
                        Button("") { goToday() }
                            .keyboardShortcut("t", modifiers: [])
                    }
                    Button("") { searchFocused = true }
                        .keyboardShortcut("f", modifiers: .command)
                }
                .opacity(0)
                .accessibilityHidden(true)
            }
        }
        .task {
            FlightRecorder.note(screen: "journal")
            await review.load()
        }
        .onAppear { convo.setFocus(focusLine) }
        .onChange(of: selectedDay) { _, day in
            convo.setFocus(focusLine)
            // Regular width: the persistent month grid follows the day pane
            // across month boundaries (stepping ← past the 1st).
            if hSize == .regular,
               !JDates.cal.isDate(day, equalTo: monthAnchor, toGranularity: .month) {
                monthAnchor = day
            }
        }
        .onChange(of: screen) { _, _ in convo.setFocus(focusLine) }
    }

    // MARK: header (big heavy title, like Health)

    private var headerBar: some View {
        HStack(spacing: 12) {
            Text("Journal")
                .font(.system(size: 34, weight: .heavy))
                .foregroundStyle(.white)
            Spacer()
            if screen == .day, JDates.cal.isDateInToday(selectedDay),
               let p = dayModel.payload(for: selectedKey) {
                // The honest liveness stamp — today builds over the day.
                Text("as of \(JDates.time.string(from: p.updatedAt ?? p.fetchedAt)) · עדכני ל־\(JDates.time.string(from: p.updatedAt ?? p.fetchedAt))")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
            }
            if dayModel.loadingKey != nil || monthModel.loadingKey != nil || searchModel.running {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.5))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    // MARK: search (fires on submit, never per keystroke)

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
            TextField("Ask your journal — \"When was I in Greece?\"", text: $searchText)
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .focused($searchFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .multilineTextAlignment(searchText.isEmpty ? .leading : searchText.readingAlignment)
                .onSubmit { submitSearch() }
            if !searchText.isEmpty || screen == .search {
                Button {
                    searchText = ""
                    searchModel.clear()
                    if screen == .search { screen = .day }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(JStyle.card, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func submitSearch() {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        screen = .search
        Task { await searchModel.search(q) }
    }

    // MARK: regular-width work surface (doctrine §11)

    /// Month grid stays put on the left; picking a day updates the right
    /// pane in place — nothing tears down, nothing swaps full-screen. The
    /// right pane shows search results while a search is active.
    private var regularSplit: some View {
        HStack(spacing: 0) {
            JournalMonthScreen(
                model: monthModel,
                anchor: $monthAnchor,
                selectedDay: selectedDay,
                onPick: { day in
                    selectedDay = day
                    screen = .day
                },
                onClose: { screen = .day })
                .frame(width: 360)
            Divider().overlay(Color.white.opacity(0.08))
            Group {
                if screen == .search {
                    JournalSearchScreen(
                        model: searchModel,
                        onOpenDay: { key in
                            if let d = JDates.parseDayKey(key) {
                                selectedDay = d
                                screen = .day
                            }
                        })
                } else {
                    JournalDayScreen(
                        model: dayModel,
                        review: review,
                        day: selectedDay,
                        onStep: { step($0) },
                        onOpenMonth: { monthAnchor = selectedDay })
                        .environmentObject(convo)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: content switch

    @ViewBuilder
    private var content: some View {
        switch screen {
        case .day:
            JournalDayScreen(
                model: dayModel,
                review: review,
                day: selectedDay,
                onStep: { step($0) },
                onOpenMonth: {
                    monthAnchor = selectedDay
                    screen = .month
                })
                .environmentObject(convo) // Catalyst SIGTRAP class: re-inject across the screen switch
        case .month:
            JournalMonthScreen(
                model: monthModel,
                anchor: $monthAnchor,
                selectedDay: selectedDay,
                onPick: { day in
                    selectedDay = day
                    screen = .day
                },
                onClose: { screen = .day })
        case .search:
            JournalSearchScreen(
                model: searchModel,
                onOpenDay: { key in
                    if let d = JDates.parseDayKey(key) {
                        selectedDay = d
                        screen = .day
                    }
                })
        }
    }

    // MARK: navigation

    private var selectedKey: String { JDates.dayKey.string(from: selectedDay) }

    private func step(_ delta: Int) {
        guard screen == .day else { return }
        let next = JDates.cal.date(byAdding: .day, value: delta, to: selectedDay) ?? selectedDay
        // The journal has no tomorrow — never step past today.
        if next <= JDates.cal.startOfDay(for: Date()) {
            withAnimation(.snappy(duration: 0.25)) { selectedDay = next }
        }
    }

    private func goToday() {
        withAnimation(.snappy(duration: 0.25)) {
            selectedDay = JDates.cal.startOfDay(for: Date())
            screen = .day
        }
    }

    private var focusLine: String {
        switch screen {
        case .day:
            let title = JDates.title(for: selectedDay)
            let n = dayModel.payload(for: selectedKey)?.items.count ?? 0
            return "[FOCUS] Ido is on the Journal, reading the day summary for \(title)"
                + (n > 0 ? " (\(n) timeline items)." : ".")
                + " He can navigate between days, open the month view, or search his journal."
        case .month:
            return "[FOCUS] Ido is on the Journal's month view for \(JDates.monthTitle.string(from: monthAnchor))."
        case .search:
            return "[FOCUS] Ido searched his Journal for: \(searchModel.lastQuery)"
        }
    }
}

// MARK: - Day screen

struct JournalDayScreen: View {
    @ObservedObject var model: JournalDayModel
    @ObservedObject var review: JournalModel
    @EnvironmentObject private var convo: Conversation
    let day: Date
    let onStep: (Int) -> Void
    let onOpenMonth: () -> Void

    /// Same reading-size control (and stored value) as the signals reader —
    /// one habit across the app.
    @AppStorage("scarlet.readingSize") private var readingSize: Double = 17

    private var key: String { JDates.dayKey.string(from: day) }
    private var isToday: Bool { JDates.cal.isDateInToday(day) }
    private var payload: JDayPayload? { model.payload(for: key) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                dateNavRow
                if !review.cards.isEmpty {
                    reviewBanner
                }
                if let err = model.error {
                    Text(err)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if model.engineDeploying {
                    engineDeployingCard
                } else if let p = payload {
                    dayBody(p)
                } else if model.loadingKey == key {
                    loadingCard
                } else if model.error == nil {
                    // First load hasn't landed yet (or nothing cached).
                    loadingCard
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 2)
            .padding(.bottom, 16)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .refreshable { await model.load(dateKey: key) }
        // ← / → by hand: a horizontal swipe walks the days without stealing
        // the vertical scroll.
        .simultaneousGesture(
            DragGesture(minimumDistance: 40)
                .onEnded { v in
                    guard abs(v.translation.width) > abs(v.translation.height) * 1.5
                    else { return }
                    onStep(v.translation.width < 0 ? 1 : -1)
                }
        )
        // Load on entry AND every time the selected day changes; for TODAY,
        // keep the page ALIVE: poll every 3 minutes while it is on screen.
        .task(id: key) {
            await model.load(dateKey: key)
            guard isToday else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 180_000_000_000)
                guard !Task.isCancelled, JDates.cal.isDateInToday(day) else { return }
                await model.load(dateKey: key)
            }
        }
        // Coming back to the foreground refreshes today immediately.
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.willEnterForegroundNotification)) { _ in
            if isToday { Task { await model.load(dateKey: key) } }
        }
    }

    // MARK: date navigation row

    private var dateNavRow: some View {
        HStack(spacing: 10) {
            Button { onStep(-1) } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 34, height: 34)
                    .background(JStyle.card, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Previous day")

            // The date IS the month-view door.
            Button(action: onOpenMonth) {
                VStack(spacing: 2) {
                    HStack(spacing: 6) {
                        Text(JDates.title(for: day))
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    if let sub = headerSubtitle {
                        Text(sub)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open month view")

            Button { onStep(1) } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isToday ? .white.opacity(0.25) : .white.opacity(0.8))
                    .frame(width: 34, height: 34)
                    .background(JStyle.card, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(isToday)
            .accessibilityLabel("Next day")
        }
    }

    /// "Kfar Kisch · ☀️ Clear · H 31° · L 22°" — place + weather, header line.
    private var headerSubtitle: String? {
        guard let p = payload else { return nil }
        var bits: [String] = []
        if !p.place.isEmpty { bits.append(p.place) }
        if let w = p.weather {
            var wb = [w.emoji, w.words].filter { !$0.isEmpty }.joined(separator: " ")
            let strip = w.strip
            if !strip.isEmpty { wb = wb.isEmpty ? strip : wb + " · " + strip }
            if !wb.isEmpty { bits.append(wb) }
        }
        return bits.isEmpty ? nil : bits.joined(separator: " · ")
    }

    // MARK: review banner (the old Journal inbox, one push away)

    private var reviewBanner: some View {
        NavigationLink {
            JournalReviewScreen(model: review)
                // Catalyst drops @EnvironmentObject across the NavigationLink
                // boundary — re-inject (crash class fixed in Inbox/Signals).
                .environmentObject(convo)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "tray.full.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(JStyle.rose)
                Text(review.cards.count == 1
                     ? "1 entry waiting for your review"
                     : "\(review.cards.count) entries waiting for your review")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(12)
            .background(JStyle.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .strokeBorder(JStyle.rose.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: the day body

    // The day reads by IMPORTANCE (Ido's commission, 2026-08-21): header →
    // narrative → key moments (meetings with summaries + walks/workouts with
    // maps, one chronological thread) → the body + meals → pins → and an
    // appendix at the very end for everything thin or speculative. Nothing
    // speculative ever sits above the appendix line.
    @ViewBuilder
    private func dayBody(_ p: JDayPayload) -> some View {
        if p.isEmpty {
            quietEmptyDay
        } else {
            if !p.narrative.isEmpty {
                narrativeCard(p.narrative)
            }
            let key = p.items.filter { Self.isKeyMoment($0) }
            let meals = p.items.filter { $0.kind == .meal }
            let pins = p.items.filter { $0.kind == .pin }
            let appendix = p.items.filter { Self.isAppendix($0) }
            if !key.isEmpty {
                sectionLabel("Key moments", icon: "sparkles", tint: JStyle.amber)
                timeline(key)
            }
            if !p.health.isEmpty {
                JHealthFooter(health: p.health)
            }
            if !meals.isEmpty {
                mealsCard(meals)
            }
            if !pins.isEmpty {
                pinsCard(pins)
            }
            if !appendix.isEmpty || !p.missing.isEmpty {
                appendixSection(appendix, missing: p.missing)
            }
        }
    }

    /// Solid evidence, chronological: episodes with substance, plus every
    /// walk, transit hop and workout (movement is GPS truth, not speculation).
    private static func isKeyMoment(_ i: JDayItem) -> Bool {
        switch i.kind {
        case .walk, .transit, .workout: return true
        case .meeting: return !i.thin
        default: return false
        }
    }

    /// The appendix's material: episodes with no summary and weak evidence,
    /// and calendar rows nothing corroborated.
    private static func isAppendix(_ i: JDayItem) -> Bool {
        i.kind == .calendar || (i.kind == .meeting && i.thin)
    }

    /// Uppercase section label — the same voice as the in-card headers.
    private func sectionLabel(_ title: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
                .textCase(.uppercase)
                .kerning(0.8)
        }
        .padding(.top, 2)
    }

    // MARK: meals (rides with the body — fuel next to the engine)

    private func mealsCard(_ meals: [JDayItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "fork.knife")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(JStyle.amber)
                Text("Meals")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .textCase(.uppercase)
                    .kerning(0.8)
            }
            ForEach(meals) { m in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(m.timeLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 42, alignment: .trailing)
                    Text(m.title.isEmpty ? "Meal" : m.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .multilineTextAlignment(m.title.readingAlignment)
                        .environment(\.layoutDirection, m.title.layoutDir)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if !m.subtitle.isEmpty {
                        Text(m.subtitle)
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20).fill(JStyle.card))
    }

    // MARK: pins (recordings — pin conversations + synced recorder docs)

    private func pinRow(_ p: JDayItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Image(systemName: p.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(JStyle.rose)
                Text(p.title.isEmpty ? "Pinned conversation" : p.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .multilineTextAlignment(p.title.readingAlignment)
                    .environment(\.layoutDirection, p.title.layoutDir)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if !p.timeLabel.isEmpty {
                    Text(p.timeLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.5))
                }
                if p.sourceId != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
            if !p.subtitle.isEmpty {
                Text(p.subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.65))
                    .multilineTextAlignment(p.subtitle.readingAlignment)
                    .frame(maxWidth: .infinity, alignment: p.subtitle.readingFrameAlignment)
                    .environment(\.layoutDirection, p.subtitle.layoutDir)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(3)
            }
        }
        .contentShape(Rectangle())
    }

    private func pinsCard(_ pins: [JDayItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(JStyle.rose)
                Text("Pins")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .textCase(.uppercase)
                    .kerning(0.8)
            }
            ForEach(pins) { p in
                // Same rule as the timeline rows: a pin with a server-side
                // story behind it pushes the full conversation detail on the
                // Journal's NavigationStack. The tap-to-transcript commission
                // (2026-08-21) shipped for episodes but this card's rows were
                // plain VStacks — pins, THE main capture device's output,
                // never opened anywhere.
                Group {
                    if p.sourceId != nil {
                        NavigationLink { JItemDetailScreen(item: p) } label: { pinRow(p) }
                            .buttonStyle(.plain)
                    } else {
                        pinRow(p)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20).fill(JStyle.card))
    }

    // MARK: appendix — the thin and the uncaptured, visually muted, dead last

    private func appendixSection(_ items: [JDayItem], missing: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().overlay(Color.white.opacity(0.12))
                .padding(.top, 8)
            Text("Appendix")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
                .textCase(.uppercase)
                .kerning(0.8)
                .padding(.top, 2)
            ForEach(items) { i in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(i.timeLabel.components(separatedBy: " – ").first ?? "")
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.35))
                        .frame(width: 42, alignment: .trailing)
                    Image(systemName: i.icon)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.35))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(i.title.isEmpty ? appendixFallback(i) : i.title)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.55))
                            .multilineTextAlignment(i.title.readingAlignment)
                            .environment(\.layoutDirection, i.title.layoutDir)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineLimit(2)
                        if !i.subtitle.isEmpty || !i.place.isEmpty {
                            Text([i.subtitle, i.place].filter { !$0.isEmpty }
                                .joined(separator: " · "))
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.35))
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    if let chip = i.chip {
                        Text(chip)
                            .font(.system(size: 9, weight: .bold))
                            .textCase(.uppercase)
                            .kerning(0.4)
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }
            }
            if !missing.isEmpty {
                // The quiet honest line — never a wall of empty boxes.
                Text("Not captured this day: \(missing.joined(separator: ", ")).")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.35))
                    .padding(.top, 2)
            }
        }
    }

    private func appendixFallback(_ i: JDayItem) -> String {
        i.kind == .calendar ? "On the calendar" : "Untitled episode"
    }

    private var quietEmptyDay: some View {
        VStack(spacing: 10) {
            Image(systemName: "moon.stars")
                .font(.system(size: 34, weight: .thin))
                .foregroundStyle(.secondary)
            Text(isToday
                 ? "The day is just getting started — this page builds as it happens."
                 : "Nothing was captured on this day.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private var loadingCard: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Opening the day…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private var engineDeployingCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 34, weight: .thin))
                .foregroundStyle(.secondary)
            Text("The journal engine is deploying")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
            Text("This view needs the newest backend. It updates itself — nothing for you to do.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: narrative (the story of the day — big type, per-paragraph bidi)

    private func narrativeCard(_ narrative: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "text.book.closed.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(JStyle.rose)
                    Text("The day")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .textCase(.uppercase)
                        .kerning(0.8)
                }
                Spacer(minLength: 0)
                readingSizeControl
            }
            .padding(.bottom, 4)
            ForEach(Array(cleanNarrative(narrative).enumerated()), id: \.offset) { _, para in
                Text(para)
                    .font(.system(size: readingSize))
                    .lineSpacing(4)
                    .foregroundStyle(.white.opacity(0.92))
                    .textSelection(.enabled)
                    .multilineTextAlignment(para.readingAlignment)
                    .frame(maxWidth: .infinity, alignment: para.readingFrameAlignment)
                    .environment(\.layoutDirection, para.layoutDir)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 4)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20).fill(JStyle.card))
    }

    /// The narrative arrives with lightweight markdown emphasis
    /// (**bold** / __underline__ / ==mark==); strip the markers and split
    /// into paragraphs so each picks its own direction.
    private func cleanNarrative(_ s: String) -> [String] {
        var t = s
        for token in ["**", "__", "=="] {
            t = t.replacingOccurrences(of: token, with: "")
        }
        return t.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// A−/A+ — same steps and bounds as SignalReadView (shared @AppStorage).
    private var readingSizeControl: some View {
        HStack(spacing: 0) {
            Button {
                readingSize = max(15, readingSize - 2)
            } label: {
                Text("A−").font(.system(size: 12, weight: .semibold))
                    .frame(width: 30, height: 24)
            }
            .disabled(readingSize <= 15)
            Divider().frame(height: 14).overlay(Color.white.opacity(0.15))
            Button {
                readingSize = min(25, readingSize + 2)
            } label: {
                Text("A+").font(.system(size: 14, weight: .semibold))
                    .frame(width: 30, height: 24)
            }
            .disabled(readingSize >= 25)
        }
        .foregroundStyle(.white.opacity(0.8))
        .background(Color.white.opacity(0.08), in: Capsule())
        .buttonStyle(.plain)
    }

    // MARK: timeline

    private func timeline(_ items: [JDayItem]) -> some View {
        // One continuous thread BEHIND the rows (a per-row flexible line
        // collapses under fixedSize); dots sit on top of it. Dot centers:
        // gutter 42 + spacing 10 + half the 12pt spine column = 58.
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(width: 1.5)
                .padding(.leading, 57.25)
                .padding(.top, 18)
                .padding(.bottom, 24)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(items) { item in
                    JTimelineRow(item: item)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - One timeline row

private struct JTimelineRow: View {
    let item: JDayItem
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Time gutter — tabular so the column never wobbles.
            Text(gutterTime)
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 42, alignment: .trailing)
                .padding(.top, 12)

            // The dot on the shared thread (the opaque dot sits over the line).
            Circle()
                .fill(dimmed ? Color.white.opacity(0.35) : item.tint)
                .frame(width: 9, height: 9)
                .frame(width: 12)
                .padding(.top, 12)

            // Rows with a server-side story behind them (pin conversations,
            // episodes) push the full detail on the Journal's single
            // NavigationStack — never a sheet (Catalyst one-sheet rule).
            Group {
                if item.sourceId != nil {
                    NavigationLink { JItemDetailScreen(item: item) } label: { rowCard }
                        .buttonStyle(.plain)
                } else {
                    rowCard
                }
            }
            .padding(.bottom, 10)
        }
    }

    /// Tap the route snapshot → the spot opens in Apple Maps, zoomable with
    /// the real map behind it (Ido 2026-08-21). maps.apple.com routes to the
    /// native Maps app on iPhone/iPad/Mac.
    private func openAppleMaps(_ route: JRoute) {
        guard !route.coords.isEmpty else { return }
        let mid = route.coords[route.coords.count / 2]
        if let url = URL(string: "https://maps.apple.com/?ll=\(mid.latitude),\(mid.longitude)&z=15") {
            openURL(url)
        }
    }

    private var gutterTime: String {
        // Range labels ("9:15 – 10:00") keep only the start in the gutter;
        // the full range lives inside the card.
        item.timeLabel.components(separatedBy: " – ").first ?? ""
    }

    private var rowCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: item.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(item.tint)
                if !item.title.isEmpty {
                    Text(item.title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(dimmed ? .white.opacity(0.65) : .white)
                        .multilineTextAlignment(item.title.readingAlignment)
                        .environment(\.layoutDirection, item.title.layoutDir)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(fallbackTitle)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                }
                Spacer(minLength: 0)
                if let chip = item.chip {
                    Text(chip)
                        .font(.system(size: 10, weight: .bold))
                        .textCase(.uppercase)
                        .kerning(0.5)
                        .foregroundStyle(item.chipGood ? JStyle.mint : JStyle.amber)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background((item.chipGood ? JStyle.mint : JStyle.amber).opacity(0.14),
                                    in: Capsule())
                }
            }
            if item.timeLabel.contains("–") || !item.place.isEmpty {
                HStack(spacing: 6) {
                    if item.timeLabel.contains("–") {
                        Text(item.timeLabel)
                            .monospacedDigit()
                    }
                    if !item.place.isEmpty {
                        if item.timeLabel.contains("–") { Text("·") }
                        Text(item.place)
                            .lineLimit(1)
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.55))
            }
            if let route = item.route {
                JRouteMap(route: route, tint: item.tint)
                    .padding(.top, 2)
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: "arrow.up.forward.app.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(6)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { openAppleMaps(route) }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint(Text("Opens in Apple Maps"))
            }
            if !item.subtitle.isEmpty {
                // On mapped rows this line doubles as the map's caption —
                // duration · distance, straight under the snapshot.
                Text(item.subtitle)
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(item.subtitle.readingAlignment)
                    .frame(maxWidth: .infinity, alignment: item.subtitle.readingFrameAlignment)
                    .environment(\.layoutDirection, item.subtitle.layoutDir)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(4)
            }
            if let route = item.route, let note = Self.routeNote(route) {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
                    .multilineTextAlignment(note.readingAlignment)
                    .environment(\.layoutDirection, note.layoutDir)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14)
            .fill(Color.white.opacity(dimmed ? 0.035 : 0.06)))
    }

    /// Calendar-only rows (never became an episode) read quieter.
    private var dimmed: Bool { item.kind == .calendar }

    /// The honest word under an approximate map: where it ran, and that the
    /// line is endpoints, not the traced path.
    static func routeNote(_ route: JRoute) -> String? {
        guard route.approximate else { return nil }
        let a = route.startPlace, b = route.endPlace
        var where_: String
        if route.isLoop {
            let p = a.isEmpty ? b : a
            where_ = p.isEmpty ? "" : "Around \(p)"
        } else if !a.isEmpty && !b.isEmpty {
            where_ = a == b ? "Around \(a)" : "\(a) → \(b)"
        } else {
            where_ = [a, b].first { !$0.isEmpty } ?? ""
        }
        let honesty = "route shows start and end — the full trace isn't captured yet"
        return where_.isEmpty
            ? "Route shows start and end — the full trace isn't captured yet"
            : "\(where_) · \(honesty)"
    }

    private var fallbackTitle: String {
        switch item.kind {
        case .walk: return "Walk"
        case .transit: return "On the move"
        case .workout: return "Workout"
        case .meeting: return "Meeting"
        case .calendar: return "On the calendar"
        case .pin: return "Pinned conversation"
        case .meal: return "Meal"
        }
    }
}

// MARK: - Item detail (drill-down)

/// The full story behind one journal row (Ido 2026-08-21: "when you click on
/// it, you can go into more detail on that conversation"): a pin fetches its
/// COMPLETE transcript via op=journal_item (the day payload carries only a
/// 400-char excerpt); an episode fetches its full row (summary, people,
/// place). Pushed on the Journal's single NavigationStack — never a sheet.
private struct JItemDetailScreen: View {
    /// Same shared reading-size dial the narrative uses (17pt floor holds).
    @AppStorage("scarlet.readingSize") private var readingSize: Double = 17
    let item: JDayItem
    @State private var fullText = ""
    @State private var people: [String] = []
    @State private var loading = true
    @State private var loadError: String? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: item.icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(item.tint)
                    Text(item.timeLabel)
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.55))
                    if !item.place.isEmpty {
                        Text("· " + item.place)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                if !people.isEmpty {
                    Text(people.joined(separator: ", "))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
                if loading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 30)
                } else {
                    if let err = loadError {
                        Text(err)
                            .font(.system(size: 12))
                            .foregroundStyle(JStyle.amber)
                    }
                    // Mixed Hebrew/English: direction per paragraph, never
                    // per screen (TextDirection.swift rule).
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, p in
                        Text(p)
                            .font(.system(size: max(17, readingSize)))
                            .foregroundStyle(.white.opacity(0.88))
                            .multilineTextAlignment(p.readingAlignment)
                            .frame(maxWidth: .infinity, alignment: p.readingFrameAlignment)
                            .environment(\.layoutDirection, p.layoutDir)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(16)
        }
        .background(ScarletBackground().ignoresSafeArea())
        .navigationTitle(item.title.isEmpty ? "Detail" : item.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var paragraphs: [String] {
        let text = fullText.isEmpty ? item.subtitle : fullText
        return text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
    }

    private func load() async {
        guard let sid = item.sourceId, let kind = item.sourceKind else {
            loading = false
            return
        }
        do {
            let obj = try await JWire.request("op=journal_item&kind=\(kind)&id=\(sid)")
            if kind == "pin" {
                fullText = (obj["transcript"] as? String) ?? ""
            } else {
                fullText = (obj["summary"] as? String) ?? ""
                people = (obj["people"] as? [String]) ?? []
            }
        } catch {
            // The row's own excerpt still shows — say so, honestly.
            loadError = "Couldn't load the full text — showing the summary from the day page."
        }
        loading = false
    }
}

// MARK: - Route snapshot map (walks + outdoor workouts)

/// A non-interactive snapshot: fixed camera fitted to the route, start/end
/// markers, no gestures (scrolling glides over it). iOS 17 Map API —
/// MapPolyline in the MapContentBuilder, the same precedent as HealthView's
/// WorkoutDetailSheet. Approximate (endpoint-only) routes draw dashed.
private struct JRouteMap: View {
    let route: JRoute
    let tint: Color

    var body: some View {
        Map(initialPosition: .region(Self.region(for: route.coords))) {
            if route.coords.count >= 2 {
                MapPolyline(coordinates: route.coords)
                    .stroke(tint, style: StrokeStyle(
                        lineWidth: 3, lineCap: .round, lineJoin: .round,
                        dash: route.approximate ? [6, 6] : []))
            }
            if let first = route.coords.first {
                Annotation(route.isLoop ? "Start · End" : "Start",
                           coordinate: first) { marker(.green) }
            }
            if route.coords.count >= 2, let last = route.coords.last {
                Annotation("End", coordinate: last) { marker(tint) }
            }
        }
        .mapStyle(.standard(elevation: .flat))
        .allowsHitTesting(false)   // a snapshot, not a browser
        .frame(height: 132)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel("Route map")
    }

    private func marker(_ color: Color) -> some View {
        Circle().fill(color)
            .frame(width: 11, height: 11)
            .overlay(Circle().stroke(.white, lineWidth: 2))
    }

    /// The route's bounding box with breathing room; a lone anchor (loop)
    /// gets a fixed neighborhood-sized window. Same math as HealthView.
    private static func region(for coords: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        guard let first = coords.first else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                span: MKCoordinateSpan(latitudeDelta: 1, longitudeDelta: 1))
        }
        var minLat = first.latitude
        var maxLat = first.latitude
        var minLon = first.longitude
        var maxLon = first.longitude
        for c in coords {
            minLat = min(minLat, c.latitude)
            maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude)
            maxLon = max(maxLon, c.longitude)
        }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                           longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.5, 0.008),
                                   longitudeDelta: max((maxLon - minLon) * 1.5, 0.008)))
    }
}

// MARK: - Health footer strip

private struct JHealthFooter: View {
    let health: JDayHealth

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(JStyle.rose)
                Text("The body")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .textCase(.uppercase)
                    .kerning(0.8)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if let v = health.steps {
                        tile(v.formatted(), "steps", "figure.walk", JStyle.pink)
                    }
                    if let v = health.distanceKm {
                        tile(String(format: "%.1f", v), "km", "point.topleft.down.curvedto.point.bottomright.up", JStyle.sky)
                    }
                    if let v = health.exerciseMin {
                        tile("\(v)", "exercise min", "flame.fill", JStyle.amber)
                    }
                    if let v = health.hrvMs {
                        tile("\(v)", "HRV ms", "waveform.path.ecg", JStyle.mint)
                    }
                    if let v = health.restingHR {
                        tile("\(v)", "resting HR", "heart.fill", JStyle.rose)
                    }
                    if let v = health.activeKcal {
                        tile(v.formatted(), "kcal", "bolt.fill", JStyle.amber)
                    }
                    if let v = health.sleepMin {
                        tile(HealthMin.text(v), "sleep", "moon.zzz.fill", JStyle.sky)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20).fill(JStyle.card))
    }

    private func tile(_ value: String, _ label: String, _ icon: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint)
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .textCase(.uppercase)
                    .kerning(0.4)
            }
            Text(value)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
    }
}

// MARK: - Month screen

struct JournalMonthScreen: View {
    @ObservedObject var model: JournalMonthModel
    @Binding var anchor: Date
    let selectedDay: Date
    let onPick: (Date) -> Void
    let onClose: () -> Void

    private var monthKey: String { JDates.monthKey.string(from: anchor) }
    private var byKey: [String: JMonthDay] {
        // uniquing keeps us safe if the wire ever repeats a date.
        Dictionary((model.days(for: monthKey) ?? []).map { ($0.dateKey, $0) },
                   uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                monthNavRow
                if model.engineDeploying {
                    VStack(spacing: 10) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 30, weight: .thin))
                            .foregroundStyle(.secondary)
                        Text("The journal engine is deploying — the month view arrives with it.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.vertical, 50)
                } else {
                    weekdayHeader
                    grid
                    if let err = model.error {
                        Text(err)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 2)
            .padding(.bottom, 16)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .refreshable { await model.load(monthKey: monthKey) }
        .task(id: monthKey) { await model.load(monthKey: monthKey) }
    }

    private var monthNavRow: some View {
        HStack(spacing: 10) {
            Button { stepMonth(-1) } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 34, height: 34)
                    .background(JStyle.card, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Previous month")

            // Tapping the month title folds back to the day view — the same
            // door the day header opened, swinging the other way.
            Button(action: onClose) {
                HStack(spacing: 6) {
                    Text(JDates.monthTitle.string(from: anchor))
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to day view")

            Button { stepMonth(1) } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isCurrentMonth ? .white.opacity(0.25) : .white.opacity(0.8))
                    .frame(width: 34, height: 34)
                    .background(JStyle.card, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(isCurrentMonth)
            .accessibilityLabel("Next month")
        }
    }

    private var isCurrentMonth: Bool {
        JDates.cal.isDate(anchor, equalTo: Date(), toGranularity: .month)
    }

    private func stepMonth(_ delta: Int) {
        guard let next = JDates.cal.date(byAdding: .month, value: delta, to: anchor)
        else { return }
        // No future months — the journal records, it doesn't predict.
        if delta < 0 || !JDates.cal.isDate(anchor, equalTo: Date(), toGranularity: .month) {
            withAnimation(.snappy(duration: 0.25)) { anchor = next }
        }
    }

    private var weekdayHeader: some View {
        let symbols = JDates.cal.veryShortWeekdaySymbols
        let first = JDates.cal.firstWeekday - 1
        let ordered = Array(symbols[first...] + symbols[..<first])
        return HStack(spacing: 6) {
            ForEach(Array(ordered.enumerated()), id: \.offset) { _, s in
                Text(s)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var grid: some View {
        let cells = monthCells
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7),
                         spacing: 6) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                if let day = cell {
                    JMonthCell(
                        day: day,
                        stats: byKey[JDates.dayKey.string(from: day)],
                        isToday: JDates.cal.isDateInToday(day),
                        isSelected: JDates.cal.isDate(day, inSameDayAs: selectedDay),
                        isFuture: day > JDates.cal.startOfDay(for: Date()),
                        onTap: { onPick(day) })
                } else {
                    Color.clear.frame(height: 58)
                }
            }
        }
    }

    /// The month laid on a weekday grid — leading nils pad to the first
    /// weekday, per the user's calendar (Sunday-first in Israel/US).
    private var monthCells: [Date?] {
        guard let interval = JDates.cal.dateInterval(of: .month, for: anchor),
              let dayCount = JDates.cal.range(of: .day, in: .month, for: anchor)?.count
        else { return [] }
        let first = interval.start
        let weekday = JDates.cal.component(.weekday, from: first)
        let lead = (weekday - JDates.cal.firstWeekday + 7) % 7
        var cells: [Date?] = Array(repeating: nil, count: lead)
        for d in 0..<dayCount {
            cells.append(JDates.cal.date(byAdding: .day, value: d, to: first))
        }
        return cells
    }
}

// MARK: - One month cell

private struct JMonthCell: View {
    let day: Date
    let stats: JMonthDay?
    let isToday: Bool
    let isSelected: Bool
    let isFuture: Bool
    let onTap: () -> Void

    private var hasData: Bool { stats?.hasData ?? false }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 3) {
                Text("\(JDates.cal.component(.day, from: day))")
                    .font(.system(size: 13, weight: isToday ? .bold : .semibold))
                    .monospacedDigit()
                    .foregroundStyle(numberColor)
                // Compact signals: weather emoji, meeting dots, steps badge.
                Group {
                    if let s = stats, s.hasData {
                        VStack(spacing: 2) {
                            HStack(spacing: 2) {
                                if !s.weatherEmoji.isEmpty {
                                    Text(s.weatherEmoji).font(.system(size: 9))
                                }
                                if s.meetings > 0 {
                                    HStack(spacing: 1.5) {
                                        ForEach(0..<min(s.meetings, 4), id: \.self) { _ in
                                            Circle().fill(JStyle.sky)
                                                .frame(width: 3.5, height: 3.5)
                                        }
                                    }
                                }
                                if s.hasPins {
                                    Circle().fill(JStyle.rose)
                                        .frame(width: 3.5, height: 3.5)
                                }
                            }
                            if s.steps > 0 {
                                Text(stepsBadge(s.steps))
                                    .font(.system(size: 8, weight: .bold))
                                    .monospacedDigit()
                                    .foregroundStyle(JStyle.pink.opacity(0.9))
                            }
                        }
                    } else {
                        // Quietly dimmed — a day with nothing recorded.
                        Text(" ").font(.system(size: 9))
                    }
                }
                .frame(height: 22)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .background(RoundedRectangle(cornerRadius: 10).fill(cellFill))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(borderColor, lineWidth: isToday || isSelected ? 1.5 : 0))
            .opacity(isFuture ? 0.25 : (hasData ? 1 : 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(isFuture)
        .accessibilityLabel(Text(JDates.dayTitle.string(from: day)))
    }

    private var numberColor: Color {
        if isToday { return JStyle.rose }
        return hasData ? .white : .white.opacity(0.55)
    }
    private var cellFill: Color {
        Color.white.opacity(hasData ? 0.07 : 0.03)
    }
    private var borderColor: Color {
        if isSelected { return .white.opacity(0.6) }
        if isToday { return JStyle.rose.opacity(0.8) }
        return .clear
    }

    private func stepsBadge(_ steps: Int) -> String {
        steps >= 1000 ? String(format: "%.0fk", Double(steps) / 1000) : "\(steps)"
    }
}

// MARK: - Search screen

struct JournalSearchScreen: View {
    @ObservedObject var model: JournalSearchModel
    let onOpenDay: (String) -> Void

    @AppStorage("scarlet.readingSize") private var readingSize: Double = 17

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if model.running {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Reading your journal…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
                } else if model.engineDeploying {
                    VStack(spacing: 10) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 30, weight: .thin))
                            .foregroundStyle(.secondary)
                        Text("The journal engine is deploying — search arrives with it.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
                } else if let err = model.error {
                    Text(err)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 30)
                } else if let r = model.result {
                    results(r)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 2)
            .padding(.bottom, 16)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private func results(_ r: JSearchResult) -> some View {
        if r.answer.isEmpty && r.days.isEmpty && r.evidence.isEmpty {
            // Honest empty state — she looked and found nothing.
            VStack(spacing: 10) {
                Image(systemName: "text.magnifyingglass")
                    .font(.system(size: 30, weight: .thin))
                    .foregroundStyle(.secondary)
                Text("Nothing in the journal matches \"\(model.lastQuery)\".")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 60)
        } else {
            if !r.answer.isEmpty {
                answerCard(r.answer)
            }
            if !r.days.isEmpty {
                dayChips(r.days)
            }
            if !r.evidence.isEmpty {
                evidenceList(r.evidence)
            }
        }
    }

    private func answerCard(_ answer: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(answer.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .enumerated()), id: \.offset) { _, para in
                Text(para)
                    .font(.system(size: max(17, readingSize)))
                    .lineSpacing(4)
                    .foregroundStyle(.white.opacity(0.92))
                    .textSelection(.enabled)
                    .multilineTextAlignment(para.readingAlignment)
                    .frame(maxWidth: .infinity, alignment: para.readingFrameAlignment)
                    .environment(\.layoutDirection, para.layoutDir)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20).fill(JStyle.card))
    }

    /// Tappable day chips — straight to that day's page.
    private func dayChips(_ days: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(days, id: \.self) { key in
                    Button {
                        onOpenDay(key)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "calendar")
                                .font(.system(size: 11, weight: .semibold))
                            Text(chipLabel(key))
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(JStyle.rose.opacity(0.22), in: Capsule())
                        .overlay(Capsule().strokeBorder(JStyle.rose.opacity(0.5), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func chipLabel(_ key: String) -> String {
        JDates.parseDayKey(key).map { JDates.chip.string(from: $0) } ?? key
    }

    /// The receipts, quietly.
    private func evidenceList(_ evidence: [JSearchEvidence]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("From the journal")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .textCase(.uppercase)
                .kerning(0.6)
                .padding(.bottom, 6)
            ForEach(evidence) { e in
                Button {
                    if !e.dateKey.isEmpty { onOpenDay(e.dateKey) }
                } label: {
                    HStack(spacing: 8) {
                        Text(chipLabel(e.dateKey))
                            .font(.system(size: 12, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.55))
                            .frame(width: 86, alignment: .leading)
                        Text(e.title.isEmpty ? e.kind : e.title)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.8))
                            .multilineTextAlignment(e.title.readingAlignment)
                            .environment(\.layoutDirection, e.title.layoutDir)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider().overlay(Color.white.opacity(0.06))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.04)))
    }
}
