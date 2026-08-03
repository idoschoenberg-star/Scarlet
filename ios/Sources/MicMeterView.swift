import SwiftUI
import AVFoundation

/// Broadcast when the user changes a live-tunable mic setting (channel or gain)
/// so the live Conversation can re-read it without an audio restart. Device
/// changes ride the same signal but only take effect on the next start.
extension Notification.Name {
    static let scarletMicChanged = Notification.Name("scarletMicChanged")
}

/// Shared, persisted microphone control state.
///
/// A singleton because the Settings sheet is presented WITHOUT the live
/// `Conversation` instance (TalkView owns it), so the two sides meet here:
/// `Conversation` writes the live `level` and reads the saved device/channel/
/// gain; `SettingsView` reads `level` and writes the choices. Nothing here
/// touches audio directly — `Conversation` applies it.
@MainActor
final class MicSettings: ObservableObject {
    static let shared = MicSettings()

    // MARK: persisted choices

    /// Preferred input, matched by stable UID first, portName as a fallback.
    @Published var preferredInputUID: String? { didSet { persist(); notifyChanged() } }
    @Published var preferredInputName: String? { didSet { persist() } }
    /// Selected 0-based channel on a multichannel input. Clamped at capture.
    @Published var channel: Int { didSet { persist(); notifyChanged() } }
    /// Extra input gain in dB (0…24), applied to captured samples before send.
    @Published var gainDB: Float { didSet { persist(); notifyChanged() } }

    // MARK: live / diagnostic (not persisted)

    /// 0…1 meter of the audio actually captured — mirrored from Conversation.
    @Published var level: Float = 0
    /// Channel count of the currently open input (1 = mono, keeps old path).
    @Published var channelCount: Int = 1
    /// What the audio session actually resolved the input to.
    @Published var activeInputName: String?
    /// Inputs the picker offers, refreshed from the audio session.
    @Published var availableInputs: [AVAudioSessionPortDescription] = []

    private let d = UserDefaults.standard
    private enum K {
        static let uid = "scarlet.mic.inputUID"
        static let name = "scarlet.mic.inputName"
        static let channel = "scarlet.mic.channel"
        static let gain = "scarlet.mic.gainDB"
    }

    private init() {
        // Property observers do not fire for these initial assignments.
        preferredInputUID = d.string(forKey: K.uid)
        preferredInputName = d.string(forKey: K.name)
        channel = d.integer(forKey: K.channel)   // absent → 0
        gainDB = d.float(forKey: K.gain)          // absent → 0
    }

    private func persist() {
        if let uid = preferredInputUID { d.set(uid, forKey: K.uid) } else { d.removeObject(forKey: K.uid) }
        if let name = preferredInputName { d.set(name, forKey: K.name) } else { d.removeObject(forKey: K.name) }
        d.set(channel, forKey: K.channel)
        d.set(gainDB, forKey: K.gain)
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: .scarletMicChanged, object: nil)
    }

    /// Choose an input (nil = system default). Name is set first so the change
    /// notification fires only once both fields are current.
    func selectInput(_ port: AVAudioSessionPortDescription?) {
        preferredInputName = port?.portName
        preferredInputUID = port?.uid
    }

    /// Populate `availableInputs` for the picker. Setting the record category
    /// is enough for the OS to enumerate inputs; we only touch it when it isn't
    /// already the recording category, so a live call's mode is left alone.
    func refreshInputs() {
        let s = AVAudioSession.sharedInstance()
        if s.category != .playAndRecord {
            try? s.setCategory(.playAndRecord, mode: .voiceChat,
                               options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP])
        }
        availableInputs = s.availableInputs ?? []
        if activeInputName == nil {
            activeInputName = s.currentRoute.inputs.first?.portName
        }
    }
}

/// A compact, ground-truth level meter: a row of bars that light up with the
/// captured signal. Green in the healthy range, warm/scarlet as it approaches
/// clipping. A flat (all-dark) meter means the input is delivering silence.
struct MicLevelMeter: View {
    var level: Float
    var barCount: Int = 16

    private let scarlet = Color(red: 1, green: 0.35, blue: 0.42)

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { i in
                let threshold = Float(i + 1) / Float(barCount)
                let on = level >= threshold - 0.0001
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(on ? color(for: threshold) : Color.white.opacity(0.09))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 16)
        .animation(.linear(duration: 0.06), value: level)
        .accessibilityLabel("Input level")
        .accessibilityValue("\(Int(level * 100)) percent")
    }

    private func color(for t: Float) -> Color {
        if t > 0.85 { return scarlet }
        if t > 0.65 { return Color(red: 1, green: 0.62, blue: 0.38) }
        return Color(red: 0.35, green: 0.82, blue: 0.5)
    }
}

/// The "Microphone" section for the Settings list. Kept here (not inline in
/// SettingsView) so the single new file carries the whole feature; SettingsView
/// just drops `MicrophoneSettingsSection()` into its List. Styling mirrors the
/// existing sections (scarlet checkmarks, footnote footers).
struct MicrophoneSettingsSection: View {
    @ObservedObject private var mic = MicSettings.shared
    private let scarlet = Color(red: 1, green: 0.35, blue: 0.42)

    var body: some View {
        Group {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    MicLevelMeter(level: mic.level)
                    if let name = mic.activeInputName, !name.isEmpty {
                        Text("Capturing from \(name)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Microphone")
            } footer: {
                Text("The bars show the audio Scarlet actually receives, while you're in a live conversation. A flat meter means the app is getting silence from this input — try another input or channel below, or raise the gain.")
            }

            Section {
                Button { mic.selectInput(nil) } label: {
                    inputRow(name: "System default", detail: nil,
                             selected: mic.preferredInputUID == nil)
                }
                .buttonStyle(.plain)
                ForEach(mic.availableInputs, id: \.uid) { port in
                    Button { mic.selectInput(port) } label: {
                        inputRow(name: port.portName, detail: shortType(port.portType),
                                 selected: mic.preferredInputUID == port.uid)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Input device")
            } footer: {
                Text("Pick the microphone Scarlet listens through — e.g. your RME/USB interface. A device change takes effect the next time you start a conversation (End, then Start).")
            }

            if mic.channelCount > 1 {
                Section {
                    Picker("Channel", selection: Binding(
                        get: { min(max(mic.channel, 0), mic.channelCount - 1) },
                        set: { mic.channel = $0 })) {
                        ForEach(Array(0..<mic.channelCount), id: \.self) { i in
                            Text("Channel \(i + 1)").tag(i)
                        }
                    }
                } header: {
                    Text("Input channel")
                } footer: {
                    Text("This input reports \(mic.channelCount) channels. If Scarlet hears silence, your live mic is probably on a different channel — pick the one whose meter above moves when you speak.")
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Gain")
                        Spacer()
                        Text("+\(Int(mic.gainDB.rounded())) dB")
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                    Slider(value: $mic.gainDB, in: 0...24, step: 1).tint(scarlet)
                }
            } header: {
                Text("Input gain")
            } footer: {
                Text("Boosts soft or whispered speech before it's sent to Scarlet. Peaks are hard-limited, so extra gain never clips.")
            }
        }
        .onAppear { mic.refreshInputs() }
    }

    private func inputRow(name: String, detail: String?, selected: Bool) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).fontWeight(.semibold)
                if let detail, !detail.isEmpty {
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if selected {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(scarlet)
            }
        }
    }

    private func shortType(_ t: AVAudioSession.Port) -> String {
        switch t {
        case .builtInMic: return "Built-in microphone"
        case .bluetoothHFP: return "Bluetooth"
        case .headsetMic: return "Wired headset"
        case .usbAudio: return "USB audio"
        case .carAudio: return "Car"
        case .lineIn: return "Line in"
        default: return t.rawValue
        }
    }
}
