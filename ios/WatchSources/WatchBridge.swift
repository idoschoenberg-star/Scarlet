import Combine
import Foundation
import WatchConnectivity

/// Receives the device token from the paired iPhone (one-time, whenever the
/// phone app is open nearby) so Ido never types the unlock code on a watch
/// keyboard. Manual code entry in WatchUnlockView stays as the fallback for
/// a watch set up away from the phone.
final class WatchBridge: NSObject, WCSessionDelegate {
    static let shared = WatchBridge()
    let tokenArrived = PassthroughSubject<Void, Never>()

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    private func absorb(_ context: [String: Any]) {
        guard let token = context["scarletToken"] as? String, !token.isEmpty,
              TokenStore.token != token else { return }
        TokenStore.token = token
        DispatchQueue.main.async { self.tokenArrived.send() }
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        absorb(session.receivedApplicationContext)
    }

    func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        absorb(context)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        absorb(message)
    }
}
