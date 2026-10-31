import XCTest

/// The route through the first run (`OnboardingFlow`), the two answers it asks for
/// (`DayAnchors`) and the rule about location (`LocationUse`).
final class OnboardingFlowTests: XCTestCase {
    func testThereIsOnePath() {
        // The welcome asked where to start for a few hours; the answer was one path for everyone.
        XCTAssertEqual(OnboardingStep.allCases, [.welcome, .wake, .windDown, .calendar, .otherCalendar])
        XCTAssertEqual(OnboardingFlow.next(after: .welcome, accounts: 0, busySettled: false), .wake)
        XCTAssertEqual(OnboardingFlow.next(after: .wake, accounts: 0, busySettled: false), .windDown)
        XCTAssertEqual(OnboardingFlow.next(after: .windDown, accounts: 0, busySettled: false), .calendar)
    }

    func testAFirstSignInLeadsToTheOtherCalendar() {
        // Work and personal is the pair busy blocks are for: one account in, the other is asked for.
        XCTAssertEqual(OnboardingFlow.next(after: .calendar, accounts: 1, busySettled: false), .otherCalendar)
        XCTAssertNil(OnboardingFlow.next(after: .otherCalendar, accounts: 1, busySettled: false))
        XCTAssertNil(OnboardingFlow.next(after: .otherCalendar, accounts: 2, busySettled: false))
    }

    func testSkippingGoogleSkipsTheOtherCalendarToo() {
        XCTAssertNil(OnboardingFlow.next(after: .calendar, accounts: 0, busySettled: false))
    }

    func testACalendarThatCameFromAnotherDeviceIsNotAskedForAgain() {
        // Signing in on one device signs in the others: the questions are still asked, the
        // first calendar is not. The other one is, until busy blocks have their answer.
        XCTAssertEqual(OnboardingFlow.next(after: .welcome, accounts: 1, busySettled: true), .wake)
        XCTAssertEqual(OnboardingFlow.next(after: .windDown, accounts: 1, busySettled: false), .otherCalendar)
        XCTAssertNil(OnboardingFlow.next(after: .windDown, accounts: 2, busySettled: true))
        XCTAssertNil(OnboardingFlow.next(after: .calendar, accounts: 1, busySettled: true))
    }

    func testTheOtherCalendarStepAddsAnAccountUntilThereAreTwo() {
        // Busy blocks get their yes on this step only when there are two accounts to keep in step.
        XCTAssertEqual(OnboardingFlow.otherCalendarAction(accounts: 0), .addAccount)
        XCTAssertEqual(OnboardingFlow.otherCalendarAction(accounts: 1), .addAccount)
        XCTAssertEqual(OnboardingFlow.otherCalendarAction(accounts: 2), .blockBusyTime)
        XCTAssertEqual(OnboardingFlow.otherCalendarAction(accounts: 3), .blockBusyTime)
    }

    func testBusyBlocksAreSettledByAnAnswerHereOrAChoiceFromElsewhere() {
        XCTAssertFalse(WriteBackStart.settled(questionAnswered: false, hasPreference: false, sharedChoice: nil))
        XCTAssertTrue(WriteBackStart.settled(questionAnswered: true, hasPreference: false, sharedChoice: nil))
        XCTAssertTrue(WriteBackStart.settled(questionAnswered: false, hasPreference: true, sharedChoice: nil))
        XCTAssertTrue(WriteBackStart.settled(questionAnswered: false, hasPreference: false, sharedChoice: false))
    }

    func testBackRetracesTheSameSteps() {
        XCTAssertNil(OnboardingFlow.previous(before: .welcome))
        XCTAssertEqual(OnboardingFlow.previous(before: .wake), .welcome)
        XCTAssertEqual(OnboardingFlow.previous(before: .windDown), .wake)
        XCTAssertEqual(OnboardingFlow.previous(before: .calendar), .windDown)
        XCTAssertNil(OnboardingFlow.previous(before: .otherCalendar), "the sign-in before it is done")
    }

    func testOnceTheFirstRunIsDoneTheAppIsOpenWhateverIsConnected() {
        // The Mac needed a connected Google calendar as well, and had no way past its screen.
        XCTAssertFalse(OnboardingFlow.showsFirstRun(completed: true))
        XCTAssertTrue(OnboardingFlow.showsFirstRun(completed: false))
    }

    // MARK: - The two answers

    func testTheAnswersStartWhereTheStarterRoutinesAre() {
        // Left alone, the questions change nothing: 6:30 and 9:00 pm are the routines' own times.
        XCTAssertEqual(DayAnchors().wakeMinutes, 6 * 60 + 30)
        XCTAssertEqual(DayAnchors().windDownMinutes, 21 * 60)
    }

    func testEachAnswerMovesItsOwnRoutineAndNoOther() {
        let anchors = DayAnchors(wakeMinutes: 7 * 60 + 15, windDownMinutes: 22 * 60 + 30)
        XCTAssertEqual(anchors.time(for: .wake)?.hour, 7)
        XCTAssertEqual(anchors.time(for: .wake)?.minute, 15)
        XCTAssertEqual(anchors.time(for: .windDown)?.hour, 22)
        XCTAssertEqual(anchors.time(for: .windDown)?.minute, 30)
        XCTAssertNil(anchors.time(for: .other), "Commute, Focus and the rest keep their times")
    }

    func testADayIsNeverDrawnUpsideDown() {
        // A wake time in the evening or a wind-down at breakfast.
        let odd = DayAnchors(wakeMinutes: 20 * 60, windDownMinutes: 8 * 60).clamped
        XCTAssertEqual(odd.wakeMinutes, DayAnchors.wakeRange.upperBound)
        XCTAssertEqual(odd.windDownMinutes, DayAnchors.windDownRange.lowerBound)
        XCTAssertLessThan(odd.wakeMinutes, odd.windDownMinutes)
        XCTAssertEqual(DayAnchors().clamped, DayAnchors())
    }

    // MARK: - Location

    func testBananaNeverAsksForLocationByItself() {
        // iOS asked for it one second after a new person first saw the plan.
        XCTAssertEqual(LocationUse.unprompted(.notAsked), .nothing)
        XCTAssertEqual(LocationUse.unprompted(.unknown), .nothing)
        XCTAssertEqual(LocationUse.unprompted(.refused), .nothing)
    }

    func testAllowedLocationIsUsed() {
        XCTAssertEqual(LocationUse.unprompted(.allowed), .fetch)
    }
}
