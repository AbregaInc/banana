import Foundation
import Security

/// Small, read-only calendar projection shared by the Watch app and its complication. The phone
/// sends it through WatchConnectivity; only the Watch writes the shared-Keychain snapshot.
struct WatchCalendarItem: Codable, Hashable, Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let location: String?
}

enum WatchCalendarSnapshotStore {
    static let widgetKind = "BananaLaunch.v9"
    private static let service = "com.boris.banana.watch.calendar"
    private static let account = "upcoming-events"
    /// The keychain group shared with the Watch face's widget: the signing team's prefix, then a name of ours.
    /// A build signed by no team (a simulator build with no Config/Local.xcconfig) has no shared
    /// groups, and keeps the item in its own keychain.
    static func accessGroup(team: String?) -> [String: Any] {
        guard let team, !team.isEmpty else { return [:] }
        return [kSecAttrAccessGroup as String: "\(team).com.boris.banana.watch.calendar"]
    }
    private static let group = accessGroup(team: Bundle.main.object(forInfoDictionaryKey: "BananaTeamID") as? String)

    @discardableResult
    static func save(_ items: [WatchCalendarItem]) -> Bool {
        guard let data = try? JSONEncoder().encode(items) else { return false }
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ].merging(group) { own, _ in own }
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(match as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        if updateStatus == errSecItemNotFound {
            var insertion = match
            insertion[kSecValueData as String] = data
            insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(insertion as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    static func load() -> [WatchCalendarItem] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ].merging(group) { own, _ in own }
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let items = try? JSONDecoder().decode([WatchCalendarItem].self, from: data)
        else { return [] }
        return items.sorted { $0.start < $1.start }
    }

    static func upcoming(from items: [WatchCalendarItem], at date: Date, limit: Int = 2)
        -> [WatchCalendarItem] {
        Array(
            items
                .filter { $0.end > date }
                .sorted { lhs, rhs in
                    if lhs.start != rhs.start { return lhs.start < rhs.start }
                    return lhs.end < rhs.end
                }
                .prefix(limit)
        )
    }
}
