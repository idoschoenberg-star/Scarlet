import SwiftUI
import WatchKit

@main
struct ScarletWatchApp: App {
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
