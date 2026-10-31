import XCTest

/// `ProductRecordCleaner.deterministicClean` against real bad records from the coverage
/// measurement (see docs referenced in `BarcodeProductLookup.swift`'s header comment) — the
/// model-backed path isn't exercised here since Apple Intelligence isn't guaranteed available in
/// a test environment; the deterministic fallback is a complete implementation of the same three
/// rules on its own, so it's the one covered directly.
final class ProductRecordCleanerTests: XCTestCase {
    func testAllCapsNameIsTitleCasedWithNoRedundantBrandOrPackSize() {
        // Real Open Food Facts record for Optimum Nutrition Opti-Men.
        let cleaned = ProductRecordCleaner.deterministicClean(name: "OPTI-MEN", brand: "Optimum Nutrition", serving: "3 Tablets")

        XCTAssertEqual(cleaned.name, "Opti-Men")
        XCTAssertEqual(cleaned.brand, "Optimum Nutrition")
        XCTAssertFalse(cleaned.usedModel)
    }

    func testRepeatedBrandAndPackCountAreStrippedButDoseIsKept() {
        // Real UPCitemdb record for Nature Made Vitamin D3 2000 IU.
        let raw = "Nature Made Vitamin D3 2000 IU (50 mcg), Bone Health and Immune Support Softgels, USP Verified - 250ct"
        let cleaned = ProductRecordCleaner.deterministicClean(name: raw, brand: "Nature Made", serving: "")

        XCTAssertFalse(cleaned.name.localizedCaseInsensitiveContains("Nature Made"),
                       "the brand is shown separately; it should not also open the name")
        XCTAssertFalse(cleaned.name.contains("250ct"), "pack count must be stripped")
        XCTAssertTrue(cleaned.name.contains("2000 IU"), "a dose amount is not a pack size and must survive")
        XCTAssertTrue(cleaned.name.contains("50 mcg"), "a dose amount is not a pack size and must survive")
    }

    func testGenuinelyGenericNameIsLeftAlone() {
        // Real Open Food Facts record — short and generic is not a defect to "fix" by inventing
        // detail that was never in the source data.
        let cleaned = ProductRecordCleaner.deterministicClean(name: "Fish oil", brand: "Nature Made", serving: "2 softgels")
        XCTAssertEqual(cleaned.name, "Fish oil")
    }

    func testAllCapsBrandOnlyFieldIsFixedTooNotJustTheName() {
        let cleaned = ProductRecordCleaner.deterministicClean(name: "Zinc Picolinate 50 mg", brand: "NOW", serving: "1 capsule")
        // Short brand names are common and shouldn't be mangled — "NOW" stays as the brand text
        // Open Food Facts/DSLD actually use; localizedCapitalized on a 3-letter word gives "Now".
        XCTAssertEqual(cleaned.brand, "Now")
    }

    func testEmptyBrandLeavesNameUntouchedByBrandStripping() {
        let cleaned = ProductRecordCleaner.deterministicClean(name: "Melatonin 5 mg", brand: "", serving: "1 Tablet")
        XCTAssertEqual(cleaned.name, "Melatonin 5 mg")
        XCTAssertEqual(cleaned.brand, "")
    }

    func testNameThatIsOnlyTheBrandIsNotReducedToEmpty() {
        // A source that only ever wrote the brand name as the "product name" shouldn't vanish —
        // better to keep showing something than silently produce a blank required field.
        let cleaned = ProductRecordCleaner.deterministicClean(name: "Solgar", brand: "Solgar", serving: "")
        XCTAssertFalse(cleaned.name.isEmpty)
    }

    func testMultipleUnitCountsAreStrippedFromAVerboseUPCitemdbTitle() {
        // Real UPCitemdb record for Optimum Nutrition Opti-Men.
        let raw = "Optimum Nutrition Opti-Men Multivitamin (150ct)"
        let cleaned = ProductRecordCleaner.deterministicClean(name: raw, brand: "Optimum Nutrition", serving: "")
        XCTAssertFalse(cleaned.name.contains("150ct"))
        XCTAssertFalse(cleaned.name.localizedCaseInsensitiveContains("Optimum Nutrition"))
        XCTAssertTrue(cleaned.name.contains("Opti-Men"))
    }

    func testServingIsTrimmedButOtherwiseUntouched() {
        let cleaned = ProductRecordCleaner.deterministicClean(name: "Magnesium Citrate 200 mg", brand: "NOW", serving: "  1 serving (2 g)  ")
        XCTAssertEqual(cleaned.serving, "1 serving (2 g)")
    }
}
