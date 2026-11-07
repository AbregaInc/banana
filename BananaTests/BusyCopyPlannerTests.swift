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
