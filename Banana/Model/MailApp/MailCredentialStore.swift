#if !BANANA_PUBLIC
import Foundation
import Security

struct MailCredential: Codable, Equatable, Sendable {
    var email: String
    var refreshToken: String
    var scopes: [String]?
    var grantedAt: Date?
    var id: String { email.lowercased() }
}

protocol MailCredentialStorage: Sendable {
    func load() async throws -> [MailCredential]
    func save(_ credentials: [MailCredential]) async throws
}

/// Separate from Calendar, non-synchronizing and scoped to the app variant by its caller.
/// Keychain calls run on this actor rather than synchronously on the main actor.
actor MailCredentialStore: MailCredentialStorage {
    private let service: String
    init(service: String) { self.service = service }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "credentials", kSecAttrSynchronizable as String: false]
    }

    func load() throws -> [MailCredential] {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = item as? Data,
              let credentials = try? JSONDecoder().decode([MailCredential].self, from: data),
              Set(credentials.map(\.id)).count == credentials.count else {
            throw MailAccessError.credentialStorage
        }
        return credentials
    }

    func save(_ credentials: [MailCredential]) throws {
        guard Set(credentials.map(\.id)).count == credentials.count else { throw MailAccessError.credentialStorage }
        if credentials.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw MailAccessError.credentialStorage }
            return
        }
        let data = try JSONEncoder().encode(credentials)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw MailAccessError.credentialStorage }
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { throw MailAccessError.credentialStorage }
    }
}

#endif
