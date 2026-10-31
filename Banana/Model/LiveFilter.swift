import Foundation

/// Versioned query meaning shared by the Apple clients and web. Interpretation never executes
/// query fragments: each adapter accepts only fields it supports and binds values as parameters.
struct LiveFilter: Codable, Hashable, Sendable {
    struct Term: Codable, Hashable, Identifiable, Sendable {
        var field: String
        var op: String
        var value: String
        var label: String? = nil
        var id: String { field + ":" + op + ":" + value }
        var title: String {
            let name = ["date":"Date", "calendar":"Calendar", "text":"Text", "person":"Person", "kind":"Type", "status":"Status", "duration":"Minutes", "archived":"Archive", "unread":"Read state", "starred":"Star", "important":"Important", "allDay":"All day"][field] ?? field
            let display = label ?? ["today":"Today", "yesterday":"Yesterday", "tomorrow":"Tomorrow", "thisWeek":"This week", "nextWeek":"Next week", "lastWeek":"Last week", "thisMonth":"This month", "lastMonth":"Last month", "7days":"Last 7 days", "30days":"Last 30 days"][value] ?? value
            let bool = field == "archived" ? (value == "true" ? "Archived" : "Unarchived") : field == "unread" ? (value == "true" ? "Unread" : "Read") : value
            let shown = ["archived", "unread"].contains(field) ? bool : display
            return name + ": " + (op == "not" ? "Not " : op == "gt" ? "Over " : op == "lt" ? "Under " : "") + shown
        }
    }
    var version = 1
    var scope: String
    var terms: [Term] = []
    var firstWeekday: Int? = nil
    // Clarifications are ephemeral, never persisted as an executable query.
    var issues: [String] = []
    var text: String { terms.filter { $0.field == "text" }.map(\.value).joined(separator: " ") }
    func value(_ field: String) -> String? { terms.first { $0.field == field }?.value }
    var isEmpty: Bool { terms.isEmpty && issues.isEmpty }
    var canRun: Bool {
        let fields: Set<String> = ["plan": ["text", "date", "calendar", "status", "allDay", "kind", "person"], "mail": ["text", "date", "person", "unread", "starred", "important"], "notes": ["text", "date", "archived"], "workouts": ["text", "date", "kind", "duration"]][scope] ?? []
        let dates: Set<String> = ["today", "tomorrow", "yesterday", "thisWeek", "nextWeek", "lastWeek", "thisMonth", "lastMonth", "7days", "30days"]
        return version == 1 && !fields.isEmpty && (firstWeekday == nil || (1...7).contains(firstWeekday!)) && Set(terms.map(\.id)).count == terms.count && issues.isEmpty && terms.allSatisfy { term in
            guard fields.contains(term.field), !term.value.isEmpty else { return false }
            switch term.field {
            case "date": return term.op == "in" && dates.contains(term.value)
            case "text", "person": return term.op == "contains"
            case "duration": return ["gt", "lt"].contains(term.op) && Double(term.value).map { $0 >= 0 && $0.isFinite } == true
            case "calendar": return ["is", "not"].contains(term.op)
            case "status": return ["is", "not"].contains(term.op) && ["accepted", "tentative", "declined", "canceled"].contains(term.value) && !(term.op == "is" && term.value == "canceled")
            case "kind": return term.op == "is" && (scope == "plan" ? term.value == "meeting" : ["strength", "running", "walking", "cycling", "swimming", "yoga"].contains(term.value))
            case "archived", "unread", "starred", "important", "allDay": return term.op == "is" && ["true", "false"].contains(term.value)
            default: return term.op == "is"
            }
        }
    }

    func interval(now: Date = Date(), calendar: Calendar = .current) -> DateInterval? {
        guard let key = value("date") else { return nil }
        var calendar = calendar
        if let firstWeekday, (1...7).contains(firstWeekday) { calendar.firstWeekday = firstWeekday }
        let day = calendar.startOfDay(for: now)
        func add(_ component: Calendar.Component, _ n: Int, _ date: Date) -> Date { calendar.date(byAdding: component, value: n, to: date)! }
        switch key {
        case "today": return DateInterval(start: day, end: add(.day, 1, day))
        case "yesterday": return DateInterval(start: add(.day, -1, day), end: day)
        case "tomorrow": return DateInterval(start: add(.day, 1, day), end: add(.day, 2, day))
        case "7days", "30days": return DateInterval(start: add(.day, key == "7days" ? -6 : -29, day), end: add(.day, 1, day))
        default:
            let component: Calendar.Component = key.contains("Month") ? .month : .weekOfYear
            guard let current = calendar.dateInterval(of: component, for: now) else { return nil }
            let offset = key.hasPrefix("next") ? 1 : key.hasPrefix("last") ? -1 : 0
            return DateInterval(start: add(component, offset, current.start), end: add(component, offset, current.end))
        }
    }
    /// Prepare validation, date boundaries and aliases once for a result set, not once per row.
    func predicate(now: Date = Date(), calendar: Calendar = .current) -> @Sendable (Date, String, String?, Double?) -> Bool {
        let valid = canRun, range = interval(now: now, calendar: calendar), conditions = terms
        let aliases = ["strength":["strength", "weight", "resistance"], "running":["running", "run"], "walking":["walking", "walk"], "cycling":["cycling", "bike", "biking"], "swimming":["swimming", "swim"]]
        return { date, text, kind, duration in
            guard valid else { return false }
            if let range, !(date >= range.start && date < range.end) { return false }
            return conditions.allSatisfy { term in
                switch term.field {
                case "text": return (text as NSString).localizedCaseInsensitiveContains(term.value)
                case "kind":
                    guard let kind else { return false }
                    return (aliases[term.value] ?? [term.value]).contains { kind.localizedCaseInsensitiveContains($0) }
                case "duration": guard let duration, let n = Double(term.value) else { return false }; return term.op == "gt" ? duration > n * 60 : duration < n * 60
                default: return true // Other fields are enforced by the scope's query adapter.
                }
            }
        }
    }
    func matches(date: Date, text: String, kind: String? = nil, duration: Double? = nil) -> Bool {
        predicate()(date, text, kind, duration)
    }

}

enum LiveFilterParser {
    struct Source: Hashable, Sendable { var id: String; var name: String }
    struct Rule: Decodable { var scopes: [String]; var pattern: String; var field: String; var op: String; var value: String }
    private static let rules: [(Rule, NSRegularExpression)] = {
        guard let url = Bundle.main.url(forResource: "LiveFilterRules", withExtension: "json"), let data = try? Data(contentsOf: url) else { return [] }
        return compile(data)
    }()
    static func compile(_ data: Data) -> [(Rule, NSRegularExpression)] {
        ((try? JSONDecoder().decode([Rule].self, from: data)) ?? []).compactMap { rule in
            (try? NSRegularExpression(pattern: rule.pattern, options: .caseInsensitive)).map { (rule, $0) }
        }
    }
    static func parse(_ sentence: String, scope: String, sources: [Source] = [], rules supplied: [(Rule, NSRegularExpression)]? = nil) -> LiveFilter {
        var result = LiveFilter(scope: scope)
        guard sentence.count <= 2000 else { result.issues = ["Use a shorter filter sentence (up to 2,000 characters). "]; return result }
        var rest = sentence
        func take(_ regex: NSRegularExpression, _ consume: (NSTextCheckingResult, NSString) -> Void) {
            let original = rest as NSString
            for match in regex.matches(in: rest, range: NSRange(location: 0, length: original.length)).reversed() {
                consume(match, original)
                rest = (rest as NSString).replacingCharacters(in: match.range, with: " ")
            }
        }
        // Quoted text is literal, even when it contains words such as "today" or "archived".
        take(try! NSRegularExpression(pattern: "\"([^\"]+)\"")) { m, s in result.terms.append(.init(field: "text", op: "contains", value: s.substring(with: m.range(at: 1)))) }
        if rest.range(of: #"\b(?:or|either)\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            result.issues.append("Use one set of conditions at a time; alternatives joined by ‘or’ are not supported yet.")
        }
        if scope == "plan" {
            let names = Dictionary(grouping: sources.filter { !$0.name.isEmpty }, by: { $0.name.lowercased() })
            for name in names.keys.sorted(by: { $0.count > $1.count }) {
                let pattern = #"(?<![\p{L}\p{N}])(?:(not|except|excluding)\s+)?(?:on\s+(?:the\s+)?)?"# + NSRegularExpression.escapedPattern(for: name) + #"(?:\s+calendar)?(?![\p{L}\p{N}])"#
                take(try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)) { m, s in
                    let options = names[name]!
                    guard options.count == 1 else { result.issues.append("Choose a calendar: ‘\(options[0].name)’ matches more than one account. Include its account in the calendar name."); return }
                    result.terms.append(.init(field: "calendar", op: m.range(at: 1).location == NSNotFound ? "is" : "not", value: options[0].id, label: options[0].name))
                }
            }
        }
        for (rule, regex) in supplied ?? rules where rule.scopes.contains(scope) {
            take(regex) { m, s in
                var value = rule.value
                if m.numberOfRanges > 1 { value = value.replacingOccurrences(of: "$1", with: s.substring(with: m.range(at: 1)).lowercased()) }
                if value == "cancelled" { value = "canceled" }
                result.terms.append(.init(field: rule.field, op: rule.op, value: value))
            }
        }
        if scope == "mail" || scope == "plan" {
            // A visible contains predicate, never a guess at a unique contact's identity.
            let pattern = #"\b(?:from|with)\s+([^,;]+?)(?=\s+(?:about|excluding|except)\b|[,;]|$)"#
            take(try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)) { m, s in
                let value = s.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { result.terms.append(.init(field: "person", op: "contains", value: value, label: "Containing “\(value)”")) }
            }
        }
        rest = rest.replacingOccurrences(of: #"\b(?:show me|show|my|all|emails?|notes?|workouts?|events?|about)\b"#, with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"[,;]\s*|\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { result.terms.append(.init(field: "text", op: "contains", value: rest)) }
        var seen = Set<String>()
        result.terms = result.terms.filter { seen.insert($0.id).inserted }
        for field in ["date", "archived", "unread", "starred", "kind"] where Set(result.terms.filter { $0.field == field }.map(\.value)).count > 1 {
            result.issues.append("Choose one \(field) condition.")
        }
        if result.terms.contains(where: { $0.field == "status" && $0.op == "is" && $0.value == "canceled" }) {
            result.issues.append("Canceled events are not available from calendar search. You can exclude canceled events instead.")
        }
        return result
    }
}

extension LiveFilter {
    /// MailPlace keeps its independent String query contract; this versioned grammar is decoded
    /// only at the adapter boundary. Invalid/future structured queries fail closed.
    var searchExpression: String {
        "banana-filter:" + ((try? JSONEncoder().encode(self).base64EncodedString()) ?? "invalid")
    }
    static func fromSearchExpression(_ text: String, scope: String) -> LiveFilter? {
        guard text.hasPrefix("banana-filter:") else { return nil }
        if let data = Data(base64Encoded: String(text.dropFirst("banana-filter:".count))),
           let filter = try? JSONDecoder().decode(LiveFilter.self, from: data), filter.version == 1, filter.scope == scope {
            return filter
        }
        return LiveFilter(scope: scope, issues: ["This filter version is not supported."])
    }
}
