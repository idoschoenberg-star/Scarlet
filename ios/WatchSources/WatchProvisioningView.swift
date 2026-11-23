import SwiftUI

/// What the watch shows before it has been provisioned. Not a login screen —
/// there is no password path any more (zero-lock policy, Ido 2026-08-17). The
/// phone mints this watch its own token the moment Scarlet is open on it, so
/// the only thing to say here is what to do and that we're waiting.
struct WatchProvisioningView: View {
    @State private var asking = false

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Open Scarlet on your iPhone")
                    .font(.footnote.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text("It sets this watch up by itself — nothing to type.")
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button {
                    asking = true
                    WatchBridge.shared.requestToken()
                    // Purely cosmetic: the real signal is the token arriving,
                    // which swaps this whole screen out.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { asking = false }
                } label: {
                    if asking { ProgressView() } else { Text("Try again") }
                }
                .padding(.top, 2)
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Scarlet")
        // Ask on appear, and keep asking while this screen is up: the phone
        // may come into range at any moment.
        .task {
            while !Task.isCancelled {
                WatchBridge.shared.requestToken()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }
}
