import SwiftUI
import HealthKit
import MapKit
import Charts

/// The Health tab: today's activity rings, sleep stages, heart trends, step
/// history and workouts (with route maps) — Apple Fitness' anatomy on the
/// app's dark Scarlet look. All data comes from HealthSync.shared: the view
/// renders exactly the payload the sync layer pushed to the backend, so what
/// Ido sees is what Scarlet's apple_health tool sees.

// MARK: - Ambient focus

/// The page-level focus line, shared by the page's own appearance and the
/// workout sheet's dismissal so both report the exact same thing.
private let healthBrowsingFocus = "[FOCUS] Ido is viewing his Health page — "
    + "today's activity, sleep, heart and workouts, synced from Apple Health. "
    + "He can ask you about any of it (apple_health tool)."

// MARK: - Palette (the rose accent family)

private enum HealthStyle {
    static let rose = Color(red: 1, green: 0.35, blue: 0.42)
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
    /// "Fri, Aug 1 · 7:05"
    static let workoutDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d · H:mm"
        return f
    }()
}

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

// MARK: - Health page

struct HealthView: View {
    @ObservedObject private var sync = HealthSync.shared
    @EnvironmentObject private var convo: Conversation

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
            .background(ScarletBackground().ignoresSafeArea())
            // Scarlet lives at the bottom of the list screen, part of its
            // layout — same pattern as ChatsView / InboxView / LibraryView.
            .safeAreaInset(edge: .bottom) {
                ScarletPresenceView(convo: convo)
                    .padding(.vertical, 6)
            }
            .toolbar(.hidden, for: .navigationBar)
            .onAppear { convo.setFocus(healthBrowsingFocus) }
            .sheet(item: $selectedWorkout, onDismiss: { restoreBrowsingFocus() }) { w in
                WorkoutDetailSheet(workout: w)
                    .preferredColorScheme(.dark)
            }
        }
        // .task re-runs every time this tab is selected → sync on appear.
        .task { if sync.authorized { await sync.syncNow() } }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.willEnterForegroundNotification)) { _ in
            Task { if sync.authorized { await sync.syncNow() } }
        }
    }

    // MARK: header (big heavy title + refresh, like Library / Chats)

    private var headerBar: some View {
        HStack(spacing: 12) {
            Text("Health")
                .font(.system(size: 34, weight: .heavy))
                .foregroundStyle(.white)
            Spacer()
            if let last = sync.lastSync {
                Text(last, style: .relative)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
            }
            Button {
                Task { await sync.syncNow() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white)
            }
            .disabled(sync.syncing || !sync.authorized)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    // MARK: content

    @ViewBuilder
    private var content: some View {
        if !sync.available {
            explainer(
                icon: "heart.slash",
                title: "No Health data here",
                text: "This device doesn't provide Apple Health data.",
                showConnect: false
            )
        } else if !sync.authorized {
            explainer(
                icon: "heart.text.square.fill",
                title: "Connect Apple Health",
                text: "Scarlet reads your activity, sleep, heart and workouts "
                    + "so you can see them here — and ask her about any of it. "
                    + "Nothing is written back to Health.",
                showConnect: true
            )
        } else if sync.days.isEmpty && sync.syncing {
            VStack(spacing: 10) {
                ProgressView()
                Text("Reading Apple Health…")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if sync.days.isEmpty {
            explainer(
                icon: "heart.text.square",
                title: "Nothing yet",
                text: "No health data came back. If you just connected, check "
                    + "that Scarlet's categories are on in the Health app, then sync.",
                showConnect: false,
                showSyncButton: true
            )
        } else {
            dashboard
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
                        await sync.syncNow()
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
                Button("Sync now") { Task { await sync.syncNow() } }
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
                todayCard
                sleepCard
                heartCard
                stepsCard
                workoutsSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
        .refreshable { await sync.syncNow() }
    }

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
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(.white.opacity(0.06)))
    }

    // MARK: TODAY — three rings

    private var todayCard: some View {
        card("Today", icon: "flame.fill", tint: HealthStyle.rose) {
            HStack(spacing: 0) {
                StatRing(value: Double(sync.todaySnapshot.steps), goal: 8000,
                         label: "Steps", text: "\(sync.todaySnapshot.steps)",
                         color: HealthStyle.pink)
                StatRing(value: Double(sync.todaySnapshot.activeKcal), goal: 500,
                         label: "Active", text: "\(sync.todaySnapshot.activeKcal) kcal",
                         color: HealthStyle.rose)
                StatRing(value: Double(sync.todaySnapshot.exerciseMin), goal: 30,
                         label: "Exercise", text: "\(sync.todaySnapshot.exerciseMin) min",
                         color: HealthStyle.peach)
            }
        }
    }

    // MARK: SLEEP

    /// The most recent night with any sleep — normally last night.
    private var lastNight: HealthDay? {
        sync.days.last(where: { $0.sleepMin > 0 })
    }

    private var sleepCard: some View {
        card("Sleep", icon: "bed.double.fill", tint: HealthStyle.sleepREM) {
            if let night = lastNight {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(HealthFmt.minutes(night.sleepMin))
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("last night")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    SleepStageBar(night: night)
                    sleepLegend(night)
                    Chart(sync.days.suffix(7)) { d in
                        BarMark(
                            x: .value("Night", d.date, unit: .day),
                            y: .value("Hours", Double(d.sleepMin) / 60)
                        )
                        .foregroundStyle(HealthStyle.sleepREM.gradient)
                        .cornerRadius(3)
                    }
                    .chartYAxis {
                        AxisMarks { _ in
                            AxisGridLine().foregroundStyle(.white.opacity(0.08))
                            AxisValueLabel().foregroundStyle(.white.opacity(0.45))
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day)) { _ in
                            AxisValueLabel(format: .dateTime.weekday(.narrow))
                                .foregroundStyle(.white.opacity(0.45))
                        }
                    }
                    .frame(height: 80)
                }
            } else {
                Text("No sleep recorded in the last two weeks.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func sleepLegend(_ night: HealthDay) -> some View {
        HStack(spacing: 12) {
            legendDot(HealthStyle.sleepDeep, "Deep \(HealthFmt.minutes(night.sleepDeepMin))")
            legendDot(HealthStyle.sleepREM, "REM \(HealthFmt.minutes(night.sleepREMMin))")
            legendDot(HealthStyle.sleepLight, "Light \(HealthFmt.minutes(night.sleepLightMin))")
            legendDot(HealthStyle.sleepAwake, "Awake \(HealthFmt.minutes(night.sleepAwakeMin))")
        }
    }

    private func legendDot(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    // MARK: HEART

    private var heartCard: some View {
        card("Heart", icon: "heart.fill", tint: HealthStyle.heartRed) {
            let hrDays = sync.days.filter { $0.restingHR > 0 }
            let latestHRV = sync.days.last(where: { $0.hrvMS > 0 })?.hrvMS
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    if let latest = hrDays.last {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("\(latest.restingHR)")
                                .font(.system(size: 30, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                            Text("resting bpm")
                                .font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                    }
                    if let hrv = latestHRV {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("\(hrv)")
                                .font(.system(size: 30, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                            Text("ms HRV")
                                .font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                    }
                }
                if hrDays.count >= 2 {
                    Chart(hrDays) { d in
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
                    .chartYAxis {
                        AxisMarks { _ in
                            AxisGridLine().foregroundStyle(.white.opacity(0.08))
                            AxisValueLabel().foregroundStyle(.white.opacity(0.45))
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: 3)) { _ in
                            AxisValueLabel(format: .dateTime.day())
                                .foregroundStyle(.white.opacity(0.45))
                        }
                    }
                    .frame(height: 90)
                } else {
                    Text("No resting heart rate readings in the last two weeks.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: STEPS

    private var stepsCard: some View {
        card("Steps · 14 days", icon: "figure.walk", tint: HealthStyle.pink) {
            Chart(sync.days) { d in
                BarMark(
                    x: .value("Day", d.date, unit: .day),
                    y: .value("Steps", d.steps)
                )
                .foregroundStyle(HealthStyle.pink.gradient)
                .cornerRadius(3)
            }
            .chartYAxis {
                AxisMarks { _ in
                    AxisGridLine().foregroundStyle(.white.opacity(0.08))
                    AxisValueLabel().foregroundStyle(.white.opacity(0.45))
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 3)) { _ in
                    AxisValueLabel(format: .dateTime.day())
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            .frame(height: 110)
        }
    }

    // MARK: WORKOUTS

    private var workoutsSection: some View {
        card("Workouts", icon: "figure.run", tint: HealthStyle.peach) {
            if sync.workouts.isEmpty {
                Text("No workouts in the last two weeks.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(sync.workouts) { w in
                        Button {
                            let f = workoutFocus(w)
                            openedFocus = f
                            convo.setFocus(f)
                            selectedWorkout = w
                        } label: {
                            HealthWorkoutRow(workout: w)
                        }
                        .buttonStyle(.plain)
                        if w.id != sync.workouts.last?.id {
                            Divider().overlay(.white.opacity(0.1))
                        }
                    }
                }
            }
        }
    }

    /// Stale-guard (InboxView's MailDetailView pattern): restore the page
    /// focus only if the closed sheet still owns it.
    private func restoreBrowsingFocus() {
        if let f = openedFocus, convo.currentFocus == f {
            convo.setFocus(healthBrowsingFocus)
        }
        openedFocus = nil
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
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .frame(width: 72, height: 72)
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Sleep stage bar (horizontal stacked)

private struct SleepStageBar: View {
    let night: HealthDay

    var body: some View {
        let deep = Double(night.sleepDeepMin)
        let rem = Double(night.sleepREMMin)
        let light = Double(night.sleepLightMin)
        let awake = Double(night.sleepAwakeMin)
        let total = max(deep + rem + light + awake, 1)
        GeometryReader { geo in
            HStack(spacing: 2) {
                segment(width: geo.size.width * deep / total, color: HealthStyle.sleepDeep)
                segment(width: geo.size.width * rem / total, color: HealthStyle.sleepREM)
                segment(width: geo.size.width * light / total, color: HealthStyle.sleepLight)
                segment(width: geo.size.width * awake / total, color: HealthStyle.sleepAwake)
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

// MARK: - Workout row

private struct HealthWorkoutRow: View {
    let workout: HealthWorkout

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(HealthStyle.peach.opacity(0.18))
                Image(systemName: HealthStyle.workoutIcon(workout.kind))
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(HealthStyle.peach)
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
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    statsGrid
                }
                .padding(16)
            }
            .background(ScarletBackground().ignoresSafeArea())
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
            return CLLocationCoordinate2D(latitude: pair[0], longitude: pair[1])
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

    private var statsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            statTile("Duration", HealthFmt.minutes(workout.durationMin), "clock.fill")
            if workout.distanceM > 0 {
                statTile("Distance", HealthFmt.distance(workout.distanceM), "point.topleft.down.curvedto.point.bottomright.up")
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
