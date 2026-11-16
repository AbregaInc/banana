#if !BANANA_PUBLIC
import Foundation

/// Reconnect restores previously enabled access, including a refused grant. It does not
/// enroll Calendar-only accounts in Mail or promote read-only Mail to write access.
enum GoogleReconnectPermissions {
    static func scopes(calendar: [String], mail: [String], readable: Bool, modifiable: Bool,
                       enabled: Bool, additional: [String]) -> [String] {
        let read = "https://www.googleapis.com/auth/gmail.readonly"
        let modify = "https://www.googleapis.com/auth/gmail.modify"
        let full = "https://mail.google.com/"
        guard enabled, readable || mail.contains(where: { [read, modify, full].contains($0) }) else {
            return Array(Set(calendar)).sorted()
        }
        let existing = mail.isEmpty ? [modifiable ? modify : read] : mail
        return Array(Set(calendar + existing + additional)).sorted()
    }
}
#endif
