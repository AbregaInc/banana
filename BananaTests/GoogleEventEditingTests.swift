import XCTest

/// Who may change what, which events a save applies to, and the exact body it sends — the parts
/// of editing that decide what happens to a real calendar, other people's included.
final class GoogleEventEditPolicyTests: XCTestCase {
    private func access(writable: Bool = true, locked: Bool = false, organizerIsSelf: Bool? = true,
                        guestsCanModify: Bool = false, type: String? = "default",
                        banana: Bool = false) -> GoogleEventEditAccess {
        GoogleEventEditPolicy.access(calendarWritable: writable, locked: locked, organizerIsSelf: organizerIsSelf,
                                     guestsCanModify: guestsCanModify, eventType: type, isBananaBlock: banana)
    }

    func testYourOwnEventsAreYoursToChange() {
        XCTAssertEqual(access(), .full)
        XCTAssertEqual(access(organizerIsSelf: nil), .full, "no organizer: made on this calendar")
    }

    func testSomeoneElsesInvitationIsOnlyYoursForAlertsAndShowAs() {
        XCTAssertEqual(access(organizerIsSelf: false), .personalOnly)
        XCTAssertEqual(access(organizerIsSelf: false, guestsCanModify: true), .full, "unless guests may edit")
        XCTAssertEqual(access(locked: true), .personalOnly)
    }

    func testWhatNobodyEditsFromHere() {
        XCTAssertEqual(access(writable: false), .readOnly)
        XCTAssertEqual(access(type: "birthday"), .readOnly)
        XCTAssertEqual(access(type: "workingLocation"), .readOnly)
        XCTAssertEqual(access(banana: true), .readOnly, "Banana's own blocks belong to write-back")
        XCTAssertTrue(GoogleEventEditPolicy.isBananaBlock([GoogleBusyBlocks.variantKey: "banana"]))
        XCTAssertFalse(GoogleEventEditPolicy.isBananaBlock(nil))
    }

    /// Google leaves `self` out when it's false: an organizer without it is someone else — read as
    /// "yours", every invitation would have been fully editable.
    func testTheOrganizerAsGoogleSendsIt() throws {
        func organizer(_ json: String) throws -> Bool? {
            let event = try JSONDecoder().decode(GoogleEvent.self, from: Data(json.utf8))
            return GoogleEventEditPolicy.organizerIsSelf(event.organizer)
        }
        XCTAssertEqual(try organizer(#"{"id":"a","organizer":{"email":"sam@example.com"}}"#), false)
        XCTAssertEqual(try organizer(#"{"id":"a","organizer":{"email":"me@example.com","self":true}}"#), true)
        XCTAssertNil(try organizer(#"{"id":"a"}"#))
        let invitation = try JSONDecoder().decode(GoogleEvent.self, from: Data(
            #"{"id":"a","organizer":{"email":"sam@example.com"},"etag":"\"3\"","eventType":"default"}"#.utf8))
        XCTAssertEqual(access(organizerIsSelf: GoogleEventEditPolicy.organizerIsSelf(invitation.organizer)), .personalOnly)
        XCTAssertEqual(invitation.etag, "\"3\"")
    }

    func testGuestsHearAboutItOnlyWhenYouOrganizeAndTheyExist() {
        XCTAssertTrue(GoogleEventEditPolicy.notifiesGuests(organizerIsSelf: true, otherGuestCount: 2))
        XCTAssertTrue(GoogleEventEditPolicy.notifiesGuests(organizerIsSelf: nil, otherGuestCount: 1))
        XCTAssertFalse(GoogleEventEditPolicy.notifiesGuests(organizerIsSelf: true, otherGuestCount: 0))
        XCTAssertFalse(GoogleEventEditPolicy.notifiesGuests(organizerIsSelf: false, otherGuestCount: 3))
    }
}

final class GoogleEventEditScopeTests: XCTestCase {
    private func question(recurring: Bool = true, repeatChanged: Bool = false, off: Bool = false,
                          guests: Int = 0, count: Bool = false) -> GoogleEventEditQuestion {
        GoogleEventEditScope.question(isRecurring: recurring, repeatChanged: repeatChanged, repeatTurnedOff: off,
                                      otherGuestCount: guests, usesCount: count)
    }

    func testASingleEventAsksNothing() {
        XCTAssertEqual(question(recurring: false), GoogleEventEditQuestion.none)
        XCTAssertEqual(question(recurring: false, repeatChanged: true), GoogleEventEditQuestion.none,
                       "adding a repeat makes it a series")
    }

    func testARepeatChangeIsTheSeries() {
        XCTAssertEqual(question(repeatChanged: true), GoogleEventEditQuestion.none)
        XCTAssertEqual(GoogleEventEditScope.scope(forRepeatChangeOnRecurring: true), .series)
    }

    func testNeverOnASeriesEndsItAfterThisOne() {
        XCTAssertEqual(question(repeatChanged: true, off: true), .endSeries)
    }

    func testThisAndFollowingOnlyWithNobodyElseOnIt() {
        XCTAssertEqual(question(guests: 0), .thisFollowingOrAll)
        XCTAssertEqual(question(guests: 2), .thisOrAll, "a new series would re-invite them")
        XCTAssertEqual(question(guests: 0, count: true), .thisOrAll, "a COUNT can't be split")
    }

    func testADragsEntireSeriesIsTheSeries() {
        XCTAssertEqual(CalendarEditSpan.allEvents.googleScope, .series)
        XCTAssertEqual(CalendarEditSpan.futureEvents.googleScope, .thisAndFollowing)
        XCTAssertEqual(CalendarEditSpan.thisEvent.googleScope, .occurrence)
    }
}

final class GoogleEventPatchTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_791_288_000)   // 2026-10-06 14:00 UTC

    private func fields(zone: String? = nil, reminders: GoogleCalendarReminderSelection? = nil,
                        location: String = "") -> GoogleEventPatch.Fields {
        GoogleEventPatch.Fields(title: " Standup ", start: start, end: start.addingTimeInterval(1_800), isAllDay: false,
                                location: location, notes: "", availability: .busy, reminders: reminders,
                                timeZoneID: zone)
    }

    func testAnUntouchedRepeatIsNotSent() {
        let body = GoogleEventPatch.body(fields(), access: .full, recurrence: nil, isRecurring: true)
        XCTAssertNil(body["recurrence"])
        XCTAssertEqual(body["summary"] as? String, "Standup")
    }

    func testANewRepeatCarriesATimeZone() {
        let rule = ["RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR"]
        let body = GoogleEventPatch.body(fields(), access: .full, recurrence: rule, isRecurring: false,
                                         fallbackTimeZoneID: "Europe/London")
        XCTAssertEqual(body["recurrence"] as? [String], rule)
        XCTAssertEqual((body["start"] as? [String: String])?["timeZone"], "Europe/London",
                       "Google needs a zone to expand a repeat")
        XCTAssertEqual((body["end"] as? [String: String])?["timeZone"], "Europe/London")

        let own = GoogleEventPatch.body(fields(zone: "America/New_York"), access: .full, recurrence: rule,
                                        isRecurring: false, fallbackTimeZoneID: "Europe/London")
        XCTAssertEqual((own["start"] as? [String: String])?["timeZone"], "America/New_York", "the event's own wins")

        let single = GoogleEventPatch.body(fields(), access: .full, recurrence: nil, isRecurring: false)
        XCTAssertNil((single["start"] as? [String: String])?["timeZone"], "a single event keeps what it had")
    }

    func testAnEmptyRepeatIsNeverSent() {
        // It would collapse a series to its first event and delete every other occurrence.
        let body = GoogleEventPatch.body(fields(), access: .full, recurrence: [], isRecurring: true)
        XCTAssertNil(body["recurrence"])
    }

    func testSomeoneElsesInvitationOnlyGetsYourAlertsAndShowAs() {
        let body = GoogleEventPatch.body(fields(reminders: .custom([10, 10, 5])), access: .personalOnly,
                                         recurrence: ["RRULE:FREQ=DAILY"], isRecurring: true)
        XCTAssertEqual(Set(body.keys), ["transparency", "reminders"])
        let reminders = body["reminders"] as? [String: Any]
        XCTAssertEqual((reminders?["overrides"] as? [[String: Any]])?.compactMap { $0["minutes"] as? Int }, [10, 5])
    }

    func testAlertsAreSentOnlyWhenChangedAndAnEmptyPlaceIsCleared() {
        let body = GoogleEventPatch.body(fields(), access: .full, recurrence: nil, isRecurring: false)
        XCTAssertNil(body["reminders"])
        XCTAssertTrue(body["location"] is NSNull)
        XCTAssertEqual(body["transparency"] as? String, "opaque")
    }

    func testTheRepeatGoesOnlyToASeriesOrASingleEvent() {
        XCTAssertTrue(GoogleEventPatch.canCarryRecurrence(eventID: "abc123", recurringEventID: nil))
        XCTAssertFalse(GoogleEventPatch.canCarryRecurrence(eventID: "abc123_20261006T140000Z", recurringEventID: nil))
        XCTAssertFalse(GoogleEventPatch.canCarryRecurrence(eventID: "abc123", recurringEventID: "abc"))
    }

    func testThisAndFollowingCopiesTheSeriesButNotWhatIdentifiesIt() {
        let master: [String: Any] = [
            "id": "old", "iCalUID": "old@google.com", "etag": "\"1\"", "colorId": "5", "visibility": "private",
            "attendees": [["email": "me@example.com", "self": true]], "conferenceData": ["x": 1],
            "recurrence": ["RRULE:FREQ=WEEKLY;BYDAY=TU"], "summary": "Old title",
            "extendedProperties": ["private": ["a": "b"]],
        ]
        let body = GoogleEventPatch.followingSeriesBody(master: master, fields: fields(), rule: ["RRULE:FREQ=WEEKLY;BYDAY=TU"],
                                                        fallbackTimeZoneID: "Europe/London")
        for key in ["id", "iCalUID", "etag", "attendees", "conferenceData", "extendedProperties"] {
            XCTAssertNil(body[key], key)
        }
        XCTAssertNil(body["location"], "a new event leaves out what's empty rather than sending null")
        XCTAssertEqual(body["colorId"] as? String, "5")
        XCTAssertEqual(body["visibility"] as? String, "private")
        XCTAssertEqual(body["summary"] as? String, "Standup")
        XCTAssertEqual(body["recurrence"] as? [String], ["RRULE:FREQ=WEEKLY;BYDAY=TU"])
        XCTAssertEqual((body["start"] as? [String: String])?["timeZone"], "Europe/London")
    }
}

final class GoogleOwnWritesTests: XCTestCase {
    func testAnOccurrenceOfASeriesBananaWroteIsBananasOwn() {
        let now = Date()
        let own = ["abc123": now]
        XCTAssertEqual(GoogleOwnWrites.writtenAt("abc123", in: own), now)
        XCTAssertEqual(GoogleOwnWrites.writtenAt("abc123_20261006T140000Z", in: own), now,
                       "a repeat added to it gives every occurrence a new id")
        XCTAssertNil(GoogleOwnWrites.writtenAt("other_20261006T140000Z", in: own))
        XCTAssertFalse(GoogleEventSync.containsNews(["abc123_20261006T140000Z", "abc123_20261008T140000Z"],
                                                    ownWrites: own, now: now))
        XCTAssertTrue(GoogleEventSync.containsNews(["zzz"], ownWrites: own, now: now))
    }
}

final class GoogleRecurrenceAllDayTruncationTests: XCTestCase {
    func testAnAllDaySeriesIsCutWithADate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let cutoff = calendar.date(from: DateComponents(year: 2026, month: 10, day: 7))!
        XCTAssertEqual(GoogleRecurrenceRule.truncated(["RRULE:FREQ=DAILY;COUNT=30", "EXDATE;VALUE=DATE:20261003"],
                                                      before: cutoff, allDay: true, calendar: calendar),
                       ["RRULE:FREQ=DAILY;UNTIL=20261006", "EXDATE;VALUE=DATE:20261003"])
    }

    // MARK: - Guests on an event that exists

    private var guestList: [[String: Any]] {
        [["email": "me@example.com", "self": true, "organizer": true, "responseStatus": "accepted"],
         ["email": "Sam@Example.com", "displayName": "Sam", "responseStatus": "accepted", "comment": "running late"],
         ["email": "pat@example.com", "responseStatus": "declined", "optional": true]]
    }

    func testAddingAGuestSendsEveryoneElseBackExactlyAsGoogleHasThem() throws {
        let updated = try XCTUnwrap(GoogleGuestPatch.attendees(guestList, change: .init(adding: ["Alex@Example.com "])))
        XCTAssertEqual(updated.count, 4)
        // A list rebuilt from addresses would reset every reply to "awaiting".
        XCTAssertEqual(updated[1]["responseStatus"] as? String, "accepted")
        XCTAssertEqual(updated[1]["comment"] as? String, "running late")
        XCTAssertEqual(updated[1]["email"] as? String, "Sam@Example.com", "untouched, case and all")
        XCTAssertEqual(updated[2]["optional"] as? Bool, true)
        XCTAssertEqual(updated[3] as? [String: String], ["email": "alex@example.com"])
    }

    func testSomeoneAlreadyOnItIsNotInvitedTwice() {
        XCTAssertNil(GoogleGuestPatch.attendees(guestList, change: .init(adding: ["sam@example.com"])))
        let twice = GoogleGuestPatch.attendees(guestList, change: .init(adding: ["alex@example.com", "ALEX@example.com"]))
        XCTAssertEqual(twice?.count, 4)
    }

    func testTakingAGuestOffLeavesTheRest() throws {
        let updated = try XCTUnwrap(GoogleGuestPatch.attendees(guestList, change: .init(removing: ["sam@example.com"])))
        XCTAssertEqual(updated.compactMap { $0["email"] as? String }, ["me@example.com", "pat@example.com"])
        XCTAssertEqual(updated[1]["responseStatus"] as? String, "declined")
    }

    func testTheOrganizerAndYouAreNeverTakenOff() {
        XCTAssertNil(GoogleGuestPatch.attendees(guestList, change: .init(removing: ["me@example.com"])))
        let theirs: [[String: Any]] = [["email": "boss@example.com", "organizer": true], ["email": "me@example.com", "self": true]]
        XCTAssertNil(GoogleGuestPatch.attendees(theirs, change: .init(removing: ["boss@example.com", "me@example.com"])))
    }

    func testNothingIsSentWhenNothingChanges() {
        XCTAssertNil(GoogleGuestPatch.attendees(guestList, change: .init()))
        XCTAssertNil(GoogleGuestPatch.attendees(guestList, change: .init(removing: ["nobody@example.com"])))
    }

    func testANameWithoutAnAddressIsNeverInvited() {
        XCTAssertNil(GoogleGuestPatch.attendees([], change: .init(adding: ["Sam", "sam@", "@example.com", "sam smith@example.com", "sam@example"])))
        XCTAssertEqual(GoogleGuestPatch.attendees([], change: .init(adding: ["sam@example.com"]))?.count, 1)
    }

    func testAnEventWithNoGuestsGetsItsFirst() {
        XCTAssertEqual(GoogleGuestPatch.attendees([], change: .init(adding: ["sam@example.com"])) as? [[String: String]],
                       [["email": "sam@example.com"]])
    }

    func testAddingAndRemovingInOneSave() throws {
        let updated = try XCTUnwrap(GoogleGuestPatch.attendees(
            guestList, change: .init(adding: ["alex@example.com"], removing: ["pat@example.com"])))
        XCTAssertEqual(updated.compactMap { $0["email"] as? String }, ["me@example.com", "Sam@Example.com", "alex@example.com"])
    }

    func testAGuestChangeIsAlwaysEmailed() {
        // No other guests yet: an ordinary edit is quiet, an invitation is not.
        XCTAssertFalse(GoogleEventEditPolicy.notifiesGuests(organizerIsSelf: nil, otherGuestCount: 0, guests: .init()))
        XCTAssertTrue(GoogleEventEditPolicy.notifiesGuests(organizerIsSelf: nil, otherGuestCount: 0,
                                                           guests: .init(adding: ["sam@example.com"])))
        XCTAssertTrue(GoogleEventEditPolicy.notifiesGuests(organizerIsSelf: true, otherGuestCount: 1,
                                                           guests: .init(removing: ["sam@example.com"])))
        XCTAssertTrue(GoogleEventEditPolicy.notifiesGuests(organizerIsSelf: true, otherGuestCount: 2, guests: .init()))
    }

    func testTheSavedToastSaysWhoWasInvitedAndRemoved() {
        XCTAssertEqual(GoogleGuestChange.savedSuffix(invited: [], removed: []), "")
        XCTAssertEqual(GoogleGuestChange.savedSuffix(invited: ["Sam"], removed: []), " \u{00B7} invited Sam")
        XCTAssertEqual(GoogleGuestChange.savedSuffix(invited: ["Sam", "Alex"], removed: ["Pat"]),
                       " \u{00B7} invited Sam and Alex, removed Pat")
    }

    func testASeriesIsNeverSplitWithAGuestChange() {
        // The editor counts the people being invited, so "This and following" isn't offered.
        XCTAssertEqual(GoogleEventEditScope.question(isRecurring: true, repeatChanged: false, repeatTurnedOff: false,
                                                     otherGuestCount: 0 + 1, usesCount: false), .thisOrAll)
    }
}
