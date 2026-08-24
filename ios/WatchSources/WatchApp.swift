import HealthKit
import SwiftUI
import WatchKit

/// Receives the workout configuration when the PHONE starts a workout via
/// HKHealthStore.startWatchApp — watchOS launches this app and delivers the
/// configuration here; the session itself always runs wrist-side in
/// WorkoutManager (HKWorkoutSession does not exist on iOS).
final class ScarletWatchAppDelegate: NSObject, WKApplicationDelegate {
    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        Task { @MainActor in
            await WorkoutManager.shared.start(configuration: workoutConfiguration)
        }
    }
}

@main
struct ScarletWatchApp: App {
    @WKApplicationDelegateAdaptor(ScarletWatchAppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var unlocked = TokenStore.token != nil

    init() {
        // Bring the provisioning bridge up first: if the iPhone app is already
        // unlocked, this watch's own minted token lands before Ido ever sees
        // the waiting screen. There is no password path to fall back to — the
        // watch being active on his wrist IS the authorization (zero-lock).
        WatchBridge.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if unlocked {
                    WatchTalkView()
                } else {
                    WatchProvisioningView()
                }
            }
            .onReceive(WatchBridge.shared.tokenArrived) { _ in
                unlocked = TokenStore.token != nil
            }
            // Signing out (or a revoked token) must take effect NOW — the
            // shell used to keep showing Talk until the next launch.
            .onReceive(NotificationCenter.default.publisher(for: .scarletWatchTokenCleared)) { _ in
                unlocked = TokenStore.token != nil
                if !unlocked { WatchBridge.shared.requestToken() }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    WatchConversation.shared.appBecameActive()
                } else {
                    // Leaving the foreground: watchOS may suspend (or kill)
                    // us any moment — push any queued conversation turns to
                    // the server ledger NOW (2026-08-24 invisible-watch
                    // incident: unposted turns died with the app).
                    WatchTurnLogger.shared.flushNow()
                }
            }
        }
    }
}
