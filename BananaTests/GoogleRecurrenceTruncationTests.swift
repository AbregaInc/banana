import XCTest

/// Truncating a Google recurrence so a series stops before a chosen occurrence.
///
/// Google's API has no "delete this and all following" verb — the operation is an `RRULE` rewrite.
/// Banana previously mapped that choice to "delete the entire series", which threw away the
/// earlier occurrences the person was explicitly keeping; the button even relabelled itself to
/// admit it.
final class GoogleRecurrenceTruncationTests: XCTestCase {
    private typealias G = GoogleRecurrenceRule

    /// Sat 26 Sep 2026, 11:30 UTC — the first occurrence being removed.
    private let cutoff = ISO8601DateFormatter().date(from: "2026-09-26T11:30:00Z")!

    func testAnUntilIsAppendedOneSecondBeforeTheCutoff() {
        let result = G.truncated(["RRULE:FREQ=DAILY"], before: cutoff)
        XCTAssertEqual(result, ["RRULE:FREQ=DAILY;UNTIL=20260926T112959Z"])
    }

    /// RFC 5545 makes UNTIL inclusive, so the last kept instance is the one at or before it.
    /// Placing it a second early is what keeps Friday and drops Saturday.
    func testTheCutoffIsExclusiveOfTheOccurrenceBeingRemoved() {
        let until = G.truncated(["RRULE:FREQ=DAILY"], before: cutoff)[0]
        XCTAssertTrue(until.hasSuffix("UNTIL=20260926T112959Z"))
        XCTAssertFalse(until.contains("20260926T113000Z"), "would keep the occurrence being deleted")
    }

    /// A stale COUNT or UNTIL left beside the new one is how a truncation silently does nothing.
    func testAnExistingUntilIsReplacedNotDuplicated() {
        let result = G.truncated(["RRULE:FREQ=DAILY;UNTIL=20271231T000000Z"], before: cutoff)
        XCTAssertEqual(result, ["RRULE:FREQ=DAILY;UNTIL=20260926T112959Z"])
    }

    func testAnExistingCountIsDropped() {
        let result = G.truncated(["RRULE:FREQ=WEEKLY;COUNT=52;BYDAY=MO"], before: cutoff)
        XCTAssertEqual(result, ["RRULE:FREQ=WEEKLY;BYDAY=MO;UNTIL=20260926T112959Z"])
    }

    func testOtherRulePartsAreKept() {
        let result = G.truncated(["RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,TH"], before: cutoff)
        XCTAssertEqual(result, ["RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,TH;UNTIL=20260926T112959Z"])
    }

    /// EXDATE/RDATE lines are part of the recurrence array and must survive untouched.
    func testNonRuleLinesArePassedThrough() {
        let result = G.truncated(
            ["RRULE:FREQ=DAILY", "EXDATE;TZID=America/New_York:20260924T073000"],
            before: cutoff)
        XCTAssertEqual(result[1], "EXDATE;TZID=America/New_York:20260924T073000")
        XCTAssertTrue(result[0].hasSuffix("UNTIL=20260926T112959Z"))
    }

    /// UNTIL must be UTC basic format regardless of the device's locale or time zone.
    func testTheUntilIsUTCBasicFormat() {
        let until = G.truncated(["RRULE:FREQ=DAILY"], before: cutoff)[0]
        XCTAssertNotNil(until.range(of: #"UNTIL=\d{8}T\d{6}Z$"#, options: .regularExpression))
    }
}
