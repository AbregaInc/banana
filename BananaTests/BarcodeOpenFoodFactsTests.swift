import XCTest

/// Exercises `BarcodeProductLookup.parseOpenFoodFactsResponse` against real captured Open Food
/// Facts responses (see `OpenFoodFactsFixtures.json`) — this is the code path the bundled USDA
/// catalog cannot cover, since it never contains dietary supplements. No network access here:
/// the fixture is a byte-for-byte record of what the service actually returned during
/// diagnosis, so a fixture that goes stale is a deliberate re-capture, not a flaky assertion.
final class BarcodeOpenFoodFactsTests: XCTestCase {
    private func fixture(_ key: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "OpenFoodFactsFixtures", withExtension: "json"))
        let all = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        return Data(try XCTUnwrap(all[key]).utf8)
    }

    func testVitaminD3ParsesAsSuccessWithNoMacros() throws {
        let product = try XCTUnwrap(
            BarcodeProductLookup.parseOpenFoodFactsResponse(try fixture("vitaminD3"), barcode: "0031604026769"))

        XCTAssertTrue(product.name.contains("Nature Made"), product.name)
        XCTAssertTrue(product.name.contains("Vitamin D3"), product.name)
        XCTAssertNil(product.macros, "a supplement with no Nutrition Facts panel must not be given fabricated macros")
    }

    func testMagnesiumGlycinateParsesAsSuccessWithServingButNoMacros() throws {
        let product = try XCTUnwrap(
            BarcodeProductLookup.parseOpenFoodFactsResponse(try fixture("magnesiumGlycinate"), barcode: "0733739012890"))

        XCTAssertTrue(product.name.contains("Now Foods"), product.name)
        XCTAssertTrue(product.name.contains("Magnesium Glycinate"), product.name)
        XCTAssertEqual(product.serving, "1 serving (1 g)")
        XCTAssertNil(product.macros)
    }

    func testWheyProteinParsesWithMacros() throws {
        let product = try XCTUnwrap(
            BarcodeProductLookup.parseOpenFoodFactsResponse(try fixture("wheyProtein"), barcode: "8719881036429"))
        let macros = try XCTUnwrap(product.macros, "a protein powder has a real Nutrition Facts panel")

        XCTAssertTrue(product.name.contains("XXL Nutrition"), product.name)
        XCTAssertEqual(product.serving, "30 gram")
        // One 30 g scoop — not the 393 kcal per 100 g the source gives, which is kept beside it.
        XCTAssertEqual(macros.calories, 118, accuracy: 0.1)
        XCTAssertEqual(macros.proteinGrams, 23.1, accuracy: 0.1)
        XCTAssertEqual(macros.carbohydrateGrams, 2.43, accuracy: 0.1)
        XCTAssertEqual(macros.fatGrams, 2.01, accuracy: 0.1)
        XCTAssertEqual(product.per100g?.calories ?? 0, 393.33, accuracy: 0.1)
        XCTAssertEqual(product.packageGrams, 600)
        XCTAssertNil(product.servingStated, "it says its serving")
    }

    func testCheeriosControlParsesWithMacros() throws {
        let product = try XCTUnwrap(
            BarcodeProductLookup.parseOpenFoodFactsResponse(try fixture("cheerios"), barcode: "0016000125414"))
        let macros = try XCTUnwrap(product.macros)

        XCTAssertTrue(product.name.localizedCaseInsensitiveContains("Cheerios"), product.name)
        // 140 kcal for the 39 g serving, as the box says — 359 is per 100 g.
        XCTAssertEqual(macros.calories, 140, accuracy: 0.1)
        XCTAssertGreaterThan(macros.proteinGrams, 0)
        XCTAssertEqual(product.per100g?.calories ?? 0, 358.97, accuracy: 0.1)
        // And as one of your foods it's per 100 g again, exactly.
        let food = try XCTUnwrap(MyFoods.food(product: product))
        XCTAssertEqual(food.per100g.calories, 358.97, accuracy: 0.1)
        XCTAssertEqual(food.servingGrams, 39)
        XCTAssertEqual(food.reference.macros(grams: 39).calories, 140, accuracy: 0.1)
    }

    // MARK: - Per 100 g is not per serving, and a package is not a serving

    /// Open Food Facts' record for barcode 0087703011274, as it answered on 5 Oct 2026: a 72 g
    /// pack, nutrition per 100 g, and no serving at all.
    private let noriJSON = #"""
    {"code":"0087703011274","status":1,"product":{"product_name":"Sushi Nori Roasted Seaweed","quantity":"72 g",
     "product_quantity":72,"nutrition_data_per":"100g",
     "nutriments":{"energy-kcal_100g":416.66666666667,"proteins_100g":41.666666666667,
                   "carbohydrates_100g":41.666666666667,"fat_100g":0}}}
    """#

    func testAPackOfSeaweedWithNoServingIsNotOneServingOfThePack() throws {
        let product = try XCTUnwrap(BarcodeProductLookup.parseOpenFoodFactsResponse(Data(noriJSON.utf8), barcode: "0087703011274"))
        XCTAssertEqual(product.serving, "100 g", "the one amount its numbers are true of")
        XCTAssertEqual(product.macros?.calories ?? 0, 416.67, accuracy: 0.01)
        XCTAssertEqual(product.servingStated, false)
        XCTAssertEqual(product.packageGrams, 72, "the pack is the pack")

        let food = try XCTUnwrap(MyFoods.food(product: product))
        XCTAssertEqual(food.per100g.calories, 416.67, accuracy: 0.01, "it was 578.7: per-100 g numbers taken for 72 g")
        XCTAssertFalse(food.servingStated)
        XCTAssertEqual(food.packageGrams, 72)
        XCTAssertEqual(food.reference.macros(grams: 5).calories, 20.8, accuracy: 0.1, "two sheets")
    }

    func testNutritionPer100gIsScaledToTheStatedServing() throws {
        let egg = #"{"status":1,"product":{"product_name":"Eggs","brands":"Trader Joe's","serving_size":"1 egg (50 g)","serving_quantity":"50","nutriments":{"energy-kcal_100g":140,"proteins_100g":12,"carbohydrates_100g":0,"fat_100g":10}}}"#
        let product = try XCTUnwrap(BarcodeProductLookup.parseOpenFoodFactsResponse(Data(egg.utf8), barcode: "00621243"))
        XCTAssertEqual(product.serving, "1 egg (50 g)")
        XCTAssertEqual(product.macros, NutritionMacros(calories: 70, proteinGrams: 6, carbohydrateGrams: 0, fatGrams: 5))
        XCTAssertEqual(try XCTUnwrap(MyFoods.food(product: product)).per100g.calories, 140, "it was 280")
    }

    func testAServingWithoutAWeightInItsTextUsesTheSourcesOwn() throws {
        // "330 ml" of a drink: the source says the serving is 330.
        let drink = #"{"status":1,"product":{"product_name":"Kombucha","serving_size":"330 ml","serving_quantity":330,"nutriments":{"energy-kcal_100g":20,"proteins_100g":0,"carbohydrates_100g":4.5,"fat_100g":0}}}"#
        let product = try XCTUnwrap(BarcodeProductLookup.parseOpenFoodFactsResponse(Data(drink.utf8), barcode: "1"))
        XCTAssertEqual(product.serving, "330 ml")
        XCTAssertEqual(product.macros?.calories ?? 0, 66, accuracy: 0.01)
        // A serving nobody weighed: its numbers stay per 100 g, and say so.
        let bar = #"{"status":1,"product":{"product_name":"Bar","serving_size":"1 bar","nutriments":{"energy-kcal_100g":450}}}"#
        let unweighed = try XCTUnwrap(BarcodeProductLookup.parseOpenFoodFactsResponse(Data(bar.utf8), barcode: "2"))
        XCTAssertEqual(unweighed.serving, "100 g")
        XCTAssertEqual(unweighed.macros?.calories, 450)
        XCTAssertEqual(unweighed.servingStated, false)
    }

    func testASupplementStillFallsBackOnItsPackageText() throws {
        // No nutrition: what it says about itself is all there is, as before.
        let pills = #"{"status":1,"product":{"product_name":"Vitamin C","quantity":"120 tablets"}}"#
        let product = try XCTUnwrap(BarcodeProductLookup.parseOpenFoodFactsResponse(Data(pills.utf8), barcode: "3"))
        XCTAssertEqual(product.serving, "120 tablets")
        XCTAssertNil(product.macros)
        XCTAssertNil(product.per100g)
    }

    func testAWeightIsReadOutOfAServingsText() {
        XCTAssertEqual(BarcodeProductLookup.grams(in: "1 cup (140 g)"), 140)
        XCTAssertEqual(BarcodeProductLookup.grams(in: "30 gram"), 30)
        XCTAssertEqual(BarcodeProductLookup.grams(in: "5.25 Gram(s)"), 5.25)
        XCTAssertNil(BarcodeProductLookup.grams(in: "500 mg"))
        XCTAssertNil(BarcodeProductLookup.grams(in: "330 ml"))
        XCTAssertNil(BarcodeProductLookup.grams(in: "2 softgels"))
    }

    func testGenuinelyAbsentBarcodeParsesAsNotFound() throws {
        XCTAssertNil(BarcodeProductLookup.parseOpenFoodFactsResponse(try fixture("notFound"), barcode: "0019283746551"))
    }

    func testMalformedResponseParsesAsNotFoundRatherThanCrashing() throws {
        XCTAssertNil(BarcodeProductLookup.parseOpenFoodFactsResponse(try fixture("malformed"), barcode: "0000000000000"))
    }

    func testEmptyResponseParsesAsNotFoundRatherThanCrashing() throws {
        XCTAssertNil(BarcodeProductLookup.parseOpenFoodFactsResponse(try fixture("empty"), barcode: "0000000000000"))
        XCTAssertNil(BarcodeProductLookup.parseOpenFoodFactsResponse(Data(), barcode: "0000000000000"))
    }
}
