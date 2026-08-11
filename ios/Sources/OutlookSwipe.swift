import SwiftUI
import UIKit

/// THE app-wide archive swipe (Ido 2026-08-11: "every consistent action looks
/// similar across the Scarlet application" — archive must feel EXACTLY like
/// the Amwell inbox everywhere it exists: Inbox, Signals, Library, any future
/// list). Extracted from InboxView, where it was born as the Outlook-fidelity
/// gesture.
///
/// The system `.swipeActions` renders the action as a floating rounded button
/// that stops at partial reveal — not Outlook's look. Here the row rides the
/// finger over a full-bleed green bar that spans the entire line height and
/// grows with the drag; the archive glyph sits pinned at the trailing edge,
/// pops (with a haptic) at the 45% commit point, and past it the row flies
/// off and the archive fires. Below it, release springs the row back.
/// Leading swipes (flag / read / later) stay on the system implementation and
/// are untouched by this gesture — it claims only leftward, horizontal-
/// dominant drags.
struct OutlookArchiveSwipe<Content: View>: View {
    let baseBackground: Color
    let onArchive: () -> Void
    @ViewBuilder let content: Content

    @State private var offset: CGFloat = 0
    @State private var width: CGFloat = 1
    @State private var pastThreshold = false
    @State private var committed = false

    private var progress: CGFloat { min(1, -offset / max(width, 1)) }

    var body: some View {
        content
            .background(GeometryReader { geo in
                Color.clear
                    .onAppear { width = geo.size.width }
                    .onChange(of: geo.size.width) { width = geo.size.width }
            })
            .offset(x: min(0, offset))
            .simultaneousGesture(
                DragGesture(minimumDistance: 18)
                    .onChanged { v in
                        guard !committed else { return }
                        let dx = v.translation.width, dy = v.translation.height
                        // Leftward, horizontal-dominant drags only — vertical
                        // scrolling and the leading (rightward) system swipe
                        // keep full ownership of everything else.
                        guard dx < 0, abs(dx) > abs(dy) * 1.2 else {
                            if offset != 0 {
                                withAnimation(.spring(duration: 0.25)) { offset = 0 }
                            }
                            return
                        }
                        offset = dx
                        let past = progress >= 0.45
                        if past != pastThreshold {
                            pastThreshold = past
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        }
                    }
                    .onEnded { _ in
                        guard !committed else { return }
                        if pastThreshold {
                            committed = true
                            withAnimation(.easeOut(duration: 0.18)) { offset = -width }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { onArchive() }
                        } else {
                            pastThreshold = false
                            withAnimation(.spring(duration: 0.3)) { offset = 0 }
                        }
                    }
            )
            .listRowBackground(
                ZStack(alignment: .trailing) {
                    baseBackground
                    // The revealed strip: full row height, exactly as wide as
                    // the drag — the Outlook "full line", not a rounded chip.
                    OutlookStyle.archiveGreen
                        .frame(width: max(0, -offset))
                    if -offset > 44 {
                        VStack(spacing: 3) {
                            Image(systemName: "archivebox.fill")
                                .font(.system(size: 18, weight: .semibold))
                            if pastThreshold {
                                Text("Archive")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                        }
                        .foregroundStyle(.white)
                        .scaleEffect(pastThreshold ? 1.12 : 1.0)
                        .animation(.spring(duration: 0.18), value: pastThreshold)
                        .padding(.trailing, 22)
                        .transition(.opacity)
                    }
                }
            )
    }
}
