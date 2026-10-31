import Foundation

/// One visual group of workouts in the Mac list — a day, a week, or a month, depending on the
/// active period's granularity (spec §3.4). `key` is the group's start-of-day/week/month, used
/// both as stable `Identifiable` identity and as the sort key (newest group first).
struct WorkoutGroup: Identifiable {
    let key: Date
    let title: String
    let entries: [WorkoutEntry]
    var id: Date { key }
}

/// Buckets a flat, newest-first `[WorkoutEntry]` (as produced by `WorkoutEntry.merge`) into
/// `WorkoutGroup`s appropriate to the period being shown, so a week of workouts reads as days,
/// a quarter reads as weeks, and a year reads as months — instead of one long undifferentiated
/// list regardless of how wide a window is on screen.
enum WorkoutGrouping {
    /// - `.week` granularity groups by day (Today/Yesterday/weekday name, `Calendar.app`).
    /// - `.month`/`.quarter` groups by week ("Week of Aug 25").
    /// - `.year` groups by month ("August").
    /// Entries within a group keep `WorkoutEntry.merge`'s existing newest-first order (this
    /// function never reorders entries, only partitions them); groups themselves are also
    /// newest-first, by their bucket key.
    static func grouped(_ entries: [WorkoutEntry], granularity: RhythmGranularity,
                         calendar: Calendar = .app, now: Date = Date()) -> [WorkoutGroup] {
        guard !entries.isEmpty else { return [] }

        var order: [Date] = []
        var buckets: [Date: [WorkoutEntry]] = [:]
        for entry in entries {
            let key = bucketKey(for: entry.start, granularity: granularity, calendar: calendar)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(entry)
        }

        return order
            .sorted(by: >)
            .map { key in
                WorkoutGroup(key: key,
                             title: title(for: key, granularity: granularity, calendar: calendar, now: now),
                             entries: buckets[key] ?? [])
            }
    }

    private static func bucketKey(for date: Date, granularity: RhythmGranularity, calendar: Calendar) -> Date {
        switch granularity {
        case .week:
            return calendar.startOfDay(for: date)
        case .month, .quarter:
            return calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
        case .year:
            return calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
        }
    }

    private static func title(for key: Date, granularity: RhythmGranularity, calendar: Calendar, now: Date) -> String {
        switch granularity {
        case .week:
            if calendar.isDate(key, inSameDayAs: now) { return "Today" }
            let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))
            if let yesterday, calendar.isDate(key, inSameDayAs: yesterday) { return "Yesterday" }
            return key.formatted(.dateTime.weekday(.wide))
        case .month, .quarter:
            let f = DateFormatter(); f.dateFormat = "MMM d"
            return "Week of \(f.string(from: key))"
        case .year:
            let f = DateFormatter(); f.dateFormat = "MMMM"
            return f.string(from: key)
        }
    }
}
