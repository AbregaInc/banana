import XCTest

/// The event behind an invitation email is the calendar's (MAIL-UX 9.1): found by its identifier,
/// answered only when he is a guest, and the series rather than one of its changed instances.
final class MailInviteEventTests: XCTestCase {
    private func event(_ json: String) throws -> GoogleEvent {
        try JSONDecoder().decode(GoogleEvent.self, from: Data(json.utf8))
    }

    private let guest = #"""
    {"id":"ev1","iCalUID":"uid-1@plan.example","status":"confirmed","summary":"Design review",
     "start":{"dateTime":"2026-11-11T09:00:00-05:00"},"end":{"dateTime":"2026-11-11T09:30:00-05:00"},
     "attendees":[{"email":"ann@plan.example","organizer":true,"responseStatus":"accepted"},
                  {"email":"noor@plan.example","self":true,"responseStatus":"needsAction"}]}
    """#

    func testAGuestsEventCarriesItsTimeAndNoAnswerYet() throws {
        let found = try XCTUnwrap(MailInviteEvent(try event(guest), calendarID: "noor@plan.example"))
        XCTAssertEqual(found.title, "Design review")
        XCTAssertEqual(found.eventID, "ev1")
        XCTAssertEqual(found.end.timeIntervalSince(found.start), 30 * 60)
        XCTAssertFalse(found.isAllDay)
        XCTAssertNil(found.response, "needsAction is not an answer")
        XCTAssertEqual(GoogleCalendarIDs.rawEventRoute(from: found.infoID)?.eventID, "ev1")
        XCTAssertEqual(GoogleCalendarIDs.rawEventRoute(from: found.infoID)?.calendarID, "noor@plan.example")
    }

    func testTheAnswerSoFarIsRead() throws {
        let answered = guest.replacingOccurrences(of: #""self":true,"responseStatus":"needsAction""#, with: #""self":true,"responseStatus":"tentative""#)
        XCTAssertEqual(MailInviteEvent(try event(answered), calendarID: "c")?.response, .tentative)
    }

    func testNothingToAnswerWhenHeIsNotAGuestOrItWasCancelled() throws {
        let notGuest = guest.replacingOccurrences(of: #""self":true,"#, with: "")
        XCTAssertNil(MailInviteEvent(try event(notGuest), calendarID: "c"))
        let cancelled = guest.replacingOccurrences(of: #""status":"confirmed""#, with: #""status":"cancelled""#)
        XCTAssertNil(MailInviteEvent(try event(cancelled), calendarID: "c"))
    }

    func testTheSeriesIsAnsweredRatherThanAChangedInstance() throws {
        let instance = guest.replacingOccurrences(of: #""id":"ev1""#, with: #""id":"ev1_20261118","recurringEventId":"ev1""#)
        let picked = MailInviteEvent.pick([try event(instance), try event(guest)], calendarID: "c")
        XCTAssertEqual(picked?.eventID, "ev1")
        XCTAssertNil(MailInviteEvent.pick([], calendarID: "c"))
    }
}
