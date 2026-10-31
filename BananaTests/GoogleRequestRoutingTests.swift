import XCTest

/// Choosing which connected Google account a request belongs to.
///
/// With several accounts connected, a request made with the wrong credential fails or — worse —
/// silently addresses a calendar the token cannot see. The calendar id is already in the URL, so
/// this is what keeps every call site honest without threading an account through all of them.
final class GoogleRequestRoutingTests: XCTestCase {
    private typealias R = GoogleRequestRouting

    private func url(_ string: String) -> URL { URL(string: string)! }

    func testTheCalendarIsReadFromAPerCalendarEndpoint() {
        XCTAssertEqual(
            R.calendarID(fromRequestURL: url(
                "https://www.googleapis.com/calendar/v3/calendars/bo@zeta.example/events")),
            "bo@zeta.example")
    }

    func testAPercentEncodedCalendarIdIsDecoded() {
        XCTAssertEqual(
            R.calendarID(fromRequestURL: url(
                "https://www.googleapis.com/calendar/v3/calendars/abc%40group.calendar.google.com/events/xyz")),
            "abc@group.calendar.google.com")
    }

    func testAnEventPathStillResolvesToItsCalendar() {
        XCTAssertEqual(
            R.calendarID(fromRequestURL: url(
                "https://www.googleapis.com/calendar/v3/calendars/bbaker%40gmail.example/events/evt123?sendUpdates=all")),
            "bbaker@gmail.example")
    }

    /// The calendar list is per-account, not per-calendar — it has to be addressed by credential
    /// explicitly, so returning nil here is what forces the caller to pass one.
    func testTheCalendarListEndpointHasNoCalendar() {
        XCTAssertNil(R.calendarID(fromRequestURL: url(
            "https://www.googleapis.com/calendar/v3/users/me/calendarList")))
        XCTAssertNil(R.calendarID(fromRequestURL: url(
            "https://www.googleapis.com/calendar/v3/users/me/calendarList?pageToken=abc")))
    }

    func testAnUnrelatedURLYieldsNothing() {
        XCTAssertNil(R.calendarID(fromRequestURL: url("https://oauth2.googleapis.com/token")))
        XCTAssertNil(R.calendarID(fromRequestURL: url("https://www.googleapis.com/calendar/v3/calendars")))
    }
}
