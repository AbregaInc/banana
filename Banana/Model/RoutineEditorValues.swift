import Foundation

/// What the routine editor's shared controls read and write. A routine keeps its clock time as an
/// hour and a minute and its days as `Calendar` weekday numbers (Sunday is 1; none means every
/// day); `TimeField` wants a `Date` and `WeekdayToggleRow` a set of weekdays. Pure.
enum RoutineEditorValues {
    /// That clock time on `day`, for the time picker to show.
    static func date(hour: Int, minute: Int, on day: Date = Date(), calendar: Calendar = .current) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }

    /// The hour and minute the time picker was set to.
    static func clock(of date: Date, calendar: Calendar = .current) -> (hour: Int, minute: Int) {
        (calendar.component(.hour, from: date), calendar.component(.minute, from: date))
    }

    /// The stored days as the weekday row's selection. Numbers outside 1...7 are dropped.
    static func days(_ weekdays: [Int]) -> Set<EventRepeat.Weekday> {
        Set(weekdays.compactMap(EventRepeat.Weekday.init(rawValue:)))
    }

    /// The weekday row's selection as stored: Sunday-first numbers, each once.
    static func weekdays(_ days: Set<EventRepeat.Weekday>) -> [Int] {
        days.map(\.rawValue).sorted()
    }
}
