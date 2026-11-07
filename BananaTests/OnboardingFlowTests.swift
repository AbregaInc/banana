import XCTest

/// The route through the first run (`OnboardingFlow`), its calendar choices and receipt, the two
/// answers it asks for (`DayAnchors`) and the rule about location (`LocationUse`).
final class OnboardingFlowTests: XCTestCase {
    private typealias Situation = OnboardingFlow.Situation
    private let nothing = Situation()
    private let connected = Situation(accounts: 1, copiesSettled: false, ownsWritableCalendar: true)

    func testThereIsOnePath() {
        // One path for everyone, led by Banana: welcome, what to look after, the day, the calendar.
        XCTAssertEqual(OnboardingStep.allCases, [.welcome, .modules, .wake, .windDown, .connect, .calendars, .copies, .done])
        XCTAssertEqual(OnboardingFlow.next(after: .welcome, in: nothing), .modules)
        XCTAssertEqual(OnboardingFlow.next(after: .modules, in: nothing), .wake)
        XCTAssertEqual(OnboardingFlow.next(after: .wake, in: nothing), .windDown)
        XCTAssertEqual(OnboardingFlow.next(after: .windDown, in: nothing), .connect)
    }

    func testWithoutACalendarTheAppOpensWithNoReceipt() {
        // Nothing to show, count or copy: a receipt would only say so.
        XCTAssertNil(OnboardingFlow.next(after: .connect, in: nothing))
    }

    func testAConnectedCalendarIsSetUpShownBusyThenCopies() {
        XCTAssertEqual(OnboardingFlow.next(after: .connect, in: connected), .calendars)
        XCTAssertEqual(OnboardingFlow.next(after: .calendars, in: connected), .copies)
        XCTAssertEqual(OnboardingFlow.next(after: .copies, in: connected), .done)
        XCTAssertNil(OnboardingFlow.next(after: .done, in: connected))
    }

    func testCopiesAreAskedOnlyWithACalendarOfYourOwnAndNoAnswerYet() {
        // Answered here before, or on another device: not asked again.
        var settled = connected
        settled.copiesSettled = true
        XCTAssertEqual(OnboardingFlow.next(after: .calendars, in: settled), .done)
        // Only someone else's calendars: nowhere a copy could go.
        var shared = connected
        shared.ownsWritableCalendar = false
        XCTAssertEqual(OnboardingFlow.next(after: .calendars, in: shared), .done)
        XCTAssertFalse(OnboardingFlow.asksAboutCopies(nothing))
        XCTAssertTrue(OnboardingFlow.asksAboutCopies(connected))
    }

    func testBusyBlocksAreSettledByAnAnswerHereOrAChoiceFromElsewhere() {
        XCTAssertFalse(WriteBackStart.settled(questionAnswered: false, hasPreference: false, sharedChoice: nil))
        XCTAssertTrue(WriteBackStart.settled(questionAnswered: true, hasPreference: false, sharedChoice: nil))
        XCTAssertTrue(WriteBackStart.settled(questionAnswered: false, hasPreference: true, sharedChoice: nil))
        XCTAssertTrue(WriteBackStart.settled(questionAnswered: false, hasPreference: false, sharedChoice: false))
    }

    func testBackRetracesTheSameSteps() {
        XCTAssertNil(OnboardingFlow.previous(before: .welcome))
        XCTAssertEqual(OnboardingFlow.previous(before: .modules), .welcome)
        XCTAssertEqual(OnboardingFlow.previous(before: .wake), .modules)
        XCTAssertEqual(OnboardingFlow.previous(before: .windDown), .wake)
        XCTAssertEqual(OnboardingFlow.previous(before: .connect), .windDown)
        XCTAssertEqual(OnboardingFlow.previous(before: .calendars), .connect)
        XCTAssertEqual(OnboardingFlow.previous(before: .copies), .calendars)
        XCTAssertNil(OnboardingFlow.previous(before: .done), "what the receipt lists has been applied")
    }

    func testAResumedFirstRunOpensWhereItWasUnlessThatPageNoLongerApplies() {
        XCTAssertEqual(OnboardingFlow.resume(nil, in: nothing), .welcome)
        XCTAssertEqual(OnboardingFlow.resume(.windDown, in: nothing), .windDown)
        XCTAssertEqual(OnboardingFlow.resume(.copies, in: connected), .copies)
        // The account went (signed out on another device): back to connecting one.
        XCTAssertEqual(OnboardingFlow.resume(.calendars, in: nothing), .connect)
        XCTAssertEqual(OnboardingFlow.resume(.copies, in: nothing), .connect)
        XCTAssertEqual(OnboardingFlow.resume(.done, in: nothing), .connect)
        // Copies answered elsewhere meanwhile: straight to the receipt.
        var settled = connected
        settled.copiesSettled = true
        XCTAssertEqual(OnboardingFlow.resume(.copies, in: settled), .done)
    }

    func testOnceTheFirstRunIsDoneTheAppIsOpenWhateverIsConnected() {
        // The Mac needed a connected Google calendar as well, and had no way past its screen.
        XCTAssertFalse(OnboardingFlow.showsFirstRun(completed: true))
        XCTAssertTrue(OnboardingFlow.showsFirstRun(completed: false))
    }

    // MARK: - Show and busy

    private func calendar(_ id: String, _ title: String, role: String, owner: String? = nil) -> GoogleCalendar {
        GoogleCalendar(accountEmail: "noor@plan.example", id: id, summary: title, summaryOverride: nil,
                       backgroundColor: nil, accessRole: role, primary: id == "noor@plan.example" ? true : nil,
                       hidden: nil, deleted: nil, dataOwner: owner)
    }

    private var three: [GoogleCalendar] {
        [calendar("family@group.calendar.google.com", "Family", role: "writer", owner: "sam@plan.example"),
         calendar("noor@plan.example", "Work", role: "owner"),
         calendar("personal@group.calendar.google.com", "Personal", role: "owner", owner: "noor@plan.example")]
    }

    func testSharedCalendarsShowButDoNotMakeYouBusy() {
        let rows = CalendarChoices.rows(three, settings: SmartScheduleSettings())
        XCTAssertEqual(rows.map(\.title), ["Personal", "Work", "Family"], "yours first, then shared")
        XCTAssertTrue(rows.allSatisfy(\.shown))
        XCTAssertEqual(rows.filter(\.busy).map(\.title), ["Personal", "Work"])
    }

    func testShowAndBusyWriteTheSettingsSettingsUses() {
        var settings = SmartScheduleSettings()
        var rows = CalendarChoices.rows(three, settings: settings)
        let family = rows.first { $0.title == "Family" }!
        CalendarChoices.setBusy(true, for: family, in: &settings)
        XCTAssertEqual(settings.calendarBlockingOverrides[family.id], true)
        let work = rows.first { $0.title == "Work" }!
        CalendarChoices.setShown(false, for: work, in: &settings)
        XCTAssertTrue(settings.excludedCalendarIDs.contains(GoogleCalendarIDs.calendarInfoID(work.id)))
        rows = CalendarChoices.rows(three, settings: settings)
        XCTAssertFalse(rows.first { $0.title == "Work" }!.busy, "a hidden calendar blocks nothing")
        XCTAssertTrue(rows.first { $0.title == "Family" }!.busy)
        // Busy on a hidden calendar shows it again.
        CalendarChoices.setBusy(true, for: rows.first { $0.title == "Work" }!, in: &settings)
        XCTAssertFalse(settings.excludedCalendarIDs.contains(GoogleCalendarIDs.calendarInfoID(work.id)))
    }

    func testTheReceiptSaysWhatWasChosen() {
        let rows = CalendarChoices.rows(three, settings: SmartScheduleSettings())
        let off = OnboardingReceipt(choices: rows, copies: .off)
        XCTAssertEqual(OnboardingReceipt.line(off.shown), "Personal, Work, Family")
        XCTAssertEqual(OnboardingReceipt.line(off.busy), "Personal, Work")
        XCTAssertEqual(off.copiesLine, "Off")
        XCTAssertEqual(OnboardingReceipt(choices: rows, copies: .on(count: 12, to: ["Work"])).copiesLine, "12 on Work")
        XCTAssertEqual(OnboardingReceipt(choices: rows, copies: .on(count: nil, to: [])).copiesLine, "On")
        XCTAssertEqual(OnboardingReceipt.line([]), "None")
    }

    func testTheTimeStripStaysInsideTheQuestion() {
        XCTAssertEqual(TimeTicks.around(6 * 60 + 30, in: DayAnchors.wakeRange), [360, 375, 390, 405, 420])
        // At the ends the strip stops at the range, five ticks still.
        XCTAssertEqual(TimeTicks.around(3 * 60, in: DayAnchors.wakeRange), [180, 195, 210, 225, 240])
        XCTAssertEqual(TimeTicks.around(23 * 60 + 59, in: DayAnchors.windDownRange), [1365, 1380, 1395, 1410, 1425])
        XCTAssertTrue(TimeTicks.around(21 * 60, in: DayAnchors.windDownRange).contains(21 * 60))
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
