import Foundation

/// The calendar's event behind an invitation email (MAIL-UX 9.1): found by the calendar's own
/// lookup of the invitation's identifier (`GoogleEvent.iCalUID`), never read from the file the
/// sender attached. Everything the card says, and the answer it sends, is the calendar's.
struct MailInviteEvent: Equatable, Sendable {
    var calendarID: String
    var eventID: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    /// His answer so far; nil while he has not answered.
    var response: GoogleCalendarRSVP?

    /// The id the calendar's own reply path takes (`InvitationReply`, `MeetingInfo.eventID`).
    var infoID: String { GoogleCalendarIDs.eventInfoID(calendarID: calendarID, eventID: eventID) }

    init(calendarID: String, eventID: String, title: String, start: Date, end: Date, isAllDay: Bool,
         response: GoogleCalendarRSVP?) {
        self.calendarID = calendarID
        self.eventID = eventID
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.response = response
    }

    /// An event he is a guest on; nil for one he isn't on (nothing to answer), or one without a time.
    init?(_ event: GoogleEvent, calendarID: String) {
        guard let id = event.id, event.status != "cancelled",
              let me = event.attendees?.first(where: { $0.selfAttendee == true }),
              let range = GoogleCalendarDates.range(of: event) else { return nil }
        self.calendarID = calendarID
        eventID = id
        title = event.summary ?? ""
        start = range.start
        end = range.end
        isAllDay = range.isAllDay
        response = me.responseStatus.flatMap(GoogleCalendarRSVP.init(rawValue:))
    }

    /// Of the events carrying the identifier (a series, or a series and the instances it has
    /// changed), the one an invitation answers: the series itself, else the first.
    static func pick(_ events: [GoogleEvent], calendarID: String) -> MailInviteEvent? {
        let found = events.filter { $0.recurringEventId == nil } + events.filter { $0.recurringEventId != nil }
        return found.lazy.compactMap { MailInviteEvent($0, calendarID: calendarID) }.first
    }
}
