import Foundation

/// Which instance of a repeating reminder is outstanding now. One rule for every repeat, daily or
/// monthly alike: an instance stays overdue until the next one's day begins; then that one is the
/// one to do and the earlier ones were missed. Yesterday's 8 PM creatine is missed at midnight and
/// today's is the one; this week's watering stays overdue until next week's day.
///
/// The rule was "until the next one's time" (2 Oct 2026), which kept yesterday's 8 PM creatine as
/// its own row all of today until 8 PM, beside today's: two rows for one habit, and the only way to
/// clear yesterday's was to tick it, saying it was done. Pure, for tests.
enum ReminderRollover {
    /// The outstanding instance's due date, and how many instances before it were missed.
    static func current(storedDue: Date, recurrence: CalendarItemRecurrence, now: Date,
                        calendar: Calendar = .current) -> (due: Date, missed: Int) {
        guard let component = recurrence.calendarComponent else { return (storedDue, 0) }
        // Counted from the stored date each time, so a monthly one on the 31st doesn't drift to
        // the 28th after February.
        func instance(_ k: Int) -> Date? { calendar.date(byAdding: component, value: k, to: storedDue) }
        func begun(_ date: Date) -> Bool { calendar.startOfDay(for: date) <= now }
        var k = 0
        // A reminder can be months behind: jump near now before stepping.
        let behind = calendar.dateComponents([component], from: storedDue, to: now).value(for: component) ?? 0
        if behind > 1 { k = behind - 1 }
        if let due = instance(k), !begun(due) { k = 0 }
        while let next = instance(k + 1), begun(next) { k += 1 }
        return (instance(k) ?? storedDue, k)
    }

    /// A reminder's id on the timeline: "task:<reminder>" for a one-off, and
    /// "task:<reminder>:<due>" for each instance of a repeating one.
    static func occurrenceID(reminder: String, instanceDue: Date?) -> String {
        instanceDue.map { "task:\(reminder):\(Int($0.timeIntervalSinceReferenceDate))" } ?? "task:\(reminder)"
    }

    /// The instance a repeating reminder's timeline id names; nil for a one-off's or anything else.
    static func instanceDue(occurrenceID id: String) -> Date? {
        let parts = id.split(separator: ":")
        guard parts.count == 3, parts[0] == "task", let seconds = Int(parts[2]) else { return nil }
        return Date(timeIntervalSinceReferenceDate: TimeInterval(seconds))
    }

    /// The instance after `instanceDue`: where "Missed it" moves a repeating reminder on to.
    static func next(after instanceDue: Date, recurrence: CalendarItemRecurrence,
                     calendar: Calendar = .current) -> Date? {
        recurrence.calendarComponent.flatMap { calendar.date(byAdding: $0, value: 1, to: instanceDue) }
    }
}

extension CalendarItemRecurrence {
    /// The step between instances; nil for one that doesn't repeat.
    var calendarComponent: Calendar.Component? {
        switch self {
        case .never: return nil
        case .daily: return .day
        case .weekly: return .weekOfYear
        case .monthly: return .month
        case .yearly: return .year
        }
    }
}

/// Earlier instances of a repeating reminder that went undone, said on the one that's due now.
struct ReminderMissed: Hashable, Codable {
    var count: Int
    var every: CalendarItemRecurrence

    var text: String {
        switch (every, count) {
        case (.daily, 1): return "Missed yesterday"
        case (.daily, _): return "Missed \(count) days"
        case (.weekly, 1): return "Missed last week"
        case (.weekly, _): return "Missed \(count) weeks"
        case (.monthly, 1): return "Missed last month"
        case (.monthly, _): return "Missed \(count) months"
        case (.yearly, 1): return "Missed last year"
        case (.yearly, _): return "Missed \(count) years"
        case (.never, _): return "Missed"
        }
    }
}
