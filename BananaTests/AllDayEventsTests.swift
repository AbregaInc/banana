import XCTest

/// All-day events (`AllDayEvents`, docs/design/ALL-DAY-EVENTS.md): one shows if it's yours, and
/// blocks its day if your copy says Busy. Tested against Calendar API payload shapes.
final class AllDayEventsTests: XCTestCase {
    private let newYork: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    private func day(_ value: String) -> Date {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        return newYork.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))!
    }

    /// An all-day Google event as the API sends it, decoded through the real model.
    private func allDayEvent(id: String, summary: String = "Sam & Ana Fun Day Trip",
                             from start: String = "2026-10-10", to end: String = "2026-10-11",
                             transparency: String? = "transparent", eventType: String? = "default",
                             myResponse: String? = "accepted", ownedBy variant: String? = nil) -> GoogleEvent {
        var json: [String: Any] = ["id": id, "summary": summary, "status": "confirmed",
                                   "start": ["date": start], "end": ["date": end]]
        if let transparency { json["transparency"] = transparency }
        if let eventType { json["eventType"] = eventType }
        if let myResponse {
            json["attendees"] = [["email": "bbaker@gmail.example", "self": true, "responseStatus": myResponse],
                                 ["email": "cbaker@gmail.example", "organizer": true, "responseStatus": "accepted"]]
        }
        if let variant {
            json["extendedProperties"] = ["private": [GoogleBusyBlocks.variantKey: variant,
                                                      GoogleBusyBlocks.itemIDKey: "mirror-\(id)"]]
        }
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(GoogleEvent.self, from: data)
    }

    private func window(_ events: [(String, GoogleEvent)], shown: Set<String>,
                        choice: AllDayEvents.Choice = .init()) -> CalendarEventWindow {
        GoogleEventWindowBuilder.window(from: events.map { GoogleFetchedEvent(calendarID: $0.0, event: $0.1) },
                                        calendar: newYork, allDayCalendarIDs: shown, allDayChoice: choice)
    }

    // MARK: - Which show

    func testYoursShowUnlessHiddenOthersOnlyWhenShown() {
        XCTAssertTrue(AllDayEvents.shows(calendarID: "me", isOwner: true, hidden: [], shown: []))
        XCTAssertFalse(AllDayEvents.shows(calendarID: "me", isOwner: true, hidden: ["me"], shown: []))
        XCTAssertFalse(AllDayEvents.shows(calendarID: "launches", isOwner: false, hidden: [], shown: []))
        XCTAssertTrue(AllDayEvents.shows(calendarID: "launches", isOwner: false, hidden: [], shown: ["launches"]))
    }

    func testWorkingLocationIsAStatusNotAnEvent() {
        XCTAssertFalse(AllDayEvents.isEvent(eventType: "workingLocation"))
        XCTAssertTrue(AllDayEvents.isEvent(eventType: "default"))
        XCTAssertTrue(AllDayEvents.isEvent(eventType: "birthday"))
        XCTAssertTrue(AllDayEvents.isEvent(eventType: nil))
    }

    func testAnEventCoversEachOfItsDaysEvenAcrossTheClockChange() {
        XCTAssertEqual(AllDayEvents.days(from: day("2026-10-10"), to: day("2026-10-11"), calendar: newYork), [day("2026-10-10")])
        // Clocks go back on Sunday 1 November: still three days, each starting at midnight.
        XCTAssertEqual(AllDayEvents.days(from: day("2026-10-31"), to: day("2026-11-03"), calendar: newYork),
                       [day("2026-10-31"), day("2026-11-01"), day("2026-11-02")])
    }

    // MARK: - What the calendar read makes of them

    func testAnAcceptedAllDayInviteShowsButAFreeOneBlocksNothing() throws {
        let result = window([("bbaker@gmail.example", allDayEvent(id: "trip"))], shown: ["bbaker@gmail.example"])
        let trip = try XCTUnwrap(result.allDayEvents.first)
        XCTAssertEqual(result.allDayEvents.count, 1)
        XCTAssertTrue(trip.isAllDay)
        XCTAssertTrue(trip.showsAsFree, "Google made it Free: it shows, it blocks nothing")
        XCTAssertEqual(trip.start, day("2026-10-10"))
        XCTAssertEqual(trip.end, day("2026-10-11"))
        XCTAssertEqual(trip.myResponse, .accepted)
        XCTAssertTrue(result.meetings.isEmpty, "never a meeting: wake plans and travel stay timed-only")
        XCTAssertTrue(result.busyIntervals.isEmpty)
    }

    func testABusyAllDayEventBlocksItsWholeDay() throws {
        let result = window([("bbaker@gmail.example", allDayEvent(id: "trip", transparency: nil))],
                            shown: ["bbaker@gmail.example"])
        XCTAssertEqual(result.allDayEvents.first?.showsAsFree, false)
        let busy = try XCTUnwrap(result.busyIntervals.first)
        XCTAssertEqual(result.busyIntervals.count, 1)
        XCTAssertEqual(busy.start, day("2026-10-10"))
        XCTAssertEqual(busy.end, day("2026-10-11"))
    }

    func testAHiddenCalendarsAllDayEventsNeitherShowNorBlock() {
        let result = window([("launches@group.calendar.google.com", allDayEvent(id: "launch", transparency: nil))],
                            shown: ["bbaker@gmail.example"])
        XCTAssertTrue(result.allDayEvents.isEmpty)
        XCTAssertTrue(result.busyIntervals.isEmpty)
    }

    func testHomeAndDeclinedNeverShow() {
        let result = window([("bo@acme.example", allDayEvent(id: "home", summary: "Home", eventType: "workingLocation",
                                                              myResponse: nil)),
                             ("bbaker@gmail.example", allDayEvent(id: "no", myResponse: "declined"))],
                            shown: ["bo@acme.example", "bbaker@gmail.example"])
        XCTAssertTrue(result.allDayEvents.isEmpty)
    }

    func testBananasOwnCopyOfABlockedDayIsCoverageNotAnEvent() {
        let copy = allDayEvent(id: "copy", summary: "Busy", transparency: nil, myResponse: nil,
                               ownedBy: "banana")
        let result = window([("bo@dewey.example", copy)], shown: ["bo@dewey.example"])
        XCTAssertTrue(result.allDayEvents.isEmpty, "Banana's copy never shows as an event of its own")
        XCTAssertEqual(result.busyIntervals.count, 1)
        XCTAssertTrue(result.busyIntervals[0].isAppWritten)
    }

    func testTheSameInviteOnTwoCalendarsShowsOnce() {
        let result = window([("bbaker@gmail.example", allDayEvent(id: "a")),
                             ("bo@zeta.example", allDayEvent(id: "b"))],
                            shown: ["bbaker@gmail.example", "bo@zeta.example"])
        XCTAssertEqual(result.allDayEvents.count, 1)
        XCTAssertEqual(result.allDayEvents.first?.alsoOnCalendarIDs.count, 1)
    }

    /// Timeline items are cached on disk: an all-day event must come back one, not as a meeting
    /// at midnight.
    func testTheAllDayMarkSurvivesTheCache() throws {
        let trip = MeetingInfo(start: day("2026-10-10"), end: day("2026-10-11"), isVirtual: false,
                               title: "Sam & Ana Fun Day Trip", eventID: "g:trip", showsAsFree: false, isAllDay: true)
        let back = try JSONDecoder().decode(MeetingInfo.self, from: JSONEncoder().encode(trip))
        XCTAssertTrue(back.isAllDay)
        XCTAssertEqual(back, trip)
        let meeting = MeetingInfo(start: day("2026-10-10"), isVirtual: true, title: "Standup")
        XCTAssertFalse(try JSONDecoder().decode(MeetingInfo.self, from: JSONEncoder().encode(meeting)).isAllDay)
        XCTAssertNotEqual(trip, MeetingInfo(start: trip.start, end: trip.end, isVirtual: false, title: trip.title,
                                            eventID: trip.eventID, showsAsFree: false))
    }

    // MARK: - Hiding

    /// A birthday can't be deleted (Google Contacts owns it): hidden by title, it's gone every
    /// year, and a hidden event never blocks a day either.
    func testAHiddenTitleNeitherShowsNorBlocks() {
        let birthday = allDayEvent(id: "b", summary: "Sergio Nunez\u{2019}s birthday", eventType: "birthday", myResponse: nil)
        let trip = allDayEvent(id: "t", transparency: nil)
        var choice = AllDayEvents.Choice()
        choice.hiddenTitles = [AllDayEvents.titleKey("  Sergio Nunez\u{2019}s Birthday ")]
        choice.hiddenTitles.insert(AllDayEvents.titleKey("Sam & Ana Fun Day Trip"))
        let result = window([("bbaker@gmail.example", birthday), ("bbaker@gmail.example", trip)],
                            shown: ["bbaker@gmail.example"], choice: choice)
        XCTAssertTrue(result.allDayEvents.isEmpty)
        XCTAssertTrue(result.busyIntervals.isEmpty, "a hidden Busy event blocks nothing")
    }

    func testTheBirthdaysSwitchHidesOnlyBirthdays() {
        let birthday = allDayEvent(id: "b", summary: "Yev Spektor\u{2019}s birthday", eventType: "birthday", myResponse: nil)
        let trip = allDayEvent(id: "t")
        var choice = AllDayEvents.Choice()
        choice.showsBirthdays = false
        let result = window([("bbaker@gmail.example", birthday), ("bbaker@gmail.example", trip)],
                            shown: ["bbaker@gmail.example"], choice: choice)
        XCTAssertEqual(result.allDayEvents.map(\.title), ["Sam & Ana Fun Day Trip"])
        XCTAssertTrue(AllDayEvents.isHidden(title: "Anything", eventType: "birthday", choice: choice))
        XCTAssertFalse(AllDayEvents.isHidden(title: "Anything", eventType: "default", choice: choice))
    }

    // MARK: - A crowded day

    func testWhatBlocksTheDayComesFirstAndTheRestKeepTheirOrder() {
        struct Event: Equatable { let title: String; let busy: Bool }
        let day = [Event(title: "Sergio's birthday", busy: false), Event(title: "Day trip", busy: true),
                   Event(title: "Rosh Hashanah", busy: false), Event(title: "Out of office", busy: true),
                   Event(title: "Bins out", busy: false)]
        let ordered = AllDayEvents.busyFirst(day, blocks: \.busy)
        XCTAssertEqual(ordered.map(\.title), ["Day trip", "Out of office", "Sergio's birthday", "Rosh Hashanah", "Bins out"])

        // Where two fit, both are the ones that block: neither is behind "+3 more".
        let fitting = AllDayEvents.fitting(ordered, limit: 2)
        XCTAssertEqual(fitting.shown.map(\.busy), [true, true])
        XCTAssertEqual(fitting.more, 3)
    }

    func testAnAllDayEventsTimeIsAllDayNotMidnightToMidnight() {
        XCTAssertEqual(AllDayEvents.timeText(from: day("2026-10-05"), to: day("2026-10-06")), "All day")
        XCTAssertEqual(AllDayEvents.timeText(from: day("2026-10-06"), to: day("2026-10-08")), "All day \u{00B7} 2 days")
        XCTAssertEqual(AllDayEvents.timeText(from: day("2026-10-05"), to: nil), "All day")
    }

    func testADayThatFitsHasNothingBehindMore() {
        XCTAssertEqual(AllDayEvents.fitting(["a", "b"], limit: 2).more, 0)
        XCTAssertEqual(AllDayEvents.fitting(["a", "b"], limit: 2).shown, ["a", "b"])
        XCTAssertEqual(AllDayEvents.fitting([String](), limit: 2).shown, [])
        XCTAssertEqual(AllDayEvents.busyFirst(["a", "b"], blocks: { _ in false }), ["a", "b"])
    }

    // MARK: - Writing a blocked day's copy

    func testABlockedDaysCopyIsWrittenAsAnAllDayEvent() throws {
        let body = GoogleBusyBlocks.body(title: "Busy", start: day("2026-10-10"), end: day("2026-10-11"),
                                         timeZoneID: "America/New_York", appItemID: "mirror-1",
                                         variant: "banana", isAllDay: true)
        let start = try XCTUnwrap(body["start"] as? [String: Any])
        let end = try XCTUnwrap(body["end"] as? [String: Any])
        XCTAssertEqual(start["date"] as? String, GoogleCalendarDates.dateString(day("2026-10-10")))
        XCTAssertEqual(end["date"] as? String, GoogleCalendarDates.dateString(day("2026-10-11")))
        XCTAssertTrue(start["dateTime"] is NSNull, "cleared, so a PATCH can't leave a time behind")
        XCTAssertEqual(body["transparency"] as? String, "opaque")
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: body))

        let timed = GoogleBusyBlocks.body(title: "Busy", start: day("2026-10-10"), end: day("2026-10-11"),
                                          timeZoneID: "America/New_York", appItemID: "mirror-1", variant: "banana")
        XCTAssertNotNil((timed["start"] as? [String: Any])?["dateTime"] as? String)
    }
}
