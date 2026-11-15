import XCTest

final class FoodNutrientIntakeTests: XCTestCase {
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c }
    private let start = Date(timeIntervalSince1970: 1_800_057_600)
    private var definition: FoodNutrientIntake.Definition { .init(id: "1180", key: "choline", name: "Choline", unit: "mg", aliases: ["coline"], reference: nil) }
    private func item(_ id: String?, grams: Double?, serving: String = "") -> MealItem {
        .init(name: "Food", serving: serving, macros: .init(), grams: grams,
              reference: id.map { FoodReference(id: $0, name: "Catalog food", per100g: .init()) })
    }
    private func meal(_ items: [MealItem], offset: Int = 0) -> MealEntry {
        MealEntry(date: calendar.date(byAdding: .day, value: offset, to: start)!, items: items, name: "Meal")
    }
    func testKnownValuesScaleByPortionAndMissingItemsAndDaysAreNotZero() throws {
        let end = calendar.date(byAdding: .day, value: 2, to: start)!
        let report = try FoodNutrientIntake.report(nutrient: "coline", start: start, end: end,
            meals: [meal([item("sr:1", grams: 150), item(nil, grams: 100)]), meal([item("sr:2", grams: nil)], offset: 1)], calendar: calendar,
            lookup: { _, _ in .init(definition: self.definition, values: ["sr:1": 100, "sr:2": 40]) })
        XCTAssertEqual(report.estimateFromLoggedFoods, 150)
        XCTAssertEqual(report.averagePerDayWithData, 150)
        XCTAssertEqual(report.quantifiedItems, 1)
        XCTAssertEqual(report.unknownItems, 2)
        XCTAssertNil(report.days[1].amount)
        XCTAssertNil(report.days[2].amount)
        XCTAssertFalse(report.fullDietCoverageKnown)
        XCTAssertEqual(report.contributors.first?.grams, 150)
    }
    func testMeasuredZeroIsDistinctFromAnUnavailableMeasurement() throws {
        let report = try FoodNutrientIntake.report(nutrient: "choline", start: start, end: start,
            meals: [meal([item("sr:1", grams: 100), item("sr:2", grams: 100)])], calendar: calendar,
            lookup: { _, _ in .init(definition: self.definition, values: ["sr:1": 0]) })
        XCTAssertEqual(report.estimateFromLoggedFoods, 0)
        XCTAssertEqual(report.quantifiedItems, 1)
        XCTAssertEqual(report.unknownItems, 1)
    }
    func testOlderExplicitMassIsUsableButAnUnspecifiedServingIsNotGuessed() throws {
        let report = try FoodNutrientIntake.report(nutrient: "choline", start: start, end: start,
            meals: [meal([item("sr:1", grams: nil, serving: "50 g"), item("sr:1", grams: nil, serving: "a plate")])], calendar: calendar,
            lookup: { _, _ in .init(definition: self.definition, values: ["sr:1": 200]) })
        XCTAssertEqual(report.estimateFromLoggedFoods, 100)
        XCTAssertEqual(report.unknownItems, 1)
    }
    func testBundledFixtureHasRealNutrientsAndAliasesWithoutChangingFoodMatches() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "FoodsFixture", withExtension: "sqlite"))
        let catalog = try XCTUnwrap(FoodDatabase.nutrientCatalog("coline", foodIDs: ["fndds:2706437"], databaseURL: url))
        XCTAssertEqual(catalog.definition.key, "choline")
        XCTAssertEqual(catalog.definition.unit, "mg")
        XCTAssertEqual(catalog.values["fndds:2706437"], 22.4)
        XCTAssertNotNil(catalog.definition.reference)
        XCTAssertNil(FoodDatabase.nutrientCatalog("a made up nutrient", foodIDs: [], databaseURL: url))
    }
}
