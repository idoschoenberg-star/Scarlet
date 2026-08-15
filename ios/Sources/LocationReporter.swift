import CoreLocation
import Foundation

extension Notification.Name {
    /// Raw CLLocation fixes from the live stream (userInfo["location"]).
    static let scarletLocationFix = Notification.Name("scarlet.locationFix")
}

/// Posts Ido's live position to the backend (app-api `op=location`) so every
/// server-side answer about "here" — where-am-I, weather with no place named,
/// distances, directions, nearby places — works from a fix that is minutes
/// old, not a days-old Telegram share. (2026-08-11, Ko Samui: "where am I?"
/// answered from a 2.5-day-old reading because nothing in the app ever
/// reported location; the backend endpoint existed with no caller.)
///
/// One fresh fix per trigger, rate-limited to one post per 5 minutes: enough
/// that a new city is known by the time he asks, without a battery cost or a
/// persistent location indicator. Triggered on app foreground and on every
/// voice-session start — the two moments that precede a "here" question.
@MainActor
final class LocationReporter: NSObject, CLLocationManagerDelegate {
    static let shared = LocationReporter()

    private let manager = CLLocationManager()
    private var lastPostAt = Date.distantPast
    /// The last coordinate actually posted — movement gate for the live stream.
    private var lastPostedPoint: CLLocation?
    /// A report() that arrived before permission was granted — fulfilled from
    /// the authorization callback so the first-ever grant still posts a fix.
    private var wantsFix = false
    private var liveTask: Task<Void, Never>?
    /// The floor report() is currently honoring — live sessions lower it.
    private var minInterval: TimeInterval = 300

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// Ask for one fresh fix and post it. Safe to call often; no-ops within
    /// 5 minutes of the last successful post and when permission is denied
    /// (the server then keeps answering from the last known fix, honestly
    /// disclosing its age).
    func report() {
        guard Date().timeIntervalSince(lastPostAt) > minInterval else { return }
        switch manager.authorizationStatus {
        case .notDetermined:
            wantsFix = true
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        default:
            break
        }
    }

    /// While a voice session is live, follow MOVEMENT with a CONTINUOUS
    /// location stream, not one-shot fixes. Root cause of the CarPlay bug
    /// (Ido 2026-08-15: navigation estimated from a position an hour old):
    /// on CarPlay the phone app is BACKGROUNDED, and a one-shot
    /// requestLocation() under when-in-use permission silently delivers
    /// nothing in background — so no fresh fix ever posted while driving.
    /// startUpdatingLocation + allowsBackgroundLocationUpdates (the target
    /// has the `location` background mode) keeps real fixes flowing for the
    /// whole session; the delegate throttles posts. The loop stops itself the
    /// moment `isLive` goes false, so every teardown path is covered.
    func startLiveUpdates(while isLive: @escaping @MainActor () -> Bool) {
        liveTask?.cancel()
        minInterval = 110
        report()
        #if os(iOS)
        if manager.authorizationStatus == .authorizedWhenInUse ||
           manager.authorizationStatus == .authorizedAlways {
            manager.allowsBackgroundLocationUpdates = true
            manager.pausesLocationUpdatesAutomatically = true
            manager.startUpdatingLocation()
        }
        #endif
        liveTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                guard let self, isLive(), !Task.isCancelled else {
                    self?.endLiveStream()
                    return
                }
                self.report()
            }
        }
    }

    func stopLiveUpdates() {
        liveTask?.cancel()
        liveTask = nil
        endLiveStream()
    }

    /// Shared teardown for both stop paths: the continuous stream and the
    /// background entitlement end WITH the session — no lingering blue arrow.
    private func endLiveStream() {
        minInterval = 300
        #if os(iOS)
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        #endif
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            guard self.wantsFix,
                  status == .authorizedWhenInUse || status == .authorizedAlways else { return }
            self.wantsFix = false
            self.manager.requestLocation()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        let lat = loc.coordinate.latitude
        let lng = loc.coordinate.longitude
        // Every fix (unthrottled) also reaches local listeners — the
        // navigation chain needs raw cadence to catch "arrived at the stop"
        // promptly. The server post below stays throttled.
        NotificationCenter.default.post(name: .scarletLocationFix, object: nil,
                                        userInfo: ["location": loc])
        Task { @MainActor in
            // The continuous live stream fires every second on the road —
            // post only when it MEANS something: the interval elapsed, or he
            // moved ≥400m since the last posted point (a highway covers that
            // in ~15s, so navigation math stays honest without spamming).
            let now = Date()
            let movedFar = self.lastPostedPoint.map {
                loc.distance(from: $0) >= 400
            } ?? true
            guard now.timeIntervalSince(self.lastPostAt) > self.minInterval || movedFar else { return }
            self.lastPostAt = now
            self.lastPostedPoint = loc
            self.post(lat: lat, lng: lng)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // A failed fix is not worth surfacing — the next foreground retries.
    }

    private func post(lat: Double, lng: Double) {
        guard let token = TokenStore.token, !token.isEmpty else { return }
        var comps = URLComponents(url: AppConfig.appAPIURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = (comps.queryItems ?? []) + [URLQueryItem(name: "op", value: "location")]
        guard let u = comps.url else { return }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(token, forHTTPHeaderField: "x-scarlet-token")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["lat": lat, "lng": lng])
        URLSession.shared.dataTask(with: req).resume()
    }
}
