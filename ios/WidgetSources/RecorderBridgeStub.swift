import Foundation

/// The extension's stand-in for the app's recorder. The recorder intents run
/// in the APP's process (AudioRecordingIntent / LiveActivityIntent), so these
/// are never called here; they exist so `RecorderShared.swift` compiles in
/// both targets.
enum RecorderBridge {
    static func start(about: String?) async throws -> String { "Open Talk once, then try again." }
    static func stop() async -> String { "Open Talk once, then try again." }
    static func isRecording() async -> Bool { false }
}
