import SwiftUI

/// The "Scarlet Presence": a floating capsule shown on every non-Talk tab so
/// her state (idle / waking / listening / speaking / chat mode) and the core
/// controls are always one glance and one tap away. Idle → tap to wake her;
/// live → mic, chat-mode and end controls; chat mode → a reply peek plus a
/// text row, right there over the tab bar.
struct ScarletPresenceView: View {
    @ObservedObject var convo: Conversation
    var goToTalk: () -> Void

    @State private var pulsing = false
    @State private var draft = ""

    private let scarlet = Color(red: 1, green: 0.35, blue: 0.42)

    var body: some View {
        VStack(spacing: 8) {
            if convo.chatMode && convo.state != .idle {
                chatExpansion
            }
            capsuleBar
        }
        .frame(maxWidth: 360)
        .padding(.horizontal, 14)
    }

    // MARK: capsule

    @ViewBuilder
    private var capsuleBar: some View {
        if convo.state == .idle {
            Button {
                convo.hasAutoStarted = true
                convo.start(token: TokenStore.token ?? "")
            } label: {
                barContent
            }
            .buttonStyle(.plain)
        } else {
            barContent
        }
    }

    private var barContent: some View {
        HStack(spacing: 10) {
            orb
            Text(statusText)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if convo.state != .idle {
                controls
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.white.opacity(0.10), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
    }

    // MARK: orb + status

    private var shouldPulse: Bool {
        convo.state == .listening && convo.micOn && !convo.chatMode
    }

    @ViewBuilder
    private var orb: some View {
        switch convo.state {
        case .idle:
            Circle()
                .stroke(scarlet.opacity(0.6), lineWidth: 1.5)
                .frame(width: 26, height: 26)
        case .connecting:
            ProgressView()
                .tint(scarlet)
                .frame(width: 26, height: 26)
        case .listening, .speaking:
            Circle()
                .fill(RadialGradient(colors: [scarlet,
                                              Color(red: 0.27, green: 0.03, blue: 0.10)],
                                     center: .init(x: 0.35, y: 0.3),
                                     startRadius: 2, endRadius: 18))
                .frame(width: 26, height: 26)
                .overlay {
                    if convo.state == .speaking {
                        Image(systemName: "waveform")
                            .font(.system(size: 15))
                            .foregroundStyle(.white)
                    }
                }
                .scaleEffect(pulsing ? 1.12 : 1.0)
                .animation(pulsing ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                                   : .easeInOut(duration: 0.2),
                           value: pulsing)
                .onAppear { pulsing = shouldPulse }
                .onChange(of: shouldPulse) { _, now in pulsing = now }
        }
    }

    private var statusText: String {
        switch convo.state {
        case .idle: return "Tap to talk to Scarlet"
        case .connecting: return "Waking her…"
        case .listening, .speaking:
            if convo.chatMode { return "Chat mode" }
            if !convo.micOn { return "Mic off" }
            return convo.state == .speaking ? "Speaking…" : "Listening…"
        }
    }

    // MARK: controls

    private var controls: some View {
        HStack(spacing: 6) {
            controlButton(icon: convo.micOn ? "mic.fill" : "mic.slash.fill",
                          active: convo.micOn) {
                if convo.chatMode { convo.setChatMode(false) } else { convo.toggleMic() }
            }
            controlButton(icon: "keyboard", active: convo.chatMode) {
                convo.setChatMode(!convo.chatMode)
            }
            controlButton(icon: "xmark", active: false) {
                convo.end()
            }
        }
    }

    private func controlButton(icon: String, active: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(active ? scarlet.opacity(0.35) : .white.opacity(0.08),
                            in: Circle())
                .overlay(Circle().stroke(active ? scarlet.opacity(0.6) : .white.opacity(0.14),
                                         lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: chat-mode expansion

    private var chatExpansion: some View {
        VStack(spacing: 6) {
            if let line = convo.lastHerLine {
                Button(action: goToTalk) {
                    Text(line)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
            inputRow
        }
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var inputRow: some View {
        HStack(spacing: 8) {
            TextField("Message Scarlet…", text: $draft, axis: .vertical)
                .lineLimit(1...3)
                .font(.system(size: 14))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
            Button {
                let t = trimmedDraft
                guard !t.isEmpty else { return }
                convo.sendText(t)
                draft = ""
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(scarlet)
            }
            .disabled(trimmedDraft.isEmpty)
        }
        .padding(8)
        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.15), lineWidth: 1))
    }
}
