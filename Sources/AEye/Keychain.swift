import Foundation
import Security

/// API keys for cloud engines, in the login Keychain (account = engine id).
enum Keychain {
    private static let service = "dev.gazevoice.api-keys"
    /// Keys already read this launch, so each one prompts at most once after a rebuild.
    private static var cache: [String: String] = [:]

    /// Whether a key is stored, without reading its value. Reading only the attributes
    /// doesn't trigger the Keychain access prompt, so the menu can call this freely.
    static func has(_ account: String) -> Bool {
        if cache[account] != nil { return true }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnAttributes as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    static func get(_ account: String) -> String? {
        if let v = cache[account] { return v }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        let v = String(data: data, encoding: .utf8)
        cache[account] = v
        return v
    }

    static func set(_ account: String, _ value: String?) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        cache[account] = nil
        guard let value, !value.isEmpty else { return }
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
