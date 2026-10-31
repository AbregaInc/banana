import Foundation

/// Device-only flight extraction — no external flight API. Given a calendar event's raw text,
/// it decides whether the event is a flight and, if so, resolves origin/destination airports
/// from the bundled `AirportTable`. The arrival *time* is NOT here: it comes free from the
/// event's own `endDate`.
///
/// With every airport in the table, three capital letters are an airport more often than not
/// ("JAN", "SAT", "API"), so a code is only as good as what stands beside it. What counts:
///   - a route between two airports ("EWR → MIA", "EWR-MIA", "EWR to MIA", "(EWR) … (MIA)"):
///     3 between two large airports, 2 otherwise, and 1 when it reads as something else — a
///     month or a weekday on either side ("JAN-MAR", "SAT-SUN"), or everyday capitals on both
///     ("USA-CAN");
///   - a flight number with a real airline's code ("UA 857", "B6 123", "W6 2314"): 2;
///   - "to <city>" for a city with a large airport, said as a flight ("Flight to Miami"): 1;
///   - an airline's name, and the word flight (or ✈, or "Fly …"): 1 each;
///   - a video-call link as the location: −5.
/// Three or more, with a destination, is a flight. `FlightParserTests` holds the cases.
enum FlightParser {
    struct Result {
        var origin: Airport?
        var destination: Airport
        var confidence: Int
        var method: String   // "code-pair" | "city-name"
    }

    // MARK: - What is known

    /// Airline names as they're written in a calendar event, lowercased.
    private static let airlineWords = [
        "united ", "delta ", "american air", "jetblue", "alaska air", "southwest", "spirit air", "frontier air",
        "hawaiian air", "air canada", "westjet", "porter air", "lufthansa", "british airways", "air france", "klm",
        "iberia", "vueling", "ryanair", "easyjet", "wizz", "swiss air", "swiss int", "austrian air",
        "brussels airlines", "tap air", "aer lingus", "scandinavian air", "norwegian air", "finnair", "icelandair",
        "lot polish", "croatia airlines", "air serbia", "aegean", "turkish airlines", "pegasus air", "emirates",
        "etihad", "qatar", "saudia", "el al", "egyptair", "royal air maroc", "ethiopian air", "kenya airways",
        "south african air", "qantas", "virgin atlantic", "virgin australia", "air new zealand",
        "singapore airlines", "cathay", "all nippon", "japan airlines", "korean air", "asiana", "china eastern",
        "china southern", "air china", "hainan air", "eva air", "china airlines", "thai airways", "vietnam airlines",
        "malaysia airlines", "airasia", "garuda", "philippine airlines", "cebu pacific", "air india", "indigo",
        "latam", "avianca", "copa air", "aeromexico", "volaris", "azul", "gol ",
    ]

    /// Two-character IATA airline codes: what makes "UA 857" a flight number and "PR 12" not.
    /// A digit can be either character ("B6", "U2", "9W"), which a pattern of two letters missed.
    private static let airlineCodes: Set<String> = [
        // North America
        "AA", "UA", "DL", "B6", "WN", "AS", "NK", "F9", "HA", "G4", "SY", "MX", "XP", "AC", "WS", "PD", "TS", "F8",
        "AM", "Y4", "VB", "4O",
        // Europe
        "BA", "VS", "U2", "LS", "BY", "FR", "W6", "W4", "W9", "LH", "LX", "OS", "SN", "EW", "4U", "DE", "X3", "AF",
        "KL", "HV", "TO", "IB", "I2", "VY", "UX", "TP", "AZ", "EI", "SK", "DY", "D8", "AY", "FI", "LO", "OK", "RO",
        "JU", "OU", "A3", "BT", "FB", "TK", "PC", "XQ", "LG", "KM", "V7", "QS", "0B",
        // Middle East and Africa
        "LY", "EK", "FZ", "EY", "QR", "GF", "SV", "XY", "WY", "KU", "RJ", "ME", "MS", "AT", "TU", "AH", "ET", "KQ",
        "SA", "FA", "WB", "MK",
        // Asia and the Pacific
        "QF", "VA", "JQ", "NZ", "FJ", "SQ", "TR", "MH", "AK", "D7", "OD", "TG", "FD", "VN", "VJ", "PR", "5J", "Z2",
        "GA", "QZ", "QG", "JT", "ID", "CX", "HX", "UO", "CI", "BR", "JX", "IT", "JL", "NH", "MM", "GK", "BC", "KE",
        "OZ", "7C", "LJ", "TW", "CA", "MU", "CZ", "HU", "3U", "ZH", "MF", "9C", "HO", "AI", "6E", "UK", "SG", "IX",
        "QP", "UL", "PK", "BG",
        // Latin America
        "CM", "AV", "LA", "JJ", "G3", "AD", "AR", "H2", "JA", "P5",
    ]

    private static let months: Set<String> = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
    private static let weekdays: Set<String> = ["MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"]

    /// Airport codes that are also everyday capitals. One beside a plain code is still a route
    /// ("EWR → DEN"); two together read as something else ("USA-CAN", "API-SDK").
    private static let everydayCapitals: Set<String> = [
        "USA", "CAN", "API", "SDK", "CEO", "CFO", "CTO", "COO", "CMO", "FYI", "ETA", "TBD", "TBA", "AMA", "PDF",
        "DOC", "QBR", "OKR", "KPI", "ROI", "VIP", "ETC", "THE", "AND", "FOR", "YOU", "ALL", "NEW", "OLD", "OUT",
        "OFF", "DAY", "PAY", "TAX", "CAT", "DOG", "BIG", "HOT", "RED", "SEA", "BAD", "MAD", "SAD", "FUN", "RUN",
        "WIN", "WAS", "HAS", "HAD", "GET", "GOT", "PUT", "SET", "LET", "ASK", "ADD", "END", "TOP", "MAX", "MIN",
        "AVG", "SUM", "DEN", "HAM", "LIS", "NAP", "LED", "PEN", "PIT", "BUS", "CAR", "AIR", "FLY", "JOB", "TEN",
        "ONE", "TWO", "SIX", "BOS", "SIN", "BUD", "GYM", "LAB", "MAP", "MOM", "DAD", "SON", "PET", "VET", "ART",
        "PRO", "CON", "YES", "NOT", "NOW", "WHO", "WHY", "HOW", "ICE", "SKI", "SPA", "ZAG", "GOA", "DIY", "RSV",
    ]

    /// A city with more than one large airport, and the one a flight "to" it means when the event
    /// names only the city. The zone and the name are the same either way; this picks the dot.
    private static let mainAirport: [String: String] = [
        "new york": "JFK", "london": "LHR", "paris": "CDG", "tokyo": "HND", "chicago": "ORD", "washington": "IAD",
        "milan": "MXP", "rome": "FCO", "moscow": "SVO", "shanghai": "PVG", "beijing": "PEK", "houston": "IAH",
        "dallas": "DFW", "los angeles": "LAX", "san francisco": "SFO", "miami": "MIA", "istanbul": "IST",
        "seoul": "ICN", "osaka": "KIX", "bangkok": "BKK", "sao paulo": "GRU", "buenos aires": "EZE",
        "rio de janeiro": "GIG", "stockholm": "ARN", "berlin": "BER", "toronto": "YYZ", "montreal": "YUL",
        "taipei": "TPE", "jakarta": "CGK", "kuala lumpur": "KUL", "dubai": "DXB", "melbourne": "MEL",
        "san jose": "SJC", "frankfurt": "FRA", "brussels": "BRU", "oslo": "OSL", "orlando": "MCO",
        "barcelona": "BCN", "manchester": "MAN", "birmingham": "BHX", "portland": "PDX", "santiago": "SCL",
        "sydney": "SYD", "vancouver": "YVR", "glasgow": "GLA", "belfast": "BFS", "tenerife": "TFS",
        "panama city": "PTY", "columbus": "CMH", "rochester": "ROC", "san juan": "SJU", "valencia": "VLC",
        "cordoba": "COR", "victoria": "YYJ", "st louis": "STL", "detroit": "DTW", "delhi": "DEL",
    ]

    /// Lowercased, accents and full stops gone, so "São Paulo", "Sao Paulo" and "St. Louis" meet.
    static func folded(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: ".", with: "")
    }

    /// City → airport for "to <city>", from the large airports in the table: the same city every
    /// run (it was whichever the dictionary happened to list first).
    private static let cityIndex: [String: String] = {
        var index: [String: String] = [:]
        for airport in AirportTable.all.values.sorted(by: { $0.code < $1.code }) where airport.size == .large {
            let city = folded(airport.city)
            guard city.count >= 3, index[city] == nil else { continue }
            index[city] = airport.code
        }
        for (city, code) in mainAirport where AirportTable.lookup(code) != nil { index[city] = code }
        return index
    }()

    /// Compiled once — NSRegularExpression construction is the expensive part of a match, and these
    /// patterns are fixed literals that always compile. NSRegularExpression is immutable/thread-safe
    /// after construction, so a single shared instance is safe to reuse from every caller. Kept
    /// optional (`try?`, not `try!`) so a future edit that breaks one of these literals degrades to
    /// "flight detection silently stops matching" — matching every other caller in this file —
    /// instead of trapping the process; `FlightParser.parse` runs on every calendar event shown.
    private static let flightNumberRegex = try? NSRegularExpression(
        pattern: "(?<![A-Za-z0-9])([A-Z]{2}|[A-Z][0-9]|[0-9][A-Z])\\s?([0-9]{1,4})(?![A-Za-z0-9])")
    private static let routeRegex = try? NSRegularExpression(
        pattern: "(?<![A-Za-z])([A-Z]{3})\\s*(?:→|->|—|–|>|-|[Tt][Oo])\\s*([A-Z]{3})(?![A-Za-z])")
    private static let parenCodeRegex = try? NSRegularExpression(pattern: "\\(([A-Z]{3})\\)")
    private static let bareCodeRegex = try? NSRegularExpression(pattern: "(?<![A-Za-z])([A-Z]{3})(?![A-Za-z])")
    private static let boardingRegex = try? NSRegularExpression(
        pattern: #"\bboard(?:ing|s)?(?:\s+time)?\s*(?:at|[:\-–—])?\s*([0-2]?\d)(?:[:.]([0-5]\d))?\s*([ap]\.?m\.?)?\b"#,
        options: [.caseInsensitive])

    /// Read the airport table and build the city index now, off the main thread, so the first
    /// calendar event drawn doesn't pay for them (a few milliseconds, once).
    static func warmUp() {
        _ = cityIndex.count
    }

    // MARK: - Parsing

    /// Parse a flight, or nil if the event doesn't look like one (confidence gate + destination
    /// required). A resolvable code with no supporting signal (e.g. "SFO parking") is rejected.
    static func parse(title: String, location: String?, notes: String?) -> Result? {
        let loc = location ?? "", note = notes ?? ""
        let hay = "\(title)\n\(note)\n\(loc)"
        let low = hay.lowercased()

        var confidence = 0
        if isVirtual(loc) { confidence -= 5 }   // a "MIA sync" on Zoom is not a flight

        var origin: Airport?
        var destination: Airport?
        var method = ""
        let numbered = hasFlightNumber(hay)

        if let route = codePair(in: hay) {
            origin = route.origin; destination = route.destination; method = "code-pair"
            confidence += route.strength
        }
        // Every city is found after "to ", so nothing is looked for unless "to " is there.
        if destination == nil, low.contains("to "), let code = cityDestination(in: hay, numbered: numbered) {
            destination = AirportTable.lookup(code); method = "city-name"; confidence += 1
        }

        if numbered { confidence += 2 }
        if airlineWords.contains(where: low.contains) { confidence += 1 }
        if saysFlight(low) || hay.contains("✈") { confidence += 1 }

        guard confidence >= 3, let dest = destination else { return nil }
        // Google's own flight events name the city in the title and the airport you leave from
        // in the location ("Newark EWR"): that is the origin.
        if origin == nil { origin = airport(named: loc, otherThan: dest) }
        return Result(origin: origin, destination: dest, confidence: confidence, method: method)
    }

    /// Returns a boarding time only when the calendar text explicitly labels one. This deliberately
    /// does not synthesize the usual "30–45 minutes before departure" value: airline schedules,
    /// aircraft and airports vary, and a guessed value must never look authoritative in the UI.
    ///
    /// Most airline calendar events express boarding in the departure airport's local time. EventKit
    /// gives us that event time zone separately, so callers should pass it instead of using the
    /// device's current zone (which may still be the zone the traveler is leaving from days later).
    static func boardingTime(title: String, location: String?, notes: String?,
                             departure: Date, timeZone: TimeZone?) -> Date? {
        guard let boardingRegex else { return nil }
        let text = [title, notes ?? "", location ?? ""].joined(separator: "\n")
        let ns = text as NSString

        for match in boardingRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let hourText = capture(match, 1, in: ns)
            let minuteText = capture(match, 2, in: ns)
            let meridiem = capture(match, 3, in: ns).lowercased().replacingOccurrences(of: ".", with: "")

            // Avoid reading "boarding group 5" as 05:00. A bare hour is a time only when it has
            // an AM/PM marker; 24-hour values still need minutes (for example "Boarding 17:40").
            guard !minuteText.isEmpty || !meridiem.isEmpty,
                  var hour = Int(hourText), hour >= 0, hour <= 23 else { continue }
            let minute = Int(minuteText) ?? 0
            if !meridiem.isEmpty {
                guard (1...12).contains(hour) else { continue }
                if meridiem == "pm", hour != 12 { hour += 12 }
                if meridiem == "am", hour == 12 { hour = 0 }
            }

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone ?? .current
            var components = calendar.dateComponents([.year, .month, .day], from: departure)
            components.hour = hour
            components.minute = minute
            components.second = 0
            guard var candidate = calendar.date(from: components) else { continue }

            // A flight just after midnight commonly boards on the prior calendar day.
            if candidate > departure.addingTimeInterval(15 * 60),
               let previousDay = calendar.date(byAdding: .day, value: -1, to: candidate) {
                candidate = previousDay
            }
            let lead = departure.timeIntervalSince(candidate)
            guard lead >= -15 * 60, lead <= 8 * 3_600 else { continue }
            return candidate
        }
        return nil
    }

    // MARK: - internals

    private static func isVirtual(_ s: String) -> Bool {
        let a = s.lowercased()
        return ["http://", "https://", "zoom.", "meet.google", "teams.microsoft", "webex"].contains { a.contains($0) }
    }

    private static func saysFlight(_ low: String) -> Bool {
        low.contains("flight") || low.hasPrefix("fly ") || low.contains("\nfly ") || low.contains("flying to ")
    }

    /// An airline's two-character code and one to four digits ("AA 1234", "UA857", "B6 23"). "AM"
    /// straight after a clock time ("9:30 AM 2026") is the morning, not Aeromexico.
    private static func hasFlightNumber(_ text: String) -> Bool {
        guard let flightNumberRegex else { return false }
        let ns = text as NSString
        for match in flightNumberRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let code = ns.substring(with: match.range(at: 1))
            guard airlineCodes.contains(code) else { continue }
            if code == "AM", match.range.location >= 2 {
                let before = ns.substring(with: NSRange(location: match.range.location - 2, length: 2))
                if before.first?.isNumber == true, before.last == " " { continue }
            }
            return true
        }
        return false
    }

    /// How much a pair of codes says by itself (see the type's comment).
    static func strength(of origin: Airport, to destination: Airport) -> Int {
        let codes = [origin.code, destination.code]
        if codes.contains(where: { months.contains($0) || weekdays.contains($0) }) { return 1 }
        if codes.allSatisfy(everydayCapitals.contains) { return 1 }
        return origin.size == .large && destination.size == .large ? 3 : 2
    }

    /// Origin/destination from an explicit "SFO → MIA" / "SFO-MIA" / "EWR to MIA" (direction
    /// wins), else the first two DISTINCT parenthesised codes in reading order. NOT first/last —
    /// the origin airport is often repeated at the end (a location field), which collapsed the
    /// route to origin→origin (caught on real TripIt data). Of several routes written out, the
    /// one that says most.
    private static func codePair(in text: String) -> (origin: Airport, destination: Airport, strength: Int)? {
        let deparened = text.replacingOccurrences(of: "(", with: " ").replacingOccurrences(of: ")", with: " ")
        var best: (origin: Airport, destination: Airport, strength: Int)?
        for g in captures(routeRegex, deparened) {
            guard let o = AirportTable.lookup(g[1]), let d = AirportTable.lookup(g[2]), o.code != d.code else { continue }
            let found = strength(of: o, to: d)
            if best == nil || found > best!.strength { best = (o, d, found) }
        }
        if let best { return best }
        var distinct: [Airport] = []
        for g in captures(parenCodeRegex, text) {
            if let a = AirportTable.lookup(g[1]), !distinct.contains(where: { $0.code == a.code }) {
                distinct.append(a)
            }
        }
        guard distinct.count >= 2 else { return nil }
        return (distinct[0], distinct[1], strength(of: distinct[0], to: distinct[1]))
    }

    /// The city after "to", when the line says it as a flight: a flight word before it ("Flight to
    /// Miami", "United flight to Austin") or a flight number in the event. "Talk to Jackson about
    /// the Delta flight" names a person. The longest city that fits wins ("to San José del Cabo").
    private static func cityDestination(in text: String, numbered: Bool) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let words = folded(String(line)).split(whereSeparator: { !($0.isLetter || $0 == "'" || $0 == "✈") })
                .map(String.init)
            for (index, word) in words.enumerated() where word == "to" && index + 1 < words.count {
                let before = words[..<index]
                guard numbered || before.contains(where: { ["flight", "flights", "fly", "flying", "✈"].contains($0) })
                else { continue }
                let after = words[(index + 1)...].prefix(4)
                for length in stride(from: after.count, through: 1, by: -1) {
                    if let code = cityIndex[after.prefix(length).joined(separator: " ")] { return code }
                }
            }
        }
        return nil
    }

    /// The airport written in a location ("Newark EWR"), by its code: the first that isn't the
    /// destination and doesn't read as a month or a weekday.
    private static func airport(named location: String, otherThan destination: Airport) -> Airport? {
        for g in captures(bareCodeRegex, location) {
            guard !months.contains(g[1]), !weekdays.contains(g[1]),
                  let airport = AirportTable.lookup(g[1]), airport.code != destination.code else { continue }
            return airport
        }
        return nil
    }

    private static func matches(_ re: NSRegularExpression?, _ text: String) -> [String] {
        guard let re else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    private static func capture(_ match: NSTextCheckingResult, _ index: Int, in text: NSString) -> String {
        guard index < match.numberOfRanges else { return "" }
        let range = match.range(at: index)
        return range.location == NSNotFound ? "" : text.substring(with: range)
    }

    private static func captures(_ re: NSRegularExpression?, _ text: String) -> [[String]] {
        guard let re else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { i in
                let r = m.range(at: i); return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
        }
    }

    #if DEBUG
    /// Deterministic launch-harness checks for the edge cases that would make a wrong boarding
    /// time actively harmful. Kept beside the parser so future syntax changes extend the fixture
    /// set instead of relying on another overnight device run.
    static func boardingVerificationFailures() -> [String] {
        guard let zone = TimeZone(identifier: "America/New_York") else { return ["missing test time zone"] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard let departure = calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 21, hour: 18, minute: 20)),
              let midnightDeparture = calendar.date(from: DateComponents(
                year: 2026, month: 7, day: 22, hour: 0, minute: 15)) else {
            return ["could not construct fixtures"]
        }

        var failures: [String] = []
        func verify(_ name: String, notes: String, departure: Date = departure, expectedLead: Int?) {
            let parsed = boardingTime(
                title: "UA 123 EWR → SFO", location: "EWR", notes: notes,
                departure: departure, timeZone: zone)
            let actual = parsed.map { Int(departure.timeIntervalSince($0) / 60) }
            if actual != expectedLead { failures.append("\(name): expected \(String(describing: expectedLead)), got \(String(describing: actual))") }
        }

        verify("labeled 12-hour", notes: "Gate C7\nBoarding: 5:40 PM", expectedLead: 40)
        verify("labeled 24-hour", notes: "Boarding 17:40", expectedLead: 40)
        verify("boarding group is not a time", notes: "Boarding group 5", expectedLead: nil)
        verify("prior-day boarding", notes: "Boards at 11:30 PM", departure: midnightDeparture, expectedLead: 45)
        verify("departure is not boarding", notes: "Departure 5:40 PM", expectedLead: nil)
        return failures
    }
    #endif
}
