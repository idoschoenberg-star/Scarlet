import Foundation
import CoreLocation

/// Keeps the backend's `user_location` in sync with the phone's REAL position,
/// so Scarlet's "where am I", weather, directions and nearby answers are about
/// where Ido actually is — not a stale Telegram share from home.
///
/// Before this existed the app declared the location-usage string but never
/// asked for or captured a fix, so `user_location` held his last Telegram share
/// (Kfar Kish) forever — and the voice agent faithfully reported Israel while he
/// was in Thailand. This grabs a one-shot fix on launch / foreground / when a
/// call starts and POSTs it to `app-api?op=location`.
///
/// City-level accuracy is plenty (weather/nearby/timezone), so it uses a coarse
/// accuracy and a single `requestLocation()` per refresh — negligible battery.
@MainActor
final class LocationReporter: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationReporter()

    private let manager = CLLocationManager()
    /// Throttle: at most one network report per ~2 minutes even if refresh() is
    /// called more often (foreground + call-start can both fire close together).
    private var lastReport = Date.distantPast

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    /// Ask permission if needed, then grab a fresh fix. Safe to call often.
    func refresh() {
        switch manager.authorizationStatus {
        case .notDetermined:
            // The grant re-enters via locationManagerDidChangeAuthorization.
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        default:
            break // denied / restricted — nothing to do, stay quiet.
        }
    }

    // Delegate callbacks arrive on the main queue (manager was made on main);
    // marked nonisolated to satisfy the protocol, hopping to the actor to post.
    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        let status = m.authorizationStatus
        Task { @MainActor in
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                m.requestLocation()
            }
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let loc = locs.last else { return }
        let lat = loc.coordinate.latitude, lng = loc.coordinate.longitude
        Task { @MainActor in
            if Date().timeIntervalSince(lastReport) < 120 { return }
            lastReport = Date()
            await Self.post(lat: lat, lng: lng)
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        // Quiet: a failed fix just leaves the last good position in place.
    }

    /// POST the fix to the backend (token-authed, same app-api plumbing as the
    /// rest of the app). Never throws to the caller.
    private static func post(lat: Double, lng: Double) async {
        guard let token = TokenStore.token, !token.isEmpty,
              let url = URL(string: "\(AppConfig.apiBase)/app-api?v=2&op=location") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(token, forHTTPHeaderField: "x-scarlet-token")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["lat": lat, "lng": lng])
        _ = try? await URLSession.shared.data(for: req)
    }
}
