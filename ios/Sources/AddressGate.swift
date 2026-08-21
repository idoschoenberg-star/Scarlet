import Foundation

/// ADDRESS GATING (CarPlay 2026-08-19: the cabin mic fed speech Ido directed
/// at his wife AND a documentary's narration into the session as user turns,
/// and she answered them). In a multi-speaker/media environment she decides
/// whether an utterance was addressed to HER before answering. Pure and
/// dependency-free BY DESIGN: CI compiles this file standalone with the
/// scenario table and runs it before every build.
enum AddressGate {
    struct Config {
        /// Master switch — mirrors GateSettings.enabled (the single source
        /// of truth; GateSettings.config populates this).
        var enabled = true
        /// A turn within this window of her last audible reply IS a
        /// follow-up addressed to her — no name needed.
        var engagedWindowSeconds: TimeInterval = 30
        /// Phone-sourced media playing (documentary, podcast) means a cabin
        /// full of third-party speech — the follow-up window shrinks.
        var mediaWindowFactor: Double = 0.5
        /// How she is called, lowercased. Transcript variants included.
        var addressForms = ["scarlet", "scarlett", "סקרלט", "סקארלט"]
        /// Max wait for the async transcript before a cold turn is dropped.
        var verdictTimeoutSeconds: TimeInterval = 3.5
    }
    enum Verdict: Equatable {
        case respond(reason: String)   // answer it; re-warms engagement
        case ignore(reason: String)    // journal, delete server item, silence
    }
    struct Signals {
        var inCar: Bool                    // drivingMode
        var speakingNow: Bool              // responseActive || pendingBuffers > 0
        var secondsSinceEngaged: TimeInterval  // since max(lastEngagedAt, playbackDeadline)
        var otherAudioPlaying: Bool        // AVAudioSession.isOtherAudioPlaying
        var transcript: String?            // nil = transcript never arrived
    }
    static func engaged(_ s: Signals, config: Config) -> Bool {
        if s.speakingNow { return true }
        let window = s.otherAudioPlaying
            ? config.engagedWindowSeconds * config.mediaWindowFactor
            : config.engagedWindowSeconds
        return s.secondsSinceEngaged < window
    }
    static func addressed(_ transcript: String, config: Config) -> Bool {
        let lower = transcript.lowercased()
        return config.addressForms.contains { lower.contains($0) }
    }
    static func decide(_ s: Signals, config: Config = Config()) -> Verdict {
        guard config.enabled, s.inCar else { return .respond(reason: "gate-off") }
        if engaged(s, config: config) {
            return .respond(reason: s.speakingNow ? "mid-exchange" : "recently-engaged")
        }
        guard let t = s.transcript, !t.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .ignore(reason: "no-transcript")
        }
        if addressed(t, config: config) { return .respond(reason: "addressed-by-name") }
        return .ignore(reason: "unaddressed")
    }
}

/// Address-gating knobs (CarPlay multi-speaker cabins). UserDefaults-backed
/// so Settings/QA can tune without a build; unset keys = shipped defaults.
/// THE single source of truth — AddressGate.Config.enabled is populated
/// from here, never set independently.
///
/// Lives HERE and not in AppConfig.swift on purpose: AppConfig.swift is
/// shared into the WATCH target, which does not compile AddressGate.swift —
/// a reference from there would break the watch build. This file stays
/// Foundation-only, so the CI standalone compile still works.
enum GateSettings {
    static let enabledKey = "scarlet.addressGate.enabled"
    static let windowKey  = "scarlet.addressGate.windowSecs"
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }
    static var config: AddressGate.Config {
        var c = AddressGate.Config()
        c.enabled = enabled
        let w = UserDefaults.standard.double(forKey: windowKey)
        if w > 0 { c.engagedWindowSeconds = w }
        return c
    }
}
