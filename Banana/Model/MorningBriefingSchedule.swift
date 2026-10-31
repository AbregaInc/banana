import Foundation

/// When the Mac should show the morning briefing. The phone shows it when the alarm that woke
/// you just rang; a Mac has no alarm, so its cue is "the first time you sit down at it in the
/// morning" — once per day, inside a window anchored on the planned wake when the smart
/// schedule has one, and on a plain early-morning window when it does not.
enum MorningBriefingSchedule {
    static let lastShownKey = "morningBriefing.lastShownDay"

    /// Wake-anchored window: from a little before the planned wake (you may beat the alarm)
    /// until the morning is plainly over.
    static let beforeWake: TimeInterval = 30 * 60
    static let afterWake: TimeInterval = 5 * 60 * 60
    /// Fallback window when no wake is planned for the day.
    static let fallbackStartHour = 4
    static let fallbackEndHour = 12

    /// True when `now` falls in this morning's window and the briefing has not been shown today.
    static func shouldShow(now: Date, plannedWake: Date?, lastShownDay: String?,
                           calendar: Calendar = .current) -> Bool {
        guard dayKey(now, calendar: calendar) != lastShownDay else { return false }
        let (start, end) = window(for: now, plannedWake: plannedWake, calendar: calendar)
        return now >= start && now < end
    }

    static func window(for now: Date, plannedWake: Date?, calendar: Calendar = .current) -> (Date, Date) {
        if let wake = plannedWake, calendar.isDate(wake, inSameDayAs: now) {
            return (wake.addingTimeInterval(-beforeWake), wake.addingTimeInterval(afterWake))
        }
        let day = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .hour, value: fallbackStartHour, to: day) ?? day
        let end = calendar.date(byAdding: .hour, value: fallbackEndHour, to: day) ?? day
        return (start, end)
    }

    /// Calendar-day identity, so "shown today" survives a relaunch and rolls over at midnight.
    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    static func lastShownDay(_ defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: lastShownKey)
    }

    static func markShown(_ date: Date, calendar: Calendar = .current, defaults: UserDefaults = .standard) {
        defaults.set(dayKey(date, calendar: calendar), forKey: lastShownKey)
    }
}
