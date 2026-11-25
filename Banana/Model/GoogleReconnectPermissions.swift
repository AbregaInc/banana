#if !BANANA_PUBLIC
import Foundation

/// Reconnect restores existing Mail access and upgrades legacy read-only grants.
enum GoogleReconnectPermissions {
    static func scopes(calendar: [String], mail: [String], readable: Bool,
                       enabled: Bool, additional: [String]) -> [String] {
        let read = "https://www.googleapis.com/auth/gmail.readonly"
        let modify = "https://www.googleapis.com/auth/gmail.modify"
        let full = "https://mail.google.com/"
        guard enabled, readable || mail.contains(where: { [read, modify, full].contains($0) }) else {
            return Array(Set(calendar)).sorted()
        }
        var restored = Set(mail)
        restored.remove(read)
        if !restored.contains(full) { restored.insert(modify) }
        return restored.union(calendar).union(additional).sorted()
    }
}
#endif
