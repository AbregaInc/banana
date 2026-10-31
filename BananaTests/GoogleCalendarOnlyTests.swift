import XCTest

// The Google-only calendar layer, tested against real Calendar API payload shapes.
//
// These are the decisions that, when wrong, cost real availability: whether a block Banana wrote
// reads back as a meeting (and gets mirrored again), whether an unreadable calendar can justify a
// removal, whether a colleague's calendar receives blocks, and whether an Apple Calendar exclusion
// survives the move to Google.

// MARK: - Fixtures

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

/// One Google event, built as the API would send it and decoded through the real model.
private func googleEvent(
    id: String,
    summary: String? = "Meeting",
    start: String = "2026-10-05T15:00:00Z",
    end: String = "2026-10-05T16:00:00Z",
    allDay: (start: String, end: String)? = nil,
    location: String? = nil,
    description: String? = nil,
    hangoutLink: String? = nil,
    transparency: String? = nil,
    status: String? = "confirmed",
    declined: Bool = false,
    attendees: Int = 0,
    ownedBy variant: String? = nil,
    itemID: String? = nil,
    iCalUID: String? = nil,
    originalStart: String? = nil
) -> GoogleEvent {
    var json: [String: Any] = ["id": id]
    if let summary { json["summary"] = summary }
    if let allDay {
        json["start"] = ["date": allDay.start]
        json["end"] = ["date": allDay.end]
    } else {
        json["start"] = ["dateTime": start, "timeZone": "America/New_York"]
        json["end"] = ["dateTime": end, "timeZone": "America/New_York"]
    }
    if let location { json["location"] = location }
    if let description { json["description"] = description }
    if let hangoutLink { json["hangoutLink"] = hangoutLink }
    if let transparency { json["transparency"] = transparency }
    if let status { json["status"] = status }
    if let iCalUID { json["iCalUID"] = iCalUID }
    if let originalStart {
        json["originalStartTime"] = ["dateTime": originalStart]
        json["recurringEventId"] = "series-id"
    }
    var people: [[String: Any]] = (0..<attendees).map { ["email": "guest\($0)@example.com"] }
    if declined { people.append(["email": "me@example.com", "self": true, "responseStatus": "declined"]) }
    if !people.isEmpty { json["attendees"] = people }
    if let variant {
        json["extendedProperties"] = ["private": [
            GoogleBusyBlocks.variantKey: variant,
            GoogleBusyBlocks.itemIDKey: itemID ?? "item-\(id)",
        ]]
    }
    let data = try! JSONSerialization.data(withJSONObject: json)
    return try! JSONDecoder().decode(GoogleEvent.self, from: data)
}

private func window(_ events: [(calendar: String, event: GoogleEvent)]) -> CalendarEventWindow {
    GoogleEventWindowBuilder.window(
        from: events.map { GoogleFetchedEvent(calendarID: $0.calendar, event: $0.event) },
        calendar: utc)
}

// MARK: - What a Google event means

final class GoogleEventWindowTests: XCTestCase {
    func testReconciliationReportPreservesLinkageWithoutPersonalDetails() throws {
        let calendars = try JSONDecoder().decode([GoogleCalendar].self, from: Data("""
        [{"id":"private-calendar-id","summary":"Private calendar name","accessRole":"reader","dataOwner":"owner@example.com"},
         {"id":"mirror-calendar-id","accessRole":"reader","dataOwner":"owner@example.com"}]
        """.utf8))
        let original = googleEvent(id: "secret-event-id", summary: "Dinner", location: "Secret restaurant", description: "Secret notes", iCalUID: "secret-uid")
        let events = [GoogleFetchedEvent(calendarID: "private-calendar-id", event: original),
                      GoogleFetchedEvent(calendarID: "mirror-calendar-id", event: googleEvent(id: "secret-mirror-id", summary: "Busy", ownedBy: "banana", itemID: dinnerMirror))]
        let report = GoogleEventWindowBuilder.reconciliationReport(events, calendars: calendars)
        let rows = report.components(separatedBy: "\n").filter { $0.contains("calendar=") }
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.contains("owner=p1") && $0.contains("mirror=m1") })
        for secret in ["Dinner", "Secret restaurant", "Secret notes", "owner@example.com", "secret-uid", "secret-event-id", "private-calendar-id", dinnerMirror] {
            XCTAssertFalse(report.contains(secret), "support text must omit \(secret)")
        }
    }

    func testReconciliationReportDistinguishesRedactionUnknownOwnerAndUnrelatedIntervals() throws {
        let calendars = try JSONDecoder().decode([GoogleCalendar].self, from: Data("""
        [{"id":"shared-calendar","accessRole":"reader"}]
        """.utf8))
        let report = GoogleEventWindowBuilder.reconciliationReport([
            .init(calendarID: "shared-calendar", event: googleEvent(id: "redacted", summary: "Busy")),
            .init(calendarID: "shared-calendar", event: googleEvent(id: "unrelated", summary: "PRIVATE FUTURE TITLE", start: "2026-10-06T15:00:00Z", end: "2026-10-06T16:00:00Z"))
        ], calendars: calendars)
        XCTAssertTrue(report.contains("owner=missing availability=true free=false uid=missing mirror=missing marker=false"))
        XCTAssertFalse(report.contains("2026-10-06"))
        XCTAssertFalse(report.contains("PRIVATE FUTURE TITLE"))
    }

    private func sharedWindow(_ events: [(String, GoogleEvent)], owners: [String: String]) -> CalendarEventWindow {
        GoogleEventWindowBuilder.window(from: events.map { GoogleFetchedEvent(calendarID: $0.0, event: $0.1) },
                                        calendar: utc, ownedCalendarIDs: ["me"], calendarOwners: owners)
    }

    private var dinnerMirror: String {
        let dinner = GoogleEventWindowBuilder.normalize(.init(calendarID: "personal", event: googleEvent(id: "d", summary: "Dinner")))!
        return GoogleBusyBlocks.mirrorID(title: dinner.title, start: dinner.start, end: dinner.end)
    }

    func testSharedMirrorFoldsIntoVisibleDinnerKeepingEveryCalendarAndRawCoverage() {
        let events = [("me", googleEvent(id: "invite", summary: "Dinner", location: "Restaurant", iCalUID: "dinner-uid")),
                      ("personal", googleEvent(id: "dinner", summary: "Dinner", iCalUID: "dinner-uid")),
                      ("fitness", googleEvent(id: "busy", summary: "Busy", ownedBy: "banana", itemID: dinnerMirror)),
                      ("work", googleEvent(id: "busy-2", summary: "Busy", ownedBy: "banana-beta", itemID: dinnerMirror))]
        let result = sharedWindow(events, owners: ["me": "viewer@example.com", "personal": "owner@example.com", "fitness": "owner@example.com", "work": "owner@example.com"])
        XCTAssertEqual(result.meetings.count, 1)
        XCTAssertEqual(result.meetings.first?.title, "Dinner")
        XCTAssertEqual(result.meetings.first?.address, "Restaurant")
        XCTAssertEqual(Set(result.meetings.first!.alsoOnCalendarIDs), Set(["personal", "fitness", "work"].map(GoogleCalendarIDs.calendarInfoID)))
        XCTAssertEqual(result.busyIntervals.count, 4, "display reconciliation must never remove raw booking coverage")
        let hidden = sharedWindow(Array(events.dropFirst(2)), owners: ["fitness": "owner@example.com", "work": "owner@example.com"])
        XCTAssertEqual(hidden.meetings.count, 1)
        XCTAssertEqual(hidden.meetings.first?.title, "Busy")
        XCTAssertEqual(hidden.meetings.first?.isAvailabilityOnly, true)
        XCTAssertEqual(hidden.meetings.first?.shouldMirrorBusyTime, false)
        XCTAssertEqual(hidden.meetings.first?.alsoOnCalendarIDs.count, 1)
        XCTAssertEqual(hidden.busyIntervals.count, 2)
    }

    func testMirrorRequiresOwnerAndFingerprintAndKeepsOtherPeoplesBusy() {
        let dinner = ("personal", googleEvent(id: "dinner", summary: "Dinner", iCalUID: "uid"))
        let mirror = ("fitness", googleEvent(id: "busy", summary: "Busy", ownedBy: "banana", itemID: dinnerMirror))
        for owners in [["personal": "one", "fitness": "two"], ["personal": "one"], ["fitness": "one"], [:]] {
            XCTAssertEqual(sharedWindow([dinner, mirror], owners: owners).meetings.count, 2)
        }
        let unknown = ("fitness", googleEvent(id: "busy", summary: "Busy"))
        XCTAssertEqual(sharedWindow([dinner, unknown], owners: ["personal": "one", "fitness": "one"]).meetings.count, 2)
        let other = ("fitness", googleEvent(id: "busy", summary: "Busy", ownedBy: "banana", itemID: "travel-123"))
        XCTAssertEqual(sharedWindow([dinner, other], owners: ["personal": "one", "fitness": "one"]).meetings.count, 2)
    }

    func testAmbiguousIdenticalTitlesWithDifferentUIDsDoNotAbsorbMirror() {
        let result = sharedWindow([
            ("personal", googleEvent(id: "dinner", summary: "Dinner", iCalUID: "uid-one")),
            ("work", googleEvent(id: "other", summary: "Dinner", iCalUID: "uid-two")),
            ("fitness", googleEvent(id: "busy", summary: "Busy", ownedBy: "banana", itemID: dinnerMirror))
        ], owners: ["personal": "one", "work": "one", "fitness": "one"])
        XCTAssertEqual(result.meetings.count, 3)
    }

    func testExtendedOrStaleMirrorAndFreeOriginalStaySeparate() {
        let owners = ["personal": "one", "fitness": "one"]
        let dinner = ("personal", googleEvent(id: "dinner", summary: "Dinner"))
        let longer = ("fitness", googleEvent(id: "busy", summary: "Busy", end: "2026-10-05T17:00:00Z", ownedBy: "banana", itemID: dinnerMirror))
        XCTAssertEqual(sharedWindow([dinner, longer], owners: owners).meetings.count, 2)
        let mirror = ("fitness", googleEvent(id: "busy", summary: "Busy", ownedBy: "banana", itemID: dinnerMirror))
        let free = ("personal", googleEvent(id: "dinner", summary: "Dinner", transparency: "transparent"))
        XCTAssertEqual(sharedWindow([free, mirror], owners: owners).meetings.count, 2)
        let renamed = ("personal", googleEvent(id: "dinner", summary: "Supper"))
        XCTAssertEqual(sharedWindow([renamed, mirror], owners: owners).meetings.count, 2)
    }

    func testRedactedCopyWithSameUIDUsesIndependentlyVisibleDetails() {
        let result = sharedWindow([
            ("me", googleEvent(id: "invite", summary: "Dinner", iCalUID: "same-instance")),
            ("personal", googleEvent(id: "private", summary: "Busy", iCalUID: "same-instance"))
        ], owners: [:])
        XCTAssertEqual(result.meetings.count, 1)
        XCTAssertEqual(result.meetings.first?.title, "Dinner")
        XCTAssertEqual(result.meetings.first?.alsoOnCalendarIDs, [GoogleCalendarIDs.calendarInfoID("personal")])
    }

    func testMirrorFingerprintRemainsCompatibleWithExistingDinnerWrites() {
        let start = ISO8601DateFormatter().date(from: "2026-10-23T22:00:00Z")!
        let end = ISO8601DateFormatter().date(from: "2026-10-24T01:00:00Z")!
        XCTAssertEqual(GoogleBusyBlocks.mirrorID(title: "Dinner", start: start, end: end), "mirror-acf52a72cdfbcbc5")
    }

    func testFlightCopiesKeepTheirExistingRouteReconciliationWithDifferentUIDs() {
        let result = window([("work", googleEvent(id: "airline", summary: "UA 123 EWR → MIA", iCalUID: "airline")),
                             ("personal", googleEvent(id: "google", summary: "United flight to Miami", iCalUID: "google"))])
        XCTAssertEqual(result.meetings.count, 1)
    }

    func testMovedRecurringOccurrencesWithSameUIDAndDisplayedTimeRemainDistinct() {
        let result = sharedWindow([
            ("personal", googleEvent(id: "instance-one", summary: "Dinner", iCalUID: "series-uid", originalStart: "2026-10-04T15:00:00Z")),
            ("work", googleEvent(id: "instance-two", summary: "Dinner", iCalUID: "series-uid", originalStart: "2026-10-05T15:00:00Z")),
            ("fitness", googleEvent(id: "mirror", summary: "Busy", ownedBy: "banana", itemID: dinnerMirror))
        ], owners: ["personal": "owner", "work": "owner", "fitness": "owner"])
        XCTAssertEqual(result.meetings.count, 3, "series UID and displayed time alone do not identify a moved occurrence")
        let copies = sharedWindow([
            ("personal", googleEvent(id: "a", summary: "Dinner", iCalUID: "series-uid", originalStart: "2026-10-04T15:00:00Z")),
            ("work", googleEvent(id: "b", summary: "Dinner", iCalUID: "series-uid", originalStart: "2026-10-04T11:00:00-04:00"))
        ], owners: ["personal": "owner", "work": "owner"])
        XCTAssertEqual(copies.meetings.count, 1, "offset spelling does not change occurrence identity")
    }

    func testCalendarManagerPermissionDoesNotMakeAnotherPersonsCalendarOurs() throws {
        let bytes = Data(#"{"id":"secondary@group.calendar.google.com","accessRole":"owner","dataOwner":"person-one@gmail.com"}"#.utf8)
        var calendar = try JSONDecoder().decode(GoogleCalendar.self, from: bytes)
        calendar.accountEmail = "person-two@gmail.com"
        XCTAssertFalse(calendar.isOwnedByAccount, "shared manager permission must retain the owner's Busy blocks")
        calendar.accountEmail = "PERSON-ONE@gmail.com"
        XCTAssertTrue(calendar.isOwnedByAccount)
        var primary = try JSONDecoder().decode(GoogleCalendar.self, from: Data(#"{"id":"person-one@gmail.com","accessRole":"owner"}"#.utf8))
        primary.accountEmail = "person-two@gmail.com"
        XCTAssertFalse(primary.isOwnedByAccount)
        primary.accountEmail = "person-one@gmail.com"
        XCTAssertTrue(primary.isOwnedByAccount)
    }

    func testAnotherPersonsSharedBusyMirrorStaysVisibleEvenWithOurAppMarker() {
        let block = googleEvent(id: "shared-busy", summary: "Busy", location: "Private work address", hangoutLink: "https://meet.google.com/private", ownedBy: "banana", itemID: "travel-other-person")
        let result = GoogleEventWindowBuilder.window(from: [GoogleFetchedEvent(calendarID: "person-one@gmail.com", event: block)], calendar: utc, ownedCalendarIDs: ["person-two@gmail.com"])
        XCTAssertEqual(result.meetings.map(\.title), ["Busy"])
        XCTAssertEqual(result.meetings.first?.calendarID, GoogleCalendarIDs.calendarInfoID("person-one@gmail.com"))
        XCTAssertNil(result.meetings.first?.address)
        XCTAssertNil(result.meetings.first?.joinURL)
        XCTAssertTrue(result.meetings.first?.isAvailabilityOnly == true)
        XCTAssertFalse(result.meetings.first?.shouldMirrorBusyTime == true, "viewing another person's availability must not copy it into our calendars")
        let bytes = try! JSONEncoder().encode(result.meetings)
        XCTAssertEqual(try! JSONDecoder().decode([MeetingInfo].self, from: bytes), result.meetings, "availability classification survives the cached window")
        XCTAssertEqual(result.busyIntervals.count, 1)
        XCTAssertFalse(result.busyIntervals[0].isAppWritten)
        XCTAssertNil(result.busyIntervals[0].appMarkerScheme)
        XCTAssertTrue(result.travelEvents.isEmpty)
        XCTAssertTrue(result.syncedTravelBlocks.isEmpty, "someone else's travel is not our travel")
        let owner = GoogleEventWindowBuilder.window(from: [GoogleFetchedEvent(calendarID: "person-one@gmail.com", event: block)], calendar: utc, ownedCalendarIDs: ["person-one@gmail.com"])
        XCTAssertTrue(owner.meetings.isEmpty, "the owner's own mirrored copy stays hidden")
    }

    func testSharedBusyBlocksAreNotLostToUnrelatedMeetingsAtTheSameTime() {
        let events = [GoogleFetchedEvent(calendarID: "me", event: googleEvent(id: "mine", summary: "Dentist")),
                      GoogleFetchedEvent(calendarID: "wife", event: googleEvent(id: "hers", summary: "Busy")),
                      GoogleFetchedEvent(calendarID: "coach", event: googleEvent(id: "theirs", summary: nil))]
        let result = GoogleEventWindowBuilder.window(from: events, calendar: utc, ownedCalendarIDs: ["me"])
        XCTAssertEqual(result.meetings.count, 3)
        XCTAssertEqual(result.meetings.filter { $0.title == "Busy" }.count, 2)
        XCTAssertEqual(Set(result.meetings.map(\.id)).count, 3, "simultaneous private blocks have distinct UI identities")
        XCTAssertEqual(result.busyIntervals.count, 3)
        let first = CalendarAgenda.firstMeetings(result.meetings, now: Date(timeIntervalSince1970: 0), calendar: utc)
        XCTAssertEqual(first.values.map(\.title), ["Dentist"], "someone else's availability must not set our wake time")
    }


    func testBusyMirroringKeepsRealAppointmentsAndExcludesFreeEvents() {
        let busy = window([("me@example.com", googleEvent(id: "real", summary: "Dentist"))])
        XCTAssertTrue(busy.meetings.first?.shouldMirrorBusyTime == true)
        let free = window([("me@example.com", googleEvent(id: "free", summary: "Lunch", transparency: "transparent"))])
        XCTAssertFalse(free.meetings.first?.shouldMirrorBusyTime == true)
    }

    func testAnOrdinaryMeetingIsAMeetingAndBusy() {
        let result = window([("work@example.com", googleEvent(id: "a", summary: "Design review"))])
        XCTAssertEqual(result.meetings.map(\.title), ["Design review"])
        XCTAssertEqual(result.busyIntervals.count, 1)
        XCTAssertFalse(result.busyIntervals[0].isAppWritten)
        XCTAssertEqual(result.meetings[0].calendarID, GoogleCalendarIDs.calendarInfoID("work@example.com"))
        XCTAssertEqual(GoogleCalendarIDs.rawEventRoute(from: result.meetings[0].eventID!)?.eventID, "a")
    }

    /// The loop behind duplicate stacking: a block Banana wrote, read back as someone's meeting,
    /// gets mirrored to every other calendar. A titled block ("Travel home", a task name on the
    /// task calendar) is exactly what the placeholder filter does not catch — only the ownership
    /// marker does.
    func testBananasOwnTitledBlockIsNeverAMeeting() {
        let block = googleEvent(id: "b", summary: "Travel home", ownedBy: "banana", itemID: "travel-42")
        let result = window([("me@example.com", block)])
        XCTAssertTrue(result.meetings.isEmpty, "our own block must not come back as a meeting")
        XCTAssertTrue(result.travelEvents.isEmpty)
        XCTAssertEqual(result.busyIntervals.count, 1)
        XCTAssertTrue(result.busyIntervals[0].isAppWritten)
        XCTAssertEqual(result.busyIntervals[0].appMarkerScheme, "banana")
        XCTAssertEqual(result.busyIntervals[0].appItemID, "travel-42")
    }

    /// Our own block is never reused as "someone else already covers this" — that would stop
    /// write-back from ever updating it.
    func testOwnBlocksAreNotReusableCoverageButForeignOnesAre() {
        let result = window([
            ("me@example.com", googleEvent(id: "own", summary: "Busy", ownedBy: "banana")),
            ("me@example.com", googleEvent(id: "reclaim", summary: "Busy",
                                           start: "2026-10-05T17:00:00Z", end: "2026-10-05T18:00:00Z")),
        ])
        let reusable = result.busyIntervals.filter {
            CalendarWriteBackVariant.production.reusesCoverage(
                markerScheme: $0.appMarkerScheme, appItemID: $0.appItemID)
        }
        XCTAssertEqual(reusable.count, 1)
        XCTAssertFalse(reusable[0].isAppWritten)
    }

    func testAForeignBusyPlaceholderIsCoverageNotAMeeting() {
        let result = window([("me@example.com", googleEvent(id: "p", summary: "Busy"))])
        XCTAssertTrue(result.meetings.isEmpty)
        XCTAssertEqual(result.busyIntervals.count, 1)
    }

    func testDeclinedAndCancelledEventsDoNotCount() {
        let result = window([
            ("me@example.com", googleEvent(id: "d", summary: "Declined", declined: true)),
            ("me@example.com", googleEvent(id: "c", summary: "Cancelled", status: "cancelled")),
        ])
        XCTAssertTrue(result.meetings.isEmpty)
        XCTAssertTrue(result.busyIntervals.isEmpty)
    }

    /// A dinner marked "Show as: Free" is on your day but must never make you busy — and so never
    /// gets a block written for it.
    func testAFreeEventShowsButIsNotBusy() {
        let result = window([("me@example.com",
                              googleEvent(id: "f", summary: "Dinner", transparency: "transparent"))])
        XCTAssertEqual(result.meetings.count, 1)
        XCTAssertTrue(result.meetings[0].showsAsFree)
        XCTAssertTrue(result.busyIntervals.isEmpty)
    }

    /// A multi-day hotel stay is the location anchor for travel, but not a meeting.
    func testAnAllDayLocatedStayIsTravelNotAMeeting() {
        let stay = googleEvent(id: "h", summary: "Stay at The Hoxton",
                               allDay: ("2026-10-05", "2026-10-08"), location: "London")
        let result = window([("me@example.com", stay)])
        XCTAssertTrue(result.meetings.isEmpty)
        XCTAssertTrue(result.busyIntervals.isEmpty, "all-day events do not block time")
        XCTAssertEqual(result.travelEvents.count, 1)
        XCTAssertTrue(result.travelEvents[0].isAllDay)
        XCTAssertEqual(result.travelEvents[0].location, "London")
    }

    /// The same invite reaching two of your accounts is one meeting, and the richer copy wins.
    func testTheSameMeetingOnTwoCalendarsAppearsOnce() {
        let bare = googleEvent(id: "x1", summary: "Board meeting")
        let rich = googleEvent(id: "x2", summary: "Board meeting", location: "HQ 4th floor",
                               attendees: 3)
        let result = window([("a@example.com", bare), ("b@example.com", rich)])
        XCTAssertEqual(result.meetings.count, 1)
        XCTAssertEqual(result.meetings[0].address, "HQ 4th floor")
        // Both still occupy their own calendar's slot for coverage purposes.
        XCTAssertEqual(result.busyIntervals.count, 2)
    }

    func testTwoDifferentMeetingsInOneSlotBothShow() {
        let result = window([
            ("a@example.com", googleEvent(id: "m1", summary: "Standup")),
            ("b@example.com", googleEvent(id: "m2", summary: "Dentist")),
        ])
        XCTAssertEqual(Set(result.meetings.map(\.title)), ["Standup", "Dentist"])
    }

    func testAVideoLinkMakesAMeetingVirtual() {
        let call = googleEvent(id: "v", summary: "Sync",
                               description: "Join: https://us02web.zoom.us/j/123456789")
        let result = window([("me@example.com", call)])
        XCTAssertTrue(result.meetings[0].isVirtual)
        XCTAssertEqual(result.meetings[0].platform, .zoom)
    }

    /// Google adds a Meet link to any event with a guest. A doctor's appointment at a street
    /// address shared with a partner got no travel time, because the link read as "a call".
    func testAStreetAddressIsSomewhereYouGoEvenWithAMeetLink() {
        let meet = "https://meet.google.com/abc-defg-hij"
        let appointment = googleEvent(id: "a", summary: "Dentist",
                                      location: "Main Street Dental, 12 Main St, Springfield, IL 62701, USA",
                                      hangoutLink: meet, attendees: 1)
        let inPerson = window([("me@example.com", appointment)]).meetings[0]
        XCTAssertFalse(inPerson.isVirtual)
        XCTAssertTrue(inPerson.hasPhysicalLocation, "so it gets travel time")
        XCTAssertEqual(inPerson.joinURL?.absoluteString, meet, "the link stays for anyone joining remotely")

        for location in ["Google Meet (instructions in description)", "Office-10th Floor-CR B (6)",
                         "Microsoft Teams Meeting", "https://zoom.us/j/123"] {
            let call = googleEvent(id: "c", summary: "Sync", location: location, hangoutLink: meet)
            XCTAssertTrue(window([("me@example.com", call)]).meetings[0].isVirtual, location)
        }
    }

    /// A travel block the phone wrote to three calendars is ONE block of occupancy on the Mac.
    func testSyncedTravelBlocksGroupAcrossCalendars() {
        let titled = googleEvent(id: "t1", summary: "Travel home", ownedBy: "banana", itemID: "travel-9")
        let mirror = googleEvent(id: "t2", summary: "Busy", ownedBy: "banana", itemID: "travel-9")
        let unrelated = googleEvent(id: "t3", summary: "Busy",
                                    start: "2026-10-05T18:00:00Z", end: "2026-10-05T19:00:00Z",
                                    ownedBy: "banana", itemID: "mirror-abc")
        let result = window([("a@example.com", titled), ("b@example.com", mirror),
                             ("c@example.com", unrelated)])
        XCTAssertEqual(result.syncedTravelBlocks.count, 1)
        XCTAssertEqual(result.syncedTravelBlocks[0].appItemID, "travel-9")
        XCTAssertEqual(result.syncedTravelBlocks[0].title, "Travel home")
    }

    func testAnEventWithoutUsableTimesIsDropped() {
        let broken = googleEvent(id: "z", start: "2026-10-05T16:00:00Z", end: "2026-10-05T15:00:00Z")
        XCTAssertNil(GoogleEventWindowBuilder.normalize(
            GoogleFetchedEvent(calendarID: "me@example.com", event: broken)))
    }

    func testOwnershipNeedsBothTheVariantAndAnItemID() {
        XCTAssertNotNil(GoogleEventWindowBuilder.ownership(of: googleEvent(id: "o", ownedBy: "banana")))
        XCTAssertNotNil(GoogleEventWindowBuilder.ownership(of: googleEvent(id: "o", ownedBy: "banana-beta")))
        XCTAssertNil(GoogleEventWindowBuilder.ownership(of: googleEvent(id: "o", ownedBy: "someone-else")),
                     "another app's private properties are not ours")
        XCTAssertNil(GoogleEventWindowBuilder.ownership(of: googleEvent(id: "o")))
    }
}

// MARK: - Agenda helpers

final class CalendarAgendaTests: XCTestCase {

    func testFirstMeetingPerDaySkipsWhatHasAlreadyStartedToday() {
        let now = ISO8601DateFormatter().date(from: "2026-10-05T12:00:00Z")!
        func meeting(_ start: String, _ title: String) -> MeetingInfo {
            MeetingInfo(start: ISO8601DateFormatter().date(from: start)!, end: nil, coordinate: nil,
                        address: nil, isVirtual: false, title: title)
        }
        let result = CalendarAgenda.firstMeetings([
            meeting("2026-10-05T09:00:00Z", "earlier today"),
            meeting("2026-10-05T14:00:00Z", "later today"),
            meeting("2026-10-06T10:00:00Z", "tomorrow late"),
            meeting("2026-10-06T08:00:00Z", "tomorrow early"),
        ], now: now, calendar: utc)
        XCTAssertEqual(result[utc.startOfDay(for: now)]?.title, "later today")
        XCTAssertEqual(result[utc.date(byAdding: .day, value: 1, to: utc.startOfDay(for: now))!]?.title,
                       "tomorrow early")
    }

    func testTemplatesCountRepeatsAndKeepTheLatestShape() {
        let calendarID = GoogleCalendarIDs.calendarInfoID("me@example.com")
        func meeting(_ start: String, minutes: Double, _ title: String, calendar: String? = nil) -> MeetingInfo {
            let startDate = ISO8601DateFormatter().date(from: start)!
            return MeetingInfo(start: startDate, end: startDate.addingTimeInterval(minutes * 60),
                               coordinate: nil, address: nil, isVirtual: false, title: title,
                               calendarID: calendar ?? calendarID)
        }
        let templates = CalendarEventTemplate.build(from: [
            meeting("2026-09-01T10:00:00Z", minutes: 30, "1:1 with Sam"),
            meeting("2026-09-08T10:00:00Z", minutes: 45, "1:1 with Sam"),
            meeting("2026-09-03T10:00:00Z", minutes: 60, "Dentist"),
            meeting("2026-09-04T10:00:00Z", minutes: 60, "Someone else's", calendar: "google-calendar:other"),
        ], writableCalendarIDs: [calendarID])
        XCTAssertEqual(templates.map(\.title), ["1:1 with Sam", "Dentist"])
        XCTAssertEqual(templates[0].useCount, 2)
        XCTAssertEqual(templates[0].durationMinutes, 45, "the latest occurrence sets the shape")
    }
}

// MARK: - Identity

final class GoogleCalendarIDTests: XCTestCase {
    func testIDsRoundTripAndAreRecognisable() {
        let calendar = GoogleCalendarIDs.calendarInfoID("c_abc123@group.calendar.google.com")
        XCTAssertTrue(GoogleCalendarIDs.isCalendarInfoID(calendar))
        XCTAssertEqual(GoogleCalendarIDs.rawCalendarID(from: calendar), "c_abc123@group.calendar.google.com")
        let event = GoogleCalendarIDs.eventInfoID(calendarID: "me@example.com", eventID: "evt_1")
        XCTAssertTrue(GoogleCalendarIDs.isEventInfoID(event))
        XCTAssertFalse(GoogleCalendarIDs.isCalendarInfoID(event))
        XCTAssertEqual(GoogleCalendarIDs.rawEventRoute(from: event)?.calendarID, "me@example.com")
        XCTAssertEqual(GoogleCalendarIDs.rawEventRoute(from: event)?.eventID, "evt_1")
        XCTAssertNil(GoogleCalendarIDs.rawCalendarID(from: "ABCD-EVENTKIT-ID"))
    }
}

// MARK: - Removal safety

final class BlockRemovalGateTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// One pass is never enough, however healthy: every mass deletion so far came from a single
    /// pass that saw less than was really there.
    func testOneHealthyPassOnlyStartsTheClock() {
        var gate = BlockRemovalGate()
        XCTAssertTrue(gate.review(unwanted: ["a"], sourcesHealthy: true, now: t0).isEmpty)
        XCTAssertTrue(gate.review(unwanted: ["a"], sourcesHealthy: true, now: t0.addingTimeInterval(30)).isEmpty,
                      "two passes seconds apart are the same moment")
        XCTAssertEqual(gate.review(unwanted: ["a"], sourcesHealthy: true,
                                   now: t0.addingTimeInterval(BlockRemovalGate.confirmationDelay)), ["a"])
    }

    /// A calendar we could not read is not a calendar with no meetings.
    func testAnUnhealthyPassConfirmsNothingAndForgetsNothing() {
        var gate = BlockRemovalGate()
        _ = gate.review(unwanted: ["a"], sourcesHealthy: true, now: t0)
        XCTAssertTrue(gate.review(unwanted: ["a", "b"], sourcesHealthy: false,
                                  now: t0.addingTimeInterval(600)).isEmpty)
        XCTAssertEqual(gate.pendingSince.keys.sorted(), ["a"], "an unhealthy pass has no standing to add or clear")
        XCTAssertEqual(gate.review(unwanted: ["a", "b"], sourcesHealthy: true,
                                   now: t0.addingTimeInterval(601)), ["a"],
                       "b was only seen unwanted once while healthy")
    }

    /// The meeting came back (a blip, or an undo): the block is wanted again and its clock resets.
    func testABlockWantedAgainIsNoLongerPending() {
        var gate = BlockRemovalGate()
        _ = gate.review(unwanted: ["a"], sourcesHealthy: true, now: t0)
        _ = gate.review(unwanted: [], sourcesHealthy: true, now: t0.addingTimeInterval(60))
        XCTAssertTrue(gate.review(unwanted: ["a"], sourcesHealthy: true,
                                  now: t0.addingTimeInterval(200)).isEmpty,
                      "the earlier sighting no longer counts")
    }

    func testThePendingSetSurvivesARelaunch() throws {
        var gate = BlockRemovalGate()
        _ = gate.review(unwanted: ["a"], sourcesHealthy: true, now: t0)
        var restored = try JSONDecoder().decode(BlockRemovalGate.self,
                                                from: try JSONEncoder().encode(gate))
        XCTAssertEqual(restored.review(unwanted: ["a"], sourcesHealthy: true,
                                       now: t0.addingTimeInterval(120)), ["a"])
    }

    /// 291 blocks disappearing is something to be asked about, not told about.
    func testLargeRemovalsAreHeld() {
        XCTAssertTrue(MassRemovalGuard.shouldHold(removing: 291, owned: 622))
        XCTAssertTrue(MassRemovalGuard.shouldHold(removing: 30, owned: 40))
        XCTAssertFalse(MassRemovalGuard.shouldHold(removing: 3, owned: 4),
                       "a handful is routine cleanup even when it is most of what exists")
        XCTAssertFalse(MassRemovalGuard.shouldHold(removing: 25, owned: 622),
                       "a normal day's churn")
    }
}

// MARK: - Destinations and exclusions

final class WriteBackDestinationTests: XCTestCase {
    private let mine = WriteBackDestinations.Calendar(
        infoID: "google-calendar:mine", titles: ["bo@dewey.example"],
        accountEmail: "bo@dewey.example", isOwner: true)
    private let family = WriteBackDestinations.Calendar(
        infoID: "google-calendar:family", titles: ["Family"],
        accountEmail: "bbaker@gmail.example", isOwner: true)
    private let colleague = WriteBackDestinations.Calendar(
        infoID: "google-calendar:colleague", titles: ["James Michado"],
        accountEmail: "bo@dewey.example", isOwner: false)

    /// A colleague's calendar you can edit is off unless turned on: every block written to it
    /// notifies everyone on it.
    func testSomeoneElsesCalendarIsOptIn() {
        let off = WriteBackDestinations.destinations(
            [mine, colleague], excludedIDs: [], excludedIdentities: [], includedShared: [])
        XCTAssertEqual(off, [mine.infoID])
        let on = WriteBackDestinations.destinations(
            [mine, colleague], excludedIDs: [], excludedIdentities: [], includedShared: [colleague.infoID])
        XCTAssertEqual(Set(on), [mine.infoID, colleague.infoID])
    }

    func testAnExcludedCalendarIsNeverADestination() {
        let result = WriteBackDestinations.destinations(
            [mine, colleague], excludedIDs: [mine.infoID, colleague.infoID],
            excludedIdentities: [], includedShared: [colleague.infoID])
        XCTAssertTrue(result.isEmpty)
    }

    /// Exclusions made against Apple Calendar named the account the way Apple does: the address
    /// on the Mac, the address's local part on the iPhone. Both must still exclude.
    func testAppleCalendarExclusionsCarryOver() {
        let fromMac = WriteBackDestinations.Identity(sourceTitle: "bbaker@gmail.example", calendarTitle: "Family")
        let fromPhone = WriteBackDestinations.Identity(sourceTitle: "Bbaker", calendarTitle: "family")
        let fromBanana = WriteBackDestinations.Identity(sourceTitle: "Google · bbaker@gmail.example",
                                                        calendarTitle: "Family")
        for identity in [fromMac, fromPhone, fromBanana] {
            XCTAssertEqual(WriteBackDestinations.excluded([mine, family], ids: [], identities: [identity]),
                           [family.infoID], "\(identity)")
        }
    }

    func testAnExclusionForAnotherAccountsCalendarDoesNotMatch() {
        let identity = WriteBackDestinations.Identity(sourceTitle: "someone@else.com", calendarTitle: "Family")
        XCTAssertTrue(WriteBackDestinations.excluded([family], ids: [], identities: [identity]).isEmpty)
        let iCloud = WriteBackDestinations.Identity(sourceTitle: "iCloud", calendarTitle: "Family")
        XCTAssertTrue(WriteBackDestinations.excluded([family], ids: [], identities: [iCloud]).isEmpty,
                      "an iCloud calendar of the same name is a different calendar")
    }

    func testARenamedCalendarMatchesEitherName() {
        let renamed = WriteBackDestinations.Calendar(
            infoID: "google-calendar:r", titles: ["Home stuff", "Family"],
            accountEmail: "bbaker@gmail.example", isOwner: true)
        let identity = WriteBackDestinations.Identity(sourceTitle: "bbaker@gmail.example", calendarTitle: "Family")
        XCTAssertEqual(WriteBackDestinations.excluded([renamed], ids: [], identities: [identity]), [renamed.infoID])
    }
}

// MARK: - Token rejection

/// Only an answer that means "this grant is dead" may mark an account as signed out. A bare 400
/// used to be enough, which let a malformed request or a rate limit do it.
final class GoogleTokenRejectionTests: XCTestCase {

    func testOnlyGrantAndClientErrorsAreRejections() {
        XCTAssertTrue(GoogleTokenMinter.isCredentialRejection(status: 400, error: "invalid_grant"))
        XCTAssertTrue(GoogleTokenMinter.isCredentialRejection(status: 401, error: "unauthorized_client"))
        XCTAssertTrue(GoogleTokenMinter.isCredentialRejection(status: 401, error: "invalid_client"))
        XCTAssertFalse(GoogleTokenMinter.isCredentialRejection(status: 400, error: "invalid_request"))
        XCTAssertFalse(GoogleTokenMinter.isCredentialRejection(status: 429, error: "rate_limit_exceeded"))
        XCTAssertFalse(GoogleTokenMinter.isCredentialRejection(status: 400, error: nil),
                       "an unexplained 400 is not proof the account is gone")
        XCTAssertTrue(GoogleTokenMinter.isCredentialRejection(status: 401, error: nil))
        XCTAssertFalse(GoogleTokenMinter.isCredentialRejection(status: 503, error: nil))
    }

    /// Google's own words are kept, because they name the cause: an OAuth app still in Testing,
    /// or a Workspace session-control policy.
    func testGooglesReasonIsKept() {
        let body = Data(#"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#.utf8)
        let parsed = GoogleTokenMinter.OAuthError.parse(body)
        XCTAssertEqual(parsed?.error, "invalid_grant")
        XCTAssertEqual(parsed?.summary, "invalid_grant: Token has been expired or revoked.")
        XCTAssertNil(GoogleTokenMinter.OAuthError.parse(Data("<html>".utf8)))
    }
}

// MARK: - Finding Apple-Calendar-written blocks in Google

/// The ledger names each old block by its EventKit identifier, `<store>:<UID>`; Google keeps the
/// same UID as the event's iCalUID. Matching them is how old blocks are taken over with no Apple
/// Calendar access at all — and every way it could claim the wrong event must be refused.
final class LegacyBlockMatcherTests: XCTestCase {
    private let ekID = "54AB09BE-4064-4E2F-8980-2AA33DE31274:FE8DC360-6565-40BC-BAB9-BF3D149FE97E"
    private let uid = "FE8DC360-6565-40BC-BAB9-BF3D149FE97E"

    private func index(_ events: [(String, GoogleEvent)]) -> [String: [GoogleFetchedEvent]] {
        LegacyBlockMatcher.index(events.map { GoogleFetchedEvent(calendarID: $0.0, event: $0.1) })
    }

    func testTheUIDIsTheLastComponent() {
        XCTAssertEqual(LegacyBlockMatcher.uid(fromEventKitIdentifier: ekID), uid)
        XCTAssertNil(LegacyBlockMatcher.uid(fromEventKitIdentifier: "no-store-prefix"))
    }

    func testAnUntaggedBlockIsAdopted() {
        let idx = index([("me@example.com", googleEvent(id: "g1", summary: "Busy", iCalUID: uid.lowercased()))])
        XCTAssertEqual(LegacyBlockMatcher.match(eventKitIdentifier: ekID, in: idx, variant: "banana"),
                       .adopt(calendarID: "me@example.com", eventID: "g1"))
    }

    func testATaggedBlockIsRecognisedNotRetagged() {
        let idx = index([("me@example.com", googleEvent(id: "g1", ownedBy: "banana", itemID: "mirror-1", iCalUID: uid))])
        XCTAssertEqual(LegacyBlockMatcher.match(eventKitIdentifier: ekID, in: idx, variant: "banana"),
                       .alreadyOurs(calendarID: "me@example.com", eventID: "g1", appItemID: "mirror-1"))
        XCTAssertEqual(LegacyBlockMatcher.match(eventKitIdentifier: ekID, in: idx, variant: "banana-beta"),
                       .otherVariant)
    }

    /// Banana's blocks never have guests. Something with guests is a real meeting, whatever the UID says.
    func testAnEventWithAttendeesIsNeverClaimed() {
        let idx = index([("me@example.com", googleEvent(id: "g1", attendees: 2, iCalUID: uid))])
        XCTAssertEqual(LegacyBlockMatcher.match(eventKitIdentifier: ekID, in: idx, variant: "banana"), .unsafe)
    }

    func testAUIDNamingTwoDifferentEventsIsNeverClaimed() {
        let idx = index([("a@example.com", googleEvent(id: "g1", iCalUID: uid)),
                         ("b@example.com", googleEvent(id: "g2", iCalUID: uid))])
        XCTAssertEqual(LegacyBlockMatcher.match(eventKitIdentifier: ekID, in: idx, variant: "banana"), .unsafe)
    }

    /// A calendar shared between two connected accounts lists the same event twice.
    func testTheSameEventSeenThroughTwoAccountsIsOneMatch() {
        let idx = index([("shared@group", googleEvent(id: "g1", iCalUID: uid)),
                         ("shared@group", googleEvent(id: "g1", iCalUID: uid))])
        XCTAssertEqual(LegacyBlockMatcher.match(eventKitIdentifier: ekID, in: idx, variant: "banana"),
                       .adopt(calendarID: "shared@group", eventID: "g1"))
    }

    func testDeletedAndMissingEventsAreNotFound() {
        let idx = index([("me@example.com", googleEvent(id: "g1", status: "cancelled", iCalUID: uid))])
        XCTAssertEqual(LegacyBlockMatcher.match(eventKitIdentifier: ekID, in: idx, variant: "banana"), .notFound)
        XCTAssertEqual(LegacyBlockMatcher.match(eventKitIdentifier: "X:OTHER", in: idx, variant: "banana"), .notFound)
    }
}

/// The phone and the Mac must name the same task's block the same way, or each deletes the
/// other's copy as unwanted.
final class WriteBackItemIDTests: XCTestCase {
    func testATaskBlockIsNamedByTheSyncedReminderID() {
        XCTAssertEqual(WriteBackItemID.forOccurrence(id: "task:LOCAL-1", reminderID: "LOCAL-1",
                                                     reminderExternalID: "SHARED-9"), "task:SHARED-9")
        XCTAssertEqual(WriteBackItemID.forOccurrence(id: "task:LOCAL-1:812345678", reminderID: "LOCAL-1",
                                                     reminderExternalID: "SHARED-9"), "task:SHARED-9:812345678",
                       "a repeating task keeps its per-occurrence suffix")
    }

    func testEverythingElseKeepsItsID() {
        XCTAssertEqual(WriteBackItemID.forOccurrence(id: "travel-abc", reminderID: nil, reminderExternalID: nil),
                       "travel-abc")
        XCTAssertEqual(WriteBackItemID.forOccurrence(id: "task:LOCAL-1", reminderID: "LOCAL-1",
                                                     reminderExternalID: nil), "task:LOCAL-1",
                       "no shared id to use: unchanged rather than invented")
    }
}

/// A calendar deleted in Google must stop being asked about — every read of it fails, and a failed
/// read suspends all removals — but a calendar merely missing because its account is signed out
/// must not be forgotten.
final class VanishedCalendarTests: XCTestCase {
    func testADeletedCalendarIsForgottenWhenTheListIsComplete() {
        XCTAssertEqual(WriteBackDestinations.vanishedCalendars(
            remembered: ["a", "transferred"], listed: ["a", "b"], listIsComplete: true), ["transferred"])
    }

    func testNothingIsForgottenFromAnIncompleteList() {
        XCTAssertTrue(WriteBackDestinations.vanishedCalendars(
            remembered: ["a", "signed-out"], listed: ["a"], listIsComplete: false).isEmpty)
        XCTAssertTrue(WriteBackDestinations.vanishedCalendars(
            remembered: ["a"], listed: [], listIsComplete: true).isEmpty,
                      "an empty list is a failed load, not every calendar deleted")
    }
}

/// The Mac menu bar's headline and the "join next meeting" shortcut.
final class MenuBarAgendaStateTests: XCTestCase {
    private let base = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func meeting(_ title: String, from start: Double, to end: Double, link: Bool = false,
                         free: Bool = false) -> MeetingInfo {
        MeetingInfo(start: base.addingTimeInterval(start * 60), end: base.addingTimeInterval(end * 60),
                    coordinate: nil, address: nil, isVirtual: link, title: title,
                    joinURL: link ? URL(string: "https://meet.google.com/abc") : nil,
                    showsAsFree: free)
    }

    func testTheMeetingInProgressIsTheHeadline() {
        let moment = MenuBarAgendaState.moment(in: [meeting("Standup", from: -5, to: 25),
                                                    meeting("Review", from: 60, to: 90)], at: base)
        XCTAssertEqual(moment?.kind, .now)
        XCTAssertEqual(moment?.meeting.title, "Standup")
        XCTAssertEqual(moment?.minutes, 25)
        XCTAssertEqual(MenuBarAgendaState.label(for: moment), "Standup · 25m left")
    }

    func testOtherwiseTheNextMeetingWithACountdown() {
        let moment = MenuBarAgendaState.moment(in: [meeting("Review", from: 75, to: 90)], at: base)
        XCTAssertEqual(moment?.kind, .next)
        XCTAssertEqual(MenuBarAgendaState.label(for: moment), "Review in 1h 15m")
    }

    /// With a trip to make, the menu bar says when to leave, not when it starts.
    func testTheMenuBarLeadsWithLeavingWhenThereIsATrip() {
        let moment = MenuBarAgendaState.moment(in: [meeting("Lap Swim", from: 40, to: 85)], at: base)
        XCTAssertEqual(MenuBarAgendaState.label(for: moment, leaveBy: base.addingTimeInterval(15 * 60), now: base),
                       "Leave in 15m · Lap Swim")
        XCTAssertEqual(MenuBarAgendaState.label(for: moment, leaveBy: base, now: base), "Leave now · Lap Swim")
        // An hour or more away, the meeting itself is the news.
        XCTAssertEqual(MenuBarAgendaState.label(for: moment, leaveBy: base.addingTimeInterval(2 * 3600), now: base),
                       "Lap Swim in 40m")
    }

    func testFreeMarkedEventsAreNotTheHeadline() {
        let moment = MenuBarAgendaState.moment(in: [meeting("Dinner", from: -5, to: 60, free: true),
                                                    meeting("Call", from: 30, to: 60)], at: base)
        XCTAssertEqual(moment?.meeting.title, "Call")
    }

    /// Join opens a meeting that has started or starts within the hour, and never one without a link.
    func testJoinPicksTheRightMeeting() {
        XCTAssertEqual(MenuBarAgendaState.joinable(in: [meeting("Call", from: 5, to: 30, link: true)], at: base)?.title, "Call")
        XCTAssertEqual(MenuBarAgendaState.joinable(in: [meeting("Call", from: -20, to: 30, link: true)], at: base)?.title, "Call")
        XCTAssertNil(MenuBarAgendaState.joinable(in: [meeting("Later", from: 90, to: 120, link: true)], at: base))
        XCTAssertNil(MenuBarAgendaState.joinable(in: [meeting("In person", from: 5, to: 30)], at: base))
    }

    func testLongTitlesAreShortenedForTheMenuBar() {
        XCTAssertEqual(MenuBarAgendaState.shortTitle("Quarterly planning with the whole leadership team"),
                       "Quarterly planning wi…")
    }
}

/// "Go to …" in the ⌘K menu: plain-words dates, and never a command mistaken for one.
final class CommandMenuDateParserTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-09-24T15:00:00Z")!   // a Thursday

    func testPlainWordDatesAreRead() {
        XCTAssertNotNil(CommandMenuDateParser.date(in: "tomorrow", now: now))
        XCTAssertNotNil(CommandMenuDateParser.date(in: "oct 12", now: now))
        XCTAssertNotNil(CommandMenuDateParser.date(in: "next friday", now: now))
    }

    func testTheResultIsTheStartOfThatDay() {
        let date = CommandMenuDateParser.date(in: "December 3, 2026", now: now)
        XCTAssertEqual(date, Calendar.current.startOfDay(for: date ?? now))
        XCTAssertEqual(Calendar.current.component(.day, from: date ?? now), 3)
    }

    func testCommandsAreNotDates() {
        XCTAssertNil(CommandMenuDateParser.date(in: "share availability", now: now))
        XCTAssertNil(CommandMenuDateParser.date(in: "new event", now: now))
        XCTAssertNil(CommandMenuDateParser.date(in: "da", now: now), "too short to mean anything")
    }
}

/// Replying to an invitation rewrites the attendee list, so everyone else must survive untouched.
final class GoogleRSVPPatchTests: XCTestCase {
    func testOnlyMyReplyChangesAndEveryOtherFieldSurvives() {
        let attendees: [[String: Any]] = [
            ["email": "organizer@example.com", "organizer": true, "responseStatus": "accepted"],
            ["email": "me@example.com", "self": true, "responseStatus": "needsAction", "comment": "maybe late"],
            ["email": "room@resource.calendar.google.com", "resource": true, "responseStatus": "accepted"],
            ["email": "guest@example.com", "optional": true, "responseStatus": "tentative", "additionalGuests": 1],
        ]
        let patched = GoogleRSVPPatch.attendees(attendees, replying: .accepted)
        XCTAssertEqual(patched?.count, 4)
        XCTAssertEqual(patched?[1]["responseStatus"] as? String, "accepted")
        XCTAssertEqual(patched?[1]["comment"] as? String, "maybe late")
        XCTAssertEqual(patched?[2]["resource"] as? Bool, true)
        XCTAssertEqual(patched?[3]["optional"] as? Bool, true)
        XCTAssertEqual(patched?[3]["additionalGuests"] as? Int, 1)
        XCTAssertEqual(patched?[3]["responseStatus"] as? String, "tentative")
    }

    func testNotAGuestMeansNothingToReplyTo() {
        XCTAssertNil(GoogleRSVPPatch.attendees([["email": "someone@example.com"]], replying: .declined))
    }
}
