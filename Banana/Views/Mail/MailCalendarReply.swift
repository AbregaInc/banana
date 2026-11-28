#if BANANA_AI && !BANANA_PUBLIC
import Foundation

/// A reply may disclose a single availability bit for a precisely named slot.
/// No event titles, attendees or model-generated calendar arguments enter the reply.
enum MailCalendarReply {
    struct Slot {
        let start: Date
        let end: Date
        let label: String
    }

    static func slot(in text: String) -> Slot? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A short statement introducing a scheduling proposal can precede the question.
        // Do not drop other requests or corrections from a multi-purpose message.
        let introduction = #"^(?:I(?: am|['’]m)|we(?: are|['’]re)) (?:comparing|considering|looking at) (?:times|options|dates)(?: for (?:the |our |a )?[\p{L} -]{1,80})?\.\s+"#
        if !text.contains("\n"), let range = text.range(of: introduction, options: [.regularExpression, .caseInsensitive]),
           !text[range].contains("\n") {
            text.removeSubrange(range)
        }
        // A disclaimer that only availability is sought does not authorize booking.
        let qualifier = #"(?<=\?)\s+(?:(?:please )?(?:leave (?:it|this) unbooked|do not book (?:it|this))|(?:I(?: am|['’]m)|we(?: are|['’]re)) (?:only|just) checking availability|a yes or no is (?:fine|enough|plenty)(?: if your calendar covers it)?)\.?$"#
        text = text.replacingOccurrences(of: qualifier, with: "", options: [.regularExpression, .caseInsensitive])
        guard text.count <= 2400, !text.contains("\n"), text.last == "?",
              text.filter({ $0 == "?" }).count == 1 else { return nil }
        // Limit the direct response to a single availability question. Mixed requests
        // (book it, send an attachment, suggest another time) need owner review.
        let event = #"(?:the |our |a )[\p{L} -]{1,80}"#
        let question = #"^(?:(?:are you (?:free|available|busy)|is your (?:calendar|schedule) (?:clear|open|busy)|(?:can|could|would) you check your (?:availability|calendar))\s+(?:for "# + event + #" on\s+|on\s+|from\s+)?|(?:would|does|will) "# + event + #" (?:conflict with|overlap) (?:anything|something) on your (?:calendar|schedule) on\s+)"#
        guard let opening = text.range(of: question, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let prefix = String(text[opening])
        guard prefix.range(of: #"\b(?:and|or|unless|instead|book|confirm|send|cancel|reschedule)\b"#,
                           options: [.regularExpression, .caseInsensitive]) == nil else { return nil }
        let raw = String(text[opening.upperBound..<text.index(before: text.endIndex)])
        let stamp = #"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:Z|[+-]\d{2}:\d{2}))"#
        if let fields = captures("^" + stamp + #"\s+(?:to|until|–)\s+"# + stamp + "$", raw),
           let start = AssistantFreeTime.absoluteTime(fields[0]), let end = AssistantFreeTime.absoluteTime(fields[1]), end > start {
            return Slot(start: start, end: end, label: raw)
        }
        let date = #"(?:(Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday),\s+)?([A-Za-z]+) (\d{1,2}), (\d{4}),?\s+(?:from\s+)?"#
        let time = #"(\d{1,2}):(\d{2})\s*(AM|PM)"#
        guard let f = captures("^" + date + time + #"\s+(?:to|until|–)\s+"# + time + #"\s+([A-Za-z_/ -]+?)(?: time)?$"#, raw),
              let zone = timeZone(f[10]), let day = Int(f[2]), let year = Int(f[3]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = zone
        guard let month = calendar.monthSymbols.firstIndex(where: { $0.caseInsensitiveCompare(f[1]) == .orderedSame }) else { return nil }
        func instant(_ i: Int) -> Date? {
            guard let hour = Int(f[i]), (1...12).contains(hour), let minute = Int(f[i+1]), minute < 60 else { return nil }
            let parts = DateComponents(year: year, month: month + 1, day: day,
                                       hour: hour % 12 + (f[i+2].uppercased() == "PM" ? 12 : 0), minute: minute, second: 0)
            guard let approximate = calendar.date(from: parts) else { return nil }
            let before = approximate.addingTimeInterval(-86400)
            guard let first = calendar.nextDate(after: before, matching: parts, matchingPolicy: .strict, repeatedTimePolicy: .first),
                  first == calendar.nextDate(after: before, matching: parts, matchingPolicy: .strict, repeatedTimePolicy: .last),
                  f[0].isEmpty || calendar.weekdaySymbols[calendar.component(.weekday, from: first)-1].caseInsensitiveCompare(f[0]) == .orderedSame else { return nil }
            return first
        }
        guard let start = instant(4), let end = instant(7), start < end else { return nil }
        return Slot(start: start, end: end, label: raw)
    }

    private static func captures(_ pattern: String, _ value: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        return (1..<match.numberOfRanges).map { Range(match.range(at: $0), in: value).map { String(value[$0]) } ?? "" }
    }

    private static func timeZone(_ name: String) -> TimeZone? {
        if name.uppercased() == "UTC" || name.uppercased() == "GMT" { return TimeZone(secondsFromGMT: 0) }
        let key = name.replacingOccurrences(of: " ", with: "_").lowercased()
        if name.contains("/") { return TimeZone(identifier: name) }
        let matches = TimeZone.knownTimeZoneIdentifiers.filter {
            $0.lowercased() == key || $0.split(separator: "/").last?.lowercased() == key
        }
        if !matches.isEmpty { return matches.count == 1 ? TimeZone(identifier: matches[0]) : nil }
        // Foundation enumerates some cities under an older spelling but resolves
        // their current IANA identifier. Ask the same database to resolve aliases.
        let city = name.capitalized(with: Locale(identifier: "en_US_POSIX")).replacingOccurrences(of: " ", with: "_")
        let regions = Set(TimeZone.knownTimeZoneIdentifiers.compactMap { id -> String? in
            guard let slash = id.firstIndex(of: "/") else { return nil }
            return String(id[..<slash])
        })
        let aliases = regions.compactMap { TimeZone(identifier: $0 + "/" + city) }
        return aliases.count == 1 ? aliases[0] : nil
    }
}
#endif
