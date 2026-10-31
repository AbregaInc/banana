import Foundation
import CoreLocation

// Google Calendar's wire format, and the pure logic that turns it into what the rest of Banana
// uses. Split out of GoogleCalendarService.swift — which is network, keychain and the Google
// Sign-In SDK — so everything that decides what a Google event MEANS can be unit-tested against
// real API payloads without any of that.

enum GoogleCalendarEventScope: Equatable {
    case occurrence
    case series
    /// This occurrence and every later one, leaving earlier occurrences intact.
    ///
    /// Google's API has no delete verb for this — the operation is expressed by truncating the
    /// series' own `RRULE` with an `UNTIL` just before the chosen occurrence. Without it, "delete
    /// Saturday onward" had to be offered as "delete entire series", which throws away the Tue–Fri
    /// occurrences the person explicitly wanted to keep.
    case thisAndFollowing
}

struct GoogleCalendar: Decodable, Identifiable, Hashable {
    /// Which connected account this calendar came from. Not part of Google's payload — filled in
    /// as each account's list is loaded, so a request can be made with the right credential. A
    /// calendar id is globally unique across accounts, which is why nothing persisted had to gain
    /// an account component.
    var accountEmail: String = ""

    /// Only the fields Google actually sends.
    ///
    /// `accountEmail` is filled in by this app after decoding, and it MUST be excluded here: a
    /// default value does not make a key optional to Swift's synthesised `Decodable`, which
    /// requires every stored property's key unless it is `Optional`. Leaving it in made every
    /// calendar-list response fail to decode — reported as `malformedResponse`, seen as accounts
    /// that connect and then show no calendars at all.
    private enum CodingKeys: String, CodingKey {
        case id, summary, summaryOverride, backgroundColor, accessRole, primary, hidden, deleted, dataOwner
    }

    let id: String
    let summary: String?
    let summaryOverride: String?
    let backgroundColor: String?
    let accessRole: String?
    let primary: Bool?
    let hidden: Bool?
    let deleted: Bool?
    var dataOwner: String? = nil

    /// Manager permission can be shared too. Google's data owner identifies secondary calendars;
    /// primary calendars use their account email. Older secondary entries fall back to the role.
    var isOwnedByAccount: Bool {
        guard accessRole == "owner" else { return false }
        let viewer = accountEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let owner = dataOwner?.trimmingCharacters(in: .whitespacesAndNewlines), !owner.isEmpty {
            return owner.lowercased() == viewer
        }
        if isPrimary { return true }
        if id.contains("@"), !id.hasSuffix(".calendar.google.com") { return id.lowercased() == viewer }
        return true
    }

    /// A person, never the connected viewer account or a secondary calendar's opaque id.
    var reconciliationOwner: String? {
        let owner = dataOwner?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let owner, !owner.isEmpty { return owner }
        guard id.contains("@"), !id.hasSuffix(".calendar.google.com") else { return nil }
        return id.lowercased()
    }

    var displayTitle: String { summaryOverride?.nilIfEmpty ?? summary?.nilIfEmpty ?? "Calendar" }
    var isPrimary: Bool { primary == true }
    var isHidden: Bool { hidden == true }
    var isDeleted: Bool { deleted == true }
    var isWritable: Bool { accessRole == "owner" || accessRole == "writer" }
}

struct GoogleCalendarListResponse: Decodable {
    let nextPageToken: String?
    let items: [GoogleCalendar]?
}

struct GoogleEventsResponse: Codable {
    let nextPageToken: String?
    /// Present on the last page of a list, when the request can be continued incrementally.
    let nextSyncToken: String?
    let items: [GoogleEvent]?
}

struct GoogleEvent: Codable {
    struct EventDate: Codable { let date: String?; let dateTime: String?; let timeZone: String? }
    struct Attendee: Codable {
        let email: String?
        let displayName: String?
        let selfAttendee: Bool?
        let organizer: Bool?
        let responseStatus: String?

        private enum CodingKeys: String, CodingKey {
            case email, displayName, organizer
            case selfAttendee = "self"
            case responseStatus
        }
    }
    struct ConferenceData: Codable {
        struct EntryPoint: Codable { let entryPointType: String?; let uri: String? }
        let entryPoints: [EntryPoint]?
    }
    struct Reminders: Codable {
        struct Override: Codable { let method: String?; let minutes: Int? }
        let useDefault: Bool?
        let overrides: [Override]?
    }

    /// App-private key/value data. Unlike the `url` marker used on EventKit events, this is not
    /// rewritten by any sync layer, which is what makes a busy block findable again after it has
    /// round-tripped through Google.
    struct ExtendedProperties: Codable {
        let `private`: [String: String]?
    }

    let id: String?
    /// The iCalendar UID. An event created through Apple Calendar's CalDAV mirror keeps the UID
    /// EventKit gave it (`calendarItemExternalIdentifier`), which is how a block written that way
    /// is found again through the API — see `LegacyBlockAdoption`.
    let iCalUID: String?
    let extendedProperties: ExtendedProperties?
    let status: String?
    let summary: String?
    let description: String?
    let location: String?
    let transparency: String?
    let hangoutLink: String?
    let start: EventDate?
    let end: EventDate?
    let attendees: [Attendee]?
    let conferenceData: ConferenceData?
    let reminders: Reminders?
    let recurrence: [String]?
    let recurringEventId: String?
    let htmlLink: String?
    /// Last modification time (RFC 3339), for telling a real change from a re-read.
    let updated: String?
    let locked: Bool?
    /// Who organizes it. `self` is true on the organizer's own calendar copy.
    let organizer: Organizer?
    let guestsCanModify: Bool?
    /// "default", or one Google manages itself ("birthday", "workingLocation", "outOfOffice"…).
    let eventType: String?
    /// The version, sent back as If-Match so an edit never overwrites a change made since.
    let etag: String?
    /// An occurrence's place in its series, which a moved occurrence keeps.
    let originalStartTime: EventDate?

    struct Organizer: Codable {
        let email: String?
        let displayName: String?
        let selfOrganizer: Bool?

        private enum CodingKeys: String, CodingKey {
            case email, displayName
            case selfOrganizer = "self"
        }
    }
}

struct GoogleAPIErrorEnvelope: Decodable {
    struct APIError: Decodable { let message: String? }
    let error: APIError
}

/// A reply to an invitation, as Google spells it.
enum GoogleCalendarRSVP: String, Equatable {
    case accepted, declined, tentative

    /// What a reply says once sent: "Going to “Standup”", "Maybe for “Standup”".
    func confirmation(title: String) -> String {
        let name = title.isEmpty ? "the invitation" : "\u{201C}\(title)\u{201D}"
        switch self {
        case .accepted: return "Going to \(name)"
        case .tentative: return "Maybe for \(name)"
        case .declined: return "Declined \(name)"
        }
    }
}

/// Change only the person's own reply in an event's attendee list, leaving every other guest —
/// and every field Banana does not model (optional, resource, comment, additionalGuests) —
/// exactly as Google sent it. PATCH replaces the whole attendee list, so it must be the list
/// Google returned with one value changed, never a re-encoding of Banana's reduced model.
enum GoogleRSVPPatch {
    static func attendees(_ attendees: [[String: Any]], replying response: GoogleCalendarRSVP) -> [[String: Any]]? {
        guard attendees.contains(where: { $0["self"] as? Bool == true }) else { return nil }
        return attendees.map { attendee in
            guard attendee["self"] as? Bool == true else { return attendee }
            var mine = attendee
            mine["responseStatus"] = response.rawValue
            return mine
        }
    }
}

// MARK: - Identity

/// Banana's identifiers for Google calendars and events.
///
/// A Google calendar or event id is not globally distinguishable from an EventKit identifier, so
/// both are wrapped in a prefixed, base64 form. The calendar id travels inside the event id because
/// every Calendar API call about an event needs both.
enum GoogleCalendarIDs {
    static let calendarPrefix = "google-calendar:"
    static let eventPrefix = "google-event:"

    static func calendarInfoID(_ rawID: String) -> String {
        calendarPrefix + Data(rawID.utf8).base64EncodedString()
    }

    static func rawCalendarID(from infoID: String) -> String? {
        guard infoID.hasPrefix(calendarPrefix) else { return nil }
        let encoded = String(infoID.dropFirst(calendarPrefix.count))
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func eventInfoID(calendarID: String, eventID: String) -> String {
        eventPrefix
            + Data(calendarID.utf8).base64EncodedString()
            + ":"
            + Data(eventID.utf8).base64EncodedString()
    }

    static func rawEventRoute(from infoID: String) -> (calendarID: String, eventID: String)? {
        guard infoID.hasPrefix(eventPrefix) else { return nil }
        let encoded = infoID.dropFirst(eventPrefix.count)
        guard let separator = encoded.firstIndex(of: ":"),
              let calendarData = Data(base64Encoded: String(encoded[..<separator])),
              let eventData = Data(base64Encoded: String(encoded[encoded.index(after: separator)...])),
              let calendarID = String(data: calendarData, encoding: .utf8),
              let eventID = String(data: eventData, encoding: .utf8) else { return nil }
        return (calendarID, eventID)
    }

    static func isCalendarInfoID(_ id: String?) -> Bool { id?.hasPrefix(calendarPrefix) == true }
    static func isEventInfoID(_ id: String?) -> Bool { id?.hasPrefix(eventPrefix) == true }
}

// MARK: - Dates

enum GoogleCalendarDates {
    static func rfc3339(_ date: Date) -> String {
        fractionalFormatter.string(from: date)
    }

    static func parseRFC3339(_ value: String) -> Date? {
        fastRFC3339(value) ?? fractionalFormatter.date(from: value) ?? wholeSecondFormatter.date(from: value)
    }

    /// Google's own shape — `2026-10-04T09:00:00-07:00`, `…Z`, `….123Z` — read by hand. Two
    /// `ISO8601DateFormatter` attempts per timestamp (Google rarely sends fractions, so the first
    /// always failed) were a tenth of building a calendar window, done twice per event per read.
    /// Anything else, or anything out of range, is nil here and goes to the formatters.
    static func fastRFC3339(_ value: String) -> Date? {
        let bytes = Array(value.utf8)
        guard bytes.count <= 40 else { return nil }
        func digits(_ at: Int, _ count: Int) -> Int? {
            guard at + count <= bytes.count else { return nil }
            var n = 0
            for i in at..<(at + count) {
                let d = Int(bytes[i]) - 48
                guard d >= 0, d <= 9 else { return nil }
                n = n * 10 + d
            }
            return n
        }
        func byte(_ at: Int, is options: String) -> Bool {
            at < bytes.count && options.utf8.contains(bytes[at])
        }
        guard bytes.count >= 20,
              let year = digits(0, 4), byte(4, is: "-"),
              let month = digits(5, 2), byte(7, is: "-"),
              let day = digits(8, 2), byte(10, is: "T"),
              let hour = digits(11, 2), byte(13, is: ":"),
              let minute = digits(14, 2), byte(16, is: ":"),
              let second = digits(17, 2),
              (1...12).contains(month), hour < 24, minute < 60, second < 60,
              day >= 1, day <= daysIn(month: month, year: year)
        else { return nil }

        var at = 19
        var fraction = 0.0
        if byte(at, is: ".") {
            at += 1
            var scale = 0.1
            let first = at
            while at < bytes.count, let d = digits(at, 1) {
                fraction += Double(d) * scale
                scale /= 10
                at += 1
            }
            guard at > first else { return nil }
        }
        var offset = 0
        if byte(at, is: "Z") {
            at += 1
        } else if byte(at, is: "+-") {
            let sign = bytes[at] == UInt8(ascii: "-") ? -1 : 1
            guard let offsetHours = digits(at + 1, 2), byte(at + 3, is: ":"),
                  let offsetMinutes = digits(at + 4, 2), offsetHours < 24, offsetMinutes < 60
            else { return nil }
            offset = sign * (offsetHours * 3_600 + offsetMinutes * 60)
            at += 6
        } else {
            return nil
        }
        guard at == bytes.count else { return nil }

        // Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's days_from_civil).
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * ((month + 9) % 12) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let days = era * 146_097 + dayOfEra - 719_468
        let seconds = days * 86_400 + hour * 3_600 + minute * 60 + second - offset
        return Date(timeIntervalSince1970: Double(seconds) + fraction)
    }

    private static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// An all-day date (`yyyy-MM-dd`) as local midnight — how an all-day event is placed on a day.
    static func parseDate(_ value: String) -> Date? {
        dateOnlyFormatter.date(from: value)
    }

    static func dateString(_ date: Date) -> String {
        dateOnlyFormatter.string(from: date)
    }

    /// The event's span, and whether it is all-day. Nil for anything without a usable, positive
    /// span — Google sends cancelled instances of a series with no times at all.
    static func range(of event: GoogleEvent) -> (start: Date, end: Date, isAllDay: Bool)? {
        if let startValue = event.start?.dateTime,
           let endValue = event.end?.dateTime,
           let start = parseRFC3339(startValue),
           let end = parseRFC3339(endValue),
           end > start {
            return (start, end, false)
        }
        if let startValue = event.start?.date,
           let endValue = event.end?.date,
           let start = parseDate(startValue),
           let end = parseDate(endValue),
           end > start {
            return (start, end, true)
        }
        return nil
    }

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let wholeSecondFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
