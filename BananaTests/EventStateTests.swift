import XCTest

/// Invitation state and merged copies, as they reach the grid.
final class EventStateTests: XCTestCase {
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func event(id: String, summary: String = "Planning", attendees: [[String: Any]] = [],
                       location: String? = nil) -> GoogleEvent {
        var json: [String: Any] = [
            "id": id, "summary": summary, "status": "confirmed",
            "start": ["dateTime": "2026-10-05T15:00:00Z"],
            "end": ["dateTime": "2026-10-05T16:00:00Z"],
        ]
        if !attendees.isEmpty { json["attendees"] = attendees }
        if let location { json["location"] = location }
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(GoogleEvent.self, from: data)
    }

    private func meetings(_ events: [(String, GoogleEvent)]) -> [MeetingInfo] {
        GoogleEventWindowBuilder.window(
            from: events.map { GoogleFetchedEvent(calendarID: $0.0, event: $0.1) }, calendar: utc
        ).meetings
    }

    private func me(_ status: String) -> [String: Any] {
        ["email": "me@example.com", "self": true, "responseStatus": status]
    }

    func testMyReplyIsCarried() {
        XCTAssertEqual(meetings([("a", event(id: "1", attendees: [me("tentative")]))]).first?.myResponse, .tentative)
        XCTAssertEqual(meetings([("a", event(id: "1", attendees: [me("needsAction")]))]).first?.myResponse, .needsAction)
        XCTAssertEqual(meetings([("a", event(id: "1", attendees: [me("accepted")]))]).first?.myResponse, .accepted)
        XCTAssertNil(meetings([("a", event(id: "1"))]).first?.myResponse, "no guest list, no reply")
    }

    func testDeclinedStaysHidden() {
        XCTAssertTrue(meetings([("a", event(id: "1", attendees: [me("declined")]))]).isEmpty)
    }

    func testEveryoneElseDeclined() {
        let declinedGuests: [[String: Any]] = [
            me("accepted"),
            ["email": "a@example.com", "responseStatus": "declined"],
            ["email": "b@example.com", "responseStatus": "declined"],
            // A room never "attends"; it must not keep the warning from showing.
            ["email": "room@resource.calendar.google.com", "responseStatus": "accepted"],
        ]
        XCTAssertEqual(meetings([("a", event(id: "1", attendees: declinedGuests))]).first?.othersAllDeclined, true)

        var oneComing = declinedGuests
        oneComing[2] = ["email": "b@example.com", "responseStatus": "needsAction"]
        XCTAssertEqual(meetings([("a", event(id: "1", attendees: oneComing))]).first?.othersAllDeclined, false)

        XCTAssertEqual(meetings([("a", event(id: "1", attendees: [me("accepted")]))]).first?.othersAllDeclined,
                       false, "alone on the invite is not 'everyone declined'")
    }

    func testDuplicatesMergeWithARibbonPerCalendar() {
        let result = meetings([
            ("work@example.com", event(id: "w", location: "Room 4")),
            ("home@example.com", event(id: "h")),
            ("side@example.com", event(id: "s")),
        ])
        XCTAssertEqual(result.count, 1)
        let merged = try! XCTUnwrap(result.first)
        XCTAssertEqual(merged.address, "Room 4", "the richer copy wins")
        XCTAssertEqual(merged.calendarID, GoogleCalendarIDs.calendarInfoID("work@example.com"))
        XCTAssertEqual(Set(merged.alsoOnCalendarIDs), [
            GoogleCalendarIDs.calendarInfoID("home@example.com"),
            GoogleCalendarIDs.calendarInfoID("side@example.com"),
        ])
    }

    func testTheSameCalendarListedTwiceIsNotASecondRibbon() {
        let result = meetings([("work@example.com", event(id: "w")), ("work@example.com", event(id: "w2"))])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.alsoOnCalendarIDs, [])
    }

    // MARK: Placeholder titles

    func testABusyTitledInvitationIsARealMeeting() {
        // 26 Sep 2026: a "Busy" invite on the personal calendar was dropped as a placeholder,
        // never mirrored, and Calendly booked over it.
        let invite = event(id: "1", summary: "Busy",
                           attendees: [me("accepted"), ["email": "dana@example.com", "responseStatus": "accepted"]])
        XCTAssertEqual(meetings([("personal@gmail.com", invite)]).count, 1)
    }

    func testABusyCopyWithoutGuestsIsStillAPlaceholder() {
        // Another tool's mirror, or a free/busy-only view of someone else's calendar.
        XCTAssertTrue(meetings([("a", event(id: "1", summary: "Busy"))]).isEmpty)
        XCTAssertTrue(meetings([("a", event(id: "1", summary: "Private", attendees: [me("accepted")]))]).isEmpty,
                      "being the only guest is not an invitation")
        XCTAssertTrue(meetings([("a", event(id: "1", summary: "Busy",
            attendees: [me("accepted"), ["email": "room@resource.calendar.google.com"]]))]).isEmpty,
                      "a room is not a guest")
    }

    func testADeclinedBusyInvitationStaysHidden() {
        let invite = event(id: "1", summary: "Busy",
                           attendees: [me("declined"), ["email": "dana@example.com"]])
        XCTAssertTrue(meetings([("a", invite)]).isEmpty)
    }

    func testABusyInvitationBeatsAPlaceholderCopyInTheSameSlot() {
        let result = meetings([
            ("work@example.com", event(id: "copy", summary: "Busy")),
            ("personal@gmail.com", event(id: "real", summary: "Busy",
                attendees: [me("accepted"), ["email": "dana@example.com"]])),
        ])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.calendarID, GoogleCalendarIDs.calendarInfoID("personal@gmail.com"))
    }

    func testNewFieldsSurviveTheSnapshotAndOldSnapshotsStillDecode() throws {
        var meeting = MeetingInfo(start: Date(timeIntervalSince1970: 0), end: nil, coordinate: nil,
                                  address: nil, isVirtual: false, title: "x")
        meeting.myResponse = .tentative
        meeting.othersAllDeclined = true
        meeting.alsoOnCalendarIDs = ["google:b"]
        let round = try JSONDecoder().decode(MeetingInfo.self, from: JSONEncoder().encode(meeting))
        XCTAssertEqual(round, meeting)

        let old = #"{"start":0,"isVirtual":false,"title":"x"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(MeetingInfo.self, from: old)
        XCTAssertNil(decoded.myResponse)
        XCTAssertFalse(decoded.othersAllDeclined)
        XCTAssertEqual(decoded.alsoOnCalendarIDs, [])
    }
}
