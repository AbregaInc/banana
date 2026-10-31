import XCTest

/// Incremental reads: when a copy may be continued, how changes land, and what counts as news.
final class GoogleEventSyncTests: XCTestCase {
    private func event(_ id: String, status: String = "confirmed", updated: String = "2026-09-01T00:00:00Z",
                       start: String = "2026-10-05T15:00:00Z", summary: String = "Meeting") -> GoogleEvent {
        let json: [String: Any] = [
            "id": id, "status": status, "updated": updated, "summary": summary,
            "start": ["dateTime": start], "end": ["dateTime": "2026-10-05T16:00:00Z"],
        ]
        return try! JSONDecoder().decode(GoogleEvent.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private let window = (start: Date(timeIntervalSince1970: 1_000_000), end: Date(timeIntervalSince1970: 5_000_000))

    private func snapshot(token: String? = "t1", fullReadAt: Date = Date(timeIntervalSince1970: 2_000_000),
                          events: [GoogleEvent] = []) -> GoogleEventSync.Snapshot {
        GoogleEventSync.Snapshot(start: window.start, end: window.end, fetchedAt: fullReadAt,
                                 fullReadAt: fullReadAt, syncToken: token, events: events)
    }

    // MARK: When to start over

    func testContinuesTheSameWindowWithAToken() {
        let now = Date(timeIntervalSince1970: 2_000_000 + 3600)
        XCTAssertTrue(GoogleEventSync.canContinue(snapshot(), window: window, now: now))
    }

    func testReadsInFullWithoutACopyOrAToken() {
        let now = Date(timeIntervalSince1970: 2_000_100)
        XCTAssertFalse(GoogleEventSync.canContinue(nil, window: window, now: now))
        XCTAssertFalse(GoogleEventSync.canContinue(snapshot(token: nil), window: window, now: now))
        XCTAssertFalse(GoogleEventSync.canContinue(snapshot(token: ""), window: window, now: now))
    }

    func testANewDaysWindowIsReadInFull() {
        // Events beyond the old window's end were never listed; continuing would never show them.
        let now = Date(timeIntervalSince1970: 2_000_100)
        let slid = (start: window.start.addingTimeInterval(86_400), end: window.end.addingTimeInterval(86_400))
        XCTAssertFalse(GoogleEventSync.canContinue(snapshot(), window: slid, now: now))
    }

    func testADayOldCopyIsReadInFull() {
        let now = Date(timeIntervalSince1970: 2_000_000 + 25 * 3600)
        XCTAssertFalse(GoogleEventSync.canContinue(snapshot(), window: window, now: now))
    }

    func testAClockThatWentBackwardsReadsInFull() {
        let now = Date(timeIntervalSince1970: 1_999_000)
        XCTAssertFalse(GoogleEventSync.canContinue(snapshot(), window: window, now: now))
    }

    // MARK: Applying changes

    func testChangesReplaceAddAndRemoveByID() {
        let cached = [event("a", summary: "A"), event("b", summary: "B"), event("c", summary: "C")]
        let result = GoogleEventSync.apply([
            event("b", summary: "B moved"),
            event("c", status: "cancelled"),
            event("d", summary: "D new"),
        ], to: cached)
        XCTAssertEqual(result.map(\.id), ["a", "b", "d"])
        XCTAssertEqual(result.map(\.summary), ["A", "B moved", "D new"])
    }

    func testCancellingSomethingNeverSeenIsHarmless() {
        let result = GoogleEventSync.apply([event("zzz", status: "cancelled")], to: [event("a")])
        XCTAssertEqual(result.map(\.id), ["a"])
    }

    func testNoChangesLeavesTheCopyAlone() {
        let cached = [event("a"), event("b")]
        XCTAssertEqual(GoogleEventSync.apply([], to: cached).map(\.id), ["a", "b"])
    }

    // MARK: What counts as news

    func testAFullReReadFindsWhatChanged() {
        let before = [event("a"), event("b"), event("c")]
        let after = [event("a"), event("b", updated: "2026-09-02T00:00:00Z"), event("d")]
        XCTAssertEqual(GoogleEventSync.changedIDs(from: before, to: after), ["b", "c", "d"])
        XCTAssertEqual(GoogleEventSync.changedIDs(from: before, to: before), [])
    }

    func testBananasOwnWritesAreNotNews() {
        let now = Date()
        let own = ["block-1": now.addingTimeInterval(-30)]
        XCTAssertFalse(GoogleEventSync.containsNews(["block-1"], ownWrites: own, now: now))
        XCTAssertTrue(GoogleEventSync.containsNews(["block-1", "meeting-9"], ownWrites: own, now: now))
        XCTAssertFalse(GoogleEventSync.containsNews([], ownWrites: own, now: now))
    }

    func testAnOldOwnWriteIsNewsAgain() {
        // Someone else editing a block Banana wrote an hour ago is a real change.
        let now = Date()
        let own = ["block-1": now.addingTimeInterval(-3600)]
        XCTAssertTrue(GoogleEventSync.containsNews(["block-1"], ownWrites: own, now: now))
        XCTAssertEqual(GoogleEventSync.pruned(own, now: now), [:])
    }

    // MARK: Disk

    func testSnapshotsRoundTripAndPruneOnDisk() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("google-sync-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let kept = snapshot(events: [event("a"), event("b")])
        GoogleEventDiskCache.save(kept, calendarID: "me@example.com", in: directory)
        GoogleEventDiskCache.save(snapshot(), calendarID: "gone#holiday@group.v.calendar.google.com", in: directory)

        let loaded = try XCTUnwrap(GoogleEventDiskCache.load(calendarID: "me@example.com", in: directory))
        XCTAssertEqual(loaded, kept)
        XCTAssertEqual(loaded.events.map(\.id), ["a", "b"])

        GoogleEventDiskCache.prune(keeping: ["me@example.com"], in: directory)
        XCTAssertNotNil(GoogleEventDiskCache.load(calendarID: "me@example.com", in: directory))
        XCTAssertNil(GoogleEventDiskCache.load(calendarID: "gone#holiday@group.v.calendar.google.com", in: directory))
    }

    func testTheWholeEventSurvivesTheDiskCopy() throws {
        let json: [String: Any] = [
            "id": "x", "status": "confirmed", "summary": "Review", "iCalUID": "UID-1",
            "start": ["dateTime": "2026-10-05T15:00:00Z", "timeZone": "America/New_York"],
            "end": ["dateTime": "2026-10-05T16:00:00Z"],
            "attendees": [["email": "me@example.com", "self": true, "responseStatus": "tentative"]],
            "extendedProperties": ["private": [GoogleBusyBlocks.variantKey: "banana"]],
            "transparency": "transparent",
        ]
        let original = try JSONDecoder().decode(GoogleEvent.self, from: JSONSerialization.data(withJSONObject: json))
        let copy = try JSONDecoder().decode(GoogleEvent.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(copy.attendees?.first?.selfAttendee, true)
        XCTAssertEqual(copy.attendees?.first?.responseStatus, "tentative")
        XCTAssertEqual(copy.extendedProperties?.private?[GoogleBusyBlocks.variantKey], "banana")
        XCTAssertEqual(copy.transparency, "transparent")
        XCTAssertEqual(copy.iCalUID, "UID-1")
        XCTAssertEqual(copy.start?.timeZone, "America/New_York")
    }
}

/// Today's events vanished, then came back: after midnight the rolling window moved, the day's
/// first (full) read of a calendar failed, and the last good copy — "not covering" the moved
/// window — was ignored, so the calendar showed nothing until a read succeeded.
final class IncompleteReadFallbackTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private let yesterday = Date(timeIntervalSince1970: 1_790_000_000)

    private func copy(start: Date, days: Double) -> GoogleEventSync.Snapshot {
        GoogleEventSync.Snapshot(start: start, end: start.addingTimeInterval(days * day), fetchedAt: start,
                                 fullReadAt: start, syncToken: "t", events: [])
    }

    func testAnExcludedCalendarIsNotCarriedWhenAnotherCalendarCannotBeRead() {
        let now = Date()
        XCTAssertFalse(GoogleEventSync.keepsThroughIncompleteRead(
            calendarID: "wife", covered: [], excluded: ["wife"], replaced: false,
            start: now, end: now.addingTimeInterval(3600), window: (now, now.addingTimeInterval(86400))))
    }

    func testYesterdaysCopyStandsInForTodaysWindow() {
        let saved = copy(start: yesterday.addingTimeInterval(-8 * day), days: 54)
        let today = (yesterday.addingTimeInterval(-7 * day), yesterday.addingTimeInterval(47 * day))
        XCTAssertFalse(saved.covers(today.0, today.1), "the moved window is never fully covered")
        XCTAssertTrue(GoogleEventSync.overlaps(saved, today.0, today.1))
    }

    func testACopyFromAnotherStretchOfTimeDoesNot() {
        let saved = copy(start: yesterday, days: 7)
        XCTAssertFalse(GoogleEventSync.overlaps(saved, yesterday.addingTimeInterval(30 * day),
                                                yesterday.addingTimeInterval(40 * day)))
    }

    func testAnUnreadCalendarKeepsItsEventsOnScreen() {
        let window = (start: yesterday, end: yesterday.addingTimeInterval(31 * day))
        let at = yesterday.addingTimeInterval(day + 3_600)
        XCTAssertTrue(GoogleEventSync.keepsThroughIncompleteRead(
            calendarID: "work", covered: ["home"], replaced: false, start: at, end: at + 1_800, window: window))
    }

    func testARereadOrReplacedEventIsNotDuplicated() {
        let window = (start: yesterday, end: yesterday.addingTimeInterval(31 * day))
        let at = yesterday.addingTimeInterval(day)
        XCTAssertFalse(GoogleEventSync.keepsThroughIncompleteRead(
            calendarID: "work", covered: ["work"], replaced: false, start: at, end: nil, window: window),
                       "a calendar the read has data for shows what the read says")
        XCTAssertFalse(GoogleEventSync.keepsThroughIncompleteRead(
            calendarID: "work", covered: [], replaced: true, start: at, end: nil, window: window))
        XCTAssertFalse(GoogleEventSync.keepsThroughIncompleteRead(
            calendarID: nil, covered: [], replaced: false, start: at, end: nil, window: window))
    }

    func testEventsThatHaveLeftTheWindowGo() {
        let window = (start: yesterday.addingTimeInterval(day), end: yesterday.addingTimeInterval(31 * day))
        XCTAssertFalse(GoogleEventSync.keepsThroughIncompleteRead(
            calendarID: "work", covered: [], replaced: false,
            start: yesterday, end: yesterday.addingTimeInterval(1_800), window: window))
    }
}

/// An account whose calendar list couldn't be read is asked again in half a minute, not in the
/// ten the list lasts: until it is read, its calendars are in no read at all.
final class CalendarListRetryTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func testAFreshCompleteListLastsItsTenMinutes() {
        XCTAssertFalse(GoogleEventSync.calendarListIsStale(loadedAt: now.addingTimeInterval(-9 * 60), isEmpty: false,
                                                           someUnreadable: false, now: now))
        XCTAssertTrue(GoogleEventSync.calendarListIsStale(loadedAt: now.addingTimeInterval(-11 * 60), isEmpty: false,
                                                          someUnreadable: false, now: now))
    }

    func testAnUnreadableAccountIsRetriedAfterHalfAMinute() {
        XCTAssertFalse(GoogleEventSync.calendarListIsStale(loadedAt: now.addingTimeInterval(-10), isEmpty: false,
                                                           someUnreadable: true, now: now),
                       "not on every read: a failing account shouldn't be hammered")
        XCTAssertTrue(GoogleEventSync.calendarListIsStale(loadedAt: now.addingTimeInterval(-45), isEmpty: false,
                                                          someUnreadable: true, now: now))
    }

    func testNoListAtAllIsAlwaysStale() {
        XCTAssertTrue(GoogleEventSync.calendarListIsStale(loadedAt: nil, isEmpty: true, someUnreadable: false, now: now))
        XCTAssertTrue(GoogleEventSync.calendarListIsStale(loadedAt: now, isEmpty: true, someUnreadable: false, now: now))
    }
}

