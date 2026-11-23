import Combine
import Foundation
import WatchConnectivity

extension Notification.Name {
    /// Posted wherever the watch drops its token (explicit sign-out, or two
    /// consecutive server rejections) so the app shell returns to the
    /// provisioning screen immediately instead of at the next launch.
    static let scarletWatchTokenCleared = Notification.Name("scarlet.watchTokenCleared")
}

/// Watch side of ZERO-LOCK provisioning (Ido, 2026-08-17). The wrist never
/// asks for a password: the phone is already unlocked and already authorized,
/// and it silently mints this watch its own device token (`op=device_grant`)
/// and hands it over here. There is no manual code path any more — a watch
/// that is active on his wrist IS the authorization.
///
/// If no token has arrived yet, we ASK: the phone answers a `needsToken`
/// message by minting one on the spot. That turns first run from "type a code
/// on a watch keyboard" into "open Scarlet on your phone once".
final class WatchBridge: NSObject, WCSessionDelegate {
    static let shared = WatchBridge()
    let tokenArrived = PassthroughSubject<Void, Never>()

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    /// Ask the phone to provision this watch. Safe to call repeatedly — the
    /// phone serializes minting and reuses the grant it already made.
    func requestToken() {
        guard WCSession.isSupported(),
              WCSession.default.activationState == .activated,
              WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(["needsToken": true], replyHandler: nil, errorHandler: { _ in })
    }

    private func absorb(_ context: [String: Any]) {
        guard let token = context["scarletToken"] as? String, !token.isEmpty,
              TokenStore.token != token else { return }
        TokenStore.token = token
        DispatchQueue.main.async { self.tokenArrived.send() }
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        absorb(session.receivedApplicationContext)
        // Nothing was waiting for us — ask the phone directly.
        if TokenStore.token == nil { DispatchQueue.main.async { self.requestToken() } }
    }

    func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        absorb(context)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        absorb(message)
    }

    /// The phone came within reach while we were waiting — ask again.
    func sessionReachabilityDidChange(_ session: WCSession) {
        guard session.isReachable, TokenStore.token == nil else { return }
        DispatchQueue.main.async { self.requestToken() }
    }
}
