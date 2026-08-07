import SwiftUI
import AVFoundation

/// Settings: pick Scarlet's voice, and tune the microphone input.
struct VoiceOption: Identifiable {
    let id: String
    let name: String
    let desc: String?
    let preview: String?
}

/// The OpenAI Realtime voices the backend allowlists (realtime-session).
/// Static on purpose: the active engine's voices are fixed by OpenAI, so no
/// network round-trip is needed to list them.
struct OpenAIVoice: Identifiable {
    let id: String
    let name: String
    let desc: String?
}

let openAIVoices: [OpenAIVoice] = [
    OpenAIVoice(id: "marin",   name: "Marin",   desc: "Default — warm, the ChatGPT-class voice"),
    OpenAIVoice(id: "cedar",   name: "Cedar",   desc: nil),
    OpenAIVoice(id: "alloy",   name: "Alloy",   desc: nil),
    OpenAIVoice(id: "ash",     name: "Ash",     desc: nil),
    OpenAIVoice(id: "ballad",  name: "Ballad",  desc: nil),
    OpenAIVoice(id: "coral",   name: "Coral",   desc: nil),
    OpenAIVoice(id: "echo",    name: "Echo",    desc: nil),
    OpenAIVoice(id: "sage",    name: "Sage",    desc: nil),
    OpenAIVoice(id: "shimmer", name: "Shimmer", desc: nil),
    OpenAIVoice(id: "verse",   name: "Verse",   desc: nil),
]

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
    /// True when presented as a sheet (a Done button dismisses it). False when
    /// rendered as a split-view detail column — there `dismiss()` is a no-op, so
    /// showing "Done" would be a dead control. Default true for sheet call sites.
    var presentedAsSheet: Bool = true

    @StateObject private var m = SettingsModel()
    @Environment(\.dismiss) private var dismiss
    // The voice for the active (OpenAI Realtime) engine. Read by Conversation
    // when minting the next session; "marin" is the server default.
    @AppStorage("openaiVoice") private var openaiVoice: String = "marin"

    var body: some View {
        NavigationStack {
            List {
                // Personalization: the dynamic preferences hub (news, section
                // order, interests — editable by control, text, or voice) and
                // the on-device storage manager. Both are self-contained pages
                // pushed within this stack; neither needs the conversation.
                Section {
                    NavigationLink {
                        PreferencesView(presentedAsSheet: false)
                    } label: {
                        Label("Preferences", systemImage: "slider.horizontal.3")
                            .font(.scarletBody)
                    }
                    NavigationLink {
                        StorageView()
                    } label: {
                        Label("Storage", systemImage: "internaldrive")
                            .font(.scarletBody)
                    }
                } header: {
                    Text("Personalization")
                } footer: {
                    Text("Your priorities and preferences live here — change them by tapping, typing, or just telling Scarlet.")
                }

                // The ACTIVE engine's voices — OpenAI Realtime. Selection is
                // stored locally and sent with the next session mint, matching
                // the same tap-to-check flow as the section below.
                Section {
                    ForEach(openAIVoices) { v in
                        Button { openaiVoice = v.id } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(v.name).fontWeight(.semibold)
                                    Spacer()
                                    if v.id == openaiVoice {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(Color(red: 1, green: 0.35, blue: 0.42))
                                    }
                                }
                                if let d = v.desc, !d.isEmpty {
                                    Text(d).font(.scarletDetail).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("OpenAI voice")
                } footer: {
                    Text("Applies from your next session (tap End, then Start).")
                }

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
                                        Text(d).font(.scarletDetail).foregroundStyle(.secondary)
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
                        Text(m.note).font(.scarletDetail).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("ElevenLabs (fallback engine)")
                } footer: {
                    Text("Used only when the fallback engine is active. Tap play to hear a sample; changes apply from your next conversation.")
                }

                // Microphone: live level meter (ground truth), input-device and
                // channel pickers, and input gain — for capturing a close mic on
                // a multichannel interface (e.g. the RME Babyface on the Mac).
                MicrophoneSettingsSection()
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
