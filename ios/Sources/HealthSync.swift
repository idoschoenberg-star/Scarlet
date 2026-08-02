import Foundation
import HealthKit
import CoreLocation

/// Apple Health sync + the Withings join + the local-first cache.
///
/// Three jobs, in the owner's order of importance:
///
/// 1. REAL-TIME, not schedules: HKObserverQuery + immediate background
///    delivery for steps, active energy, workouts and sleep — when HealthKit
///    signals a change, an incremental `syncNow()` runs automatically
///    (debounced to at most one run per 60 s). On-appear and pull-to-refresh
///    syncs remain.
/// 2. LOCAL-FIRST: the full render model (days, workouts, Withings measures
///    and nights) is persisted as JSON at Documents/health-cache.json after
///    every load and re-loaded synchronously in `init`, so the Health tab
///    paints instantly — even offline. `lastUpdated` is the honest stamp.
/// 3. THE WITHINGS JOIN: after pushing local HealthKit data (`op=
///    health_push`, so the server copy includes today), the merged overview
///    is read back (`op=health_overview`) — server-side `health_days`
///    history (30 days), Withings body measures (weight, fat %, muscle,
///    hydration, HR) and Withings sleep nights (score, stages, night HR) —
///    and folded into the published model.
///
/// HealthKit caveat coded around throughout: READ authorization status is
/// deliberately not queryable (getRequestStatus only says whether the sheet
/// would show). "authorized" here means "the request sheet has completed" —
/// best effort; queries simply return whatever data the user actually
/// granted, and every metric failure is non-fatal (that metric stays zero).

// MARK: - Published shapes

/// One day of aggregates — the same fields the wire `days` entry carries.
struct HealthDay: Identifiable, Codable {
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
struct HealthWorkout: Identifiable, Codable {
    let start: Date
    let end: Date
    let kind: String        // "walking", "running", "strength", ...
    var distanceM: Int = 0
    var kcal: Int = 0
    var avgHR: Int = 0
    /// Downsampled [lat, lng] pairs (≤500), empty when no route was recorded.
    var route: [[Double]] = []

    var id: String { "\(start.timeIntervalSince1970)-\(kind)" }
    var durationMin: Int { max(0, Int(end.timeIntervalSince(start) / 60)) }
}

/// One Withings scale/device measure (weight_kg, fat_ratio_pct,
/// muscle_mass_kg, hydration_kg, heart_rate_bpm).
struct WithingsMeasure: Identifiable, Codable {
    let metric: String
    let value: Double
    let unit: String
    let measuredAt: Date

    var id: String { "\(metric)-\(measuredAt.timeIntervalSince1970)" }
}

/// One Withings sleep night, keyed by the wake date.
struct WithingsNight: Identifiable, Codable {
    let night: String       // "2026-08-02" (wake date)
    let date: Date          // local start of the wake day
    var sleepScore: Int = 0
    var totalSleepMin: Int = 0
    var deepMin: Int = 0
    var remMin: Int = 0
    var lightMin: Int = 0
    var awakeMin: Int = 0
    var hrAvg: Int = 0      // average heart rate during the night, 0 = none

    var id: String { night }
}

/// Strength vs cardio vs other — the owner's "weights vs steps" split.
/// Kinds are the app's own vocabulary (see `HealthSync.kindName`):
/// functional/traditional strength training map to "strength",
/// coreTraining to "core".
enum WorkoutCategory: String {
    case strength, cardio, other

    static let strengthKinds: Set<String> = ["strength", "core"]
    static let cardioKinds: Set<String> = [
        "walking", "running", "cycling", "swimming", "hiking",
        "rowing", "elliptical", "tennis", "pickleball", "hiit",
    ]

    static func classify(_ kind: String) -> WorkoutCategory {
        if strengthKinds.contains(kind) { return .strength }
        if cardioKinds.contains(kind) { return .cardio }
        return .other
    }
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
    /// Last time the server accepted a push.
    @Published var lastSync: Date?
    /// Last time the published model changed — the "updated Xm ago" stamp.
    /// Survives restarts via the cache, so offline the stamp stays honest.
    @Published var lastUpdated: Date?
    @Published var todaySnapshot = TodaySnapshot()
    /// The merged model: local HealthKit window + server history, oldest day
    /// first. May span up to 120 days once the overview has been read.
    @Published var days: [HealthDay] = []
    /// Newest workout first.
    @Published var workouts: [HealthWorkout] = []
    /// Withings body measures, oldest first.
    @Published var withingsMeasures: [WithingsMeasure] = []
    /// Withings sleep nights, oldest first.
    @Published var withingsNights: [WithingsNight] = []
    @Published var errorText = ""

    private let store = HKHealthStore()
    private static let authorizedKey = "scarlet.healthAuthorized"

    /// Observer machinery (doctrine #1).
    private var observerQueries: [HKObserverQuery] = []
    private var observing = false
    private var lastObserverSync = Date.distantPast
    private var observerSyncScheduled = false
    private static let observerDebounce: TimeInterval = 60

    private init() {
        authorized = UserDefaults.standard.bool(forKey: Self.authorizedKey)
        // Local-first: paint from the cache before any query or network call.
        loadCache()
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
            startObserving()
        } else {
            errorText = "Couldn't open the Health access sheet — try again."
        }
    }

    // MARK: real-time observers (doctrine #1)

    /// Registers one HKObserverQuery per change-worthy type and asks for
    /// immediate background delivery. Idempotent — safe to call on every
    /// sync. When HealthKit signals, an incremental sync runs, debounced to
    /// one per `observerDebounce` seconds.
    func startObserving() {
        guard available, authorized, !observing else { return }
        observing = true
        var types: [HKSampleType] = []
        for id in [HKQuantityTypeIdentifier.stepCount, .activeEnergyBurned] {
            if let t = HKObjectType.quantityType(forIdentifier: id) { types.append(t) }
        }
        if let t = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { types.append(t) }
        types.append(HKObjectType.workoutType())
        for type in types {
            let q = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, error in
                // Always complete first — that's what keeps background
                // delivery alive; then hop to the main actor to sync.
                completion()
                guard error == nil else { return }
                Task { @MainActor in self?.healthStoreDidSignal() }
            }
            store.execute(q)
            observerQueries.append(q)
            // .immediate is a request; the system may clamp some types (e.g.
            // stepCount is hourly at best in the background). Failure is
            // non-fatal — foreground observation still fires immediately.
            store.enableBackgroundDelivery(for: type, frequency: .immediate) { _, _ in }
        }
    }

    /// Debounced reaction to an observer firing: sync immediately if the
    /// last observer-driven sync is older than the debounce window, else
    /// coalesce into one trailing run.
    private func healthStoreDidSignal() {
        let since = Date().timeIntervalSince(lastObserverSync)
        if since >= Self.observerDebounce {
            lastObserverSync = Date()
            Task { await syncNow() }
        } else if !observerSyncScheduled {
            observerSyncScheduled = true
            let delay = Self.observerDebounce - since
            Task {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                observerSyncScheduled = false
                lastObserverSync = Date()
                await syncNow()
            }
        }
    }

    // MARK: sync

    func syncNow() async {
        guard available, authorized, !syncing else { return }
        startObserving()
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

        // Local-first publish: fresh device data lands immediately (and is
        // cached), even if every network call below fails.
        applyMerged(localDays: newDays, localWorkouts: newWorkouts, overview: nil)

        // Push, so the server copy includes today...
        do {
            try await Self.push(days: newDays.map(Self.wireDay),
                                workouts: newWorkouts.map(Self.wireWorkout))
            lastSync = Date()
        } catch {
            errorText = "Synced locally — couldn't reach the server."
        }

        // ...then the Withings join: read back the merged overview (server
        // day history + Withings body & sleep) and fold it in.
        if let overview = try? await Self.fetchOverview(windowDays: 30) {
            applyMerged(localDays: newDays, localWorkouts: newWorkouts, overview: overview)
        }
    }

    /// Merge policy: existing model days ∪ server days ∪ local days, with
    /// local (this device, just read) winning per date; same for workouts,
    /// keyed by start-minute + kind so ISO second round-trips don't
    /// duplicate. Withings series replace wholesale when an overview is
    /// present, and are kept as-is when offline. Everything is trimmed to
    /// 120 days and cached.
    private func applyMerged(localDays: [HealthDay], localWorkouts: [HealthWorkout],
                             overview: Overview?) {
        var byKey: [String: HealthDay] = [:]
        for d in days { byKey[d.dateKey] = d }
        if let o = overview {
            for d in o.days { byKey[d.dateKey] = d }
        }
        for d in localDays { byKey[d.dateKey] = d }
        days = Array(byKey.values.sorted { $0.date < $1.date }.suffix(120))

        var wByKey: [String: HealthWorkout] = [:]
        for w in workouts { wByKey[Self.workoutMergeKey(w)] = w }
        if let o = overview {
            for w in o.workouts { wByKey[Self.workoutMergeKey(w)] = w }
        }
        for w in localWorkouts { wByKey[Self.workoutMergeKey(w)] = w }
        let cutoff = Calendar.current.date(byAdding: .day, value: -120, to: Date()) ?? .distantPast
        workouts = wByKey.values.filter { $0.start >= cutoff }.sorted { $0.start > $1.start }

        if let o = overview {
            withingsMeasures = o.measures.sorted { $0.measuredAt < $1.measuredAt }
            withingsNights = o.nights.sorted { $0.date < $1.date }
        }

        refreshTodaySnapshot()
        lastUpdated = Date()
        saveCache()
    }

    private func refreshTodaySnapshot() {
        let key = Self.dayKey.string(from: Date())
        let today = days.first(where: { $0.dateKey == key })
        todaySnapshot = TodaySnapshot(steps: today?.steps ?? 0,
                                      activeKcal: today?.activeKcal ?? 0,
                                      exerciseMin: today?.exerciseMin ?? 0,
                                      sleepMin: today?.sleepMin ?? 0)
    }

    /// Start times round-trip through ISO seconds on the server, so key by
    /// start minute + kind.
    private static func workoutMergeKey(_ w: HealthWorkout) -> String {
        "\(Int(w.start.timeIntervalSince1970 / 60))-\(w.kind)"
    }

    // MARK: local-first cache (doctrine #2)

    /// Documents/health-cache.json — the full render model, ISO-8601 dates.
    private struct HealthCacheFile: Codable {
        var savedAt: Date
        var lastSync: Date?
        var days: [HealthDay]
        var workouts: [HealthWorkout]
        var withingsMeasures: [WithingsMeasure]
        var withingsNights: [WithingsNight]
    }

    private static var cacheURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return docs.appendingPathComponent("health-cache.json")
    }

    private static let cacheEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let cacheDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Synchronous by design: called from `init` so the first frame of the
    /// Health tab already has data — even offline. A missing or corrupt
    /// cache is simply an empty start.
    private func loadCache() {
        guard let data = try? Data(contentsOf: Self.cacheURL),
              let file = try? Self.cacheDecoder.decode(HealthCacheFile.self, from: data)
        else { return }
        days = file.days
        workouts = file.workouts
        withingsMeasures = file.withingsMeasures
        withingsNights = file.withingsNights
        lastSync = file.lastSync
        lastUpdated = file.savedAt
        refreshTodaySnapshot()
    }

    private func saveCache() {
        let file = HealthCacheFile(savedAt: lastUpdated ?? Date(),
                                   lastSync: lastSync,
                                   days: days,
                                   workouts: workouts,
                                   withingsMeasures: withingsMeasures,
                                   withingsNights: withingsNights)
        guard let data = try? Self.cacheEncoder.encode(file) else { return }
        try? data.write(to: Self.cacheURL, options: .atomic)
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

    /// Server timestamps sometimes carry fractional seconds — accept both.
    static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func parseISO(_ s: String) -> Date? {
        iso.date(from: s) ?? isoFractional.date(from: s)
    }

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

    // MARK: network (op rides the query string, x-scarlet-token — app convention)

    private static func makeRequest(op: String, body: [String: Any]) throws -> URLRequest {
        guard TokenStore.token != nil else { throw URLError(.userAuthenticationRequired) }
        var comps = URLComponents(url: AppConfig.appAPIURL, resolvingAgainstBaseURL: false)!
        var qItems = comps.queryItems ?? []
        qItems.append(URLQueryItem(name: "op", value: op))
        comps.queryItems = qItems
        var req = URLRequest(url: comps.url ?? AppConfig.appAPIURL)
        req.httpMethod = "POST"
        req.setValue(TokenStore.token ?? "", forHTTPHeaderField: "x-scarlet-token")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    private static func push(days: [[String: Any]], workouts: [[String: Any]]) async throws {
        let req = try makeRequest(op: "health_push", body: [
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

    // MARK: overview read (doctrine #3 — the Withings join)

    /// What `op=health_overview` returns, already parsed into app shapes.
    private struct Overview {
        var days: [HealthDay] = []
        var workouts: [HealthWorkout] = []
        var measures: [WithingsMeasure] = []
        var nights: [WithingsNight] = []
    }

    /// POST op=health_overview {"days": N} → server-side history + Withings.
    /// Tolerant of partial payloads: any missing array is simply empty, any
    /// malformed row is skipped.
    private static func fetchOverview(windowDays: Int) async throws -> Overview {
        let req = try makeRequest(op: "health_overview", body: ["days": windowDays])
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        var out = Overview()

        for row in (obj["days"] as? [[String: Any]]) ?? [] {
            guard let key = row["date"] as? String,
                  let date = dayKey.date(from: key) else { continue }
            var d = HealthDay(date: date, dateKey: key)
            d.steps = intVal(row["steps"])
            d.distanceM = intVal(row["distance_m"])
            d.activeKcal = intVal(row["active_kcal"])
            d.exerciseMin = intVal(row["exercise_min"])
            d.standHours = intVal(row["stand_hours"])
            d.restingHR = intVal(row["resting_hr"])
            d.hrvMS = intVal(row["hrv_ms"])
            d.sleepMin = intVal(row["sleep_min"])
            d.sleepDeepMin = intVal(row["sleep_deep_min"])
            d.sleepREMMin = intVal(row["sleep_rem_min"])
            d.sleepAwakeMin = intVal(row["sleep_awake_min"])
            out.days.append(d)
        }

        for row in (obj["workouts"] as? [[String: Any]]) ?? [] {
            guard let startS = row["start_at"] as? String,
                  let endS = row["end_at"] as? String,
                  let start = parseISO(startS),
                  let end = parseISO(endS),
                  let kind = row["kind"] as? String else { continue }
            var w = HealthWorkout(start: start, end: end, kind: kind)
            w.distanceM = intVal(row["distance_m"])
            w.kcal = intVal(row["kcal"])
            w.avgHR = intVal(row["avg_hr"])
            if let raw = row["route"] as? [[Any]] {
                w.route = raw.compactMap { pair in
                    let nums = pair.compactMap { ($0 as? NSNumber)?.doubleValue }
                    return nums.count >= 2 ? [nums[0], nums[1]] : nil
                }
            }
            out.workouts.append(w)
        }

        for row in (obj["withings_measures"] as? [[String: Any]]) ?? [] {
            guard let metric = row["metric"] as? String,
                  let atS = row["measured_at"] as? String,
                  let at = parseISO(atS) else { continue }
            out.measures.append(WithingsMeasure(metric: metric,
                                                value: dblVal(row["value"]),
                                                unit: (row["unit"] as? String) ?? "",
                                                measuredAt: at))
        }

        for row in (obj["withings_sleep"] as? [[String: Any]]) ?? [] {
            guard let night = row["night"] as? String,
                  let date = dayKey.date(from: night) else { continue }
            var n = WithingsNight(night: night, date: date)
            n.sleepScore = intVal(row["sleep_score"])
            n.totalSleepMin = intVal(row["total_sleep_min"])
            n.deepMin = intVal(row["deep_min"])
            n.remMin = intVal(row["rem_min"])
            n.lightMin = intVal(row["light_min"])
            n.awakeMin = intVal(row["awake_min"])
            n.hrAvg = intVal(row["hr_avg"])
            out.nights.append(n)
        }

        return out
    }

    /// JSON leniency: numbers may arrive as Int, Double or String.
    private static func intVal(_ any: Any?) -> Int {
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String, let v = Double(s) { return Int(v) }
        return 0
    }

    private static func dblVal(_ any: Any?) -> Double {
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String, let v = Double(s) { return v }
        return 0
    }
}
