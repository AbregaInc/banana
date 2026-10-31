#if !BANANA_PUBLIC
import Foundation

/// A time typed the way you would say it, for Send later (MAIL-UX 6.5.2): "fri 9am", "tomorrow
/// 8:30", "in 2 hours".
///
/// **There is no parser here.** The words are read by the app's reader of typed event times
/// (`EventPhrase.takeDate`, which holds the system's date detector and the two rules a new parser
/// would rediscover: an hour with no am or pm between 1 and 6 is the afternoon, and a time already
/// past today is tomorrow). What it adds is what sending later needs and an event does not, and the
/// detector does not read: a span ("in 2 hours", "3 days"), a day with no time (that day at 8 AM,
/// where the detector says noon), "monday 9" (the detector reads the ninth of a month) and three
/// fixed words.
enum MailTimePhrase {

    enum Reading: Equatable, Sendable {
        /// A time to send at.
        case at(Date)
        /// Understood, and gone: "That's in the past."
        case past(Date)
    }

    /// What "morning" is: 8 AM, with no setting (MAIL-UX 6.5.1).
    static let morningHour = 8

    /// Nil for words that are not a time.
    static func parse(_ text: String, now: Date, calendar: Calendar = .current) -> Reading? {
        let words = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard !words.isEmpty else { return nil }
        let date = span(words, now: now, calendar: calendar)
            ?? fixedWord(words, now: now, calendar: calendar)
            ?? detected(words, now: now, calendar: calendar)
        guard let date else { return nil }
        return date > now ? .at(date) : .past(date)
    }

    // MARK: Spans

    /// "in 2 hours", "2h", "45 min", "in an hour": from now. "3 days", "in 2 weeks": that many days
    /// from today, at 8 AM.
    private static func span(_ words: String, now: Date, calendar: Calendar) -> Date? {
        let pattern = #"^(?:in )?(\d+(?:\.\d+)?|an?) ?(minutes?|mins?|m|hours?|hrs?|h|days?|d|weeks?|wks?|w)$"#
        guard let match = words.range(of: pattern, options: .regularExpression) else { return nil }
        let parts = words[match].replacingOccurrences(of: "in ", with: "")
        let amountText = parts.prefix { $0.isNumber || $0 == "." || $0 == "a" || $0 == "n" }
        let unit = parts.dropFirst(amountText.count).trimmingCharacters(in: .whitespaces)
        let amount = Double(amountText) ?? 1
        switch unit.first {
        case "m": return now.addingTimeInterval(amount * 60)
        case "h": return now.addingTimeInterval(amount * 3_600)
        case "d", "w":
            let days = Int((unit.first == "w" ? amount * 7 : amount).rounded())
            guard let day = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now)) else { return nil }
            return calendar.date(bySettingHour: morningHour, minute: 0, second: 0, of: day)
        default: return nil
        }
    }

    // MARK: Three fixed words

    private static func fixedWord(_ words: String, now: Date, calendar: Calendar) -> Date? {
        switch words {
        case "noon":
            let today = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: now) ?? now
            return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today)
        case "next week":
            return MailTimePresets.nextMonday(after: now, calendar: calendar)
        case "weekend", "this weekend":
            return MailTimePresets.weekend(after: now, calendar: calendar)
        default:
            return nil
        }
    }

    // MARK: Everything else is the event reader's

    private static let weekdayPattern = "(?:mon|tue|wed|thu|fri|sat|sun)[a-z]*"

    private static func detected(_ words: String, now: Date, calendar: Calendar) -> Date? {
        // "monday 9" is a day and an hour; read as written the detector says the ninth of a month.
        var rest = " " + words.replacingOccurrences(
            of: "^(\(weekdayPattern)) (\\d{1,2}(?::\\d\\d)?)$", with: "$1 at $2", options: .regularExpression) + " "
        guard let found = EventPhrase.takeDate(&rest, now: now, calendar: calendar) else { return nil }
        // Words left over that are not joining words mean this was not about a time.
        let left = rest.replacingOccurrences(of: #"\b(at|on|by|the|of)\b"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
        guard left.isEmpty else { return nil }
        guard !found.hasTime else { return found.date }
        // A day with no time of day: that day, in the morning.
        return calendar.date(bySettingHour: morningHour, minute: 0, second: 0, of: found.date)
    }
}

#endif
