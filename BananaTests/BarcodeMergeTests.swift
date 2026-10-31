import XCTest

/// `BarcodeProductLookup.mergeFields(_:)` — requirement 2 of the barcode-scanner fix: take the
/// best non-empty value per field across whichever sources answered, instead of the first source
/// that found anything winning outright, and record which source each field came from.
final class BarcodeMergeTests: XCTestCase {
    private typealias RawFields = BarcodeProductLookup.RawProductFields

    func testSingleSourceUsesItsOwnFieldsThroughout() throws {
        let off = RawFields(source: .openFoodFacts, name: "Fish Oil", brand: "Nature Made", serving: "2 softgels", macros: nil)
        let merged = try XCTUnwrap(BarcodeProductLookup.mergeFields([off]))

        XCTAssertEqual(merged.name, "Fish Oil")
        XCTAssertEqual(merged.nameSource, .openFoodFacts)
        XCTAssertEqual(merged.serving, "2 softgels")
        XCTAssertEqual(merged.servingSource, .openFoodFacts)
    }

    func testDSLDNameWinsOverOpenFoodFactsWhenBothPresent() throws {
        // DSLD's curated fullName ("Opti-Men") is preferred over Open Food Facts' bare,
        // ALL-CAPS product_name for the same product — this is the "later source has the better
        // name" half of the measurement's example.
        let off = RawFields(source: .openFoodFacts, name: "OPTI-MEN", brand: "Optimum Nutrition", serving: nil, macros: nil)
        let dsld = RawFields(source: .dsld, name: "Opti-Men", brand: "ON Optimum Nutrition", serving: "3 Tablet(s)", macros: nil)
        let merged = try XCTUnwrap(BarcodeProductLookup.mergeFields([off, dsld]))

        XCTAssertEqual(merged.name, "Opti-Men")
        XCTAssertEqual(merged.nameSource, .dsld)
    }

    func testOpenFoodFactsServingWinsOverDSLDWhenBothPresent() throws {
        // Open Food Facts' `serving_size` ("1 scoop (35 g)") is preferred over DSLD's serving —
        // the "earlier source had the serving size" half of the measurement's example.
        let off = RawFields(source: .openFoodFacts, name: "", brand: "", serving: "1 scoop (35 g)", macros: nil)
        let dsld = RawFields(source: .dsld, name: "Micronized Creatine Powder", brand: "Optimum Nutrition", serving: "5.25 Gram(s)", macros: nil)
        let merged = try XCTUnwrap(BarcodeProductLookup.mergeFields([off, dsld]))

        XCTAssertEqual(merged.serving, "1 scoop (35 g)")
        XCTAssertEqual(merged.servingSource, .openFoodFacts)
        // Name still comes from DSLD since Open Food Facts left it blank here.
        XCTAssertEqual(merged.name, "Micronized Creatine Powder")
        XCTAssertEqual(merged.nameSource, .dsld)
    }

    func testDSLDFillsAGapOpenFoodFactsLeftBlank() throws {
        let off = RawFields(source: .openFoodFacts, name: "", brand: "", serving: nil, macros: nil)
        let dsld = RawFields(source: .dsld, name: "Zinc 30 mg", brand: "Nature Made", serving: "1 Tablet(s)", macros: nil)
        let merged = try XCTUnwrap(BarcodeProductLookup.mergeFields([off, dsld]))

        XCTAssertEqual(merged.name, "Zinc 30 mg")
        XCTAssertEqual(merged.brand, "Nature Made")
        XCTAssertEqual(merged.serving, "1 Tablet(s)")
    }

    func testMacrosOnlyEverComeFromOpenFoodFacts() throws {
        let macros = NutritionMacros(calories: 393, proteinGrams: 77, carbohydrateGrams: 8, fatGrams: 6.7)
        // Open Food Facts gives it per 100 g, and that's how it's carried: scaling to the serving
        // happens once, when the product is finished.
        let off = RawFields(source: .openFoodFacts, name: "Whey Protein", brand: "XXL Nutrition", serving: "30 gram",
                            macros: nil, per100g: macros, packageGrams: 600)
        let dsld = RawFields(source: .dsld, name: "Whey Protein Concentrate", brand: "XXL Nutrition", serving: nil, macros: nil)
        let merged = try XCTUnwrap(BarcodeProductLookup.mergeFields([off, dsld]))

        XCTAssertEqual(merged.per100g, macros)
        XCTAssertNil(merged.macros)
        XCTAssertEqual(merged.packageGrams, 600)
        XCTAssertTrue(merged.servingStated)
        let worked = BarcodeProductLookup.servingAndMacros(per100g: macros, serving: merged.serving, servingGrams: nil)
        XCTAssertEqual(worked.macros.calories, 117.9, accuracy: 0.01)

        // No source says a serving: the default text isn't one.
        let bare = RawFields(source: .openFoodFacts, name: "Nori", brand: "", serving: nil, macros: nil,
                             per100g: macros, packageGrams: 72)
        XCTAssertEqual(try XCTUnwrap(BarcodeProductLookup.mergeFields([bare])).servingStated, false)
    }

    func testEmptySourceListMergesToNil() {
        XCTAssertNil(BarcodeProductLookup.mergeFields([]))
    }

    func testAllSourcesEmptyNameMergesToNil() {
        // Every source found *something* for this barcode, but none had any actual name text —
        // must not synthesize a record with an empty name.
        let off = RawFields(source: .openFoodFacts, name: "", brand: "", serving: "1 serving", macros: nil)
        XCTAssertNil(BarcodeProductLookup.mergeFields([off]))
    }

    func testServingDefaultsWhenNoSourceHasOne() throws {
        let off = RawFields(source: .openFoodFacts, name: "Ashwagandha Extract", brand: "NOW", serving: nil, macros: nil)
        let merged = try XCTUnwrap(BarcodeProductLookup.mergeFields([off]))
        XCTAssertEqual(merged.serving, "1 serving")
    }
}
