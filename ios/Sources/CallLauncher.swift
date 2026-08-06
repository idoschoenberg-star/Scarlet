import SwiftUI
import UIKit

/// # CallLauncher — one honest, verified way to place a call from Scarlet
///
/// Ido asked to launch a call straight from a conversation: a phone icon and a
/// video icon in the thread header, plus (via the persona tool the integrator
/// wires separately) "make a phone / WhatsApp / Teams call." This file is the
/// native tap-to-call half: a tiny helper that builds ONLY the deep links we
/// verified work, guards each with `canOpenURL`, and a `CallBar` row that shows
/// only the buttons that make sense for the conversation's channel.
///
/// ## The honest truth about each link (why the labels read the way they do)
/// - **Regular phone call** — `tel:+<E164>` dials the cellular line directly.
///   Absent on Mac Catalyst (no phone), so that button hides itself there.
/// - **Teams** — the official `https://teams.microsoft.com/l/call/0/0?users=…`
///   (`&withVideo=true` for video). Teams shows its own confirm, then calls.
/// - **WhatsApp** — WhatsApp has **no public "start call" URL**. The only
///   reliable path is to OPEN THE CHAT (`whatsapp://send?phone=…`, falling back
///   to `https://wa.me/…`) where WhatsApp's own call buttons are one tap away.
///   So a WhatsApp call button is honestly an *open WhatsApp* button — the UI
///   says so (accessibility label + the icon's WhatsApp green), and it never
///   pretends to auto-dial.
/// - **FaceTime** — `facetime://` (audio+video) / `facetime-audio://` (audio).
///   Also absent on Mac Catalyst → guarded and hidden.
///
/// Every call is a plain `UIApplication.shared.open` — never a sheet — so this
/// adds no presentation and can't collide with the thread's single `.sheet`.
@MainActor
enum CallLauncher {

    // MARK: Placing calls

    /// A regular cellular phone call to `number` (any format; normalized to
    /// E.164 `tel:+digits`). Returns false — and posts a failure toast — when
    /// the number is empty or the device can't dial (e.g. Mac Catalyst).
    @discardableResult
    static func phone(_ number: String) -> Bool {
        let d = digitsOnly(number)
        guard !d.isEmpty, let url = URL(string: "tel:+\(d)") else {
            return failed("Couldn't place the call — no valid number.")
        }
        return openGuarded(url, failure: "This device can't place phone calls.")
    }

    /// Opens the WhatsApp chat with `number` so Ido can tap WhatsApp's own
    /// voice/video call button. Prefers the in-app `whatsapp://` scheme, falls
    /// back to `https://wa.me/…` (which always opens). This does NOT auto-dial —
    /// it hands off to WhatsApp, by design.
    @discardableResult
    static func whatsApp(number: String) -> Bool {
        let d = digitsOnly(number)
        guard !d.isEmpty else {
            return failed("Couldn't open WhatsApp — no valid number.")
        }
        if let app = URL(string: "whatsapp://send?phone=\(d)"),
           UIApplication.shared.canOpenURL(app) {
            UIApplication.shared.open(app, options: [:], completionHandler: nil)
            return true
        }
        // WhatsApp not installed (or scheme unqueryable) — the https deep link
        // opens the chat in WhatsApp or, failing that, its web fallback.
        guard let web = URL(string: "https://wa.me/\(d)") else {
            return failed("Couldn't open WhatsApp for that number.")
        }
        UIApplication.shared.open(web, options: [:], completionHandler: nil)
        return true
    }

    /// A Microsoft Teams audio (or video) call to `user` — a UPN / email
    /// address. Uses the official Teams call deep link; Teams asks to confirm,
    /// then starts the call.
    @discardableResult
    static func teams(user: String, video: Bool) -> Bool {
        let trimmed = user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(
                withAllowedCharacters: .urlQueryAllowed) else {
            return failed("Couldn't start the Teams call — no address for this person.")
        }
        var s = "https://teams.microsoft.com/l/call/0/0?users=\(encoded)"
        if video { s += "&withVideo=true" }
        guard let url = URL(string: s) else {
            return failed("Couldn't build the Teams call link.")
        }
        // https always "opens" (Teams app or browser) — no canOpenURL gate.
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
        return true
    }

    /// A FaceTime call to `id` (a phone number or Apple ID email). `video`
    /// picks `facetime://` (audio+video) vs `facetime-audio://` (audio only).
    /// Guarded — hidden/disabled where FaceTime is unavailable (Mac Catalyst).
    @discardableResult
    static func faceTime(_ id: String, video: Bool) -> Bool {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(
                withAllowedCharacters: .urlHostAllowed) else {
            return failed("Couldn't start FaceTime — no valid contact.")
        }
        let scheme = video ? "facetime" : "facetime-audio"
        guard let url = URL(string: "\(scheme)://\(encoded)") else {
            return failed("Couldn't build the FaceTime link.")
        }
        return openGuarded(url, failure: "FaceTime isn't available on this device.")
    }

    // MARK: Capability probes (drive which buttons a CallBar shows)

    /// Whether this device can place a cellular `tel:` call (false on Mac).
    static var canPlacePhoneCall: Bool {
        guard let url = URL(string: "tel:+10000000000") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    /// Whether FaceTime is available (false on Mac Catalyst).
    static var canFaceTime: Bool {
        guard let url = URL(string: "facetime://0") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    // MARK: Helpers

    /// Keep only 0–9. A WhatsApp jid ("972…@s.whatsapp.net") or an E.164 handle
    /// ("+972…") both reduce to the bare international number this way.
    static func digitsOnly(_ s: String) -> String {
        String(s.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) })
    }

    /// A handle that is an email (Apple ID / SharePoint UPN) rather than a
    /// phone — used to route iMessage/Teams targets. Deliberately excludes
    /// WhatsApp jids and Teams conversation ids (which also contain "@").
    static func looksLikeEmail(_ s: String) -> Bool {
        guard s.contains("@"), s.contains(".") else { return false }
        let lower = s.lowercased()
        if lower.hasSuffix("@s.whatsapp.net") || lower.contains("@g.us") { return false }
        if lower.contains("thread.v2") || lower.contains("gbl.spaces") { return false }
        if lower.hasPrefix("19:") || lower.hasPrefix("48:") { return false }
        return true
    }

    private static func openGuarded(_ url: URL, failure: String) -> Bool {
        guard UIApplication.shared.canOpenURL(url) else { return failed(failure) }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
        return true
    }

    /// Post a failure toast (observed by `.callFailureToast()`) and return false
    /// so a caller can also branch on the result.
    @discardableResult
    private static func failed(_ message: String) -> Bool {
        NotificationCenter.default.post(name: .callLaunchFailed, object: message)
        return false
    }
}

extension Notification.Name {
    /// Posted by `CallLauncher` when a call couldn't be launched. `object` is
    /// the user-facing message string.
    static let callLaunchFailed = Notification.Name("ScarletCallLaunchFailed")
}

// MARK: - CallBar

/// A compact row of circular call buttons for the top-right of a conversation.
/// It shows ONLY the buttons that make sense for the channel and that this
/// device can actually launch:
///
/// - **WhatsApp** (1:1): a phone icon (real cellular call, hidden on Mac) and a
///   WhatsApp-green video icon that OPENS WhatsApp to place the voice/video call.
/// - **iMessage** (1:1): a phone icon (cellular for a number, else FaceTime
///   audio for an Apple-ID email) and a FaceTime video icon.
/// - **Teams** (1:1): Teams audio + Teams video — shown only when a UPN/email
///   for the person is known (see `teamsUser`). A Teams *conversation id* alone
///   is not a call target, so without a UPN no Teams button appears rather than
///   a broken one.
///
/// Group threads have no single callee, so the bar renders nothing for them.
/// Uses no sheets — every button is a direct `UIApplication.open`.
struct CallBar: View {
    let channel: ChatChannel
    /// The conversation's identifier: WhatsApp jid, iMessage handle, or Teams
    /// chat id (as carried by `ChatSummary.id`).
    let counterpartID: String
    let isGroup: Bool
    let tint: Color
    /// A Teams UPN/email for the person, when known. Teams call buttons appear
    /// only if this is non-nil (the client's Teams chat id is not a call target).
    var teamsUser: String? = nil
    /// Accessibility: who is being called.
    var displayName: String = ""

    var body: some View {
        HStack(spacing: 14) {
            ForEach(buttons) { spec in
                Button(action: spec.action) {
                    Image(systemName: spec.icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(spec.color)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(spec.color.opacity(0.16)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(spec.label)
            }
        }
    }

    /// The channel-appropriate, device-available button set.
    private var buttons: [CallButtonSpec] {
        guard !isGroup else { return [] }
        switch channel {
        case .whatsapp:  return whatsAppButtons
        case .imessage:  return iMessageButtons
        case .teams:     return teamsButtons
        }
    }

    // WhatsApp: cellular phone (if the device can dial) + open-WhatsApp video.
    private var whatsAppButtons: [CallButtonSpec] {
        let number = CallLauncher.digitsOnly(counterpartID)
        guard !number.isEmpty else { return [] }
        var out: [CallButtonSpec] = []
        if CallLauncher.canPlacePhoneCall {
            out.append(CallButtonSpec(
                icon: "phone.fill", color: .white,
                label: "Call \(displayName)",
                action: { CallLauncher.phone(number) }))
        }
        out.append(CallButtonSpec(
            icon: "video.fill", color: tint,
            label: "Video call \(displayName) on WhatsApp — opens WhatsApp",
            action: { CallLauncher.whatsApp(number: number) }))
        return out
    }

    // iMessage: a phone/FaceTime-audio button + FaceTime video.
    private var iMessageButtons: [CallButtonSpec] {
        let handle = counterpartID
        guard !handle.isEmpty else { return [] }
        let isEmail = CallLauncher.looksLikeEmail(handle)
        var out: [CallButtonSpec] = []
        if !isEmail, CallLauncher.canPlacePhoneCall {
            out.append(CallButtonSpec(
                icon: "phone.fill", color: .white,
                label: "Call \(displayName)",
                action: { CallLauncher.phone(handle) }))
        } else if CallLauncher.canFaceTime {
            out.append(CallButtonSpec(
                icon: "phone.fill", color: tint,
                label: "FaceTime audio \(displayName)",
                action: { CallLauncher.faceTime(handle, video: false) }))
        }
        if CallLauncher.canFaceTime {
            out.append(CallButtonSpec(
                icon: "video.fill", color: tint,
                label: "FaceTime video \(displayName)",
                action: { CallLauncher.faceTime(handle, video: true) }))
        }
        return out
    }

    // Teams: only when a UPN/email is known — otherwise no call target.
    private var teamsButtons: [CallButtonSpec] {
        let user = (teamsUser?.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? (CallLauncher.looksLikeEmail(counterpartID) ? counterpartID : "")
        guard !user.isEmpty else { return [] }
        return [
            CallButtonSpec(
                icon: "phone.fill", color: tint,
                label: "Teams audio call \(displayName)",
                action: { CallLauncher.teams(user: user, video: false) }),
            CallButtonSpec(
                icon: "video.fill", color: tint,
                label: "Teams video call \(displayName)",
                action: { CallLauncher.teams(user: user, video: true) }),
        ]
    }
}

/// One CallBar button's presentation + action.
private struct CallButtonSpec: Identifiable {
    let id = UUID()
    let icon: String
    let color: Color
    let label: String
    let action: () -> Void
}

// MARK: - Failure toast

/// A brief bottom toast shown when a call couldn't be launched. Attach once to a
/// screen with `.callFailureToast()`; it listens for `.callLaunchFailed`.
private struct CallFailureToast: ViewModifier {
    @State private var message: String?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let message {
                    Text(message)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color.black.opacity(0.82)))
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .callLaunchFailed)) { note in
                let text = (note.object as? String) ?? "Couldn't place the call."
                withAnimation(.snappy) { message = text }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_600_000_000)
                    withAnimation(.snappy) { message = nil }
                }
            }
    }
}

extension View {
    /// Shows a transient toast whenever a `CallLauncher` action fails.
    func callFailureToast() -> some View { modifier(CallFailureToast()) }
}
