import XCTest

/// Exercises the NIH DSLD (Dietary Supplement Label Database) barcode path: the exact quoted
/// "1-5-5-1" regrouping the search API requires, and the `upcSku`-based confirmation that keeps a
/// coincidental search-rank match from being accepted as a real one. Label-response fixtures are
/// real, captured payloads (see `DSLDFixtures.json`) — no network access here.
final class BarcodeDSLDTests: XCTestCase {

    // MARK: - Regrouping / quoting

    func testUPCA12DigitBarcodeRegroupsToDocumentedForm() {
        // The exact example from DSLD's own API guide.
        XCTAssertEqual(BarcodeProductLookup.dsldSearchQuery(forBarcode: "031604026783"), "\"0 31604 02678 3\"")
    }

    func testZeroPaddedEAN13BarcodeStripsToUPCA12BeforeRegrouping() {
        // The same product, scanned as a 13-digit EAN (the common shape a US barcode scan
        // actually returns) — must strip the padding zero, not the check digit.
        XCTAssertEqual(BarcodeProductLookup.dsldSearchQuery(forBarcode: "0031604026783"), "\"0 31604 02678 3\"")
    }

    func testAnotherRealBarcodeRegroupsCorrectly() {
        // NOW Foods Vitamin D-3, from the coverage measurement's real 42-barcode test set.
        XCTAssertEqual(BarcodeProductLookup.dsldSearchQuery(forBarcode: "0733739003737"), "\"7 33739 00373 7\"")
        XCTAssertEqual(BarcodeProductLookup.dsldSearchQuery(forBarcode: "733739003737"), "\"7 33739 00373 7\"")
    }

    func testGenuineEAN13NotStartingWithZeroIsNotAttempted() {
        // A German product's real EAN-13 (Abtei Magnesium, from the same test set) — never
        // matched under any grouping in the measurement, so DSLD is simply skipped for it rather
        // than guessing an unvalidated grouping.
        XCTAssertNil(BarcodeProductLookup.dsldSearchQuery(forBarcode: "4250752201910"))
    }

    func testNonNumericOrWrongLengthBarcodeIsNotAttempted() {
        XCTAssertNil(BarcodeProductLookup.dsldSearchQuery(forBarcode: "12345678")) // 8-digit UPC-E
        XCTAssertNil(BarcodeProductLookup.dsldSearchQuery(forBarcode: "12ab34567890"))
    }

    func testSearchURLQuotesAndPercentEncodesTheGroupedQuery() throws {
        let url = try XCTUnwrap(BarcodeProductLookup.dsldSearchURL(forBarcode: "031604026783"))
        XCTAssertEqual(url.absoluteString, "https://api.ods.od.nih.gov/dsld/v9/search-filter?q=%220%2031604%2002678%203%22&status=2")
    }

    // MARK: - upcSku confirmation (never trust search rank alone)

    func testMatchingUpcSkuAccepted() {
        XCTAssertTrue(BarcodeProductLookup.matchesDSLDUpcSku("0 31604 01277 9", barcode: "031604012779"))
        XCTAssertTrue(BarcodeProductLookup.matchesDSLDUpcSku("0 31604 01277 9", barcode: "0031604012779"))
    }

    func testMismatchedUpcSkuRejected() {
        // A search hit that ranked first by text relevance but is a different product's label —
        // exactly the scenario the assessment calls out: reject on a mismatch, don't trust rank.
        XCTAssertFalse(BarcodeProductLookup.matchesDSLDUpcSku("0 31604 01277 9", barcode: "999999999999"))
    }

    func testEmptyOrUnparseableUpcSkuRejected() {
        XCTAssertFalse(BarcodeProductLookup.matchesDSLDUpcSku("", barcode: "031604012779"))
        XCTAssertFalse(BarcodeProductLookup.matchesDSLDUpcSku("not a upc", barcode: "031604012779"))
    }

    // MARK: - Label response parsing (real fixtures)

    private func fixture(_ key: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "DSLDFixtures", withExtension: "json"))
        let all = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        return Data(try XCTUnwrap(all[key]).utf8)
    }

    func testMatchingLabelResponseParsesWithCleanFields() throws {
        // Real DSLD label for Nature Made Zinc 30 mg, barcode 031604012779 (upcSku "0 31604 01277 9").
        let fields = try XCTUnwrap(
            BarcodeProductLookup.parseDSLDLabelResponse(try fixture("natureMadeZinc"), barcode: "031604012779"))

        XCTAssertEqual(fields.source, .dsld)
        XCTAssertEqual(fields.name, "Zinc 30 mg")
        XCTAssertEqual(fields.brand, "Nature Made")
        XCTAssertEqual(fields.serving, "1 Tablet(s)")
        XCTAssertNil(fields.macros, "DSLD never carries a Nutrition Facts panel")
    }

    func testMatchingLabelResponseAlsoParsesForTheZeroPaddedBarcodeForm() throws {
        let fields = try XCTUnwrap(
            BarcodeProductLookup.parseDSLDLabelResponse(try fixture("natureMadeZinc"), barcode: "0031604012779"))
        XCTAssertEqual(fields.name, "Zinc 30 mg")
    }

    func testLabelResponseRejectedWhenBarcodeDoesNotMatchUpcSku() throws {
        // Same real, well-formed label payload — but looked up against a barcode that isn't
        // actually this product. Must be rejected rather than accepted because it was the top
        // (only) search hit.
        XCTAssertNil(BarcodeProductLookup.parseDSLDLabelResponse(try fixture("natureMadeZinc"), barcode: "111111111111"))
    }

    func testSecondRealLabelResponseParsesWithMultiPartServing() throws {
        // Real DSLD label for NOW B-12 1,000 mcg, barcode 733739004680.
        let fields = try XCTUnwrap(
            BarcodeProductLookup.parseDSLDLabelResponse(try fixture("nowB12"), barcode: "733739004680"))
        XCTAssertEqual(fields.name, "B-12 1,000 mcg")
        XCTAssertEqual(fields.brand, "NOW")
    }

    func testMalformedLabelResponseParsesAsNilRatherThanCrashing() {
        XCTAssertNil(BarcodeProductLookup.parseDSLDLabelResponse(Data("not json".utf8), barcode: "031604012779"))
        XCTAssertNil(BarcodeProductLookup.parseDSLDLabelResponse(Data(), barcode: "031604012779"))
    }

    // MARK: - Ingredient panel

    func testIngredientPanelIsParsedFromARealLabel() throws {
        let fields = BarcodeProductLookup.parseDSLDLabelResponse(try fixture("natureMadeZinc"),
                                                                barcode: "031604012779")
        XCTAssertEqual(fields?.ingredients, ["Zinc"])
    }

    /// NIH's `ingredientGroup` normalises every salt to one name, which is the vocabulary
    /// `SupplementInteractions` already matches. The label's own wording is only the fallback.
    func testNormalisedGroupNameBeatsTheLabelsOwnWording() {
        let rows = [
            BarcodeProductLookup.DSLDLabelResponse.IngredientRow(
                name: "Ferrous Fumarate", ingredientGroup: "Iron", category: "mineral", nestedRows: nil),
            BarcodeProductLookup.DSLDLabelResponse.IngredientRow(
                name: "Proprietary Herb Blend", ingredientGroup: nil, category: "blend", nestedRows: nil),
        ]
        XCTAssertEqual(BarcodeProductLookup.dsldIngredients(rows), ["Iron", "Proprietary Herb Blend"])
    }

    /// The minerals in a multivitamin live inside a blend row. Not walking into it is the
    /// difference between seeing "Mineral Blend" and seeing the iron that clashes with calcium.
    func testBlendRowsAreWalkedSoAMultivitaminsMineralsAreVisible() {
        let rows = [
            BarcodeProductLookup.DSLDLabelResponse.IngredientRow(
                name: "Mineral Blend", ingredientGroup: nil, category: "blend",
                nestedRows: [
                    .init(name: "Ferrous Fumarate", ingredientGroup: "Iron", category: "mineral", nestedRows: nil),
                    .init(name: "Calcium Carbonate", ingredientGroup: "Calcium", category: "mineral", nestedRows: nil),
                ]),
        ]
        let ingredients = BarcodeProductLookup.dsldIngredients(rows)
        XCTAssertEqual(ingredients, ["Mineral Blend", "Iron", "Calcium"])
        // The whole point: this bottle is now visible to the interaction check.
        let found = SupplementInteractions.substances(in: ingredients.joined(separator: " "))
        XCTAssertTrue(found.isSuperset(of: [.iron, .calcium]))
    }

    func testALabelWithNoIngredientPanelYieldsNoIngredientsRatherThanFailing() {
        XCTAssertEqual(BarcodeProductLookup.dsldIngredients(nil), [])
    }
}
