// KeychainStore (W3-T4) — the secure home for the opt-in Groq cloud API key.
//
// The cloud fallback tier is strictly opt-in (audio leaves the Mac only when
// the user turns it on AND provides a key), so the key is a genuine secret: it
// belongs in the macOS Keychain, NOT in UserDefaults / oliv.toml alongside the
// non-secret knobs. This is a deliberately tiny generic-password wrapper over the
// Security framework (no third-party Swift deps — the project rule), stored under
// service "com.oliv.app" / account "groq-api-key".
//
// Testability: everything goes through the `KeychainStoring` protocol so the
// settings store / tests inject `InMemoryKeychain` and never touch the real login
// keychain (which an unsigned test host can't reliably write). Production uses
// `KeychainStore`, which talks to SecItem* directly.

import Foundation
import Security

/// The seam OLIVSettings depends on: read/write a string secret by account.
/// Setting nil deletes the item. Both real and in-memory backends conform.
protocol KeychainStoring {
    func string(forAccount account: String) -> String?
    func set(_ value: String?, forAccount account: String)
}

extension KeychainStoring {
    /// Convenience for the single secret this app stores today.
    func groqAPIKey() -> String? { string(forAccount: KeychainStore.groqAccount) }
    func setGroqAPIKey(_ value: String?) { set(value, forAccount: KeychainStore.groqAccount) }
}

/// Real backend: generic-password items in the login keychain under a fixed
/// service. Reads that miss return nil; writes are idempotent (add-or-update);
/// setting nil/empty deletes. Never throws — a keychain hiccup degrades to "no
/// key" rather than crashing the app (failure philosophy: never crash).
final class KeychainStore: KeychainStoring {
    static let service = "com.oliv.app"
    static let groqAccount = "groq-api-key"

    static let shared = KeychainStore()

    private let service: String
    init(service: String = KeychainStore.service) { self.service = service }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func string(forAccount account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    func set(_ value: String?, forAccount account: String) {
        // An empty string is "no key" — treat it as a delete so a cleared field
        // never leaves a zero-length secret behind.
        guard let value = value, !value.isEmpty else {
            SecItemDelete(baseQuery(account) as CFDictionary)
            return
        }
        let data = Data(value.utf8)
        let attrs = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery(account) as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery(account)
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

/// In-memory backend for tests: the injectable seam so the settings store and
/// its tests round-trip the key without ever touching the real keychain.
final class InMemoryKeychain: KeychainStoring {
    private var storage: [String: String] = [:]

    func string(forAccount account: String) -> String? { storage[account] }

    func set(_ value: String?, forAccount account: String) {
        if let value = value, !value.isEmpty {
            storage[account] = value
        } else {
            storage.removeValue(forKey: account)
        }
    }
}
