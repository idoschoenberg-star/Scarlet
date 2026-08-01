import SwiftUI

/// The one-pager: breathing orb, live transcript, Mic / Voice, big End button.
struct TalkView: View {
    @EnvironmentObject var session: AppSession
    @StateObject private var convo = Conversation()
    @State private var showSettings = false
    @State private var showType = false
    @State private var typed = ""
    @FocusState private var typeFocused: Bool

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Text("SCARLET").font(.system(size: 22, weight: .thin)).tracking(9)
                    .foregroundStyle(Color(red: 0.98, green: 0.92, blue: 0.92))
                HStack {
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

            Orb(active: convo.state == .speaking).frame(width: 220, height: 220)

            Text(convo.status).font(.callout).foregroundStyle(.secondary)
                .frame(minHeight: 22)

            Transcript(lines: convo.transcript).frame(maxHeight: 260)

            Spacer()

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
                RoundControl(icon: convo.loudspeaker ? "speaker.wave.3.fill" : "ear.fill",
                             label: "Speaker", off: !convo.loudspeaker) { convo.toggleLoudspeaker() }
                RoundControl(icon: "keyboard", label: "Type", off: false) {
                    showType.toggle()
                    typeFocused = showType
                }
            }

            Button(role: .destructive) {
                convo.end()
            } label: {
                Text("End").font(.headline).frame(maxWidth: 340).padding(16)
                    .background(Color(red: 0.75, green: 0.15, blue: 0.23),
                                in: RoundedRectangle(cornerRadius: 30))
                    .foregroundStyle(.white)
            }
            .padding(.bottom, 2)

            Link(destination: AppConfig.fullAppURL) {
                Text("Full Scarlet app ›")
                    .font(.footnote)
                    .foregroundStyle(Color(red: 0.79, green: 0.64, blue: 0.65))
            }
            .padding(.bottom, 6)
        }
        .padding(.horizontal, 24)
        .sheet(isPresented: $showSettings) { SettingsView().preferredColorScheme(.dark) }
        .onAppear { convo.start(token: TokenStore.token ?? "") }   // auto-connect: one press → talking
        .onDisappear { convo.end() }
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
    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 18))
                Text(label).font(.system(size: 9, weight: .semibold)).tracking(0.5)
            }
            .frame(width: 62, height: 62)
            .foregroundStyle(.white)
            .background((off ? Color(red: 1, green: 0.35, blue: 0.42).opacity(0.18)
                             : .white.opacity(0.07)),
                        in: Circle())
            .overlay(Circle().stroke(off ? Color(red: 1, green: 0.35, blue: 0.42).opacity(0.55)
                                         : .white.opacity(0.16), lineWidth: 1))
        }
    }
}
