import XCTest

final class RoutineEditorValuesTests: XCTestCase {
    private let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    private var day: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 15, minute: 42))!
    }

    func testClockTimeSurvivesTheTripThroughADate() {
        for (hour, minute) in [(0, 0), (6, 45), (12, 0), (23, 59)] {
            let date = RoutineEditorValues.date(hour: hour, minute: minute, on: day, calendar: calendar)
            let clock = RoutineEditorValues.clock(of: date, calendar: calendar)
            XCTAssertEqual(clock.hour, hour)
            XCTAssertEqual(clock.minute, minute)
        }
    }

    func testDateKeepsTheDayAndDropsSeconds() {
        let date = RoutineEditorValues.date(hour: 7, minute: 30, on: day, calendar: calendar)
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        XCTAssertEqual(parts.year, 2026)
        XCTAssertEqual(parts.month, 10)
        XCTAssertEqual(parts.day, 11)
        XCTAssertEqual(parts.hour, 7)
        XCTAssertEqual(parts.minute, 30)
        XCTAssertEqual(parts.second, 0)
    }

    func testStoredDaysBecomeTheRowsSelection() {
        XCTAssertEqual(RoutineEditorValues.days([2, 4, 6]), [.monday, .wednesday, .friday])
        XCTAssertEqual(RoutineEditorValues.days([1, 7]), [.sunday, .saturday])
    }

    func testNoDaysStaysNoDays() {
        // None stored means every day; the row shows none chosen and writes none back.
        XCTAssertEqual(RoutineEditorValues.days([]), [])
        XCTAssertEqual(RoutineEditorValues.weekdays([]), [])
    }

    func testDaysOutOfRangeAndRepeatsAreDropped() {
        XCTAssertEqual(RoutineEditorValues.days([0, 2, 2, 8]), [.monday])
    }

    func testSelectionIsStoredSundayFirstWhateverTheTapOrder() {
        XCTAssertEqual(RoutineEditorValues.weekdays([.friday, .sunday, .tuesday]), [1, 3, 6])
    }

    func testDaysSurviveTheTrip() {
        let stored = [2, 3, 4, 5, 6]
        XCTAssertEqual(RoutineEditorValues.weekdays(RoutineEditorValues.days(stored)), stored)
    }
}
