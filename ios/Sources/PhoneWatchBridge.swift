import Foundation
import UIKit
import WatchConnectivity

/// Phone side of the watch pairing: pushes the device token to the paired
/// Apple Watch so the watch app signs in with zero typing. Fire-and-forget —
/// no watch paired, no harm. Token rides applicationContext (delivered even
/// when the watch app is closed) and never leaves Apple's encrypted channel.
final class PhoneWatchBridge: NSObject, WCSessionDelegate {
    static let shared = PhoneWatchBridge()

    func start() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
        NotificationCenter.default.addObserver(
            self, selector: #selector(pushToken),
            name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    @objc func pushToken() {
        guard WCSession.isSupported(),
              WCSession.default.activationState == .activated,
              let token = TokenStore.token else { return }
        try? WCSession.default.updateApplicationContext(["scarletToken": token])
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async { self.pushToken() }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
}
