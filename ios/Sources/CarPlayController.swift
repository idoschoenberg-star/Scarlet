import CarPlay
import Combine
import MediaPlayer
import UIKit

/// Drives the CarPlay surface for Scarlet's voice-based conversational category
/// (iOS 26.4). One compliant, distraction-minimal template: a `CPVoiceControl
/// Template` that only shows listening / thinking / speaking state — no text of
/// answers, no lists, no maps. Everything substantive is SPOKEN by the existing
/// voice engine, one item at a time, so the driver's eyes stay on the road.
///
/// It reuses `Conversation.shared`, so connecting to the car continues the same
/// session (and the engine's route-driven driving-mode announcement fires on
/// its own). Category rules honored: voice is primary on launch, ≤ 5 states,
/// depth 1, audio session deactivated on disconnect, manual launch only.
@MainActor
final class CarPlayController {
    private let interfaceController: CPInterfaceController
    private var cancellables = Set<AnyCancellable>()
    private var rootIsVoice = false
    /// True only when CarPlay itself started the shared conversation (it was idle
    /// when we connected). If the phone already had a session going, the car must
    /// NOT end it on disconnect — leaving the car would cut off the phone.
    private var startedSession = false

    // Exactly five voice-control states (Apple caps at 5). Identifiers are
    // stable strings we activate from Conversation.state / micOn.
    fileprivate enum VState: String { case connecting, listening, thinking, speaking, muted }

    /// Debounce for the in-car self-restart (below): one attempt per 5s, so a
    /// hard failure (mic permission revoked) can't spin a start loop.
    private var lastAutoStart = Date.distantPast

    private lazy var voiceTemplate: CPVoiceControlTemplate = {
        let states: [CPVoiceControlState] = [
            state(.connecting, "Connecting…"),
            state(.listening,  "Listening…"),
            state(.thinking,   "Thinking…"),
            state(.speaking,   "Scarlet"),
            // A muted mic cannot HEAR "unmute" — never instruct the driver to
            // speak to a deaf session; the phone's Mic button is the way back.
            state(.muted,      "Mic off — tap Mic on your phone"),
        ]
        return CPVoiceControlTemplate(voiceControlStates: states)
    }()

    init(interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
    }

    // MARK: lifecycle

    func start() {
        guard TokenStore.token != nil else {
            showSignInNotice()
            return
        }
        interfaceController.setRootTemplate(voiceTemplate, animated: false) { [weak self] _, _ in
            guard let self else { return }
            self.rootIsVoice = true
            let convo = Conversation.shared
            if convo.state == .idle {
                convo.start(token: TokenStore.token ?? "")
                self.startedSession = true   // the car owns this session
            }
            convo.carPlayDidConnect()
            self.applyState()
        }
        observe()
    }

    func stop() {
        cancellables.removeAll()
        clearNowPlaying()
        // Only end the shared conversation if the car started it AND the phone
        // UI isn't in the foreground continuing it. Otherwise just relinquish the
        // CarPlay surface and leave the conversation running on the phone.
        let phoneActive = UIApplication.shared.applicationState == .active
        if startedSession && !phoneActive {
            Conversation.shared.end()   // end() stops audio + setActive(false, notifyOthers)
        }
        startedSession = false
    }

    // MARK: state bridge

    private func observe() {
        let convo = Conversation.shared
        convo.$state.sink { [weak self] _ in self?.applyState() }.store(in: &cancellables)
        convo.$micOn.sink { [weak self] _ in self?.applyState() }.store(in: &cancellables)
        // Status drives the listening↔thinking distinction on the car screen.
        convo.$status.sink { [weak self] _ in self?.applyState() }.store(in: &cancellables)
    }

    /// Map the engine state to a voice-control state + the head unit's now-playing.
    private func applyState() {
        guard rootIsVoice else { return }
        let convo = Conversation.shared
        let v: VState
        switch convo.state {
        case .idle:
            // The car has no Start button — eyes-free means a session that
            // gave up (dead cell spot, reconnects exhausted) must come back BY
            // ITSELF while the car surface is up. Debounced; start() is a
            // no-op unless truly idle. But an End IDO PRESSED is sacred — the
            // car never resurrects a session he explicitly hung up on.
            if !convo.endedByUser, Date().timeIntervalSince(lastAutoStart) > 5,
               let t = TokenStore.token {
                lastAutoStart = Date()
                convo.hasAutoStarted = true
                startedSession = true   // the car owns this revival — end it on disconnect
                convo.start(token: t)
                v = .connecting
            } else {
                // Truthful idle: ended (or unable to start) is "mic off", not
                // an eternal fake "Connecting…".
                v = .muted
            }
        case .connecting: v = .connecting
        case .listening:
            // "Thinking" between his speech ending and her reply starting —
            // the status strings are the live turn markers.
            if !convo.micOn { v = .muted }
            else if convo.status == "Thinking…" || convo.status == "Got it — on it…" { v = .thinking }
            else { v = .listening }
        case .speaking:   v = .speaking
        }
        voiceTemplate.activateVoiceControlState(withIdentifier: v.rawValue)
        if convo.state == .speaking { setNowPlaying() } else { clearNowPlaying() }
    }

    // MARK: helpers

    private func state(_ s: VState, _ title: String) -> CPVoiceControlState {
        // The car screen shows the same living orb as the phone — rendered at
        // runtime (no assets), animated per state, static amber when muted.
        CPVoiceControlState(identifier: s.rawValue,
                            titleVariants: [title],
                            image: CarPlayOrbArt.image(for: s),
                            repeats: s != .muted)
    }

    private func showSignInNotice() {
        let item = CPInformationItem(title: "Sign in on your phone",
                                     detail: "Open Scarlet on your iPhone to sign in, then reconnect.")
        let info = CPInformationTemplate(title: "Scarlet",
                                         layout: .leading,
                                         items: [item],
                                         actions: [])
        interfaceController.setRootTemplate(info, animated: false, completion: nil)
    }

    private func setNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: "Scarlet",
            MPMediaItemPropertyArtist: "Speaking",
        ]
    }

    private func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}

// MARK: - Orb art

/// Runtime-rendered CarPlay orb — the same deep wine/scarlet radial orb the
/// phone's TalkView shows (highlight `(1, 0.3, 0.41)` upper-left → deep wine
/// `(0.27, 0.03, 0.10)` → near-black edge), drawn with UIGraphicsImageRenderer
/// so no asset files ship. Animated states are 8–12 frames on a full sine
/// cycle, so the loop is seamless when `CPVoiceControlState` repeats them:
///   connecting — dim, slow pulse;  listening — full brightness, gentle
///   breathing;  thinking — brightness shimmer;  speaking — brighter, wider
///   halo pulse;  muted — amber-tinted single static frame.
fileprivate enum CarPlayOrbArt {

    /// Canvas side in points. The orb disc fills ~68% of it; the rest is halo.
    private static let side: CGFloat = 168

    static func image(for state: CarPlayController.VState) -> UIImage {
        switch state {
        case .connecting:
            // Dim, slow pulse: brightness and halo swell gently together.
            return animated(frames: 10, duration: 3.0) { p in
                frame(brightness: 0.50 + 0.10 * p, scale: 1.0 + 0.02 * p, halo: 0.18 + 0.10 * p)
            }
        case .listening:
            // Full brightness, gentle breathing (scale 1.0 → 1.06).
            return animated(frames: 12, duration: 2.6) { p in
                frame(brightness: 1.0, scale: 1.0 + 0.06 * p, halo: 0.35 + 0.08 * p)
            }
        case .thinking:
            // Brightness shimmer at steady size.
            return animated(frames: 10, duration: 1.4) { p in
                frame(brightness: 0.82 + 0.26 * p, scale: 1.0, halo: 0.30 + 0.06 * p)
            }
        case .speaking:
            // Brighter, with a wider halo pulse.
            return animated(frames: 12, duration: 1.1) { p in
                frame(brightness: 1.0 + 0.12 * p, scale: 1.0 + 0.03 * p,
                      halo: 0.45 + 0.30 * p, haloSpread: 0.12 * p)
            }
        case .muted:
            // Amber-tinted, static — matches the phone's amber "muted" accent.
            return frame(brightness: 0.9, scale: 1.0, halo: 0.22, amber: true)
        }
    }

    /// Frames follow sin(2πt) mapped to 0…1, so frame N wraps back to frame 0.
    private static func animated(frames n: Int, duration: TimeInterval,
                                 _ make: (CGFloat) -> UIImage) -> UIImage {
        let imgs = (0..<n).map { i -> UIImage in
            let phase = CGFloat(i) / CGFloat(n) * 2 * .pi
            return make((sin(phase) + 1) / 2)   // 0…1, seamless loop
        }
        return UIImage.animatedImage(with: imgs, duration: duration) ?? imgs[0]
    }

    /// One orb frame: soft outer glow, then the gradient disc. `brightness`
    /// scales the disc colors, `scale` breathes the disc, `halo` is glow
    /// opacity, `haloSpread` widens the glow's reach.
    private static func frame(brightness: CGFloat, scale: CGFloat, halo: CGFloat,
                              haloSpread: CGFloat = 0, amber: Bool = false) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 2
        fmt.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: fmt)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            let center = CGPoint(x: side / 2, y: side / 2)
            let radius = side * 0.34 * scale

            // TalkView's palette (amber variant for muted, like the Mic button).
            let hi:   (CGFloat, CGFloat, CGFloat) = amber ? (0.96, 0.62, 0.22) : (1.00, 0.30, 0.41)
            let mid:  (CGFloat, CGFloat, CGFloat) = amber ? (0.34, 0.19, 0.05) : (0.27, 0.03, 0.10)
            let edge: (CGFloat, CGFloat, CGFloat) = amber ? (0.06, 0.04, 0.01) : (0.05, 0.01, 0.02)
            func c(_ t: (CGFloat, CGFloat, CGFloat), _ b: CGFloat, alpha: CGFloat = 1) -> CGColor {
                UIColor(red: min(1, t.0 * b), green: min(1, t.1 * b), blue: min(1, t.2 * b),
                        alpha: alpha).cgColor
            }
            let space = CGColorSpaceCreateDeviceRGB()

            // Soft outer glow: highlight color fading to clear past the rim.
            if let glow = CGGradient(colorsSpace: space,
                                     colors: [c(hi, brightness, alpha: min(1, halo)),
                                              c(hi, brightness, alpha: 0)] as CFArray,
                                     locations: [0, 1]) {
                cg.drawRadialGradient(glow,
                                      startCenter: center, startRadius: radius * 0.55,
                                      endCenter: center,
                                      endRadius: radius * (1.45 + haloSpread) + side * 0.06,
                                      options: [])
            }

            // The disc: radial gradient with the light hitting upper-left.
            let orbRect = CGRect(x: center.x - radius, y: center.y - radius,
                                 width: radius * 2, height: radius * 2)
            cg.saveGState()
            cg.addEllipse(in: orbRect)
            cg.clip()
            let light = CGPoint(x: orbRect.minX + orbRect.width * 0.35,
                                y: orbRect.minY + orbRect.height * 0.30)
            if let disc = CGGradient(colorsSpace: space,
                                     colors: [c(hi, brightness), c(mid, brightness),
                                              c(edge, 1)] as CFArray,
                                     locations: [0, 0.55, 1]) {
                cg.drawRadialGradient(disc,
                                      startCenter: light, startRadius: radius * 0.05,
                                      endCenter: light, endRadius: radius * 1.35,
                                      options: .drawsAfterEndLocation)
            }
            cg.restoreGState()
        }
    }
}
