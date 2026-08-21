import SwiftUI
import AVFoundation
import CoreLocation

/// Settings: pick Scarlet's voice, and tune the microphone input.
struct VoiceOption: Identifiable {
    let id: String
    let name: String
    let desc: String?
    let preview: String?
}

@MainActor
final class SettingsModel: ObservableObject {
    @Published var voices: [VoiceOption] = []
    @Published var currentId: String = ""
    @Published var loading = true
    @Published var note = ""
    private var player: AVPlayer?

    /// The chosen OpenAI Realtime voice lives on-device and rides to the
    /// server as ?voice= at every session mint — no server round-trip to set.
    static let voiceKey = "scarlet.openaiVoice"

    func load() async {
        loading = true
        defer { loading = false }
        do {
            let data = try await call("voices=1", method: "GET")
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            currentId = UserDefaults.standard.string(forKey: Self.voiceKey)
                ?? (obj["current"] as? String) ?? currentId
            var seenV = Set<String>()
            voices = ((obj["voices"] as? [[String: Any]]) ?? []).compactMap { v in
                guard let id = v["id"] as? String else { return nil }
                // A duplicate voice id would collide as a ForEach id in the
                // split-view List — keep the first.
                guard seenV.insert(id).inserted else { return nil }
                return VoiceOption(id: id, name: (v["name"] as? String) ?? id,
                                   desc: v["desc"] as? String, preview: v["preview"] as? String)
            }
            if voices.isEmpty { note = "No voices came back — check your connection and reopen Settings." }
        } catch {
            note = "Couldn't load voices. Check your connection and reopen Settings."
        }
    }

    func select(_ v: VoiceOption) {
        // Local truth: the pick is saved on-device and attached to every
        // session mint (?voice=) — nothing to fail server-side.
        currentId = v.id
        UserDefaults.standard.set(v.id, forKey: Self.voiceKey)
        note = "Voice set to \(v.name) — she'll use it from the next conversation."
    }

    func preview(_ v: VoiceOption) {
        guard let p = v.preview, let u = URL(string: p) else { return }
        player = AVPlayer(url: u)
        player?.play()
    }

    private func call(_ q: String, method: String) async throws -> Data {
        var req = URLRequest(url: URL(string: AppConfig.realtimeURL.absoluteString + "?v=2&" + q)!)
        req.httpMethod = method
        req.setValue(TokenStore.token ?? "", forHTTPHeaderField: "x-scarlet-token")
        let (d, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return d
    }
}

struct SettingsView: View {
    /// True when presented as a sheet (a Done button dismisses it). False when
    /// rendered as a split-view detail column — there `dismiss()` is a no-op, so
    /// showing "Done" would be a dead control. Default true for sheet call sites.
    var presentedAsSheet: Bool = true

    @StateObject private var m = SettingsModel()
    @Environment(\.dismiss) private var dismiss
    /// Address gate (car cabins): GateSettings.enabledKey is the single
    /// source of truth; @AppStorage just gives the toggle live UI state.
    @AppStorage(GateSettings.enabledKey) private var addressGateOn = true

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if m.loading {
                        HStack { ProgressView(); Text("Loading voices…").foregroundStyle(.secondary) }
                    }
                    ForEach(m.voices) { v in
                        HStack(spacing: 10) {
                            Button { m.select(v) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(v.name).fontWeight(.semibold)
                                        Spacer()
                                        if v.id == m.currentId {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(Color(red: 1, green: 0.35, blue: 0.42))
                                        }
                                    }
                                    if let d = v.desc, !d.isEmpty {
                                        Text(d).font(.footnote).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            if v.preview != nil {
                                Button { m.preview(v) } label: {
                                    Image(systemName: "play.circle").font(.title3)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                    if !m.note.isEmpty {
                        Text(m.note).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Scarlet's voice")
                } footer: {
                    Text("Tap play to hear a sample. Changes apply from your next conversation.")
                }

                Section {
                    Toggle("In the car: answer only when addressed", isOn: $addressGateOn)
                } footer: {
                    Text("With this on, cabin conversation and media speech she wasn't part of stay unanswered — say “Scarlet” to reach her cold, or just keep talking within half a minute of her last reply.")
                }

                // Microphone: live level meter (ground truth), input-device and
                // channel pickers, and input gain — for capturing a close mic on
                // a multichannel interface (e.g. the RME Babyface on the Mac).
                MicrophoneSettingsSection()

                LocationSettingsSection()
            }
            .navigationTitle("Settings")
            .toolbar {
                if presentedAsSheet {
                    ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
                }
            }
            .task { await m.load() }
        }
    }
}

/// Location access, as a Settings row (Ido 2026-08-15: "I never got to
/// approve always access — screen never appeared. Make it a setting
/// option?"). iOS shows its own While-Using→Always upgrade prompt only when
/// IT decides to, which can be never — so the reliable path is this one-tap
/// jump to the app's page in the Settings app, where the Always switch
/// always exists.
private struct LocationSettingsSection: View {
    @State private var status: CLAuthorizationStatus = CLLocationManager().authorizationStatus
    @State private var trailOn = false

    private var label: String {
        switch status {
        case .authorizedAlways: return "Always ✓"
        case .authorizedWhenInUse: return "While Using — upgrade to Always"
        case .denied, .restricted: return "Off"
        default: return "Not set yet"
        }
    }

    private var good: Bool { status == .authorizedAlways }

    var body: some View {
        Section {
            HStack {
                Text("Access").foregroundStyle(.secondary)
                Spacer()
                Text(label).fontWeight(.semibold)
                    .foregroundStyle(good ? Color.green : Color.orange)
            }
            // The trail is what gives the Journal its "where" axis — a day
            // reconstructs as a real route instead of a list of guesses. It
            // records only on Always, so say plainly whether it is running.
            HStack {
                Text("Journal trail").foregroundStyle(.secondary)
                Spacer()
                Text(trailOn ? "Recording ✓" : "Needs “Always”").fontWeight(.semibold)
                    .foregroundStyle(trailOn ? Color.green : Color.orange)
            }
            if !good {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("Open iOS Settings → Location", systemImage: "location.fill")
                }
            }
        } header: {
            Text("Location")
        } footer: {
            Text("“Always” is what lets navigation and “where am I” answers work while the phone is locked in the car — and what lets the Journal record where your day was spent. On the page that opens, tap Location and choose Always. The trail only wakes on meaningful movement; a phone sitting still costs nothing.")
        }
        // Re-read on return from the Settings app so the row reflects reality.
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didBecomeActiveNotification)) { _ in
            status = CLLocationManager().authorizationStatus
            trailOn = LocationReporter.shared.trailActive
        }
        .onAppear { trailOn = LocationReporter.shared.trailActive }
    }
}
