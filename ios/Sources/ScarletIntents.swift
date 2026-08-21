import AppIntents
import Foundation

/// Siri / Shortcuts entry point for the car and any hands-free moment:
/// "Hey Siri, Talk to Scarlet" opens the app and starts a live conversation.
///
/// A live session needs the shared `Conversation` + the device token, both of
/// which live in the SwiftUI shell — an App Intent can't reach them directly.
/// So the intent opens the app (`openAppWhenRun`) and hands off through a
/// lightweight launcher: it flags a pending start (drained on first launch,
/// for the COLD case where no observer is listening yet) AND posts
/// `scarletStartFromIntent` (for the WARM case where the app is already up).
/// RootView owns the token + conversation and does the actual `start(token:)`.

extension Notification.Name {
    /// Posted by `ScarletLauncher.requestStart()` (driven by the App Intent);
    /// ScarletTalkApp's RootView observes it and wakes the live conversation.
    static let scarletStartFromIntent = Notification.Name("scarletStartFromIntent")
}

/// Bridges the App Intent (which runs outside the view hierarchy) to the shell
/// that owns the live `Conversation`. MainActor: it only ever touches UI-side
/// state and posts on the main thread.
@MainActor
final class ScarletLauncher: ObservableObject {
    static let shared = ScarletLauncher()
    private init() {}

    /// Raised by the intent when the app may have been COLD-launched: the
    /// notification could fire before RootView installs its observer, so the
    /// shell also drains this flag on its first appearance.
    private(set) var pendingStart = false

    /// Called from `TalkToScarletIntent.perform()`. Records a pending start and
    /// broadcasts it live for an already-running app.
    func requestStart() {
        pendingStart = true
        NotificationCenter.default.post(name: .scarletStartFromIntent, object: nil)
    }

    /// RootView calls this once on appear; returns true a single time when a
    /// start was requested while the app was launching.
    func consumePendingStart() -> Bool {
        guard pendingStart else { return false }
        pendingStart = false
        return true
    }
}

/// "Talk to Scarlet" — the Siri phrase and Shortcuts action. iOS 16.4+
/// `AudioStartingIntent`, background-capable: `openAppWhenRun = true` made
/// the intent unrunnable from CarPlay/Watch Siri ("continue on your iPhone"
/// — the 2026-08-18 morning failure). App Intents run IN-PROCESS, so the
/// shared Conversation and the Keychain token are reachable directly; the
/// session starts right here, and the launcher handoff stays so the UI
/// catches up whenever the app is (or becomes) visible.
struct TalkToScarletIntent: AudioStartingIntent {
    static var title: LocalizedStringResource = "Talk to Scarlet"
    static var description = IntentDescription(
        "Start a live, hands-free conversation with Scarlet.")

    /// Background-capable — the whole point: from CarPlay/Watch Siri the
    /// audio session starts without bouncing to the phone screen.
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        try await MainActor.run {
            guard let t = TokenStore.token else {
                // Something TRUTHFUL for Siri to say, not a silent shrug.
                throw TalkIntentError.notSignedIn
            }
            if Conversation.shared.state == .idle {
                Conversation.shared.hasAutoStarted = true
                Conversation.shared.start(token: t)
            }
            ScarletLauncher.shared.requestStart()   // UI handoff for when the app IS visible
        }
        return .result()
    }
}

enum TalkIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notSignedIn
    var localizedStringResource: LocalizedStringResource {
        "Open Scarlet on your iPhone and sign in first."
    }
}

/// Makes "Hey Siri, Talk to Scarlet" work with a natural phrase and surfaces
/// the action in Shortcuts / Spotlight with zero user setup.
///
/// NOTE: every phrase MUST contain the `\(.applicationName)` token. The app's
/// display name is currently "Talk", so `\(.applicationName)` resolves to
/// "Talk" (see the report for how to make Siri also recognise the bare word
/// "Scarlet" via alternate app names).
struct ScarletAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TalkToScarletIntent(),
            phrases: [
                "Talk to \(.applicationName)",
                "Start \(.applicationName)",
                "Open \(.applicationName) and talk to Scarlet",
                "Talk to Scarlet with \(.applicationName)",
            ],
            shortTitle: "Talk to Scarlet",
            systemImageName: "waveform"
        )
    }
}
