import XCTest

/// Searching foods by name (`FoodSearch`): the words, the brand a search names, amounts and how
/// they read, Open Food Facts' answers, and what of yours a search finds.
final class FoodSearchTests: XCTestCase {
    private let carrots = FoodMatch(
        reference: FoodReference(id: "fndds:2709660", name: "Carrots, raw",
                                 per100g: NutritionMacros(calories: 41, proteinGrams: 0.9, carbohydrateGrams: 9.6, fatGrams: 0.2)),
        category: "Vegetables",
        portions: [FoodPortion(label: "1 cup", grams: 120), FoodPortion(label: "1 baby carrot", grams: 10)])

    private var index: FoodSearch.BrandIndex {
        FoodSearch.BrandIndex(brands: [("TRADER JOE'S", 73), ("Whole Foods Market, Inc.", 3120),
                                       ("Chobani, LLC", 40), ("Baby Carrot Farms", 5)],
                              brandWords: ["chobani"])
    }

    // MARK: - Words and brands

    func testWordsFoldApostrophesPluralsAndFiller() {
        XCTAssertEqual(FoodSearch.words("Trader Joe's Cut & Peeled Carrots"), ["trader", "joe", "cut", "peeled", "carrot"])
        XCTAssertEqual(FoodSearch.words("Mini scallops", singular: false), ["mini", "scallops"])
        XCTAssertEqual(FoodSearch.words("2 cups of berries"), ["cup", "berry"])
    }

    func testBrandsAreLabelledAsOnThePackage() {
        XCTAssertEqual(FoodSearch.label(brand: "TRADER JOE'S"), "Trader Joe's")
        XCTAssertEqual(FoodSearch.label(brand: "Whole Foods Market, Inc."), "Whole Foods Market")
        XCTAssertEqual(FoodSearch.label(brand: "The Kroger Co."), "Kroger")
    }

    func testABrandAtTheStartOrEndLeavesTheFood() throws {
        let start = try XCTUnwrap(FoodSearch.brand(in: "trader joes cut and peeled carrots", index: index))
        XCTAssertEqual(start.brand.name, "Trader Joe's")
        XCTAssertEqual(start.food, ["cut", "peeled", "carrot"])

        let end = try XCTUnwrap(FoodSearch.brand(in: "carrots from Trader Joe's", index: index))
        XCTAssertEqual(end.brand.name, "Trader Joe's")
        XCTAssertEqual(end.food, ["carrot"])

        XCTAssertEqual(FoodSearch.brand(in: "tj mini scallops", index: index)?.brand.name, "Trader Joe's")
        // As much of the brand as was said: what Open Food Facts is asked for.
        XCTAssertEqual(FoodSearch.brand(in: "whole foods hummus", index: index)?.brand.name, "Whole Foods")
        XCTAssertEqual(FoodSearch.brand(in: "chobani greek yogurt", index: index)?.brand.name, "Chobani")
    }

    func testABrandIsNeverTheWholeSearchNorAFoodsName() {
        XCTAssertNil(FoodSearch.brand(in: "trader joes", index: index))
        // "Baby Carrot Farms" exists, but "baby carrots" names a food.
        XCTAssertNil(FoodSearch.brand(in: "baby carrots raw", index: index) { $0 == "baby carrot" })
        // A one-word brand counts only when the word is only ever a brand.
        XCTAssertNil(FoodSearch.brand(in: "whole carrots", index: index))
    }

    func testTheRealBrandsKnowTraderJoesAndNotBabyCarrots() throws {
        let bundle = Bundle(for: Self.self)
        let foodsURL = try XCTUnwrap(bundle.url(forResource: "Foods", withExtension: "sqlite"))
        let productsURL = try XCTUnwrap(bundle.url(forResource: "BarcodeProducts", withExtension: "sqlite"))
        let index = FoodSearch.BrandIndex(brands: FoodDatabase.brands(productsURL: productsURL),
                                          brandWords: FoodDatabase.brandWords(databaseURL: foodsURL))
        let isFood = { (phrase: String) in
            FoodSearch.names(phrase, among: FoodDatabase.search(phrase, limit: 5, databaseURL: foodsURL, productsURL: nil))
        }
        let found = try XCTUnwrap(FoodSearch.brand(in: "trader joes mini scallops", index: index, isFood: isFood))
        XCTAssertEqual(found.brand.name, "Trader Joe's")
        XCTAssertEqual(found.food, ["mini", "scallop"])
        XCTAssertNil(FoodSearch.brand(in: "baby carrots raw", index: index, isFood: isFood))
        XCTAssertNil(FoodSearch.brand(in: "greek yogurt plain", index: index, isFood: isFood))

        // And the carrots themselves are there without the brand.
        let generic = FoodDatabase.search(found.food.joined(separator: " "), limit: 15, databaseURL: foodsURL, productsURL: nil)
        XCTAssertTrue(generic.contains { $0.reference.name.lowercased().hasPrefix("scallops") })
    }

    // MARK: - Which foods

    func testTheHeadWordIsTheLastOfTheFoodBeforeWith() {
        let brand = FoodSearch.Brand(name: "Trader Joe's", words: ["trader", "joe"])
        XCTAssertEqual(FoodSearch.head(of: "trader joes cut and peeled carrots", brand: brand), "carrot")
        XCTAssertEqual(FoodSearch.head(of: "carrots from trader joes", brand: brand), "carrot")
        XCTAssertEqual(FoodSearch.head(of: "oatmeal with blueberries", brand: nil), "oatmeal")
        XCTAssertEqual(FoodSearch.head(of: "mini scallops", brand: nil), "scallop")
    }

    private func match(_ id: String, _ name: String) -> FoodMatch {
        FoodMatch(reference: FoodReference(id: id, name: name, per100g: .init()), category: "", portions: [])
    }

    func testFoodsAreTheOnesWithTheWordWholeNamedForItFirstEachOnce() {
        let matches = [match("1", "Scallops, fried"), match("2", "Potato, scalloped, NFS"),
                       match("3", "Squash, summer, scallop, raw"), match("4", "Scallops, sea, frozen, wild caught"),
                       match("5", "Muffins, blueberry (includes mini-muffins)"), match("6", "scallops, fried")]
        XCTAssertEqual(FoodSearch.focused(matches, head: "scallop", limit: 10).map(\.reference.id), ["1", "4", "3"])
        XCTAssertEqual(FoodSearch.focused(matches, head: "scallop", limit: 1).map(\.reference.id), ["1"])
        // Nothing has the word: the database's order stands.
        XCTAssertEqual(FoodSearch.focused(matches, head: "lobster", limit: 2).map(\.reference.id), ["1", "2"])
    }

    func testTheRealDatabaseShowsCarrotsAndScallopsNotWhatSharesAWord() throws {
        let foodsURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Foods", withExtension: "sqlite"))
        func names(_ query: String) -> [String] {
            FoodSearch.focused(FoodDatabase.search(query, limit: 40, databaseURL: foodsURL, productsURL: nil),
                               head: FoodSearch.head(of: query, brand: nil), limit: 15).map(\.reference.name)
        }
        let carrots = names("cut and peeled carrots")
        XCTAssertTrue(carrots.contains("Carrots, baby, raw"))
        XCTAssertFalse(carrots.contains { $0.hasPrefix("Lamb") })
        XCTAssertEqual(carrots.filter { $0 == "Carrots, raw" }.count, 1)
        let scallops = names("mini scallops")
        XCTAssertTrue(scallops.contains("Scallops, bay, Patagonian, frozen, wild caught"))
        XCTAssertFalse(scallops.contains { $0.lowercased().contains("scalloped") || $0.lowercased().contains("muffin") })
    }

    // MARK: - Amounts

    func testAmountsReadAsTheMeasureCounted() {
        let cup = FoodPortion(label: "1 cup", grams: 120)
        XCTAssertEqual(FoodSearch.serving(.init(count: 1.5, unit: .portion(cup))), "1\u{00BD} cups \u{00B7} 180 g")
        XCTAssertEqual(FoodSearch.serving(.init(count: 10, unit: .portion(FoodPortion(label: "1 baby carrot", grams: 10)))),
                       "10 baby carrots \u{00B7} 100 g")
        XCTAssertEqual(FoodSearch.serving(.init(count: 2, unit: .portion(FoodPortion(label: "1 cup chopped", grams: 128)))),
                       "2 cups chopped \u{00B7} 256 g")
        XCTAssertEqual(FoodSearch.serving(.init(count: 2, unit: .portion(FoodPortion(label: "typical portion", grams: 85)))),
                       "2 \u{00D7} typical portion \u{00B7} 170 g")
        XCTAssertEqual(FoodSearch.serving(.init(count: 3, unit: .ounces)), "3 oz \u{00B7} 85 g")
        XCTAssertEqual(FoodSearch.serving(.init(count: 120, unit: .grams)), "120 g")
        XCTAssertEqual(FoodSearch.serving(.init(count: 2, unit: .servings), base: "1 bowl"), "2 \u{00D7} 1 bowl")
    }

    func testAFoodsNumbersFollowItsWeight() {
        let result = FoodSearch.result(carrots, section: .foods)
        XCTAssertEqual(result.start, FoodSearch.Amount(count: 1, unit: .portion(FoodPortion(label: "1 cup", grams: 120))))
        let item = FoodSearch.item(result, amount: .init(count: 10, unit: .portion(FoodPortion(label: "1 baby carrot", grams: 10))),
                                   name: "Trader Joe's cut & peeled carrots")
        XCTAssertEqual(item.name, "Trader Joe's cut & peeled carrots")
        XCTAssertEqual(item.grams, 100)
        XCTAssertEqual(item.macros.calories, 41, accuracy: 0.01)
        XCTAssertEqual(item.reference?.id, "fndds:2709660")
        XCTAssertEqual(item.confidence, 1)
        XCTAssertEqual(FoodSearch.item(result, amount: result.start, name: " ").name, "Carrots, raw")
    }

    func testSomethingLoggedWithoutAWeightScalesByCount() {
        let shake = MealItem(name: "Protein shake", serving: "1 bottle",
                             macros: NutritionMacros(calories: 160, proteinGrams: 30, carbohydrateGrams: 5, fatGrams: 2))
        let result = FoodSearch.Result(id: "yours:shake", section: .yours, name: "Protein shake", detail: "",
                                       item: shake, portions: [], start: .init(count: 1, unit: .servings))
        let two = FoodSearch.item(result, amount: .init(count: 2, unit: .servings), name: "Protein shake")
        XCTAssertEqual(two.macros.calories, 320)
        XCTAssertEqual(two.serving, "2 \u{00D7} 1 bottle")
    }

    func testSteppingAndChangingUnitsKeepTheWeight() {
        let cup = FoodPortion(label: "1 cup", grams: 120)
        XCTAssertEqual(FoodSearch.stepped(.init(count: 1, unit: .portion(cup)), by: 1).count, 1.5)
        XCTAssertEqual(FoodSearch.stepped(.init(count: 1, unit: .portion(cup)), by: -1).count, 0.75)
        XCTAssertEqual(FoodSearch.stepped(.init(count: 0.25, unit: .portion(cup)), by: -1).count, 0.25)
        XCTAssertEqual(FoodSearch.stepped(.init(count: 100, unit: .grams), by: 1).count, 110)

        let inGrams = FoodSearch.converted(.init(count: 1, unit: .portion(cup)), to: .grams)
        XCTAssertEqual(inGrams, .init(count: 120, unit: .grams))
        XCTAssertEqual(FoodSearch.converted(inGrams, to: .portion(FoodPortion(label: "1 baby carrot", grams: 10))).count, 12)
        XCTAssertEqual(FoodSearch.converted(.init(count: 85, unit: .grams), to: .ounces).count, 3)
    }

    func testYourUsualWeightStartsInItsMeasureOnlyWhenThatDoesntChangeIt() {
        let cup = FoodPortion(label: "1 cup", grams: 120)
        XCTAssertEqual(FoodSearch.startAmount(portions: [cup], grams: 180, serving: "1\u{00BD} cups \u{00B7} 180 g"),
                       .init(count: 1.5, unit: .portion(cup)))
        XCTAssertEqual(FoodSearch.startAmount(portions: [cup], grams: 180, serving: "1 cup \u{00B7} 180 g").unit, .portion(cup))
        XCTAssertEqual(FoodSearch.startAmount(portions: [cup], grams: 95, serving: "1 cup \u{00B7} 95 g"), .init(count: 95, unit: .grams))
        XCTAssertEqual(FoodSearch.startAmount(portions: [], grams: nil), .init(count: 100, unit: .grams))
    }

    // MARK: - An amount of something already in a meal

    private let cucumberPortions = [FoodPortion(label: "1 piece/slice", grams: 10), FoodPortion(label: "1 regular", grams: 200),
                                    FoodPortion(label: "1 miniature", grams: 65), FoodPortion(label: "1 cup", grams: 120),
                                    FoodPortion(label: "typical portion", grams: 60)]
    private let cucumber = FoodReference(id: "fndds:2709784", name: "Cucumber, raw",
                                         per100g: NutritionMacros(calories: 16, proteinGrams: 0.62, carbohydrateGrams: 2.95,
                                                                  fatGrams: 0.18))

    /// The photo's guess at a cucumber, as it reached the review: half a cup.
    private var guessedCucumber: MealItem {
        MealItem(name: "Cucumber", serving: "1/2 cup \u{00B7} 60 g", macros: cucumber.macros(grams: 60),
                 confidence: 0.8, grams: 60, reference: cucumber)
    }

    func testAnItemStartsInTheMeasureItsServingNames() {
        let cup = FoodPortion(label: "1 cup", grams: 120)
        XCTAssertEqual(FoodSearch.amount(of: guessedCucumber, portions: cucumberPortions), .init(count: 0.5, unit: .portion(cup)))
        var oddWeight = guessedCucumber
        oddWeight.grams = 73
        XCTAssertEqual(FoodSearch.amount(of: oddWeight, portions: cucumberPortions), .init(count: 73, unit: .grams))
        let beer = MealItem(name: "large 0.0 beer", serving: "1 serving", macros: .init(calories: 153))
        XCTAssertEqual(FoodSearch.amount(of: beer, portions: []), .init(count: 1, unit: .servings))
    }

    func testACucumberCountsInCucumbersOrGramsNotHalfCups() {
        let item = guessedCucumber
        let regular = FoodPortion(label: "1 regular", grams: 200)
        let one = FoodSearch.item(item, at: .init(count: 1, unit: .portion(regular)), base: item)
        XCTAssertEqual(one.grams, 200)
        XCTAssertEqual(one.macros.calories, 32, accuracy: 0.01)
        XCTAssertEqual(one.serving, "1 regular \u{00B7} 200 g")
        XCTAssertEqual(one.reference, cucumber)

        let typed = FoodSearch.item(one, at: .init(count: 150, unit: .grams), base: item)
        XCTAssertEqual(typed.grams, 150)
        XCTAssertEqual(typed.macros.calories, 24, accuracy: 0.01)
        XCTAssertEqual(typed.serving, "150 g")

        let ounces = FoodSearch.item(item, at: .init(count: 4, unit: .ounces), base: item)
        XCTAssertEqual(ounces.grams ?? 0, 113.4, accuracy: 0.1)
    }

    func testGramsStepFinelyWhenThereAreFew() {
        func stepped(_ grams: Double, _ direction: Int) -> Double {
            FoodSearch.stepped(.init(count: grams, unit: .grams), by: direction).count
        }
        XCTAssertEqual(stepped(0, 1), 1, "a sheet of seaweed at a time")
        XCTAssertEqual(stepped(3, 1), 4)
        XCTAssertEqual(stepped(20, -1), 19)
        XCTAssertEqual(stepped(20, 1), 25)
        XCTAssertEqual(stepped(100, -1), 95)
        XCTAssertEqual(stepped(100, 1), 110)
        XCTAssertEqual(stepped(1, -1), 1, "never to nothing")
    }

    func testAFoodWithNoWeightYetStartsInGramsToBeSaid() {
        var unset = guessedCucumber
        unset.grams = 0
        XCTAssertEqual(FoodSearch.amount(of: unset, portions: cucumberPortions), .init(count: 0, unit: .grams))
        let said = FoodSearch.item(unset, at: .init(count: 40, unit: .grams), base: unset)
        XCTAssertEqual(said.grams, 40)
        XCTAssertEqual(said.macros.calories, 6.4, accuracy: 0.01)
    }

    func testEveryMeasureOfAWeighedFoodIsOffered() {
        let units = FoodSearch.units(portions: cucumberPortions, weighable: true)
        XCTAssertEqual(units.count, cucumberPortions.count + 2)
        XCTAssertEqual(units.suffix(2), [.grams, .ounces])
        XCTAssertEqual(FoodSearch.units(portions: cucumberPortions, weighable: false), [.servings])
    }

    func testMeasuresAreNamedBesideTheirCount() {
        XCTAssertEqual(FoodSearch.unitName(.portion(FoodPortion(label: "1 regular", grams: 200))), "regular \u{00B7} 200 g")
        XCTAssertEqual(FoodSearch.unitName(.portion(FoodPortion(label: "typical portion", grams: 60))),
                       "typical portion \u{00B7} 60 g")
        XCTAssertEqual(FoodSearch.unitName(.grams), "grams")
        XCTAssertEqual(FoodSearch.unitName(.servings, serving: "1 can"), "\u{00D7} 1 can")
        XCTAssertEqual(FoodSearch.unitName(.servings), "servings")
    }

    func testMeasuresAreShortOnTheirChips() {
        XCTAssertEqual(FoodSearch.unitChip(.grams), "g")
        XCTAssertEqual(FoodSearch.unitChip(.ounces), "oz")
        XCTAssertEqual(FoodSearch.unitChip(.portion(FoodPortion(label: "1 regular", grams: 200))), "regular")
        XCTAssertEqual(FoodSearch.unitChip(.portion(FoodPortion(label: "1 cup, sliced", grams: 104))), "cup")
        XCTAssertEqual(FoodSearch.unitChip(.portion(FoodPortion(label: "typical portion", grams: 60))), "typical portion")
    }

    func testSomethingWithoutAWeightIsAnyNumberOfWhatWasLogged() {
        let beer = MealItem(name: "large 0.0 beer", serving: "1 serving",
                            macros: NutritionMacros(calories: 153, proteinGrams: 1, carbohydrateGrams: 30, fatGrams: 0))
        let more = FoodSearch.item(beer, at: .init(count: 2.5, unit: .servings), base: beer)
        XCTAssertEqual(more.macros.calories, 382.5, accuracy: 0.01)
        XCTAssertEqual(more.serving, "2\u{00BD} \u{00D7} 1 serving")
        XCTAssertNil(more.grams)
        let back = FoodSearch.item(more, at: .init(count: 1, unit: .servings), base: beer)
        XCTAssertEqual(back.macros.calories, 153, accuracy: 0.01)
        XCTAssertEqual(back.serving, "1 serving")
    }

    func testTheRealDatabaseCountsACucumberWhole() throws {
        let foodsURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Foods", withExtension: "sqlite"))
        let portions = try XCTUnwrap(FoodDatabase.food(id: "fndds:2709784", databaseURL: foodsURL, productsURL: nil)).portions
        let units = FoodSearch.units(portions: portions, weighable: true)
        XCTAssertTrue(units.contains(.portion(FoodPortion(label: "1 regular", grams: 200))))
        XCTAssertTrue(units.contains(.grams))
    }

    // MARK: - Open Food Facts

    private func search(_ hits: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["hits": hits, "count": hits.count])
    }

    private func hit(_ code: String, _ name: String, brands: Any? = ["Trader Joe's"], kcal: Any? = 41,
                     serving: Any? = nil, servingSize: String? = nil) -> [String: Any] {
        var nutriments: [String: Any] = ["proteins_100g": 0.9, "carbohydrates_100g": "9.6", "fat_100g": 0.2]
        if let kcal { nutriments["energy-kcal_100g"] = kcal }
        var hit: [String: Any] = ["code": code, "product_name": name, "nutriments": nutriments]
        if let brands { hit["brands"] = brands }
        if let serving { hit["serving_quantity"] = serving }
        if let servingSize { hit["serving_size"] = servingSize }
        return hit
    }

    func testABrandsProductsNeedAWordOfTheFood() throws {
        let brand = FoodSearch.Brand(name: "Trader Joe's", words: ["trader", "joe"])
        let data = try search([
            hit("1", "Spinach Dip - Trader Joe's - Trader Joe's", kcal: 266),
            hit("2", "Organic Whole Carrots", serving: "85", servingSize: "3 oz (85g)"),
            hit("3", "Colorful Carrot Coins", kcal: 80),
            hit("4", "Carrot spirals", kcal: nil),
            hit("5", "organic whole carrots", brands: "Trader Joe's, Boston Man Marketing"),
            hit("6", "Trader Joe's", kcal: 400),
        ])
        let results = FoodSearch.products(fromSearch: data, food: ["cut", "peeled", "carrot"], brand: brand)
        XCTAssertEqual(results.map(\.name), ["Trader Joe's Organic Whole Carrots", "Trader Joe's Colorful Carrot Coins"])
        XCTAssertEqual(FoodSearch.products(fromSearch: data, food: ["carrot"], brand: brand, limit: 1).count, 1)
        let first = try XCTUnwrap(results.first)
        XCTAssertEqual(first.id, "off:2")
        XCTAssertEqual(first.portions.first, FoodPortion(label: "1 serving (3 oz (85g))", grams: 85))
        XCTAssertEqual(first.item.grams, 85)
        XCTAssertEqual(first.item.reference?.per100g.carbohydrateGrams, 9.6)
        XCTAssertEqual(first.item.reference?.sourceName, "Open Food Facts")
    }

    func testAProductThatIsTheFoodComesBeforeOneThatHasIt() throws {
        let brand = FoodSearch.Brand(name: "Trader Joe's", words: ["trader", "joe"])
        let data = try search([hit("1", "Carrot Ginger Soup", kcal: 33), hit("2", "Carrot spirals"),
                               hit("3", "Organic Whole Carrots", kcal: 40)])
        XCTAssertEqual(FoodSearch.products(fromSearch: data, food: ["cut", "peeled", "carrot"], brand: brand).first?.name,
                       "Trader Joe's Organic Whole Carrots")
    }

    func testWithoutABrandAProductNeedsEveryWord() throws {
        let data = try search([
            hit("1", "Fairlife Milk - fat free", brands: ["Fairlife"], kcal: 32),
            hit("2", "Fairlife Chocolate Milk", brands: nil, kcal: 60),
            hit("3", "Coquilles Saint Jacques", brands: ["Excellence"], kcal: 120),
        ])
        XCTAssertEqual(FoodSearch.products(fromSearch: data, food: ["fairlife", "milk"], brand: nil).map(\.name),
                       ["Fairlife Chocolate Milk", "Fairlife Milk - fat free"])
        XCTAssertTrue(FoodSearch.products(fromSearch: data, food: ["mini", "scallop"], brand: nil).isEmpty)
        XCTAssertTrue(FoodSearch.products(fromSearch: Data("nope".utf8), food: ["milk"], brand: nil).isEmpty)
    }

    func testTheOnlineSearchAsksForTheFoodOfTheBrand() throws {
        let brand = FoodSearch.Brand(name: "Trader Joe's", words: ["trader", "joe"])
        let url = try XCTUnwrap(FoodSearch.onlineURL("trader joes mini scallops", brand: brand))
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value
        XCTAssertEqual(q, "scallops AND brands:\"trader joe's\"")
        let plain = try XCTUnwrap(FoodSearch.onlineURL("fairlife milk", brand: nil))
        XCTAssertEqual(URLComponents(url: plain, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value,
                       "fairlife milk")
        XCTAssertNil(FoodSearch.onlineURL("  ", brand: nil))
    }

    // MARK: - Yours

    private func meal(_ daysAgo: Double, _ items: [MealItem]) -> MealEntry {
        MealEntry(date: Date(timeIntervalSince1970: 1_800_000_000 - daysAgo * 86_400), items: items)
    }

    private func loggedCarrots(_ grams: Double) -> MealItem {
        MealItem(name: "TJ baby carrots", serving: "\(Int(grams)) g", macros: carrots.reference.macros(grams: grams),
                 confidence: 1, grams: grams, reference: carrots.reference)
    }

    func testWhatYouLoggedIsFoundAtYourUsualAmountWhateverTheBrand() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let meals = [meal(9, [loggedCarrots(100)]), meal(5, [loggedCarrots(85)]), meal(1, [loggedCarrots(85)])]
        let brand = FoodSearch.Brand(name: "Trader Joe's", words: ["trader", "joe"])
        let found = FoodSearch.yours("trader joes carrots", meals: meals, myFoods: [], picked: [:], brand: brand, now: now)
        let carrots = try XCTUnwrap(found.first)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(carrots.name, "TJ baby carrots")
        XCTAssertEqual(carrots.item.grams, 85)
        XCTAssertEqual(carrots.detail, "Had 3 times \u{00B7} usually 85 g")
        XCTAssertTrue(FoodSearch.yours("scallops", meals: meals, myFoods: [], picked: [:], brand: nil, now: now).isEmpty)
    }

    func testWhatWasPickedForTheseWordsIsFoundAndComesFirst() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let other = MealItem(name: "Carrot cake", serving: "1 slice",
                             macros: NutritionMacros(calories: 350, proteinGrams: 4, carbohydrateGrams: 50, fatGrams: 15),
                             confidence: 1, grams: 100, reference: FoodReference(id: "fndds:1", name: "Carrot cake", per100g: .init()))
        let meals = [meal(2, [other]), meal(3, [other]), meal(1, [loggedCarrots(85)])]
        let found = FoodSearch.yours("carrot", meals: meals, myFoods: [], picked: [carrots.reference.id: 2], brand: nil, now: now)
        XCTAssertEqual(found.map(\.name), ["TJ baby carrots", "Carrot cake"])
        // Found by the pick alone, though no word of the search is in its name.
        XCTAssertEqual(FoodSearch.yours("orange sticks", meals: meals, myFoods: [], picked: [carrots.reference.id: 1],
                                        brand: nil, now: now).map(\.name), ["TJ baby carrots"])
    }

    func testAScannedFoodIsFoundByWhatItStoodFor() throws {
        var food = MyFood(name: "Pumpkin Gnocchi", barcode: "1", per100g: NutritionMacros(calories: 180, proteinGrams: 4, carbohydrateGrams: 36, fatGrams: 2),
                          servingLabel: "1 cup", servingGrams: 140, packageGrams: 500, source: .barcode)
        food.standsFor = ["dumpling"]
        let found = try XCTUnwrap(FoodSearch.yours("dumplings", meals: [], myFoods: [food], picked: [:], brand: nil).first)
        XCTAssertEqual(found.name, "Pumpkin Gnocchi")
        XCTAssertEqual(found.portions.map(\.label), ["1 cup", "1 package"])
        XCTAssertEqual(found.item.macros.calories, 252, accuracy: 0.01)
    }

    func testProductNamesLoseTheBrandRepeatedInThem() {
        XCTAssertEqual(FoodSearch.productName("Spinach Dip - Trader Joe's - Trader Joe's", brands: ["Trader Joe's"]), "Spinach Dip")
        XCTAssertNil(FoodSearch.productName("Trader Joe's", brands: ["Trader Joe's"]))
        XCTAssertEqual(FoodSearch.productName("carrot spirals", brands: []), "Carrot spirals")
    }
}
