import XCTest

/// The two rules that decide whether an event the user typed survives.
///
/// An event that has been created but not yet accepted by a calendar exists only in Banana's own
/// pending store — no calendar app can show it, and nothing else has a copy. So the failure worth
/// testing for is not "the badge is wrong", it is "the event quietly disappeared": a placeholder
/// retired without its event having arrived, or an interrupted write left in a state nothing ever
/// resolves.
final class PendingCalendarWriteTests: XCTestCase {

    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func signature(_ title: String, _ date: Date) -> String {
        PendingCalendarWriteRules.signature(title: title, start: date)
    }

    // MARK: - Retiring a placeholder

    func testAnAcceptedWriteIsRetiredWhenItsIdentifierComesBack() {
        XCTAssertTrue(PendingCalendarWriteRules.shouldRetire(
            state: .awaitingReadBack, remoteID: "EK-1", signature: signature("Standup", start),
            confirmedRemoteIDs: ["EK-1"], confirmedSignatures: []))
    }

    func testAnAcceptedWriteWithoutAnIdentifierFallsBackToTitleAndTime() {
        XCTAssertTrue(PendingCalendarWriteRules.shouldRetire(
            state: .awaitingReadBack, remoteID: nil, signature: signature("Standup", start),
            confirmedRemoteIDs: [], confirmedSignatures: [signature("Standup", start)]))
    }

    /// The failure this whole design exists to prevent: an unrelated read must never retire a
    /// placeholder, or a lost event silently becomes one that looks saved.
    func testAnUnrelatedReadDoesNotRetireAPlaceholder() {
        XCTAssertFalse(PendingCalendarWriteRules.shouldRetire(
            state: .awaitingReadBack, remoteID: "EK-1", signature: signature("Standup", start),
            confirmedRemoteIDs: ["EK-9"], confirmedSignatures: [signature("Other", start)]))
    }

    /// A write with an identifier is judged on that identifier alone. A coincidentally identical
    /// title and time on some other calendar entry is not proof this one landed.
    func testAnIdentifiedWriteIgnoresACoincidentalTitleMatch() {
        XCTAssertFalse(PendingCalendarWriteRules.shouldRetire(
            state: .awaitingReadBack, remoteID: "EK-1", signature: signature("Standup", start),
            confirmedRemoteIDs: [], confirmedSignatures: [signature("Standup", start)]))
    }

    func testAWriteStillInFlightIsNeverRetiredByARead() {
        XCTAssertFalse(PendingCalendarWriteRules.shouldRetire(
            state: .writing, remoteID: nil, signature: signature("Standup", start),
            confirmedRemoteIDs: [], confirmedSignatures: [signature("Standup", start)]))
    }

    func testAFailedWriteIsNeverRetiredByARead() {
        XCTAssertFalse(PendingCalendarWriteRules.shouldRetire(
            state: .failed, remoteID: "EK-1", signature: signature("Standup", start),
            confirmedRemoteIDs: ["EK-1"], confirmedSignatures: []),
            "a failed write is the user's to retry or discard, never something a read clears")
    }

    func testSignatureIgnoresSecondsAndSurroundingWhitespace() {
        XCTAssertEqual(signature("  Standup  ", start),
                       signature("standup", start.addingTimeInterval(31)))
    }

    func testSignatureSeparatesDifferentMinutes() {
        XCTAssertNotEqual(signature("Standup", start), signature("Standup", start.addingTimeInterval(120)))
    }

    // MARK: - Surviving a relaunch

    /// Killed mid-write: the event must come back as something with a retry, not a placeholder
    /// that spins forever.
    func testAnInterruptedWriteBecomesRetryable() {
        XCTAssertEqual(
            PendingCalendarWriteRules.stateAfterRelaunch(state: .writing),
            .failed)
    }

    func testAFailedWriteRemainsRetryableAfterRelaunch() {
        XCTAssertEqual(
            PendingCalendarWriteRules.stateAfterRelaunch(state: .failed),
            .failed)
    }

    func testAnAcceptedWriteIsNotDowngradedByAge() {
        XCTAssertEqual(
            PendingCalendarWriteRules.stateAfterRelaunch(state: .awaitingReadBack),
            .awaitingReadBack,
            "it reached the calendar; it is only waiting to be read back")
    }

    // MARK: - Events written by something else

    /// The system editor writes through EventKit itself. There is nothing for us to write, but the
    /// read-back still costs a debounce and a recompute — so the event is adopted as a placeholder
    /// and retired when the real one arrives.
    func testAnAdoptedEventIsAlreadyAwaitingReadBack() {
        XCTAssertTrue(PendingCalendarWriteRules.shouldRetire(
            state: .awaitingReadBack, remoteID: "EK-77", signature: signature("Dinner", start),
            confirmedRemoteIDs: ["EK-77"], confirmedSignatures: []))
    }

    /// It must never be treated as an in-flight write that could fail and need retrying: the write
    /// already happened, and offering to retry it would create a duplicate.
    func testAnAdoptedEventIsNotDowngradedOnRelaunch() {
        XCTAssertEqual(
            PendingCalendarWriteRules.stateAfterRelaunch(state: .awaitingReadBack),
            .awaitingReadBack)
    }

    // MARK: - Giving up on a placeholder

    /// The bug this prevents: a placeholder whose write was accepted but never seen coming back
    /// waited forever, and a forever-waiting placeholder is drawn on the calendar as a block that
    /// cannot be deleted — because it is not an event at all. One sat on a real calendar reading
    /// "Busy, 8:00 PM – 10:15 PM" while the underlying event was 25 minutes long.
    func testAPlaceholderNeverSeenOnAReadIsGivenUpOn() {
        let later = start.addingTimeInterval(PendingCalendarWriteRules.readBackGraceInterval + 1)
        XCTAssertTrue(PendingCalendarWriteRules.hasOutlivedReadBack(
            state: .awaitingReadBack, createdAt: start, now: later))
    }

    /// The ordinary case must not be cut short: a read-back normally lands seconds later.
    func testAFreshPlaceholderIsNotGivenUpOn() {
        XCTAssertFalse(PendingCalendarWriteRules.hasOutlivedReadBack(
            state: .awaitingReadBack, createdAt: start, now: start.addingTimeInterval(5)))
    }

    /// A FAILED write is the user's to retry or discard and must never expire: it holds the only
    /// copy of what they typed.
    func testAFailedWriteIsNeverGivenUpOn() {
        let later = start.addingTimeInterval(PendingCalendarWriteRules.readBackGraceInterval * 100)
        XCTAssertFalse(PendingCalendarWriteRules.hasOutlivedReadBack(
            state: .failed, createdAt: start, now: later))
    }

    /// Nor may a write still in flight be dropped — it has not been accepted yet.
    func testAnInFlightWriteIsNeverGivenUpOn() {
        let later = start.addingTimeInterval(PendingCalendarWriteRules.readBackGraceInterval * 100)
        XCTAssertFalse(PendingCalendarWriteRules.hasOutlivedReadBack(
            state: .writing, createdAt: start, now: later))
    }
}
