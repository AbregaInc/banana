import XCTest

/// "I had two of those" without retyping four numbers.
final class PortionScalingTests: XCTestCase {
    private let toast = NutritionMacros(calories: 120, proteinGrams: 4, carbohydrateGrams: 22, fatGrams: 1.5)

    func testScalingMultipliesEveryMacro() {
        let two = PortionScaling.scaled(toast, by: 2)
        XCTAssertEqual(two.calories, 240)
        XCTAssertEqual(two.proteinGrams, 8)
        XCTAssertEqual(two.carbohydrateGrams, 44)
        XCTAssertEqual(two.fatGrams, 3)
    }

    func testTheServingSaysHowMany() {
        XCTAssertEqual(PortionScaling.serving("1 slice", factor: 2), "2 × 1 slice")
        XCTAssertEqual(PortionScaling.serving("1 slice", factor: 0.5), "½ × 1 slice")
        XCTAssertEqual(PortionScaling.serving("1 slice", factor: 1), "1 slice")
        XCTAssertEqual(PortionScaling.serving("", factor: 1.5), "1½ serving")
        XCTAssertEqual(PortionScaling.label(1.5), "1½×")
    }

    func testAHugeSingleItemIsFlagged() {
        XCTAssertFalse(PortionScaling.isImplausible(toast))
        XCTAssertTrue(PortionScaling.isImplausible(PortionScaling.scaled(toast, by: 100)))
    }

    func testTheMacroLine() {
        // Protein, carbs, fat, each held together so a wrapped line never splits "F" from its grams.
        XCTAssertEqual(NutritionText.macroLine(toast), "P\u{00A0}4\u{00A0}g · C\u{00A0}22\u{00A0}g · F\u{00A0}2\u{00A0}g")
        XCTAssertEqual(NutritionText.kcal(toast), "120\u{00A0}kcal")
        XCTAssertEqual(NutritionText.kcal(2_028), "2,028\u{00A0}kcal")
    }

    func testAMeasureLosesUSDAsStrayOne() {
        XCTAssertEqual(NutritionText.measure("1 5.3 oz container"), "5.3 oz container")
        XCTAssertEqual(NutritionText.measure("1 cup"), "1 cup")
        XCTAssertEqual(NutritionText.serving("1 6 oz container", grams: 170), "6 oz container \u{00B7} 170 g")
    }

    func testUSDAsNotSpecifiedClausesAreDropped() {
        XCTAssertEqual(GroundedFoodEstimate.displayName("Yogurt, Greek, NS as to type of milk, plain"), "Yogurt, Greek, plain")
        XCTAssertEqual(GroundedFoodEstimate.displayName("Yogurt, Greek, NS as to type of milk or flavor"), "Yogurt, Greek")
        XCTAssertEqual(GroundedFoodEstimate.displayName("Rice, NFS"), "Rice")
        XCTAssertEqual(GroundedFoodEstimate.displayName("white rice"), "White rice")
    }
}
