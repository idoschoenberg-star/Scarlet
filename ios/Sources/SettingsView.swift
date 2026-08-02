import SwiftUI
import AVFoundation

/// Settings: pick Scarlet's voice (same server voices the web app offers),
/// plus the doorway to the full Scarlet app.
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

    func load() async {
        loading = true
        defer { loading = false }
        do {
            let data = try await call("voices=1", method: "GET")
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            currentId = (obj["current"] as? String) ?? currentId
            var seenV = Set<String>()
            voices = ((obj["voices"] as? [[String: Any]]) ?? []).compactMap { v in
                guard let id = v["id"] as? String else { return nil }
                // A duplicate voice id would collide as a ForEach id in the
                // split-view List — keep the first.
                guard seenV.insert(id).inserted else { return nil }
                return VoiceOption(id: id, name: (v["name"] as? String) ?? id,
                                   desc: v["desc"] as? String, preview: v["preview"] as? String)
            }
            if voices.isEmpty { note = "No voices came back — is the Premium engine set up?" }
        } catch {
            note = "Couldn't load voices. Check your connection and reopen Settings."
        }
    }

    func select(_ v: VoiceOption) {
        let previous = currentId
        currentId = v.id
        note = "Voice set to \(v.name) — she'll use it from the next conversation."
        Task {
            do {
                _ = try await call("setvoice=\(v.id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? v.id)", method: "POST")
            } catch {
                // Don't claim success the server didn't confirm — revert the
                // checkmark and say so, instead of silently snapping back on the
                // next open.
                currentId = previous
                note = "Couldn't set \(v.name) — check your connection and try again."
            }
        }
    }

    func preview(_ v: VoiceOption) {
        guard let p = v.preview, let u = URL(string: p) else { return }
        player = AVPlayer(url: u)
        player?.play()
    }

    private func call(_ q: String, method: String) async throws -> Data {
        var req = URLRequest(url: URL(string: AppConfig.elevenURL.absoluteString + "?v=2&" + q)!)
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
    @StateObject private var m = SettingsModel()
    @Environment(\.dismiss) private var dismiss

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
                    Text("Tap ▶ to hear a sample. Changes apply from your next conversation.")
                }

                // Microphone: live level meter (ground truth), input-device and
                // channel pickers, and input gain — for capturing a close mic on
                // a multichannel interface (e.g. the RME Babyface on the Mac).
                MicrophoneSettingsSection()
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .task { await m.load() }
        }
    }
}
