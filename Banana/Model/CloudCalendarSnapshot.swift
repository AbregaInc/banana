import Foundation

/// A complete or partial service read, not permission to clear a native cache or start a writer.
/// Provider models stay shared with the existing Calendar normalization path.
struct CloudCalendarSnapshot: Decodable {
    struct Source: Decodable {
        let email: String
        let calendar: GoogleCalendar
        let events: [GoogleEvent]

        var ownedCalendar: GoogleCalendar {
            var result = calendar
            result.accountEmail = email.lowercased()
            return result
        }
    }
    struct Unavailable: Decodable {
        let email: String
        let calendar: String?
        let calendarID: String?
        let reason: String
    }
    enum Failure: Error { case invalidWindow, unsupportedResponse, unavailable, contextChanged }
    let version: Int
    let from: Int64
    let to: Int64
    let sources: [Source]
    let unavailable: [Unavailable]

    var isComplete: Bool { unavailable.isEmpty }
    /// Empty successful calendars are covered. Failed calendars are never covered.
    var coveredCalendarIDs: Set<String> { Set(sources.map { $0.calendar.id }) }

    static func bounds(from: Date, to: Date) throws -> (from: Int64, to: Int64) {
        let start = from.timeIntervalSince1970 * 1000
        let end = to.timeIntervalSince1970 * 1000
        guard start.isFinite, end.isFinite, start > 0, end > start,
              end - start <= 8 * 86_400_000,
              start < Double(Int64.max), end < Double(Int64.max) else { throw Failure.invalidWindow }
        let result = (from: Int64(start), to: Int64(end))
        guard result.to > result.from else { throw Failure.invalidWindow }
        return result
    }

    static func decode(_ data: Data, from: Int64, to: Int64) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.version == 1, value.from == from, value.to == to else { throw Failure.unsupportedResponse }
        // A provider may return the same calendar through different linked accounts. A failed
        // source must not authorize clearing that calendar even if another account read it.
        let failed = Set(value.unavailable.compactMap(\.calendarID))
        guard value.sources.allSatisfy({ !$0.calendar.id.isEmpty && !$0.email.isEmpty }),
              value.coveredCalendarIDs.isDisjoint(with: failed) else { throw Failure.unsupportedResponse }
        return value
    }
}
