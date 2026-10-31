import XCTest

/// The two clocks: the system's, and the one a test moves by hand.
///
/// The manual clock is what every later test of anything that waits stands on — a send held for
/// undo, a snooze that comes due, a pause for quota — so what matters here is that it can be
/// trusted to wake exactly what it should and nothing else, in the order real time would have.
/// None of it takes any time: a test says an hour passes and an hour passes.
///
/// A task that has been started has not necessarily reached its `sleep`, so a test that moves
/// the clock first waits for the clock to say how many are asleep (`untilSleeping`) rather than
/// for a while.
final class MailClockTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private struct Woken: Equatable { let name: String }

    /// A sleeper that is woken by a deadline, and what happened to it.
    private func sleeper(_ clock: ManualMailClock, until deadline: Date) -> Task<Void, Error> {
        Task { try await clock.sleep(until: deadline) }
    }

    // MARK: - The manual clock

    func testTheManualClockStandsWhereItIsPutAndMovesOnlyWhenAdvanced() {
        let clock = ManualMailClock(start: start)
        XCTAssertEqual(clock.now, start)
        XCTAssertEqual(clock.now, start, "and still")
        clock.advance(by: 90)
        XCTAssertEqual(clock.now, start.addingTimeInterval(90))
        clock.advance(by: 3_600)
        XCTAssertEqual(clock.now, start.addingTimeInterval(3_690))
    }

    func testAManualClockWakesSleepersInDeadlineOrderAndReportsWhatIsPending() async throws {
        let clock = ManualMailClock(start: start)
        // Begun in no particular order of deadline.
        let late = sleeper(clock, until: start.addingTimeInterval(300))
        let early = sleeper(clock, until: start.addingTimeInterval(60))
        let middle = sleeper(clock, until: start.addingTimeInterval(120))
        await clock.untilSleeping(atLeast: 3)

        XCTAssertEqual(clock.pendingSleeps, [60, 120, 300].map { start.addingTimeInterval($0) },
                       "pending is reported earliest first, whatever order they began in")

        clock.advance(by: 59)
        XCTAssertEqual(clock.pendingSleeps.count, 3, "nothing is due yet")

        // One moment is reached: that sleeper wakes, the other two do not.
        let first = clock.advance(by: 1)
        XCTAssertEqual(first, [start.addingTimeInterval(60)])
        try await early.value
        XCTAssertEqual(clock.pendingSleeps, [120, 300].map { start.addingTimeInterval($0) })

        let second = clock.advance(by: 60)
        XCTAssertEqual(second, [start.addingTimeInterval(120)])
        try await middle.value
        XCTAssertEqual(clock.pendingSleeps, [start.addingTimeInterval(300)])

        let third = clock.advance(by: 180)
        XCTAssertEqual(third, [start.addingTimeInterval(300)])
        try await late.value
        XCTAssertEqual(clock.pendingSleeps, [])
    }

    func testAnAdvanceThatPassesSeveralMomentsWakesThemEarliestFirst() async throws {
        let clock = ManualMailClock(start: start)
        let c = sleeper(clock, until: start.addingTimeInterval(30))
        let a = sleeper(clock, until: start.addingTimeInterval(10))
        let b = sleeper(clock, until: start.addingTimeInterval(20))
        await clock.untilSleeping(atLeast: 3)

        let woken = clock.advance(by: 3_600)
        XCTAssertEqual(woken, [10, 20, 30].map { start.addingTimeInterval($0) })
        try await a.value; try await b.value; try await c.value
        XCTAssertEqual(clock.pendingSleeps, [])
    }

    func testTwoSleepersWithTheSameMomentWakeInTheOrderTheyBegan() async throws {
        let clock = ManualMailClock(start: start)
        let moment = start.addingTimeInterval(5)
        let first = sleeper(clock, until: moment)
        await clock.untilSleeping(atLeast: 1)
        let second = sleeper(clock, until: moment)
        await clock.untilSleeping(atLeast: 2)
        XCTAssertEqual(clock.pendingSleeps, [moment, moment])
        XCTAssertEqual(clock.advance(by: 5), [moment, moment])
        try await first.value; try await second.value
    }

    func testASleepWhoseMomentHasAlreadyComeReturnsAtOnce() async throws {
        let clock = ManualMailClock(start: start)
        try await clock.sleep(until: start)                                  // now
        try await clock.sleep(until: start.addingTimeInterval(-3_600))       // in the past
        XCTAssertEqual(clock.pendingSleeps, [])
    }

    func testCancellingASleeperEndsItsSleepWithCancellationErrorAndTakesItOffThePendingList() async throws {
        let clock = ManualMailClock(start: start)
        let staying = sleeper(clock, until: start.addingTimeInterval(100))
        let leaving = sleeper(clock, until: start.addingTimeInterval(50))
        await clock.untilSleeping(atLeast: 2)

        leaving.cancel()
        do {
            try await leaving.value
            XCTFail("a cancelled sleep must throw")
        } catch is CancellationError {
        }
        XCTAssertEqual(clock.pendingSleeps, [start.addingTimeInterval(100)])

        // The one that stayed is unaffected, and the one that left is not woken twice.
        XCTAssertEqual(clock.advance(by: 100), [start.addingTimeInterval(100)])
        try await staying.value
    }

    func testOneJumpWakesALoopingSleeperOnceAndNotOncePerMomentItPassed() async throws {
        // What one `advance` gives, as the doc comment says: the time moves once, so a sleeper that
        // sleeps again for a minute, again and again, is woken once by an hour — and asks for its
        // next minute from the time after the jump.
        let clock = ManualMailClock(start: start)
        let wokenAt = MailTestList<Date>()
        let looping = Task {
            for _ in 1...3 {
                try await clock.sleep(until: clock.now.addingTimeInterval(60))
                wokenAt.add(clock.now)
            }
        }
        await clock.untilSleeping(atLeast: 1)
        XCTAssertEqual(clock.advance(by: 3_600).count, 1)

        await clock.untilSleeping(atLeast: 1)       // it has woken, read the time, and slept again
        XCTAssertEqual(wokenAt.all, [start.addingTimeInterval(3_600)], "once, at the time after the jump")
        XCTAssertEqual(clock.pendingSleeps, [start.addingTimeInterval(3_660)], "its next minute is from there")

        looping.cancel()
        _ = try? await looping.value
        XCTAssertEqual(clock.pendingSleeps, [])
    }

    func testASleeperCancelledBeforeItBeganNeverSleeps() async throws {
        let clock = ManualMailClock(start: start)
        let task = Task { () -> Bool in
            // Cancelled before it begins, or while it is beginning: the answer is the same.
            do {
                try await clock.sleep(until: self.start.addingTimeInterval(10))
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        task.cancel()
        let threw = await task.value
        XCTAssertTrue(threw)
        XCTAssertEqual(clock.pendingSleeps, [])
    }

    func testAWokenSleeperIsNotWokenAgainByALaterAdvanceOrACancel() async throws {
        let clock = ManualMailClock(start: start)
        let one = sleeper(clock, until: start.addingTimeInterval(1))
        await clock.untilSleeping(atLeast: 1)
        XCTAssertEqual(clock.advance(by: 1).count, 1)
        try await one.value
        XCTAssertEqual(clock.advance(by: 10).count, 0)
        one.cancel()
        XCTAssertEqual(clock.pendingSleeps, [])
    }

    func testUntilSleepingReturnsAtOnceWhenEnoughAreAlreadyAsleep() async {
        let clock = ManualMailClock(start: start)
        let one = sleeper(clock, until: start.addingTimeInterval(1))
        await clock.untilSleeping(atLeast: 1)
        await clock.untilSleeping(atLeast: 1)
        await clock.untilSleeping(atLeast: 0)
        clock.advance(by: 1)
        _ = try? await one.value
    }

    func testSleepersOnTheManualClockNeverWaitForRealTime() async throws {
        // An hour on the clock, no time at all in the test.
        let clock = ManualMailClock(start: start)
        let hour = sleeper(clock, until: start.addingTimeInterval(3_600))
        await clock.untilSleeping(atLeast: 1)
        clock.advance(by: 3_600)
        try await hour.value
    }

    // MARK: - The system clock

    func testTheSystemClockSaysTheDeviceTime() {
        let clock = SystemMailClock()
        let before = Date()
        let said = clock.now
        let after = Date()
        XCTAssertGreaterThanOrEqual(said, before)
        XCTAssertLessThanOrEqual(said, after)
    }

    func testASystemSleepToAMomentThatHasPassedReturnsAtOnce() async throws {
        let clock = SystemMailClock()
        try await clock.sleep(until: clock.now.addingTimeInterval(-1))
    }

    func testASystemSleepToAMomentAheadReturnsAtOrAfterIt() async throws {
        // The real path, once: a sleep to a moment twenty milliseconds ahead. Only the order is
        // asserted — it returns at or after the moment — never how long it took.
        let clock = SystemMailClock()
        let deadline = clock.now.addingTimeInterval(0.02)
        try await clock.sleep(until: deadline)
        XCTAssertGreaterThanOrEqual(clock.now, deadline)
    }

    func testCancellingASystemSleepEndsItWithCancellationError() async throws {
        let clock = SystemMailClock()
        let task = Task { try await clock.sleep(until: clock.now.addingTimeInterval(3_600)) }
        task.cancel()
        do {
            try await task.value
            XCTFail("an hour's sleep that was cancelled must not have finished")
        } catch is CancellationError {
        }
    }

    func testTheTwoClocksAreInterchangeableToAnythingThatTakesAMailClock() {
        let clocks: [MailClock] = [SystemMailClock(), ManualMailClock()]
        XCTAssertEqual(clocks.count, 2)
    }
}
