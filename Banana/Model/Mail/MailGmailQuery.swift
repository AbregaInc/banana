#if !BANANA_PUBLIC
import Foundation

/// A search as Gmail's `q` (MAIL-ENGINE 9.4). Typed text goes to Gmail as typed: Gmail reads its
/// own operators. A structured filter (`banana-filter:`) is translated term by term, and the
/// list's filters add Gmail's `is:` operators. Nil: Gmail is not asked — fewer than two
/// characters, nothing to search for but flags, or a filter that cannot run.
enum MailGmailQuery {
    static func translate(_ text: String, filters: Set<MailFilter>, now: Date = Date(),
                          calendar: Calendar = .current) -> String? {
        var parts: [String] = []
        var searchable = false
        if let filter = LiveFilter.fromSearchExpression(text, scope: "mail") {
            guard filter.canRun else { return nil }
            for term in filter.terms {
                switch term.field {
                case "text":
                    let words = term.value.split(whereSeparator: \.isWhitespace).compactMap { word(String($0)) }
                    parts += words; searchable = searchable || !words.isEmpty
                case "person":
                    guard let value = phrase(term.value) else { continue }
                    parts.append("from:" + value); searchable = true
                case "unread": parts.append(term.value == "true" ? "is:unread" : "-is:unread")
                case "starred": parts.append(term.value == "true" ? "is:starred" : "-is:starred")
                case "important": parts.append(term.value == "true" ? "is:important" : "-is:important")
                default: break
                }
            }
            if let interval = filter.interval(now: now, calendar: calendar) {
                // Epoch seconds: Gmail reads bare dates as midnight Pacific (DOCUMENTED §11).
                parts.append("after:\(Int64(interval.start.timeIntervalSince1970) - 1)")
                parts.append("before:\(Int64(interval.end.timeIntervalSince1970))")
                searchable = true
            }
        } else {
            let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard typed.count >= 2, typed.count <= 1_500 else { return nil }
            parts.append(typed); searchable = true
        }
        guard searchable else { return nil }
        for (filter, op) in [(MailFilter.unread, "is:unread"), (.starred, "is:starred"), (.important, "is:important")]
        where filters.contains(filter) && !parts.contains(op) {
            parts.append(op)
        }
        // `.noReply` has no Gmail operator: its rows are filtered on the device.
        return parts.joined(separator: " ")
    }

    /// One word of a structured filter's text. A Gmail operator as typed (`has:attachment`,
    /// `-in:chats`) goes as typed; anything else is a word: quotes, brackets and a leading minus
    /// are dropped, and a word with a colon is quoted.
    static func word(_ raw: String) -> String? {
        if raw.range(of: #"^-?[a-z_]+:[^\s"(){}]+$"#, options: .regularExpression) != nil { return raw }
        var value = raw.filter { !"\"(){}".contains($0) }
        while value.hasPrefix("-") { value.removeFirst() }
        guard !value.isEmpty else { return nil }
        return value.contains(":") ? "\"" + value + "\"" : value
    }

    /// A value that may hold spaces, as one Gmail term.
    static func phrase(_ raw: String) -> String? {
        let value = raw.filter { !"\"(){}".contains($0) }.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let plain = value.allSatisfy { $0.isLetter || $0.isNumber || "@._+".contains($0) }
        return plain ? value : "\"" + value + "\""
    }
}

#endif
