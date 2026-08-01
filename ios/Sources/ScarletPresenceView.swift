import SwiftUI

/// Sheet-visibility broadcast: DraftView posts it on appear/disappear so the
/// shell can hide this capsule while a drafting surface is up (one Scarlet
/// entry per screen). Defined here — both DraftView and RootView compile
/// against it module-wide.
extension Notification.Name {
    static let scarletDraftSheetVisible = Notification.Name("scarletDraftSheetVisible")
    /// Bottom-edge ownership: screens whose OWN controls live at the bottom
    /// edge (chat thread compose bar, mail reader action bar, calendar event
    /// detail) post ["owned": true] on appear and false on disappear. RootView
    /// COUNTS owners (not a bool — push/present/dismiss ordering is not LIFO)
    /// and hides the presence capsule while any owner exists, so it can never
    /// sit on top of a screen's own bottom controls.
    static let scarletBottomOwned = Notification.Name("scarletBottomOwned")
}

/// The "Scarlet Presence": a floating capsule shown on every non-Talk tab.
/// Collapsed by default — just the orb and a status line. Idle → tap to wake
/// her; live → tap to expand the mic / chat-mode / end controls (and, in
/// chat mode, a reply peek plus a text row) right there over the tab bar.
struct ScarletPresenceView: View {
    @ObservedObject var convo: Conversation
    var goToTalk: () -> Void

    @State private var pulsing = false
    @State private var draft = ""
    /// Live-state controls are opt-in: a tap on the capsule opens them, the
    /// conversation ending closes them again.
    @State private var expanded = false

    private let scarlet = Color(red: 1, green: 0.35, blue: 0.42)
    /// OPAQUE surface for everything this view draws. Translucent fills over
    /// a scrolling list read as broken overlap — content bleeds through the
    /// input field and buttons — so the capsule and the chat panel both sit
    /// on a solid card.
    private let surface = Color(red: 0.16, green: 0.055, blue: 0.085)

    var body: some View {
        Group {
            if expanded && convo.chatMode && convo.state != .idle {
                // Chat mode is ONE solid panel (header + reply peek + input),
                // never separate stacked pieces floating over the list.
                chatPanel
            } else {
                capsuleBar
            }
        }
        .frame(maxWidth: 360)
        .padding(.horizontal, 14)
        .onChange(of: convo.state) { _, newState in
            if newState == .idle { expanded = false }
        }
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
            // Live: the bar itself toggles the controls; the inner control
            // buttons keep their own taps (child gestures win).
            barContent
                .contentShape(Capsule())
                .onTapGesture { expanded.toggle() }
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
            if expanded && convo.state != .idle {
                controls
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(surface, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 14, y: 5)
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

    // MARK: chat-mode panel (one solid card)

    private var chatPanel: some View {
        VStack(spacing: 10) {
            // Header: orb + label + the same three controls. Tapping the
            // header (not the buttons) collapses back to the capsule.
            HStack(spacing: 10) {
                orb
                Text("Chat with Scarlet")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                controls
            }
            .contentShape(Rectangle())
            .onTapGesture { expanded = false }
            if let line = convo.lastHerLine {
                Button(action: goToTalk) {
                    Text(line)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
            inputRow
        }
        .padding(12)
        .background(surface, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.18), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 14, y: 5)
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
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.14), lineWidth: 1))
            Button {
                let t = trimmedDraft
                guard !t.isEmpty else { return }
                convo.sendText(t)
                draft = ""
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(scarlet)
            }
            .disabled(trimmedDraft.isEmpty)
        }
    }
}
