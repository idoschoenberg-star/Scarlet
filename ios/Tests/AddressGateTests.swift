import Foundation

/// Decision-table gate for AddressGate. NOT part of any app target: CI
/// compiles it standalone with ios/Sources/AddressGate.swift
/// (`swiftc -parse-as-library ios/Sources/AddressGate.swift
/// ios/Tests/AddressGateTests.swift`) and runs it BEFORE the ~10-minute
/// cloud build — the only unit-level gate this app has. Any miss exits 1.
/// 13-row contract from the 2026-08-19 CarPlay QA.
@main
struct AddressGateTests {
    static func main() {
        var failures = 0
        func expect(_ name: String, _ verdict: AddressGate.Verdict,
                    isRespond: Bool, reason: String? = nil) {
            let got: Bool
            let gotReason: String
            switch verdict {
            case .respond(let r): got = true;  gotReason = r
            case .ignore(let r):  got = false; gotReason = r
            }
            var ok = got == isRespond
            if let reason, gotReason != reason { ok = false }
            if ok {
                print("ok   \(name)")
            } else {
                failures += 1
                print("FAIL \(name): got \(verdict)")
            }
        }
        func sig(inCar: Bool = true, speaking: Bool = false,
                 engagedSecs: TimeInterval = 9999, media: Bool = false,
                 t: String?) -> AddressGate.Signals {
            .init(inCar: inCar, speakingNow: speaking,
                  secondsSinceEngaged: engagedSecs,
                  otherAudioPlaying: media, transcript: t)
        }
        var cfg = AddressGate.Config()

        // (1) not inCar, cold, no name → respond(gate-off)
        expect("1 not-in-car", AddressGate.decide(sig(inCar: false, t: "מה מזג האוויר מחר"), config: cfg),
               isRespond: true, reason: "gate-off")
        // (2) inCar cold Hebrew no-name (speech to his wife) → ignore
        expect("2 wife", AddressGate.decide(sig(t: "מה מזג האוויר מחר"), config: cfg),
               isRespond: false, reason: "unaddressed")
        // (3) addressed by name, Hebrew → respond
        expect("3 he-name", AddressGate.decide(sig(t: "סקרלט, מה מזג האוויר"), config: cfg),
               isRespond: true, reason: "addressed-by-name")
        // (4) addressed by name, English spelling variant → respond
        expect("4 en-name", AddressGate.decide(sig(t: "Scarlett what's my next meeting"), config: cfg),
               isRespond: true, reason: "addressed-by-name")
        // (5) transcriber variant סקארלט → respond
        expect("5 variant", AddressGate.decide(sig(t: "סקארלט תתקשרי לפיליס"), config: cfg),
               isRespond: true, reason: "addressed-by-name")
        // (6) engaged 10s ago, no name → respond (follow-up window)
        expect("6 engaged-10s", AddressGate.decide(sig(engagedSecs: 10, t: "and what about tomorrow"), config: cfg),
               isRespond: true, reason: "recently-engaged")
        // (7) engaged 40s ago, no name → ignore (window is 30s)
        expect("7 engaged-40s", AddressGate.decide(sig(engagedSecs: 40, t: "and what about tomorrow"), config: cfg),
               isRespond: false, reason: "unaddressed")
        // (8) engaged 20s + media playing (window shrinks to 15s) → ignore
        expect("8 media-20s", AddressGate.decide(sig(engagedSecs: 20, media: true, t: "so then she left Paris"), config: cfg),
               isRespond: false, reason: "unaddressed")
        // (9) engaged 10s + media → respond (still inside the shrunk window)
        expect("9 media-10s", AddressGate.decide(sig(engagedSecs: 10, media: true, t: "wait, say that again"), config: cfg),
               isRespond: true, reason: "recently-engaged")
        // (10) she is speaking NOW, clock cold → respond(mid-exchange)
        expect("10 mid-exchange", AddressGate.decide(sig(speaking: true, t: nil), config: cfg),
               isRespond: true, reason: "mid-exchange")
        // (11) cold turn whose transcript never arrived → ignore(no-transcript)
        expect("11 no-transcript", AddressGate.decide(sig(t: nil), config: cfg),
               isRespond: false, reason: "no-transcript")
        // (12) 60-word documentary narration paragraph → ignore
        let narration = Array(repeating: "the story of Josephine Baker continued through the war years and",
                              count: 6).joined(separator: " ")
        expect("12 narration", AddressGate.decide(sig(media: true, t: narration), config: cfg),
               isRespond: false, reason: "unaddressed")
        // (13) gate disabled → respond(gate-off) — the master switch is honest
        cfg.enabled = false
        expect("13 gate-disabled", AddressGate.decide(sig(t: "anything at all"), config: cfg),
               isRespond: true, reason: "gate-off")

        if failures > 0 {
            print("\(failures) address-gate contract row(s) FAILED")
            exit(1)
        }
        print("address-gate decision table: all 13 rows hold")
    }
}
