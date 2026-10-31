import XCTest

/// A due dose says since when, in the same words on the phone's Taken tab and on the wide
/// Nutrition page (`ActionItems.dueText`): the Mac and iPad page used to show its plain time,
/// with nothing to say it was due.
final class DueTextTests: XCTestCase {
    private let eight = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func testInItsFirstMinuteItIsDueNow() {
        XCTAssertEqual(ActionItems.dueText(since: eight, now: eight), "Due now")
        XCTAssertEqual(ActionItems.dueText(since: eight, now: eight.addingTimeInterval(59)), "Due now")
    }

    func testAfterThatItSaysSinceWhen() {
        let text = ActionItems.dueText(since: eight, now: eight.addingTimeInterval(45 * 60))
        XCTAssertEqual(text, "Due since \(eight.formatted(date: .omitted, time: .shortened))")
    }
}
