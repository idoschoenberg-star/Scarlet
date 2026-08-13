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
        // Bring the phone-token bridge up first: if the iPhone app is already
        // unlocked, the token lands before Ido ever sees the unlock screen.
        WatchBridge.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if unlocked {
                    WatchTalkView()
                } else {
                    WatchUnlockView(onUnlocked: { unlocked = true })
                }
            }
            .onReceive(WatchBridge.shared.tokenArrived) { _ in
                unlocked = TokenStore.token != nil
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { WatchConversation.shared.appBecameActive() }
            }
        }
    }
}
