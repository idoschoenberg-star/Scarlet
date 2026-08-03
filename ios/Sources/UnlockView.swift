import SwiftUI

/// One-time unlock: the code mints a device token (same server flow as web).
/// After this, Face ID (LocalAuthentication) can gate opens — added in v1.1.
struct UnlockView: View {
    @EnvironmentObject var session: AppSession
    @State private var code = ""
    @State private var busy = false
    @State private var error = ""

    var body: some View {
        VStack(spacing: 18) {
            Text("SCARLET")
                .font(.system(size: 26, weight: .thin)).tracking(10)
                .foregroundStyle(Color(red: 0.98, green: 0.92, blue: 0.92))
            Text("Private. Yours alone.")
                .font(.footnote).foregroundStyle(.secondary)

            SecureField("Unlock code", text: $code)
                .textInputAutocapitalization(.never)
                .multilineTextAlignment(.center)
                .padding(14)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
                .foregroundStyle(.white)

            Button(action: unlock) {
                Text(busy ? "Checking…" : "Unlock")
                    .font(.headline).frame(maxWidth: .infinity).padding(15)
                    .background(LinearGradient(colors: [Color(red: 0.85, green: 0.14, blue: 0.27),
                                                        Color(red: 0.55, green: 0.07, blue: 0.19)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing),
                                in: RoundedRectangle(cornerRadius: 16))
                    .foregroundStyle(.white)
            }
            .disabled(busy || code.isEmpty)

            if !error.isEmpty {
                Text(error).font(.caption).foregroundStyle(Color(red: 0.91, green: 0.69, blue: 0.31))
            }
        }
        .padding(28)
        .frame(maxWidth: 340)
    }

    private func unlock() {
        busy = true; error = ""
        // @MainActor Task: `error`, `busy` (in defer), and `session.setToken` all
        // run after a network `await`, so the whole body must stay on main — not
        // just the one setToken call. This removes the earlier inconsistency where
        // only setToken hopped while the error/busy writes raced.
        Task { @MainActor in
            defer { busy = false }
            do {
                var req = URLRequest(url: AppConfig.unlockURL)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONSerialization.data(withJSONObject: ["code": code])
                let (data, _) = try await URLSession.shared.data(for: req)
                let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                guard let token = obj?["token"] as? String else {
                    error = "That's not it — try again."; return
                }
                session.setToken(token)
            } catch {
                self.error = "Couldn't reach Scarlet — check your connection."
            }
        }
    }
}
