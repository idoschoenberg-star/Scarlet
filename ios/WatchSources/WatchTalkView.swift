import SwiftUI

/// The whole watch experience is one screen: the orb. Tap it to talk.
/// Scrolling down reveals the recent transcript; the toolbar carries the
/// mode switch (tap-to-talk vs continuous) and End.
struct WatchTalkView: View {
    @State private var convo = WatchConversation.shared
    /// Auto-start is a LAUNCH behavior only: onAppear also fires on the way
    /// back from Settings, and restarting there would resurrect a session he
    /// explicitly ended.
    @State private var didAutoStart = false

    private var orbColor: Color {
        switch convo.state {
        case .idle: return Color(red: 0.55, green: 0.06, blue: 0.13)
        case .connecting: return .orange
        case .listening: return convo.micArmed ? .green : Color(red: 0.55, green: 0.06, blue: 0.13)
        case .thinking: return .orange
        case .speaking: return Color(red: 0.85, green: 0.15, blue: 0.25)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    Button(action: { convo.orbTapped() }) {
                        ZStack {
                            Circle()
                                .fill(orbColor.gradient)
                                .frame(width: 108, height: 108)
                                .shadow(color: orbColor.opacity(0.6), radius: convo.state == .speaking ? 16 : 6)
                            Image(systemName: iconName)
                                .font(.system(size: 40, weight: .light))
                                .foregroundStyle(.white)
                        }
                    }
                    .buttonStyle(.plain)
                    .animation(.easeInOut(duration: 0.25), value: convo.state)

                    Text(convo.status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    if !convo.transcript.isEmpty {
                        Divider().padding(.vertical, 2)
                        ForEach(convo.transcript.suffix(6)) { line in
                            Text(line.text)
                                .font(.caption2)
                                .foregroundStyle(line.fromHer ? .primary : .secondary)
                                .frame(maxWidth: .infinity, alignment: line.fromHer ? .leading : .trailing)
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
            // ACTION BUTTON = LIVE SCARLET (Ido 2026-08-13, Ultra Action
            // button → Shortcut → Open App): opening the app IS the intent to
            // talk — connect immediately instead of demanding one more tap on
            // a 108pt orb. Continuous mode is listening the moment the session
            // is up; tapToTalk still waits for its arming tap by design.
            // endedByUser inside start() guards nothing here — a fresh open is
            // a fresh intent — and start() no-ops when a session already runs.
            .onAppear {
                guard !didAutoStart else { return }
                didAutoStart = true
                if convo.state == .idle { convo.start() }
            }
            .navigationTitle("Scarlet")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(destination: WatchSettingsView()) {
                        Image(systemName: "gearshape")
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    if convo.state != .idle {
                        Button(role: .destructive, action: { convo.end() }) {
                            Label("End", systemImage: "xmark")
                        }
                    }
                }
            }
        }
    }

    private var iconName: String {
        switch convo.state {
        case .idle: return "waveform"
        case .connecting: return "ellipsis"
        case .listening: return convo.micArmed ? "mic.fill" : "mic.slash"
        case .thinking: return "brain"
        case .speaking: return "speaker.wave.2.fill"
        }
    }
}

struct WatchSettingsView: View {
    @State private var convo = WatchConversation.shared
    @State private var continuous = WatchConversation.shared.mode == .continuous

    var body: some View {
        List {
            Section {
                Toggle("Continuous listening", isOn: $continuous)
                    .onChange(of: continuous) { _, on in
                        convo.mode = on ? .continuous : .tapToTalk
                    }
            } footer: {
                Text(continuous
                     ? "She listens the whole session, like CarPlay. Uses more battery."
                     : "Tap the orb before each thing you say. Kindest to the battery.")
            }
            Section {
                Button("Sign out", role: .destructive) {
                    WatchConversation.shared.end()
                    TokenStore.token = nil
                }
            } footer: {
                Text("Open the Scarlet app on your iPhone nearby to sign in again automatically.")
            }
        }
        .navigationTitle("Settings")
    }
}
