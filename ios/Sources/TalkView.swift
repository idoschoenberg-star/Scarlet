import SwiftUI

/// The one-pager: breathing orb, live transcript, Mic / Voice, big End button.
struct TalkView: View {
    @EnvironmentObject var session: AppSession
    @ObservedObject var convo: Conversation   // owned by RootView, survives tab switches
    @State private var showSettings = false
    @State private var showDictate = false
    @State private var showType = false
    @State private var typed = ""
    @FocusState private var typeFocused: Bool

    /// The orb yields space to the transcript while he's typing/dictating.
    private var orbSize: CGFloat { typeFocused ? 110 : 200 }
    /// The transcript compresses too, so the control row and End button stay
    /// on screen above the keyboard — the dead-end fix's first belt.
    private var transcriptMin: CGFloat { typeFocused ? 70 : 150 }

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
                    // Dictate mode (Ido 2026-08-28): uninterrupted dictation
                    // with live transcription — the keyboard+Wispr replacement.
                    // Also reachable by long-pressing the orb.
                    Button {
                        if convo.state != .idle { convo.end() }
                        showDictate = true
                    } label: {
                        Image(systemName: "waveform.badge.mic")
                            .font(.system(size: 18))
                            .foregroundStyle(.white.opacity(0.65))
                            .frame(width: 44, height: 44)
                    }
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
            Orb(active: convo.state == .speaking,
                userLevel: convo.micStreaming && convo.state == .listening
                    ? max(0, (convo.inputLevel - 0.14) / 0.86) : 0)
                .frame(width: orbSize, height: orbSize)
                .animation(.easeInOut(duration: 0.25), value: typeFocused)
                // The orb IS the Scarlet button: tapping it while idle wakes
                // her; tapping it while she SPEAKS cuts her off (urgent
                // question beats a long story — Ido 2026-08-11).
                .onTapGesture {
                    if convo.state == .idle {
                        convo.hasAutoStarted = true
                        convo.start(token: TokenStore.token ?? "")
                    } else {
                        convo.stopSpeaking()
                    }
                }
                // Long-press = Dictate mode: she stays silent, he speaks as
                // long as he likes, the words land on screen for editing.
                // Any live conversation ends first (one audio owner at a time
                // — the double-tap crash rule).
                .onLongPressGesture(minimumDuration: 0.5) {
                    if convo.state != .idle { convo.end() }
                    showDictate = true
                }

            // Wispr-Flow-style capture wave (Ido 2026-08-11): a strip of bars
            // dancing with the REAL captured signal — motion is ground truth
            // that his voice is being registered, silence is a FLAT line.
            // Flat amber = mic muted; dimmed = reconnecting (not capturing).
            if convo.state != .idle && !convo.chatMode {
                VoiceWave(level: convo.inputLevel,
                          streaming: convo.micStreaming,
                          muted: !convo.micOn,
                          connecting: convo.state == .connecting)
            }

            Text(convo.status).font(.callout).foregroundStyle(.secondary)
                .frame(minHeight: 22)

            // Her reply lives here — always a real, readable, scrollable area
            // (never squeezed to nothing), and it takes any spare height so a
            // silent answer is easy to read.
            Transcript(lines: convo.transcript)
                .frame(minHeight: transcriptMin, maxHeight: .infinity)
                .layoutPriority(1)
                // Second belt: tapping the transcript always lowers the keyboard.
                .simultaneousGesture(TapGesture().onEnded { typeFocused = false })

            if showType {
                HStack(spacing: 8) {
                    TextField("Type or dictate to Scarlet…", text: $typed, axis: .vertical)
                        .lineLimit(1...4)
                        .padding(10)
                        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
                        .focused($typeFocused)
                        .onSubmit { convo.sendText(typed); typed = "" }
                        // Third belt — the guaranteed exit: a bar riding ON TOP
                        // of the keyboard with Done plus live Mic/Voice toggles,
                        // so muted-mic + muted-voice + open-keyboard can never
                        // trap him again (the delete-and-reinstall dead end).
                        .toolbar {
                            ToolbarItemGroup(placement: .keyboard) {
                                Button {
                                    convo.toggleMic()
                                } label: {
                                    Image(systemName: convo.micOn ? "mic.fill" : "mic.slash.fill")
                                }
                                Button {
                                    convo.toggleSpeaker()
                                } label: {
                                    Image(systemName: convo.speakerOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
                                }
                                Spacer()
                                Button("Done") {
                                    typeFocused = false   // the focus onChange runs endTyping
                                    showType = false
                                }
                                .fontWeight(.semibold)
                            }
                        }
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
                    typeFocused = showType   // the focus onChange drives begin/endTyping
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
        // ONE source of truth for the typing pause: every way the keyboard
        // rises or falls flows through focus — the Type button, Done, tapping
        // the transcript, AND the interactive swipe-dismiss, which used to
        // bypass endTyping entirely and leak a mic pause (ears shut until the
        // 90s watchdog expiry). Same pattern as DeskView/ChatsView.
        .onChange(of: typeFocused) { _, focused in
            if focused { convo.beginTyping() } else { convo.endTyping() }
        }
        .reportsModalPresence(showSettings || showDictate)
        .sheet(isPresented: $showSettings) { SettingsView().preferredColorScheme(.dark) }
        // Dictate rides the ONE allowed .fullScreenCover next to the one
        // .sheet (Mac Catalyst single-sheet rule) — and full screen is right
        // for it anyway: dictation is a mode, not a popover.
        .fullScreenCover(isPresented: $showDictate) { DictateView() }
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
    /// Live mic energy (0…1) while she's listening — the orb visibly reacts
    /// to IDO's voice, not just her own speech: glow and a subtle swell track
    /// what the mic is capturing in real time.
    var userLevel: Float = 0
    @State private var breathe = false
    var body: some View {
        let lift = CGFloat(min(1, max(0, userLevel)))
        Circle()
            .fill(RadialGradient(colors: [Color(red: 1, green: 0.3, blue: 0.41),
                                          Color(red: 0.27, green: 0.03, blue: 0.10)],
                                 center: .init(x: 0.35, y: 0.3), startRadius: 8, endRadius: 160))
            .shadow(color: Color(red: 1, green: 0.3, blue: 0.41)
                        .opacity(active ? 0.6 : 0.3 + 0.4 * lift),
                    radius: (active ? 40 : 22) + lift * 26)
            .scaleEffect((breathe ? 1.05 : 1.0) + lift * 0.06)
            .animation(.easeInOut(duration: active ? 0.6 : 2.2).repeatForever(autoreverses: true),
                       value: breathe)
            .animation(.linear(duration: 0.08), value: lift)
            .onAppear { breathe = true }
    }
}

/// The Wispr-Flow-style live capture wave, v2 (the build-218 version froze:
/// it advanced only when the level VALUE changed, so a dead audio path left
/// bars stuck mid-height, and room noise kept "silence" visibly wavy).
/// Now a 24 fps ticker drives the strip unconditionally:
///  - silence and room hum sit BELOW a display noise floor → truly flat line;
///  - real speech (even soft) rises above it → visible motion, boosted by a
///    perceptual curve so a quiet murmur still swings the bars;
///  - motion renders ONLY while the mic is genuinely streaming to the server
///    (`streaming`), so her own loudspeaker voice or a dead session can never
///    fake "your voice is being captured";
///  - muted = flat amber; reconnecting = dimmed flat.
struct VoiceWave: View {
    var level: Float
    var streaming: Bool
    var muted: Bool
    var connecting: Bool
    static let barCount = 36
    @State private var history: [CGFloat] = Array(repeating: 0, count: VoiceWave.barCount)
    private static let scarlet = Color(red: 1, green: 0.35, blue: 0.42)
    private static let amber = Color(red: 0.96, green: 0.62, blue: 0.22)
    private let ticker = Timer.publish(every: 1.0 / 24.0, on: .main, in: .common).autoconnect()

    @State private var phase: CGFloat = 0

    var body: some View {
        Canvas { ctx, size in
            let n = Self.barCount
            let midY = size.height / 2
            let step = size.width / CGFloat(n - 1)
            let color: Color = muted ? Self.amber : Self.scarlet
            let dotOpacity = muted ? 0.85 : (connecting ? 0.25 : 0.6)
            // Wispr Flow's grammar, mirrored: ONE row of very small dots.
            // Silence = a perfectly flat, thin dotted line. Voice = each dot
            // rides a travelling waveform whose height tracks the captured
            // level sample-by-sample — the line literally moves as he speaks,
            // as much or as little as his voice does.
            // 1-2-1 smoothing keeps the motion organic, never jagged.
            var amp = [CGFloat](repeating: 0, count: n)
            for i in 0..<n {
                let a = history[max(0, i - 1)], b = history[i], c = history[min(n - 1, i + 1)]
                amp[i] = (a + 2 * b + c) / 4 * (midY - 3)
            }
            var points = [CGPoint](repeating: .zero, count: n)
            for i in 0..<n {
                let x = CGFloat(i) * step
                let y = midY - amp[i] * sin(CGFloat(i) * 0.75 + phase)
                points[i] = CGPoint(x: x, y: y)
            }
            // When the voice is strong enough, the dots connect into a live
            // line (Wispr's speaking state); the dots stay on top throughout.
            if (amp.max() ?? 0) > 2.5, !muted, !connecting {
                var line = Path()
                line.move(to: points[0])
                for i in 1..<n {
                    let mid = CGPoint(x: (points[i - 1].x + points[i].x) / 2,
                                      y: (points[i - 1].y + points[i].y) / 2)
                    line.addQuadCurve(to: mid, control: points[i - 1])
                }
                line.addLine(to: points[n - 1])
                ctx.stroke(line, with: .color(color.opacity(0.55)), lineWidth: 1.5)
            }
            let r: CGFloat = 1.3
            for p in points {
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                         with: .color(color.opacity(dotOpacity)))
            }
        }
        .frame(height: 36)
        .onReceive(ticker) { _ in
            phase += 0.35   // the waveform travels, like Wispr's
            var v: CGFloat = 0
            if streaming && !muted {
                // Display noise floor at ~-52 dB: the room's hum stays a flat
                // dotted line, speech — even soft — moves it. pow 0.6 lifts
                // whispers into clearly visible motion.
                let raw = CGFloat(min(1, max(0, level)))
                let gated = raw < 0.14 ? 0 : (raw - 0.14) / 0.86
                v = pow(gated, 0.6)
            }
            var h = history
            h.removeFirst()
            h.append(v)
            history = h
        }
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
            // Dragging the transcript pulls the keyboard down with it —
            // the same escape iMessage teaches every thumb.
            .scrollDismissesKeyboard(.interactively)
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
