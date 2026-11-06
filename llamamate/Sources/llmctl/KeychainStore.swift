import Foundation
import Security

/// Minimal wrapper around the macOS Keychain for small secrets such as the
/// Hugging Face access token. Values live in the login keychain under the
/// app's service, not in UserDefaults (which stores plaintext in a plist).
enum KeychainStore {
    static let service = "com.llamamate.app"
    static let hfTokenAccount = "hf_token"

    @discardableResult
    static func set(_ value: String, account: String) -> Bool {
        let data = Data(value.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if SecItemCopyMatching(base as CFDictionary, nil) == errSecSuccess {
            let attrs: [String: Any] = [kSecValueData as String: data]
            return SecItemUpdate(base as CFDictionary, attrs as CFDictionary) == errSecSuccess
        } else {
            var add = base
            add[kSecValueData as String] = data
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
    }

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        return value
    }

    @discardableResult
    static func delete(_ account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: Hugging Face token convenience

    /// Non-empty Hugging Face token, or nil.
    static var hfToken: String? {
        guard let t = get(hfTokenAccount), !t.isEmpty else { return nil }
        return t
    }

    static func setHFToken(_ token: String) {
        set(token, account: hfTokenAccount)
    }

    /// One-time migration: move a token previously stored in UserDefaults into
    /// the Keychain, then remove the plaintext copy.
    static func migrateHFTokenFromDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        guard let legacy = defaults.string(forKey: hfTokenAccount), !legacy.isEmpty else { return }
        if get(hfTokenAccount) == nil {
            set(legacy, account: hfTokenAccount)
        }
        defaults.removeObject(forKey: hfTokenAccount)
    }
}
