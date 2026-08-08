import Foundation
#if canImport(SpotifyiOS) && !targetEnvironment(macCatalyst)
import SpotifyiOS
#endif
#if canImport(UIKit)
import UIKit
#endif

/// "Play on this iPhone" via the official Spotify App Remote SDK.
///
/// The old path opened the Spotify app and left Ido there hoping the server's
/// deviceless retry landed. With the SDK, `authorizeAndPlayURI` bounces to
/// Spotify just long enough to authorize (first time shows one approval
/// sheet), starts the requested track/playlist, and hops straight back to
/// Scarlet — playback simply begins. Requires the dashboard-registered
/// redirect URI `scarlettalk://spotify-login` and the app's bundle id in the
/// Spotify app settings (both configured 2026-08-08).
///
/// The OAuth client id is fetched once from the backend (`op=music_config`)
/// and cached — never hardcoded in this public repo.
@MainActor
final class SpotifyRemote: NSObject {
    static let shared = SpotifyRemote()

    private static let clientIDKey = "spotify.clientID"
    private static let redirect = URL(string: "scarlettalk://spotify-login")!

    #if canImport(SpotifyiOS) && !targetEnvironment(macCatalyst)
    private var appRemote: SPTAppRemote?

    private func remote(clientID: String) -> SPTAppRemote {
        if let r = appRemote { return r }
        let config = SPTConfiguration(clientID: clientID, redirectURL: Self.redirect)
        let r = SPTAppRemote(configuration: config, logLevel: .none)
        appRemote = r
        return r
    }
    #endif

    /// Wake Spotify on THIS device and start `uri` (track/playlist/album URI).
    /// Returns false when the SDK path can't run here (no client id yet, Mac,
    /// Spotify not installed) — caller falls back to the plain app-open path.
    func playHere(uri: String) async -> Bool {
        #if canImport(SpotifyiOS) && !targetEnvironment(macCatalyst)
        guard let clientID = await clientID(), !clientID.isEmpty else { return false }
        let r = remote(clientID: clientID)
        return await withCheckedContinuation { cont in
            r.authorizeAndPlayURI(uri) { success in
                Task { @MainActor in cont.resume(returning: success) }
            }
        }
        #else
        _ = uri
        return false
        #endif
    }

    /// Handle the `scarlettalk://spotify-login` callback: stash the App Remote
    /// access token so later plays can skip the authorize bounce entirely.
    /// Returns true when the URL was ours.
    @discardableResult
    func handleCallback(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "scarlettalk" else { return false }
        #if canImport(SpotifyiOS) && !targetEnvironment(macCatalyst)
        guard let r = appRemote,
              let params = r.authorizationParameters(from: url) else { return true }
        if let token = params[SPTAppRemoteAccessTokenKey] {
            r.connectionParameters.accessToken = token
        }
        #endif
        return true
    }

    /// The Spotify OAuth client id — cached after the first backend fetch.
    private func clientID() async -> String? {
        if let cached = UserDefaults.standard.string(forKey: Self.clientIDKey), !cached.isEmpty {
            return cached
        }
        guard let data = try? await MusicAPI.get("music_config"),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["client_id"] as? String, !id.isEmpty else { return nil }
        UserDefaults.standard.set(id, forKey: Self.clientIDKey)
        return id
    }
}
