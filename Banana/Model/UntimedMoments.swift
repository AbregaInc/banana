import Foundation

/// When a routine moment with no time of its own — a workout "on start", a manual one — is shown
/// above the hours: only while it's due. That is today, from the routine's own time (the time it
/// carries for ordering the day, e.g. Sleep's 10:30 PM), until it's done or skipped. Not earlier
/// in the day, and not on any other day: a week of "Workout" and "Sleep" on every column said
/// nothing. Pure, for tests.
enum UntimedMoments {
    static func isDue(start: Date, done: Bool, skipped: Bool, now: Date = Date(),
                      calendar: Calendar = .current) -> Bool {
        !done && !skipped && calendar.isDate(start, inSameDayAs: now) && start <= now
    }

    /// The Plan rows' rule for one moment: it leaves once it's done, marked done (`completed`) or,
    /// for a routine that follows a workout, once a workout was recorded that day (`workedOut`).
    static func shows(start: Date, completed: Bool, skipped: Bool, workedOut: Bool,
                      now: Date = Date(), calendar: Calendar = .current) -> Bool {
        isDue(start: start, done: completed || workedOut, skipped: skipped, now: now, calendar: calendar)
    }
}
