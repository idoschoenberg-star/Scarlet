import SwiftUI
import HealthKit
import MapKit
import Charts

/// The Health tab, v2 — a period-browsable dashboard that joins Apple Health
/// and Withings:
///
/// - Today | Week | Month browser up top; everything re-scopes with it.
/// - The hero glance: activity rings (Today) or period totals, plus a
///   sleep-last-night pill (Withings score when present) and a
///   weight-this-morning pill (latest Withings weight vs 7-day average).
/// - Training Balance: strength vs cardio minutes per day, stacked — the
///   "if I do weight work and steps, I want to see the difference" card.
/// - Sleep from two sources, honestly: Withings nights (score, stages,
///   night HR) preferred, Apple Health as fallback, per night.
/// - Body: Withings weight with 7-day moving average, fat %, muscle,
///   hydration.
/// - Heart: resting HR + HRV trends.
/// - Workouts grouped by day, tinted by category, with route-map details.
///
/// All data comes from HealthSync.shared, which paints instantly from its
/// local cache (Documents/health-cache.json) and refreshes live — the
/// "updated Xm ago" stamp in the header is the honest freshness signal.

// MARK: - Palette (the rose accent family + a warm amber for cardio/body)

private enum HealthStyle {
    static let rose = Color(red: 1, green: 0.35, blue: 0.42)
    static let amber = Color(red: 1, green: 0.72, blue: 0.30)
    static let peach = Color(red: 1, green: 0.62, blue: 0.38)
    static let pink = Color(red: 0.96, green: 0.42, blue: 0.75)
    static let sleepDeep = Color(red: 0.35, green: 0.42, blue: 0.95)
    static let sleepREM = Color(red: 0.45, green: 0.72, blue: 0.98)
    static let sleepLight = Color(red: 0.62, green: 0.55, blue: 0.98)
    static let sleepAwake = Color(red: 0.98, green: 0.65, blue: 0.35)
    static let heartRed = Color(red: 0.98, green: 0.35, blue: 0.38)

    static func workoutIcon(_ kind: String) -> String {
        switch kind {
        case "walking": return "figure.walk"
        case "running": return "figure.run"
        case "cycling": return "figure.outdoor.cycle"
        case "swimming": return "figure.pool.swim"
        case "hiking": return "figure.hiking"
        case "yoga": return "figure.yoga"
        case "rowing": return "figure.rower"
        case "elliptical": return "figure.elliptical"
        case "tennis": return "figure.tennis"
        case "pickleball": return "figure.pickleball"
        case "hiit": return "figure.highintensity.intervaltraining"
        case "core": return "figure.core.training"
        case "strength": return "dumbbell.fill"
        default: return "figure.mixed.cardio"
        }
    }

    /// Strength = rose, cardio = amber, other = pink — the same hues the
    /// Training Balance chart uses, so the whole page reads as one system.
    static func categoryTint(_ kind: String) -> Color {
        switch WorkoutCategory.classify(kind) {
        case .strength: return rose
        case .cardio: return amber
        case .other: return pink
        }
    }
}

// MARK: - Shared formatting

private enum HealthFmt {
    /// "6h 52m" / "42m"
    static func minutes(_ min: Int) -> String {
        min >= 60 ? "\(min / 60)h \(min % 60)m" : "\(min)m"
    }
    /// "3.2 km" / "450 m"
    static func distance(_ meters: Int) -> String {
        meters >= 1000
            ? String(format: "%.1f km", Double(meters) / 1000)
            : "\(meters) m"
    }
    /// "5'32\" /km" — average pace, or "—" when not applicable.
    static func pace(distanceM: Int, seconds: Int) -> String {
        guard distanceM > 0, seconds > 0 else { return "—" }
        let secPerKm = Int(Double(seconds) / (Double(distanceM) / 1000))
        return "\(secPerKm / 60)'\(String(format: "%02d", secPerKm % 60))\" /km"
    }
    /// "Fri, Aug 1 · 7:05"
    static let workoutDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d · H:mm"
        return f
    }()
    /// "Friday, Aug 1" — workout group headers.
    static let dayHeader: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMM d"
        return f
    }()

    static func dayHeaderText(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        return dayHeader.string(from: day)
    }
}

// MARK: - Period browser

private enum HealthPeriod: String, CaseIterable, Identifiable {
    case today = "Today"
    case week = "Week"
    case month = "Month"

    var id: String { rawValue }
    /// The literal scope (workout list, hero totals).
    var windowDays: Int {
        switch self {
        case .today: return 1
        case .week: return 7
        case .month: return 30
        }
    }
    /// Chart context: even "Today" charts show the surrounding week.
    var chartDays: Int { self == .month ? 30 : 7 }
}

// MARK: - Focus lines

/// The workout sheet's focus line — built purely from row data so appear and
/// dismissal agree byte-for-byte.
private func workoutFocus(_ w: HealthWorkout) -> String {
    var line = "[FOCUS] Ido opened a workout from Apple Health: \(w.kind) on "
        + "\(HealthFmt.workoutDay.string(from: w.start)), "
        + "\(HealthFmt.minutes(w.durationMin))"
    if w.distanceM > 0 { line += ", \(HealthFmt.distance(w.distanceM))" }
    if w.kcal > 0 { line += ", \(w.kcal) kcal" }
    if w.avgHR > 0 { line += ", avg HR \(w.avgHR)" }
    line += w.route.isEmpty ? "." : ". He is looking at its route map."
    return line
}

// MARK: - Chart axis helpers (shared dark styling)

private extension View {
    func healthYAxis() -> some View {
        chartYAxis {
            AxisMarks { _ in
                AxisGridLine().foregroundStyle(.white.opacity(0.08))
                AxisValueLabel().foregroundStyle(.white.opacity(0.45))
            }
        }
    }

    @ViewBuilder
    func healthXAxis(days window: Int) -> some View {
        if window <= 7 {
            chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.narrow))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
        } else {
            chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                    AxisValueLabel(format: .dateTime.day())
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
        }
    }
}

// MARK: - Small chart shapes

private struct MetricPoint: Identifiable {
    let date: Date
    let value: Double
    var id: String { "\(date.timeIntervalSince1970)-\(value)" }
}

private struct BalanceEntry: Identifiable {
    let date: Date
    let category: String    // "Strength" | "Cardio"
    let minutes: Int
    var id: String { "\(date.timeIntervalSince1970)-\(category)" }
}

private struct StageEntry: Identifiable {
    let date: Date
    let stage: String       // "Deep" | "REM" | "Light" | "Awake"
    let minutes: Int
    var id: String { "\(date.timeIntervalSince1970)-\(stage)" }
}

/// One night, source-resolved: Withings (score, night HR) preferred,
/// Apple Health as fallback.
private struct NightUI: Identifiable {
    let date: Date
    let deep: Int
    let rem: Int
    let light: Int
    let awake: Int
    let score: Int          // 0 = no Withings score
    let hr: Int             // 0 = no night HR
    let source: String      // "Withings" | "Apple Health"
    var total: Int { deep + rem + light }
    var id: Date { date }
}

// MARK: - Health page

struct HealthView: View {
    @ObservedObject private var sync = HealthSync.shared
    @EnvironmentObject private var convo: Conversation

    /// The period browser — everything below it re-scopes.
    @State private var period: HealthPeriod = .today
    /// Tapped workout → detail sheet (stats + route map).
    @State private var selectedWorkout: HealthWorkout?
    /// The exact focus line last claimed for an open workout; the sheet's
    /// dismissal restores the page focus only if this still owns it
    /// (InboxView's stale-guard pattern).
    @State private var openedFocus: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                headerBar
                content
            }
            .scarletScreen()
            // Scarlet lives at the bottom of the list screen, part of its
            // layout — same pattern as ChatsView / InboxView / LibraryView.
            .safeAreaInset(edge: .bottom) {
                ScarletPresenceView(convo: convo)
                    .padding(.vertical, 6)
            }
            .toolbar(.hidden, for: .navigationBar)
            .onAppear { convo.setFocus(pageFocus()) }
            .onChange(of: period) { _, _ in convo.setFocus(pageFocus()) }
            .reportsModalPresence(selectedWorkout != nil)
            .sheet(item: $selectedWorkout, onDismiss: { restoreBrowsingFocus() }) { w in
                WorkoutDetailSheet(workout: w)
                    .preferredColorScheme(.dark)
            }
        }
        // .task re-runs every time this tab is selected → refresh on appear.
        // (The cache already painted; this refreshes deltas in background.)
        // `refresh()` routes itself: HealthKit read+push on iPhone/iPad, a
        // server-only overview load on Mac Catalyst — so the Mac pulls the
        // freshest iPhone-pushed data the moment the tab appears or foregrounds.
        .task { await sync.refresh() }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.willEnterForegroundNotification)) { _ in
            Task { await sync.refresh() }
        }
    }

    // MARK: header (big heavy title + freshness stamp + refresh)

    private var headerBar: some View {
        HStack(spacing: 12) {
            Text("Health")
                .font(.system(size: 34, weight: .heavy))
                .foregroundStyle(.white)
            Spacer()
            if sync.syncing {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.5))
            }
            // The honest freshness signal — offline, this stamp is the
            // whole story: cached data, this old, never a blank screen.
            if let updated = sync.lastUpdated {
                (Text("updated ") + Text(updated, style: .relative) + Text(" ago"))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
            }
            Button {
                Task { await sync.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white)
            }
            // Not gated on HealthKit authorization: on the Mac (no HealthKit)
            // this button still pulls the server overview.
            .disabled(sync.syncing)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    // MARK: content

    @ViewBuilder
    private var content: some View {
        if sync.available && !sync.authorized && !sync.hasData {
            // iPhone/iPad first run: HealthKit is present but not yet granted,
            // and nothing is cached — offer the connect flow.
            explainer(
                icon: "heart.text.square.fill",
                title: "Connect Apple Health",
                text: "Scarlet reads your activity, sleep, heart and workouts "
                    + "so you can see them here — joined with your Withings "
                    + "data — and ask her about any of it. Nothing is written "
                    + "back to Health.",
                showConnect: true
            )
        } else if sync.hasData {
            // The populated dashboard — whether the data came from HealthKit
            // (iPhone/iPad) or purely from the server overview (Mac Catalyst).
            dashboard
        } else if sync.syncing {
            VStack(spacing: 10) {
                ProgressView()
                Text(sync.available ? "Reading Apple Health…" : "Loading your health data…")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // Authorized (or Mac) but nothing came back yet.
            explainer(
                icon: "heart.text.square",
                title: "Nothing yet",
                text: sync.available
                    ? "No health data came back. If you just connected, check "
                        + "that Scarlet's categories are on in the Health app, then sync."
                    : "No health data has synced from your iPhone or Withings yet. "
                        + "Open the Health tab on your iPhone to push the latest, then sync here.",
                showConnect: false,
                showSyncButton: true
            )
        }
    }

    private func explainer(icon: String, title: String, text: String,
                           showConnect: Bool, showSyncButton: Bool = false) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundStyle(HealthStyle.rose)
            Text(title)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if showConnect {
                Button {
                    Task {
                        await sync.requestAccess()
                        await sync.refresh()
                    }
                } label: {
                    Label("Connect Apple Health", systemImage: "heart.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(HealthStyle.rose)
                .padding(.top, 6)
            }
            if showSyncButton {
                Button("Sync now") { Task { await sync.refresh() } }
                    .buttonStyle(.bordered)
                    .tint(HealthStyle.rose)
            }
            if !sync.errorText.isEmpty {
                Text(sync.errorText)
                    .font(.footnote)
                    .foregroundStyle(Color(red: 0.91, green: 0.69, blue: 0.31))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: dashboard

    private var dashboard: some View {
        ScrollView {
            VStack(spacing: 14) {
                if !sync.errorText.isEmpty {
                    Text(sync.errorText)
                        .font(.footnote)
                        .foregroundStyle(Color(red: 0.91, green: 0.69, blue: 0.31))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 2)
                }
                PeriodPicker(period: $period)
                heroCard
                trainingBalanceCard
                sleepCard
                bodyCard
                heartCard
                if period != .today {
                    stepsCard
                }
                workoutsSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 12)
            .animation(.snappy(duration: 0.35), value: period)
        }
        .scrollIndicators(.hidden)
        .refreshable { await sync.refresh() }
    }

    /// The shared card shell — 20 pt radius, small-caps header, generous air.
    private func card<Content: View>(_ title: String, icon: String, tint: Color,
                                     @ViewBuilder body: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
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
            body()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20).fill(.white.opacity(0.06)))
    }

    // MARK: data scoping helpers

    /// The most recent `n` days of the merged model, by date.
    private func daysWindow(_ n: Int) -> [HealthDay] {
        let cal = Calendar.current
        let cutoff = cal.date(byAdding: .day, value: -(n - 1),
                              to: cal.startOfDay(for: Date())) ?? .distantPast
        return sync.days.filter { $0.date >= cutoff }
    }

    /// Workouts inside the literal period window (Today → today only).
    private var scopedWorkouts: [HealthWorkout] {
        let cal = Calendar.current
        let cutoff = cal.date(byAdding: .day, value: -(period.windowDays - 1),
                              to: cal.startOfDay(for: Date())) ?? .distantPast
        return sync.workouts.filter { $0.start >= cutoff }
    }

    private var groupedWorkouts: [(day: Date, items: [HealthWorkout])] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: scopedWorkouts) { cal.startOfDay(for: $0.start) }
        return groups.keys.sorted(by: >).map { day in
            (day: day, items: (groups[day] ?? []).sorted { $0.start > $1.start })
        }
    }

    // MARK: HERO — the one-glance composition

    private var heroTitle: String {
        switch period {
        case .today: return "Today"
        case .week: return "This Week"
        case .month: return "This Month"
        }
    }

    private var heroCard: some View {
        card(heroTitle, icon: "sparkles", tint: HealthStyle.rose) {
            VStack(spacing: 14) {
                if period == .today {
                    HStack(spacing: 0) {
                        StatRing(value: Double(sync.todaySnapshot.steps), goal: 8000,
                                 label: "Steps", text: sync.todaySnapshot.steps.formatted(),
                                 color: HealthStyle.pink)
                        StatRing(value: Double(sync.todaySnapshot.activeKcal), goal: 500,
                                 label: "Active", text: "\(sync.todaySnapshot.activeKcal) kcal",
                                 color: HealthStyle.rose)
                        StatRing(value: Double(sync.todaySnapshot.exerciseMin), goal: 30,
                                 label: "Exercise", text: "\(sync.todaySnapshot.exerciseMin) min",
                                 color: HealthStyle.peach)
                    }
                } else {
                    periodStatsGrid
                }
                HStack(spacing: 10) {
                    sleepPill
                    weightPill
                }
            }
        }
    }

    private var periodStatsGrid: some View {
        let ds = daysWindow(period.windowDays)
        let active = ds.filter { $0.steps > 0 }
        let avgSteps = active.isEmpty ? 0 : active.map(\.steps).reduce(0, +) / active.count
        let kcal = ds.map(\.activeKcal).reduce(0, +)
        let exMin = ds.map(\.exerciseMin).reduce(0, +)
        let sessions = scopedWorkouts.count
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                         spacing: 14) {
            HeroStat(value: avgSteps.formatted(), label: "avg steps / day",
                     tint: HealthStyle.pink)
            HeroStat(value: "\(kcal.formatted()) kcal", label: "active energy",
                     tint: HealthStyle.rose)
            HeroStat(value: HealthFmt.minutes(exMin), label: "exercise",
                     tint: HealthStyle.peach)
            HeroStat(value: "\(sessions)", label: sessions == 1 ? "workout" : "workouts",
                     tint: HealthStyle.amber)
        }
    }

    @ViewBuilder
    private var sleepPill: some View {
        if let n = latestNight {
            GlancePill(icon: "moon.zzz.fill", tint: HealthStyle.sleepREM,
                       value: HealthFmt.minutes(n.total),
                       sub: n.score > 0 ? "sleep score \(n.score)" : "last night · \(n.source)")
        } else {
            GlancePill(icon: "moon.zzz", tint: HealthStyle.sleepREM,
                       value: "—", sub: "no sleep yet")
        }
    }

    @ViewBuilder
    private var weightPill: some View {
        if let w = latestWeight {
            GlancePill(icon: "scalemass.fill", tint: HealthStyle.amber,
                       value: String(format: "%.1f kg", w.value),
                       sub: weightDeltaText)
        } else {
            GlancePill(icon: "scalemass", tint: HealthStyle.amber,
                       value: "—", sub: "no Withings weight")
        }
    }

    // MARK: TRAINING BALANCE — weights vs steps, the explicit ask

    private var balanceWindow: Int { period == .month ? 30 : 7 }

    private var balanceEntries: [BalanceEntry] {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let cutoff = cal.date(byAdding: .day, value: -(balanceWindow - 1),
                              to: todayStart) ?? todayStart
        var strength: [Date: Int] = [:]
        var cardio: [Date: Int] = [:]
        for w in sync.workouts where w.start >= cutoff {
            let day = cal.startOfDay(for: w.start)
            switch WorkoutCategory.classify(w.kind) {
            case .strength: strength[day, default: 0] += w.durationMin
            case .cardio: cardio[day, default: 0] += w.durationMin
            case .other: break
            }
        }
        var out: [BalanceEntry] = []
        for i in 0..<balanceWindow {
            guard let day = cal.date(byAdding: .day, value: -i, to: todayStart) else { continue }
            out.append(BalanceEntry(date: day, category: "Strength",
                                    minutes: strength[day] ?? 0))
            out.append(BalanceEntry(date: day, category: "Cardio",
                                    minutes: cardio[day] ?? 0))
        }
        return out.sorted { $0.date < $1.date }
    }

    private var balanceSummary: (sSessions: Int, sMin: Int, cSessions: Int,
                                 cMin: Int, oMin: Int) {
        let cal = Calendar.current
        let cutoff = cal.date(byAdding: .day, value: -(balanceWindow - 1),
                              to: cal.startOfDay(for: Date())) ?? .distantPast
        var s = 0, sm = 0, c = 0, cm = 0, om = 0
        for w in sync.workouts where w.start >= cutoff {
            switch WorkoutCategory.classify(w.kind) {
            case .strength:
                s += 1
                sm += w.durationMin
            case .cardio:
                c += 1
                cm += w.durationMin
            case .other:
                om += w.durationMin
            }
        }
        return (s, sm, c, cm, om)
    }

    private var balanceReadout: String {
        let b = balanceSummary
        let prefix = period == .month ? "This month" : "This week"
        let strengthPart = b.sSessions == 1
            ? "1 strength session" : "\(b.sSessions) strength sessions"
        var line = "\(prefix): \(strengthPart) · \(b.cMin) cardio minutes"
        if b.oMin > 0 { line += " · \(b.oMin) other min" }
        return line
    }

    private var trainingBalanceCard: some View {
        card("Training Balance", icon: "dumbbell.fill", tint: HealthStyle.rose) {
            let b = balanceSummary
            VStack(alignment: .leading, spacing: 10) {
                Text(balanceReadout)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                if b.sMin == 0 && b.cMin == 0 {
                    Text("No workouts \(period == .month ? "this month" : "this week") "
                        + "yet — strength vs cardio will show up here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    balanceChart
                    HStack(spacing: 14) {
                        LegendChip(color: HealthStyle.rose,
                                   text: "Strength \(HealthFmt.minutes(b.sMin))")
                        LegendChip(color: HealthStyle.amber,
                                   text: "Cardio \(HealthFmt.minutes(b.cMin))")
                        if b.oMin > 0 {
                            LegendChip(color: HealthStyle.pink,
                                       text: "Other \(HealthFmt.minutes(b.oMin))")
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private var balanceChart: some View {
        Chart(balanceEntries) { e in
            BarMark(
                x: .value("Day", e.date, unit: .day),
                y: .value("Minutes", e.minutes)
            )
            .foregroundStyle(by: .value("Type", e.category))
            .cornerRadius(3)
        }
        .chartForegroundStyleScale([
            "Strength": HealthStyle.rose,
            "Cardio": HealthStyle.amber,
        ])
        .chartLegend(.hidden)
        .healthYAxis()
        .healthXAxis(days: balanceWindow)
        .frame(height: 110)
    }

    // MARK: SLEEP — two sources, honestly

    /// Nights inside a window, Withings preferred per night, Apple fallback.
    private func nightsUI(window: Int) -> [NightUI] {
        let cal = Calendar.current
        let cutoff = cal.date(byAdding: .day, value: -(window - 1),
                              to: cal.startOfDay(for: Date())) ?? .distantPast
        var byDate: [Date: NightUI] = [:]
        for d in sync.days where d.date >= cutoff && d.sleepMin > 0 {
            byDate[d.date] = NightUI(date: d.date, deep: d.sleepDeepMin,
                                     rem: d.sleepREMMin, light: d.sleepLightMin,
                                     awake: d.sleepAwakeMin, score: 0, hr: 0,
                                     source: "Apple Health")
        }
        for n in sync.withingsNights where n.date >= cutoff && n.totalSleepMin > 0 {
            byDate[n.date] = NightUI(date: n.date, deep: n.deepMin, rem: n.remMin,
                                     light: n.lightMin, awake: n.awakeMin,
                                     score: n.sleepScore, hr: n.hrAvg,
                                     source: "Withings")
        }
        return byDate.values.sorted { $0.date < $1.date }
    }

    private var scopedNights: [NightUI] { nightsUI(window: period.chartDays) }
    /// The pill + headline night, regardless of period.
    private var latestNight: NightUI? { nightsUI(window: 30).last }

    private func stageEntries(_ nights: [NightUI]) -> [StageEntry] {
        var out: [StageEntry] = []
        for n in nights {
            out.append(StageEntry(date: n.date, stage: "Deep", minutes: n.deep))
            out.append(StageEntry(date: n.date, stage: "REM", minutes: n.rem))
            out.append(StageEntry(date: n.date, stage: "Light", minutes: n.light))
            out.append(StageEntry(date: n.date, stage: "Awake", minutes: n.awake))
        }
        return out
    }

    private var sleepCard: some View {
        card("Sleep", icon: "bed.double.fill", tint: HealthStyle.sleepREM) {
            let nights = scopedNights
            if let latest = nights.last {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(HealthFmt.minutes(latest.total))
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .contentTransition(.numericText())
                        Text("last night · \(latest.source)")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        if latest.score > 0 {
                            Text("score \(latest.score)")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(HealthStyle.sleepREM)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(HealthStyle.sleepREM.opacity(0.15)))
                        }
                    }
                    if latest.hr > 0 {
                        Text("night heart rate \(latest.hr) bpm")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    SleepStageBar(deep: latest.deep, rem: latest.rem,
                                  light: latest.light, awake: latest.awake)
                    SleepLegend(deep: latest.deep, rem: latest.rem,
                                light: latest.light, awake: latest.awake)
                    sleepChart(nights)
                    let hrPoints = nights.filter { $0.hr > 0 }
                        .map { MetricPoint(date: $0.date, value: Double($0.hr)) }
                    if hrPoints.count >= 2 {
                        nightHRChart(hrPoints)
                    }
                }
            } else {
                Text("No sleep recorded in this period.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func sleepChart(_ nights: [NightUI]) -> some View {
        let entries = stageEntries(nights)
        let avg = nights.isEmpty ? 0
            : Double(nights.map(\.total).reduce(0, +)) / Double(nights.count) / 60
        return Chart {
            ForEach(entries) { e in
                BarMark(
                    x: .value("Night", e.date, unit: .day),
                    y: .value("Hours", Double(e.minutes) / 60)
                )
                .foregroundStyle(by: .value("Stage", e.stage))
                .cornerRadius(2)
            }
            if avg > 0 {
                RuleMark(y: .value("Average", avg))
                    .foregroundStyle(.white.opacity(0.3))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .topTrailing) {
                        Text("avg \(HealthFmt.minutes(Int(avg * 60)))")
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.5))
                    }
            }
        }
        .chartForegroundStyleScale([
            "Deep": HealthStyle.sleepDeep,
            "REM": HealthStyle.sleepREM,
            "Light": HealthStyle.sleepLight,
            "Awake": HealthStyle.sleepAwake,
        ])
        .chartLegend(.hidden)
        .healthYAxis()
        .healthXAxis(days: period.chartDays)
        .frame(height: 110)
    }

    private func nightHRChart(_ points: [MetricPoint]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Night heart rate · Withings")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
                .textCase(.uppercase)
                .kerning(0.6)
            Chart(points) { p in
                LineMark(
                    x: .value("Night", p.date, unit: .day),
                    y: .value("bpm", p.value)
                )
                .foregroundStyle(HealthStyle.heartRed)
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .healthYAxis()
            .chartXAxis(.hidden)
            .frame(height: 50)
        }
    }

    // MARK: BODY — Withings scale

    /// Body charts keep at least two weeks of context; Month shows 30 days.
    private var bodyWindow: Int { period == .month ? 30 : 14 }

    private func measureSeries(_ metric: String, days n: Int) -> [MetricPoint] {
        let cal = Calendar.current
        let cutoff = cal.date(byAdding: .day, value: -(n - 1),
                              to: cal.startOfDay(for: Date())) ?? .distantPast
        return sync.withingsMeasures
            .filter { $0.metric == metric && $0.measuredAt >= cutoff }
            .sorted { $0.measuredAt < $1.measuredAt }
            .map { MetricPoint(date: $0.measuredAt, value: $0.value) }
    }

    private func latestMeasure(_ metric: String) -> WithingsMeasure? {
        sync.withingsMeasures
            .filter { $0.metric == metric }
            .max { $0.measuredAt < $1.measuredAt }
    }

    /// -1 / 0 / +1 over the body window; |Δ| < 0.1 counts as flat.
    private func trend(_ metric: String) -> Int {
        let pts = measureSeries(metric, days: bodyWindow)
        guard let first = pts.first?.value, let last = pts.last?.value,
              pts.count >= 2 else { return 0 }
        let d = last - first
        if d > 0.1 { return 1 }
        if d < -0.1 { return -1 }
        return 0
    }

    private var latestWeight: WithingsMeasure? { latestMeasure("weight_kg") }

    /// Latest weight minus the average of the 7 prior days' readings.
    private var weightDelta: Double? {
        guard let latest = latestWeight else { return nil }
        let from = latest.measuredAt.addingTimeInterval(-7 * 86400)
        let prior = sync.withingsMeasures.filter {
            $0.metric == "weight_kg"
                && $0.measuredAt >= from && $0.measuredAt < latest.measuredAt
        }
        guard !prior.isEmpty else { return nil }
        let avg = prior.map(\.value).reduce(0, +) / Double(prior.count)
        return latest.value - avg
    }

    private var weightDeltaText: String {
        guard let d = weightDelta else { return "this morning" }
        let arrow = d > 0.05 ? "↑" : (d < -0.05 ? "↓" : "→")
        return String(format: "%@ %.1f kg vs 7-day avg", arrow, abs(d))
    }

    private var weightSeries: [MetricPoint] { measureSeries("weight_kg", days: bodyWindow) }

    /// Trailing 7-day moving average at each weight reading.
    private var weightAvgSeries: [MetricPoint] {
        let pts = weightSeries
        return pts.map { p in
            let from = p.date.addingTimeInterval(-7 * 86400)
            let window = pts.filter { $0.date >= from && $0.date <= p.date }
            let avg = window.map(\.value).reduce(0, +) / Double(max(window.count, 1))
            return MetricPoint(date: p.date, value: avg)
        }
    }

    private var bodyCard: some View {
        card("Body · Withings", icon: "scalemass.fill", tint: HealthStyle.amber) {
            if sync.withingsMeasures.isEmpty {
                Text("No Withings body data yet — weight, body fat, muscle and "
                    + "hydration will appear here when the scale syncs.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    if let w = latestWeight {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(String(format: "%.1f", w.value))
                                .font(.system(size: 30, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .contentTransition(.numericText())
                            Text("kg")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                            Text(weightDeltaText)
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.55))
                            Spacer(minLength: 0)
                        }
                    }
                    if weightSeries.count >= 2 {
                        weightChart
                    }
                    bodyStatRow
                    let fat = measureSeries("fat_ratio_pct", days: bodyWindow)
                    if fat.count >= 2 {
                        fatChart(fat)
                    }
                }
            }
        }
    }

    private var weightChart: some View {
        Chart {
            ForEach(weightAvgSeries) { p in
                LineMark(
                    x: .value("Day", p.date),
                    y: .value("kg", p.value),
                    series: .value("Series", "7-day avg")
                )
                .foregroundStyle(.white.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                .interpolationMethod(.catmullRom)
            }
            ForEach(weightSeries) { p in
                LineMark(
                    x: .value("Day", p.date),
                    y: .value("kg", p.value),
                    series: .value("Series", "Weight")
                )
                .foregroundStyle(HealthStyle.amber)
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                PointMark(
                    x: .value("Day", p.date),
                    y: .value("kg", p.value)
                )
                .foregroundStyle(HealthStyle.amber)
                .symbolSize(18)
            }
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .healthYAxis()
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: bodyWindow > 14 ? 7 : 3)) { _ in
                AxisValueLabel(format: .dateTime.day())
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .frame(height: 100)
    }

    private var bodyStatRow: some View {
        HStack(spacing: 10) {
            bodyStat("Body fat",
                     latestMeasure("fat_ratio_pct").map { String(format: "%.1f%%", $0.value) },
                     trend: trend("fat_ratio_pct"))
            bodyStat("Muscle",
                     latestMeasure("muscle_mass_kg").map { String(format: "%.1f kg", $0.value) },
                     trend: trend("muscle_mass_kg"))
            bodyStat("Hydration",
                     latestMeasure("hydration_kg").map { String(format: "%.1f kg", $0.value) },
                     trend: trend("hydration_kg"))
        }
    }

    private func bodyStat(_ label: String, _ value: String?, trend: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
                .textCase(.uppercase)
                .kerning(0.6)
            HStack(spacing: 4) {
                Text(value ?? "—")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                if value != nil && trend != 0 {
                    Image(systemName: trend > 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.05)))
    }

    private func fatChart(_ points: [MetricPoint]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Body fat %")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
                .textCase(.uppercase)
                .kerning(0.6)
            Chart(points) { p in
                LineMark(
                    x: .value("Day", p.date),
                    y: .value("%", p.value)
                )
                .foregroundStyle(HealthStyle.pink)
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .healthYAxis()
            .chartXAxis(.hidden)
            .frame(height: 50)
        }
    }

    // MARK: HEART

    private var hrDays: [HealthDay] { daysWindow(period.chartDays).filter { $0.restingHR > 0 } }
    private var hrvDays: [HealthDay] { daysWindow(period.chartDays).filter { $0.hrvMS > 0 } }

    private var heartCard: some View {
        card("Heart", icon: "heart.fill", tint: HealthStyle.heartRed) {
            let hr = hrDays
            let hrv = hrvDays
            if hr.isEmpty && hrv.isEmpty {
                Text("No heart data in this period.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        if let latest = hr.last {
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text("\(latest.restingHR)")
                                    .font(.system(size: 30, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .contentTransition(.numericText())
                                Text("resting bpm")
                                    .font(.system(size: 13)).foregroundStyle(.secondary)
                            }
                        }
                        if let latest = hrv.last {
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text("\(latest.hrvMS)")
                                    .font(.system(size: 30, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .contentTransition(.numericText())
                                Text("ms HRV")
                                    .font(.system(size: 13)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if hr.count >= 2 {
                        restingHRChart(hr)
                    }
                    if hrv.count >= 2 {
                        hrvChart(hrv)
                    }
                }
            }
        }
    }

    private func restingHRChart(_ days: [HealthDay]) -> some View {
        Chart(days) { d in
            LineMark(
                x: .value("Day", d.date, unit: .day),
                y: .value("Resting HR", d.restingHR)
            )
            .foregroundStyle(HealthStyle.heartRed)
            .interpolationMethod(.catmullRom)
            .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
            PointMark(
                x: .value("Day", d.date, unit: .day),
                y: .value("Resting HR", d.restingHR)
            )
            .foregroundStyle(HealthStyle.heartRed)
            .symbolSize(20)
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .healthYAxis()
        .healthXAxis(days: period.chartDays)
        .frame(height: 90)
    }

    private func hrvChart(_ days: [HealthDay]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("HRV · ms")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
                .textCase(.uppercase)
                .kerning(0.6)
            Chart(days) { d in
                LineMark(
                    x: .value("Day", d.date, unit: .day),
                    y: .value("HRV", d.hrvMS)
                )
                .foregroundStyle(HealthStyle.pink)
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .healthYAxis()
            .chartXAxis(.hidden)
            .frame(height: 50)
        }
    }

    // MARK: STEPS

    private var stepsCard: some View {
        card("Steps · \(period.chartDays) days", icon: "figure.walk", tint: HealthStyle.pink) {
            Chart(daysWindow(period.chartDays)) { d in
                BarMark(
                    x: .value("Day", d.date, unit: .day),
                    y: .value("Steps", d.steps)
                )
                .foregroundStyle(HealthStyle.pink.gradient)
                .cornerRadius(3)
            }
            .healthYAxis()
            .healthXAxis(days: period.chartDays)
            .frame(height: 110)
        }
    }

    // MARK: WORKOUTS — grouped by day, tinted by category

    private var workoutsEmptyText: String {
        switch period {
        case .today: return "No workouts today."
        case .week: return "No workouts this week."
        case .month: return "No workouts this month."
        }
    }

    private var workoutsSection: some View {
        card("Workouts", icon: "figure.run", tint: HealthStyle.peach) {
            if groupedWorkouts.isEmpty {
                Text(workoutsEmptyText)
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(groupedWorkouts, id: \.day) { group in
                        Text(HealthFmt.dayHeaderText(group.day))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.45))
                            .textCase(.uppercase)
                            .kerning(0.8)
                            .padding(.top, 8)
                        ForEach(group.items) { w in
                            Button {
                                let f = workoutFocus(w)
                                openedFocus = f
                                convo.setFocus(f)
                                selectedWorkout = w
                            } label: {
                                HealthWorkoutRow(workout: w,
                                                 tint: HealthStyle.categoryTint(w.kind))
                            }
                            .buttonStyle(.plain)
                            if w.id != group.items.last?.id {
                                Divider().overlay(.white.opacity(0.1))
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: focus (page-level, enriched with the live period + headlines)

    /// What Scarlet "sees" while Ido browses: the period plus the headline
    /// numbers, so she can discuss exactly what's on screen.
    private func pageFocus() -> String {
        let s = sync.todaySnapshot
        var bits: [String] = [
            "today \(s.steps.formatted()) steps, \(s.activeKcal) kcal, "
                + "\(s.exerciseMin) exercise min"
        ]
        if let n = latestNight {
            var sleepBit = "last night \(HealthFmt.minutes(n.total))"
            if n.score > 0 { sleepBit += " (Withings score \(n.score))" }
            bits.append(sleepBit)
        }
        if let w = latestWeight {
            bits.append(String(format: "weight %.1f kg", w.value))
        }
        let b = balanceSummary
        if b.sSessions + b.cSessions > 0 {
            bits.append("\(period == .month ? "this month" : "this week") "
                + "\(b.sSessions) strength sessions and \(b.cMin) cardio minutes")
        }
        return "[FOCUS] Ido is viewing his Health page (\(period.rawValue) view) — "
            + bits.joined(separator: "; ")
            + ". Synced live from Apple Health and Withings — he can ask you "
            + "about any of it (apple_health tool)."
    }

    /// Stale-guard (InboxView's MailDetailView pattern): restore the page
    /// focus only if the closed sheet still owns it.
    private func restoreBrowsingFocus() {
        if let f = openedFocus, convo.currentFocus == f {
            convo.setFocus(pageFocus())
        }
        openedFocus = nil
    }
}

// MARK: - Period picker (segmented capsule)

private struct PeriodPicker: View {
    @Binding var period: HealthPeriod

    var body: some View {
        HStack(spacing: 4) {
            ForEach(HealthPeriod.allCases) { p in
                Button {
                    withAnimation(.snappy(duration: 0.3)) { period = p }
                } label: {
                    Text(p.rawValue)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(period == p ? .white : .white.opacity(0.55))
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity)
                        .background {
                            if period == p {
                                Capsule().fill(HealthStyle.rose.opacity(0.85))
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Capsule().fill(.white.opacity(0.06)))
    }
}

// MARK: - Stat ring (Circle().trim gauge, Fitness-style)

private struct StatRing: View {
    let value: Double
    let goal: Double
    let label: String
    let text: String
    let color: Color

    private var progress: Double {
        guard goal > 0 else { return 0 }
        return min(value / goal, 1)
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(color.opacity(0.18), lineWidth: 9)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(color, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                // The real value is the headline (what he came to read); the
                // percent-of-goal is the small supporting number.
                VStack(spacing: 0) {
                    Text(text)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                        .contentTransition(.numericText())
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 6)
            }
            .frame(width: 72, height: 72)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Hero pieces

/// A compact capsule fact — sleep last night, weight this morning.
private struct GlancePill: View {
    let icon: String
    let tint: Color
    let value: String
    let sub: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                Text(sub)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Capsule().fill(.white.opacity(0.06)))
    }
}

/// A big period total for the Week/Month hero grid.
private struct HeroStat: View {
    let value: String
    let label: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .contentTransition(.numericText())
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A legend dot + label, used by the balance card.
private struct LegendChip: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.55))
        }
    }
}

// MARK: - Sleep stage bar (horizontal stacked) + legend

private struct SleepStageBar: View {
    let deep: Int
    let rem: Int
    let light: Int
    let awake: Int

    var body: some View {
        let d = Double(deep)
        let r = Double(rem)
        let l = Double(light)
        let a = Double(awake)
        let total = max(d + r + l + a, 1)
        GeometryReader { geo in
            HStack(spacing: 2) {
                segment(width: geo.size.width * d / total, color: HealthStyle.sleepDeep)
                segment(width: geo.size.width * r / total, color: HealthStyle.sleepREM)
                segment(width: geo.size.width * l / total, color: HealthStyle.sleepLight)
                segment(width: geo.size.width * a / total, color: HealthStyle.sleepAwake)
            }
        }
        .frame(height: 14)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    @ViewBuilder
    private func segment(width: CGFloat, color: Color) -> some View {
        if width >= 1 {
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .frame(width: max(width - 2, 2))
        }
    }
}

private struct SleepLegend: View {
    let deep: Int
    let rem: Int
    let light: Int
    let awake: Int

    var body: some View {
        HStack(spacing: 12) {
            LegendChip(color: HealthStyle.sleepDeep,
                       text: "Deep \(HealthFmt.minutes(deep))")
            LegendChip(color: HealthStyle.sleepREM,
                       text: "REM \(HealthFmt.minutes(rem))")
            LegendChip(color: HealthStyle.sleepLight,
                       text: "Light \(HealthFmt.minutes(light))")
            LegendChip(color: HealthStyle.sleepAwake,
                       text: "Awake \(HealthFmt.minutes(awake))")
        }
    }
}

// MARK: - Workout row

private struct HealthWorkoutRow: View {
    let workout: HealthWorkout
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(tint.opacity(0.18))
                Image(systemName: HealthStyle.workoutIcon(workout.kind))
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(tint)
            }
            .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text(workout.kind.capitalized)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Text(HealthFmt.workoutDay.string(from: workout.start))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(statsLine)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer(minLength: 8)
            if !workout.route.isEmpty {
                Image(systemName: "map")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.4))
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.35))
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private var statsLine: String {
        var parts = [HealthFmt.minutes(workout.durationMin)]
        if workout.distanceM > 0 { parts.append(HealthFmt.distance(workout.distanceM)) }
        if workout.kcal > 0 { parts.append("\(workout.kcal) kcal") }
        if workout.avgHR > 0 { parts.append("\(workout.avgHR) bpm") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Workout detail sheet (route map + stats)

private struct WorkoutDetailSheet: View {
    let workout: HealthWorkout
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if coordinates.count >= 2 {
                        routeMap
                            .frame(height: 320)
                            .clipShape(RoundedRectangle(cornerRadius: 20))
                    }
                    statsGrid
                }
                .padding(16)
            }
            .scarletScreen()
            .navigationTitle(workout.kind.capitalized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var coordinates: [CLLocationCoordinate2D] {
        workout.route.compactMap { pair in
            guard pair.count >= 2 else { return nil }
            let c = CLLocationCoordinate2D(latitude: pair[0], longitude: pair[1])
            // A bad server row (e.g. lat 999) fed to MapPolyline/MKCoordinateRegion
            // makes MapKit assert and take the app down — drop invalid pairs.
            guard CLLocationCoordinate2DIsValid(c) else { return nil }
            return c
        }
    }

    /// iOS 17 Map API: MapPolyline inside the MapContentBuilder, camera
    /// framed on the route's bounds.
    private var routeMap: some View {
        Map(initialPosition: .region(Self.region(for: coordinates))) {
            MapPolyline(coordinates: coordinates)
                .stroke(HealthStyle.rose,
                        style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            if let start = coordinates.first {
                Annotation("Start", coordinate: start) {
                    Circle().fill(.green)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                }
            }
            if let end = coordinates.last {
                Annotation("End", coordinate: end) {
                    Circle().fill(HealthStyle.rose)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                }
            }
        }
        .mapStyle(.standard(elevation: .flat))
    }

    /// A region covering the route's bounding box with breathing room.
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
            span: MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.4, 0.005),
                                   longitudeDelta: max((maxLon - minLon) * 1.4, 0.005)))
    }

    private var durationSeconds: Int {
        max(0, Int(workout.end.timeIntervalSince(workout.start)))
    }

    private var statsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            statTile("Duration", HealthFmt.minutes(workout.durationMin), "clock.fill")
            if workout.distanceM > 0 {
                statTile("Distance", HealthFmt.distance(workout.distanceM),
                         "point.topleft.down.curvedto.point.bottomright.up")
            }
            if workout.distanceM > 0 && durationSeconds > 0 {
                statTile("Avg pace",
                         HealthFmt.pace(distanceM: workout.distanceM, seconds: durationSeconds),
                         "speedometer")
            }
            if workout.kcal > 0 {
                statTile("Active energy", "\(workout.kcal) kcal", "flame.fill")
            }
            if workout.avgHR > 0 {
                statTile("Avg heart rate", "\(workout.avgHR) bpm", "heart.fill")
            }
            statTile("Started", HealthFmt.workoutDay.string(from: workout.start), "calendar")
        }
    }

    private func statTile(_ label: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(HealthStyle.rose)
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .textCase(.uppercase)
                    .kerning(0.6)
            }
            Text(value)
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.06)))
    }
}
