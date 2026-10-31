import Foundation
import Security

/// One connected Google account: who it is, and the long-lived credential that can mint access
/// tokens for it.
///
/// The refresh token is the only durable secret — access tokens last an hour and are minted on
/// demand — so this is all that needs storing or syncing.
struct GoogleAccountCredential: Codable, Equatable, Identifiable, Sendable {
    var email: String
    var refreshToken: String
    var grantedScopes: [String]

    var id: String { email.lowercased() }
}

/// Keychain-backed store of every connected Google account.
///
/// Replaces `GIDSignIn`'s single `currentUser` as the source of truth for *who is connected*.
/// The SDK is still used for the interactive consent flow — it handles the platform differences,
/// PKCE and the redirect properly — but the session it keeps afterwards holds exactly one user,
/// which is why connecting a second Google account used to disconnect the first.
///
/// Stored as one keychain item holding all accounts, marked `kSecAttrSynchronizable` so iCloud
/// Keychain carries it between this person's devices. That is what makes signing in on the Mac
/// also sign in on the iPhone; iCloud Keychain is end-to-end encrypted and is the mechanism Apple
/// provides for exactly this, which is why the tokens are not put anywhere else.
enum GoogleAccountStore {
    private static let service = AppVariant.current.googleKeychainService
    private static let account = "credentials"

    static func load() -> [GoogleAccountCredential] {
        SyncedKeychain.read(service: service, account: account) {
            try? JSONDecoder().decode([GoogleAccountCredential].self, from: $0)
        } ?? []
    }

    @discardableResult
    static func save(_ credentials: [GoogleAccountCredential]) -> Bool {
        guard let data = try? JSONEncoder().encode(credentials) else { return false }
        return SyncedKeychain.write(data, service: service, account: account)
    }

    /// Adds or replaces one account, keyed by email. Returns the full set afterwards.
    @discardableResult
    static func upsert(_ credential: GoogleAccountCredential) -> [GoogleAccountCredential] {
        var all = load()
        all.removeAll { $0.id == credential.id }
        all.append(credential)
        all.sort { $0.email.localizedCaseInsensitiveCompare($1.email) == .orderedAscending }
        save(all)
        return all
    }

    @discardableResult
    static func remove(email: String) -> [GoogleAccountCredential] {
        var all = load()
        all.removeAll { $0.id == email.lowercased() }
        save(all)
        return all
    }

    static func removeAll() {
        SyncedKeychain.delete(service: service, account: account)
    }
}

/// One keychain item that iCloud Keychain carries between this person's devices, with a
/// device-local fallback where syncing is refused. Used for the Google credentials and the Banana
/// session (`BananaAccount`).
enum SyncedKeychain {
    /// The synced item first, then a device-local one (which only exists where syncing was
    /// refused): the first that `decode` can read.
    static func read<Value>(service: String, account: String, _ decode: (Data) -> Value?) -> Value? {
        read(service: service, account: account, synchronizable: true).flatMap(decode)
            ?? read(service: service, account: account, synchronizable: false).flatMap(decode)
    }

    private static func read(service: String, account: String, synchronizable: Bool) -> Data? {
        var query = baseQuery(service: service, account: account, synchronizable: synchronizable)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    @discardableResult
    static func write(_ data: Data, service: String, account: String) -> Bool {
        // Syncing is the point, but it is not worth losing the item over: if the synchronized
        // item cannot be written — iCloud Keychain off, or an entitlement the build does not
        // carry — fall back to a device-local item so it still works here.
        if write(data, service: service, account: account, synchronizable: true) { return true }
        return write(data, service: service, account: account, synchronizable: false)
    }

    private static func write(_ data: Data, service: String, account: String, synchronizable: Bool) -> Bool {
        let query = baseQuery(service: service, account: account, synchronizable: synchronizable)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var insert = query
        insert[kSecValueData as String] = data
        // Available once the device has been unlocked after boot. Not `ThisDeviceOnly`, which
        // would refuse to sync.
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    static func delete(service: String, account: String) {
        SecItemDelete(baseQuery(service: service, account: account, synchronizable: true) as CFDictionary)
        SecItemDelete(baseQuery(service: service, account: account, synchronizable: false) as CFDictionary)
    }

    private static func baseQuery(service: String, account: String, synchronizable: Bool) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: (synchronizable ? kCFBooleanTrue : kCFBooleanFalse) as Any,
        ]
    }
}
