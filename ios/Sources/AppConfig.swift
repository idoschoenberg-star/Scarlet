import Foundation
import Security

/// Endpoints (the same servers the web app uses) and the device-token store.
enum AppConfig {
    static let apiBase = "https://zstkwjgtushnyegxkqeg.supabase.co/functions/v1"
    static var unlockURL: URL   { URL(string: "\(apiBase)/app-api?op=unlock")! }
    static var elevenURL: URL   { URL(string: "\(apiBase)/eleven-session")! }
    static var appAPIURL: URL   { URL(string: "\(apiBase)/app-api?v=2")! }
    static func toolURL(_ name: String) -> URL {
        URL(string: "\(apiBase)/realtime-session?tool=\(name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name)")!
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
