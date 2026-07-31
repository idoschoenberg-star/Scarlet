import SwiftUI

@main
struct ScarletTalkApp: App {
    @StateObject private var session = AppSession()

    var body: some Scene {
        WindowGroup {
            ZStack {
                ScarletBackground().ignoresSafeArea()
                if session.unlocked {
                    TalkView().environmentObject(session)
                } else {
                    UnlockView().environmentObject(session)
                }
            }
            .preferredColorScheme(.dark)
        }
    }
}

/// App-wide state: whether we hold a valid device token.
final class AppSession: ObservableObject {
    @Published var unlocked: Bool

    init() { self.unlocked = TokenStore.token != nil }

    func setToken(_ token: String) {
        TokenStore.token = token
        unlocked = true
    }
    func signOut() {
        TokenStore.token = nil
        unlocked = false
    }
}

/// The living scarlet silk background, native gradient version of the web app.
struct ScarletBackground: View {
    var body: some View {
        RadialGradient(
            colors: [Color(red: 0.55, green: 0.07, blue: 0.19),
                     Color(red: 0.043, green: 0.02, blue: 0.027)],
            center: .center, startRadius: 40, endRadius: 620
        )
    }
}
