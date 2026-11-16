import XCTest
import Combine

@MainActor final class MailSyncProgressTests: XCTestCase {
    func testPercentageRequiresKnownTotal() {
        let unknown = MailSyncProgress.Value(completed: 25, pending: 75, checking: true)
        XCTAssertNil(unknown.fraction)
        XCTAssertTrue(unknown.isVisible)
        let known = MailSyncProgress.Value(completed: 25, pending: 75, totalKnown: true)
        XCTAssertEqual(known.fraction, 0.25)
        XCTAssertNil(MailSyncProgress.Value(completed: 25, pending: 1_001,
                                           totalKnown: true, pendingIsAtLeast: true).fraction)
    }
    func testIdleAndCompletedWorkDoNotLeaveAProgressIndicator() {
        XCTAssertFalse(MailSyncProgress.Value().isVisible)
        XCTAssertFalse(MailSyncProgress.Value(completed: 100, totalKnown: true).isVisible)
        XCTAssertNil(MailSyncProgress.Value(totalKnown: true).fraction)
        XCTAssertNil(MailSyncProgress.Value(completed: -1, pending: 20, totalKnown: true).fraction)
    }
    func testIdenticalSnapshotsDoNotPublishAgain() {
        let progress = MailSyncProgress()
        var deliveries = 0
        let subscription = progress.$value.dropFirst().sink { _ in deliveries += 1 }
        let value = MailSyncProgress.Value(completed: 1, pending: 3, totalKnown: true)
        progress.update(value); progress.update(value)
        XCTAssertEqual(deliveries, 1)
        withExtendedLifetime(subscription) {}
    }
    func testProgressObservationStartsOnceAndStopsAfterTheLastHeader() async {
        var transitions = 0
        let progress = MailSyncProgress { transitions += 1 }
        let first = progress.observe(), second = progress.observe()
        XCTAssertEqual(transitions, 1)
        first.cancel()
        for _ in 0..<100 where progress.observers != 1 { await Task.yield() }
        XCTAssertEqual(progress.observers, 1)
        XCTAssertEqual(transitions, 1)
        second.cancel()
        for _ in 0..<100 where progress.observers != 0 { await Task.yield() }
        XCTAssertEqual(progress.observers, 0)
        XCTAssertEqual(transitions, 2)
    }
}
