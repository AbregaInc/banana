import Foundation

/// What a day's reminders line shows — the row of reminders above the hours in Day and Week.
///
/// **On today, everything outstanding:** every reminder past its time and not done, whenever it
/// was due, oldest first — then the day's own untimed ones. Those overdue ones are what the Plan
/// badge counts, and they were only to be found in List: a reminder from Saturday, or this
/// morning's scrolled past, had a number on the tab and nothing in the Day view to show for it.
/// Any other day shows just its own untimed reminders. And what the line holds, the hours below
/// don't repeat (`leavesTheGrid`). Pure, for tests.
enum OutstandingReminders {
    static func line<Item>(untimed: [Item], overdue: [Item], isToday: Bool,
                           id: (Item) -> String, due: (Item) -> Date) -> [Item] {
        guard isToday else { return untimed }
        let late = overdue.sorted { due($0) < due($1) }
        let lateIDs = Set(late.map(id))
        return late + untimed.filter { !lateIDs.contains(id($0)) }
    }

    /// An overdue reminder is in today's line, so it isn't drawn among the hours as well — as long
    /// as that line is the one on screen. (A week on the phone shows the selected day's line: with
    /// another day selected, today's overdue reminders stay in today's column.)
    static func leavesTheGrid(overdueReminder: Bool, onToday: Bool, lineIsTodays: Bool) -> Bool {
        overdueReminder && onToday && lineIsTodays
    }

    /// How late, beside an overdue reminder: "Overdue" for one due today, "since yesterday",
    /// "since Sat" within the week, "since Sep 28" for anything older.
    static func since(_ due: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: due),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ...0: return "Overdue"
        case 1: return "since yesterday"
        case 2...6:
            var style = Date.FormatStyle.dateTime.weekday(.abbreviated)
            style.calendar = calendar
            style.timeZone = calendar.timeZone
            return "since \(due.formatted(style))"
        default:
            var style = Date.FormatStyle.dateTime.month(.abbreviated).day()
            style.calendar = calendar
            style.timeZone = calendar.timeZone
            return "since \(due.formatted(style))"
        }
    }
}
