#if !BANANA_PUBLIC
import Foundation
import Combine

/// The rows Send later offers before anything is typed (MAIL-UX 6.5.1), each with the time it
/// stands for, so nobody has to work out what "this weekend" means. Pure: `now` and the calendar
/// are handed in.
enum MailTimePresets {

    struct Preset: Equatable, Identifiable, Sendable {
        var id: String
        var title: String
        var date: Date
    }

    /// Later today (three hours on, rounded up to the half hour, while that is before 9 PM),
    /// tomorrow morning, the weekend, and Monday morning. "Morning" is 8 AM.
    static func rows(now: Date, calendar: Calendar = .current) -> [Preset] {
        var rows: [Preset] = []
        if let later = laterToday(now: now, calendar: calendar) {
            rows.append(Preset(id: "later", title: "Later today", date: later))
        }
        let tomorrow = tomorrowMorning(now: now, calendar: calendar)
        rows.append(Preset(id: "tomorrow", title: "Tomorrow morning", date: tomorrow))
        let weekend = weekend(after: now, calendar: calendar)
        let isWeekend = [1, 7].contains(calendar.component(.weekday, from: now))
        rows.append(Preset(id: "weekend", title: isWeekend ? "Next weekend" : "This weekend", date: weekend))
        // On a Sunday Monday is tomorrow, and a second row for it would only repeat the first.
        let monday = nextMonday(after: now, calendar: calendar)
        if monday != tomorrow {
            rows.append(Preset(id: "monday", title: "Monday morning", date: monday))
        }
        return rows
    }

    static func laterToday(now: Date, calendar: Calendar) -> Date? {
        let rounded = Self.roundedUpToHalfHour(now.addingTimeInterval(3 * 3_600), calendar: calendar)
        guard calendar.isDate(rounded, inSameDayAs: now),
              calendar.component(.hour, from: rounded) < 21 else { return nil }
        return rounded
    }

    static func tomorrowMorning(now: Date, calendar: Calendar) -> Date {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        return calendar.date(bySettingHour: MailTimePhrase.morningHour, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }

    /// Saturday, 9 AM; on a Saturday or a Sunday, the next one.
    static func weekend(after now: Date, calendar: Calendar) -> Date {
        let weekday = calendar.component(.weekday, from: now)           // Sunday is 1, Saturday is 7
        let ahead = weekday == 7 ? 7 : (7 - weekday + 7) % 7
        let day = calendar.date(byAdding: .day, value: ahead, to: calendar.startOfDay(for: now)) ?? now
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
    }

    /// The Monday after today, 8 AM.
    static func nextMonday(after now: Date, calendar: Calendar) -> Date {
        let weekday = calendar.component(.weekday, from: now)
        let ahead = (9 - weekday) % 7 == 0 ? 7 : (9 - weekday) % 7
        let day = calendar.date(byAdding: .day, value: ahead, to: calendar.startOfDay(for: now)) ?? now
        return calendar.date(bySettingHour: MailTimePhrase.morningHour, minute: 0, second: 0, of: day) ?? day
    }

    private static func roundedUpToHalfHour(_ date: Date, calendar: Calendar) -> Date {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let minute = parts.minute ?? 0
        let floored = calendar.date(from: parts) ?? date
        if minute == 0 || minute == 30,
           date.timeIntervalSince(floored) < 1 { return floored }
        let add = minute < 30 ? 30 - minute : 60 - minute
        return floored.addingTimeInterval(TimeInterval(add * 60))
    }
}

/// The time picker's own state: what is typed, the rows that answer it, which is highlighted.
/// It is the model of the popover or sheet and nothing else observes it, so a keystroke here
/// re-evaluates the picker alone.
@MainActor
final class MailTimePickerModel: ObservableObject {

    struct Row: Equatable, Identifiable {
        var id: String
        var title: String
        var date: Date
        /// Said at the trailing edge: "Thu 8:00 AM".
        var time: String
    }

    @Published var text = "" { didSet { read() } }
    @Published private(set) var rows: [Row] = []
    @Published private(set) var reading: MailTimePhrase.Reading?
    @Published var highlighted = 0 { didSet { updateNote() } }
    /// What the footer says: who sends it, and when, for the time under the highlight.
    @Published private(set) var note = ""

    private let now: () -> Date
    private let holder: MailScheduleCopy.Holder
    private let calendar: Calendar
    private let locale: Locale

    init(now: @escaping () -> Date, holder: MailScheduleCopy.Holder, calendar: Calendar = .current,
         locale: Locale = .current) {
        self.now = now
        self.holder = holder
        self.calendar = calendar
        self.locale = locale
        read()
    }

    /// "That's in the past.": something typed that is a time, and gone.
    var isPast: Bool {
        if case .past? = reading { return true }
        return false
    }

    private func read() {
        let current = now()
        reading = MailTimePhrase.parse(text, now: current, calendar: calendar)
        var made: [Row] = []
        if case .at(let date)? = reading {
            made.append(Row(id: "typed", title: text.trimmingCharacters(in: .whitespaces), date: date,
                            time: MailScheduleCopy.when(date, now: current, calendar: calendar, locale: locale)))
        }
        for preset in MailTimePresets.rows(now: current, calendar: calendar) {
            made.append(Row(id: preset.id, title: preset.title, date: preset.date,
                            time: MailScheduleCopy.when(preset.date, now: current, calendar: calendar, locale: locale)))
        }
        rows = made
        highlighted = 0
        updateNote()
    }

    private func updateNote() {
        let date = isPast || !rows.indices.contains(highlighted) ? nil : rows[highlighted].date
        note = MailScheduleCopy.pickerNote(holder: holder, at: date, now: now(), calendar: calendar, locale: locale)
    }

    func moveHighlight(by step: Int) {
        guard !rows.isEmpty else { return }
        highlighted = min(max(highlighted + step, 0), rows.count - 1)
    }

    /// The time `Return` chooses: the highlighted row's, which is what was typed when something was.
    /// Nothing, when what is typed is gone by.
    func chosen() -> Date? {
        guard !isPast, rows.indices.contains(highlighted) else { return nil }
        return rows[highlighted].date
    }
}

#endif
