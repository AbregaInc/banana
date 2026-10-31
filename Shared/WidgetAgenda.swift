import Foundation
import Security

/// What the iPhone widgets draw: today's and tomorrow's meetings, with leave-by times, written
/// by the app into a keychain item shared with the widget extension and read from there.
///
/// Stored rather than live, because a widget runs in its own process on its own schedule; it
/// must be able to draw the next few hours from whatever the app last knew. The keychain rather
/// than an App Group file because a team-prefixed keychain group needs no developer-portal
/// registration — the same arrangement the Watch complication uses. Readable after first unlock,
/// so Lock Screen widgets draw while the phone is locked.
struct WidgetAgenda: Codable, Equatable {
    struct Event: Codable, Equatable, Identifiable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        /// The calendar's colour, "#RRGGBB".
        let colorHex: String?
        let location: String?
        let isVirtual: Bool
        let joinURL: URL?
        /// When to leave for it, if it is somewhere you travel to.
        let leaveBy: Date?
        let travelMinutes: Int?
        let isTentative: Bool
        let showsAsFree: Bool
        /// The trip's mode as an SF Symbol ("figure.walk"), so leave-by shows how you're going.
        var travelSymbol: String? = nil
    }

    var generatedAt: Date
    var events: [Event]

    static let widgetKinds = ["BananaNextMeeting", "BananaDayGrid"]
    private static let service = "com.boris.banana.widget.agenda"
    private static let account = "agenda"
    /// The keychain group shared with the widgets: the signing team's prefix, then a name of ours.
    /// A build signed by no team (a simulator build with no Config/Local.xcconfig) has no shared
    /// groups, and keeps the item in its own keychain.
    static func accessGroup(team: String?) -> [String: Any] {
        guard let team, !team.isEmpty else { return [:] }
        return [kSecAttrAccessGroup as String: "\(team).com.boris.banana.widget.agenda"]
    }
    private static let group = accessGroup(team: Bundle.main.object(forInfoDictionaryKey: "BananaTeamID") as? String)

    private static var match: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account].merging(group) { own, _ in own }
    }

    static func load() -> WidgetAgenda? {
        var query = match
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(WidgetAgenda.self, from: data)
    }

    /// Write, returning whether the content changed (so the caller only reloads widgets when
    /// something they draw is different).
    @discardableResult
    func save() -> Bool {
        if let existing = Self.load(), existing.events == events { return false }
        guard let data = try? JSONEncoder().encode(self) else { return false }
        let update = SecItemUpdate(Self.match as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var insertion = Self.match
        insertion[kSecValueData as String] = data
        insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(insertion as CFDictionary, nil) == errSecSuccess
    }

    // MARK: - What to show when

    /// The meeting a glance is about at `now`: one in progress, otherwise the next to start.
    func focus(at now: Date) -> Event? {
        let live = events.filter { !$0.showsAsFree }.sorted { $0.start < $1.start }
        if let current = live.first(where: { $0.start <= now && $0.end > now }) { return current }
        return live.first { $0.start > now }
    }

    /// Events overlapping `[from, to)`, in order.
    func events(from: Date, to: Date) -> [Event] {
        events.filter { $0.end > from && $0.start < to }.sorted { $0.start < $1.start }
    }

    /// The moments a widget's contents change: each start, end and leave-by within `horizon`.
    /// A timeline entry at each keeps "next" and "in 12 min" honest without the app running.
    func changePoints(after now: Date, horizon: TimeInterval = 24 * 3600) -> [Date] {
        let limit = now.addingTimeInterval(horizon)
        let points = events.flatMap { [$0.leaveBy, $0.start, $0.end].compactMap { $0 } }
            .filter { $0 > now && $0 <= limit }
        return Array(Set(points)).sorted()
    }
}
