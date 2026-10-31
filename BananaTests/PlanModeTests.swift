import XCTest

/// Plan is Day or Week, on every device (`PlanMode`). The List it also had is gone, and so is the
/// older "agenda" layout of Week that led to it.
final class PlanModeTests: XCTestCase {
    func testThereAreTwoModesNamedTheSameEverywhere() {
        XCTAssertEqual(PlanMode.allCases.map(\.title), ["Day", "Week"])
    }

    func testAStoredListIsNotAModeAnyMore() {
        // `@AppStorage` then shows its default, Day.
        XCTAssertNil(PlanMode(rawValue: "list"))
    }

    func testWeekThatShowedTheAgendaIsDay() {
        XCTAssertEqual(PlanMode.week.retiringAgendaLayout(true), .day)
    }

    func testWeekOnTheCalendarStaysWeek() {
        XCTAssertEqual(PlanMode.week.retiringAgendaLayout(false), .week)
    }

    func testDayWasNeverTheAgendaSetting() {
        XCTAssertEqual(PlanMode.day.retiringAgendaLayout(true), .day)
    }
}
