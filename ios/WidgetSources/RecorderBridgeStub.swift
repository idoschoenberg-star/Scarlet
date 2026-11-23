import Foundation

/// The extension's side of the recorder intents. iOS is meant to run them in
/// the app, but when it runs one here (as the 2026-11-18 report showed for
/// Stop), the stop still reaches the app through `RecorderSignal`.
enum RecorderBridge {
    static func start(about: String?) async throws -> String { "Open Talk once, then try again." }
    static func stop() async -> String {
        RecorderSignal.postStop()
        return "Stopping the recording."
    }
    static func isRecording() async -> Bool { RecorderSignal.activityRecording() }
}
