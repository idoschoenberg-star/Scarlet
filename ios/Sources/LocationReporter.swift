import CoreLocation
import Foundation
#if canImport(UIKit)
import UIKit
#endif

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

    // MARK: the trail (the journal's "where" axis)

    /// A SECOND manager, dedicated to significant-change monitoring. It must
    /// be separate from `manager`: one CLLocationManager delivers every fix
    /// through one delegate with no way to tell which service produced it, so
    /// sharing it would make the trail indistinguishable from the live
    /// session stream — and stopping one service would silently reconfigure
    /// the other. Two managers, two delegates, two independent lifetimes.
    private let trailManager = CLLocationManager()
    private lazy var trailDelegate = TrailDelegate(owner: self)
    private var trailRunning = false
    /// The last point handed to op=loc_ping, so a phone that wakes us with a
    /// near-identical fix doesn't spend a request the server would only thin.
    private var lastTrailPoint: CLLocation?
    private var lastTrailAt = Date.distantPast

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        // Significant-change monitoring needs NO background-updates flag and
        // shows no location indicator: iOS relaunches the app to deliver a
        // fix, wakes us for the length of one post, and lets us go again.
        trailManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
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
        if manager.authorizationStatus == .authorizedWhenInUse ||
           manager.authorizationStatus == .authorizedAlways {
            #if os(iOS)
            manager.allowsBackgroundLocationUpdates = true
            // iOS pausing the stream when he goes stationary NEVER
            // auto-resumes — arrive at a hotel, sit ten minutes, and the
            // next "navigate to…" answers from the last mid-drive fix (the
            // 2026-08-15 "she thought I was on Via Bernina" bug). Sessions
            // are bounded, so an unpaused stream costs minutes of GPS, not
            // days.
            manager.pausesLocationUpdatesAutomatically = false
            #endif
            // Runs on the WATCH too — the wrist is the device that's ON him,
            // and the old iOS-only guard left it with throttled one-shots.
            manager.startUpdatingLocation()
            // "Always" lets a session that starts with the phone LOCKED
            // (CarPlay, pocket) still begin the stream — under when-in-use,
            // iOS silently refuses a background start and the whole drive
            // runs on a stale fix. Asking when already granted is a no-op;
            // iOS decides if/when to actually show the upgrade prompt.
            if manager.authorizationStatus == .authorizedWhenInUse {
                manager.requestAlwaysAuthorization()
            }
        }
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
        manager.stopUpdatingLocation()
        #if os(iOS)
        manager.allowsBackgroundLocationUpdates = false
        #endif
    }

    /// The strongest freshness guarantee we can make: called the moment Ido
    /// STARTS SPEAKING in a live session, so by the time any tool reads his
    /// position (seconds later) the fix is turn-fresh — never the drive-in
    /// point from an hour ago. Gated to one shot per 30s; a no-op without
    /// permission.
    func reportNow() {
        guard Date().timeIntervalSince(lastPostAt) > 30 else { return }
        guard manager.authorizationStatus == .authorizedWhenInUse ||
              manager.authorizationStatus == .authorizedAlways else { return }
        manager.requestLocation()
    }

    // MARK: - The trail (task #112 — the journal's "where" axis)

    /// Start (or re-start) significant-change monitoring. This is the trail:
    /// iOS wakes the app — even after termination — whenever Ido has moved
    /// meaningfully (cell/Wi-Fi derived, typically ~500 m, no GPS duty cycle),
    /// and each wake posts one point to `op=loc_ping`. The server thins
    /// anything within ~150 m of the previous point inside 10 minutes, so a
    /// stationary phone costs nothing and a day of movement reconstructs as a
    /// real route.
    ///
    /// Requires ALWAYS authorization — under when-in-use iOS accepts the call
    /// and then delivers nothing once the app leaves the foreground, which is
    /// exactly the silent-failure shape we refuse to ship. When the grant is
    /// only when-in-use we ask for the upgrade and leave the Settings row (the
    /// established one-tap path) as the reliable way in.
    func startTrail() {
        #if os(iOS)
        guard CLLocationManager.significantLocationChangeMonitoringAvailable() else { return }
        switch trailManager.authorizationStatus {
        case .authorizedAlways:
            guard !trailRunning else { return }
            trailRunning = true
            trailManager.delegate = trailDelegate
            trailManager.startMonitoringSignificantLocationChanges()
        case .authorizedWhenInUse:
            // iOS shows the While-Using → Always upgrade prompt on its own
            // schedule (sometimes never); Settings › Location is the sure path
            // and LocationSettingsSection puts it one tap away.
            trailManager.delegate = trailDelegate
            trailManager.requestAlwaysAuthorization()
        case .notDetermined:
            trailManager.delegate = trailDelegate
            trailManager.requestWhenInUseAuthorization()
        default:
            break
        }
        #endif
    }

    /// True when the trail is actually recording — what the Settings row reads.
    var trailActive: Bool { trailRunning }

    /// Post one point to the trail. Called from the significant-change wake and
    /// (already-throttled) from the live-session stream, so a drive or a walk
    /// lands with real resolution instead of two endpoints. Locally gated at
    /// 60 s / 120 m purely to avoid spending a request on something the server
    /// would thin anyway; the server remains the authority on what is stored.
    fileprivate func pingTrail(_ loc: CLLocation) {
        let now = Date()
        if let prev = lastTrailPoint,
           now.timeIntervalSince(lastTrailAt) < 60,
           loc.distance(from: prev) < 120 { return }
        lastTrailPoint = loc
        lastTrailAt = now
        postTrail(loc)
    }

    private func postTrail(_ loc: CLLocation) {
        guard let token = TokenStore.token, !token.isEmpty else { return }
        var comps = URLComponents(url: AppConfig.appAPIURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = (comps.queryItems ?? []) + [URLQueryItem(name: "op", value: "loc_ping")]
        guard let u = comps.url else { return }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(token, forHTTPHeaderField: "x-scarlet-token")
        var body: [String: Any] = [
            "lat": loc.coordinate.latitude,
            "lng": loc.coordinate.longitude,
            "at": Self.iso.string(from: loc.timestamp),
            "source": Self.trailSource,
        ]
        // The wire key the server reads is `accuracy`; `accuracy_m` is sent
        // alongside it because that is the name the spec uses and a future
        // server revision may prefer it. Negative means "no estimate" in
        // CoreLocation — send nothing rather than a lie.
        if loc.horizontalAccuracy >= 0 {
            body["accuracy"] = loc.horizontalAccuracy
            body["accuracy_m"] = loc.horizontalAccuracy
        }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req).resume()
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Which device laid the point down — the correlator distinguishes a
    /// phone left on a desk from the watch that was actually on his wrist.
    private static var trailSource: String {
        #if os(watchOS)
        return "watch"
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
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
            // The same fix also lays a trail point: a live call is when he is
            // usually MOVING, and significant-change wakes alone would render
            // a drive as two dots. Both gates (this one and the server's) keep
            // it honest.
            self.pingTrail(loc)
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

/// Delegate for the significant-change manager only. Kept separate from
/// LocationReporter's own delegate conformance so the two location services
/// (live session stream, trail) can never be confused for one another — the
/// delegate callback carries no indication of which service produced a fix.
private final class TrailDelegate: NSObject, CLLocationManagerDelegate {
    private weak var owner: LocationReporter?

    init(owner: LocationReporter) {
        self.owner = owner
        super.init()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor [weak owner] in owner?.pingTrail(loc) }
    }

    /// The Always grant can land long after the first ask (he may approve it
    /// from Settings days later) — start the trail the moment it does.
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager.authorizationStatus == .authorizedAlways else { return }
        Task { @MainActor [weak owner] in owner?.startTrail() }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // A failed significant-change fix is not actionable — the next wake retries.
    }
}
