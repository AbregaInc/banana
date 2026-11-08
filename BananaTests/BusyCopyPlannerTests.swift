import XCTest

/// The one planner behind Busy copies (`BusyCopyPlanner`): what a write-back pass does on a
/// calendar, and therefore what the first run's consent screen counts before anyone says yes.
final class BusyCopyPlannerTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var later: Date { now.addingTimeInterval(3_600) }
    private var earlier: Date { now.addingTimeInterval(-3_600) }

    private func wanted(_ id: String, _ fingerprint: Int = 1) -> BusyCopyPlanner.Desired {
        BusyCopyPlanner.Desired(appItemID: id, ledgerKey: "\(id)|work", fingerprint: fingerprint)
    }

    private func owned(_ eventID: String, etag: String = "e", end: Date? = nil) -> BusyCopyPlanner.Owned {
        BusyCopyPlanner.Owned(eventID: eventID, etag: etag, end: end ?? later)
    }

    func testANewCalendarGetsOneCreatePerWantedBlock() {
        let plan = BusyCopyPlanner.plan(desired: [wanted("a"), wanted("b"), wanted("c")], owned: [:], recorded: [:], now: now)
        XCTAssertEqual(plan.creates, 3)
        XCTAssertEqual(plan.updates, 0)
        XCTAssertEqual(plan.removals, 0)
        XCTAssertEqual(plan.writes, [.create(index: 0), .create(index: 1), .create(index: 2)])
    }

    func testAnUnchangedCopyIsLeftAlone() {
        let recorded = ["a|work": BusyCopyPlanner.Recorded(eventID: "x", fingerprint: 1, etag: "e")]
        let plan = BusyCopyPlanner.plan(desired: [wanted("a")], owned: ["a": [owned("x")]], recorded: recorded, now: now)
        XCTAssertTrue(plan.writes.isEmpty)
    }

    func testAChangedOrUnrecordedCopyIsRewrittenInPlace() {
        let recorded = ["a|work": BusyCopyPlanner.Recorded(eventID: "x", fingerprint: 1, etag: "e")]
        let moved = BusyCopyPlanner.plan(desired: [wanted("a", 2)], owned: ["a": [owned("x")]], recorded: recorded, now: now)
        XCTAssertEqual(moved.writes, [.update(index: 0, eventID: "x", etag: "e")])
        // Written by another device: this one has no record, so it rewrites rather than duplicates.
        let foreign = BusyCopyPlanner.plan(desired: [wanted("a")], owned: ["a": [owned("x", etag: "f")]], recorded: [:], now: now)
        XCTAssertEqual(foreign.writes, [.update(index: 0, eventID: "x", etag: "f")])
        XCTAssertEqual(foreign.creates, 0)
    }

    func testACopyAlreadySayingWhatIsWantedIsNeverWritten() {
        // Written by another device, so this one's record is stale or missing — and it says
        // exactly what this pass wants. Nothing to write; the ledger just learns the version.
        let wantedCopy = BusyCopyPlanner.Desired(appItemID: "a", ledgerKey: "a|work", fingerprint: 1, content: "Busy|10:00")
        let stale = ["a|work": BusyCopyPlanner.Recorded(eventID: "x", fingerprint: 1, etag: "old")]
        for recorded in [stale, [:]] {
            let plan = BusyCopyPlanner.plan(
                desired: [wantedCopy],
                owned: ["a": [BusyCopyPlanner.Owned(eventID: "x", etag: "new", end: later, content: "Busy|10:00")]],
                recorded: recorded, now: now)
            XCTAssertTrue(plan.writes.isEmpty, "a copy that already matches was written again")
            XCTAssertEqual(plan.matches, [.init(index: 0, eventID: "x", etag: "new")])
            XCTAssertEqual(plan.updates, 0)
        }
    }

    func testACopySayingSomethingElseIsRewrittenWhateverThisDeviceRecorded() {
        // This device's record says it wrote this very version, but the server copy reads
        // differently (edited by hand, or written from older inputs): what the server says wins.
        let recorded = ["a|work": BusyCopyPlanner.Recorded(eventID: "x", fingerprint: 1, etag: "e")]
        let plan = BusyCopyPlanner.plan(
            desired: [BusyCopyPlanner.Desired(appItemID: "a", ledgerKey: "a|work", fingerprint: 1, content: "Busy|10:00")],
            owned: ["a": [BusyCopyPlanner.Owned(eventID: "x", etag: "e", end: later, content: "Busy|10:05")]],
            recorded: recorded, now: now)
        XCTAssertEqual(plan.writes, [.update(index: 0, eventID: "x", etag: "e")])
        XCTAssertTrue(plan.matches.isEmpty)
    }

    func testDuplicatesKeepTheSameCopyOnEveryDevice() {
        let plan = BusyCopyPlanner.plan(desired: [wanted("a")], owned: ["a": [owned("y"), owned("x")]], recorded: [:], now: now)
        XCTAssertEqual(plan.duplicates.map(\.eventID), ["y"])
        XCTAssertEqual(plan.writes, [.update(index: 0, eventID: "x", etag: "e")])
        XCTAssertEqual(plan.removals, 1)
    }

    func testOnlyCurrentUnwantedCopiesAreCountedForRemoval() {
        let plan = BusyCopyPlanner.plan(desired: [], owned: ["gone": [owned("g")], "past": [owned("p", end: earlier)]],
                                        recorded: [:], now: now)
        XCTAssertEqual(Array(plan.unwanted.keys), ["gone"], "a block that is over protects nothing; removing it is churn")
        XCTAssertEqual(plan.removals, 1)
    }

    // MARK: - Devices taking turns

    /// Google's side of one calendar: the copies Banana owns, each with the version and content a
    /// read would return. Every write gives the copy a new version, as Google does — even when the
    /// content is the same.
    private struct Server {
        var copies: [String: (eventID: String, etag: String, content: String)] = [:]
        var versions = 0
        var writes = 0

        mutating func write(_ item: String, content: String) {
            versions += 1
            writes += 1
            copies[item] = (copies[item]?.eventID ?? "event-\(item)", "v\(versions)", content)
        }

        func owned(readingContent: Bool) -> [String: [BusyCopyPlanner.Owned]] {
            copies.mapValues { [BusyCopyPlanner.Owned(eventID: $0.eventID, etag: $0.etag, end: Date.distantFuture,
                                                      content: readingContent ? $0.content : nil)] }
        }
    }

    /// One device's write-back pass over the server, with its own ledger.
    private struct Device {
        var recorded: [String: BusyCopyPlanner.Recorded] = [:]

        mutating func pass(wanting items: [String: String], on server: inout Server, readingContent: Bool, now: Date) {
            let keys = items.keys.sorted()
            let desired = keys.map {
                BusyCopyPlanner.Desired(appItemID: $0, ledgerKey: "\($0)|work", fingerprint: items[$0]!.hashValue,
                                        content: readingContent ? items[$0] : nil)
            }
            let plan = BusyCopyPlanner.plan(desired: desired, owned: server.owned(readingContent: readingContent),
                                            recorded: recorded, now: now)
            for match in plan.matches {
                recorded[desired[match.index].ledgerKey] = .init(eventID: match.eventID,
                                                                 fingerprint: desired[match.index].fingerprint, etag: match.etag)
            }
            for write in plan.writes {
                let index: Int
                switch write {
                case .create(let i): index = i
                case .update(let i, _, _): index = i
                }
                let item = keys[index]
                server.write(item, content: items[item]!)
                recorded[desired[index].ledgerKey] = .init(eventID: server.copies[item]!.eventID,
                                                           fingerprint: desired[index].fingerprint,
                                                           etag: server.copies[item]!.etag)
            }
        }
    }

    /// Two devices wanting the same blocks, each running a pass after the other's writes (every
    /// write reaches the other as calendar news). Comparing versions, each rewrote whatever the
    /// other had just written, and that never ended; comparing content, they settle at once.
    func testTwoDevicesWantingTheSameBlocksSettleInsteadOfTakingTurns() {
        let wanted = ["travel-1": "Busy|15:35|15:45", "mirror-2": "Busy|09:00|10:00", "task-3": "Busy|12:00|12:30"]
        func run(readingContent: Bool) -> [Int] {
            var server = Server()
            var phone = Device(), iPad = Device()
            var writesPerRound: [Int] = []
            for _ in 0..<10 {
                let before = server.writes
                phone.pass(wanting: wanted, on: &server, readingContent: readingContent, now: now)
                iPad.pass(wanting: wanted, on: &server, readingContent: readingContent, now: now)
                writesPerRound.append(server.writes - before)
            }
            return writesPerRound
        }

        let byVersion = run(readingContent: false)
        XCTAssertEqual(byVersion.suffix(5), [6, 6, 6, 6, 6],
                       "the old rule: every round, both devices rewrite all three copies")
        let byContent = run(readingContent: true)
        XCTAssertEqual(byContent.first, 3, "the first device writes each block once")
        XCTAssertEqual(byContent.dropFirst().reduce(0, +), 0, "and then nobody writes again")
    }

    // MARK: - What a copy says

    func testContentReadBackFromGoogleEqualsWhatWasWritten() {
        // A time with a fraction is written as its whole second; read back, it is that second.
        let wanted = Date(timeIntervalSince1970: 1_800_000_000.75)
        let stored = Date(timeIntervalSince1970: 1_800_000_000)
        let end = stored.addingTimeInterval(600)
        XCTAssertEqual(GoogleBusyBlocks.content(title: "Busy", start: wanted, end: end, isAllDay: false),
                       GoogleBusyBlocks.content(title: "Busy", start: stored, end: end, isAllDay: false))
        XCTAssertNotEqual(GoogleBusyBlocks.content(title: "Busy", start: stored, end: end, isAllDay: false),
                          GoogleBusyBlocks.content(title: "Busy", start: stored.addingTimeInterval(300), end: end, isAllDay: false))
        XCTAssertNotEqual(GoogleBusyBlocks.content(title: "Busy", start: stored, end: end, isAllDay: false),
                          GoogleBusyBlocks.content(title: "Lunch", start: stored, end: end, isAllDay: false))
        // What the writer sends for that time is the same second.
        let body = GoogleBusyBlocks.body(title: "Busy", start: wanted, end: end, timeZoneID: "UTC",
                                         appItemID: "a", variant: "banana-beta")
        let sent = (body["start"] as? [String: Any])?["dateTime"] as? String
        XCTAssertEqual(sent.flatMap(GoogleCalendarDates.parseRFC3339), stored)
    }

    func testAllDayContentComparesDates() {
        let day = GoogleCalendarDates.parseDate("2026-12-01")!
        let next = GoogleCalendarDates.parseDate("2026-12-02")!
        XCTAssertEqual(GoogleBusyBlocks.content(title: "Busy", start: day, end: next, isAllDay: true),
                       GoogleBusyBlocks.content(title: "Busy", start: day, end: next, isAllDay: true))
        XCTAssertNotEqual(GoogleBusyBlocks.content(title: "Busy", start: day, end: next, isAllDay: true),
                          GoogleBusyBlocks.content(title: "Busy", start: day, end: next, isAllDay: false))
    }

    // MARK: - Refused writes

    func testARefusedWriteWaitsUntilSomethingChanged() {
        var refusals = BusyCopyRefusals()
        refusals.refuse("a|work", fingerprint: 1, etag: "e", now: now)
        XCTAssertTrue(refusals.holds("a|work", fingerprint: 1, etag: "e", now: now.addingTimeInterval(60)),
                      "the same write over the same copy is not sent again a minute later")
        XCTAssertFalse(refusals.holds("a|work", fingerprint: 2, etag: "e", now: now), "a different write goes")
        XCTAssertFalse(refusals.holds("a|work", fingerprint: 1, etag: "f", now: now), "the copy changed: try again")
        XCTAssertFalse(refusals.holds("b|work", fingerprint: 1, etag: "e", now: now))
        XCTAssertFalse(refusals.holds("a|work", fingerprint: 1, etag: "e",
                                      now: now.addingTimeInterval(BusyCopyRefusals.quiet + 1)), "and in time anyway")
        refusals.clear("a|work")
        XCTAssertFalse(refusals.holds("a|work", fingerprint: 1, etag: "e", now: now))
        XCTAssertTrue(BusyCopyRefusals.isRefusal(status: 409))
        XCTAssertTrue(BusyCopyRefusals.isRefusal(status: 428))
        XCTAssertFalse(BusyCopyRefusals.isRefusal(status: 412), "a stale version is retried with the new one")
        XCTAssertFalse(BusyCopyRefusals.isRefusal(status: 502))
    }

    func testAPreviewOnlyAgreesWithTheSamePlan() {
        let shown = BusyCopyPreview(destinations: [.init(id: "w", title: "Work", creates: 12)], sources: ["Personal"])
        XCTAssertTrue(shown.agrees(with: shown))
        var more = shown
        more.destinations[0].creates = 13
        XCTAssertFalse(shown.agrees(with: more), "a yes for 12 is not a yes for 13")
        var elsewhere = shown
        elsewhere.destinations.append(.init(id: "p", title: "Personal", creates: 1))
        XCTAssertFalse(shown.agrees(with: elsewhere))
        XCTAssertEqual(elsewhere.creates, 13)
        XCTAssertEqual(elsewhere.changing.map(\.title), ["Work", "Personal"])
    }
}
