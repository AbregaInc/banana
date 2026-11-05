import XCTest

final class CloudCalendarSnapshotTests: XCTestCase {
    private func payload(version: Int = 1, unavailable: [[String: Any]] = []) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "version": version, "from": 1000, "to": 2000,
            "sources": [["email": "Noor@plan.example", "calendar": ["id": "owned", "accessRole": "owner", "primary": true],
                         "events": [["id": "event", "etag": "revision", "reminders": ["useDefault": true]]]],
                        ["email": "noor@plan.example", "calendar": ["id": "empty", "accessRole": "reader"], "events": []]],
            "unavailable": unavailable,
        ])
    }

    func testPreservesProviderFieldsAndSuccessfulEmptyCalendar() throws {
        let result = try CloudCalendarSnapshot.decode(payload(), from: 1000, to: 2000)
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.coveredCalendarIDs, ["owned", "empty"])
        XCTAssertEqual(result.sources[0].events[0].etag, "revision")
        XCTAssertEqual(result.sources[0].events[0].reminders?.useDefault, true)
        XCTAssertEqual(result.sources[0].ownedCalendar.accountEmail, "noor@plan.example")
        XCTAssertTrue(result.sources[0].ownedCalendar.isOwnedByAccount)
    }

    func testPartialFailureCannotBecomeSuccessfulEmptyCalendar() throws {
        let result = try CloudCalendarSnapshot.decode(payload(unavailable: [[
            "email": "noor@plan.example", "calendarID": "failed", "reason": "retry",
        ]]), from: 1000, to: 2000)
        XCTAssertFalse(result.isComplete)
        XCTAssertFalse(result.coveredCalendarIDs.contains("failed"))
        XCTAssertThrowsError(try CloudCalendarSnapshot.decode(payload(unavailable: [[
            "email": "noor@plan.example", "calendarID": "owned", "reason": "retry",
        ]]), from: 1000, to: 2000))
    }

    func testRejectsUnexpectedVersionOrWindow() throws {
        XCTAssertThrowsError(try CloudCalendarSnapshot.decode(payload(version: 2), from: 1000, to: 2000))
        XCTAssertThrowsError(try CloudCalendarSnapshot.decode(payload(), from: 1000, to: 3000))
    }

    func testRejectsUnboundedAndInvalidDatesBeforeRequest() throws {
        let start = Date(timeIntervalSince1970: 1)
        XCTAssertThrowsError(try CloudCalendarSnapshot.bounds(from: start, to: start))
        XCTAssertThrowsError(try CloudCalendarSnapshot.bounds(from: start, to: start.addingTimeInterval(9 * 86400)))
        XCTAssertThrowsError(try CloudCalendarSnapshot.bounds(from: Date(timeIntervalSince1970: .nan), to: start))
        let valid = try CloudCalendarSnapshot.bounds(from: start, to: start.addingTimeInterval(86400))
        XCTAssertEqual(valid.from, 1000)
        XCTAssertEqual(valid.to, 86_401_000)
    }

    func testRequestUsesBananaSessionAndFixedServiceRoute() {
        let request = BananaService.request(.calendarSnapshot(from: 1000, to: 2000), host: "service.example", session: "session")
        XCTAssertEqual(request.url?.absoluteString, "https://service.example/v1/calendar/snapshot?from=1000&to=2000")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer session")
        XCTAssertNil(request.httpBody)
    }
}
