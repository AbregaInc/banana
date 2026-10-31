import XCTest

/// A zone named as changed is fetched, or stays owed until it is.
final class CloudPollRulesTests: XCTestCase {
    func testNothingIsAskedBeforeTheSyncsHaveStarted() {
        // The Mac, 8 Oct 2026: asked two seconds before the workout sync started, the answer
        // named Fitness to nobody, and the trimmed workout wasn't fetched.
        XCTAssertFalse(CloudPollRules.mayAsk(allowed: true, syncsStarted: false, checking: false))
        XCTAssertTrue(CloudPollRules.mayAsk(allowed: true, syncsStarted: true, checking: false))
        XCTAssertFalse(CloudPollRules.mayAsk(allowed: true, syncsStarted: true, checking: true))
        XCTAssertFalse(CloudPollRules.mayAsk(allowed: false, syncsStarted: true, checking: false))
    }

    func testAFetchThatDidNotReachTheEndIsStillOwed() {
        XCTAssertTrue(CloudPollRules.caughtUp(after: .readToTheEnd))
        XCTAssertFalse(CloudPollRules.caughtUp(after: .moreToCome))
        XCTAssertFalse(CloudPollRules.caughtUp(after: .failed), "the network dropped: fetch again next minute")
        XCTAssertFalse(CloudPollRules.caughtUp(after: .notRun), "the phone left the front before it could read")
    }

    func testAnOwedZoneIsFetchedWhetherOrNotItIsNamedAgain() {
        // The minute after a failed fetch: the answer names nothing (the zone was named last time).
        XCTAssertTrue(CloudPollRules.fetches(zone: "Fitness", changed: [], caughtUp: false))
        XCTAssertFalse(CloudPollRules.fetches(zone: "Fitness", changed: [], caughtUp: true), "an idle minute fetches nothing")
        XCTAssertTrue(CloudPollRules.fetches(zone: "Fitness", changed: ["Fitness", "Wellness"], caughtUp: true))
        XCTAssertFalse(CloudPollRules.fetches(zone: "Fitness", changed: ["Wellness"], caughtUp: true))
        XCTAssertTrue(CloudPollRules.fetches(zone: "Fitness", changed: nil, caughtUp: true), "couldn't tell: fetch")
    }
}
