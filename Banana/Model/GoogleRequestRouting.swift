import Foundation

/// Which account a Google Calendar API request belongs to.
///
/// With one account connected this never mattered — there was one token. With several, every
/// request has to be made with the credential of the account that owns the calendar, and the
/// calendar id is already in the URL of every per-calendar endpoint
/// (`/calendar/v3/calendars/{calendarId}/…`). Deriving it from the request means the account did
/// not have to be threaded through every call site, and — because Google calendar ids are globally
/// unique — nothing persisted needed an account component or a migration.
enum GoogleRequestRouting {

    /// The calendar id in a Calendar API URL, or nil for endpoints that aren't per-calendar
    /// (`/users/me/calendarList`, the token endpoint), which are addressed by account directly.
    static func calendarID(fromRequestURL url: URL) -> String? {
        let parts = url.pathComponents
        guard let index = parts.firstIndex(of: "calendars"), index + 1 < parts.count else { return nil }
        let raw = parts[index + 1]
        return raw.removingPercentEncoding ?? raw
    }
}
