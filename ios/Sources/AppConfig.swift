import Foundation
import Security

/// Endpoints (the same servers the web app uses) and the device-token store.
enum AppConfig {
    static let apiBase = "https://zstkwjgtushnyegxkqeg.supabase.co/functions/v1"
    static var unlockURL: URL   { URL(string: "\(apiBase)/app-api?op=unlock")! }
    static var elevenURL: URL   { URL(string: "\(apiBase)/eleven-session")! }
    static var realtimeURL: URL { URL(string: "\(apiBase)/realtime-session")! }
    static var appAPIURL: URL   { URL(string: "\(apiBase)/app-api?v=2")! }
    static let fullAppURL = URL(string: "https://raw.githack.com/idoschoenberg-star/Scarlet/main/index.html")!
    static func toolURL(_ name: String) -> URL {
        URL(string: "\(apiBase)/realtime-session?tool=\(name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name)")!
    }

    /// The region the database lives in. A function the platform starts near
    /// the caller (Frankfurt or Zurich from Israel) pays an ocean for every
    /// query it makes; asked to run beside the database it pays one long hop
    /// instead (speed design, W6 Phase B, section 2 items 1 and 2: the tool
    /// endpoint measured a median 458 ms beside the database and 4,979 ms
    /// from Frankfurt). A region name, never a secret.
    static let dbRegion = "us-west-2"

    /// Pin one request to the database's region (Supabase regional
    /// invocation: the `x-region` header moves where the function runs).
    /// Used on the session mint and on every tool call, the two paths whose
    /// functions make several queries per request.
    static func pinToDatabaseRegion(_ req: inout URLRequest) {
        req.setValue(dbRegion, forHTTPHeaderField: "x-region")
    }
}

/// The per-device token, held in the Keychain (survives reinstalls-off, never
/// in plain storage). Mirrors the web app's `scarletToken`.
enum TokenStore {
    private static let key = "scarlet.deviceToken"

    static var token: String? {
        get { read() }
        set { newValue.map(save) ?? clear() }
    }

    private static func save(_ value: String) {
        clear()
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(q as CFDictionary, nil)
    }
    private static func read() -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    private static func clear() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ] as CFDictionary)
    }
}
