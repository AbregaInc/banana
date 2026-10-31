import XCTest

/// The next-alert sample on the plan card must not rescan the timeline on every view body.
final class AlertCandidateCacheTests: XCTestCase {
    private func candidate(_ id: String) -> EventAlertPlan.Candidate {
        EventAlertPlan.Candidate(id: id, title: id, start: Date(timeIntervalSince1970: 1_000))
    }

    func testRepeatedReadsOfTheSameSnapshotScanOnce() {
        var cache = AlertCandidateCache()
        var scans = 0
        for _ in 0..<50 {
            let result = cache.candidates(revision: 7, muted: ["work"]) { scans += 1; return [candidate("a")] }
            XCTAssertEqual(result.map(\.id), ["a"])
        }
        XCTAssertEqual(scans, 1)
        XCTAssertEqual(cache.computations, 1)
    }

    func testANewTimelineSnapshotRescans() {
        var cache = AlertCandidateCache()
        _ = cache.candidates(revision: 1, muted: []) { [candidate("a")] }
        let after = cache.candidates(revision: 2, muted: []) { [candidate("b")] }
        XCTAssertEqual(after.map(\.id), ["b"])
        XCTAssertEqual(cache.computations, 2)
    }

    func testAChangedMuteSetRescansEvenForTheSameSnapshot() {
        var cache = AlertCandidateCache()
        _ = cache.candidates(revision: 1, muted: []) { [candidate("a"), candidate("b")] }
        let muted = cache.candidates(revision: 1, muted: ["b"]) { [candidate("a")] }
        XCTAssertEqual(muted.map(\.id), ["a"])
        XCTAssertEqual(cache.computations, 2)
        // And back to the earlier set is a fresh scan too: the cache holds one entry, not a history.
        _ = cache.candidates(revision: 1, muted: []) { [candidate("a"), candidate("b")] }
        XCTAssertEqual(cache.computations, 3)
    }

    func testTheFirstReadAlwaysScans() {
        var cache = AlertCandidateCache()
        let first = cache.candidates(revision: 0, muted: []) { [candidate("a")] }
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(cache.computations, 1)
    }
}
