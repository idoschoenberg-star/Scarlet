import AVFoundation
import MediaPlayer
import SwiftUI

/// Live FM radio — Scarlet's own stream player. The station registry lives on
/// the server (the fm_radio tool resolves names → stream URLs, so a dead
/// stream is fixed by a redeploy, never an app build); this object just plays.
/// Works in the background (UIBackgroundModes audio), through CarPlay/A2DP,
/// and answers the lock-screen / car play-pause buttons via MPRemoteCommand.
@MainActor
final class RadioPlayer: ObservableObject {
    static let shared = RadioPlayer()

    @Published private(set) var stationName: String = ""
    @Published private(set) var playing = false

    private var player: AVPlayer?
    private var commandsInstalled = false

    private init() {}

    func play(name: String, url: URL) {
        // One player at a time; a new station replaces the old mid-stream.
        player?.pause()
        // Outside a live Scarlet call the radio needs a REAL playback
        // category: on the default .soloAmbient it dies on screen lock
        // despite UIBackgroundModes:[audio] and obeys the silent switch.
        // When a call is live, the call's own .playAndRecord config wins —
        // never clobber it from here.
        let s = AVAudioSession.sharedInstance()
        if Conversation.shared.state == .idle {
            try? s.setCategory(.playback, mode: .default)   // background-capable, silent-switch-immune
        }
        try? s.setActive(true)
        let p = AVPlayer(url: url)
        p.play()
        player = p
        stationName = name
        playing = true
        installRemoteCommands()
        updateNowPlaying()
        // Ground her: she learns the radio state silently, so "what's
        // playing?" and pause/stop requests route correctly (fm_radio, not
        // Spotify) for the rest of the session.
        Conversation.shared.noteAmbient("[SYSTEM] Scarlet's own radio player just STARTED live station: \(name). Pause/stop requests for this go through fm_radio, not Spotify.")
    }

    func pause() {
        player?.pause()
        playing = false
        updateNowPlaying()
        Conversation.shared.noteAmbient("[SYSTEM] The live radio (\(stationName)) is now PAUSED.")
    }

    func resume() {
        guard player != nil else { return }
        // Same category rule as play(): a resume outside a live call must
        // not ride .soloAmbient (dies on lock); a live call's config wins.
        let s = AVAudioSession.sharedInstance()
        if Conversation.shared.state == .idle {
            try? s.setCategory(.playback, mode: .default)
        }
        try? s.setActive(true)
        player?.play()
        playing = true
        updateNowPlaying()
        Conversation.shared.noteAmbient("[SYSTEM] The live radio (\(stationName)) RESUMED playing.")
    }

    func stop() {
        let name = stationName
        player?.pause()
        player = nil
        playing = false
        stationName = ""
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        if !name.isEmpty {
            Conversation.shared.noteAmbient("[SYSTEM] The live radio (\(name)) STOPPED — nothing is playing from Scarlet's radio now.")
        }
    }

    /// Scarlet's voice ducks the radio and the last drained buffer restores
    /// it — the two must never fight at full volume (voice-only audit).
    /// Intermediate tier (2026-08-19 CarPlay): while she LISTENS in the car,
    /// a radio at 1.0 plays straight into the unprocessed cabin mic — a
    /// direct feeder of media-as-user-turns. Hold ~0.5 there. Honest note:
    /// this reduces, not eliminates, media-triggered turns — the full fix is
    /// AEC (vp-io trial) + the address gate.
    func duck(_ on: Bool) {
        guard playing else { return }
        if on { player?.volume = 0.15; return }
        let convo = Conversation.shared
        let inCar = AVAudioSession.sharedInstance().currentRoute.outputs
            .contains { $0.portType == .carAudio }
        player?.volume = (inCar && convo.state == .listening && convo.micOn) ? 0.5 : 1.0
    }

    /// Re-assert the radio's now-playing if a station is loaded (CarPlay's
    /// speaking overlay hands the widget back through this) — the car's
    /// audio screen keeps live radio metadata instead of going blank on
    /// every state flicker.
    func reassertNowPlaying() {
        guard !stationName.isEmpty else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        updateNowPlaying()
    }

    /// Apply an fm_radio tool result (the voice lane) — the server resolved
    /// the station; this side only acts.
    func apply(toolResult: [String: Any]) {
        let action = (toolResult["action"] as? String) ?? ""
        switch action {
        case "play":
            if let st = toolResult["station"] as? [String: Any],
               let urlStr = st["stream_url"] as? String,
               let url = URL(string: urlStr) {
                play(name: (st["name_he"] as? String) ?? (st["name"] as? String) ?? "Radio", url: url)
            }
        case "pause": pause()
        case "resume": resume()
        case "stop": stop()
        default: break
        }
    }

    // Lock screen / CarPlay transport buttons control the radio like any
    // audio app. Installed once, on first play, so Scarlet's voice-call
    // machinery is never affected before radio was ever used.
    private func installRemoteCommands() {
        guard !commandsInstalled else { return }
        commandsInstalled = true
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.playing ? self.pause() : self.resume()
            }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard !stationName.isEmpty else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: stationName,
            MPMediaItemPropertyArtist: "Live radio · Scarlet",
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
        ]
    }
}
