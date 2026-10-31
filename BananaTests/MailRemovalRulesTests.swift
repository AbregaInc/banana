import XCTest

final class MailRemovalRulesTests: XCTestCase {
    private let now: Int64 = 100 * 3_600_000

    func testHoldNeedsBothTwentyRemovalsAndMoreThanAThird() throws {
        for (count, cached, expected) in [(19, 20, false), (20, 60, false), (20, 59, true), (21, 60, true)] {
            let value = try MailRemovalRules.decide(removals: count, cachedMessages: cached,
                previous: [], hasUnresolvedHold: false, nowMS: now)
            XCTAssertEqual(value.hold, expected)
            XCTAssertEqual(value.history.reduce(0) { $0 + $1.count }, expected ? 0 : count)
        }
    }

    func testIncrementalPagesCannotEvadeTheHoldByDeletingSmallBatches() throws {
        let first = try MailRemovalRules.decide(removals: 10, cachedMessages: 50,
            previous: [], hasUnresolvedHold: false, nowMS: now)
        XCTAssertFalse(first.hold)
        let second = try MailRemovalRules.decide(removals: 10, cachedMessages: 40,
            previous: first.history, hasUnresolvedHold: false, nowMS: now + 1)
        XCTAssertTrue(second.hold)
        XCTAssertEqual(second.history, first.history, "Held removals are not applied deletions")
    }

    func testUnansweredHoldAccumulatesEvenWhenNewBatchIsSmall() throws {
        let value = try MailRemovalRules.decide(removals: 1, cachedMessages: 10_000,
            previous: [], hasUnresolvedHold: true, nowMS: now)
        XCTAssertTrue(value.hold)
        XCTAssertTrue(value.history.isEmpty)
    }

    func testBoundaryHourAndBackwardsClockCannotEraseRecentRemovals() throws {
        for hour in [Int64(76), 100, 101] {
            let value = try MailRemovalRules.decide(removals: 10, cachedMessages: 40,
                previous: [.init(hour: hour, count: 10)], hasUnresolvedHold: false, nowMS: now)
            XCTAssertTrue(value.hold)
        }
        let expired = try MailRemovalRules.decide(removals: 10, cachedMessages: 40,
            previous: [.init(hour: 75, count: 10)], hasUnresolvedHold: false, nowMS: now)
        XCTAssertFalse(expired.hold)
    }

    func testMalformedAccountingFailsInsteadOfPermittingDeletion() {
        for history in [[MailRemovalRules.Hour(hour: 100, count: -1)],
                        [.init(hour: 100, count: Int.max), .init(hour: 100, count: 1)]] {
            XCTAssertThrowsError(try MailRemovalRules.decide(removals: 1, cachedMessages: 40,
                previous: history, hasUnresolvedHold: false, nowMS: now))
        }
        XCTAssertThrowsError(try MailRemovalRules.decide(removals: 41, cachedMessages: 40,
            previous: [], hasUnresolvedHold: false, nowMS: now))
    }
}
