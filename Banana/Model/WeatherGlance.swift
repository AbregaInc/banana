import Foundation

/// Which hour of a day's forecast the plan's weather chip shows (`WeatherChip`): for today, the
/// hour it is now (or the nearest one the forecast has); for another day, midday.
///
/// The forecast used to run down Plan's List as a stripe. With List gone the Day and Week
/// calendars had no weather at all, so the day's header carries it.
enum WeatherGlance {
    /// The moment the chip stands for: now, today; midday on another day.
    static func instant(on day: Date, now: Date, calendar: Calendar = .current) -> Date {
        if calendar.isDate(day, inSameDayAs: now) { return now }
        return calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
    }

    static func hourIndex(of hours: [Date], on day: Date, now: Date, calendar: Calendar = .current) -> Int? {
        guard !hours.isEmpty else { return nil }
        let target = instant(on: day, now: now, calendar: calendar)
        return hours.indices.min { abs(hours[$0].timeIntervalSince(target)) < abs(hours[$1].timeIntervalSince(target)) }
    }
}
