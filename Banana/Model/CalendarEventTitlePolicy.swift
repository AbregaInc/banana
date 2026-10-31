import Foundation

enum CalendarEventTitlePolicy {
    static func isPrivacyPlaceholder(_ rawTitle: String?) -> Bool {
        let title = (rawTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if title.isEmpty { return true }
        return ["busy", "private", "reserved", "no title", "(no title)"].contains(title)
    }
}
