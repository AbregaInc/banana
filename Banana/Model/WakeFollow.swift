import Foundation

/// Moving the wake alarm while Banana isn't open.
///
/// The alarm was armed only with the app in front, so a meeting put on tomorrow morning after
/// you last opened Banana left the alarm where it was. The background calendar refresh now
/// follows the calendar too, under one rule that can't make things worse: **a background pass
/// only adds a wake to a day that has none, or makes a day's wake earlier.** Never later, never
/// fewer, and nothing at all when a calendar couldn't be read — a missing meeting must not read
/// as "sleep in". An alarm that rings earlier than it needed to is put right the next time the
/// app is opened; one that doesn't ring can't be.
enum WakeFollow {
    struct Change: Equatable {
        /// The alarm to arm.
        var new: Date
        /// The one it stands in for, cancelled only after `new` is armed.
        var replacing: Date?
    }

    /// Wakes closer together than this are the same wake: not worth an alarm of its own.
    static let tolerance: TimeInterval = 60

    static func changes(armed: [Date], computed: [Date], sourcesHealthy: Bool, now: Date,
                        calendar: Calendar = .current) -> [Change] {
        guard sourcesHealthy else { return [] }
        var earliestArmed: [Date: Date] = [:]
        for date in armed where date > now {
            let day = calendar.startOfDay(for: date)
            earliestArmed[day] = min(earliestArmed[day] ?? date, date)
        }
        var wanted: [Date: Date] = [:]
        for date in computed where date > now {
            let day = calendar.startOfDay(for: date)
            wanted[day] = min(wanted[day] ?? date, date)
        }
        return wanted.keys.sorted().compactMap { day in
            guard let new = wanted[day] else { return nil }
            guard let existing = earliestArmed[day] else { return Change(new: new, replacing: nil) }
            return new < existing.addingTimeInterval(-tolerance) ? Change(new: new, replacing: existing) : nil
        }
    }
}
