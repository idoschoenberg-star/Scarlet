import SwiftUI

/// The one-pager: breathing orb, live transcript, Mic / Voice, big End button.
struct TalkView: View {
    @EnvironmentObject var session: AppSession
    @ObservedObject var convo: Conversation   // owned by RootView, survives tab switches
    @State private var showSettings = false
    @State private var showType = false
    @State private var typed = ""
    @FocusState private var typeFocused: Bool

    /// The orb yields space to the transcript while he's typing/dictating.
    private var orbSize: CGFloat { typeFocused ? 110 : 200 }

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Text("SCARLET").font(.system(size: 22, weight: .thin)).tracking(9)
                    .foregroundStyle(Color(red: 0.98, green: 0.92, blue: 0.92))
                HStack {
                    Image("ScarletMark")
                        .resizable()
                        .scaledToFill()
                        .frame(width: 30, height: 30)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))
                        .frame(width: 44, height: 44)
                    Spacer()
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 18))
                            .foregroundStyle(.white.opacity(0.65))
                            .frame(width: 44, height: 44)
                    }
                }
            }
            .padding(.top, 8)

            // The orb shrinks the moment the keyboard is up, so her written
            // reply always has room — the whole point of "answering silently".
            Orb(active: convo.state == .speaking)
                .frame(width: orbSize, height: orbSize)
                .animation(.easeInOut(duration: 0.25), value: typeFocused)
                // The orb IS the Scarlet button: tapping it while idle wakes her.
                .onTapGesture {
                    if convo.state == .idle {
                        convo.hasAutoStarted = true
                        convo.start(token: TokenStore.token ?? "")
                    }
                }

            Text(convo.status).font(.callout).foregroundStyle(.secondary)
                .frame(minHeight: 22)

            // Her reply lives here — always a real, readable, scrollable area
            // (never squeezed to nothing), and it takes any spare height so a
            // silent answer is easy to read.
            Transcript(lines: convo.transcript)
                .frame(minHeight: 150, maxHeight: .infinity)
                .layoutPriority(1)

            if showType {
                HStack(spacing: 8) {
                    TextField("Type or dictate to Scarlet…", text: $typed, axis: .vertical)
                        .lineLimit(1...4)
                        .padding(10)
                        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
                        .focused($typeFocused)
                        .onSubmit { convo.sendText(typed); typed = "" }
                    Button {
                        convo.sendText(typed); typed = ""
                    } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
                            .foregroundStyle(Color(red: 1, green: 0.35, blue: 0.42))
                    }
                }
            }

            HStack(spacing: 16) {
                RoundControl(icon: convo.micOn ? "mic.fill" : "mic.slash.fill",
                             label: "Mic", off: !convo.micOn) { convo.toggleMic() }
                RoundControl(icon: convo.speakerOn ? "speaker.wave.2.fill" : "speaker.slash.fill",
                             label: "Voice", off: !convo.speakerOn) { convo.toggleSpeaker() }
                // Output ROUTE (earpiece ⇄ loudspeaker) — a different axis from
                // "Voice" (whether she speaks at all); labelled so the two audio
                // buttons don't read as duplicates.
                RoundControl(icon: convo.loudspeaker ? "speaker.wave.3.fill" : "ear.fill",
                             label: "Output", off: !convo.loudspeaker) { convo.toggleLoudspeaker() }
                RoundControl(icon: showType ? "keyboard.chevron.compact.down" : "keyboard",
                             label: "Type", off: showType) {
                    showType.toggle()
                    typeFocused = showType
                    if showType { convo.beginTyping() } else { convo.endTyping() }
                }
                // Hand her a document or a photo — camera, library or Files;
                // she acknowledges and analyzes it (Claude reads behind her).
                AttachToScarletButton(convo: convo)
            }

            // ONE big button, two faces: Start when she's asleep, End when
            // live. Ending never strands him — the same button (or the orb)
            // brings her back. For long half-day sessions the Mic/Voice
            // buttons above mute without ending; the session stays alive.
            if convo.state == .idle {
                Button {
                    convo.hasAutoStarted = true
                    convo.start(token: TokenStore.token ?? "")
                } label: {
                    Text("Start").font(.headline).frame(maxWidth: 340).padding(16)
                        .background(Color(red: 1, green: 0.35, blue: 0.42),
                                    in: RoundedRectangle(cornerRadius: 30))
                        .foregroundStyle(.white)
                }
                .padding(.bottom, 2)
            } else {
                Button(role: .destructive) {
                    convo.end()
                } label: {
                    Text("End").font(.headline).frame(maxWidth: 340).padding(16)
                        .background(Color(red: 0.75, green: 0.15, blue: 0.23),
                                    in: RoundedRectangle(cornerRadius: 30))
                        .foregroundStyle(.white)
                }
                .padding(.bottom, 2)
            }
        }
        .padding(.horizontal, 24)
        .reportsModalPresence(showSettings)
        .sheet(isPresented: $showSettings) { SettingsView().preferredColorScheme(.dark) }
        // Auto-connect ONCE per app session: one press → talking. Coming back
        // from the Inbox tab must not restart (or end) a conversation — the
        // End button is the only way to hang up.
        .onAppear {
            if convo.state == .idle && !convo.hasAutoStarted {
                convo.hasAutoStarted = true
                convo.start(token: TokenStore.token ?? "")
            }
        }
    }
}

// MARK: - Small building blocks

struct Orb: View {
    var active: Bool
    @State private var breathe = false
    var body: some View {
        Circle()
            .fill(RadialGradient(colors: [Color(red: 1, green: 0.3, blue: 0.41),
                                          Color(red: 0.27, green: 0.03, blue: 0.10)],
                                 center: .init(x: 0.35, y: 0.3), startRadius: 8, endRadius: 160))
            .shadow(color: Color(red: 1, green: 0.3, blue: 0.41).opacity(active ? 0.6 : 0.3),
                    radius: active ? 40 : 22)
            .scaleEffect(breathe ? 1.05 : 1.0)
            .animation(.easeInOut(duration: active ? 0.6 : 2.2).repeatForever(autoreverses: true),
                       value: breathe)
            .onAppear { breathe = true }
    }
}

struct Transcript: View {
    var lines: [Conversation.Line]
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(lines) { l in
                        Text(l.text)
                            .font(.callout)
                            .foregroundStyle(l.fromHer ? Color(red: 0.96, green: 0.87, blue: 0.88)
                                                       : Color(red: 0.66, green: 0.56, blue: 0.57))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(l.id)
                    }
                }.padding(14)
            }
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20))
            .onChange(of: lines.count) { _, _ in
                if let last = lines.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }
}

struct RoundControl: View {
    var icon: String, label: String, off: Bool, action: () -> Void
    // A control in its non-default state (mic/voice muted, output on earpiece,
    // keyboard open) is tinted AMBER — a distinct "heads-up / changed" cue that
    // is deliberately NOT the scarlet primary color (which means active/live on
    // the Start button, orb and send arrow), so a muted Mic no longer reads as
    // "live".
    private static let amber = Color(red: 0.96, green: 0.62, blue: 0.22)
    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 18))
                Text(label).font(.system(size: 9, weight: .semibold)).tracking(0.5)
            }
            .frame(width: 62, height: 62)
            .foregroundStyle(off ? Self.amber : .white)
            .background((off ? Self.amber.opacity(0.16) : .white.opacity(0.07)), in: Circle())
            .overlay(Circle().stroke(off ? Self.amber.opacity(0.6) : .white.opacity(0.16), lineWidth: 1))
        }
    }
}
