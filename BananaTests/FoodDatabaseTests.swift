import SQLite3
import XCTest

/// `FoodDatabase` against the fixture databases in BananaTests/Fixtures — written by
/// `tools/build_food_database.py --fixture`, the same code that builds the bundled Foods.sqlite,
/// over a couple of dozen foods chosen as look-alikes (banana vs banana pudding, rice cooked
/// plain vs with oil, salmon vs salmon salad) plus a slice of the branded products table — and,
/// in the last few tests, against the real bundled database.
final class FoodDatabaseTests: XCTestCase {
    private var bundle: Bundle { Bundle(for: Self.self) }

    private func fixtureURLs() throws -> (foods: URL, products: URL) {
        (try XCTUnwrap(bundle.url(forResource: "FoodsFixture", withExtension: "sqlite")),
         try XCTUnwrap(bundle.url(forResource: "BarcodeProductsFixture", withExtension: "sqlite")))
    }

    private func search(_ query: String, limit: Int = 8) throws -> [FoodMatch] {
        let urls = try fixtureURLs()
        return FoodDatabase.search(query, limit: limit, databaseURL: urls.foods, productsURL: urls.products)
    }

    private func food(_ id: String) throws -> FoodMatch? {
        let urls = try fixtureURLs()
        return FoodDatabase.food(id: id, databaseURL: urls.foods, productsURL: urls.products)
    }

    private func ids(_ matches: [FoodMatch]) -> [String] { matches.map(\.reference.id) }

    // MARK: - SQLite on this platform

    /// The index is FTS5; this is the check that the OS's own SQLite (what the app links) has it.
    func testSystemSQLiteRunsFTS5Match() throws {
        XCTAssertEqual(sqlite3_compileoption_used("ENABLE_FTS5"), 1)
        let url = try fixtureURLs().foods
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, "SELECT count(*) FROM foods_fts WHERE foods_fts MATCH '\"banana\"'",
                                          -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertGreaterThanOrEqual(sqlite3_column_int(statement, 0), 5)
    }

    // MARK: - Ranking

    func testShortQueryPrefersThePlainFood() throws {
        let results = ids(try search("banana"))
        XCTAssertEqual(results.first, "fndds:2709224") // Banana, raw
        let plainSR = try XCTUnwrap(results.firstIndex(of: "sr:173944")) // Bananas, raw
        XCTAssertLessThan(plainSR, try XCTUnwrap(results.firstIndex(of: "fndds:2705697"))) // Banana pudding
        XCTAssertLessThan(plainSR, try XCTUnwrap(results.firstIndex(of: "sr:174906"))) // Bread, banana, …
    }

    func testDefaultVariantBeatsOnesWithAddedWords() throws {
        let results = ids(try search("white rice cooked"))
        XCTAssertTrue(["fndds:2708408", "fndds:2708403"].contains(results.first ?? ""), "\(results)")
        let withOil = try XCTUnwrap(results.firstIndex(of: "fndds:2708404"))
        XCTAssertLessThan(try XCTUnwrap(results.firstIndex(of: "fndds:2708408")), withOil)
        XCTAssertLessThan(try XCTUnwrap(results.firstIndex(of: "fndds:2708403")), withOil)
    }

    func testDishesFindTheDish() throws {
        XCTAssertEqual(ids(try search("chicken curry")).first, "fndds:2706437") // Chicken curry
        XCTAssertEqual(ids(try search("pad thai")).first, "fndds:2708804") // Pad Thai, NFS
        XCTAssertEqual(ids(try search("big mac")).first, "fndds:2706916") // Big Mac (McDonalds)
    }

    func testAFoodNamedAsAModifierRanksBelowTheFoodItself() throws {
        let results = ids(try search("salmon"))
        XCTAssertLessThan(try XCTUnwrap(results.firstIndex(of: "fndds:2706285")), // Fish, salmon, NFS
                          try XCTUnwrap(results.firstIndex(of: "fndds:2706826"))) // Salmon salad
    }

    func testLimitIsRespected() throws {
        XCTAssertEqual(try search("rice", limit: 2).count, 2)
        XCTAssertEqual(try search("rice", limit: 0), [])
        XCTAssertEqual(try search("   "), [])
    }

    func testNameShape() {
        let salad = FoodDatabase.nameShape("Salmon salad", queryStems: ["salmon"])
        XCTAssertTrue(salad.modifiesAnotherNoun)
        XCTAssertEqual(salad.extraWords, 1)

        let padThai = FoodDatabase.nameShape("Pad Thai with chicken", queryStems: ["pad", "thai"])
        XCTAssertFalse(padThai.modifiesAnotherNoun)
        XCTAssertEqual(padThai.extraWords, 1)

        let rice = FoodDatabase.nameShape("Rice, white, cooked, NS as to fat", queryStems: ["white", "rice", "cooked"])
        XCTAssertEqual(rice, .init(extraWords: 0, modifiesAnotherNoun: false, hasDefaultSegment: true))

        let fries = FoodDatabase.nameShape("McDONALD'S, french fries", queryStems: ["mcdonald", "fry"])
        XCTAssertEqual(fries.extraWords, 1) // "french"; the "s" of "'S" isn't a word
        XCTAssertFalse(fries.modifiesAnotherNoun)
    }

    // MARK: - Query words

    func testQueryWordsFoldAndDropFillerAndOperators() {
        XCTAssertEqual(FoodDatabase.queryWords("The Banana's, with Crème fraîche!"), ["banana", "creme", "fraiche"])
        XCTAssertEqual(FoodDatabase.queryWords("2% milk"), ["2", "milk"])
        XCTAssertEqual(FoodDatabase.queryWords("\"banana\" OR NEAR(pad* -thai) {name}:x ^y"),
                       ["banana", "near", "pad", "thai", "name"])
        XCTAssertEqual(FoodDatabase.queryWords("\" * - ( ) :"), [])
    }

    func testFTSSyntaxInQueriesIsHarmless() throws {
        for query in ["banana\" OR \"pad", "NEAR(banana", "banana*", "banana AND NOT", "^banana:", "{name}: banana"] {
            XCTAssertTrue(ids(try search(query)).contains("fndds:2709224"), query)
        }
        for query in ["\"", "-", "*", "()", "AND"] {
            XCTAssertNoThrow(try search(query), query)
        }
    }

    func testStem() {
        XCTAssertEqual(FoodDatabase.stem("fries"), "fry")
        XCTAssertEqual(FoodDatabase.stem("tomatoes"), "tomato")
        XCTAssertEqual(FoodDatabase.stem("peaches"), "peach")
        XCTAssertEqual(FoodDatabase.stem("eggs"), "egg")
        XCTAssertEqual(FoodDatabase.stem("hummus"), "hummu")
        XCTAssertEqual(FoodDatabase.stem("glass"), "glass")
        XCTAssertEqual(FoodDatabase.stem("gas"), "gas")
    }

    // MARK: - Branded products

    func testPlainFoodQueryGetsNoBrandedResults() throws {
        XCTAssertFalse(ids(try search("banana")).contains { $0.hasPrefix("branded:") })
        XCTAssertFalse(ids(try search("chicken curry")).contains { $0.hasPrefix("branded:") })
    }

    func testBrandQueryAddsBrandedProductsAfterGenericFoods() throws {
        let results = try search("chobani vanilla")
        let resultIDs = ids(results)
        XCTAssertEqual(resultIDs.first, "sr:171296") // Yogurt, Greek, nonfat, vanilla, CHOBANI
        let firstBranded = try XCTUnwrap(resultIDs.firstIndex { $0.hasPrefix("branded:") })
        XCTAssertTrue(resultIDs[firstBranded...].allSatisfy { $0.hasPrefix("branded:") }, "\(resultIDs)")
        XCTAssertLessThanOrEqual(resultIDs.count - firstBranded, FoodDatabase.maxBrandedResults)

        let yogurt = try XCTUnwrap(results.first { $0.reference.id == "branded:0818290012791" })
        XCTAssertEqual(yogurt.reference.per100g.calories, 110 / 1.5, accuracy: 0.01) // 110 kcal in 150 g
        XCTAssertEqual(yogurt.reference.per100g.proteinGrams, 8, accuracy: 0.01)
        XCTAssertEqual(yogurt.portions, [FoodPortion(label: "1 container", grams: 150)])
        XCTAssertEqual(yogurt.category, "Branded product")
        XCTAssertTrue(yogurt.reference.name.localizedCaseInsensitiveContains("chobani"), yogurt.reference.name)
    }

    func testZeroCalorieDrinkKeepsItsRealZero() throws {
        let coke = try XCTUnwrap(try search("diet coke").first { $0.reference.id == "branded:00049000006582" })
        XCTAssertEqual(coke.reference.per100g.calories, 0)
        XCTAssertEqual(coke.portions, [FoodPortion(label: "1 can", grams: 355)])
    }

    func testBrandedSearchLoosensOnlyLongQueriesAndNeverDropsTheProduct() throws {
        // Three words, no product has all three: dropping the ordinary food word "banana" (common
        // among the fixture's generic foods) still finds the RXBARs.
        XCTAssertTrue(ids(try search("rxbar banana protein")).contains("branded:193908002813"))
        // Two words are never loosened — "rxbar chocolate" isn't the orange bar.
        XCTAssertFalse(ids(try search("rxbar chocolate")).contains { $0.hasPrefix("branded:") })
        // "rxbar" is never the word dropped: Chobani's vanilla Greek yogurt isn't an RXBAR.
        XCTAssertFalse(ids(try search("rxbar vanilla greek yogurt")).contains { $0.hasPrefix("branded:") })
    }

    func testProductsTheBuildLeavesOutAreNotFoodsEither() throws {
        XCTAssertNil(try food("branded:0019622043487")) // serving "1/4 tsp": no weight
        XCTAssertNil(try food("branded:00013562474066")) // all zeros, not a zero-calorie product
        XCTAssertNil(try food("branded:0000000000000")) // not in the table
    }

    func testBarcodeFromRowidKeepsLeadingZeros() {
        let rowid = (Int64(51) << 51) | (Int64(818_290_012_791) * 16 + 13)
        XCTAssertEqual(FoodDatabase.barcode(fromRowid: rowid), "0818290012791")
        XCTAssertEqual(FoodDatabase.barcode(fromRowid: Int64(6_582) * 16 + 14), "00000000006582")
    }

    func testServingGrams() {
        XCTAssertEqual(FoodDatabase.servingGrams("1 bar (52 g)"), 52)
        XCTAssertEqual(FoodDatabase.servingGrams("2 cups (28g) (28 GRM)"), 28)
        XCTAssertEqual(FoodDatabase.servingGrams("1 Bottle (207mL) (207 MLT)"), 207)
        XCTAssertEqual(FoodDatabase.servingGrams("150 g"), 150)
        XCTAssertEqual(FoodDatabase.servingGrams("1 ONZ"), 28.35)
        XCTAssertEqual(try XCTUnwrap(FoodDatabase.servingGrams("1.5 oz")), 42.525, accuracy: 0.0001)
        XCTAssertNil(FoodDatabase.servingGrams("8 fl oz"))
        XCTAssertNil(FoodDatabase.servingGrams("1/4 tsp"))
        XCTAssertNil(FoodDatabase.servingGrams("28 MG"))
    }

    func testServingLabel() {
        XCTAssertEqual(FoodDatabase.servingLabel("1 Container (128g) (128 GRM)"), "1 container")
        XCTAssertEqual(FoodDatabase.servingLabel("1 ONZ (28 g)"), "1 oz")
        XCTAssertEqual(FoodDatabase.servingLabel("8 OZA (240 ml)"), "8 fl oz")
        XCTAssertEqual(FoodDatabase.servingLabel("1 cup with 1/2 cup skim milk (160 g)"), "1 cup with 1/2 cup skim milk")
        XCTAssertEqual(FoodDatabase.servingLabel("150 g"), "1 serving")
        XCTAssertEqual(FoodDatabase.servingLabel("52 GRM"), "1 serving")
        XCTAssertEqual(FoodDatabase.servingLabel("None (28 g)"), "1 serving")
        XCTAssertEqual(FoodDatabase.servingLabel("28 (28 GRM)"), "1 serving")
    }

    // MARK: - food(id:)

    func testFoodByID() throws {
        let banana = try XCTUnwrap(try food("fndds:2709224"))
        XCTAssertEqual(banana.reference.name, "Banana, raw")
        XCTAssertEqual(banana.reference.per100g.calories, 97, accuracy: 0.5)
        XCTAssertEqual(banana.category, "Bananas")
        XCTAssertEqual(banana.portions.first, FoodPortion(label: "1 banana", grams: 126))
        XCTAssertEqual(banana.portions.last, FoodPortion(label: "typical portion", grams: 126))

        let bar = try XCTUnwrap(try food("branded:602652170065"))
        XCTAssertEqual(bar.reference.per100g.calories, 525, accuracy: 0.01) // 210 kcal in 40 g
        XCTAssertEqual(bar.portions, [FoodPortion(label: "1 bar", grams: 40)])

        XCTAssertNil(try food("fndds:1"))
        XCTAssertNil(try food("nonsense"))
    }

    func testSRPortionsReadAsMeasures() throws {
        let banana = try XCTUnwrap(try food("sr:173944"))
        XCTAssertEqual(banana.portions.first, FoodPortion(label: "1 cup, mashed", grams: 225))
        XCTAssertTrue(banana.portions.contains(FoodPortion(label: "1 medium (7\" to 7-7/8\" long)", grams: 118)))
    }

    func testFoundationSupersedesOlderEntriesOfTheSameName() throws {
        XCTAssertNotNil(try food("foundation:747447")) // Broccoli, raw — the newer analysis
        XCTAssertNil(try food("foundation:321900")) // the older Foundation entry
        XCTAssertNil(try food("sr:170379")) // SR Legacy's "Broccoli, raw"
    }

    func testSearchResultsMatchFoodByID() throws {
        for match in try search("chobani vanilla") {
            XCTAssertEqual(try food(match.reference.id), match)
        }
    }

    // MARK: - Tool text

    func testToolTextFormat() {
        let rice = FoodMatch(
            reference: FoodReference(id: "fndds:1", name: "Rice | white",
                                     per100g: NutritionMacros(calories: 130.4, proteinGrams: 2.69,
                                                              carbohydrateGrams: 28.2, fatGrams: 0.28)),
            category: "Rice",
            portions: [FoodPortion(label: "1 cup", grams: 158), FoodPortion(label: "1 oz", grams: 28.35)]
                + (1...6).map { FoodPortion(label: "\($0) spoon", grams: 4.24 * Double($0)) })
        let plain = FoodMatch(
            reference: FoodReference(id: "sr:2", name: "Salt, table", per100g: NutritionMacros()),
            category: "Spices", portions: [])
        XCTAssertEqual(FoodDatabase.toolText([rice, plain]), """
            fndds:1 | Rice / white | per 100 g: 130 kcal, P 2.7 g, C 28 g, F 0.3 g | 1 cup = 158 g; 1 oz = 28 g; \
            1 spoon = 4.2 g; 2 spoon = 8.5 g; 3 spoon = 13 g; 4 spoon = 17 g
            sr:2 | Salt, table | per 100 g: 0 kcal, P 0 g, C 0 g, F 0 g
            """)
        XCTAssertEqual(FoodDatabase.toolText([]), "No matching foods.")
    }

    // MARK: - Threads

    func testConcurrentSearchesAgree() throws {
        let urls = try fixtureURLs()
        let expected = FoodDatabase.search("chobani vanilla", databaseURL: urls.foods, productsURL: urls.products)
        let lock = NSLock()
        var results: [[FoodMatch]] = []
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            let result = FoodDatabase.search("chobani vanilla", databaseURL: urls.foods, productsURL: urls.products)
            lock.lock(); results.append(result); lock.unlock()
        }
        XCTAssertEqual(results.count, 16)
        XCTAssertTrue(results.allSatisfy { $0 == expected })
    }

    // MARK: - The bundled database

    private func bundledURLs() throws -> (foods: URL, products: URL) {
        (try XCTUnwrap(bundle.url(forResource: "Foods", withExtension: "sqlite")),
         try XCTUnwrap(bundle.url(forResource: "BarcodeProducts", withExtension: "sqlite")))
    }

    private func bundledSearch(_ query: String) throws -> [FoodMatch] {
        let urls = try bundledURLs()
        return FoodDatabase.search(query, databaseURL: urls.foods, productsURL: urls.products)
    }

    func testBundledDatabaseFirstHitsAreSensible() throws {
        let cases: [(query: String, name: String, kcal: ClosedRange<Double>)] = [
            ("banana", "Banana, raw", 80...110),
            ("chicken curry", "Chicken curry", 80...200),
            ("white rice cooked", "Rice, white, cooked", 110...150),
            ("pad thai", "Pad Thai", 120...200),
            ("big mac", "Big Mac", 220...300),
            ("oatmeal", "Oatmeal", 50...120),
            ("egg", "Egg, whole", 130...160),
            ("peanut butter", "Peanut butter", 550...650),
        ]
        for (query, name, kcal) in cases {
            let first = try XCTUnwrap(try bundledSearch(query).first, query)
            XCTAssertTrue(first.reference.name.hasPrefix(name), "\(query) → \(first.reference.name)")
            XCTAssertTrue(kcal.contains(first.reference.per100g.calories), "\(query) → \(first.reference.per100g.calories)")
            XCTAssertFalse(first.portions.isEmpty, query)
        }
    }

    func testBundledDatabaseFindsBrandedProducts() throws {
        let chobani = try bundledSearch("chobani vanilla").filter { $0.reference.id.hasPrefix("branded:") }
        XCTAssertFalse(chobani.isEmpty)
        for product in chobani {
            XCTAssertTrue(product.reference.name.localizedCaseInsensitiveContains("chobani"), product.reference.name)
            XCTAssertTrue((40...200).contains(product.reference.per100g.calories), "\(product.reference)")
            XCTAssertEqual(product.portions.count, 1)
        }

        let tikka = try bundledSearch("chicken tikka masala").filter { $0.reference.id.hasPrefix("branded:") }
        XCTAssertTrue(tikka.contains { $0.reference.name.localizedCaseInsensitiveContains("tikka masala") })
    }

    func testBundledToolTextReadsAsDocumented() throws {
        let line = try XCTUnwrap(FoodDatabase.toolText(try bundledSearch("banana")).split(separator: "\n").first)
        XCTAssertTrue(line.hasPrefix("fndds:2709224 | Banana, raw | per 100 g: 97 kcal, P 0.7 g, C 23 g, F 0.3 g | "), String(line))
        XCTAssertTrue(line.contains("1 banana = 126 g"), String(line))
    }

    /// The look-ups the 1 Oct 2026 review found wrong, through the real database: what's chosen
    /// for the model's sketch of each food (`GroundedFoodEstimate.parts(fromSketches:)`).
    func testBundledLookupsTheReviewFoundWrong() throws {
        let urls = try bundledURLs()
        func chosen(_ name: String, grams: Double, kcal: Double) -> FoodMatch? {
            let part = GroundedFoodEstimate.parts(
                fromSketches: [.init(name: name, grams: grams, portion: "", ownEstimate: .init(calories: kcal))],
                search: { FoodDatabase.search($0, databaseURL: urls.foods, productsURL: urls.products) })[0]
            return part.foodID.isEmpty ? nil
                : FoodDatabase.food(id: part.foodID, databaseURL: urls.foods, productsURL: urls.products)
        }
        let sauce = try XCTUnwrap(chosen("1/2 can of tomato sauce", grams: 120, kcal: 40))
        XCTAssertLessThan(sauce.reference.per100g.calories, 40, sauce.reference.name)
        let broth = try XCTUnwrap(chosen("chicken broth", grams: 120, kcal: 10))
        XCTAssertLessThan(broth.reference.per100g.calories, 40, broth.reference.name)
        if let bone = chosen("beef bone broth", grams: 240, kcal: 20) {
            XCTAssertLessThan(bone.reference.per100g.calories, 60, bone.reference.name)
        }
        XCTAssertNil(chosen("orzo", grams: 150, kcal: 200), "only dry orzo is listed: the model's own beats it")
        let vinegar = try XCTUnwrap(chosen("apple cider vinegar", grams: 15, kcal: 3))
        XCTAssertTrue(vinegar.reference.name.localizedCaseInsensitiveContains("vinegar"), vinegar.reference.name)
        let oil = try XCTUnwrap(chosen("1/2 spoon of olive oil", grams: 7, kcal: 60))
        XCTAssertTrue(oil.reference.name.localizedCaseInsensitiveContains("olive oil"), oil.reference.name)
    }

    func testBundledDatabaseRanksPlainTomatoSauceFirst() throws {
        let first = try XCTUnwrap(try bundledSearch("tomato sauce").first)
        XCTAssertLessThan(first.reference.per100g.calories, 40, first.reference.name)
    }

    func testBundledDatabaseSearchIsFast() throws {
        let urls = try bundledURLs()
        measure {
            for query in ["banana", "chicken curry", "chobani vanilla", "grilled chicken breast with rice"] {
                _ = FoodDatabase.search(query, databaseURL: urls.foods, productsURL: urls.products)
            }
        }
    }
}
