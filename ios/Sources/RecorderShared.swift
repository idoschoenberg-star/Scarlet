import ActivityKit
import AppIntents
import Foundation
import WidgetKit

// Compiled into BOTH the app and the ScarletRecorderWidgets extension: the
// Live Activity's attributes and the three recorder intents. The extension
// renders the Live Activity and the Control (Lock Screen, Control Center,
// Action button); every intent runs in the APP's process (AudioRecordingIntent
// and LiveActivityIntent are run by the app when the app target contains
// them), where `RecorderBridge` is the real recorder. The extension carries a
// no-op `RecorderBridge` so the shared file compiles there.

/// The lock-screen card: "Recording · 00:14:32 · uploaded ✓".
struct MeetingRecordingAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var startedAt: Date
        var recording: Bool        // false once stopped (the card shows the upload tail)
        var uploadedMinutes: Int
        var pendingMinutes: Int    // written but not yet on the server
        var finished: Bool         // the server has the whole meeting
        var consent: String?       // "two-party" shows a line to tell the room
    }
    var sid: String
}

/// "Start recording" — Siri, Shortcuts, the Action button.
struct StartMeetingRecordingIntent: AudioRecordingIntent, LiveActivityIntent {
    static var title: LocalizedStringResource = "Start recording a meeting"
    static var description = IntentDescription("Scarlet records the meeting with the screen locked and files it when you stop.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "About", description: "What the meeting is, if you want to say it.")
    var about: String?

    init() {}
    init(about: String?) { self.about = about }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let line = try await RecorderBridge.start(about: about)
        return .result(dialog: IntentDialog(stringLiteral: line))
    }
}

/// "Stop recording".
struct StopMeetingRecordingIntent: AudioRecordingIntent, LiveActivityIntent {
    static var title: LocalizedStringResource = "Stop recording the meeting"
    static var description = IntentDescription("Stops the recording; Scarlet uploads the rest and files the meeting.")
    static var openAppWhenRun: Bool = false

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let line = await RecorderBridge.stop()
        return .result(dialog: IntentDialog(stringLiteral: line))
    }
}

/// One button for the Action button and the Control: starts when idle,
/// stops when recording.
struct ToggleMeetingRecordingIntent: AudioRecordingIntent, LiveActivityIntent {
    static var title: LocalizedStringResource = "Record meeting (start or stop)"
    static var description = IntentDescription("Starts recording a meeting, or stops the one that is recording.")
    static var openAppWhenRun: Bool = false

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        if await RecorderBridge.isRecording() {
            return .result(dialog: IntentDialog(stringLiteral: await RecorderBridge.stop()))
        }
        return .result(dialog: IntentDialog(stringLiteral: try await RecorderBridge.start(about: nil)))
    }
}

/// The cross-process stop (2026-11-18: the Live Activity's Stop and the Lock
/// Screen control did nothing). Whichever process iOS runs a recorder intent
/// in, a stop is also posted as a Darwin notification, which the app, the one
/// process that holds the microphone, always hears while it records.
enum RecorderSignal {
    static let stopName = "com.idoschoenberg.scarlettalk.recorder.stop"

    static func postStop() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(stopName as CFString), nil, nil, true)
    }

    /// True when a recorder Live Activity is up and still recording: the
    /// state both processes can read.
    static func activityRecording() -> Bool {
        Activity<MeetingRecordingAttributes>.activities.contains { $0.content.state.recording && $0.activityState == .active }
    }
}

/// The Control Center / Lock Screen control's kind, and its refresh.
enum RecorderControl {
    static let kind = "com.idoschoenberg.scarlettalk.record-meeting"
    static func reload() {
        if #available(iOS 18.0, *) { ControlCenter.shared.reloadControls(ofKind: kind) }
    }
}
