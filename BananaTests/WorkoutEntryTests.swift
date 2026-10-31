import XCTest

/// Coverage for the two pure pieces of the "delete leaves the Fitness entry" fix:
/// `WorkoutEntry.merge` dropping hidden HealthKit workouts (`HealthKitStore.hiddenWorkoutIDs`),
/// and `PendingRemoval`'s match window/expiry (the tombstone `HealthKitStore.expectRemoval`
/// records for a Banana-summary delete whose paired Health workout hasn't imported yet).
/// Both types are plain data (`HealthWorkout.swift`), so this needs no live `HealthKitStore`.
final class WorkoutEntryTests: XCTestCase {

    private func healthWorkout(_ start: Date, activity: String = "Running",
                               id: UUID = UUID()) -> HealthWorkout {
        HealthWorkout(id: id, activity: activity, start: start,
                     end: start.addingTimeInterval(1_800), duration: 1_800, source: "Apple Watch")
    }

    private func summary(_ start: Date, activity: String = "Running") -> FitnessSessionSummary {
        let session = FitnessSession(id: UUID(), start: start, end: start.addingTimeInterval(1_800),
                                     activity: activity, avgHeartRate: nil, totalEnergy: nil,
                                     totalDistance: nil, samples: [])
        return FitnessSessionSummary(session: session)
    }

    private func date(_ offsetMinutes: Int, from base: Date = Date(timeIntervalSinceReferenceDate: 0)) -> Date {
        base.addingTimeInterval(TimeInterval(offsetMinutes * 60))
    }

    // MARK: - WorkoutEntry.merge drops hidden health workouts

    func testMergeDropsHiddenHealthOnlyWorkout() {
        let shown = healthWorkout(date(0))
        let hidden = healthWorkout(date(200))   // far enough from `shown` to be its own bucket

        let entries = WorkoutEntry.merge(summaries: [], health: [shown, hidden],
                                         hiddenHealthIDs: [hidden.id])

        XCTAssertEqual(entries.map(\.id), [WorkoutEntry(health: shown, summary: nil).id])
    }

    /// A hidden Health workout must disappear even when it would otherwise have paired with a
    /// Banana summary — the summary itself stays (as a summary-only entry), only the Health
    /// stats vanish.
    func testMergeDropsHiddenHealthWorkoutEvenWhenPairedWithASummary() {
        let start = date(0)
        let pairedHealth = healthWorkout(start)
        let s = summary(start)

        let entries = WorkoutEntry.merge(summaries: [s], health: [pairedHealth],
                                         hiddenHealthIDs: [pairedHealth.id])

        XCTAssertEqual(entries.count, 1)
        XCTAssertNil(entries[0].health)
        XCTAssertEqual(entries[0].summary?.id, s.id)
    }

    func testMergeWithEmptyHiddenSetBehavesLikeNoFilter() {
        let a = healthWorkout(date(0))
        let b = healthWorkout(date(200))

        let entries = WorkoutEntry.merge(summaries: [], health: [a, b], hiddenHealthIDs: [])

        XCTAssertEqual(Set(entries.map(\.id)),
                       Set([WorkoutEntry(health: a, summary: nil).id, WorkoutEntry(health: b, summary: nil).id]))
    }

    func testMergeDefaultParameterHidesNothing() {
        let a = healthWorkout(date(0))
        // No `hiddenHealthIDs` argument at all — the default must not drop anything.
        let entries = WorkoutEntry.merge(summaries: [], health: [a])
        XCTAssertEqual(entries.count, 1)
    }

    // MARK: - PendingRemoval match window + expiry

    // A deleted workout is gone from the list at once, while its Undo is offered (`WorkoutRemoval`).

    func testAWorkoutDeletedAMomentAgoIsHidden() {
        let run = WorkoutEntry(health: nil, summary: summary(date(0)))
        let swim = WorkoutEntry(health: nil, summary: summary(date(600), activity: "Swimming"))
        XCTAssertEqual(WorkoutEntry.visible([run, swim], hiding: [run.removalID]), [swim])
        XCTAssertEqual(WorkoutEntry.visible([run, swim], hiding: []), [run, swim], "Undo: it's back")
    }

    func testItStaysHiddenWhenItsHealthHalfArrives() {
        // The entry's own id changes from "s-…" to "h-…" once Health's copy is paired with it;
        // what hides it is its Banana record's id, which doesn't.
        let recorded = summary(date(0))
        let alone = WorkoutEntry(health: nil, summary: recorded)
        let paired = WorkoutEntry(health: healthWorkout(date(0)), summary: recorded)
        XCTAssertNotEqual(alone.id, paired.id)
        XCTAssertEqual(alone.removalID, paired.removalID)
        XCTAssertEqual(WorkoutEntry.visible([paired], hiding: [alone.removalID]), [])
    }

    func testPendingRemovalMatchesWithinWindow() {
        let start = date(0)
        let tombstone = PendingRemoval(start: start, now: start)
        // Just inside the 90s window WorkoutEntry.matchTolerance defines. The workout already
        // ended by the tombstone's creation time, same as the original deleted workout would have.
        let nearby = start.addingTimeInterval(PendingRemoval.matchWindow - 1)
        XCTAssertTrue(tombstone.matches(nearby, start, now: start))
    }

    func testPendingRemovalDoesNotMatchOutsideWindow() {
        let start = date(0)
        let tombstone = PendingRemoval(start: start, now: start)
        let farAway = start.addingTimeInterval(PendingRemoval.matchWindow + 1)
        XCTAssertFalse(tombstone.matches(farAway, start, now: start))
    }

    /// The window is symmetric — a workout that imported slightly *before* the delete (clock
    /// skew, or the summary's own start rounding) still matches.
    func testPendingRemovalMatchesSymmetrically() {
        let start = date(10)
        let tombstone = PendingRemoval(start: start, now: start)
        let earlier = start.addingTimeInterval(-(PendingRemoval.matchWindow - 1))
        XCTAssertTrue(tombstone.matches(earlier, earlier, now: start))
    }

    /// The race this tombstone exists to close: the owner mis-taps, records a few seconds, and
    /// deletes it — then immediately starts a REAL workout that happens to start within the match
    /// window of the mis-tap. The real workout is still recording (ends well after the tombstone
    /// was created), so it must never be swept up and deleted just because its start lines up.
    func testPendingRemovalDoesNotMatchWorkoutThatStartedAfterTombstone() {
        let deletedAt = date(0)
        let tombstone = PendingRemoval(start: deletedAt, now: deletedAt)
        let newWorkoutStart = deletedAt.addingTimeInterval(PendingRemoval.matchWindow / 2)
        let newWorkoutEnd = deletedAt.addingTimeInterval(45 * 60)   // still recording 45 min later
        XCTAssertFalse(tombstone.matches(newWorkoutStart, newWorkoutEnd, now: deletedAt))
    }

    func testPendingRemovalExpiresAfterTTL() {
        let recorded = date(0)
        let tombstone = PendingRemoval(start: recorded, now: recorded)
        let sameStart = recorded   // would match on window alone
        let justBeforeExpiry = recorded.addingTimeInterval(PendingRemoval.ttl - 1)
        let justAfterExpiry = recorded.addingTimeInterval(PendingRemoval.ttl + 1)

        XCTAssertTrue(tombstone.matches(sameStart, sameStart, now: justBeforeExpiry))
        XCTAssertFalse(tombstone.matches(sameStart, sameStart, now: justAfterExpiry))
    }

    // MARK: - A stored route id still finds its workout

    /// Opened while only our recording existed ("s-…"); after the Health copy imports the merged
    /// entry's id is "h-…". The restored screen must still open the same workout.
    func testRouteIDFromBeforeTheHealthImportStillMatches() {
        let ours = summary(date(0))
        let before = WorkoutEntry(health: nil, summary: ours)
        let after = WorkoutEntry(health: healthWorkout(date(0)), summary: ours)
        XCTAssertNotEqual(before.id, after.id)
        XCTAssertTrue(after.matches(routeID: before.id))
        XCTAssertFalse(WorkoutEntry(health: healthWorkout(date(60)), summary: nil).matches(routeID: before.id))
    }

    // MARK: Which detail a workout opens in

    func testAWorkoutBananaRecordedOpensInTheLayoutsOwnDetail() {
        let entry = WorkoutEntry(health: nil, summary: summary(date(0)))
        XCTAssertEqual(entry.detail(wide: true), .wide)
        XCTAssertEqual(entry.detail(wide: false), .compact)
    }

    func testOneThatIsOnlyInHealthOpensToo() {
        // On the Mac its row went nowhere: the wide detail needs a Banana recording.
        let entry = WorkoutEntry(health: healthWorkout(date(0)), summary: nil)
        XCTAssertEqual(entry.detail(wide: true), .healthOnly)
        XCTAssertEqual(entry.detail(wide: false), .healthOnly)
    }

    func testOneWithBothHalvesIsBananas() {
        let entry = WorkoutEntry(health: healthWorkout(date(0)), summary: summary(date(0)))
        XCTAssertEqual(entry.detail(wide: true), .wide)
    }
}
