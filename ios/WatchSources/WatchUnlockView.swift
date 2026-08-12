import SwiftUI

/// First-run: the token normally arrives silently from the iPhone app via
/// WatchConnectivity (WatchBridge). This screen covers the standalone case —
/// the same unlock code the phone and web use, entered once.
struct WatchUnlockView: View {
    var onUnlocked: () -> Void
    @State private var code = ""
    @State private var busy = false
    @State private var error = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: "lock.circle")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Open Scarlet on your iPhone nearby — or enter your code.")
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                TextField("Code", text: $code)
                    .multilineTextAlignment(.center)
                Button(action: unlock) {
                    if busy { ProgressView() } else { Text("Unlock") }
                }
                .disabled(code.isEmpty || busy)
                if !error.isEmpty {
                    Text(error).font(.caption2).foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Scarlet")
    }

    private func unlock() {
        busy = true; error = ""
        Task {
            defer { busy = false }
            do {
                var req = URLRequest(url: AppConfig.unlockURL)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONSerialization.data(withJSONObject: ["code": code])
                let (data, _) = try await URLSession.shared.data(for: req)
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                guard let token = obj?["token"] as? String, !token.isEmpty else {
                    error = "Wrong code — try again."
                    return
                }
                TokenStore.token = token
                onUnlocked()
            } catch {
                self.error = "No connection — try again."
            }
        }
    }
}
