import Foundation
@main struct Check {
    static func main() throws {
        let query = CalendarSearchQuery(text: "  café & planning  ", start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 86400))
        let url = query.googleURL(calendarID: "a/b@example.com", pageToken: "next&=?")!
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let values = Dictionary(uniqueKeysWithValues: parts.queryItems!.map { ($0.name, $0.value!) })
        precondition(parts.percentEncodedPath.contains("a%2Fb@example.com"))
        precondition(values["q"] == "café & planning")
        precondition(values["pageToken"] == "next&=?")
        precondition(values["singleEvents"] == "true" && values["maxResults"] == "50")
        precondition(query.googleURL(calendarID: "a") != nil)
        precondition(CalendarSearchQuery(text: "", start: query.start, end: query.end).googleURL(calendarID: "a") == nil)
        precondition(CalendarSearchQuery(text: "x", start: query.end, end: query.start).googleURL(calendarID: "a") == nil)
        print("Calendar search URL checks passed")
    }
}
