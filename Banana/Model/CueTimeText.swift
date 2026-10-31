import Foundation

/// The words for a routine moment's time — its day, and what set it — for the sheet a tap on it in
/// the calendar opens (`CueOccurrenceSheet`). Pure, for tests.
enum CueTimeText {
    /// "Today", "Tomorrow", or "Friday, 2 October".
    static func day(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "Tomorrow, \(date.formatted(.dateTime.weekday(.wide)))"
        }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    /// Why a cue timed by the wake plan lands where it does: the morning's first meeting, or the
    /// usual wake time when there's none. Nil for any other cue — its rule says it already.
    static func wakeReason(on date: Date, firstMeeting: Date?, hasWake: Bool) -> String? {
        guard hasWake else { return nil }
        if let firstMeeting {
            return "Set by your wake plan, to be ready for your first meeting at \(firstMeeting.formatted(date: .omitted, time: .shortened))."
        }
        return "Set by your wake plan: no meetings that morning, so your usual wake time."
    }
}

extension CueTimeText {
    /// The footer under the time: the wake plan's reason for a meeting-timed cue, else the
    /// routine's own rule.
    static func reason(triggerIsWakePlan: Bool, ruleDescription: String, date: Date, plan: WakePlan?,
                       calendar: Calendar = .current) -> String {
        if triggerIsWakePlan,
           let day = plan?.days.first(where: { calendar.isDate($0.date, inSameDayAs: date) }),
           let text = wakeReason(on: date, firstMeeting: day.firstMeeting, hasWake: day.wake != nil) {
            return text
        }
        return ruleDescription
    }
}

extension CueTimeText {
    /// "Today at 7:10 AM", "Tomorrow, Saturday at 7:10 AM" — when a moment is, for a toast.
    static func when(_ date: Date, hasTime: Bool, now: Date = Date(), calendar: Calendar = .current) -> String {
        let day = day(date, now: now, calendar: calendar)
        return hasTime ? "\(day) at \(date.formatted(date: .omitted, time: .shortened))" : day
    }

    /// The toast after skipping one ("Skipped Wake up · Tomorrow, Saturday at 7:10 AM").
    static func skipped(_ title: String, at date: Date, hasTime: Bool, now: Date = Date(),
                        calendar: Calendar = .current) -> String {
        "Skipped \(title) \u{00B7} \(when(date, hasTime: hasTime, now: now, calendar: calendar))"
    }

    /// The toast after bringing one back.
    static func restored(_ title: String, at date: Date, hasTime: Bool, now: Date = Date(),
                         calendar: Calendar = .current) -> String {
        "\(title) is back \u{00B7} \(when(date, hasTime: hasTime, now: now, calendar: calendar))"
    }
}
