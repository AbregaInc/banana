import XCTest

final class GoogleMeetCreationTests: XCTestCase {
    func testCalendarCapabilityComesFromGoogleAndRequiresWriteAccess() throws {
        func calendar(_ role: String, _ capabilities: String) throws -> GoogleCalendar {
            try JSONDecoder().decode(GoogleCalendar.self, from: Data("""
            {"id":"calendar@example.com","accessRole":"\(role)","conferenceProperties":{"allowedConferenceSolutionTypes":\(capabilities)}}
            """.utf8))
        }
        XCTAssertTrue(try calendar("owner", "[\"hangoutsMeet\"]").supportsGoogleMeet)
        XCTAssertTrue(try calendar("writer", "[\"hangoutsMeet\"]").supportsGoogleMeet)
        XCTAssertFalse(try calendar("reader", "[\"hangoutsMeet\"]").supportsGoogleMeet)
        XCTAssertFalse(try calendar("owner", "[]").supportsGoogleMeet)
        XCTAssertFalse(try JSONDecoder().decode(GoogleCalendar.self, from: Data("{\"id\":\"legacy\",\"accessRole\":\"owner\"}".utf8)).supportsGoogleMeet)
    }

    func testMeetRequestSurvivesDurableDraftAndLegacyDraftsStillDecode() throws {
        let id = UUID()
        let input = CalendarEventInput(title: "Meeting", start: Date(), end: Date().addingTimeInterval(3600),
                                       isAllDay: false, availability: .busy, googleMeetRequestID: id)
        let encoded = try JSONEncoder().encode(input)
        XCTAssertEqual(try JSONDecoder().decode(CalendarEventInput.self, from: encoded).googleMeetRequestID, id)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "googleMeetRequestID")
        let decoded = try JSONDecoder().decode(CalendarEventInput.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(decoded.googleMeetRequestID)
    }

    func testConferenceStatusDecodesWithoutRequiringItOnOlderEvents() throws {
        let event = try JSONDecoder().decode(GoogleEvent.self, from: Data("""
        {"id":"event","conferenceData":{"createRequest":{"status":{"statusCode":"pending"}}}}
        """.utf8))
        XCTAssertEqual(event.conferenceData?.createRequest?.status?.statusCode, "pending")
        let old = try JSONDecoder().decode(GoogleEvent.self, from: Data("{\"id\":\"event\",\"conferenceData\":{}}".utf8))
        XCTAssertNil(old.conferenceData?.createRequest)
    }

    func testRetryReusesSameEventIdentityAndRejectsDifferentPayload() throws {
        let operation = UUID()
        var body: [String: Any] = ["summary": "Meeting", "conferenceData": GoogleMeetCreation.conference(requestID: operation)]
        var retry = body
        let receipt = try AssistantCalendarIdentity.attach(to: &body, operation: operation)
        let retryReceipt = try AssistantCalendarIdentity.attach(to: &retry, operation: operation)
        XCTAssertEqual(body["id"] as? String, retry["id"] as? String)
        XCTAssertTrue(AssistantCalendarIdentity.matches(receipt, receipt: retryReceipt))
        retry.removeValue(forKey: "extendedProperties")
        retry["summary"] = "Different meeting"
        let other = try AssistantCalendarIdentity.attach(to: &retry, operation: operation)
        XCTAssertFalse(AssistantCalendarIdentity.matches(receipt, receipt: other))
    }
}
