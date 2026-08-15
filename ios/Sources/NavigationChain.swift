import Foundation
import CoreLocation
import UIKit
import UserNotifications

/// Route-through-a-point for Apple Maps (Ido 2026-08-15, the Vereina drive:
/// "the ability to change routes and so on").
///
/// Apple Maps' URL scheme cannot carry waypoints and no API can touch an
/// active Maps trip — so a "via" route becomes a LEG CHAIN: the server's
/// navigate_to returns `legs` [stop, destination], leg 1 opens immediately,
/// and this object watches the live location stream (.scarletLocationFix,
/// unthrottled) for arrival at the stop. On arrival, three things happen in
/// order of reliability:
///   1. She SAYS it — a [guidance] cue goes into the live session, so he
///      hears "reached Selfranga — continuing to St. Moritz" in his language.
///   2. The app TRIES to open leg 2 directly (works when foregrounded, and
///      often on CarPlay).
///   3. A local notification with the leg-2 link is posted as the fallback —
///      one tap from the lock screen resumes navigation even if (2) was
///      blocked in the background.
/// The chain survives app restarts within a drive via UserDefaults; it
/// expires after 12h so a stale chain can never fire on next week's drive.
@MainActor
final class NavigationChain: ObservableObject {
    static let shared = NavigationChain()

    struct Leg: Codable {
        let name: String
        let lat: Double
        let lng: Double
        let mapsURL: String
    }

    private struct StoredChain: Codable {
        var legs: [Leg]
        var nextIndex: Int
        var startedAt: Date
    }

    /// Inside this radius of the stop counts as "arrived". Generous on
    /// purpose: a car-train terminal or gas stop is reached on approach
    /// roads, not at the geocoded pin.
    private static let arrivalRadiusM: CLLocationDistance = 600
    private static let storeKey = "scarlet.navChain"
    private static let maxAge: TimeInterval = 12 * 3600

    private var chain: StoredChain?
    private var observer: NSObjectProtocol?

    private init() {
        // Resume a chain that was mid-drive when the app restarted.
        if let data = UserDefaults.standard.data(forKey: Self.storeKey),
           let c = try? JSONDecoder().decode(StoredChain.self, from: data),
           Date().timeIntervalSince(c.startedAt) < Self.maxAge,
           c.nextIndex < c.legs.count {
            chain = c
            startWatching()
        } else {
            UserDefaults.standard.removeObject(forKey: Self.storeKey)
        }
    }

    /// Begin a chained route: opens leg 1 now, arms the arrival watch for
    /// the remaining legs. A single-leg call just navigates and clears any
    /// previous chain (a new direct destination supersedes an old via).
    func begin(legs: [Leg]) {
        guard let first = legs.first else { return }
        openMaps(first)
        if legs.count > 1 {
            chain = StoredChain(legs: legs, nextIndex: 1, startedAt: Date())
            persist()
            startWatching()
            // Provisional = delivered quietly, no permission dialog — the
            // fallback works on first use without interrupting the drive.
            UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .provisional]) { _, _ in }
        } else {
            clear()
        }
    }

    func clear() {
        chain = nil
        UserDefaults.standard.removeObject(forKey: Self.storeKey)
        stopWatching()
    }

    // MARK: arrival watch

    private func startWatching() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .scarletLocationFix, object: nil, queue: .main
        ) { [weak self] note in
            guard let loc = note.userInfo?["location"] as? CLLocation else { return }
            Task { @MainActor in self?.check(at: loc) }
        }
    }

    private func stopWatching() {
        if let o = observer { NotificationCenter.default.removeObserver(o) }
        observer = nil
    }

    private func check(at loc: CLLocation) {
        guard var c = chain, c.nextIndex < c.legs.count else { stopWatching(); return }
        if Date().timeIntervalSince(c.startedAt) > Self.maxAge { clear(); return }
        let target = c.legs[c.nextIndex - 1]   // the stop we're driving to now
        let d = loc.distance(from: CLLocation(latitude: target.lat, longitude: target.lng))
        guard d <= Self.arrivalRadiusM else { return }

        let next = c.legs[c.nextIndex]
        c.nextIndex += 1
        chain = c
        persist()
        if c.nextIndex >= c.legs.count { clear() }

        advance(from: target, to: next)
    }

    private func advance(from stop: Leg, to next: Leg) {
        // 1) She says it — the session cue is the channel he actually hears
        //    (fires only when the session is live; the notification below
        //    covers the silent case).
        Conversation.shared.sendSystemNudge(
            "[guidance] Ido just reached \(stop.name). Navigation to \(next.name) is opening now — " +
            "tell him in ONE short sentence, in HIS language, that you're continuing to \(next.name).")
        // 2) Try to open leg 2 directly.
        openMaps(next)
        // 3) Lock-screen fallback: one tap resumes navigation if (2) was
        //    blocked while backgrounded.
        let content = UNMutableNotificationContent()
        content.title = "Continue to \(next.name)"
        content.body = "Tap to resume navigation in Apple Maps."
        content.sound = .default
        content.userInfo = ["open_url": next.mapsURL]
        let req = UNNotificationRequest(identifier: "nav-chain-\(next.name)",
                                        content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    private func openMaps(_ leg: Leg) {
        guard let url = URL(string: leg.mapsURL),
              url.host?.lowercased() == "maps.apple.com" || url.scheme?.lowercased() == "maps"
        else { return }
        UIApplication.shared.open(url)
    }

    private func persist() {
        guard let c = chain, let data = try? JSONEncoder().encode(c) else { return }
        UserDefaults.standard.set(data, forKey: Self.storeKey)
    }
}
