import XCTest

final class PiSampleMealsTests: XCTestCase {
    private let calendar = AssistantNutrition.calendar(TimeZone(identifier: "America/New_York")!)
    private var now: Date { try! AssistantNutrition.date("2026-10-24", calendar: calendar) }

    func testHistoryIsDeterministicVariedAndHasGaps() {
        let meals = PiSampleMeals.make(now: now, calendar: calendar)
        XCTAssertEqual(meals, PiSampleMeals.make(now: now, calendar: calendar))
        XCTAssertEqual(meals.count, 249)
        XCTAssertEqual(Set(meals.map(\.id)).count, meals.count)
        XCTAssertGreaterThan(Set(meals.map(\.name)).count, 3)
        XCTAssertEqual(Set(meals.map { AssistantNutrition.key($0.date, calendar: calendar) }).count, 83)
        XCTAssertTrue(meals.allSatisfy(PiSampleMeals.contains))
    }
    func testReloadDoesNotDuplicateOrOverwriteExistingRows() {
        var original = PiSampleMeals.make(now: now, calendar: calendar)
        original[0].name = "Edited sample breakfast"
        let reloaded = PiSampleMeals.adding(to: original, now: now, calendar: calendar)
        XCTAssertEqual(reloaded.count, original.count)
        XCTAssertEqual(reloaded.first(where: { $0.id == original[0].id })?.name, "Edited sample breakfast")
    }
    func testRemovalKeepsRealMealsAndSavedCopies() {
        var real = PiSampleMeals.make(now: now, calendar: calendar)[0]
        real.id = UUID(); real.note = "My own meal"
        var copy = real; copy.id = UUID(); copy.note = PiSampleMeals.marker
        let result = PiSampleMeals.removing(from: PiSampleMeals.adding(to: [real, copy], now: now, calendar: calendar))
        XCTAssertEqual(Set(result.map(\.id)), Set([real.id, copy.id]))
    }
    func testDataSupportsFoodSearchAndPreviousPeriodComparison() throws {
        let meals = PiSampleMeals.make(now: now, calendar: calendar)
        var view = AssistantNutritionSurface(revision: 1, metric: .protein, start: "2026-10-01", end: "2026-10-24",
            weekdaysOnly: false, compare: true, search: "")
        let days = AssistantNutrition.days(view, meals: meals, calendar: calendar)
        XCTAssertTrue(days.contains { $0.value != nil })
        XCTAssertTrue(days.contains { $0.previous != nil })
        view.search = "yogurt"
        XCTAssertFalse(AssistantNutrition.days(view, meals: meals, calendar: calendar).flatMap(\.meals).isEmpty)
    }
    func testStableIDsSurviveDifferentGenerationDates() {
        let first = PiSampleMeals.make(now: now, calendar: calendar)
        let next = PiSampleMeals.make(now: calendar.date(byAdding: .day, value: 1, to: now)!, calendar: calendar)
        let existing = Dictionary(uniqueKeysWithValues: first.map { ($0.id, $0) })
        for meal in next {
            if let prior = existing[meal.id] { XCTAssertEqual(meal, prior) }
        }
    }
    func testSnapshotRoundTripPreservesMarkersAndNutrition() throws {
        var snapshot = WellnessSnapshot(); snapshot.meals = PiSampleMeals.make(now: now, calendar: calendar)
        let restored = try JSONDecoder().decode(WellnessSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(restored.meals, snapshot.meals)
    }
}
