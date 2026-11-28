#if BANANA_AI
import Foundation

enum AssistantFreeTime {
    enum InvalidWindow: LocalizedError {
        case date, period, time
        var errorDescription: String? {
            switch self {
            case .date: "Choose a day from today through the next 29 days."
            case .period: "Choose one date, this week, next week, or the next seven days."
            case .time: "Choose a valid local time in HH:mm format."
            }
        }
    }

    static func weekday(_ name: String, after now: Date, calendar: Calendar) -> Date? {
        let names = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        guard let weekday = names.firstIndex(of: name.lowercased()) else { return nil }
        let today = calendar.startOfDay(for: now)
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
            .first { calendar.component(.weekday, from: $0) == weekday + 1 }
    }

    static func days(date: Date?, period: String?, now: Date, horizon: Date, calendar: Calendar) throws -> [Date] {
        let today = calendar.startOfDay(for: now)
        guard let period else {
            let day = date ?? today
            guard day >= today, day < horizon else { throw InvalidWindow.date }
            return [day]
        }
        guard date == nil, ["thisWeek", "nextWeek", "next7days"].contains(period),
              let week = calendar.dateInterval(of: .weekOfYear, for: today) else { throw InvalidWindow.period }
        let anchor = period == "nextWeek" ? week.end : period == "thisWeek" ? week.start : today
        return (0..<7).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: anchor)
        }.filter { $0 >= today && $0 < horizon }
    }

    static func time(_ raw: String, day: Date, calendar: Calendar) throws -> Date {
        let parts = raw.split(separator: ":")
        guard parts.count == 2, parts.allSatisfy({ $0.count == 2 }),
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute),
              let value = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day,
                                        matchingPolicy: .strict),
              calendar.isDate(value, inSameDayAs: day) else {
            throw InvalidWindow.time
        }
        return value
    }

    /// The formatter normalizes invalid dates and 24-hour values. Round-trip the wall clock
    /// before a copied time can become a calendar lookup or a draft.
    static func absoluteTime(_ value: String) -> Date? {
        guard value.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:Z|[+-][0-9]{2}:[0-9]{2})$"#,
                          options: .regularExpression) != nil else { return nil }
        let suffix = value.dropFirst(19)
        guard suffix != "-00:00" else { return nil }  // The sender's local offset is unknown.
        var offset = 0
        if suffix != "Z" {
            guard let hours = Int(suffix.dropFirst().prefix(2)), let minutes = Int(suffix.suffix(2)),
                  hours <= 14, minutes < 60, hours < 14 || minutes == 0 else { return nil }
            offset = (hours * 60 + minutes) * (suffix.first == "-" ? -60 : 60)
        }
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: offset)
        guard let date = formatter.date(from: value),
              formatter.string(from: date).prefix(19) == value.prefix(19) else { return nil }
        return date
    }

    /// Clip to the requested window and merge by advancing the cursor to the
    /// furthest busy end. Touching events and overlapping calendar copies leave no false gap.
    static func slots(in window: DateInterval, busy: [DateInterval], minimum: TimeInterval) -> [DateInterval] {
        var cursor = window.start
        var free: [DateInterval] = []
        for interval in busy.sorted(by: { $0.start < $1.start }) {
            if interval.end <= cursor { continue }
            if interval.start >= window.end { break }
            if interval.start.timeIntervalSince(cursor) >= minimum {
                free.append(DateInterval(start: cursor, end: interval.start))
            }
            cursor = max(cursor, interval.end)
        }
        if window.end.timeIntervalSince(cursor) >= minimum {
            free.append(DateInterval(start: cursor, end: window.end))
        }
        return free
    }
}
#endif
