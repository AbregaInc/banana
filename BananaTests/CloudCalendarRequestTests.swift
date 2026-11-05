import XCTest

final class CloudCalendarRequestTests: XCTestCase {
    func testEncodedCalendarAndEventIDsStaySeparateFromPaths() throws {
        let request = try CloudCalendarRequest(url: XCTUnwrap(URL(string: "https://www.googleapis.com/calendar/v3/calendars/a%2Fb%40plan.example/events/event%2Fid?maxResults=50&q=caf%C3%A9%20%26%20work")), email: "Noor@plan.example")
        XCTAssertEqual(request.resource, "event")
        XCTAssertEqual(request.calendarID, "a/b@plan.example")
        XCTAssertEqual(request.eventID, "event/id")
        XCTAssertEqual(request.email, "noor@plan.example")
        XCTAssertEqual(request.query.last?.value, "café & work")
    }
    func testOnlyKnownCalendarReadResourcesAreAccepted() throws {
        let examples = [("users/me/calendarList", "calendarList"), ("calendars/work/events", "events"),
                        ("calendars/work/events/event/instances", "instances")]
        for (path, resource) in examples {
            XCTAssertEqual(try CloudCalendarRequest(url: XCTUnwrap(URL(string: "https://www.googleapis.com/calendar/v3/" + path)), email: "noor@plan.example").resource, resource)
        }
        for text in ["https://evil.example/calendar/v3/calendars/work/events", "http://www.googleapis.com/calendar/v3/calendars/work/events",
                     "https://www.googleapis.com/calendar/v3/calendars/work/events/event/move", "https://www.googleapis.com/gmail/v1/users/me/messages",
                     "https://user@www.googleapis.com/calendar/v3/calendars/work/events"] {
            XCTAssertThrowsError(try CloudCalendarRequest(url: XCTUnwrap(URL(string: text)), email: "noor@plan.example"))
        }
    }
    func testReadEnvelopeContainsNoGoogleCredentialOrArbitraryURL() throws {
        let read = try CloudCalendarRequest(url: XCTUnwrap(URL(string: "https://www.googleapis.com/calendar/v3/calendars/work/events?syncToken=banana-calendar%3Acursor")), email: "noor@plan.example")
        let request = BananaService.request(.calendarRead(read), host: "service.example", session: "banana-session")
        XCTAssertEqual(request.url?.absoluteString, "https://service.example/v1/calendar/read")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer banana-session")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(json["resource"] as? String, "events")
        XCTAssertNil(json["url"])
        XCTAssertNil(json["token"])
    }
    func testProviderCursorCannotCrossReadModes() {
        let direct = GoogleCalendarReadAuthorization.direct("token")
        let cloud = GoogleCalendarReadAuthorization.cloud(email: "noor@plan.example", context: "session")
        XCTAssertTrue(direct.accepts(cursor: "google-token"))
        XCTAssertFalse(direct.accepts(cursor: "banana-calendar:cursor"))
        XCTAssertFalse(cloud.accepts(cursor: "google-token"))
        XCTAssertTrue(cloud.accepts(cursor: "banana-calendar:cursor"))
    }
}
