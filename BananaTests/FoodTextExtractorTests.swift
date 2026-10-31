import XCTest

/// Exercises only the pure, model-independent parts of natural-language food entry —
/// `FoodTextExtractor.resolve(_:)` and how an amount is sized. `FoundationModels` is never invoked
/// here: `resolve(_:)` takes its catalog lookup and learned-correction lookup as injected
/// closures specifically so this is possible without the on-device model.
final class FoodTextExtractorTests: XCTestCase {
    private lazy var catalog: GenericFoodTable! = GenericFoodCatalog.loadTable(from: Bundle(for: Self.self))

    private func catalogMatch(_ name: String) -> GenericFood? {
        GenericFoodCatalog.match(name: name, in: catalog)
    }

    private func fixture(name: String, quantity: String, calories: Double = 999,
                         protein: Double = 999, carbs: Double = 999, fat: Double = 999) -> ExtractedFoodItem {
        .init(name: name, quantityPhrase: quantity, estimatedCalories: calories,
              estimatedProteinGrams: protein, estimatedCarbGrams: carbs, estimatedFatGrams: fat)
    }

    // MARK: - Resolution priority: learned > catalog > estimate

    func testCatalogHitYieldsExactMacrosAndHighConfidence() throws {
        let egg = try XCTUnwrap(catalogMatch("egg"))
        let item = fixture(name: "egg", quantity: "2 large")

        let resolved = FoodTextExtractor.resolve(item, catalogMatch: catalogMatch)

        XCTAssertEqual(resolved.source, .catalog)
        XCTAssertEqual(resolved.confidence, 1.0)
        XCTAssertEqual(resolved.macros.calories, egg.unitMacros.calories * 2, accuracy: 0.01)
        XCTAssertEqual(resolved.macros.proteinGrams, egg.unitMacros.proteinGrams * 2, accuracy: 0.01)
        XCTAssertEqual(resolved.serving, "2 large")
    }

    func testCatalogMissFallsThroughToTheModelsOwnEstimateWithLowConfidence() {
        let item = fixture(name: "xyz-not-a-real-food-123", quantity: "1 bowl",
                           calories: 250, protein: 10, carbs: 20, fat: 5)

        let resolved = FoodTextExtractor.resolve(item, catalogMatch: catalogMatch)

        XCTAssertEqual(resolved.source, .aiEstimate)
        XCTAssertEqual(resolved.confidence, 0.35)
        XCTAssertEqual(resolved.macros.calories, 250)
        XCTAssertEqual(resolved.macros.proteinGrams, 10)
        XCTAssertEqual(resolved.macros.carbohydrateGrams, 20)
        XCTAssertEqual(resolved.macros.fatGrams, 5)
        XCTAssertFalse(resolved.isConfident)
    }

    func testLearnedCorrectionOutranksACatalogMatch() throws {
        // "egg" genuinely matches the catalog, but a learned correction must still win.
        XCTAssertNotNil(catalogMatch("egg"))
        let correction = FoodCorrection(
            macros: .init(calories: 999, proteinGrams: 40, carbohydrateGrams: 1, fatGrams: 2),
            serving: "3 large, my usual", observedCount: 2)

        let resolved = FoodTextExtractor.resolve(fixture(name: "egg", quantity: "2 large"),
                                                  catalogMatch: catalogMatch,
                                                  learned: { $0 == "egg" ? correction : nil })

        XCTAssertEqual(resolved.source, .learned)
        XCTAssertEqual(resolved.confidence, 1.0)
        XCTAssertEqual(resolved.macros, correction.macros)
        XCTAssertEqual(resolved.serving, "3 large, my usual")
    }

    // MARK: - The amount said, against the catalog's unit

    private func calories(_ name: String, _ quantity: String) -> (calories: Double, source: ResolvedFoodItem.Source) {
        let resolved = FoodTextExtractor.resolve(fixture(name: name, quantity: quantity), catalogMatch: catalogMatch)
        return (resolved.macros.calories, resolved.source)
    }

    func testAWeightIsDividedByWhatTheUnitWeighs() throws {
        // Rice is "1 cup cooked (158 g)": 200 g was read as 200 cups.
        let rice = try XCTUnwrap(catalogMatch("rice"))
        let said = calories("rice", "200 g")
        XCTAssertEqual(said.source, .catalog)
        XCTAssertEqual(said.calories, rice.unitMacros.calories * 200 / 158, accuracy: 0.5)
        // Chicken is "3 oz cooked (85 g)": six ounces is two of them.
        let chicken = try XCTUnwrap(catalogMatch("chicken breast"))
        XCTAssertEqual(calories("chicken breast", "6 oz").calories, chicken.unitMacros.calories * 2, accuracy: 1)
    }

    func testAFractionIsAFraction() throws {
        // "1/2 cup" was one cup: only the leading whole number was read.
        let rice = try XCTUnwrap(catalogMatch("rice"))
        XCTAssertEqual(calories("rice", "1/2 cup").calories, rice.unitMacros.calories / 2, accuracy: 0.5)
        XCTAssertEqual(calories("rice", "1.5 cups").calories, rice.unitMacros.calories * 1.5, accuracy: 0.5)
    }

    func testOneVolumeIsConvertedToAnother() throws {
        // Butter is "1 tbsp (14 g)": two teaspoons are two thirds of it.
        let butter = try XCTUnwrap(catalogMatch("butter"))
        XCTAssertEqual(calories("butter", "2 tsp").calories, butter.unitMacros.calories * 2 / 3, accuracy: 1)
        let rice = try XCTUnwrap(catalogMatch("rice"))
        XCTAssertEqual(calories("rice", "a bowl").calories, rice.unitMacros.calories * 1.5, accuracy: 1,
                       "a bowl is about a cup and a half")
    }

    func testACountIsDividedByWhatTheUnitCounts() throws {
        let egg = try XCTUnwrap(catalogMatch("egg"))
        XCTAssertEqual(calories("egg", "3").calories, egg.unitMacros.calories * 3, accuracy: 0.01)
        // Tacos are "2 tacos": four are two units, not four.
        let taco = try XCTUnwrap(catalogMatch("taco"))
        XCTAssertEqual(calories("tacos", "4").calories, taco.unitMacros.calories * 2, accuracy: 0.01)
    }

    func testAnAmountThatCannotBeComparedIsAnEstimateNotAConfidentGuess() {
        // A cup of something sold by weight, a weight of something counted, a slice of rice:
        // nothing to convert with, so the catalog's number isn't multiplied anyway.
        XCTAssertEqual(calories("chicken breast", "1 cup").source, .aiEstimate)
        XCTAssertEqual(calories("egg", "100 g").source, .aiEstimate)
        XCTAssertEqual(calories("rice", "2 slices").source, .aiEstimate)
    }

    func testNoAmountIsOneUnit() throws {
        let rice = try XCTUnwrap(catalogMatch("rice"))
        XCTAssertEqual(calories("rice", "").calories, rice.unitMacros.calories, accuracy: 0.01)
        XCTAssertEqual(calories("rice", "1 serving").calories, rice.unitMacros.calories, accuracy: 0.01)
    }

    func testTheCatalogIsConsultedOnlyWhenItCanPriceTheAmount() {
        XCTAssertNotNil(FoodTextExtractor.catalogUnits("rice", "200 g", catalogMatch))
        XCTAssertNil(FoodTextExtractor.catalogUnits("rice", "2 slices", catalogMatch), "this one goes to the model")
        XCTAssertNil(FoodTextExtractor.catalogUnits("dragon fruit smoothie", "1 cup", catalogMatch))
    }

    func testResolveDefaultsServingWhenQuantityIsEmpty() {
        let resolved = FoodTextExtractor.resolve(fixture(name: "xyz-unknown", quantity: ""),
                                                  catalogMatch: catalogMatch)
        XCTAssertEqual(resolved.serving, "1 serving")
    }

    // MARK: - ResolvedFoodItem.Source.saved (saved-meal editing, FoodTextCaptureView)

    func testSavedSourceBadgeAndConfidence() {
        let saved = ResolvedFoodItem(name: "Egg", serving: "2 large", macros: .init(), confidence: 1.0, source: .saved)
        XCTAssertTrue(saved.isConfident)
        XCTAssertEqual(saved.badgeText, "Already saved")
    }

    // MARK: - MealEntry.Source.text

    func testMealEntrySourceTextRoundTripsThroughCodable() throws {
        let entry = MealEntry(items: [MealItem(name: "Eggs", serving: "2 large", macros: .init())],
                              note: "two eggs", source: .text)

        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(MealEntry.self, from: data)

        XCTAssertEqual(decoded.source, .text)
        XCTAssertEqual(decoded.note, "two eggs")
    }
}
