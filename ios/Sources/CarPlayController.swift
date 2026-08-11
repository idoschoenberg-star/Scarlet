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
    private enum VState: String { case connecting, listening, thinking, speaking, muted }

    /// Debounce for the in-car self-restart (below): one attempt per 5s, so a
    /// hard failure (mic permission revoked) can't spin a start loop.
    private var lastAutoStart = Date.distantPast

    private lazy var voiceTemplate: CPVoiceControlTemplate = {
        let states: [CPVoiceControlState] = [
            state(.connecting, "Connecting…",       "hourglass"),
            state(.listening,  "Listening…",        "waveform"),
            state(.thinking,   "Thinking…",         "ellipsis"),
            state(.speaking,   "Scarlet",           "speaker.wave.2.fill"),
            // A muted mic cannot HEAR "unmute" — never instruct the driver to
            // speak to a deaf session; the phone's Mic button is the way back.
            state(.muted,      "Mic off — tap Mic on your phone", "mic.slash.fill"),
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
    }

    /// Map the engine state to a voice-control state + the head unit's now-playing.
    private func applyState() {
        guard rootIsVoice else { return }
        let convo = Conversation.shared
        let v: VState
        switch convo.state {
        case .idle:
            v = .connecting
            // The car has no Start button — eyes-free means a session that
            // gave up (dead cell spot, reconnects exhausted) must come back BY
            // ITSELF while the car surface is up. Debounced; start() is a
            // no-op unless truly idle.
            if Date().timeIntervalSince(lastAutoStart) > 5, let t = TokenStore.token {
                lastAutoStart = Date()
                convo.hasAutoStarted = true
                convo.start(token: t)
            }
        case .connecting: v = .connecting
        case .listening:  v = convo.micOn ? .listening : .muted
        case .speaking:   v = .speaking
        }
        voiceTemplate.activateVoiceControlState(withIdentifier: v.rawValue)
        if convo.state == .speaking { setNowPlaying() } else { clearNowPlaying() }
    }

    // MARK: helpers

    private func state(_ s: VState, _ title: String, _ symbol: String) -> CPVoiceControlState {
        CPVoiceControlState(identifier: s.rawValue,
                            titleVariants: [title],
                            image: UIImage(systemName: symbol),
                            repeats: true)
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
