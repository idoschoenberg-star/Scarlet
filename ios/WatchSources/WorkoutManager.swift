import Foundation
import HealthKit

/// Voice-initiated workouts, wrist-local by construction: HKWorkoutSession +
/// HKLiveWorkoutBuilder only exist on watchOS, so THIS is where a workout
/// actually runs — the phone can only launch the watch app with a
/// configuration (HKHealthStore.startWatchApp), and the server tools are a
/// fallback that answers honestly. The three voice tools (start_workout /
/// workout_status / end_workout) are intercepted in WatchConversation BEFORE
/// the HTTP proxy and serviced here.
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
    static let toolNames: Set<String> = ["start_workout", "end_workout", "workout_status"]

    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?

    private(set) var typeName = ""
    private(set) var startedAt: Date?
    /// Latest live metrics, updated by the builder delegate. 0 = no reading
    /// yet (a heart-rate sample takes a few seconds to arrive after start).
    private(set) var heartRateBPM = 0
    private(set) var activeKcal = 0

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
        default:
            result = ["ok": false, "error": "unknown workout tool \(tool)"]
        }
        let data = (try? JSONSerialization.data(withJSONObject: result)) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: - authorization

    /// Workouts WRITE (the session saves a workout + its heart-rate and
    /// energy samples), unlike everything else in the app — so this is a
    /// separate ask from the phone's read-only HealthSync grant, and watchOS
    /// permission is its own grant besides. READ status is deliberately not
    /// queryable (HealthKit design); SHARE status is, and sharingDenied is
    /// the one denial we can name honestly instead of failing mid-save.
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
        ]
        let read: Set<HKObjectType> = [
            HKObjectType.workoutType(),
            HKQuantityType(.heartRate),
            HKQuantityType(.activeEnergyBurned),
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

    // MARK: - lifecycle

    /// The voice tool's enum → HealthKit's. Indoor/outdoor matters: it picks
    /// the sensor strategy (GPS vs motion) and how Fitness files the workout.
    private static func configuration(for name: String) -> HKWorkoutConfiguration {
        let c = HKWorkoutConfiguration()
        switch name {
        case "walking":    c.activityType = .walking; c.locationType = .outdoor
        case "elliptical": c.activityType = .elliptical; c.locationType = .indoor
        case "strength":   c.activityType = .traditionalStrengthTraining; c.locationType = .indoor
        case "running":    c.activityType = .running; c.locationType = .outdoor
        default:           c.activityType = .other; c.locationType = .unknown
        }
        return c
    }

    private static func canonicalName(for type: HKWorkoutActivityType) -> String {
        switch type {
        case .walking: return "walking"
        case .elliptical: return "elliptical"
        case .traditionalStrengthTraining, .functionalStrengthTraining: return "strength"
        case .running: return "running"
        default: return "other"
        }
    }

    func start(typeNamed raw: String) async -> [String: Any] {
        let name = ["walking", "elliptical", "strength", "running", "other"].contains(raw.lowercased())
            ? raw.lowercased() : "other"
        return await start(configuration: Self.configuration(for: name), named: name)
    }

    /// Phone-launched entry: HKHealthStore.startWatchApp delivers the
    /// configuration through WKApplicationDelegate.handle(_:) — same path,
    /// the type name is recovered from the configuration.
    func start(configuration: HKWorkoutConfiguration) async {
        _ = await start(configuration: configuration,
                        named: Self.canonicalName(for: configuration.activityType))
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
            activeKcal = 0
            return ["ok": true, "type": name, "elapsed_sec": 0,
                    "note": "workout is RUNNING on the watch — heart rate arrives within seconds; workout_status reads the live numbers"]
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

    func status() -> [String: Any] {
        guard let startedAt, session != nil else {
            return ["ok": false, "error": "no workout is running on this watch"]
        }
        var out: [String: Any] = [
            "ok": true, "type": typeName,
            "elapsed_sec": Int(Date().timeIntervalSince(startedAt)),
            "active_kcal": activeKcal,
        ]
        // 0 BPM is "no sample yet", not a reading — omit rather than let the
        // model speak a zero pulse.
        if heartRateBPM > 0 { out["heart_rate_bpm"] = heartRateBPM }
        return out
    }

    func end() async -> [String: Any] {
        guard let s = session, let b = builder, let startedAt else {
            return ["ok": false, "error": "no workout is running on this watch"]
        }
        let endDate = Date()
        let summary: [String: Any] = [
            "type": typeName,
            "elapsed_sec": Int(endDate.timeIntervalSince(startedAt)),
            "heart_rate_bpm": heartRateBPM,
            "active_kcal": activeKcal,
        ]
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
        // State moves are driven by our own start()/end() calls; nothing to
        // mirror here. The one surprise — the system ending the session
        // (battery, user force-quit) — lands as .ended with no end() of ours,
        // and the next status()/end() then answers "no workout running".
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
        // mostRecentQuantity/sumQuantity are snapshots, safe to take here.
        var hr: Int?
        var kcal: Int?
        if collectedTypes.contains(HKQuantityType(.heartRate)),
           let q = workoutBuilder.statistics(for: HKQuantityType(.heartRate))?.mostRecentQuantity() {
            hr = Int(q.doubleValue(for: HKUnit.count().unitDivided(by: .minute())).rounded())
        }
        if collectedTypes.contains(HKQuantityType(.activeEnergyBurned)),
           let q = workoutBuilder.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity() {
            kcal = Int(q.doubleValue(for: .kilocalorie()).rounded())
        }
        guard hr != nil || kcal != nil else { return }
        Task { @MainActor [weak self] in
            guard let self, self.builder === workoutBuilder else { return }
            if let hr { self.heartRateBPM = hr }
            if let kcal { self.activeKcal = kcal }
        }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {
        // Events (pause/resume/segment) aren't surfaced in v1 — elapsed time
        // is wall-clock from start, which matches the tool contract.
    }
}
