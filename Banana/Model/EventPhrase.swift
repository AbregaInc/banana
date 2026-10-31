import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// "Lunch with Sam tomorrow at 1 at Balthazar, every Friday" → an event's title, time, place and
/// repeat, for the new-event form to fill in and the person to check before saving.
///
/// The dates are always worked out here, from the words, by the system's own date reading
/// (`NSDataDetector`) — never by a model, which is good at telling which words are which and
/// unreliable at calendar arithmetic. When Apple Intelligence is here, the model only says which
/// words are the title, the when, the place and the repeat (`read`); anything it says that isn't in
/// the words is ignored.
enum EventPhrase {
    struct Draft: Equatable, Sendable {
        var title: String
        var start: Date?
        var end: Date?
        var isAllDay = false
        var location: String?
        /// Nil when the words don't say it repeats.
        var recurrence: EventRecurrence?
        /// Who it's with, as typed — "Sam", "ana@…" — for the form to match to people
        /// (`GuestDirectory`). The title keeps them: "Lunch with Sam" is still what it is.
        var guests: [String] = []

        /// Anything beyond a title: worth offering to fill the form in from.
        var saysMore: Bool { start != nil || location != nil || recurrence != nil || !guests.isEmpty }
    }

    // MARK: - Reading the words (pure, apart from the system's date reading)

    static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current,
                      defaultDuration: TimeInterval = 3_600) -> Draft {
        let guests = GuestDirectory.names(in: text) + GuestDirectory.emails(in: text)
        var rest = " " + text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression) + " "

        let recurrence = takeRecurrence(&rest)
        let duration = takeDuration(&rest)
        var start: Date?
        var end: Date?
        var isAllDay = false
        if let found = takeDate(&rest, now: now, calendar: calendar) {
            isAllDay = !found.hasTime
            start = isAllDay ? calendar.startOfDay(for: found.date) : found.date
            if isAllDay {
                end = calendar.date(byAdding: .day, value: 1, to: start!)
            } else {
                end = start!.addingTimeInterval(found.duration ?? duration ?? defaultDuration)
            }
        } else if recurrence != nil {
            // "Standup every weekday" with no time: the repeat is still worth filling in.
            start = nil
        }
        // "Every Tuesday and Thursday at 7": it starts on the first of those days, not today.
        if let begin = start, let shifted = recurrence?.repeatValue?.alignedStart(begin) {
            end = end.map { $0.addingTimeInterval(shifted.timeIntervalSince(begin)) }
            start = shifted
        }
        // An address is a guest, not part of the title.
        for email in GuestDirectory.emails(in: rest) {
            rest = rest.replacingOccurrences(of: email, with: " ", options: .caseInsensitive)
        }
        let location = takeLocation(&rest)
        return Draft(title: tidyTitle(rest), start: start, end: end, isAllDay: isAllDay,
                     location: location, recurrence: recurrence, guests: guests)
    }

    // MARK: Repeat

    private static let weekdayWords: [(pattern: String, day: EventRepeat.Weekday)] = [
        ("mon(?:day)?s?", .monday), ("tue(?:s|sday)?s?", .tuesday), ("wed(?:nesday)?s?", .wednesday),
        ("thu(?:rs?|rsday)?s?", .thursday), ("fri(?:day)?s?", .friday), ("sat(?:urday)?s?", .saturday),
        ("sun(?:day)?s?", .sunday),
    ]

    private static var weekdayAlternation: String { weekdayWords.map(\.pattern).joined(separator: "|") }

    /// "every Tuesday and Thursday", "every other week", "weekdays", "daily", "on Mondays".
    static func takeRecurrence(_ text: inout String) -> EventRecurrence? {
        let days = "(?:\(weekdayAlternation))"
        let list = "\(days)(?:\\s*(?:,|and|&|\\+)\\s*\(days))*"
        let rules: [(String, (String) -> EventRecurrence?)] = [
            (#"\b(?:every|each) ?(?:week ?day|workday)s?\b|\bon weekdays\b|\bweekdays\b"#, { _ in
                .rule(EventRepeat(frequency: .weekly, weekdays: EventRepeat.Weekday.workdays)) }),
            ("\\b(?:every|each)\\s+(?:other\\s+)?\(list)\\b", { match in
                let days = weekdays(in: match)
                guard !days.isEmpty else { return nil }
                return .rule(EventRepeat(frequency: .weekly, interval: match.contains("other") ? 2 : 1, weekdays: days)) }),
            // "on Tuesdays", "Mondays and Wednesdays": a plural day is a habit.
            ("\\b(?:on\\s+)?(?:mondays|tuesdays|wednesdays|thursdays|fridays|saturdays|sundays)(?:\\s*(?:,|and|&)\\s*\(days))*\\b", { match in
                let days = weekdays(in: match)
                return days.isEmpty ? nil : .rule(EventRepeat(frequency: .weekly, weekdays: days)) }),
            (#"\b(?:every|each) ?day\b|\bdaily\b"#, { _ in .rule(EventRepeat(frequency: .daily)) }),
            (#"\b(?:every|each) other week\b|\bbiweekly\b|\bfortnightly\b"#, { _ in
                .rule(EventRepeat(frequency: .weekly, interval: 2)) }),
            (#"\b(?:every|each) week\b|\bweekly\b"#, { _ in .rule(EventRepeat(frequency: .weekly)) }),
            (#"\b(?:every|each) month\b|\bmonthly\b"#, { _ in .rule(EventRepeat(frequency: .monthly)) }),
            (#"\b(?:every|each) year\b|\byearly\b|\bannually\b"#, { _ in .rule(EventRepeat(frequency: .yearly)) }),
        ]
        for (pattern, make) in rules {
            guard let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]),
                  let recurrence = make(String(text[range]).lowercased()) else { continue }
            text.replaceSubrange(range, with: " ")
            return recurrence
        }
        return nil
    }

    private static func weekdays(in text: String) -> Set<EventRepeat.Weekday> {
        var found = Set<EventRepeat.Weekday>()
        for word in text.components(separatedBy: CharacterSet.letters.inverted) where !word.isEmpty {
            for (pattern, day) in weekdayWords where word.range(of: "^\(pattern)$", options: [.regularExpression, .caseInsensitive]) != nil {
                found.insert(day)
            }
        }
        return found
    }

    // MARK: Length

    /// "for an hour", "for 45 min", "for 1.5 hours", "for half an hour", "for an hour and a half".
    static func takeDuration(_ text: inout String) -> TimeInterval? {
        let pattern = #"\bfor (an?|one|half an?|\d+(?:\.\d+)?) ?(hours?|hrs?|h|minutes?|mins?|m)( and a half)?\b"#
        guard let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let words = text[range].lowercased().split(separator: " ").map(String.init)
        guard words.count >= 2 else { return nil }
        let amountWord = words[1] == "half" ? "0.5" : words[1]
        let amount = ["a": 1, "an": 1, "one": 1][amountWord].map(Double.init) ?? Double(amountWord) ?? 1
        let unitWord = words.first { $0.hasPrefix("h") || $0.hasPrefix("m") } ?? "hour"
        var seconds = amount * (unitWord.hasPrefix("h") ? 3_600 : 60)
        if text[range].lowercased().hasSuffix("and a half") { seconds += unitWord.hasPrefix("h") ? 1_800 : 30 }
        text.replaceSubrange(range, with: " ")
        return seconds > 0 ? seconds : nil
    }

    // MARK: When

    /// Made once: the form reads the title on every keystroke.
    nonisolated(unsafe) private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)

    struct FoundDate {
        var date: Date
        var duration: TimeInterval?
        var hasTime: Bool
    }

    /// The when, by the system's date reading. "at 1" with no am or pm is in the afternoon when that
    /// reads as a waking hour; a time already gone today with no day said is tomorrow.
    static func takeDate(_ text: inout String, now: Date, calendar: Calendar) -> FoundDate? {
        guard let detector else { return nil }
        let ns = text as NSString
        guard let match = detector.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .max(by: { $0.range.length < $1.range.length }),
              var date = match.date, let range = Range(match.range, in: text) else { return nil }
        let words = text[range].lowercased()
        let hasTime = words.range(of: #"\d\s*(a\.?m\.?|p\.?m\.?)\b|\d:\d\d|\bnoon\b|\bmidnight\b|o'?clock|\btonight\b|\bmorning\b|\bafternoon\b|\bevening\b|\bat \d"#,
                                  options: .regularExpression) != nil
        let saysMeridiem = words.range(of: #"(a\.?m\.?|p\.?m\.?)\b|morning|noon|midnight"#, options: .regularExpression) != nil
        if hasTime, !saysMeridiem, (1...6).contains(calendar.component(.hour, from: date)) {
            date = date.addingTimeInterval(12 * 3_600)
        }
        let saysDay = words.range(of: #"today|tonight|tomorrow|mon|tue|wed|thu|fri|sat|sun|jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec|\d+/\d+|\d+(st|nd|rd|th)|next|this"#,
                                  options: .regularExpression) != nil
        if hasTime, !saysDay, date < now {
            date = calendar.date(byAdding: .day, value: 1, to: date) ?? date
        }
        text.replaceSubrange(range, with: " ")
        return FoundDate(date: date, duration: match.duration > 0 ? match.duration : nil, hasTime: hasTime)
    }

    // MARK: Where

    /// What follows the last " at " or " @ " — "Balthazar", "the office" — once the when is out.
    static func takeLocation(_ text: inout String) -> String? {
        guard let range = text.range(of: #"\s(?:at|@)\s+([^,;]+?)\s*$"#, options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        var place = String(text[range])
        // "at  at Equinox", when the time's own "at" was left behind: every one goes.
        place = place.replacingOccurrences(of: #"^\s*(?:(?:at|@)\s+)+"#, with: "", options: [.regularExpression, .caseInsensitive])
        place = place.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !place.isEmpty, place.first?.isNumber == false else { return nil }
        text.replaceSubrange(range, with: " ")
        return place
    }

    // MARK: Title

    static func tidyTitle(_ text: String) -> String {
        var title = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let connectors = #"^(?:(?:on|at|from|for|this|next|in|by|,|-|–)\s*)+|(?:\s*(?:on|at|from|for|this|next|in|by|,|-|–))+$"#
        title = title.replacingOccurrences(of: connectors, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard let first = title.first else { return "" }
        return first.uppercased() + title.dropFirst()
    }

    // MARK: - With the model

    /// The words read as well as Banana can: the model says which are which, when there is one;
    /// the dates are always read here. Whatever the model can't do, or says that isn't in the
    /// words, falls back to `parse`.
    @MainActor
    static func read(_ text: String, now: Date = Date(), defaultDuration: TimeInterval = 3_600) async -> Draft {
        let plain = parse(text, now: now, defaultDuration: defaultDuration)
        #if canImport(FoundationModels)
        guard #available(iOS 26, macOS 26, *) else { return plain }
        let availability = Intelligence.current
        guard Intelligence.route(.knowledge, given: availability) != .none,
              let (session, chosen) = Intelligence.session(for: .knowledge, instructions: instructions,
                                                           availability: availability) else { return plain }
        do {
            let parts: GeneratedEventParts = try await Intelligence.withTimeout(seconds: chosen == .cloud ? 20 : 10, route: chosen) {
                try await session.respond(to: text, generating: GeneratedEventParts.self,
                                          options: .init(temperature: 0)).content
            }
            return merged(plain, with: parts.parts, text: text, now: now, defaultDuration: defaultDuration)
        } catch {
            return plain
        }
        #else
        return plain
        #endif
    }

    /// What the model said each part is, before it's checked against the words.
    struct ModelParts: Equatable, Sendable {
        var title: String
        var when: String
        var place: String
        var durationMinutes: Int
        var repeats: String
        var repeatDays: [String]
        var guests: [String] = []
    }

    /// The model's reading over the plain one, part by part, only where it holds up: a title or
    /// place made of the person's own words, a when the date reading can read.
    static func merged(_ plain: Draft, with parts: ModelParts, text: String, now: Date = Date(),
                       calendar: Calendar = .current, defaultDuration: TimeInterval = 3_600) -> Draft {
        var draft = plain
        let said = Set(GroundedFoodEstimate.words(text))
        func ownWords(_ value: String) -> Bool {
            let words = GroundedFoodEstimate.words(value)
            return !words.isEmpty && words.isSubset(of: said)
        }
        let title = tidyTitle(parts.title)
        if ownWords(title) { draft.title = title }
        let place = parts.place.trimmingCharacters(in: .whitespacesAndNewlines)
        if !place.isEmpty, ownWords(place) { draft.location = place }
        if !parts.when.isEmpty {
            var when = " " + parts.when + " "
            if let found = takeDate(&when, now: now, calendar: calendar) {
                draft.isAllDay = !found.hasTime
                let start = draft.isAllDay ? calendar.startOfDay(for: found.date) : found.date
                draft.start = start
                let length = found.duration ?? (parts.durationMinutes > 0 ? TimeInterval(parts.durationMinutes * 60) : nil)
                draft.end = draft.isAllDay ? calendar.date(byAdding: .day, value: 1, to: start)
                    : start.addingTimeInterval(length ?? plain.end.map { $0.timeIntervalSince(plain.start ?? $0) } ?? defaultDuration)
            }
        }
        // People the plain reading missed — "dinner jess friday", no "with" — when they're words said.
        let named = parts.guests.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && ($0.contains("@") || ownWords($0)) }
        if draft.guests.isEmpty, !named.isEmpty { draft.guests = named }
        if draft.recurrence == nil {
            var words = " \(parts.repeats) \(parts.repeatDays.joined(separator: " and ")) "
            if parts.repeats.lowercased() == "weekly", !parts.repeatDays.isEmpty { words = " every \(parts.repeatDays.joined(separator: " and ")) " }
            draft.recurrence = takeRecurrence(&words)
        }
        return draft
    }

    static let instructions = """
    You split a short note about a calendar event into its parts. Copy words from the note; never \
    add facts it doesn't say. title: what the event is, without the time, place or repeat \
    ("Lunch with Sam"). when: the exact words that say the day and time ("tomorrow at 1pm", \
    "Friday 3-4pm"), or empty. place: the place, if one is named, or empty. durationMinutes: only \
    if the note says how long, else 0. repeats: none, daily, weekdays, weekly, monthly or yearly. \
    repeatDays: the weekdays it repeats on, if it says. guests: the people it's with, by the \
    names or addresses the note uses, or empty.
    """

    // MARK: - For the form

    /// "Sat, Oct 4 · 1:00–2:00 PM · Balthazar · Weekly on Fri" — what filling in would set.
    static func preview(_ draft: Draft, calendar: Calendar = .current) -> String {
        var parts: [String] = []
        if let start = draft.start {
            let day = start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
            if draft.isAllDay {
                parts.append("\(day), all day")
            } else if let end = draft.end {
                parts.append("\(day) \u{00B7} \(TimeRangeText.compact(start, end))")
            } else {
                parts.append("\(day) \u{00B7} \(start.formatted(date: .omitted, time: .shortened))")
            }
        }
        if let location = draft.location { parts.append(location) }
        if let repeatValue = draft.recurrence?.repeatValue { parts.append(repeatText(repeatValue, calendar: calendar)) }
        if !draft.guests.isEmpty { parts.append("With " + draft.guests.joined(separator: ", ")) }
        return parts.joined(separator: " \u{00B7} ")
    }

    static func repeatText(_ value: EventRepeat, calendar: Calendar = .current) -> String {
        switch value.frequency {
        case .daily: return "Daily"
        case .monthly: return "Monthly"
        case .yearly: return "Yearly"
        case .weekly:
            if value.weekdays == EventRepeat.Weekday.workdays { return "Weekdays" }
            let every = value.interval == 2 ? "Every other week" : "Weekly"
            guard !value.weekdays.isEmpty else { return every }
            let names = EventRepeat.Weekday.ruleOrder(value.weekdays).map { calendar.shortWeekdaySymbols[$0.rawValue - 1] }
            return "\(every) on \(names.joined(separator: ", "))"
        }
    }
}

#if canImport(FoundationModels)
@available(iOS 26, macOS 26, *)
@Generable
struct GeneratedEventParts {
    @Guide(description: "What the event is, without the time, place or repeat, e.g. 'Lunch with Sam'")
    var title: String
    @Guide(description: "The exact words that say the day and time, e.g. 'tomorrow at 1pm', or empty")
    var when: String
    @Guide(description: "The place, if the note names one, or empty")
    var place: String
    @Guide(description: "How long, in minutes, only if the note says; otherwise 0")
    var durationMinutes: Int
    @Guide(description: "none, daily, weekdays, weekly, monthly or yearly")
    var repeats: String
    @Guide(description: "Weekdays it repeats on, if the note says, e.g. ['Tuesday', 'Thursday']")
    var repeatDays: [String]
    @Guide(description: "The people it's with, by the names or email addresses the note uses, e.g. ['Sam', 'Ana Lee']")
    var guests: [String]

    var parts: EventPhrase.ModelParts {
        .init(title: title, when: when, place: place, durationMinutes: durationMinutes, repeats: repeats,
              repeatDays: repeatDays, guests: guests)
    }
}
#endif
