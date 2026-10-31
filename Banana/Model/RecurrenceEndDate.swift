import Foundation

/// Turning "repeats until the 25th" into the instants the two calendar providers want.
///
/// The person picks a DAY and means "include that day". Both providers want an instant, and they
/// want different ones:
///
/// - EventKit's `EKRecurrenceEnd(end:)` keeps occurrences starting at or before the instant, so it
///   needs the last moment of the chosen day.
/// - Google's `UNTIL` is also inclusive, and `GoogleRecurrenceRule.truncated(_:before:)` is written
///   in terms of the first occurrence being REMOVED — so it needs the start of the following day.
///
/// Getting this off by one is the difference between a blocker that covers your last day and one
/// that stops the morning before, which is exactly the kind of mistake nobody notices until someone
/// books over it. Computed through `Calendar` rather than by adding 86,400 seconds so a DST
/// boundary inside the series doesn't shift the end.
enum RecurrenceEndDate {

    /// The first instant NOT included — start of the day after the last included day.
    static func firstExcludedInstant(lastDayIncluded: Date, calendar: Calendar = .current) -> Date {
        let startOfDay = calendar.startOfDay(for: lastDayIncluded)
        return calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay
    }

    /// The last instant included, for providers that want an inclusive endpoint.
    static func lastIncludedInstant(lastDayIncluded: Date, calendar: Calendar = .current) -> Date {
        firstExcludedInstant(lastDayIncluded: lastDayIncluded, calendar: calendar)
            .addingTimeInterval(-1)
    }
}
