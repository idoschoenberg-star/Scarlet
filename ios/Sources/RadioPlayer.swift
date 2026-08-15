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
        // Outside a live Scarlet call the session may be inactive — a plain
        // activate is enough (the call's own config wins when a call is live;
        // radio rides the same session either way).
        try? AVAudioSession.sharedInstance().setActive(true)
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
        try? AVAudioSession.sharedInstance().setActive(true)
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
    func duck(_ on: Bool) {
        guard playing else { return }
        player?.volume = on ? 0.15 : 1.0
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
