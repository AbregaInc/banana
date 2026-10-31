import Foundation

/// A date written in plain words — "tomorrow", "next friday", "oct 12", "12/3" — for the ⌘K menu's
/// "Go to …". Foundation's date detector does the reading; this keeps only answers that are the
/// whole query (so "share availability" is not read as a date) and returns the start of that day.
enum CommandMenuDateParser {
    static func date(in query: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        else { return nil }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = detector.firstMatch(in: trimmed, options: [], range: range),
              let date = match.date,
              // Most of the query must be the date, not a command that happens to contain one.
              Double(match.range.length) >= Double(range.length) * 0.6
        else { return nil }
        return calendar.startOfDay(for: date)
    }
}
