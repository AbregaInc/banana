import XCTest

/// A workout removed on an iPad or the Mac is finished by the phone, which owns Apple Health
/// (`HealthRemovalRequests`): the other devices ask, and the phone never guesses.
final class HealthRemovalRequestsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func workout(_ id: UUID = UUID(), startedAgo seconds: TimeInterval, lasting: TimeInterval = 1_800) -> HealthWorkout {
        let start = now.addingTimeInterval(-seconds)
        return HealthWorkout(id: id, activity: "Run", start: start, end: start.addingTimeInterval(lasting),
                             duration: lasting, source: "Banana", sourceBundleID: "com.boris.banana")
    }

    private func step(_ target: HealthRemovalRequest.Target, askedAgo: TimeInterval = 60,
                      health: [HealthWorkout] = [], summaries: [Date] = []) -> HealthRemovalRequests.Step {
        HealthRemovalRequests.step(for: HealthRemovalRequest(target: target, askedAt: now.addingTimeInterval(-askedAgo)),
                                   health: health, summaryStarts: summaries, now: now)
    }

    // MARK: A Banana workout deleted on another device

    func testItsHealthHalfIsRemovedOnceTheDeleteHasArrived() {
        let half = workout(startedAgo: 7_200)
        XCTAssertEqual(step(.pairedWith(start: half.start.addingTimeInterval(4)), health: [half]), .remove(half.id))
    }

    func testItWaitsWhileTheWorkoutStillStandsOnThePhone() {
        // The request came by one road and the delete by another: until the workout is gone
        // here, nothing in Health is touched.
        let half = workout(startedAgo: 7_200)
        XCTAssertEqual(step(.pairedWith(start: half.start), health: [half], summaries: [half.start.addingTimeInterval(2)]), .wait)
    }

    func testAnotherWorkoutThatDayIsNoReasonToWait() {
        let half = workout(startedAgo: 7_200)
        XCTAssertEqual(step(.pairedWith(start: half.start), health: [half], summaries: [half.start.addingTimeInterval(3 * 3_600)]),
                       .remove(half.id))
    }

    func testAnUnrelatedHealthWorkoutIsLeftAlone() {
        let other = workout(startedAgo: 20_000)
        let start = now.addingTimeInterval(-7_200)
        XCTAssertEqual(step(.pairedWith(start: start), health: [other]), .expect(start),
                       "its own half hasn't come from the Watch yet: remove that when it does")
    }

    // MARK: A workout that's only in Health

    func testAHealthOnlyWorkoutIsRemovedByItsID() {
        let one = workout(startedAgo: 7_200)
        XCTAssertEqual(step(.healthWorkout(one.id), health: [one, workout(startedAgo: 90_000)]), .remove(one.id))
    }

    func testOneThatIsAlreadyGoneIsDropped() {
        XCTAssertEqual(step(.healthWorkout(UUID()), health: [workout(startedAgo: 7_200)]), .drop)
    }

    // MARK: Age

    func testAnOldRequestIsDroppedNotCarriedOut() {
        let half = workout(startedAgo: 7_200)
        XCTAssertEqual(step(.pairedWith(start: half.start), askedAgo: HealthRemovalRequest.lifetime + 1, health: [half]), .drop)
        XCTAssertEqual(step(.healthWorkout(half.id), askedAgo: HealthRemovalRequest.lifetime + 1, health: [half]), .drop)
    }

    // MARK: The list

    func testAddingKeepsOneOfEachAndDropsTheOld() {
        let start = now.addingTimeInterval(-7_200)
        let old = HealthRemovalRequest(target: .healthWorkout(UUID()), askedAt: now.addingTimeInterval(-HealthRemovalRequest.lifetime - 5))
        let first = HealthRemovalRequest(target: .pairedWith(start: start), askedAt: now.addingTimeInterval(-30))
        let other = HealthRemovalRequest(target: .healthWorkout(UUID()), askedAt: now.addingTimeInterval(-20))
        let again = HealthRemovalRequest(target: .pairedWith(start: start), askedAt: now)
        let list = HealthRemovalRequests.adding(again, to: [old, first, other], now: now)
        XCTAssertEqual(list.map(\.id), [other.id, again.id])
    }

    func testTheListIsCapped() {
        var list: [HealthRemovalRequest] = []
        for _ in 0..<(HealthRemovalRequests.limit + 10) {
            list = HealthRemovalRequests.adding(HealthRemovalRequest(target: .healthWorkout(UUID()), askedAt: now), to: list, now: now)
        }
        XCTAssertEqual(list.count, HealthRemovalRequests.limit)
    }

    func testARequestSurvivesTheTripBetweenDevices() throws {
        let sent = [HealthRemovalRequest(target: .pairedWith(start: now), askedAt: now),
                    HealthRemovalRequest(target: .healthWorkout(UUID()), askedAt: now)]
        let received = try JSONDecoder().decode([HealthRemovalRequest].self, from: JSONEncoder().encode(sent))
        XCTAssertEqual(received, sent)
    }

    // MARK: A snapshot from before the phone heard

    func testAWorkoutRemovedHereStaysHiddenWhenAnOlderSnapshotBringsItBack() {
        let removed = workout(startedAgo: 7_200)
        let kept = workout(startedAgo: 90_000)
        let tombstone = PendingRemoval(start: removed.start, now: now.addingTimeInterval(-60))
        XCTAssertEqual(HealthRemovalRequests.removedHere(in: [removed, kept], tombstones: [tombstone], now: now), [removed.id])
    }

    func testAWorkoutStartedAfterTheDeleteIsNotSweptUp() {
        // Deleted a mis-tap, then started the real session within the match window.
        let tombstone = PendingRemoval(start: now.addingTimeInterval(-300), now: now.addingTimeInterval(-280))
        let fresh = workout(startedAgo: 270, lasting: 200)
        XCTAssertEqual(HealthRemovalRequests.removedHere(in: [fresh], tombstones: [tombstone], now: now), [])
    }
}
