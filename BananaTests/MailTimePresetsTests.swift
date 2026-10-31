import XCTest

/// The rows Send later offers (MAIL-UX 6.5.1), the picker's own state, and the words around a
/// scheduled message (`MailScheduleCopy`). Pure: the calendar is one the test makes, and "now" is a
/// moment the test picks.
@MainActor
final class MailTimePresetsTests: XCTestCase {

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }()

    private let locale = Locale(identifier: "en_US")

    /// The system puts a narrow no-break space before AM and PM; a test reads a plain one.
    private func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ")
    }

    /// Wednesday 7 October 2026.
    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    private func titles(_ rows: [MailTimePresets.Preset]) -> [String] { rows.map(\.title) }

    func testOnAWednesdayMorning() {
        let rows = MailTimePresets.rows(now: at(7, 10, 10), calendar: calendar)
        XCTAssertEqual(titles(rows), ["Later today", "Tomorrow morning", "This weekend", "Monday morning"])
        XCTAssertEqual(rows.map(\.date), [at(7, 13, 30), at(8, 8), at(10, 9), at(12, 8)],
                       "three hours on rounded up to the half hour; 8 AM; Saturday 9 AM; Monday 8 AM")
    }

    func testLaterTodayRoundsUpToTheHalfHourAndNeverPastNine() {
        XCTAssertEqual(MailTimePresets.laterToday(now: at(7, 10, 0), calendar: calendar), at(7, 13, 0))
        XCTAssertEqual(MailTimePresets.laterToday(now: at(7, 10, 1), calendar: calendar), at(7, 13, 30))
        XCTAssertEqual(MailTimePresets.laterToday(now: at(7, 10, 30), calendar: calendar), at(7, 13, 30))
        XCTAssertEqual(MailTimePresets.laterToday(now: at(7, 10, 45), calendar: calendar), at(7, 14, 0))
        XCTAssertNil(MailTimePresets.laterToday(now: at(7, 17, 50), calendar: calendar), "9 PM is not before 9 PM")
        XCTAssertEqual(MailTimePresets.laterToday(now: at(7, 17, 20), calendar: calendar), at(7, 20, 30))
        XCTAssertNil(MailTimePresets.laterToday(now: at(7, 19, 0), calendar: calendar), "10 PM is not later today")
        XCTAssertNil(MailTimePresets.laterToday(now: at(7, 22, 0), calendar: calendar), "that is tomorrow")
        let evening = MailTimePresets.rows(now: at(7, 19, 0), calendar: calendar)
        XCTAssertEqual(titles(evening), ["Tomorrow morning", "This weekend", "Monday morning"])
    }

    func testTheWeekendIsTheNextSaturdayAndOnTheWeekendTheOneAfter() {
        XCTAssertEqual(MailTimePresets.weekend(after: at(9, 12), calendar: calendar), at(10, 9), "Friday")
        XCTAssertEqual(MailTimePresets.weekend(after: at(10, 12), calendar: calendar), at(17, 9), "a Saturday")
        XCTAssertEqual(MailTimePresets.weekend(after: at(11, 12), calendar: calendar), at(17, 9), "a Sunday")
        let saturday = MailTimePresets.rows(now: at(10, 12), calendar: calendar)
        XCTAssertEqual(titles(saturday)[2], "Next weekend")
    }

    func testMondayIsTheOneAfterTodayAndOnASundayItIsNotRepeated() {
        XCTAssertEqual(MailTimePresets.nextMonday(after: at(12, 9), calendar: calendar), at(19, 8), "a Monday")
        XCTAssertEqual(MailTimePresets.nextMonday(after: at(10, 9), calendar: calendar), at(12, 8), "a Saturday")
        let sunday = MailTimePresets.rows(now: at(11, 12), calendar: calendar)
        XCTAssertEqual(titles(sunday), ["Later today", "Tomorrow morning", "Next weekend"],
                       "tomorrow morning is Monday morning")
    }

    // MARK: The picker

    func testNothingTypedOffersTheRowsAndTheFirstIsHighlighted() {
        let now = at(7, 10, 10)
        let picker = MailTimePickerModel(now: { now }, holder: .thisDevice(name: "Mac"), calendar: calendar, locale: locale)
        XCTAssertEqual(picker.rows.map(\.id), ["later", "tomorrow", "weekend", "monday"])
        XCTAssertEqual(picker.highlighted, 0)
        XCTAssertEqual(picker.chosen(), at(7, 13, 30))
        XCTAssertEqual(plain(picker.rows[1].time), "Thu 8:00 AM", "every row says when it is")
        picker.moveHighlight(by: 1)
        XCTAssertEqual(picker.chosen(), at(8, 8))
        picker.moveHighlight(by: 99)
        XCTAssertEqual(picker.chosen(), at(12, 8), "it stops at the last")
        picker.moveHighlight(by: -99)
        XCTAssertEqual(picker.highlighted, 0)
    }

    func testATypedTimeIsTheFirstRowAndWhatReturnChooses() throws {
        // A morning of the test's own: with the real clock, "Later today" is gone after 6 PM and
        // the picker offers three rows to take instead of four.
        let now = at(7, 10, 10)
        let picker = MailTimePickerModel(now: { now }, holder: .thisDevice(name: "Mac"), calendar: calendar, locale: locale)
        picker.text = "in 2 hours"
        XCTAssertEqual(picker.rows.first?.id, "typed")
        XCTAssertEqual(picker.rows.first?.title, "in 2 hours")
        XCTAssertEqual(picker.chosen(), now.addingTimeInterval(7_200))
        XCTAssertEqual(picker.rows.count, 5, "the typed time, and the four to take instead")
        picker.text = ""
        XCTAssertEqual(picker.rows.first?.id, "later")
    }

    func testATimeThatHasGoneCannotBeChosen() {
        let now = Date()
        let picker = MailTimePickerModel(now: { now }, holder: .thisDevice(name: "Mac"))
        picker.text = "jan 1 2020"
        XCTAssertTrue(picker.isPast)
        XCTAssertNil(picker.chosen(), "\"That's in the past.\"")
        XCTAssertFalse(picker.rows.contains { $0.id == "typed" })
    }

    func testWordsThatAreNotATimeOfferTheRowsAndChooseTheHighlightedOne() {
        let now = at(7, 10, 10)
        let picker = MailTimePickerModel(now: { now }, holder: .thisDevice(name: "Mac"), calendar: calendar, locale: locale)
        picker.text = "banana"
        XCTAssertFalse(picker.isPast)
        XCTAssertEqual(picker.rows.first?.id, "later")
    }

    func testTheFooterNamesWhoSendsItAndWhenForTheTimeUnderTheHighlight() {
        let now = at(7, 10, 10)
        let picker = MailTimePickerModel(now: { now }, holder: .thisDevice(name: "Mac"), calendar: calendar, locale: locale)
        XCTAssertEqual(plain(picker.note),
                       "This Mac sends it Wed 1:30 PM if Banana is open. If it isn\u{2019}t, the message is late, and waits for you.")
        picker.moveHighlight(by: 1)
        XCTAssertTrue(plain(picker.note).contains("Thu 8:00 AM"), picker.note)
        picker.text = "jan 1 2020"
        XCTAssertEqual(picker.note,
                       "This Mac sends it at the time you choose, if Banana is open. If it isn\u{2019}t, the message is late, and waits for you.",
                       "nothing under the highlight is a time to name")
    }
}
