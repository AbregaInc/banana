import XCTest

/// `SupplementCatalogSearch`'s pure parts: the URL it asks NIH for, and what it makes of the
/// answer. Exercised against a captured live response, so a schema change shows up as a failing
/// test rather than an empty picker.
final class SupplementCatalogSearchTests: XCTestCase {

    /// Trimmed from a real `search-filter?q=Nature Made Zinc&status=1` response, captured
    /// 2026-09-15 — two hits, one of them a multivitamin whose title names none of its minerals.
    private let liveShape = """
    {"hits":[
      {"_index":"dsldnxt_labels","_type":"_doc","_id":"180249","_score":50.4,
       "_source":{"brandName":"Nature Made VitaMelts","fullName":"Zinc 15 mg Honey Lemon",
         "allIngredients":[
           {"ingredientGroup":"Zinc","notes":"Zinc (Form: as Zinc Oxide)","name":"Zinc","category":"mineral"},
           {"ingredientGroup":"Mannitol","notes":"","name":"Mannitol","category":"non-nutrient/non-botanical"},
           {"ingredientGroup":"Starch","notes":"","name":"Corn Starch","category":"complex carbohydrate"}]}},
      {"_index":"dsldnxt_labels","_type":"_doc","_id":"179985","_score":44.1,
       "_source":{"brandName":"Nature Made","fullName":"Immune Complex Adult Gummies",
         "allIngredients":[
           {"ingredientGroup":"Vitamin C","notes":"","name":"Ascorbic Acid","category":"vitamin"},
           {"ingredientGroup":"Zinc","notes":"","name":"Zinc","category":"mineral"},
           {"ingredientGroup":"Iron","notes":"","name":"Ferrous Fumarate","category":"mineral"},
           {"ingredientGroup":"Glucose Syrup","notes":"","name":"Glucose Syrup","category":"non-nutrient/non-botanical"}]}}
    ],"stats":{"count":51176}}
    """

    private func parsed() -> [SupplementCatalogEntry] {
        SupplementCatalogSearch.parseSearchResponse(Data(liveShape.utf8))
    }

    func testParsesBrandAndProductFromALiveShapedResponse() {
        let entries = parsed()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].id, "180249")
        XCTAssertEqual(entries[0].brand, "Nature Made VitaMelts")
        XCTAssertEqual(entries[0].product, "Zinc 15 mg Honey Lemon")
    }

    func testExcipientsAreDroppedAndActivesKeptInLabelOrder() {
        XCTAssertEqual(parsed()[0].ingredients, ["Zinc"], "mannitol and corn starch are not why anyone buys this")
        XCTAssertEqual(parsed()[1].ingredients, ["Vitamin C", "Zinc", "Iron"])
    }

    /// The reason this screen exists at all: picking a product teaches the app what is in the
    /// bottle, so a title that names no mineral still reaches the interaction check.
    func testAProductWhoseTitleNamesNoMineralStillYieldsItsMinerals() {
        let gummies = parsed()[1]
        XCTAssertTrue(SupplementInteractions.substances(in: gummies.product).isEmpty,
                      "the title alone gives nothing away — that is the problem being solved")
        let found = SupplementInteractions.substances(in: gummies.ingredients.joined(separator: " "))
        XCTAssertTrue(found.isSuperset(of: [.iron, .zinc, .vitaminC]))
    }

    func testSearchURLAsksForOnMarketProductsAndNeedsARealQuery() {
        let url = SupplementCatalogSearch.searchURL(for: "Nature Made Zinc", limit: 20)
        let query = url?.query ?? ""
        XCTAssertTrue(query.contains("status=1"), "on-market only")
        XCTAssertTrue(query.contains("size=20"))
        XCTAssertNil(SupplementCatalogSearch.searchURL(for: "zi"), "too short to be worth a request")
        XCTAssertNil(SupplementCatalogSearch.searchURL(for: "   "))
    }

    func testAnUnparseableResponseYieldsNoResultsRatherThanCrashing() {
        XCTAssertTrue(SupplementCatalogSearch.parseSearchResponse(Data("not json".utf8)).isEmpty)
        XCTAssertTrue(SupplementCatalogSearch.parseSearchResponse(Data(#"{"hits":[]}"#.utf8)).isEmpty)
    }

    func testIngredientSummaryNamesACountRatherThanTrailingOff() {
        let multi = SupplementCatalogEntry(id: "1", brand: "Centrum", product: "Centrum Men Under 50",
                                           ingredients: ["Vitamin A", "Vitamin C", "Vitamin D", "Vitamin E",
                                                         "Vitamin K", "Iron", "Calcium"])
        XCTAssertEqual(multi.ingredientSummary, "Vitamin A · Vitamin C · Vitamin D · Vitamin E +3 more")

        let single = SupplementCatalogEntry(id: "2", brand: "Nature Made", product: "Zinc 30 mg",
                                            ingredients: ["Zinc"])
        XCTAssertEqual(single.ingredientSummary, "Zinc")
        XCTAssertEqual(SupplementCatalogEntry(id: "3", brand: "", product: "x", ingredients: []).ingredientSummary, "")
    }
}
