import Foundation

/// The fixed grid of 15-minute alarm slots for a full day.
///
/// A "slot" is identified by its minutes-since-midnight (0, 15, 30 … 1425),
/// which is stable, sortable, and easy to persist.
enum TimeSlot {
    static let stepMinutes = 15
    static let count = (24 * 60) / stepMinutes // 96

    /// All slot identifiers for the day, 00:00 … 23:45.
    static let all: [Int] = Array(stride(from: 0, to: 24 * 60, by: stepMinutes))

    static func hour(_ minutesOfDay: Int) -> Int { minutesOfDay / 60 }
    static func minute(_ minutesOfDay: Int) -> Int { minutesOfDay % 60 }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    /// Localized time label, e.g. "6:15 AM" or "06:15" depending on the device setting.
    static func formatted(_ minutesOfDay: Int) -> String {
        var comps = DateComponents()
        comps.hour = hour(minutesOfDay)
        comps.minute = minute(minutesOfDay)
        let date = Calendar.current.date(from: comps) ?? Date()
        return formatter.string(from: date)
    }

    /// True on the top of the hour — used to visually group the long list.
    static func isHourStart(_ minutesOfDay: Int) -> Bool { minute(minutesOfDay) == 0 }
}
