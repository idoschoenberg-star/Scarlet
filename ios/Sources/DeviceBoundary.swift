import SwiftUI
import UIKit

// MARK: - Device Boundary (docs/DEVICE_BOUNDARY.md in base-)
//
// Every device carries a tier — personal | corporate | unknown — and UNKNOWN
// RENDERS AS CORPORATE (fail-closed): misclassifying that way costs one extra
// tap; the other way would put personal categories on an employer-managed
// screen. Apple hides MDM state from apps, so the tier comes from a one-time
// guided question at pairing (`tier_source: user`), stamped server-side via
// `op=device_tier` and read back via `op=device_me`.
//
// This file holds the whole client side of the boundary:
//   • DeviceBoundary — the process-wide observable: effective tier, the
//     one-time-question trigger, and the per-SESSION "show anyway" reveals.
//   • DeviceTierQuestionView — the pairing-time classification card.
//   • PersonalSurface — the gate the shells wrap Journal/Health/Photos in:
//     on a corporate screen the section collapses to a quiet
//     "Personal — tap to show" card; one tap reveals it for this session
//     only (in-memory — nothing about the reveal is persisted).

@MainActor
final class DeviceBoundary: ObservableObject {
    static let shared = DeviceBoundary()

    /// Server-truth tier, seeded from the local cache so a cold launch renders
    /// the SAME boundary as the last one instead of flickering through a
    /// default. "unknown" until the server (or Ido) says otherwise.
    @Published private(set) var tier: String
    /// True when this device still needs its one-time classification — the
    /// shell presents the question card exactly once per launch off this.
    @Published var needsClassification = false
    /// Personal sections Ido tapped open THIS SESSION on a corporate screen.
    /// Deliberately in-memory only: the next launch collapses them again.
    @Published private(set) var revealed: Set<String> = []

    /// The fail-closed contract, spelled out exactly as the server does:
    /// anything that isn't provably personal renders as corporate.
    var effectiveTier: String { tier == "personal" ? "personal" : "corporate" }
    var isCorporate: Bool { effectiveTier == "corporate" }

    /// Whether a personal section should show its collapsed placeholder.
    func isCollapsed(_ section: String) -> Bool {
        isCorporate && !revealed.contains(section)
    }

    /// "Show anyway" — for this session only.
    func reveal(_ section: String) { revealed.insert(section) }

    /// Asked-this-launch latch: dismissing the question without answering
    /// means corporate for this session and a fresh offer NEXT launch — never
    /// a nag loop within one run.
    private var askedThisLaunch = false
    private static let tierCacheKey = "scarlet.deviceTier"

    private init() {
        tier = UserDefaults.standard.string(forKey: Self.tierCacheKey) ?? "unknown"
    }

    // MARK: cache (read from non-main contexts, e.g. HealthSync's cache path)

    /// Last tier the server confirmed, readable off-main (UserDefaults is
    /// thread-safe). "unknown" before the first device_me ever lands.
    nonisolated static var cachedTier: String {
        UserDefaults.standard.string(forKey: tierCacheKey) ?? "unknown"
    }
    /// Fail-closed effective form of `cachedTier`.
    nonisolated static var cachedTierIsCorporateEffective: Bool {
        cachedTier != "personal"
    }

    private func cache(_ t: String) {
        tier = t
        UserDefaults.standard.set(t, forKey: Self.tierCacheKey)
    }

    // MARK: server round-trips

    /// Launch refresh: pull `device_me`, adopt the server's tier, and — for a
    /// device still unclassified — raise the one-time question (once per
    /// launch). Silent on network failure: the cached tier keeps ruling.
    func refresh() async {
        guard TokenStore.token != nil else { return }
        guard let (data, status) = await Self.call("op=device_me", method: "GET"),
              (200...299).contains(status),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        let t = (obj["tier"] as? String) ?? "unknown"
        cache(t)
        if t == "unknown" && !askedThisLaunch {
            askedThisLaunch = true
            needsClassification = true
        }
    }

    /// Stamp the one-time answer on THIS device (`op=device_tier` on self).
    /// Returns false on failure so the question card can say so and stay up.
    func classify(_ answer: String) async -> Bool {
        guard let (data, status) = await Self.call("op=device_tier", method: "POST",
                                                   body: ["tier": answer]),
              (200...299).contains(status),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["ok"] as? Bool) == true
        else { return false }
        cache(answer)
        needsClassification = false
        return true
    }

    /// He closed the question without answering: corporate for this session
    /// (the unknown tier already renders that way), fresh offer next launch.
    func dismissedWithoutAnswer() {
        needsClassification = false
    }

    /// Fresh pairing: the unlock response already carries the tier (usually
    /// "unknown" — the question card follows right after RootView appears).
    func noteUnlockTier(_ t: String?) {
        if let t, ["personal", "corporate", "unknown"].contains(t) { cache(t) }
    }

    // MARK: device identity (sent with unlock so the registry shows real names)

    /// What this surface is, in the server's vocabulary
    /// ("ios" | "ipados" | "mac" — watch/web pair through their own paths).
    static var platformString: String {
        #if targetEnvironment(macCatalyst)
        return "mac"
        #else
        if ProcessInfo.processInfo.isiOSAppOnMac { return "mac" }
        return UIDevice.current.userInterfaceIdiom == .pad ? "ipados" : "ios"
        #endif
    }

    /// The user-facing device name (on Mac Catalyst / iPad-on-Mac this is the
    /// Mac's name). iOS 16+ returns a generic "iPhone" without the entitlement
    /// — still honest, just less specific.
    static var deviceName: String { UIDevice.current.name }

    // MARK: plumbing — same shape as ChatsAPI, but the STATUS comes back too
    // (device_tier answers 409 for an MDM-managed Mac and the UI must say so).

    static func call(_ query: String, method: String,
                     body: [String: Any]? = nil) async -> (Data, Int)? {
        guard let url = URL(string: "\(AppConfig.apiBase)/app-api?v=2&\(query)") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(TokenStore.token ?? "", forHTTPHeaderField: "x-scarlet-token")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return nil }
        return (data, http.statusCode)
    }
}

// MARK: - The one-time classification card

/// Presented (as a full-screen cover — RootView's single sheet slot belongs
/// to the draft window, and one .sheet + one .fullScreenCover on a view is
/// the Catalyst-safe pairing) the first time a device shows up unclassified.
/// It walks Ido through the one place iOS actually shows MDM state, then
/// stamps his answer server-side. "Not now" is honest: unknown already
/// renders as corporate, and the question returns next launch.
struct DeviceTierQuestionView: View {
    @ObservedObject private var boundary = DeviceBoundary.shared
    @State private var busy = false
    @State private var error = ""

    var body: some View {
        ZStack {
            ScarletBackground().ignoresSafeArea()
            ScrollView {
                VStack(spacing: 18) {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(Color(red: 0.98, green: 0.92, blue: 0.92))
                    Text("Is this device managed by your company?")
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("A quick check, once:")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.9))
                        Text("Open Settings → General → VPN & Device Management. If no management profile is listed there, the device is yours.")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.75))
                        Text("On a company-managed device, personal sections (Journal, Health, Photos) stay tucked behind a tap and nothing personal is kept on the device.")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))

                    Button { answer("personal") } label: {
                        Text(busy ? "Saving…" : "Personal — no management profile")
                            .font(.headline).frame(maxWidth: .infinity).padding(15)
                            .background(LinearGradient(colors: [Color(red: 0.85, green: 0.14, blue: 0.27),
                                                                Color(red: 0.55, green: 0.07, blue: 0.19)],
                                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                                        in: RoundedRectangle(cornerRadius: 16))
                            .foregroundStyle(.white)
                    }
                    .disabled(busy)

                    Button { answer("corporate") } label: {
                        Text("Company-managed")
                            .font(.headline).frame(maxWidth: .infinity).padding(15)
                            .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
                            .foregroundStyle(.white)
                    }
                    .disabled(busy)

                    if !error.isEmpty {
                        Text(error).font(.caption)
                            .foregroundStyle(Color(red: 0.91, green: 0.69, blue: 0.31))
                    }

                    Button("Not now") { boundary.dismissedWithoutAnswer() }
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.5))
                        .disabled(busy)
                        .padding(.top, 2)
                }
                .padding(28)
                .frame(maxWidth: 440)
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
            }
        }
        .preferredColorScheme(.dark)
    }

    private func answer(_ tier: String) {
        busy = true; error = ""
        Task { @MainActor in
            defer { busy = false }
            if await boundary.classify(tier) {
                // classify() clears needsClassification; the cover closes itself.
            } else {
                error = "Couldn't save that — check your connection and try again."
            }
        }
    }
}

// MARK: - The corp-view gate

/// Wraps one personal section (Journal / Health / Photos). On a personal
/// device it is invisible — the content renders untouched. On a corporate (or
/// still-unknown) device the section collapses to a quiet card; one tap shows
/// it for this session. The reveal lives only in memory (DeviceBoundary), so
/// every launch starts collapsed again — deliberate, per the boundary charter.
struct PersonalSurface<Content: View>: View {
    @ObservedObject private var boundary = DeviceBoundary.shared
    let section: String
    let title: String
    let icon: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        if boundary.isCollapsed(section) {
            ZStack {
                ScarletBackground().ignoresSafeArea()
                Button { withAnimation(.easeOut(duration: 0.2)) { boundary.reveal(section) } } label: {
                    HStack(spacing: 12) {
                        Image(systemName: icon)
                            .font(.system(size: 17))
                            .foregroundStyle(.white.opacity(0.6))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Personal — tap to show")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                            Text("\(title) stays tucked away on this screen.")
                                .font(.footnote)
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    .padding(16)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16)
                        .stroke(.white.opacity(0.10), lineWidth: 1))
                    .contentShape(RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .frame(maxWidth: 440)
                .padding(.horizontal, 24)
            }
        } else {
            content()
        }
    }
}
