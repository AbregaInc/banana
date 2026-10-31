import XCTest

/// The plan asks for one thing at a time above the day (`PlanPrompt`). These cards lived only on
/// the retired Today screen, so the phone's plan had no "calendar isn't connected" state at all.
final class PlanPromptTests: XCTestCase {
    func testACalendarThatIsNotConnectedComesFirst() {
        XCTAssertEqual(PlanPrompt.current(calendarConnected: false, hasPlaceQuestion: true), .connectCalendar)
        XCTAssertEqual(PlanPrompt.current(calendarConnected: false, hasPlaceQuestion: false), .connectCalendar)
        // Nothing a connected calendar would raise is asked without one.
        let everything = PlanPrompt.Open(busyCalendars: true, notifications: true, reminders: true)
        XCTAssertEqual(PlanPrompt.current(calendarConnected: false, hasPlaceQuestion: false, open: everything), .connectCalendar)
    }

    func testThenATripTimedToAGuessedPlace() {
        XCTAssertEqual(PlanPrompt.current(calendarConnected: true, hasPlaceQuestion: true), .placeQuestion)
        let everything = PlanPrompt.Open(busyCalendars: true, notifications: true, reminders: true)
        XCTAssertEqual(PlanPrompt.current(calendarConnected: true, hasPlaceQuestion: true, open: everything), .placeQuestion,
                       "a trip has a clock on it; the asks do not")
    }

    func testThenWhatTheCalendarMakesWorthAskingOneAtATime() {
        var open = PlanPrompt.Open(busyCalendars: true, notifications: true, reminders: true)
        XCTAssertEqual(PlanPrompt.current(calendarConnected: true, hasPlaceQuestion: false, open: open), .busyCalendars)
        open.busyCalendars = false
        XCTAssertEqual(PlanPrompt.current(calendarConnected: true, hasPlaceQuestion: false, open: open), .notifications)
        open.notifications = false
        XCTAssertEqual(PlanPrompt.current(calendarConnected: true, hasPlaceQuestion: false, open: open), .reminders)
    }

    func testThenTheRestOfSetup() {
        XCTAssertEqual(PlanPrompt.current(calendarConnected: true, hasPlaceQuestion: false), .finishSetup)
    }

    // MARK: - Busy blocks wait for an answer

    func testNothingIsWrittenBeforeTheQuestionIsAnswered() {
        // Busy blocks started the moment a Google account connected, with the sheet that explains
        // them shown after. The sheet no longer stands in that spot, so the start waits for it.
        XCTAssertFalse(WriteBackStart.mayStartByDefault(questionAnswered: false, hasPreference: false, sharedChoice: nil))
        XCTAssertTrue(WriteBackStart.mayStartByDefault(questionAnswered: true, hasPreference: false, sharedChoice: nil))
    }

    func testAChoiceAlreadyMadeIsNeitherAskedAgainNorChanged() {
        // This device chose before, or another of the person's devices did.
        XCTAssertFalse(WriteBackStart.mayStartByDefault(questionAnswered: true, hasPreference: true, sharedChoice: nil))
        XCTAssertFalse(WriteBackStart.mayStartByDefault(questionAnswered: true, hasPreference: false, sharedChoice: false))
        XCTAssertFalse(WriteBackStart.needsAnswer(connected: true, ownsACalendar: true, questionAnswered: false,
                                                  hasPreference: true, sharedChoice: nil))
        XCTAssertFalse(WriteBackStart.needsAnswer(connected: true, ownsACalendar: true, questionAnswered: false,
                                                  hasPreference: false, sharedChoice: true))
    }

    func testThePlanAsksOnlySomeoneWithACalendarOfTheirOwnToWriteTo() {
        XCTAssertTrue(WriteBackStart.needsAnswer(connected: true, ownsACalendar: true, questionAnswered: false,
                                                 hasPreference: false, sharedChoice: nil))
        XCTAssertFalse(WriteBackStart.needsAnswer(connected: false, ownsACalendar: true, questionAnswered: false,
                                                  hasPreference: false, sharedChoice: nil))
        XCTAssertFalse(WriteBackStart.needsAnswer(connected: true, ownsACalendar: false, questionAnswered: false,
                                                  hasPreference: false, sharedChoice: nil))
        XCTAssertFalse(WriteBackStart.needsAnswer(connected: true, ownsACalendar: true, questionAnswered: true,
                                                  hasPreference: false, sharedChoice: nil))
    }

    // MARK: - The sample on the card that asks for alerts

    func testTheSampleIsThePersonsNextMeetingInTheAlertsOwnWords() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "h:mm a"
        let later = EventAlertPlan.Candidate(id: "b", title: "Design review", start: now.addingTimeInterval(5 * 3600))
        let sooner = EventAlertPlan.Candidate(id: "a", title: "Team standup", start: now.addingTimeInterval(2 * 3600))
        let sample = NextAlertSample.sample(candidates: [later, sooner], leads: [10], now: now, formatter: formatter)
        XCTAssertEqual(sample?.title, "Team standup")
        // Word for word what the real alert says, ten minutes ahead.
        let item = EventAlertPlan.items(from: [sooner], leads: [10], now: now)[0]
        XCTAssertEqual(sample?.body, EventAlertPlan.body(for: item, now: item.fireAt, formatter: formatter))
        XCTAssertTrue(sample?.body.hasPrefix("Starts in 10 minutes") == true)
    }

    func testNoMeetingAheadMeansNoSampleAndSoNoCard() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let past = EventAlertPlan.Candidate(id: "a", title: "Yesterday", start: now.addingTimeInterval(-3600))
        XCTAssertNil(NextAlertSample.sample(candidates: [past], leads: [10], now: now, formatter: DateFormatter()))
        XCTAssertNil(NextAlertSample.sample(candidates: [], leads: [10], now: now, formatter: DateFormatter()))
    }
}
