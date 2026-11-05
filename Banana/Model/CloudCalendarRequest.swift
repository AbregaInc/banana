import Foundation

/// A typed, read-only Calendar request. Never forwards a host, arbitrary path, or write method.
struct CloudCalendarRequest: Codable, Equatable, Sendable {
    struct Query: Codable, Equatable, Sendable { let name: String; let value: String }
    let resource: String
    let email: String
    let calendarID: String?
    let eventID: String?
    let query: [Query]

    init(url: URL, email: String) throws {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host == "www.googleapis.com", parts.port == nil,
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              !email.isEmpty else { throw CloudCalendarSnapshot.Failure.unsupportedResponse }
        let encoded = parts.percentEncodedPath.split(separator: "/")
        let path = encoded.compactMap { String($0).removingPercentEncoding }
        guard path.count == encoded.count else { throw CloudCalendarSnapshot.Failure.unsupportedResponse }
        guard path.prefix(2) == ["calendar", "v3"] else { throw CloudCalendarSnapshot.Failure.unsupportedResponse }
        let rest = Array(path.dropFirst(2))
        if rest == ["users", "me", "calendarList"] {
            resource = "calendarList"; calendarID = nil; eventID = nil
        } else if rest.count == 3, rest[0] == "calendars", rest[2] == "acl" {
            resource = "acl"; calendarID = rest[1]; eventID = nil
        } else if (3...5).contains(rest.count), rest[0] == "calendars", rest[2] == "events",
                  rest.count != 5 || rest[4] == "instances" {
            resource = rest.count == 3 ? "events" : rest.count == 4 ? "event" : "instances"
            calendarID = rest[1]; eventID = rest.count >= 4 ? rest[3] : nil
        } else { throw CloudCalendarSnapshot.Failure.unsupportedResponse }
        self.email = email.lowercased()
        query = (parts.queryItems ?? []).map { Query(name: $0.name, value: $0.value ?? "") }
    }
}

enum GoogleCalendarReadAuthorization: Sendable {
    case direct(String)
    case cloud(email: String, context: String)

    func accepts(cursor: String) -> Bool {
        switch self {
        case .direct: return !cursor.hasPrefix("banana-calendar:")
        case .cloud: return cursor.hasPrefix("banana-calendar:")
        }
    }
}
