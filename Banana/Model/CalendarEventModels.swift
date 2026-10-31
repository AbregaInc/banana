import Foundation
import CoreLocation

// Provider-neutral calendar values.
//
// These used to live in CalendarService.swift, which is the EventKit reader. Nothing here depends
// on EventKit, and keeping them beside it meant every piece of calendar logic that touched a
// `MeetingInfo` dragged EventKit (and the rest of CalendarService's dependencies) in behind it —
// which is why none of it could be unit-tested. The Google-only calendar layer is built on these.
enum CalendarEventCreationError: LocalizedError {
    case accessDenied
    case noDefaultCalendar
    case calendarUnavailable
    case emptyTitle
    case invalidDuration
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Banana needs Calendar access to create events. Enable it in Settings and try again."
        case .noDefaultCalendar:
            return "Choose a default writable calendar in Apple Calendar, then try again."
        case .calendarUnavailable:
            return "That calendar is no longer available or writable. Choose another calendar and try again."
        case .emptyTitle:
            return "Enter an event name."
        case .invalidDuration:
            return "The event must end after it starts."
        case .saveFailed(let detail):
            return "The calendar couldn’t save this event: \(detail)"
        }
    }
}

enum CalendarEventMoveError: LocalizedError {
    case originalCouldNotBeDeleted(String)
    case duplicateLeftAfterFailedRollback(String)

    var errorDescription: String? {
        switch self {
        case .originalCouldNotBeDeleted(let detail):
            return "The original event couldn’t be removed, so Banana removed the new copy. Nothing was moved. \(detail)"
        case .duplicateLeftAfterFailedRollback(let detail):
            return "The new copy was created, but the original couldn’t be removed. Both events still exist; delete one manually. \(detail)"
        }
    }
}

enum CalendarEventAvailability: String, CaseIterable, Identifiable, Codable {
    case busy, free, tentative, unavailable

    var id: String { rawValue }
    var title: String {
        switch self {
        case .busy: return "Busy"
        case .free: return "Free"
        case .tentative: return "Tentative"
        case .unavailable: return "Out of office"
        }
    }
}

enum CalendarItemRecurrence: String, CaseIterable, Identifiable, Hashable, Codable {
    case never, daily, weekly, monthly, yearly

    var id: String { rawValue }
    var title: String {
        switch self {
        case .never: return "Never"
        case .daily: return "Every day"
        case .weekly: return "Every week"
        case .monthly: return "Every month"
        case .yearly: return "Every year"
        }
    }
}

struct CalendarEventLocation: Codable, Hashable, Sendable {
    var title: String
    var latitude: Double
    var longitude: Double
    var placeID: String?
}

/// `Codable` because an event the user has typed but which has not yet reached a calendar exists
/// nowhere else. If the write fails, or the app is killed mid-write, this struct is the only copy
/// of what they asked for — see `PendingCalendarWriteStore`.
struct CalendarEventInput: Codable {
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var location: String?
    var notes: String?
    var url: URL?
    var availability: CalendarEventAvailability
    var alertMinutesBefore: Int?
    var structuredLocation: CalendarEventLocation? = nil
    var recurrence: CalendarItemRecurrence = .never
    /// When the repeat stops, inclusive of that day. `nil` repeats forever.
    ///
    /// Worth having at creation rather than only as an edit: a blocker made to repeat forever and
    /// truncated later depends on that truncation reaching every copy of the calendar, and when it
    /// does not the series keeps generating on the server while the local rule says otherwise.
    /// Setting the end up front means there is nothing to truncate.
    var recurrenceEnd: Date? = nil
    var secondaryAlertMinutesBefore: Int? = nil
    /// Provider-neutral RFC 5545 rules used when migrating an existing repeating series.
    var recurrenceRules: [String]? = nil
    /// Guests' addresses. Google emails each an invitation when the event is made. Optional, so a
    /// pending write saved before guests existed still reads back.
    var attendees: [String]? = nil
}

/// A day's first qualifying meeting, with whatever location info it carries.
struct MeetingInfo: Identifiable {
    var start: Date
    var end: Date?                            // event end, for duration / scheduling free time
    var coordinate: CLLocationCoordinate2D?   // present if the event has structured coords
    var address: String?                      // free-text location, if any
    var isVirtual: Bool                       // looks like a video-call link, not a place
    var title: String = "your meeting"
    var eventID: String?                      // provider event id, to re-fetch for detail/RSVP
    var joinURL: URL?                         // parsed video-meeting link (Zoom/Meet/Teams/…)
    var platform: MeetingPlatform?            // which platform, for the branded Join button
    var calendarID: String? = nil             // owning calendar, for cross-calendar availability
    /// The event is marked transparent ("Show As: Free"). It still appears on the timeline — it
    /// is a thing you are doing — but it never counts as busy and never gets a block written for
    /// it. Restaurant bookings and imported confirmations arrive this way constantly, and they
    /// used to be dropped at ingest with nothing shown anywhere.
    var showsAsFree: Bool = false
    var isRecurring: Bool = false
    /// Your reply, when the event is an invitation. `nil` for events without guests (or where
    /// you are not on the guest list), which read as plainly yours.
    var myResponse: MeetingResponse? = nil
    /// Every other guest has declined — the meeting is probably not happening.
    var othersAllDeclined: Bool = false
    /// Other calendars the same meeting was found on and merged away, so the grid can show one
    /// block with a ribbon per calendar instead of stacked copies.
    var alsoOnCalendarIDs: [String] = []
    /// An all-day event — a trip, an offsite, a birthday: `start` is its first day's start and
    /// `end` the start of the day after its last. Never in `CalendarEventWindow.meetings`; it
    /// blocks its days only when it isn't `showsAsFree` (docs/design/ALL-DAY-EVENTS.md).
    var isAllDay: Bool = false
    /// Someone else's private availability: visible on their calendar, never your appointment.
    var isAvailabilityOnly: Bool = false
    var shouldMirrorBusyTime: Bool { !showsAsFree && !isAvailabilityOnly }

    var id: String { eventID ?? "\(Int(start.timeIntervalSince1970))-\(title)" }
    var hasPhysicalLocation: Bool {
        !isVirtual && (coordinate != nil || (address?.isEmpty == false))
    }
}

/// Your reply to an invitation. Declined events never reach the timeline, so there is no case
/// for them.
enum MeetingResponse: String, Codable, Hashable {
    case accepted, tentative, needsAction

    init?(googleStatus: String?) {
        switch googleStatus {
        case "accepted": self = .accepted
        case "tentative": self = .tentative
        case "needsAction": self = .needsAction
        default: return nil
        }
    }
}

/// Codable so an `Occurrence` carrying a meeting can ride in the first-paint snapshot
/// (CLLocationCoordinate2D isn't Codable; it round-trips as lat/lon).
extension MeetingInfo: Codable {
    private enum CodingKeys: String, CodingKey {
        case start, end, lat, lon, address, isVirtual, title, eventID, joinURL, platform, calendarID
        case showsAsFree, isRecurring, myResponse, othersAllDeclined, alsoOnCalendarIDs, isAllDay, isAvailabilityOnly
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let lat = try c.decodeIfPresent(Double.self, forKey: .lat)
        let lon = try c.decodeIfPresent(Double.self, forKey: .lon)
        self.init(start: try c.decode(Date.self, forKey: .start),
                  end: try c.decodeIfPresent(Date.self, forKey: .end),
                  coordinate: (lat != nil && lon != nil) ? CLLocationCoordinate2D(latitude: lat!, longitude: lon!) : nil,
                  address: try c.decodeIfPresent(String.self, forKey: .address),
                  isVirtual: try c.decode(Bool.self, forKey: .isVirtual),
                  title: try c.decodeIfPresent(String.self, forKey: .title) ?? "your meeting",
                  eventID: try c.decodeIfPresent(String.self, forKey: .eventID),
                  joinURL: try c.decodeIfPresent(URL.self, forKey: .joinURL),
                  platform: try c.decodeIfPresent(MeetingPlatform.self, forKey: .platform),
                  calendarID: try c.decodeIfPresent(String.self, forKey: .calendarID),
                  showsAsFree: try c.decodeIfPresent(Bool.self, forKey: .showsAsFree) ?? false,
                  isRecurring: try c.decodeIfPresent(Bool.self, forKey: .isRecurring) ?? false,
                  myResponse: try c.decodeIfPresent(MeetingResponse.self, forKey: .myResponse),
                  othersAllDeclined: try c.decodeIfPresent(Bool.self, forKey: .othersAllDeclined) ?? false,
                  alsoOnCalendarIDs: try c.decodeIfPresent([String].self, forKey: .alsoOnCalendarIDs) ?? [],
                  isAllDay: try c.decodeIfPresent(Bool.self, forKey: .isAllDay) ?? false,
                  isAvailabilityOnly: try c.decodeIfPresent(Bool.self, forKey: .isAvailabilityOnly) ?? false)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(start, forKey: .start)
        try c.encodeIfPresent(end, forKey: .end)
        try c.encodeIfPresent(coordinate?.latitude, forKey: .lat)
        try c.encodeIfPresent(coordinate?.longitude, forKey: .lon)
        try c.encodeIfPresent(address, forKey: .address)
        try c.encode(isVirtual, forKey: .isVirtual)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(eventID, forKey: .eventID)
        try c.encodeIfPresent(joinURL, forKey: .joinURL)
        try c.encodeIfPresent(platform, forKey: .platform)
        try c.encodeIfPresent(calendarID, forKey: .calendarID)
        try c.encode(showsAsFree, forKey: .showsAsFree)
        try c.encode(isRecurring, forKey: .isRecurring)
        try c.encodeIfPresent(myResponse, forKey: .myResponse)
        if othersAllDeclined { try c.encode(othersAllDeclined, forKey: .othersAllDeclined) }
        if !alsoOnCalendarIDs.isEmpty { try c.encode(alsoOnCalendarIDs, forKey: .alsoOnCalendarIDs) }
        if isAllDay { try c.encode(isAllDay, forKey: .isAllDay) }
        if isAvailabilityOnly { try c.encode(isAvailabilityOnly, forKey: .isAvailabilityOnly) }
    }
}

/// Manual Hashable conformance over exactly the fields the Codable conformance above enumerates
/// (CLLocationCoordinate2D isn't Hashable, so `coordinate` is decomposed into lat/lon the same way
/// Codable already does). Used only as a cheap change-detection token (WeekView's day content
/// hash); not persisted or compared across launches, so hash-value stability across app versions
/// is not a requirement.
extension MeetingInfo: Hashable {
    static func == (a: MeetingInfo, b: MeetingInfo) -> Bool {
        a.start == b.start && a.end == b.end
            && a.coordinate?.latitude == b.coordinate?.latitude
            && a.coordinate?.longitude == b.coordinate?.longitude
            && a.address == b.address && a.isVirtual == b.isVirtual && a.title == b.title
            && a.eventID == b.eventID && a.joinURL == b.joinURL && a.platform == b.platform
            && a.calendarID == b.calendarID && a.showsAsFree == b.showsAsFree
            && a.isRecurring == b.isRecurring
            && a.myResponse == b.myResponse && a.othersAllDeclined == b.othersAllDeclined
            && a.alsoOnCalendarIDs == b.alsoOnCalendarIDs && a.isAllDay == b.isAllDay && a.isAvailabilityOnly == b.isAvailabilityOnly
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(start); hasher.combine(end)
        hasher.combine(coordinate?.latitude); hasher.combine(coordinate?.longitude)
        hasher.combine(address); hasher.combine(isVirtual); hasher.combine(title)
        hasher.combine(eventID); hasher.combine(joinURL); hasher.combine(platform)
        hasher.combine(calendarID); hasher.combine(showsAsFree); hasher.combine(isRecurring)
        hasher.combine(myResponse); hasher.combine(othersAllDeclined); hasher.combine(alsoOnCalendarIDs)
        hasher.combine(isAllDay); hasher.combine(isAvailabilityOnly)
    }
}

/// Raw calendar event fields the timeline needs — the ones `MeetingInfo` throws away (notes,
/// isAllDay). Includes all-day events: a multi-day hotel "Stay" is the location anchor for the
/// days you are not flying.
struct TravelEvent {
    let title: String
    let location: String?
    let notes: String?
    let coordinate: CLLocationCoordinate2D?
    let start: Date
    let end: Date
    let isAllDay: Bool
    let timeZone: TimeZone?
}

/// A content-free view of an existing event, retained alongside the deduped agenda so
/// cross-calendar write-back can reuse coverage from Reclaim or another sync tool.
///
/// `appMarkerScheme` names the Banana variant that wrote the event (`banana`, `banana-beta`,
/// legacy `quarters`), or nil for everything else. For a Google event that is the variant stored
/// in its private extended properties — the same values the EventKit URL marker used, so the
/// ownership rules in `CalendarWriteBackVariant` apply unchanged.
struct CalendarBusyInterval {
    let calendarID: String
    let start: Date
    let end: Date
    let isAppWritten: Bool
    let appMarkerScheme: String?
    let appItemID: String?
}

/// A travel block written by Banana on another device (or a prior install). These are kept
/// out of the normal meeting ingest to avoid mirror loops, but the planner must still defend
/// their time or a Mac could schedule work during a phone-created commute.
struct CalendarSyncedTravelBlock {
    let appItemID: String   // an `AppItemID`; spelled out so this file stands alone
    let title: String
    let start: Date
    let end: Date
}

struct CalendarEventWindow {
    let meetings: [MeetingInfo]
    let busyIntervals: [CalendarBusyInterval]
    let travelEvents: [TravelEvent]
    let syncedTravelBlocks: [CalendarSyncedTravelBlock]
    /// All-day events on the calendars whose all-day events show (`AllDayEvents`), each once.
    var allDayEvents: [MeetingInfo] = []

    static let empty = CalendarEventWindow(
        meetings: [], busyIntervals: [], travelEvents: [], syncedTravelBlocks: [])
}

/// One calendar as the pickers and settings see it.
struct CalendarSourceInfo: Identifiable, Hashable {
    enum Provider: String, Hashable {
        case apple
        case google
    }

    let id: String
    let title: String
    let colorHex: String?
    let sourceID: String
    let sourceTitle: String
    let isDefault: Bool
    let provider: Provider
}

/// A frequent event shape, offered as autocomplete when creating an event.
struct CalendarEventTemplate: Identifiable, Codable, Hashable, Sendable {
    let title: String
    let durationMinutes: Int
    let location: String?
    let structuredLocation: CalendarEventLocation?
    let calendarID: String
    let useCount: Int

    var id: String { title.lowercased() }

    /// The most used titles on writable calendars, each with the shape of its latest occurrence.
    /// Banana's own blocks and all-day events are already absent from `meetings`.
    static func build(from meetings: [MeetingInfo], writableCalendarIDs: Set<String>,
                      limit: Int = 60) -> [CalendarEventTemplate] {
        struct Aggregate {
            var template: CalendarEventTemplate
            var latest: Date
            var count: Int
        }
        var byTitle: [String: Aggregate] = [:]
        for meeting in meetings {
            guard let calendarID = meeting.calendarID, writableCalendarIDs.contains(calendarID),
                  let end = meeting.end, end > meeting.start else { continue }
            let title = meeting.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            let key = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            let template = CalendarEventTemplate(
                title: title,
                durationMinutes: max(15, Int(end.timeIntervalSince(meeting.start) / 60)),
                location: meeting.address,
                structuredLocation: nil,
                calendarID: calendarID,
                useCount: 1)
            if var existing = byTitle[key] {
                existing.count += 1
                if meeting.start > existing.latest {
                    existing.template = template
                    existing.latest = meeting.start
                }
                byTitle[key] = existing
            } else {
                byTitle[key] = Aggregate(template: template, latest: meeting.start, count: 1)
            }
        }
        return byTitle.values
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.latest > $1.latest
            }
            .prefix(limit)
            .map {
                CalendarEventTemplate(
                    title: $0.template.title,
                    durationMinutes: $0.template.durationMinutes,
                    location: $0.template.location,
                    structuredLocation: $0.template.structuredLocation,
                    calendarID: $0.template.calendarID,
                    useCount: $0.count)
            }
    }
}

/// How much of a repeating event an edit applies to.
enum CalendarEditSpan: Equatable {
    case thisEvent
    /// This occurrence and every later one.
    case futureEvents
    /// The whole series.
    case allEvents

    /// Google expresses "this one and the rest" by truncating the series' RRULE, not by deleting
    /// the series — mapping it to the whole series threw away the occurrences being kept.
    ///
    /// A drag's "Move entire series" used to send `futureEvents`, which reached Google as
    /// "this and following" — and a move only ever honoured the whole series, so it moved the
    /// one occurrence. It's `allEvents` now.
    var googleScope: GoogleCalendarEventScope {
        switch self {
        case .thisEvent: return .occurrence
        case .futureEvents: return .thisAndFollowing
        case .allEvents: return .series
        }
    }
}
