import Foundation

/// Provider-independent search scope. Recurrence expansion is bounded by the visible date range.
struct CalendarSearchQuery: Hashable, Sendable {
    var text: String
    var start: Date
    var end: Date
    var excludedCalendarIDs: Set<String> = []

    var filter = LiveFilter(scope: "plan")

    var terms: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isValid: Bool { (!terms.isEmpty || !filter.isEmpty) && filter.canRun && start < end }

    func googleURL(calendarID: String, pageToken: String? = nil) -> URL? {
        guard isValid else { return nil }
        var url = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/")!
        url.path += calendarID + "/events"
        let formatter = ISO8601DateFormatter()
        url.queryItems = [
            URLQueryItem(name: "timeMin", value: formatter.string(from: start)),
            URLQueryItem(name: "timeMax", value: formatter.string(from: end)),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "showDeleted", value: "false"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "maxResults", value: "50")
        ]
        if !terms.isEmpty { url.queryItems?.append(URLQueryItem(name: "q", value: terms)) }
        if let pageToken { url.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        // A calendar id is one path segment, including ids containing a slash.
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/%?#"))
        guard let encoded = calendarID.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        url.percentEncodedPath = "/calendar/v3/calendars/" + encoded + "/events"
        return url.url
    }
}

struct CalendarSearchCursor: Hashable, Sendable {
    let query: CalendarSearchQuery
    let calendarIDs: [String]
    let calendarIndex: Int
    let pageToken: String?
}
