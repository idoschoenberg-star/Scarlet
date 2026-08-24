import Foundation
import HealthKit
import CoreLocation
import UIKit

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
    /// Flights of stairs climbed (HealthKit `flightsClimbed`). The Watch shows
    /// this on the same screen as steps; Scarlet had no elevation axis at all
    /// until now (Ido, 2026-08-18: "מה הנתונים בגובה?").
    var flightsClimbed: Int = 0
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
    /// Cumulative ascent in metres. Read from HealthKit's own
    /// `elevationAscended` workout metadata when the device recorded it, and
    /// otherwise INTEGRATED from the route's altitudes — a Watch walk in the
    /// Alps has a real climb even when the metadata key is absent.
    var elevationGainM: Int = 0
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
    /// Flights of stairs climbed today — the elevation axis Scarlet used to
    /// have no answer for at all.
    var flightsClimbed: Int = 0
    /// Last night's total (the night attributed to today's wake date).
    var sleepMin: Int = 0
}

/// HealthKit query watchdog. A query whose callback never fires (a rare but
/// real HealthKit failure mode) must cost `seconds`, not the whole sync:
/// syncNow() awaits these queries with `syncing == true`, so one silent query
/// would latch the flag and every future sync — launch, foreground, observer,
/// call-start — would no-op forever with zero trace (the 2026-08-15 "no
/// health row since yesterday" outage pattern). The abandoned query resumes
/// its continuation harmlessly later if HealthKit ever answers.
private func hkTimeout<T>(_ seconds: Double = 10, fallback: T,
                          _ op: @escaping () async -> T) async -> T {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await op() }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first ?? fallback
    }
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
    /// Guards + throttles the fast today-only path (`syncToday`).
    private var todaySyncing = false
    private var lastTodaySync = Date.distantPast
    private var observerSyncScheduled = false
    private static let observerDebounce: TimeInterval = 60

    private init() {
        authorized = UserDefaults.standard.bool(forKey: Self.authorizedKey)
        // Local-first: paint from the cache before any query or network call.
        loadCache()
    }

    /// One server breadcrumb per skip-reason per process — enough to see
    /// "the sync never ran and here's why" without flooding agent_log.
    private static var notedReasons = Set<String>()
    private static func noteOnce(_ reason: String) {
        guard !notedReasons.contains(reason) else { return }
        notedReasons.insert(reason)
        FlightRecorder.telemetry(kind: "health_sync", detail: ["skip": reason])
    }

    var available: Bool { HKHealthStore.isHealthDataAvailable() }

    // MARK: authorization

    /// Everything the tab reads. Share (write) nothing.
    private static func readTypes() -> Set<HKObjectType> {
        var read: Set<HKObjectType> = []
        let quantities: [HKQuantityTypeIdentifier] = [
            .stepCount, .distanceWalkingRunning, .activeEnergyBurned,
            .appleExerciseTime, .restingHeartRate,
            .heartRateVariabilitySDNN, .heartRate, .flightsClimbed,
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
        for id in [HKQuantityTypeIdentifier.stepCount, .activeEnergyBurned, .flightsClimbed] {
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
        // Breadcrumb every skip reason once per process (agent_log stage
        // app_health_sync): the 2026-08-15 outage — no server row for a full
        // day — was invisible precisely because every exit here is silent.
        guard available, authorized, !syncing else {
            if !authorized { Self.noteOnce("skip-unauthorized") }
            return
        }
        // HealthKit data is unreadable while the device is locked (a CarPlay
        // drive, a pocketed phone): every query would return zeros, and
        // pushing those would overwrite real server rows with zeros. Skip
        // the whole run — the observer/foreground paths re-sync on unlock.
        guard UIApplication.shared.isProtectedDataAvailable else {
            Self.noteOnce("skip-locked")
            return
        }
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
        let flights = await dailyStats(.flightsClimbed, unit: .count(),
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
            d.flightsClimbed = Int(flights[dayStart] ?? 0)
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
            out.elevationGainM = Self.elevationGain(for: w, route: locations)
            newWorkouts.append(out)
        }

        // Local-first publish: fresh device data lands immediately (and is
        // cached), even if every network call below fails.
        applyMerged(localDays: newDays, localWorkouts: newWorkouts, overview: nil)

        // Push, so the server copy includes today...
        var pushResult = "ok"
        do {
            try await Self.push(days: newDays.map(Self.wireDay),
                                workouts: newWorkouts.map(Self.wireWorkout))
            lastSync = Date()
        } catch {
            errorText = "Synced locally — couldn't reach the server."
            pushResult = String(describing: error).prefix(200).description
        }
        // The one line that makes this pipeline debuggable from the server:
        // what today looked like on-device and whether the push landed.
        FlightRecorder.telemetry(kind: "health_sync", detail: [
            "today_steps": newDays.last?.steps ?? -1,
            "today_kcal": newDays.last?.activeKcal ?? -1,
            "days": newDays.count,
            "workouts": newWorkouts.count,
            "push": pushResult,
        ])

        // ...then the Withings join: read back the merged overview (server
        // day history + Withings body & sleep) and fold it in.
        if let overview = try? await Self.fetchOverview(windowDays: 30) {
            applyMerged(localDays: newDays, localWorkouts: newWorkouts, overview: overview)
        }
    }

    /// TODAY, FAST (task #120). `syncNow()` reads a 14-day window across ~8
    /// statistics collections plus every workout and its route — seconds of
    /// work. That is fine for the Health tab, and far too slow for the moment
    /// that actually matters: he starts a call and asks "how many steps today"
    /// within a couple of seconds, and the answer comes from the SERVER row.
    /// Before this, that row was whatever the last full sync left behind — the
    /// 2026-08-18 evidence, Watch 17,985 against a spoken "18,238".
    ///
    /// So: five cheap single-day sums, one one-row push, no routes, no
    /// workouts, no read-back. Runs alongside the full sync (the upsert is
    /// keyed by date and idempotent) and throttles to one per 20 s so a burst
    /// of foreground/call-start events costs one round trip.
    func syncToday() async {
        guard available, authorized, !todaySyncing else { return }
        guard UIApplication.shared.isProtectedDataAvailable else {
            Self.noteOnce("skip-locked-today")
            return
        }
        guard Date().timeIntervalSince(lastTodaySync) > 20 else { return }
        todaySyncing = true
        lastTodaySync = Date()
        defer { todaySyncing = false }

        let cal = Calendar.current
        let now = Date()
        let todayStart = cal.startOfDay(for: now)

        async let stepsQ = dailyStats(.stepCount, unit: .count(),
                                      options: .cumulativeSum, from: todayStart, to: now)
        async let distQ = dailyStats(.distanceWalkingRunning, unit: .meter(),
                                     options: .cumulativeSum, from: todayStart, to: now)
        async let kcalQ = dailyStats(.activeEnergyBurned, unit: .kilocalorie(),
                                     options: .cumulativeSum, from: todayStart, to: now)
        async let exQ = dailyStats(.appleExerciseTime, unit: .minute(),
                                   options: .cumulativeSum, from: todayStart, to: now)
        async let flightsQ = dailyStats(.flightsClimbed, unit: .count(),
                                        options: .cumulativeSum, from: todayStart, to: now)
        let (steps, dist, kcal, ex, flights) = await (stepsQ, distQ, kcalQ, exQ, flightsQ)

        var d = HealthDay(date: todayStart, dateKey: Self.dayKey.string(from: todayStart))
        // Carry forward everything this fast path does not read (sleep, stand,
        // resting HR, HRV) from what the model already holds for today, so the
        // push never blanks a field it simply didn't look at.
        if let existing = days.first(where: { $0.dateKey == d.dateKey }) { d = existing }
        d.steps = Int(steps[todayStart] ?? 0)
        d.distanceM = Int(dist[todayStart] ?? 0)
        d.activeKcal = Int(kcal[todayStart] ?? 0)
        d.exerciseMin = Int(ex[todayStart] ?? 0)
        d.flightsClimbed = Int(flights[todayStart] ?? 0)

        applyMerged(localDays: [d], localWorkouts: [], overview: nil)
        try? await Self.push(days: [Self.wireDay(d)], workouts: [])
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
                                      flightsClimbed: today?.flightsClimbed ?? 0,
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
        // DEVICE BOUNDARY: a device Ido classified as CORPORATE keeps no
        // health data on disk — purge any file left from before the label
        // and start empty. (A still-unknown device only stops WRITING, in
        // saveCache below, so a mislabeled personal phone loses nothing
        // while the one-time question is pending.)
        if DeviceBoundary.cachedTier == "corporate" {
            try? FileManager.default.removeItem(at: Self.cacheURL)
            return
        }
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
        // DEVICE BOUNDARY (fail-closed): on a corporate — or still-unknown —
        // device, health data lives in memory only; nothing is persisted.
        // An explicitly corporate device also sheds any pre-label file.
        if DeviceBoundary.cachedTierIsCorporateEffective {
            if DeviceBoundary.cachedTier == "corporate" {
                try? FileManager.default.removeItem(at: Self.cacheURL)
            }
            return
        }
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
        let store = self.store
        return await hkTimeout(fallback: [:]) {
            await withCheckedContinuation { cont in
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
                store.execute(q)
            }
        }
    }

    private func categorySamples(_ id: HKCategoryTypeIdentifier,
                                 from start: Date, to end: Date) async -> [HKCategorySample] {
        guard let type = HKObjectType.categoryType(forIdentifier: id) else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        let store = self.store
        return await hkTimeout(fallback: []) {
            await withCheckedContinuation { cont in
                let q = HKSampleQuery(sampleType: type, predicate: predicate,
                                      limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, samples, _ in
                    cont.resume(returning: (samples as? [HKCategorySample]) ?? [])
                }
                store.execute(q)
            }
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
        let store = self.store
        return await hkTimeout(fallback: []) {
            await withCheckedContinuation { cont in
                let q = HKSampleQuery(sampleType: HKObjectType.workoutType(),
                                      predicate: predicate,
                                      limit: HKObjectQueryNoLimit,
                                      sortDescriptors: [sort]) { _, samples, _ in
                    cont.resume(returning: (samples as? [HKWorkout]) ?? [])
                }
                store.execute(q)
            }
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
        let store = self.store
        return await hkTimeout(fallback: 0) {
            await withCheckedContinuation { cont in
                let q = HKStatisticsQuery(quantityType: hrType,
                                          quantitySamplePredicate: predicate,
                                          options: .discreteAverage) { _, stats, _ in
                    cont.resume(returning: stats?.averageQuantity()?.doubleValue(for: bpm) ?? 0)
                }
                store.execute(q)
            }
        }
    }

    /// All CLLocations of a workout's (first) route, in order. Empty when the
    /// workout has no route or the route grant was withheld.
    private func routeLocations(for workout: HKWorkout) async -> [CLLocation] {
        let store = self.store
        let routes: [HKWorkoutRoute] = await hkTimeout(fallback: []) {
            await withCheckedContinuation { cont in
                let predicate = HKQuery.predicateForObjects(from: workout)
                let q = HKSampleQuery(sampleType: HKSeriesType.workoutRoute(),
                                      predicate: predicate,
                                      limit: HKObjectQueryNoLimit,
                                      sortDescriptors: nil) { _, samples, _ in
                    cont.resume(returning: (samples as? [HKWorkoutRoute]) ?? [])
                }
                store.execute(q)
            }
        }
        guard let route = routes.first else { return [] }
        // Routes stream in batches — give long walks more rope than the
        // point queries, but still never let one wedge the whole sync.
        return await hkTimeout(20, fallback: []) {
            await withCheckedContinuation { cont in
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
                store.execute(q)
            }
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

    /// Cumulative ascent for one workout, in metres.
    ///
    /// Two sources, in order of trust:
    /// 1. `HKMetadataKeyElevationAscended` — what the Watch itself recorded
    ///    with its barometric altimeter. Authoritative when present.
    /// 2. The route's altitudes, integrated: sum every positive step between
    ///    consecutive fixes. GPS altitude is noisy, so steps under a 1.5 m
    ///    threshold are treated as jitter and dropped — without that floor a
    ///    flat walk "climbs" hundreds of metres of noise.
    ///
    /// Zero means "no ascent data", never "flat" — the server and the tool
    /// stay honest about the difference by omitting the field rather than
    /// claiming a zero climb.
    static func elevationGain(for workout: HKWorkout, route: [CLLocation]) -> Int {
        if let q = workout.metadata?[HKMetadataKeyElevationAscended] as? HKQuantity {
            let m = q.doubleValue(for: .meter())
            if m > 0 { return Int(m.rounded()) }
        }
        guard route.count > 1 else { return 0 }
        var gain = 0.0
        var reference: Double?
        for loc in route {
            // verticalAccuracy < 0 means the altitude is not valid at all.
            guard loc.verticalAccuracy >= 0 else { continue }
            let alt = loc.altitude
            guard let prev = reference else { reference = alt; continue }
            let delta = alt - prev
            if delta >= 1.5 {
                gain += delta
                reference = alt
            } else if delta <= -1.5 {
                reference = alt   // descending: move the reference down, add nothing
            }
        }
        return Int(gain.rounded())
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
            "flights_climbed": d.flightsClimbed,
            "resting_hr": d.restingHR,
            "hrv_ms": d.hrvMS,
            "sleep_min": d.sleepMin,
            "sleep_deep_min": d.sleepDeepMin,
            "sleep_rem_min": d.sleepREMMin,
            "sleep_awake_min": d.sleepAwakeMin,
        ]
    }

    static func wireWorkout(_ w: HealthWorkout) -> [String: Any] {
        var out: [String: Any] = [
            "start": iso.string(from: w.start),
            "end": iso.string(from: w.end),
            "kind": w.kind,
            "distance_m": w.distanceM,
            "kcal": w.kcal,
            "avg_hr": w.avgHR,
            "route": w.route,
        ]
        // OMITTED when zero, deliberately: the server stores a missing key as
        // NULL, and "no altitude was recorded" is a different claim from "this
        // route was flat". Sending 0 would let Scarlet answer "you climbed
        // nothing" about a walk whose device simply had no altimeter fix —
        // exactly the class of confident-but-wrong answer this batch is
        // fixing. Flights climbed is NOT treated this way: a genuine zero-step
        // day really did climb zero flights.
        if w.elevationGainM > 0 { out["elevation_gain_m"] = w.elevationGainM }
        return out
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
            d.flightsClimbed = intVal(row["flights_climbed"])
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
            w.elevationGainM = intVal(row["elevation_gain_m"])
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
