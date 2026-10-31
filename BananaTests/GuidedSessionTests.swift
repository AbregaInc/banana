import XCTest

/// A guided workout keeps running when the phone is locked between sets.
///
/// The coach used to hold its progress in view state and count down one second at a time while
/// on screen. Locking the phone stopped the countdown, and a few seconds later the background
/// blank threw the screen — and the session — away. These pin the replacement: wall-clock
/// phases that catch up, and a store that outlives the screen.
@MainActor
final class GuidedSessionTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    /// 2 × 10 push-ups (30 s rest), then 2 × 40 s plank (20 s rest).
    private let plan = WorkoutPlan(title: "Test", focus: .mixed, targetMinutes: 10, exercises: [
        ExercisePrescription(exerciseID: "pushup", sets: 2, reps: 10, durationSeconds: nil, restSeconds: 30),
        ExercisePrescription(exerciseID: "plank", sets: 2, reps: nil, durationSeconds: 40, restSeconds: 20),
    ])

    func testRestKeepsCountingWhileTheScreenIsGone() {
        var s = GuidedSession(plan: plan, now: t0)
        s.completeSet(in: plan, at: t0)
        XCTAssertTrue(s.resting)
        XCTAssertEqual(s.remaining(at: t0), 30)
        // Phone locked for 12 s: the rest has 18 s left, not 30.
        XCTAssertEqual(s.remaining(at: t0.addingTimeInterval(12)), 18)
    }

    func testCatchUpStopsAtTheNextRepBasedSet() {
        var s = GuidedSession(plan: plan, now: t0)
        s.completeSet(in: plan, at: t0)
        // Away for five minutes: the rest ended long ago, and set 2 of push-ups waits for a tap.
        XCTAssertEqual(s.tick(in: plan, now: t0.addingTimeInterval(300)), .running)
        XCTAssertFalse(s.resting)
        XCTAssertEqual(s.index, 0)
        XCTAssertEqual(s.setNumber, 2)
        XCTAssertNil(s.phaseEndsAt)
    }

    func testTimedPhasesPlayOutFromWhenEachOneEnded() {
        var s = GuidedSession(plan: plan, now: t0)
        s.completeSet(in: plan, at: t0)
        s.tick(in: plan, now: t0.addingTimeInterval(30))
        s.completeSet(in: plan, at: t0.addingTimeInterval(40))   // push-ups done → 30 s rest
        // Rest ends at 70; plank 1 runs 70–110; rest 110–130; plank 2 runs from 130.
        XCTAssertEqual(s.tick(in: plan, now: t0.addingTimeInterval(125)), .running)
        XCTAssertTrue(s.resting)
        XCTAssertEqual(s.remaining(at: t0.addingTimeInterval(125)), 5)
        XCTAssertEqual(s.tick(in: plan, now: t0.addingTimeInterval(150)), .running)
        XCTAssertEqual(s.index, 1)
        XCTAssertEqual(s.setNumber, 2)
        XCTAssertEqual(s.remaining(at: t0.addingTimeInterval(150)), 20)
        // Plank 2 ends at 170: that's the whole workout.
        XCTAssertEqual(s.tick(in: plan, now: t0.addingTimeInterval(200)), .finished)
        XCTAssertEqual(s.completed, ["pushup", "plank"])
    }

    func testPauseFreezesTheClock() {
        var s = GuidedSession(plan: plan, now: t0)
        s.completeSet(in: plan, at: t0)
        s.togglePause(at: t0.addingTimeInterval(10))
        XCTAssertEqual(s.remaining(at: t0.addingTimeInterval(500)), 20)
        XCTAssertEqual(s.tick(in: plan, now: t0.addingTimeInterval(500)), .running)
        XCTAssertTrue(s.resting, "nothing moves while paused")
        s.togglePause(at: t0.addingTimeInterval(500))
        XCTAssertEqual(s.remaining(at: t0.addingTimeInterval(505)), 15)
    }

    func testTheStoreOutlivesTheScreenAndTheProcess() {
        let suite = "GuidedSessionTests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = GuidedSessionStore(defaults: defaults, now: t0)
        store.begin(plan, now: t0)
        store.update { $0.completeSet(in: plan, at: t0) }

        let relaunched = GuidedSessionStore(defaults: defaults, now: t0.addingTimeInterval(600))
        XCTAssertEqual(relaunched.session(for: plan.id)?.resting, true)
        XCTAssertEqual(relaunched.begin(plan, now: t0.addingTimeInterval(600)).startedAt, t0,
                       "opening the coach again resumes; it doesn't restart")

        let nextDay = GuidedSessionStore(defaults: defaults, now: t0.addingTimeInterval(24 * 3600))
        XCTAssertNil(nextDay.session, "a session left overnight was abandoned")

        relaunched.end()
        XCTAssertNil(GuidedSessionStore(defaults: defaults, now: t0).session)
    }

    func testWorkoutsStackRoundTrips() throws {
        let stack: [ShellState.WorkoutsRoute] = [.trends(window: 30), .trend("restingHR", window: 30)]
        let data = try JSONEncoder().encode(ShellState(tab: .workouts, workouts: stack))
        let back = try JSONDecoder().decode(ShellState.self, from: data)
        XCTAssertEqual(back.workouts, stack)
    }

    // MARK: Switched off (`Features.guidedPlans`)

    func testAPlaceSavedInsideGuidedPlansOpensOnWhatWasUnderIt() {
        typealias Route = ShellState.WorkoutsRoute
        XCTAssertEqual(Route.available([.guidedPlans, .plan(plan.id), .coach(plan.id)], guidedPlans: false), [])
        XCTAssertEqual(Route.available([.sleep, .guidedPlans, .plan(plan.id)], guidedPlans: false), [.sleep],
                       "what was under it stays; nothing that was opened from inside it does")
        XCTAssertEqual(Route.available([.workout("a"), .sleep], guidedPlans: false), [.workout("a"), .sleep])
    }

    func testTheSameStackIsWholeWhenGuidedPlansAreOn() {
        typealias Route = ShellState.WorkoutsRoute
        let stack: [Route] = [.guidedPlans, .plan(plan.id), .coach(plan.id)]
        XCTAssertEqual(Route.available(stack, guidedPlans: true), stack)
    }

    func testARestoredStateDropsThemWhileTheyAreOff() throws {
        try XCTSkipIf(Features.guidedPlans, "guided plans are on")
        let data = try JSONEncoder().encode(ShellState(tab: .workouts, workouts: [.guidedPlans, .coach(plan.id)]))
        XCTAssertEqual(try JSONDecoder().decode(ShellState.self, from: data).workouts, [])
    }

    func testStateSavedBeforeAFieldExistedStillRestores() throws {
        let old = Data(#"{"tab":"notes","notes":["99A5F6E1-9D7D-4D98-A8EA-610EF6E13B01"],"library":[]}"#.utf8)
        let state = try JSONDecoder().decode(ShellState.self, from: old)
        XCTAssertEqual(state.tab, .notes)
        XCTAssertEqual(state.workouts, [])
    }

    func testASetFinishedWhilePausedStartsItsRestPaused() {
        var s = GuidedSession(plan: plan, now: t0)
        s.togglePause(at: t0)
        s.completeSet(in: plan, at: t0.addingTimeInterval(5))
        XCTAssertTrue(s.resting)
        XCTAssertNil(s.phaseEndsAt, "the rest must not run down while paused")
        XCTAssertEqual(s.remaining(at: t0.addingTimeInterval(100)), 30)
        s.togglePause(at: t0.addingTimeInterval(100))
        XCTAssertEqual(s.remaining(at: t0.addingTimeInterval(110)), 20)
    }

    func testAWorkoutThatEndedWhileLockedRecordsWhenItEnded() {
        var s = GuidedSession(plan: plan, now: t0)
        s.completeSet(in: plan, at: t0)
        s.tick(in: plan, now: t0.addingTimeInterval(30))
        s.completeSet(in: plan, at: t0.addingTimeInterval(40))
        XCTAssertEqual(s.tick(in: plan, now: t0.addingTimeInterval(3_600)), .finished)
        XCTAssertEqual(s.finishedAt, t0.addingTimeInterval(170), "the last plank ended at +170 s, not an hour later")
    }
}
