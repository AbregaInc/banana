import Foundation

/// How a calendar event repeats, as the Repeat picker shows it — and as the one RFC 5545 `RRULE`
/// line Google keeps on the series.
///
/// Weekly on several days ("every week on Mon, Wed and Fri", `BYDAY=MO,WE,FR`) is first-class:
/// the picker's day toggles edit `weekdays`, and "Every weekday" is just Mon–Fri. Pure, so the
/// rule text — the part that decides what lands on a real calendar — is covered by tests.
struct EventRepeat: Hashable {
    enum Frequency: String, CaseIterable, Identifiable {
        case daily = "DAILY", weekly = "WEEKLY", monthly = "MONTHLY", yearly = "YEARLY"
        var id: String { rawValue }

        /// "day", "week"… for "Every 2 weeks".
        var unit: String {
            switch self {
            case .daily: return "day"
            case .weekly: return "week"
            case .monthly: return "month"
            case .yearly: return "year"
            }
        }
    }

    /// `Calendar`'s numbering: Sunday is 1.
    enum Weekday: Int, CaseIterable, Comparable, Identifiable {
        case sunday = 1, monday, tuesday, wednesday, thursday, friday, saturday
        var id: Int { rawValue }

        var code: String { ["SU", "MO", "TU", "WE", "TH", "FR", "SA"][rawValue - 1] }

        init?(code: String) {
            guard let index = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"].firstIndex(of: code.uppercased()) else {
                return nil
            }
            self.init(rawValue: index + 1)
        }

        init(of date: Date, calendar: Calendar) {
            self = Weekday(rawValue: calendar.component(.weekday, from: date)) ?? .monday
        }

        static func < (lhs: Weekday, rhs: Weekday) -> Bool { lhs.rawValue < rhs.rawValue }

        static let workdays: Set<Weekday> = [.monday, .tuesday, .wednesday, .thursday, .friday]

        /// The week in the order this calendar's locale starts it (Monday first in most of the
        /// world, Sunday in the US).
        static func ordered(for calendar: Calendar) -> [Weekday] {
            let first = calendar.firstWeekday
            return (0..<7).compactMap { Weekday(rawValue: (first - 1 + $0) % 7 + 1) }
        }

        /// Monday-first, the order rules are written in — so the same days always give the same
        /// text, whichever order they were tapped in.
        static func ruleOrder(_ days: Set<Weekday>) -> [Weekday] {
            days.sorted { ($0.rawValue + 5) % 7 < ($1.rawValue + 5) % 7 }
        }
    }

    /// Monthly on a day of the month ("the 7th"), or on an ordinal weekday ("the first Tuesday",
    /// ordinal -1 for "the last Friday").
    enum MonthlyMode: Hashable {
        case dayOfMonth(Int)
        case weekdayOrdinal(ordinal: Int, weekday: Weekday)
    }

    enum End: Hashable {
        case never
        /// The last day included.
        case onDate(Date)
        case afterCount(Int)
    }

    var frequency: Frequency
    var interval: Int = 1
    /// Weekly only, never empty there.
    var weekdays: Set<Weekday> = []
    /// Monthly only; nil means the start's day of the month.
    var monthly: MonthlyMode? = nil
    var end: End = .never
}

/// What an event's recurrence lines say, for the picker.
enum EventRecurrence: Hashable {
    case none
    case rule(EventRepeat)
    /// A rule the picker can't show (several RRULEs, BYSETPOS, hourly…). Shown as a summary and
    /// never rewritten unless the person picks something else.
    case unsupported([String])

    var repeatValue: EventRepeat? {
        if case .rule(let value) = self { return value }
        return nil
    }

    var repeats: Bool { self != .none }
}

/// The Repeat picker's rows.
enum EventRepeatPreset: String, CaseIterable, Identifiable {
    case never, daily, weekdays, weekly, monthly, yearly, custom
    var id: String { rawValue }
}

// MARK: - Building

extension EventRepeat {
    /// The default rule for a preset, from the event's start: weekly on its weekday, monthly on
    /// its day of the month.
    static func preset(_ preset: EventRepeatPreset, start: Date, calendar: Calendar = .current) -> EventRecurrence {
        switch preset {
        case .never: return .none
        case .daily: return .rule(EventRepeat(frequency: .daily))
        case .weekdays: return .rule(EventRepeat(frequency: .weekly, weekdays: Weekday.workdays))
        case .weekly: return .rule(EventRepeat(frequency: .weekly, weekdays: [Weekday(of: start, calendar: calendar)]))
        case .monthly: return .rule(EventRepeat(frequency: .monthly))
        case .yearly: return .rule(EventRepeat(frequency: .yearly))
        case .custom: return .rule(EventRepeat(frequency: .weekly, weekdays: [Weekday(of: start, calendar: calendar)]))
        }
    }

    /// Which picker row a rule reads as.
    static func preset(of recurrence: EventRecurrence) -> EventRepeatPreset {
        switch recurrence {
        case .none: return .never
        case .unsupported: return .custom
        case .rule(let value):
            guard value.interval == 1 else { return .custom }
            switch value.frequency {
            case .daily: return .daily
            case .weekly: return value.weekdays == Weekday.workdays ? .weekdays : .weekly
            case .monthly:
                if case .weekdayOrdinal = value.monthly { return .custom }
                return .monthly
            case .yearly: return .yearly
            }
        }
    }

    /// The `RRULE:` line. `start` decides nothing that's already explicit; `isAllDay` decides
    /// the form of `UNTIL` (RFC 5545: a date for an all-day series, a UTC date-time otherwise —
    /// Google rejects the mismatch).
    func rule(isAllDay: Bool, calendar: Calendar = .current) -> String {
        var parts = ["FREQ=\(frequency.rawValue)"]
        if interval > 1 { parts.append("INTERVAL=\(interval)") }
        switch frequency {
        case .weekly:
            if !weekdays.isEmpty {
                parts.append("BYDAY=" + Weekday.ruleOrder(weekdays).map(\.code).joined(separator: ","))
            }
        case .monthly:
            switch monthly {
            case .dayOfMonth(let day): parts.append("BYMONTHDAY=\(day)")
            case .weekdayOrdinal(let ordinal, let weekday): parts.append("BYDAY=\(ordinal)\(weekday.code)")
            case nil: break
            }
        case .daily, .yearly:
            break
        }
        switch end {
        case .never: break
        case .afterCount(let count): parts.append("COUNT=\(max(1, count))")
        case .onDate(let lastDay):
            if isAllDay {
                parts.append("UNTIL=" + Self.dateFormatter(calendar).string(from: lastDay))
            } else {
                let lastInstant = RecurrenceEndDate.lastIncludedInstant(lastDayIncluded: lastDay, calendar: calendar)
                parts.append("UNTIL=" + Self.utcFormatter.string(from: lastInstant))
            }
        }
        return "RRULE:" + parts.joined(separator: ";")
    }

    /// For a weekly series whose own day isn't one of its days: the first chosen day on or after
    /// `start`, at the same time — a series' start always counts as an occurrence, so leaving it
    /// would add a stray one. Nil when `start` is already one of the days.
    func alignedStart(_ start: Date, calendar: Calendar = .current) -> Date? {
        guard frequency == .weekly, !weekdays.isEmpty,
              !weekdays.contains(Weekday(of: start, calendar: calendar)) else { return nil }
        for offset in 1...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { continue }
            if weekdays.contains(Weekday(of: day, calendar: calendar)) { return day }
        }
        return nil
    }
}

// MARK: - Reading

extension EventRepeat {
    /// What Google's recurrence lines say. EXDATE and RDATE lines (skipped and added
    /// occurrences) don't change the picker; anything the picker can't express is `unsupported`.
    static func parse(_ lines: [String], start: Date, calendar: Calendar = .current) -> EventRecurrence {
        let rules = lines.filter { $0.uppercased().hasPrefix("RRULE:") }
        guard !rules.isEmpty else { return .none }
        guard rules.count == 1 else { return .unsupported(lines) }
        var fields: [String: String] = [:]
        for part in rules[0].dropFirst("RRULE:".count).split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { return .unsupported(lines) }
            fields[pair[0].uppercased()] = pair[1].uppercased()
        }
        let known: Set<String> = ["FREQ", "INTERVAL", "BYDAY", "BYMONTHDAY", "BYMONTH", "COUNT", "UNTIL", "WKST"]
        guard Set(fields.keys).isSubset(of: known),
              let frequency = fields["FREQ"].flatMap(Frequency.init(rawValue:)) else { return .unsupported(lines) }

        var value = EventRepeat(frequency: frequency)
        if let interval = fields["INTERVAL"] {
            guard let number = Int(interval), number >= 1 else { return .unsupported(lines) }
            value.interval = number
        }
        let byDay = fields["BYDAY"].map { $0.split(separator: ",").map(String.init) }

        switch frequency {
        case .daily:
            guard fields["BYMONTHDAY"] == nil, fields["BYMONTH"] == nil else { return .unsupported(lines) }
            if let byDay {
                // Every day but only on these days is weekly on them — Google writes "every
                // weekday" either way.
                guard value.interval == 1, let days = plainWeekdays(byDay) else { return .unsupported(lines) }
                value.frequency = .weekly
                value.weekdays = days
            }
        case .weekly:
            guard fields["BYMONTHDAY"] == nil, fields["BYMONTH"] == nil else { return .unsupported(lines) }
            if let byDay {
                guard let days = plainWeekdays(byDay) else { return .unsupported(lines) }
                value.weekdays = days
            } else {
                value.weekdays = [Weekday(of: start, calendar: calendar)]
            }
        case .monthly:
            guard fields["BYMONTH"] == nil else { return .unsupported(lines) }
            if let monthDay = fields["BYMONTHDAY"] {
                guard byDay == nil, let day = Int(monthDay), (1...31).contains(day) else { return .unsupported(lines) }
                value.monthly = .dayOfMonth(day)
            } else if let byDay {
                guard byDay.count == 1, let ordinal = ordinalWeekday(byDay[0]) else { return .unsupported(lines) }
                value.monthly = .weekdayOrdinal(ordinal: ordinal.0, weekday: ordinal.1)
            }
        case .yearly:
            // "Every year on 7 Oct" is the series' own date; a rule naming other months or days
            // is more than the picker shows.
            guard byDay == nil else { return .unsupported(lines) }
            if let month = fields["BYMONTH"], Int(month) != calendar.component(.month, from: start) {
                return .unsupported(lines)
            }
            if let day = fields["BYMONTHDAY"], Int(day) != calendar.component(.day, from: start) {
                return .unsupported(lines)
            }
        }

        if let count = fields["COUNT"] {
            guard fields["UNTIL"] == nil, let number = Int(count), number >= 1 else { return .unsupported(lines) }
            value.end = .afterCount(number)
        } else if let until = fields["UNTIL"] {
            guard let lastDay = lastDay(fromUntil: until, calendar: calendar) else { return .unsupported(lines) }
            value.end = .onDate(lastDay)
        }
        return .rule(value)
    }

    /// The same lines with the RRULE replaced by `rule` — EXDATE and RDATE (occurrences skipped
    /// or added in Google) kept, so changing the repeat never brings back a deleted occurrence.
    static func replacingRule(in lines: [String], with rule: String) -> [String] {
        [rule] + lines.filter { !$0.uppercased().hasPrefix("RRULE:") }
    }

    private static func plainWeekdays(_ codes: [String]) -> Set<Weekday>? {
        let days = codes.compactMap(Weekday.init(code:))
        return days.count == codes.count && !days.isEmpty ? Set(days) : nil
    }

    /// "2TU" → (2, Tuesday), "-1FR" → (-1, Friday).
    private static func ordinalWeekday(_ code: String) -> (Int, Weekday)? {
        guard code.count >= 3, let weekday = Weekday(code: String(code.suffix(2))),
              let ordinal = Int(code.dropLast(2)), ordinal != 0, (-5...5).contains(ordinal) else { return nil }
        return (ordinal, weekday)
    }

    /// `UNTIL` back to the last day it includes: a date as written, a UTC instant as the local
    /// day it falls on.
    private static func lastDay(fromUntil value: String, calendar: Calendar) -> Date? {
        if value.count == 8 { return dateFormatter(calendar).date(from: value) }
        guard let instant = utcFormatter.date(from: value) else { return nil }
        return calendar.startOfDay(for: instant)
    }

    private static let utcFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static func dateFormatter(_ calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }
}

// MARK: - Words

extension EventRepeat {
    /// "Every week on Mon, Wed and Fri", "Every 2 weeks on Tue, until 25 Oct", "Every month on
    /// the last Friday, 10 times".
    func summary(start: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        var text = cadence(start: start, calendar: calendar, locale: locale)
        switch end {
        case .never: break
        case .afterCount(let count): text += count == 1 ? ", once" : ", \(count) times"
        case .onDate(let lastDay):
            let style = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, calendar: calendar,
                                         timeZone: calendar.timeZone)
            text += ", until \(lastDay.formatted(style))"
        }
        return text
    }

    private func cadence(start: Date, calendar: Calendar, locale: Locale) -> String {
        let every = interval == 1 ? "Every \(frequency.unit)" : "Every \(interval) \(frequency.unit)s"
        switch frequency {
        case .daily:
            return every
        case .weekly:
            if interval == 1, weekdays == Weekday.workdays { return "Every weekday" }
            var symbols = calendar
            symbols.locale = locale
            let names = Weekday.ordered(for: calendar).filter(weekdays.contains)
                .map { symbols.shortWeekdaySymbols[$0.rawValue - 1] }
            guard !names.isEmpty else { return every }
            return "\(every) on \(Self.list(names, locale: locale))"
        case .monthly:
            switch monthly ?? .dayOfMonth(calendar.component(.day, from: start)) {
            case .dayOfMonth(let day):
                return "\(every) on the \(Self.ordinalNumber(day, locale: locale))"
            case .weekdayOrdinal(let ordinal, let weekday):
                var symbols = calendar
                symbols.locale = locale
                let which = ordinal == -1 ? "last" : ["first", "second", "third", "fourth", "fifth"][min(max(ordinal, 1), 5) - 1]
                return "\(every) on the \(which) \(symbols.weekdaySymbols[weekday.rawValue - 1])"
            }
        case .yearly:
            let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
                .month(.abbreviated).day()
            return "\(every) on \(start.formatted(style))"
        }
    }

    private static func list(_ items: [String], locale: Locale) -> String {
        let formatter = ListFormatter()
        formatter.locale = locale
        return formatter.string(from: items) ?? items.joined(separator: ", ")
    }

    private static func ordinalNumber(_ value: Int, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .ordinal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

extension EventRecurrence {
    /// The line under an event: "Repeats every week on Mon, Wed and Fri". Nil when it doesn't.
    func detailLine(start: Date, calendar: Calendar = .current, locale: Locale = .current) -> String? {
        switch self {
        case .none: return nil
        case .unsupported: return "Repeats on a custom rule from Google Calendar"
        case .rule(let value):
            let summary = value.summary(start: start, calendar: calendar, locale: locale)
            return "Repeats " + summary.prefix(1).lowercased() + summary.dropFirst()
        }
    }
}
