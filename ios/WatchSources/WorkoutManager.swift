import Foundation
import HealthKit

/// Voice-initiated workouts, wrist-local by construction: HKWorkoutSession +
/// HKLiveWorkoutBuilder only exist on watchOS, so THIS is where a workout
/// actually runs — the phone can only launch the watch app with a
/// configuration (HKHealthStore.startWatchApp), and the server tools are a
/// fallback that answers honestly. The five voice tools (start_workout /
/// workout_status / pause_workout / resume_workout / end_workout) are
/// intercepted in WatchConversation BEFORE the HTTP proxy and serviced here.
///
/// One instance for the process: a second HKWorkoutSession would be rejected
/// by HealthKit anyway (one live session per app), and the delegate wiring
/// assumes a single owner — same argument as Conversation.shared.
@MainActor
final class WorkoutManager: NSObject {
    static let shared = WorkoutManager()
    private override init() {}

    /// The tool names serviced on-device instead of over the proxy. The server
    /// keeps cases for the same names so a Telegram/web call still gets an
    /// honest answer — interception here is what makes the wrist path real.
    static let toolNames: Set<String> = [
        "start_workout", "end_workout", "workout_status",
        "pause_workout", "resume_workout",
    ]

    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?

    private(set) var typeName = ""
    private(set) var startedAt: Date?
    /// Latest live metrics, updated by the builder delegate. 0 = no reading
    /// yet (a heart-rate sample takes a few seconds to arrive after start).
    private(set) var heartRateBPM = 0
    private(set) var avgHeartRateBPM = 0
    private(set) var activeKcal = 0
    /// Total distance in meters for distance-bearing types (walk/run/hike/
    /// cycle/swim); stays 0 — and is OMITTED from results — for the rest.
    private(set) var distanceMeters = 0.0
    /// Small ring of (time, cumulative distance) samples feeding the CURRENT
    /// pace (recent delta), as opposed to avg pace (= elapsed/distance).
    private var paceRing: [(at: Date, meters: Double)] = []

    var isActive: Bool { session != nil }

    // MARK: - tool entry

    /// One JSON string per call — the exact function_call_output payload.
    /// Compact keys, honest errors: the model speaks FROM this result, so a
    /// failure must read as "did not start", never as silence.
    func run(tool: String, params: [String: Any]) async -> String {
        let result: [String: Any]
        switch tool {
        case "start_workout":
            result = await start(typeNamed: (params["type"] as? String ?? "other"))
        case "end_workout":
            result = await end()
        case "workout_status":
            result = status()
        case "pause_workout":
            result = pause()
        case "resume_workout":
            result = resume()
        default:
            result = ["ok": false, "error": "unknown workout tool \(tool)"]
        }
        let data = (try? JSONSerialization.data(withJSONObject: result)) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: - authorization

    /// Workouts WRITE (the session saves a workout + its heart-rate, energy
    /// and distance samples), unlike everything else in the app — so this is
    /// a separate ask from the phone's read-only HealthSync grant, and
    /// watchOS permission is its own grant besides. READ status is
    /// deliberately not queryable (HealthKit design); SHARE status is, and
    /// sharingDenied is the one denial we can name honestly instead of
    /// failing mid-save.
    func requestAuthorization() async -> String? {
        guard HKHealthStore.isHealthDataAvailable() else {
            return "Health data isn't available on this watch"
        }
        // Two sets, same members: Set is not covariant in Swift, so the
        // share (Set<HKSampleType>) and read (Set<HKObjectType>) parameters
        // need separately-typed literals.
        let share: Set<HKSampleType> = [
            HKObjectType.workoutType(),
            HKQuantityType(.heartRate),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.distanceCycling),
            HKQuantityType(.distanceSwimming),
        ]
        let read: Set<HKObjectType> = [
            HKObjectType.workoutType(),
            HKQuantityType(.heartRate),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.distanceCycling),
            HKQuantityType(.distanceSwimming),
        ]
        do {
            try await store.requestAuthorization(toShare: share, read: read)
        } catch {
            return "Health authorization failed: \(error.localizedDescription)"
        }
        if store.authorizationStatus(for: HKObjectType.workoutType()) == .sharingDenied {
            return "Health permission denied — enable Workouts for Scarlet in Settings → Health"
        }
        return nil
    }

    // MARK: - type map

    /// One row of the spoken-name → HealthKit table. Indoor/outdoor matters:
    /// it picks the sensor strategy (GPS vs motion) and how Fitness files the
    /// workout; for swims the pool/open-water split additionally selects the
    /// stroke-detection model.
    private struct Kind {
        let keys: [String]
        let name: String
        let activity: HKWorkoutActivityType
        let location: HKWorkoutSessionLocationType
        var swim: HKWorkoutSwimmingLocationType? = nil
    }

    /// Ordered SPECIFIC-FIRST: "indoor run" must win before "run", "open
    /// water" before "swim", "kickbox" before "box". Matching is
    /// case-insensitive substring over his spoken words, so "start an outdoor
    /// bike ride" lands on cycling without the model naming an enum.
    /// NOTE: the phone keeps a twin of this table in Conversation.swift
    /// (performWorkoutTool) — it must map to the SAME (activity, location)
    /// pairs, because a phone-launched workout arrives here as a bare
    /// HKWorkoutConfiguration and gets its spoken name back from this table.
    private static let kinds: [Kind] = [
        Kind(keys: ["treadmill", "indoor run"], name: "indoor run", activity: .running, location: .indoor),
        Kind(keys: ["indoor walk"], name: "indoor walk", activity: .walking, location: .indoor),
        Kind(keys: ["open water", "sea swim", "ocean swim"], name: "open-water swim", activity: .swimming, location: .outdoor, swim: .openWater),
        Kind(keys: ["swim", "pool", "שחייה", "שחיה"], name: "pool swim", activity: .swimming, location: .indoor, swim: .pool),
        Kind(keys: ["spin", "indoor cycl", "indoor bike", "indoor ride", "stationary bike", "exercise bike", "peloton"], name: "indoor cycling", activity: .cycling, location: .indoor),
        Kind(keys: ["kickbox"], name: "kickboxing", activity: .kickboxing, location: .indoor),
        Kind(keys: ["box"], name: "boxing", activity: .boxing, location: .indoor),
        Kind(keys: ["jump rope", "jumprope", "jump-rope", "skipping"], name: "jump rope", activity: .jumpRope, location: .indoor),
        Kind(keys: ["functional"], name: "functional strength", activity: .functionalStrengthTraining, location: .indoor),
        Kind(keys: ["strength", "weight", "lifting", "lift", "משקולות", "כוח"], name: "strength training", activity: .traditionalStrengthTraining, location: .indoor),
        Kind(keys: ["stair", "stepmill"], name: "stair climbing", activity: .stairClimbing, location: .indoor),
        Kind(keys: ["stepper", "step training", "step machine"], name: "stepper", activity: .stepTraining, location: .indoor),
        Kind(keys: ["elliptical", "cross trainer", "cross-trainer"], name: "elliptical", activity: .elliptical, location: .indoor),
        Kind(keys: ["rowing", "row", "erg"], name: "rowing", activity: .rowing, location: .indoor),
        Kind(keys: ["hiit", "high intensity", "high-intensity", "interval", "tabata"], name: "HIIT", activity: .highIntensityIntervalTraining, location: .indoor),
        Kind(keys: ["yoga", "יוגה"], name: "yoga", activity: .yoga, location: .indoor),
        Kind(keys: ["pilates", "פילאטיס"], name: "pilates", activity: .pilates, location: .indoor),
        Kind(keys: ["core", "abs"], name: "core training", activity: .coreTraining, location: .indoor),
        Kind(keys: ["cooldown", "cool down", "cool-down"], name: "cooldown", activity: .cooldown, location: .indoor),
        Kind(keys: ["stretch", "flexibility", "mobility"], name: "stretching", activity: .flexibility, location: .indoor),
        Kind(keys: ["danc", "zumba", "ריקוד"], name: "dance", activity: .cardioDance, location: .indoor),
        Kind(keys: ["hike", "hiking", "trail"], name: "hiking", activity: .hiking, location: .outdoor),
        Kind(keys: ["cycl", "bike", "biking", "ride", "אופניים"], name: "outdoor cycling", activity: .cycling, location: .outdoor),
        Kind(keys: ["run", "jog", "ריצה"], name: "outdoor run", activity: .running, location: .outdoor),
        Kind(keys: ["walk", "הליכה"], name: "outdoor walk", activity: .walking, location: .outdoor),
    ]

    /// Free-form spoken name → configuration + the name she says back.
    /// Unrecognized names start honestly as .other and ECHO the requested
    /// name, so "start badminton" becomes "tracking badminton as a general
    /// workout", never a silent walk.
    private static func resolve(_ raw: String) -> (config: HKWorkoutConfiguration, name: String, recognized: Bool) {
        let q = raw.lowercased()
        let c = HKWorkoutConfiguration()
        if let k = kinds.first(where: { k in k.keys.contains(where: { q.contains($0) }) }) {
            c.activityType = k.activity
            c.locationType = k.location
            if let s = k.swim { c.swimmingLocationType = s }
            return (c, k.name, true)
        }
        c.activityType = .other
        c.locationType = .unknown
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return (c, trimmed.isEmpty ? "workout" : trimmed, false)
    }

    private static func canonicalName(for configuration: HKWorkoutConfiguration) -> String {
        if let k = kinds.first(where: { $0.activity == configuration.activityType
                                     && $0.location == configuration.locationType }) {
            return k.name
        }
        if let k = kinds.first(where: { $0.activity == configuration.activityType }) {
            return k.name
        }
        return "workout"
    }

    /// The cumulative-distance quantity HealthKit fills for this activity, or
    /// nil for types where distance is meaningless (strength, yoga, HIIT…) —
    /// nil is what keeps distance/pace OUT of those results instead of zeros.
    // nonisolated: pure type mapping, and the live-builder delegate calls it
    // from HealthKit's own (non-main) queue — MainActor isolation there is a
    // compile error, not just a hazard.
    nonisolated private static func distanceType(for activity: HKWorkoutActivityType) -> HKQuantityType? {
        switch activity {
        case .walking, .running, .hiking: return HKQuantityType(.distanceWalkingRunning)
        case .cycling: return HKQuantityType(.distanceCycling)
        case .swimming: return HKQuantityType(.distanceSwimming)
        default: return nil
        }
    }

    private var tracksDistance: Bool {
        guard let s = session else { return false }
        return Self.distanceType(for: s.workoutConfiguration.activityType) != nil
    }

    // MARK: - lifecycle

    func start(typeNamed raw: String) async -> [String: Any] {
        let (config, name, recognized) = Self.resolve(raw)
        var out = await start(configuration: config, named: name)
        if !recognized, out["ok"] as? Bool == true {
            out["requested"] = raw
            out["note"] = "no exact Workout-app match for '\(raw)' — RUNNING as a general workout (heart rate + calories still tracked). Say you started '\(raw)' as a general session."
        }
        return out
    }

    /// Phone-launched entry: HKHealthStore.startWatchApp delivers the
    /// configuration through WKApplicationDelegate.handle(_:) — same path,
    /// the type name is recovered from the configuration.
    func start(configuration: HKWorkoutConfiguration) async {
        _ = await start(configuration: configuration,
                        named: Self.canonicalName(for: configuration))
    }

    private func start(configuration: HKWorkoutConfiguration, named name: String) async -> [String: Any] {
        if let s = session {
            // One live session per app is a HealthKit rule, not a choice —
            // starting over an active workout would throw anyway. Honest no.
            return ["ok": false, "error": "a \(typeName) workout is already running (\(Int(-1 * (startedAt ?? Date()).timeIntervalSinceNow))s in) — end it first",
                    "type": typeName, "state": String(describing: s.state)]
        }
        if let denied = await requestAuthorization() {
            return ["ok": false, "error": denied]
        }
        do {
            let s = try HKWorkoutSession(healthStore: store, configuration: configuration)
            let b = s.associatedWorkoutBuilder()
            b.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: configuration)
            s.delegate = self
            b.delegate = self
            let startDate = Date()
            s.startActivity(with: startDate)
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                b.beginCollection(withStart: startDate) { ok, error in
                    if ok { cont.resume() }
                    else { cont.resume(throwing: error ?? NSError(domain: "ScarletWorkout", code: 1)) }
                }
            }
            session = s
            builder = b
            typeName = name
            startedAt = startDate
            heartRateBPM = 0
            avgHeartRateBPM = 0
            activeKcal = 0
            distanceMeters = 0
            paceRing.removeAll()
            var out: [String: Any] = ["ok": true, "type": name, "elapsed_sec": 0,
                    "note": "workout is RUNNING on the watch — heart rate arrives within seconds; workout_status reads the live numbers"]
            if configuration.activityType == .swimming {
                // Water Lock engages with a swim: the touchscreen — and in
                // practice the mic path — go quiet until he turns the crown.
                out["note"] = "swim is RUNNING on the watch — Water Lock engages, so mid-swim voice control is limited until he unlocks; status and ending work again after"
            }
            return out
        } catch {
            // A session that failed to begin must not linger half-built: a
            // stale session would block every future start with "already
            // running" while nothing is actually collecting.
            session?.end()
            session = nil
            builder = nil
            return ["ok": false, "error": "couldn't start the workout: \(error.localizedDescription)"]
        }
    }

    /// Elapsed EXERCISE seconds: the builder's clock stops while paused —
    /// exactly what the Workout app shows — with wall clock as the fallback
    /// before the builder exists.
    private var elapsedSeconds: Int {
        if let b = builder { return Int(b.elapsedTime) }
        guard let startedAt else { return 0 }
        return Int(Date().timeIntervalSince(startedAt))
    }

    /// CURRENT pace min/km from the recent distance delta (last ≤75s of ring
    /// samples). nil when he's effectively stationary, the workout has no
    /// distance, or the session is paused — omission beats a made-up number.
    private func currentPaceMinPerKm() -> Double? {
        guard let last = paceRing.last else { return nil }
        let cutoff = last.at.addingTimeInterval(-75)
        guard let base = paceRing.first(where: { $0.at >= cutoff }), base.at < last.at else { return nil }
        let dd = last.meters - base.meters
        let dt = last.at.timeIntervalSince(base.at)
        guard dd >= 5, dt >= 20 else { return nil }
        let pace = (dt / 60) / (dd / 1000)
        // >60 min/km is standing still with sensor noise, not a pace.
        guard pace <= 60 else { return nil }
        return (pace * 100).rounded() / 100
    }

    /// AVG pace min/km = exercise time / total distance. Requires enough
    /// distance for the number to mean something.
    private func avgPaceMinPerKm() -> Double? {
        guard distanceMeters >= 50, elapsedSeconds > 0 else { return nil }
        let pace = (Double(elapsedSeconds) / 60) / (distanceMeters / 1000)
        guard pace <= 60 else { return nil }
        return (pace * 100).rounded() / 100
    }

    func status() -> [String: Any] {
        guard let s = session, startedAt != nil else {
            return ["ok": false, "error": "no workout is running on this watch"]
        }
        let paused = s.state == .paused
        var out: [String: Any] = [
            "ok": true, "type": typeName,
            "state": paused ? "paused" : "running",
            "elapsed_sec": elapsedSeconds,
            "active_kcal": activeKcal,
        ]
        // 0 BPM is "no sample yet", not a reading — omit rather than let the
        // model speak a zero pulse. Same for distance/pace on distance-less
        // types: absent keys, never zeros.
        if heartRateBPM > 0 { out["heart_rate_bpm"] = heartRateBPM }
        if avgHeartRateBPM > 0 { out["avg_heart_rate_bpm"] = avgHeartRateBPM }
        if tracksDistance, distanceMeters > 0 {
            out["distance_m"] = Int(distanceMeters.rounded())
            if let avg = avgPaceMinPerKm() { out["avg_pace_min_per_km"] = avg }
            if !paused, let cur = currentPaceMinPerKm() { out["pace_min_per_km"] = cur }
        }
        return out
    }

    // MARK: - pause / resume

    /// pause()/resume() on HKWorkoutSession are requests the session applies
    /// almost immediately; the delegate confirms via didChangeTo. State
    /// checks here keep the answers honest: "already paused" / "no workout
    /// running" instead of a silent no-op.
    func pause() -> [String: Any] {
        guard let s = session else {
            return ["ok": false, "error": "no workout is running on this watch"]
        }
        switch s.state {
        case .paused:
            return ["ok": false, "error": "the \(typeName) workout is already paused", "type": typeName, "state": "paused"]
        case .running:
            s.pause()
            // Stale motion must not leak into the next pace reading — the
            // ring restarts with post-resume samples.
            paceRing.removeAll()
            return ["ok": true, "type": typeName, "state": "paused",
                    "elapsed_sec": elapsedSeconds,
                    "note": "workout PAUSED on the watch — the timer and rings stop until he resumes"]
        default:
            return ["ok": false, "error": "the workout can't be paused right now (state: \(String(describing: s.state)))", "type": typeName]
        }
    }

    func resume() -> [String: Any] {
        guard let s = session else {
            return ["ok": false, "error": "no workout is running on this watch"]
        }
        switch s.state {
        case .running:
            return ["ok": false, "error": "the \(typeName) workout is already running — nothing was paused", "type": typeName, "state": "running"]
        case .paused:
            s.resume()
            return ["ok": true, "type": typeName, "state": "running",
                    "elapsed_sec": elapsedSeconds,
                    "note": "workout RESUMED on the watch — the clock is running again"]
        default:
            return ["ok": false, "error": "the workout can't be resumed right now (state: \(String(describing: s.state)))", "type": typeName]
        }
    }

    func end() async -> [String: Any] {
        guard let s = session, let b = builder, startedAt != nil else {
            return ["ok": false, "error": "no workout is running on this watch"]
        }
        let endDate = Date()
        var summary: [String: Any] = [
            "type": typeName,
            "elapsed_sec": elapsedSeconds,
            "active_kcal": activeKcal,
        ]
        if heartRateBPM > 0 { summary["heart_rate_bpm"] = heartRateBPM }
        if avgHeartRateBPM > 0 { summary["avg_heart_rate_bpm"] = avgHeartRateBPM }
        if tracksDistance, distanceMeters > 0 {
            summary["distance_m"] = Int(distanceMeters.rounded())
            if let avg = avgPaceMinPerKm() { summary["avg_pace_min_per_km"] = avg }
        }
        s.end()
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                b.endCollection(withEnd: endDate) { ok, error in
                    if ok { cont.resume() }
                    else { cont.resume(throwing: error ?? NSError(domain: "ScarletWorkout", code: 2)) }
                }
            }
            let workout: HKWorkout? = try await withCheckedThrowingContinuation { cont in
                b.finishWorkout { workout, error in
                    if let error { cont.resume(throwing: error) } else { cont.resume(returning: workout) }
                }
            }
            reset()
            var out = summary
            out["ok"] = true
            out["saved"] = workout != nil
            out["note"] = workout != nil
                ? "workout ended and SAVED to Health — it counts toward his rings"
                : "workout ended but HealthKit returned no saved workout — say the save is uncertain"
            return out
        } catch {
            // The session is over either way (s.end() already ran); only the
            // SAVE failed. Report the split honestly — "ended but not saved"
            // is a different sentence from "still running".
            reset()
            var out = summary
            out["ok"] = false
            out["error"] = "workout ended but saving to Health failed: \(error.localizedDescription)"
            return out
        }
    }

    private func reset() {
        session = nil
        builder = nil
        typeName = ""
        startedAt = nil
        heartRateBPM = 0
        avgHeartRateBPM = 0
        activeKcal = 0
        distanceMeters = 0
        paceRing.removeAll()
    }
}

// MARK: - HealthKit delegates

// Delegate callbacks arrive on HealthKit's own queues; every touch of
// main-actor state hops explicitly — same discipline as the audio tap.
extension WorkoutManager: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                                    didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState,
                                    date: Date) {
        // Pause/resume moves are driven by our own calls (and confirmed
        // here); a SYSTEM-driven pause still clears the pace ring so a stale
        // delta can't fabricate a current pace at resume. The one surprise —
        // the system ending the session (battery, user force-quit) — lands
        // as .ended with no end() of ours, and the next status()/end() then
        // answers "no workout running".
        if toState == .paused {
            Task { @MainActor [weak self] in
                guard let self, self.session === workoutSession else { return }
                self.paceRing.removeAll()
            }
        }
        if toState == .ended {
            Task { @MainActor [weak self] in
                guard let self, self.session === workoutSession else { return }
                // Builder teardown already happened if end() drove this; a
                // system-driven end leaves the builder unfinished — drop the
                // handles so a fresh start is possible. The partial workout
                // is HealthKit's to keep or discard.
                self.reset()
            }
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                                    didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.session === workoutSession else { return }
            self.reset()
        }
    }
}

extension WorkoutManager: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder,
                                    didCollectDataOf collectedTypes: Set<HKSampleType>) {
        // Read the statistics on the callback, publish on the main actor —
        // mostRecentQuantity/sumQuantity/averageQuantity are snapshots, safe
        // to take here.
        var hr: Int?
        var avgHR: Int?
        var kcal: Int?
        var dist: Double?
        let bpm = HKUnit.count().unitDivided(by: .minute())
        if collectedTypes.contains(HKQuantityType(.heartRate)),
           let stats = workoutBuilder.statistics(for: HKQuantityType(.heartRate)) {
            if let q = stats.mostRecentQuantity() { hr = Int(q.doubleValue(for: bpm).rounded()) }
            if let q = stats.averageQuantity() { avgHR = Int(q.doubleValue(for: bpm).rounded()) }
        }
        if collectedTypes.contains(HKQuantityType(.activeEnergyBurned)),
           let q = workoutBuilder.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity() {
            kcal = Int(q.doubleValue(for: .kilocalorie()).rounded())
        }
        if let dType = Self.distanceType(for: workoutBuilder.workoutConfiguration.activityType),
           collectedTypes.contains(dType),
           let q = workoutBuilder.statistics(for: dType)?.sumQuantity() {
            dist = q.doubleValue(for: .meter())
        }
        guard hr != nil || avgHR != nil || kcal != nil || dist != nil else { return }
        Task { @MainActor [weak self] in
            guard let self, self.builder === workoutBuilder else { return }
            if let hr { self.heartRateBPM = hr }
            if let avgHR { self.avgHeartRateBPM = avgHR }
            if let kcal { self.activeKcal = kcal }
            if let dist {
                self.distanceMeters = dist
                // Feed the current-pace ring only while RUNNING — a paused
                // session can still tick out straggler samples.
                if self.session?.state == .running {
                    self.paceRing.append((at: Date(), meters: dist))
                    // Bounded: ~2 minutes of samples is all current pace reads.
                    if self.paceRing.count > 48 { self.paceRing.removeFirst(self.paceRing.count - 48) }
                }
            }
        }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {
        // Pause/resume events surface through the SESSION delegate; elapsed
        // time is the builder's own pause-aware clock (elapsedTime).
    }
}
