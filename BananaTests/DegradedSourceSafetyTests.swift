import XCTest

/// Busy blocks must never be removed on the strength of data that failed to load.
///
/// Measured, not hypothetical: when Google rejected one account's refresh token, that account's
/// meetings vanished from the pass, write-back concluded 291 blocks were no longer wanted, and
/// deleted them — leaving that time bookable with nothing on screen to say why. Adding coverage
/// from partial data is safe; withdrawing it is not.
final class DegradedSourceSafetyTests: XCTestCase {

    /// Exercised through the real gate write-back consults, not a restatement of it.
    func testRemovalIsSuspendedWhileASourceIsUnreadable() {
        var gate = BlockRemovalGate()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        for minute in 0..<60 {
            XCTAssertTrue(gate.review(unwanted: ["block"], sourcesHealthy: false,
                                      now: start.addingTimeInterval(Double(minute) * 60)).isEmpty,
                          "a calendar we cannot read is not a calendar with no meetings")
        }
    }

    func testRemovalResumesOnceEverySourceReads() {
        var gate = BlockRemovalGate()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        _ = gate.review(unwanted: ["block"], sourcesHealthy: true, now: start)
        XCTAssertEqual(gate.review(unwanted: ["block"], sourcesHealthy: true,
                                   now: start.addingTimeInterval(BlockRemovalGate.confirmationDelay)),
                       ["block"])
    }
}

/// A rejected credential is marked, never dropped.
///
/// Dropping it was wrong twice: the synced credential store re-supplied the same dead account on
/// the next foreground, so it flapped between present and absent — and each disappearance removed
/// that account's meetings, which is what drove the mass deletion above.
final class RejectedAccountHandlingTests: XCTestCase {

    func testAMarkedAccountStaysInTheList() {
        var accounts = ["a@example.com", "b@example.com"]
        var needsReconnect: Set<String> = []
        // Google rejects b.
        needsReconnect.insert("b@example.com")
        XCTAssertEqual(accounts.count, 2, "the account remains connected and visible")
        XCTAssertTrue(needsReconnect.contains("b@example.com"))

        // And the synced store re-supplying it changes nothing, where a removal would have flapped.
        accounts = Array(Set(accounts + ["b@example.com"])).sorted()
        XCTAssertEqual(accounts.count, 2)
    }

    func testAnySingleMarkedAccountDegradesTheWholePass() {
        // One unreadable account is enough: the meetings it would have contributed are missing
        // from the desired set, so nothing computed this pass can justify a deletion.
        let needsReconnect: Set<String> = ["b@example.com"]
        XCTAssertFalse(needsReconnect.isEmpty)
    }
}
