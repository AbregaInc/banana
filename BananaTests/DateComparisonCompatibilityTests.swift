import XCTest
import Foundation

final class DateComparisonCompatibilityTests: XCTestCase {
    func testComparisonsMatchNumericOrderingIncludingNonfiniteDates() {
        let values = [-Double.infinity, Date.distantPast.timeIntervalSinceReferenceDate,
                      -1, 0, 1, Date.distantFuture.timeIntervalSinceReferenceDate,
                      Double.infinity, Double.nan]
        for lhs in values {
            for rhs in values {
                let left = Date(timeIntervalSinceReferenceDate: lhs)
                let right = Date(timeIntervalSinceReferenceDate: rhs)
                XCTAssertEqual(left >= right, lhs >= rhs)
                XCTAssertEqual(left <= right, lhs <= rhs)
            }
        }
    }

    func testStoredComparatorsAndRetryBoundary() {
        let atLeast: (Date, Date) -> Bool = (>=)
        let atMost: (Date, Date) -> Bool = (<=)
        let deadline = Date(timeIntervalSinceReferenceDate: 123)
        XCTAssertFalse(atLeast(deadline.addingTimeInterval(-1), deadline))
        XCTAssertTrue(atLeast(deadline, deadline))
        XCTAssertTrue(atMost(deadline, deadline))
        XCTAssertFalse(atMost(deadline.addingTimeInterval(1), deadline))
    }
}
