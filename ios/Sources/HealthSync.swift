import Foundation
import HealthKit
import CoreLocation

/// Apple Health sync: reads the last 14 days of activity, sleep, heart and
/// workout data from HealthKit, pushes it to the backend (`op=health_push`,
/// same app-api plumbing as the rest of the app — the server upserts days by
/// date and workouts by start+kind), and keeps the computed payload published
/// so HealthView renders instantly from exactly the data it pushed.
///
/// HealthKit caveat coded around throughout: READ authorization status is
/// deliberately not queryable (getRequestStatus only says whether the sheet
/// would show). "authorized" here means "the request sheet has completed" —
/// best effort; queries simply return whatever data the user actually
/// granted, and every metric failure is non-fatal (that metric stays zero).

// MARK: - Published shapes

/// One day of aggregates — the same fields the wire `days` entry carries.
struct HealthDay: Identifiable {
    let date: Date          // local start of day
    let dateKey: String     // "2026-08-02"
    var steps: Int = 0
    var distanceM: Int = 0
    var activeKcal: Int = 0
    var exerciseMin: Int = 0
    var standHours: Int = 0
    var restingHR: Int = 0  // 0 = no reading that day
    var hrvMS: Int = 0
    var sleepMin: Int = 0
    var sleepDeepMin: Int = 0
    var sleepREMMin: Int = 0
    var sleepAwakeMin: Int = 0

    var id: String { dateKey }
    /// Asleep-but-not-deep-not-REM minutes, for the stage bar.
    var sleepLightMin: Int { max(0, sleepMin - sleepDeepMin - sleepREMMin) }
}

/// One workout — the same fields the wire `workouts` entry carries.
struct HealthWorkout: Identifiable {
    let start: Date
    let end: Date
    let kind: String        // "walking", "running", ...
    var distanceM: Int = 0
    var kcal: Int = 0
    var avgHR: Int = 0
    /// Downsampled [lat, lng] pairs (≤500), empty when no route was recorded.
    var route: [[Double]] = []

    var id: String { "\(start.timeIntervalSince1970)-\(kind)" }
    var durationMin: Int { max(0, Int(end.timeIntervalSince(start) / 60)) }
}

/// The tab header's at-a-glance numbers.
struct TodaySnapshot {
    var steps: Int = 0
    var activeKcal: Int = 0
    var exerciseMin: Int = 0
    /// Last night's total (the night attributed to today's wake date).
    var sleepMin: Int = 0
}

// MARK: - HealthSync

@MainActor
final class HealthSync: ObservableObject {
    static let shared = HealthSync()

    /// "The authorization sheet has completed at least once." Read grants are
    /// not queryable — this is the honest best-effort flag (persisted so the
    /// explainer doesn't reappear every launch).
    @Published var authorized: Bool
    @Published var syncing = false
    @Published var lastSync: Date?
    @Published var todaySnapshot = TodaySnapshot()
    /// Local cache of the last computed payload, oldest day first.
    @Published var days: [HealthDay] = []
    /// Newest workout first.
    @Published var workouts: [HealthWorkout] = []
    @Published var errorText = ""

    private let store = HKHealthStore()
    private static let authorizedKey = "scarlet.healthAuthorized"

    private init() {
        authorized = UserDefaults.standard.bool(forKey: Self.authorizedKey)
    }

    var available: Bool { HKHealthStore.isHealthDataAvailable() }

    // MARK: authorization

    /// Everything the tab reads. Share (write) nothing.
    private static func readTypes() -> Set<HKObjectType> {
        var read: Set<HKObjectType> = []
        let quantities: [HKQuantityTypeIdentifier] = [
            .stepCount, .distanceWalkingRunning, .activeEnergyBurned,
            .appleExerciseTime, .restingHeartRate,
            .heartRateVariabilitySDNN, .heartRate,
        ]
        for id in quantities {
            if let t = HKObjectType.quantityType(forIdentifier: id) { read.insert(t) }
        }
        let categories: [HKCategoryTypeIdentifier] = [.sleepAnalysis, .appleStandHour]
        for id in categories {
            if let t = HKObjectType.categoryType(forIdentifier: id) { read.insert(t) }
        }
        read.insert(HKObjectType.workoutType())
        read.insert(HKSeriesType.workoutRoute())
        return read
    }

    func requestAccess() async {
        guard available else {
            errorText = "Health data isn't available on this device."
            return
        }
        let ok: Bool = await withCheckedContinuation { cont in
            store.requestAuthorization(toShare: nil, read: Self.readTypes()) { granted, _ in
                cont.resume(returning: granted)
            }
        }
        // `granted` only means the request flow completed — per-type read
        // grants are invisible by design. Proceed and render what returns.
        if ok {
            authorized = true
            UserDefaults.standard.set(true, forKey: Self.authorizedKey)
        } else {
            errorText = "Couldn't open the Health access sheet — try again."
        }
    }

    // MARK: sync

    func syncNow() async {
        guard available, authorized, !syncing else { return }
        syncing = true
        errorText = ""
        defer { syncing = false }

        let cal = Calendar.current
        let now = Date()
        let todayStart = cal.startOfDay(for: now)
        guard let windowStart = cal.date(byAdding: .day, value: -13, to: todayStart) else { return }

        // Daily aggregates — each query independent, failures leave zeros.
        let steps = await dailyStats(.stepCount, unit: .count(),
                                     options: .cumulativeSum, from: windowStart, to: now)
        let distance = await dailyStats(.distanceWalkingRunning, unit: .meter(),
                                        options: .cumulativeSum, from: windowStart, to: now)
        let kcal = await dailyStats(.activeEnergyBurned, unit: .kilocalorie(),
                                    options: .cumulativeSum, from: windowStart, to: now)
        let exercise = await dailyStats(.appleExerciseTime, unit: .minute(),
                                        options: .cumulativeSum, from: windowStart, to: now)
        let restingHR = await dailyStats(.restingHeartRate,
                                         unit: HKUnit.count().unitDivided(by: .minute()),
                                         options: .discreteAverage, from: windowStart, to: now)
        let hrv = await dailyStats(.heartRateVariabilitySDNN,
                                   unit: HKUnit.secondUnit(with: .milli),
                                   options: .discreteAverage, from: windowStart, to: now)
        let stand = await standHoursByDay(from: windowStart, to: now)
        let nights = await sleepByNight(from: windowStart, to: now)

        var newDays: [HealthDay] = []
        for i in 0..<14 {
            guard let dayStart = cal.date(byAdding: .day, value: i, to: windowStart) else { continue }
            var d = HealthDay(date: dayStart, dateKey: Self.dayKey.string(from: dayStart))
            d.steps = Int(steps[dayStart] ?? 0)
            d.distanceM = Int(distance[dayStart] ?? 0)
            d.activeKcal = Int(kcal[dayStart] ?? 0)
            d.exerciseMin = Int(exercise[dayStart] ?? 0)
            d.standHours = stand[dayStart] ?? 0
            d.restingHR = Int((restingHR[dayStart] ?? 0).rounded())
            d.hrvMS = Int((hrv[dayStart] ?? 0).rounded())
            if let n = nights[dayStart] {
                d.sleepMin = Int(n.asleepTotal.rounded())
                d.sleepDeepMin = Int(n.deep.rounded())
                d.sleepREMMin = Int(n.rem.rounded())
                d.sleepAwakeMin = Int(n.awake.rounded())
            }
            newDays.append(d)
        }

        // Workouts of the window, newest first, with routes + avg HR.
        let hkWorkouts = await fetchWorkouts(from: windowStart, to: now)
        var newWorkouts: [HealthWorkout] = []
        for w in hkWorkouts {
            var out = HealthWorkout(start: w.startDate, end: w.endDate,
                                    kind: Self.kindName(w.workoutActivityType))
            if let meters = w.totalDistance?.doubleValue(for: .meter()) {
                out.distanceM = Int(meters)
            }
            if let energy = w.totalEnergyBurned?.doubleValue(for: .kilocalorie()) {
                out.kcal = Int(energy)
            }
            out.avgHR = Int(await averageHR(for: w).rounded())
            let locations = await routeLocations(for: w)
            out.route = Self.downsample(locations, to: 500)
            newWorkouts.append(out)
        }

        // Publish the local cache first — the view renders even if the push
        // fails; lastSync only advances when the server accepted the payload.
        days = newDays
        workouts = newWorkouts
        if let today = newDays.last {
            todaySnapshot = TodaySnapshot(steps: today.steps,
                                          activeKcal: today.activeKcal,
                                          exerciseMin: today.exerciseMin,
                                          sleepMin: today.sleepMin)
        }

        do {
            try await Self.push(days: newDays.map(Self.wireDay),
                                workouts: newWorkouts.map(Self.wireWorkout))
            lastSync = Date()
        } catch {
            errorText = "Synced locally — couldn't reach the server."
        }
    }

    // MARK: HK queries (each wrapped in a continuation, all non-fatal)

    /// Per-day statistics keyed by local start of day. `.cumulativeSum` sums,
    /// `.discreteAverage` averages; days with no data are simply absent.
    private func dailyStats(_ id: HKQuantityTypeIdentifier, unit: HKUnit,
                            options: HKStatisticsOptions,
                            from start: Date, to end: Date) async -> [Date: Double] {
        guard let type = HKObjectType.quantityType(forIdentifier: id) else { return [:] }
        let anchor = Calendar.current.startOfDay(for: start)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end,
                                                    options: .strictStartDate)
        return await withCheckedContinuation { cont in
            let q = HKStatisticsCollectionQuery(quantityType: type,
                                                quantitySamplePredicate: predicate,
                                                options: options,
                                                anchorDate: anchor,
                                                intervalComponents: DateComponents(day: 1))
            q.initialResultsHandler = { _, collection, _ in
                var out: [Date: Double] = [:]
                collection?.enumerateStatistics(from: anchor, to: end) { stat, _ in
                    let qty = options.contains(.cumulativeSum)
                        ? stat.sumQuantity() : stat.averageQuantity()
                    if let qty { out[stat.startDate] = qty.doubleValue(for: unit) }
                }
                cont.resume(returning: out)
            }
            self.store.execute(q)
        }
    }

    private func categorySamples(_ id: HKCategoryTypeIdentifier,
                                 from start: Date, to end: Date) async -> [HKCategorySample] {
        guard let type = HKObjectType.categoryType(forIdentifier: id) else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        return await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: type, predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, samples, _ in
                cont.resume(returning: (samples as? [HKCategorySample]) ?? [])
            }
            self.store.execute(q)
        }
    }

    /// Stood-hour count per local day.
    private func standHoursByDay(from start: Date, to end: Date) async -> [Date: Int] {
        let cal = Calendar.current
        let samples = await categorySamples(.appleStandHour, from: start, to: end)
        var out: [Date: Int] = [:]
        for s in samples where s.value == HKCategoryValueAppleStandHour.stood.rawValue {
            let day = cal.startOfDay(for: s.startDate)
            out[day, default: 0] += 1
        }
        return out
    }

    /// Sleep-stage minute buckets for one night.
    private struct NightAgg {
        var core = 0.0   // asleepCore + asleepUnspecified
        var deep = 0.0
        var rem = 0.0
        var awake = 0.0
        var asleepTotal: Double { core + deep + rem }
    }

    /// Sleep aggregated per night, keyed by the WAKE date's start of day.
    /// A night is the 18:00–18:00 window: samples ending after 18:00 belong
    /// to the next day. Multiple sources (Watch + iPhone + apps) would
    /// double-count, so per night only the source with the most asleep
    /// minutes is kept.
    private func sleepByNight(from start: Date, to end: Date) async -> [Date: NightAgg] {
        let cal = Calendar.current
        // Pull from the evening before the window so day 1's night is whole.
        let sleepStart = cal.date(byAdding: .hour, value: -6, to: start) ?? start
        let samples = await categorySamples(.sleepAnalysis, from: sleepStart, to: end)
        // night -> source bundle id -> buckets
        var perSource: [Date: [String: NightAgg]] = [:]
        for s in samples {
            let base = cal.startOfDay(for: s.endDate)
            let night = cal.component(.hour, from: s.endDate) >= 18
                ? (cal.date(byAdding: .day, value: 1, to: base) ?? base) : base
            let minutes = s.endDate.timeIntervalSince(s.startDate) / 60
            guard minutes > 0 else { continue }
            let source = s.sourceRevision.source.bundleIdentifier
            var agg = perSource[night]?[source] ?? NightAgg()
            switch s.value {
            case HKCategoryValueSleepAnalysis.asleepDeep.rawValue:
                agg.deep += minutes
            case HKCategoryValueSleepAnalysis.asleepREM.rawValue:
                agg.rem += minutes
            case HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                 HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue:
                agg.core += minutes
            case HKCategoryValueSleepAnalysis.awake.rawValue:
                agg.awake += minutes
            default:
                break  // inBed is not sleep
            }
            perSource[night, default: [:]][source] = agg
        }
        var out: [Date: NightAgg] = [:]
        for (night, sources) in perSource {
            if let best = sources.values.max(by: { $0.asleepTotal < $1.asleepTotal }),
               best.asleepTotal > 0 {
                out[night] = best
            }
        }
        return out
    }

    private func fetchWorkouts(from start: Date, to end: Date) async -> [HKWorkout] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end,
                                                    options: .strictStartDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        return await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: HKObjectType.workoutType(),
                                  predicate: predicate,
                                  limit: HKObjectQueryNoLimit,
                                  sortDescriptors: [sort]) { _, samples, _ in
                cont.resume(returning: (samples as? [HKWorkout]) ?? [])
            }
            self.store.execute(q)
        }
    }

    /// Average heart rate during a workout: the workout's own bundled
    /// statistics when present (workout-builder data), else a discrete-average
    /// query over the workout's interval. 0 when neither has data.
    private func averageHR(for workout: HKWorkout) async -> Double {
        guard let hrType = HKObjectType.quantityType(forIdentifier: .heartRate) else { return 0 }
        let bpm = HKUnit.count().unitDivided(by: .minute())
        if let avg = workout.statistics(for: hrType)?.averageQuantity() {
            return avg.doubleValue(for: bpm)
        }
        let predicate = HKQuery.predicateForSamples(withStart: workout.startDate,
                                                    end: workout.endDate, options: [])
        return await withCheckedContinuation { cont in
            let q = HKStatisticsQuery(quantityType: hrType,
                                      quantitySamplePredicate: predicate,
                                      options: .discreteAverage) { _, stats, _ in
                cont.resume(returning: stats?.averageQuantity()?.doubleValue(for: bpm) ?? 0)
            }
            self.store.execute(q)
        }
    }

    /// All CLLocations of a workout's (first) route, in order. Empty when the
    /// workout has no route or the route grant was withheld.
    private func routeLocations(for workout: HKWorkout) async -> [CLLocation] {
        let routes: [HKWorkoutRoute] = await withCheckedContinuation { cont in
            let predicate = HKQuery.predicateForObjects(from: workout)
            let q = HKSampleQuery(sampleType: HKSeriesType.workoutRoute(),
                                  predicate: predicate,
                                  limit: HKObjectQueryNoLimit,
                                  sortDescriptors: nil) { _, samples, _ in
                cont.resume(returning: (samples as? [HKWorkoutRoute]) ?? [])
            }
            self.store.execute(q)
        }
        guard let route = routes.first else { return [] }
        return await withCheckedContinuation { cont in
            var collected: [CLLocation] = []
            var resumed = false
            // The route streams in batches; `done` marks the last one. On
            // error the query stops without a final `done` — resume exactly
            // once either way.
            let q = HKWorkoutRouteQuery(route: route) { _, batch, done, error in
                if let batch { collected.append(contentsOf: batch) }
                if (done || error != nil) && !resumed {
                    resumed = true
                    cont.resume(returning: collected)
                }
            }
            self.store.execute(q)
        }
    }

    // MARK: helpers

    static let dayKey: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func kindName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .walking: return "walking"
        case .running: return "running"
        case .cycling: return "cycling"
        case .swimming: return "swimming"
        case .hiking: return "hiking"
        case .yoga: return "yoga"
        case .rowing: return "rowing"
        case .elliptical: return "elliptical"
        case .tennis: return "tennis"
        case .pickleball: return "pickleball"
        case .highIntensityIntervalTraining: return "hiit"
        case .coreTraining: return "core"
        case .functionalStrengthTraining, .traditionalStrengthTraining: return "strength"
        default: return "other"
        }
    }

    /// ≤ maxCount evenly-strided [lat, lng] pairs, endpoints preserved,
    /// rounded to 5 decimals (~1 m) to keep the payload small.
    static func downsample(_ locations: [CLLocation], to maxCount: Int) -> [[Double]] {
        func pair(_ l: CLLocation) -> [Double] {
            [(l.coordinate.latitude * 1e5).rounded() / 1e5,
             (l.coordinate.longitude * 1e5).rounded() / 1e5]
        }
        guard locations.count > maxCount else { return locations.map(pair) }
        let step = Double(locations.count - 1) / Double(maxCount - 1)
        var out: [[Double]] = []
        out.reserveCapacity(maxCount)
        for i in 0..<maxCount {
            let index = min(locations.count - 1, Int((Double(i) * step).rounded()))
            out.append(pair(locations[index]))
        }
        return out
    }

    static func wireDay(_ d: HealthDay) -> [String: Any] {
        [
            "date": d.dateKey,
            "steps": d.steps,
            "distance_m": d.distanceM,
            "active_kcal": d.activeKcal,
            "exercise_min": d.exerciseMin,
            "stand_hours": d.standHours,
            "resting_hr": d.restingHR,
            "hrv_ms": d.hrvMS,
            "sleep_min": d.sleepMin,
            "sleep_deep_min": d.sleepDeepMin,
            "sleep_rem_min": d.sleepREMMin,
            "sleep_awake_min": d.sleepAwakeMin,
        ]
    }

    static func wireWorkout(_ w: HealthWorkout) -> [String: Any] {
        [
            "start": iso.string(from: w.start),
            "end": iso.string(from: w.end),
            "kind": w.kind,
            "distance_m": w.distanceM,
            "kcal": w.kcal,
            "avg_hr": w.avgHR,
            "route": w.route,
        ]
    }

    // MARK: push (op rides the query string, x-scarlet-token — app convention)

    private static func push(days: [[String: Any]], workouts: [[String: Any]]) async throws {
        guard TokenStore.token != nil else { throw URLError(.userAuthenticationRequired) }
        var comps = URLComponents(url: AppConfig.appAPIURL, resolvingAgainstBaseURL: false)!
        var qItems = comps.queryItems ?? []
        qItems.append(URLQueryItem(name: "op", value: "health_push"))
        comps.queryItems = qItems
        var req = URLRequest(url: comps.url ?? AppConfig.appAPIURL)
        req.httpMethod = "POST"
        req.setValue(TokenStore.token ?? "", forHTTPHeaderField: "x-scarlet-token")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "days": days,
            "workouts": workouts,
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (obj?["ok"] as? Bool) == true else { throw URLError(.badServerResponse) }
    }
}
