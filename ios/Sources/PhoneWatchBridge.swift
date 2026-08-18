import Foundation
import UIKit
import WatchConnectivity

/// Phone side of watch provisioning — the ZERO-LOCK policy (Ido, 2026-08-17,
/// verbatim: the watch is only active because his unlocked phone unlocked it
/// under corporate policy; that IS the authorization, Scarlet adds no second
/// gate).
///
/// The phone does not hand over its OWN token. It asks the server to mint a
/// FRESH one for the wrist (`op=device_grant`, authenticated with the phone's
/// token) and hands THAT over WatchConnectivity, where the watch files it in
/// its Keychain. Two consequences that matter: revoking the watch never
/// touches the phone, and the phone's token never leaves the phone.
///
/// Fire-and-forget — no watch paired, no harm. The grant rides
/// applicationContext (delivered even when the watch app is closed) and never
/// leaves Apple's encrypted channel.
final class PhoneWatchBridge: NSObject, WCSessionDelegate {
    static let shared = PhoneWatchBridge()

    /// The grant we minted for this watch. Cached so a foreground event costs
    /// nothing — a device token has no expiry, so re-minting on every wake
    /// would just litter the device table.
    private static let grantKey = "scarlet.watchGrantToken"
    /// The phone token the cached grant was minted under. When the phone
    /// re-unlocks with a new token the old grant may have been revoked with
    /// it, so the fingerprint change forces a fresh mint.
    private static let grantForKey = "scarlet.watchGrantMintedFor"

    /// Serializes mint attempts so a burst of activations/foregrounds can't
    /// mint a pile of tokens.
    private var minting = false

    func start() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
        NotificationCenter.default.addObserver(
            self, selector: #selector(pushToken),
            name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    @objc func pushToken() {
        Task { @MainActor in await self.provision(force: false) }
    }

    /// Mint (or reuse) the watch's own token and push it across.
    /// `force` re-mints even when a cached grant exists — used when the watch
    /// says it has nothing, which means the cached grant never landed or was
    /// wiped with the watch app.
    @MainActor
    private func provision(force: Bool) async {
        guard WCSession.isSupported(),
              WCSession.default.activationState == .activated,
              let phoneToken = TokenStore.token, !phoneToken.isEmpty else { return }
        guard !minting else { return }
        minting = true
        defer { minting = false }

        let d = UserDefaults.standard
        let fingerprint = String(phoneToken.suffix(8))
        var grant = d.string(forKey: Self.grantKey)
        if force || grant == nil || d.string(forKey: Self.grantForKey) != fingerprint {
            grant = await Self.mintGrant(phoneToken: phoneToken)
            if let grant {
                d.set(grant, forKey: Self.grantKey)
                d.set(fingerprint, forKey: Self.grantForKey)
            }
        }
        // No grant (offline, server hiccup): send NOTHING. The watch shows its
        // "waiting for your iPhone" screen and asks again — which is honest,
        // and infinitely better than the phone's own token leaking to the
        // wrist as a consolation prize.
        guard let grant, !grant.isEmpty else { return }
        try? WCSession.default.updateApplicationContext(["scarletToken": grant])
        // applicationContext only delivers the LATEST value and is coalesced;
        // a reachable watch also gets an immediate message so a watch sitting
        // on the provisioning screen unblocks the moment the phone opens.
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(["scarletToken": grant], replyHandler: nil, errorHandler: { _ in })
        }
    }

    /// POST app-api?op=device_grant with the phone's token → a fresh device
    /// token for the watch. nil on any failure; the caller retries later.
    private static func mintGrant(phoneToken: String) async -> String? {
        var comps = URLComponents(url: AppConfig.appAPIURL, resolvingAgainstBaseURL: false)
        comps?.queryItems = (comps?.queryItems ?? []) + [URLQueryItem(name: "op", value: "device_grant")]
        guard let url = comps?.url else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(phoneToken, forHTTPHeaderField: "x-scarlet-token")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["label": "apple-watch"])
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = obj["token"] as? String, !token.isEmpty else { return nil }
        return token
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async { self.pushToken() }
    }

    /// The watch asks for provisioning when it has no token of its own (first
    /// run, or after the watch app was reinstalled). Always re-mint for that
    /// ask: a cached grant the watch cannot see is worthless.
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard message["needsToken"] as? Bool == true else { return }
        Task { @MainActor in await self.provision(force: true) }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
}
