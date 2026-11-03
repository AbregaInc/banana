import XCTest

final class AssistantNutritionTests: XCTestCase {
    private let calendar = AssistantNutrition.calendar(TimeZone(identifier: "America/New_York")!)
    private func surface() -> AssistantNutritionSurface {
        .init(revision: 1, metric: .protein, start: "2026-03-07", end: "2026-03-09", weekdaysOnly: false, compare: true, search: "")
    }
    private func meal(_ day: String, _ protein: Double, name: String = "Breakfast") throws -> MealEntry {
        MealEntry(date: try AssistantNutrition.date(day, calendar: calendar), items: [
            MealItem(name: "Yogurt", serving: "1 cup", macros: .init(calories: 100, proteinGrams: protein))
        ], name: name)
    }
    func testMissingDaysAreNotZeroAndSameDayMealsSum() throws {
        let days = AssistantNutrition.days(surface(), meals: [try meal("2026-03-07", 10), try meal("2026-03-07", 20)], calendar: calendar)
        XCTAssertEqual(days.count, 3)
        XCTAssertEqual(days[0].value, 30)
        XCTAssertNil(days[1].value)
        XCTAssertNil(days[2].value)
    }
    func testPreviousIntervalUsesCalendarDaysAcrossDST() throws {
        let days = AssistantNutrition.days(surface(), meals: [try meal("2026-03-04", 15), try meal("2026-03-06", 25)], calendar: calendar)
        XCTAssertEqual(days.map(\.id), ["2026-03-07", "2026-03-08", "2026-03-09"])
        XCTAssertEqual(days[0].previous, 15)
        XCTAssertEqual(days[2].previous, 25)
    }
    func testWeekdaysAndFoodSearchFilterActualEntries() throws {
        var view = surface(); view.weekdaysOnly = true; view.search = "yogurt"
        let days = AssistantNutrition.days(view, meals: [try meal("2026-03-09", 18)], calendar: calendar)
        XCTAssertEqual(days.map(\.id), ["2026-03-09"])
        XCTAssertEqual(days.first?.value, 18)
        view.search = "not logged"
        XCTAssertNil(AssistantNutrition.days(view, meals: [try meal("2026-03-09", 18)], calendar: calendar).first?.value)
    }
    func testMealNameSearchAndMetricSelection() throws {
        var view = surface(); view.search = "breakfast"; view.metric = .calories
        XCTAssertEqual(AssistantNutrition.days(view, meals: [try meal("2026-03-09", 18)], calendar: calendar).last?.value, 100)
    }
    func testInvalidDatesRangesAndSelectionAreRejected() throws {
        XCTAssertThrowsError(try AssistantNutrition.date("2026-02-30", calendar: calendar))
        var view = surface(); view.end = "2026-03-01"
        XCTAssertThrowsError(try AssistantNutrition.validate(view, calendar: calendar))
        view = surface(); view.end = "2027-01-01"
        XCTAssertThrowsError(try AssistantNutrition.validate(view, calendar: calendar))
        view = surface(); view.weekdaysOnly = true; view.selectedDay = "2026-03-08"
        XCTAssertThrowsError(try AssistantNutrition.validate(view, calendar: calendar))
        view = surface(); view.selectedDay = "2026-03-10"
        XCTAssertThrowsError(try AssistantNutrition.validate(view, calendar: calendar))
    }
    func testDraftRequiresValidMealIdentityAndDate() throws {
        var view = surface(); view.draftMealID = "invented"
        XCTAssertThrowsError(try AssistantNutrition.validate(view, calendar: calendar))
        view.draftMealID = UUID().uuidString; view.draftDate = "2026-03-10"
        XCTAssertNoThrow(try AssistantNutrition.validate(view, calendar: calendar))
    }
    func testRelativePeriodsUseNativeCalendarArithmetic() throws {
        let now = try AssistantNutrition.date("2026-03-09", calendar: calendar)
        let month = try AssistantNutrition.resolve(surface(), period: "this_month", now: now, calendar: calendar)
        XCTAssertEqual(month.start, "2026-03-01"); XCTAssertEqual(month.end, "2026-03-09")
        let last = try AssistantNutrition.resolve(surface(), period: "last_month", now: now, calendar: calendar)
        XCTAssertEqual(last.start, "2026-02-01"); XCTAssertEqual(last.end, "2026-02-28")
        let week = try AssistantNutrition.resolve(surface(), period: "last_7_days", now: now, calendar: calendar)
        XCTAssertEqual(week.start, "2026-03-03"); XCTAssertEqual(week.end, "2026-03-09")
    }
    func testWeekdayFilterAlsoExcludesPriorWeekendMeals() throws {
        var view = surface(); view.start = "2026-03-09"; view.end = "2026-03-10"; view.weekdaysOnly = true
        let days = AssistantNutrition.days(view, meals: [try meal("2026-03-07", 20), try meal("2026-03-08", 30)], calendar: calendar)
        XCTAssertEqual(days.count, 2)
        XCTAssertTrue(days.allSatisfy { $0.previous == nil })
    }
}
