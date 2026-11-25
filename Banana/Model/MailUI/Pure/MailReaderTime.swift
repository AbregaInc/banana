#if !BANANA_PUBLIC
import Foundation

/// A reader annotation derived from a dated time with an explicit zone in the message itself.
enum MailReaderTime {
    struct Note: Equatable, Sendable {
        var end: Int
        var date: Date
        var sourceZone: TimeZone
    }

    private static let time = #"(?<![\w:])(?<hour>\d{1,2})(?::(?<minute>\d{2}))?\s*(?<period>[ap]m)?\s*(?<zone>ET|CT|MT|PT|(?:UTC|GMT)(?:[+-]\d{1,2}(?::[0-5]\d)?)?)(?![\w:+-])"#
    private static let day = #"(?:(?<weekday>Mon(?:day)?|Tue(?:sday)?|Wed(?:nesday)?|Thu(?:rsday)?|Fri(?:day)?|Sat(?:urday)?|Sun(?:day)?),?\s+)?(?<month>Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:tember)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\.?\s+(?<day>\d{1,2})(?:,?\s+(?<year>\d{4}))?\b"#
    private static let patterns = [time + #"\s+(?:on\s+)?"# + day, #"(?<!\w)"# + day + #"\s+(?:at\s+)?"# + time]
        .compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
    private static let months = ["jan","feb","mar","apr","may","jun","jul","aug","sep","oct","nov","dec"]
    private static let weekdays = ["sun","mon","tue","wed","thu","fri","sat"]
    private static let zones = ["ET":"America/New_York","CT":"America/Chicago","MT":"America/Denver","PT":"America/Los_Angeles"]
    private static let recurrence = try? NSRegularExpression(pattern: #"\b(?:every|weekly|daily|recurring|each)\b"#, options: .caseInsensitive)

    static func notes(in text: String, sent: Date) -> [Note] {
        guard text.utf8.count <= 4_096, text.contains(where: \.isNumber) else { return [] }
        let whole = NSRange(text.startIndex..<text.endIndex, in: text)
        guard recurrence?.firstMatch(in: text, range: whole) == nil else { return [] }
        return Array(patterns.flatMap { $0.matches(in: text, range: whole) }.compactMap { match -> Note? in
            func field(_ name: String) -> String? {
                Range(match.range(withName: name), in: text).map { String(text[$0]).lowercased() }
            }
            guard let range = Range(match.range, in: text),
                  let month = field("month").flatMap({ months.firstIndex(of: String($0.prefix(3))) }),
                  let day = field("day").flatMap(Int.init), (1...31).contains(day),
                  var hour = field("hour").flatMap(Int.init),
                  let zone = field("zone").flatMap(zone) else { return nil }
            let minute = field("minute").flatMap(Int.init) ?? 0
            guard minute < 60 else { return nil }
            if let period = field("period") {
                guard (1...12).contains(hour) else { return nil }
                hour = hour % 12 + (period == "pm" ? 12 : 0)
            } else {
                guard field("minute") != nil, hour == 0 || (13...23).contains(hour) else { return nil }
            }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            let weekday = field("weekday").flatMap { weekdays.firstIndex(of: String($0.prefix(3))) }.map { $0 + 1 }
            let year = field("year").flatMap(Int.init)
            guard year != nil || weekday != nil else { return nil }
            let sentYear = calendar.component(.year, from: sent)
            let years = year.map { [$0] } ?? [sentYear - 1, sentYear, sentYear + 1]
            let candidates = years.compactMap { year -> Date? in
                let components = DateComponents(year: year, month: month + 1, day: day, hour: hour, minute: minute)
                guard let midnight = calendar.date(from: DateComponents(year: year, month: month + 1, day: day)),
                      weekday.map({ $0 == calendar.component(.weekday, from: midnight) }) ?? true,
                      let first = calendar.nextDate(after: midnight.addingTimeInterval(-1), matching: components,
                                                    matchingPolicy: .strict, repeatedTimePolicy: .first),
                      first == calendar.nextDate(after: midnight.addingTimeInterval(-1), matching: components,
                                                 matchingPolicy: .strict, repeatedTimePolicy: .last),
                      field("year") != nil || abs(first.timeIntervalSince(sent)) <= 183 * 86_400 else { return nil }
                return first
            }
            guard candidates.count == 1, let date = candidates.first else { return nil }
            return Note(end: text.distance(from: text.startIndex, to: range.upperBound), date: date, sourceZone: zone)
        }.sorted { $0.end < $1.end }.prefix(4))
    }

    private static func zone(_ name: String) -> TimeZone? {
        if let id = zones[name.uppercased()] { return TimeZone(identifier: id) }
        let offset = name.dropFirst(3)
        guard let sign = offset.first else { return TimeZone(secondsFromGMT: 0) }
        let parts = offset.dropFirst().split(separator: ":")
        guard let hours = parts.first.flatMap({ Int($0) }), hours <= 14 else { return nil }
        let minutes = parts.count == 2 ? Int(parts[1]) ?? 0 : 0
        guard hours < 14 || minutes == 0 else { return nil }
        return TimeZone(secondsFromGMT: (sign == "-" ? -1 : 1) * (hours * 3600 + minutes * 60))
    }
}
#endif
