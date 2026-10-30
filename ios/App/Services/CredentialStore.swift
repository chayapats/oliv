import Foundation
import Security

protocol CredentialStoring {
    func read() throws -> String?
    func write(_ token: String) throws
}

struct KeychainCredentialStore: CredentialStoring {
    private static let productionService = "com.chayapat.oliv.ios.server"
    private let service: String

    init(service: String = "com.chayapat.oliv.ios.server") {
        self.service = service
    }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "access-token"]
    }

    func read() throws -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else { throw CredentialError.unavailable }
        return value
    }

    func write(_ token: String) throws {
        guard !token.isEmpty else { return }
        let attributes: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let add = query.merging(attributes) { _, new in new }
            guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw CredentialError.unavailable }
        } else if status != errSecSuccess { throw CredentialError.unavailable }
    }

    #if DEBUG
    /// Cleanup for an isolated test namespace. Production credentials cannot
    /// be deleted through this helper, including an accidentally default store.
    func delete() throws {
        guard service != Self.productionService else { throw CredentialError.unavailable }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialError.unavailable }
    }
    #endif
}

enum CredentialError: LocalizedError {
    case unavailable
    var errorDescription: String? { String(localized: "The access token could not be read or saved securely. Unlock your iPhone and try again.") }
}

#if DEBUG
final class MemoryCredentialStore: CredentialStoring {
    var token: String?
    init(token: String? = nil) { self.token = token }
    func read() throws -> String? { token }
    func write(_ token: String) throws { self.token = token }
}
#endif
