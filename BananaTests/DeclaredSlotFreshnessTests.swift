import XCTest

/// Prefetched ad-server headers have a shelf life.
///
/// The pods are stitched per request: the headers fetched when you opened a show can describe a
/// different assembly of ads than the one that streams when you press play minutes later. A
/// download is exempt — the bytes captured and the bytes played are the same fetch — but a stale
/// prefetch applied to a fresh stream would skip the wrong seconds.
final class DeclaredSlotFreshnessTests: XCTestCase {

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func slots(capturedAt: Date) -> DeclaredAdSlots {
        DeclaredAdSlots(episodeID: "ep", headers: ["x-megaphone-payload-2": "…"],
                        byteCount: 34_000_000, capturedAt: capturedAt)
    }

    private func isStale(_ slots: DeclaredAdSlots, at moment: Date) -> Bool {
        !slots.isFresh(at: moment)
    }

    func testAFreshPrefetchIsUsed() {
        XCTAssertFalse(isStale(slots(capturedAt: now), at: now.addingTimeInterval(30)))
    }

    func testAPrefetchOlderThanTheWindowIsRefetched() {
        let old = now.addingTimeInterval(-DeclaredAdSlots.freshness - 1)
        XCTAssertTrue(isStale(slots(capturedAt: old), at: now))
    }

    /// The boundary itself counts as fresh, so a capture made exactly at the limit is not thrown
    /// away for the sake of a second.
    func testTheBoundaryCountsAsFresh() {
        let edge = now.addingTimeInterval(-DeclaredAdSlots.freshness)
        XCTAssertFalse(isStale(slots(capturedAt: edge), at: now))
    }

    func testTheWindowIsShortEnoughToMatterButNotHostile() {
        XCTAssertGreaterThanOrEqual(DeclaredAdSlots.freshness, 60)
        XCTAssertLessThanOrEqual(DeclaredAdSlots.freshness, 15 * 60)
    }
}
