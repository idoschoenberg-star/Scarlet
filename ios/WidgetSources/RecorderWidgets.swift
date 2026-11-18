import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// The phone recorder's two surfaces outside the app (commission 2026-11-07):
/// the Live Activity on the Lock Screen and Dynamic Island (shown on the
/// Watch's Smart Stack too), and a Control for the Lock Screen, Control
/// Center and the Action button.
@main
struct ScarletRecorderWidgets: WidgetBundle {
    var body: some Widget {
        MeetingRecordingLiveActivity()
        RecordMeetingControl()
    }
}

// MARK: Live Activity

struct MeetingRecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MeetingRecordingAttributes.self) { context in
            LockScreenRecordingView(state: context.state)
                .padding(16)
                .activityBackgroundTint(Color.black.opacity(0.85))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label { Text(context.state.recording ? "Recording" : "Uploading") } icon: {
                        Image(systemName: context.state.recording ? "record.circle.fill" : "icloud.and.arrow.up")
                    }
                    .foregroundStyle(context.state.recording ? .red : .white)
                    .font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ElapsedText(state: context.state).font(.headline.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        UploadLine(state: context.state).font(.subheadline)
                        Spacer()
                        if context.state.recording {
                            Button(intent: StopMeetingRecordingIntent()) {
                                Label("Stop", systemImage: "stop.fill")
                            }
                            .tint(.red)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.recording ? "record.circle.fill" : "icloud.and.arrow.up")
                    .foregroundStyle(context.state.recording ? .red : .white)
            } compactTrailing: {
                ElapsedText(state: context.state).font(.caption.monospacedDigit()).frame(maxWidth: 56)
            } minimal: {
                Image(systemName: "record.circle.fill").foregroundStyle(.red)
            }
        }
        .supplementalActivityFamilies([.small])
    }
}

struct LockScreenRecordingView: View {
    let state: MeetingRecordingAttributes.ContentState
    @Environment(\.activityFamily) private var family

    var body: some View {
        if family == .small {
            // The Watch's Smart Stack.
            VStack(alignment: .leading, spacing: 2) {
                Label(state.recording ? "Recording" : "Uploading", systemImage: state.recording ? "record.circle.fill" : "icloud.and.arrow.up")
                    .foregroundStyle(state.recording ? .red : .white)
                ElapsedText(state: state).font(.title3.monospacedDigit())
                UploadLine(state: state).font(.caption2)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(state.recording ? "Recording" : (state.finished ? "Uploaded" : "Uploading"),
                          systemImage: state.recording ? "record.circle.fill" : "icloud.and.arrow.up")
                        .foregroundStyle(state.recording ? .red : .white)
                        .font(.headline)
                    Text("·").foregroundStyle(.secondary)
                    ElapsedText(state: state).font(.headline.monospacedDigit()).foregroundStyle(.white)
                    Spacer()
                    if state.recording {
                        Button(intent: StopMeetingRecordingIntent()) {
                            Label("Stop", systemImage: "stop.fill")
                        }
                        .tint(.red)
                    }
                }
                UploadLine(state: state).font(.subheadline).foregroundStyle(.white.opacity(0.85))
                if state.recording && state.consent == "two-party" {
                    Text("Two-party consent here: tell the room it is being recorded.")
                        .font(.caption).foregroundStyle(.yellow)
                }
            }
        }
    }
}

struct ElapsedText: View {
    let state: MeetingRecordingAttributes.ContentState
    var body: some View {
        if state.recording {
            Text(timerInterval: state.startedAt...Date.distantFuture, countsDown: false)
        } else {
            Text("done")
        }
    }
}

struct UploadLine: View {
    let state: MeetingRecordingAttributes.ContentState
    var body: some View {
        if state.finished {
            Text("Uploaded ✓  Scarlet is filing it")
        } else if state.pendingMinutes == 0 && state.uploadedMinutes > 0 {
            Text("Uploaded ✓  \(state.uploadedMinutes) min")
        } else if state.uploadedMinutes == 0 && state.pendingMinutes == 0 {
            Text("First minute uploads at 1:00")
        } else {
            Text("Uploaded \(state.uploadedMinutes) min · \(state.pendingMinutes) waiting")
        }
    }
}

// MARK: Control (Lock Screen, Control Center, Action button)

struct RecordMeetingControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: RecorderControl.kind, provider: RecordingStateProvider()) { recording in
            // One button whose face says what a tap does: "Record meeting"
            // when idle, a red "Stop recording" while a meeting records.
            ControlWidgetButton(action: ToggleMeetingRecordingIntent()) {
                if recording {
                    Label("Stop recording", systemImage: "stop.circle.fill")
                } else {
                    Label("Record meeting", systemImage: "record.circle")
                }
            }
        }
        .displayName("Record meeting")
        .description("Tap to start recording a meeting for Scarlet; tap again to stop.")
    }
}

/// The control's face follows the recorder's Live Activity, the state both
/// processes can read; the app reloads the control on every start and stop.
struct RecordingStateProvider: ControlValueProvider {
    var previewValue: Bool { false }
    func currentValue() async throws -> Bool { RecorderSignal.activityRecording() }
}
