import XCTest

/// Nutrition Facts as text recognition reads them off a package.
final class NutritionLabelParserTests: XCTestCase {
    func testATraderJoesStyleLabel() throws {
        let label = try XCTUnwrap(NutritionLabelParser.parse("""
            Nutrition Facts
            About 3 servings per container
            Serving size 1 cup (140g)
            Amount per serving
            Calories 210
            % Daily Value*
            Total Fat 3.5g 4%
            Saturated Fat 2g 10%
            Trans Fat 0g
            Cholesterol 10mg 3%
            Sodium 480mg 21%
            Total Carbohydrate 40g 15%
            Dietary Fiber 2g 7%
            Total Sugars 3g
            Includes 0g Added Sugars 0%
            Protein 5g
            Vitamin D 0mcg 0% • Calcium 30mg 2%
            * The % Daily Value (DV) tells you how much a nutrient in a serving of food contributes to a daily diet. 2,000 calories a day is used for general nutrition advice.
            """.components(separatedBy: "\n")))
        XCTAssertEqual(label.servingLabel, "1 cup")
        XCTAssertEqual(label.servingGrams, 140)
        XCTAssertEqual(label.servingsPerContainer, 3)
        XCTAssertEqual(label.perServing, NutritionMacros(calories: 210, proteinGrams: 5, carbohydrateGrams: 40, fatGrams: 3.5))
        XCTAssertEqual(label.packageGrams, 420)
        XCTAssertEqual(label.per100g.calories, 150, accuracy: 0.001)
    }

    /// What the camera actually makes of one: the big calories number on its own line, an O for a
    /// zero, words run together, the serving's weight on the line after.
    func testTextRecognitionNoise() throws {
        let label = try XCTUnwrap(NutritionLabelParser.parse([
            "Nutrition Facts", "8 servings per container", "Servingsize", "2/3 cup (55g)",
            "Amount per serving", "Calories", "230", "% Daily Value*",
            "Total Fat Og 0%", "Sodium 160mg 7%", "TotalCarbohydrate 37g 13%", "Protein 3g",
        ]))
        XCTAssertEqual(label.servingLabel, "2/3 cup")
        XCTAssertEqual(label.servingGrams, 55)
        XCTAssertEqual(label.servingsPerContainer, 8)
        XCTAssertEqual(label.perServing, NutritionMacros(calories: 230, proteinGrams: 3, carbohydrateGrams: 37, fatGrams: 0))
    }

    func testTheOlderLabel() throws {
        let label = try XCTUnwrap(NutritionLabelParser.parse([
            "Serving Size 1 package (283g)", "Servings Per Container 1", "Amount Per Serving",
            "Calories 380 Calories from Fat 90", "Total Fat 10g 15%", "Total Carb. 52g 17%", "Protein 18g",
        ]))
        XCTAssertEqual(label.servingLabel, "1 package")
        XCTAssertEqual(label.servingGrams, 283)
        XCTAssertEqual(label.servingsPerContainer, 1)
        XCTAssertEqual(label.perServing.calories, 380)
        XCTAssertEqual(label.perServing.fatGrams, 10)
        XCTAssertEqual(label.perServing.carbohydrateGrams, 52)
        XCTAssertEqual(label.perServing.proteinGrams, 18)
    }

    func testAmountPerServingAndCaloriesOnOneLineAndLessThanAGram() throws {
        let label = try XCTUnwrap(NutritionLabelParser.parse([
            "Serving size: 1 bar (40g)", "Amount per serving Calories 190", "Total Fat 7g", "Total Carbs 26g",
            "Protein <1g",
        ]))
        XCTAssertEqual(label.servingLabel, "1 bar")
        XCTAssertEqual(label.perServing.calories, 190)
        XCTAssertEqual(label.perServing.carbohydrateGrams, 26)
        XCTAssertEqual(label.perServing.proteinGrams, 1)
        XCTAssertNil(label.servingsPerContainer)
    }

    func testAProductsNameIsTheBigWordsOnItsFront() {
        let front: [(text: String, height: Double, top: Double)] = [
            ("PUMPKIN GNOCCHI", 0.10, 0.20), ("TRADER JOE'S", 0.08, 0.10), ("with a hint of sage", 0.03, 0.35),
            ("Cooks in 3 minutes!", 0.04, 0.50), ("NET WT 17.6 OZ (500g)", 0.03, 0.90),
        ]
        XCTAssertEqual(ProductNameReading.name(from: front), "Trader Joe's Pumpkin Gnocchi")
        XCTAssertEqual(ProductNameReading.titled("Kale Chips"), "Kale Chips")
        XCTAssertNil(ProductNameReading.name(from: [("12 oz", 0.1, 0.1)]))
        XCTAssertNil(ProductNameReading.name(from: []))
    }

    /// Without the serving's weight nothing can be scaled to what was eaten; without calories it
    /// isn't a nutrition label.
    func testNothingWithoutAWeightOrCalories() {
        XCTAssertNil(NutritionLabelParser.parse(["Serving size 1 cup", "Amount per serving", "Calories 210"]))
        XCTAssertNil(NutritionLabelParser.parse(["Serving size 1 cup (140g)", "Total Fat 3g", "Protein 5g"]))
        XCTAssertNil(NutritionLabelParser.parse(["INGREDIENTS: PUMPKIN, POTATO FLAKES, WHEAT FLOUR, SALT."]))
    }
}

/// Your foods: matching, usual amounts, ranking.
final class MyFoodsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    private func gnocchi(uses: [MyFood.Use] = [], standsFor: [String] = []) -> MyFood {
        MyFood(name: "Trader Joe's Pumpkin Gnocchi", barcode: "00512345",
               per100g: NutritionMacros(calories: 150, proteinGrams: 3.6, carbohydrateGrams: 28.6, fatGrams: 2.5),
               servingLabel: "1 cup", servingGrams: 140, packageGrams: 420, source: .label, addedAt: daysAgo(30),
               uses: uses, standsFor: standsFor)
    }

    func testFromALabelAndFromABarcodeProduct() throws {
        let label = ParsedNutritionLabel(servingLabel: "1 cup", servingGrams: 140, servingsPerContainer: 3,
                                         perServing: NutritionMacros(calories: 210, proteinGrams: 5, carbohydrateGrams: 40, fatGrams: 3.5))
        let fromLabel = MyFoods.food(label: label, name: "Pumpkin Gnocchi", barcode: nil)
        XCTAssertEqual(fromLabel.per100g.calories, 150, accuracy: 0.001)
        XCTAssertEqual(fromLabel.packageGrams, 420)
        let fromBarcode = try XCTUnwrap(MyFoods.food(name: "Gnocchi", barcode: "123", servingLabel: "1 cup",
                                                     servingGrams: 140, perServing: label.perServing, source: .barcode))
        XCTAssertEqual(fromBarcode.per100g, fromLabel.per100g)
        XCTAssertNil(MyFoods.food(name: "x", barcode: nil, servingLabel: "", servingGrams: 0,
                                  perServing: label.perServing, source: .barcode))
    }

    /// A barcode product needs its serving's weight to be one of yours; without it, or without
    /// nutrition, the label is photographed instead.
    func testFromABarcodeProductOnlyWithAWeighedServing() throws {
        let perServing = NutritionMacros(calories: 210, proteinGrams: 5, carbohydrateGrams: 40, fatGrams: 3.5)
        let product = BarcodeProduct(barcode: "0051", name: "Pumpkin Gnocchi", serving: "1 cup (140 g)", macros: perServing)
        let food = try XCTUnwrap(MyFoods.food(product: product))
        XCTAssertEqual(food.servingLabel, "1 cup")
        XCTAssertEqual(food.servingGrams, 140)
        XCTAssertEqual(food.barcode, "0051")
        XCTAssertEqual(food.source, .barcode)
        XCTAssertNil(MyFoods.food(product: BarcodeProduct(barcode: "1", name: "x", serving: "1 cup", macros: perServing)))
        XCTAssertNil(MyFoods.food(product: BarcodeProduct(barcode: "1", name: "x", serving: "140 g", macros: nil)))
        XCTAssertEqual(MyFoods.serving("28g")?.label, "28 g")
        XCTAssertEqual(MyFoods.serving("2 pieces (28.5 grams)")?.grams, 28.5)
        XCTAssertNil(MyFoods.serving("250 ml"))
    }

    func testTheItemAScanBecomes() {
        let id = UUID()
        let food = gnocchi()
        let item = ScanCorrection.item(food: food, grams: 210, id: id)
        XCTAssertEqual(item.id, id)
        XCTAssertEqual(item.name, "Trader Joe's Pumpkin Gnocchi")
        XCTAssertEqual(item.serving, "1½ cups · 210 g")
        XCTAssertEqual(item.macros.calories, 315, accuracy: 0.001)
        XCTAssertEqual(item.confidence, 1)
        XCTAssertEqual(item.reference, food.reference)
    }

    // MARK: - A product that states no serving (a pack of seaweed)

    /// As scanned from Open Food Facts on 5 Oct 2026: a 72 g pack, nutrition per 100 g, no serving.
    private var nori: MyFood {
        MyFood(name: "Sushi Nori Roasted Seaweed", barcode: "0087703011274",
               per100g: NutritionMacros(calories: 416.67, proteinGrams: 41.67, carbohydrateGrams: 41.67, fatGrams: 0),
               servingLabel: "100 g", servingGrams: 100, packageGrams: 72, servingStated: false, source: .barcode,
               addedAt: now)
    }

    func testWithNoServingOnThePackageNothingIsCountedInServings() {
        // Its package is a measure; "100 g" isn't one, and there's no serving to count.
        XCTAssertEqual(MyFoods.measures(nori), [FoodPortion(label: "1 package", grams: 72)])
        XCTAssertEqual(ScanCorrection.amount(grams: 5, of: nori), .init(count: 5, unit: .grams))
        XCTAssertEqual(ScanCorrection.item(food: nori, grams: 5).serving, "5 g")
        XCTAssertEqual(ScanCorrection.item(food: nori, grams: 5).macros.calories, 20.83, accuracy: 0.01)
    }

    func testWithNoServingTheAmountComesFromYourUsualOrTheEstimateNeverThePackage() {
        // The photo's count of "servings" means nothing here, and neither does a whole pack.
        XCTAssertEqual(ScanCorrection.startingGrams(photoServings: 1, food: nori, estimatedGrams: 6, now: now), 6)
        XCTAssertEqual(ScanCorrection.startingGrams(photoServings: 1, food: nori, estimatedGrams: nil, now: now), 0,
                       "nothing says how much: asked for, not guessed")
        var had = nori
        had.uses = [MyFood.Use(at: now, grams: 4), MyFood.Use(at: now, grams: 4)]
        XCTAssertEqual(ScanCorrection.startingGrams(photoServings: nil, food: had, estimatedGrams: 30, now: now), 4)
    }

    func testAScannedAmountReadsInItsOwnServingWhenThatsARoundNumber() {
        let food = gnocchi()
        let cup = FoodPortion(label: "1 cup", grams: 140)
        XCTAssertEqual(ScanCorrection.amount(grams: 245, of: food), .init(count: 1.75, unit: .portion(cup)))
        XCTAssertEqual(ScanCorrection.amount(grams: 200, of: food), .init(count: 200, unit: .grams))
        XCTAssertEqual(MyFoods.measures(food), [cup, FoodPortion(label: "1 package", grams: 420)])
        // A serving that's only a weight is "1 serving", not a thing called "30 g" to have two of.
        XCTAssertEqual(MyFoods.servingMeasure("30 g"), "1 serving")
        XCTAssertEqual(MyFoods.servingMeasure("egg"), "1 egg")
        XCTAssertEqual(MyFoods.servingMeasure("3/4 cup"), "3/4 cup")
    }

    // MARK: - Putting right what was scanned mis-scaled

    /// A Trader Joe's egg as it was stored: Open Food Facts' 140 kcal per 100 g taken for one
    /// 50 g egg's, so 280 per 100 g.
    private var misScaledEgg: MyFood {
        MyFood(name: "Trader Joe's Pasture Raised Large Brown Eggs", barcode: "00621243",
               per100g: NutritionMacros(calories: 280, proteinGrams: 24, carbohydrateGrams: 0, fatGrams: 20),
               servingLabel: "1 egg", servingGrams: 50, source: .barcode, addedAt: daysAgo(3),
               standsFor: [MyFoods.key("egg")])
    }

    /// The same barcode scanned today: what its source says.
    private var eggScannedNow: MyFood {
        MyFood(name: "Trader Joe's Eggs", barcode: "00621243",
               per100g: NutritionMacros(calories: 140, proteinGrams: 12, carbohydrateGrams: 0, fatGrams: 10),
               servingLabel: "1 egg", servingGrams: 50, source: .barcode, addedAt: now)
    }

    func testAFoodIsBroughtIntoLineWithItsSourceKeepingWhatItIs() throws {
        let egg = misScaledEgg
        let fixed = try XCTUnwrap(MyFoods.reconciled(egg, with: eggScannedNow))
        XCTAssertEqual(fixed.per100g, NutritionMacros(calories: 140, proteinGrams: 12, carbohydrateGrams: 0, fatGrams: 10))
        XCTAssertEqual(fixed.reference.macros(grams: 50).calories, 70, "one egg")
        XCTAssertEqual(fixed.id, egg.id)
        XCTAssertEqual(fixed.name, egg.name, "what you call it")
        XCTAssertEqual(fixed.addedAt, egg.addedAt)
        XCTAssertEqual(fixed.standsFor, egg.standsFor)
    }

    /// The first repair multiplied wherever a synced field read "not yet", and a device on an
    /// older build saved corrected foods back without the field. Compared with the source, a
    /// food already right is left alone however it got that way.
    func testCheckingAgainChangesNothingWhateverStateItArrivesIn() throws {
        let fixed = try XCTUnwrap(MyFoods.reconciled(misScaledEgg, with: eggScannedNow))
        XCTAssertNil(MyFoods.reconciled(fixed, with: eggScannedNow), "never twice")
        // Corrected on another device, then saved by a build that doesn't know `numbers`.
        var stripped = fixed
        stripped.numbers = 1
        XCTAssertNil(MyFoods.reconciled(stripped, with: eggScannedNow), "right is right, marker or not")
        // Corrected twice by that mistake: back to the source's, not multiplied again.
        var twice = fixed
        twice.per100g = NutritionMacros(calories: 70, proteinGrams: 6, carbohydrateGrams: 0, fatGrams: 5)
        XCTAssertEqual(MyFoods.reconciled(twice, with: eggScannedNow)?.per100g.calories, 140)
    }

    func testAPackageTakenForAServingIsPutRightToo() throws {
        var stale = nori
        stale.servingLabel = "72 g"
        stale.servingGrams = 72
        stale.servingStated = true
        stale.packageGrams = nil
        stale.standsFor = ["seaweed"]
        let fixed = try XCTUnwrap(MyFoods.reconciled(stale, with: nori))
        XCTAssertFalse(fixed.servingStated)
        XCTAssertEqual(fixed.servingGrams, 100)
        XCTAssertEqual(fixed.packageGrams, 72)
        XCTAssertEqual(fixed.standsFor, ["seaweed"])
    }

    func testWhatWasCheckedIsKnownByItsNumbers() throws {
        let egg = misScaledEgg
        let fixed = try XCTUnwrap(MyFoods.reconciled(egg, with: eggScannedNow))
        XCTAssertNotEqual(MyFoods.fingerprint(egg), MyFoods.fingerprint(fixed),
                          "a stale copy arriving later isn't mistaken for the one checked")
        XCTAssertEqual(MyFoods.fingerprint(fixed), MyFoods.fingerprint(fixed))
    }

    func testAFoodStoredBeforeTheFieldsExistedStillDecodes() throws {
        let json = #"{"id":"8268D758-0000-4000-8000-000000000001","name":"Eggs","barcode":"00621243","per100g":{"calories":280,"proteinGrams":24,"carbohydrateGrams":0,"fatGrams":20},"servingLabel":"1 egg","servingGrams":50,"source":"barcode","addedAt":812000000,"standsFor":["egg"]}"#
        let stored = try JSONDecoder().decode(MyFood.self, from: Data(json.utf8))
        XCTAssertTrue(stored.servingStated)
        XCTAssertEqual(stored.per100g.calories, 280)
    }

    func testAMealLoggedFromItIsPutRightAtTheWeightItWasLoggedAt() throws {
        let old = misScaledEgg
        let new = try XCTUnwrap(MyFoods.reconciled(old, with: eggScannedNow))
        // 61 g of egg, logged at 171 kcal.
        let logged = ScanCorrection.item(food: old, grams: 61)
        XCTAssertEqual(logged.macros.calories, 170.8, accuracy: 0.01)
        let fixed = try XCTUnwrap(MyFoods.repaired(logged, from: old, to: new))
        XCTAssertEqual(fixed.macros.calories, 85.4, accuracy: 0.01)
        XCTAssertEqual(fixed.grams, 61)
        XCTAssertEqual(fixed.id, logged.id)
        XCTAssertEqual(fixed.reference?.per100g.calories, 140)
        XCTAssertNil(MyFoods.repaired(fixed, from: old, to: new), "never twice")
    }

    func testNumbersChangedByHandStandAndOtherFoodsAreLeftAlone() throws {
        let old = misScaledEgg
        let new = try XCTUnwrap(MyFoods.reconciled(old, with: eggScannedNow))
        var edited = ScanCorrection.item(food: old, grams: 61)
        edited.macros.calories = 90
        let fixed = try XCTUnwrap(MyFoods.repaired(edited, from: old, to: new))
        XCTAssertEqual(fixed.macros.calories, 90, "what you typed stands")
        XCTAssertEqual(fixed.reference?.per100g.calories, 140, "its food is still put right")
        XCTAssertNil(MyFoods.repaired(ScanCorrection.item(food: gnocchi(), grams: 140), from: old, to: new))
        XCTAssertNil(MyFoods.repaired(MealItem(name: "Toast", serving: "1 slice", macros: .init(calories: 80)), from: old, to: new))
    }

    func testAFoodWithNoServingAndNoHistoryIsntClaimedForATypedItem() {
        var seaweed = nori
        seaweed.standsFor = ["seaweed"]
        XCTAssertNil(MyFoods.item(name: "seaweed", quantity: "", in: [seaweed], now: now),
                     "100 g of seaweed is nobody's portion: left to the estimate")
        XCTAssertEqual(MyFoods.item(name: "seaweed", quantity: "5 g", in: [seaweed], now: now)?.grams, 5)
        seaweed.uses = [MyFood.Use(at: now, grams: 4)]
        XCTAssertEqual(MyFoods.item(name: "seaweed", quantity: "", in: [seaweed], now: now)?.grams, 4)
    }

    func testTheUsualIsTheRecentMiddleNotOneBigBowl() throws {
        let steady = gnocchi(uses: [200, 210, 205, 600].map { MyFood.Use(at: daysAgo(3), grams: $0) })
        XCTAssertEqual(MyFoods.typicalGrams(steady, now: now), 205)
        // Months of big portions, then two weeks of smaller ones: the habit changed.
        let changed = gnocchi(uses: [300, 300, 300].map { MyFood.Use(at: daysAgo(200), grams: $0) }
                                    + [150, 150].map { MyFood.Use(at: daysAgo(5), grams: $0) })
        XCTAssertEqual(MyFoods.typicalGrams(changed, now: now), 150)
        XCTAssertNil(MyFoods.typicalGrams(gnocchi(), now: now))
    }

    func testUsesComeFromTheMealLog() {
        let food = gnocchi()
        let meals = [
            MealEntry(date: daysAgo(2), items: [MealItem(name: "Gnocchi", serving: "", macros: .init(), grams: 210, reference: food.reference),
                                                 MealItem(name: "Salad", serving: "", macros: .init(), grams: 80)]),
            MealEntry(date: daysAgo(9), items: [MealItem(name: "Gnocchi", serving: "", macros: .init(), grams: 140, reference: food.reference)]),
        ]
        let uses = MyFoods.uses(in: meals)[food.id]
        XCTAssertEqual(uses?.map(\.grams), [140, 210])
        XCTAssertEqual(uses?.last?.at, daysAgo(2))
    }

    func testRecentHabitsRankAboveOldOnesAndNothingIsDropped() {
        let old = MyFood(name: "Old cereal", per100g: .init(calories: 380), servingLabel: "1 cup", servingGrams: 40,
                         source: .barcode, addedAt: daysAgo(400),
                         uses: (0..<10).map { _ in MyFood.Use(at: daysAgo(200), grams: 40) })
        let current = gnocchi(uses: (0..<3).map { MyFood.Use(at: daysAgo(Double($0)), grams: 210) })
        let justScanned = MyFood(name: "Kale chips", per100g: .init(calories: 500), servingLabel: "1 oz", servingGrams: 28,
                                 source: .label, addedAt: now)
        let ranked = MyFoods.ranked([old, justScanned, current], now: now)
        // Just bought outranks a cereal last had 200 days ago; not what you have every day.
        XCTAssertEqual(ranked.map(\.name), ["Trader Joe's Pumpkin Gnocchi", "Kale chips", "Old cereal"])
        // A year on, still there — just further down.
        XCTAssertEqual(MyFoods.ranked([old], now: now.addingTimeInterval(365 * 86_400)).count, 1)
        XCTAssertEqual(MyFoods.usualNames([old, justScanned, current], now: now),
                       ["Trader Joe's Pumpkin Gnocchi", "Kale chips", "Old cereal"])
    }

    func testMatchingByNameAndByWhatItStoodInFor() {
        let food = gnocchi(standsFor: [MyFoods.key("Pasta")])
        XCTAssertEqual(MyFoods.match("gnocchi", in: [food], now: now)?.id, food.id)
        XCTAssertEqual(MyFoods.match("Pumpkin gnocchi", in: [food], now: now)?.id, food.id)
        XCTAssertEqual(MyFoods.match("pasta", in: [food], now: now)?.id, food.id)
        XCTAssertNil(MyFoods.match("pumpkin soup", in: [food], now: now))
        XCTAssertNil(MyFoods.match("potato gnocchi with butter and sage", in: [food], now: now))
    }

    func testSharingAWordWithAProductIsntBeingIt() {
        let tenders = MyFood(name: "Trader Joe's Sundried Tomato And Basil Chicken Tenders",
                             per100g: NutritionMacros(calories: 132, proteinGrams: 22, carbohydrateGrams: 7, fatGrams: 2),
                             servingLabel: "1 serving", servingGrams: 113, source: .barcode, addedAt: now,
                             standsFor: [MyFoods.key("roasted chicken")])
        XCTAssertNil(MyFoods.match("Tomato", in: [tenders], now: now), "a tomato was logged as these")
        XCTAssertNil(MyFoods.match("basil", in: [tenders], now: now))
        XCTAssertEqual(MyFoods.match("chicken tenders", in: [tenders], now: now)?.id, tenders.id)
        XCTAssertEqual(MyFoods.match("Roasted chicken", in: [tenders], now: now)?.id, tenders.id, "you said so")
    }

    func testWhatAnItemWasCalledIsRememberedOnce() {
        var food = MyFoods.noting(gnocchi(), standsFor: "Pumpkin gnocchi with sage")
        food = MyFoods.noting(food, standsFor: "pumpkin gnocchi with sage")
        food = MyFoods.noting(food, standsFor: "Trader Joe's Pumpkin Gnocchi")
        XCTAssertEqual(food.standsFor, [MyFoods.key("Pumpkin gnocchi with sage")])
    }

    /// A scan that replaced "Pasta" mustn't make every pasta — a restaurant's included — your
    /// gnocchi: a name is remembered only when it shares a word with the food's.
    func testAGenericNameWithNoWordInCommonIsntLearned() {
        let food = MyFoods.noting(gnocchi(), standsFor: "Pasta")
        XCTAssertTrue(food.standsFor.isEmpty)
        XCTAssertNil(MyFoods.match("pasta", in: [food], now: now))
    }

    func testOldRecordsDecodeAndUsesAreNotStored() throws {
        let json = #"{"id":"\#(UUID().uuidString)","name":"Gnocchi","per100g":{"calories":150}}"#
        let food = try JSONDecoder().decode(MyFood.self, from: Data(json.utf8))
        XCTAssertEqual(food.servingLabel, "1 serving")
        XCTAssertEqual(food.source, .label)
        let encoded = try JSONEncoder().encode(gnocchi(uses: [MyFood.Use(at: now, grams: 200)]))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("uses"))
    }

    func testAsADatabaseFoodItsServingAndPackageAreMeasures() {
        let food = gnocchi()
        let match = MyFoods.foodMatch(food)
        XCTAssertEqual(match.portions, [FoodPortion(label: "1 cup", grams: 140), FoodPortion(label: "1 package", grams: 420)])
        XCTAssertEqual(MyFoods.food(id: food.reference.id, in: [food])?.reference, food.reference)
        XCTAssertNil(MyFoods.food(id: "fndds:123", in: [food]))
        XCTAssertEqual(food.reference.sourceName, "your foods")
    }

    func testATypedItemIsYourFoodAtTheAmountSaidOrYourUsual() throws {
        let food = gnocchi(uses: [MyFood.Use(at: daysAgo(1), grams: 210)])
        let said = try XCTUnwrap(MyFoods.item(name: "pumpkin gnocchi", quantity: "2 cups", in: [food], now: now))
        XCTAssertEqual(said.grams, 280)
        XCTAssertEqual(said.macros.calories, 420, accuracy: 0.001)
        XCTAssertEqual(said.reference?.id, food.reference.id)
        let usual = try XCTUnwrap(MyFoods.item(name: "gnocchi", quantity: "", in: [food], now: now))
        XCTAssertEqual(usual.grams, 210)
        XCTAssertEqual(usual.serving, "your usual · 210 g")
        XCTAssertEqual(usual.confidence, 1)
        XCTAssertNil(MyFoods.item(name: "rice", quantity: "1 cup", in: [food], now: now))
    }
}

/// Which item a scan corrects, and how much of it there was.
final class ScanCorrectionTests: XCTestCase {
    private let food = "Trader Joe's Pumpkin Gnocchi"

    private func items(_ names: String...) -> [(id: UUID, name: String)] {
        names.map { (UUID(), $0) }
    }

    func testTheItemThatIsThatFood() {
        let meal = items("Gnocchi", "Tomato sauce", "Parmesan")
        XCTAssertEqual(ScanCorrection.target(foodName: food, items: meal), .item(meal[0].id))
    }

    /// Gnocchi is pasta; the sauce only shares "pumpkin".
    func testTheSameKindOfFoodOverASharedWord() {
        let meal = items("Pumpkin cream sauce", "Pasta", "Side salad")
        XCTAssertEqual(ScanCorrection.target(foodName: food, items: meal), .item(meal[1].id))
        XCTAssertEqual(ScanCorrection.ranked(foodName: food, items: meal).first, meal[1].id)
    }

    func testAMealOfOneIsThatItem() {
        let meal = items("Chicken stir fry")
        XCTAssertEqual(ScanCorrection.target(foodName: food, items: meal), .item(meal[0].id))
    }

    func testNothingClearAsks() {
        XCTAssertEqual(ScanCorrection.target(foodName: food, items: items("Side salad", "Chicken breast")), .ask)
        // Only a shared describing word: not enough to replace without asking.
        XCTAssertEqual(ScanCorrection.target(foodName: food, items: items("Pumpkin soup", "Bread")), .ask)
        // Two of the kind, neither closer.
        XCTAssertEqual(ScanCorrection.target(foodName: food, items: items("Spaghetti", "Penne")), .ask)
        XCTAssertEqual(ScanCorrection.target(foodName: food, items: []), .ask)
    }

    func testANameItStoodInForBefore() {
        let meal = items("Dumplings", "Broccoli")
        XCTAssertEqual(ScanCorrection.target(foodName: food, standsFor: [MyFoods.key("Dumplings")], items: meal),
                       .item(meal[0].id))
    }

    func testWhereTheAmountStartsFrom() {
        let now = Date()
        var food = MyFood(name: food, per100g: .init(calories: 150), servingLabel: "1 cup", servingGrams: 140, source: .label)
        XCTAssertEqual(ScanCorrection.startingGrams(photoServings: nil, food: food, estimatedGrams: nil, now: now), 140)
        XCTAssertEqual(ScanCorrection.startingGrams(photoServings: nil, food: food, estimatedGrams: 180, now: now), 180)
        food.uses = [MyFood.Use(at: now, grams: 210)]
        XCTAssertEqual(ScanCorrection.startingGrams(photoServings: nil, food: food, estimatedGrams: 180, now: now), 210)
        XCTAssertEqual(ScanCorrection.startingGrams(photoServings: 2, food: food, estimatedGrams: 180, now: now), 280)
    }
}

/// The estimate uses your foods before the database.
final class GroundedEstimateMyFoodsTests: XCTestCase {
    private let now = Date()

    private lazy var gnocchi = MyFood(
        name: "Trader Joe's Pumpkin Gnocchi",
        per100g: NutritionMacros(calories: 150, proteinGrams: 3.6, carbohydrateGrams: 28.6, fatGrams: 2.5),
        servingLabel: "1 cup", servingGrams: 140, packageGrams: 420, source: .label,
        uses: [MyFood.Use(at: now, grams: 210), MyFood.Use(at: now, grams: 210)])

    private func part(_ name: String, grams: Double, portion: String) -> GroundedFoodEstimate.ModelPart {
        GroundedFoodEstimate.ModelPart(name: name, foodID: "fndds:11111", grams: grams, portion: portion,
                                       ownEstimate: .init(calories: 300), confidence: 0.5)
    }

    func testYourFoodAtYourUsualWhenThePhotoGuessIsClose() throws {
        let foods = [gnocchi]
        let parts = GroundedFoodEstimate.preferringMine([part("gnocchi", grams: 180, portion: "1 plate"),
                                                         part("side salad", grams: 80, portion: "1 bowl")],
                                                        myFoods: foods, amountsFromWords: false, now: now)
        XCTAssertEqual(parts[0].foodID, gnocchi.reference.id)
        XCTAssertEqual(parts[0].grams, 210)
        XCTAssertEqual(parts[1].foodID, "fndds:11111")
        let item = try XCTUnwrap(GroundedFoodEstimate.resolve(Array(parts.prefix(1)),
                                                               lookup: GroundedFoodEstimate.lookup(foods)).first)
        XCTAssertEqual(item.reference?.name, "Trader Joe's Pumpkin Gnocchi")
        XCTAssertEqual(item.grams, 210)
        XCTAssertEqual(item.macros.calories, 315, accuracy: 0.001)
        XCTAssertEqual(item.serving, "your usual · 210 g")
    }

    func testTheAmountSaidWinsOverYourUsual() throws {
        let foods = [gnocchi]
        let parts = GroundedFoodEstimate.preferringMine([part("pumpkin gnocchi", grams: 300, portion: "1 cup")],
                                                        myFoods: foods, amountsFromWords: true, now: now)
        let item = try XCTUnwrap(GroundedFoodEstimate.resolve(parts, lookup: GroundedFoodEstimate.lookup(foods)).first)
        XCTAssertEqual(item.grams, 140)
        XCTAssertEqual(item.macros.calories, 210, accuracy: 0.001)
    }

    /// Twice the usual or more on the plate is a different meal, not noise.
    func testAPortionFarFromYourUsualStands() {
        let parts = GroundedFoodEstimate.preferringMine([part("gnocchi", grams: 600, portion: "")],
                                                        myFoods: [gnocchi], amountsFromWords: false, now: now)
        XCTAssertEqual(parts[0].foodID, gnocchi.reference.id)
        XCTAssertEqual(parts[0].grams, 600)
        XCTAssertEqual(MyFoods.grams(estimated: 100, usual: 210), 100)
        XCTAssertEqual(MyFoods.grams(estimated: nil, usual: 210), 210)
        XCTAssertEqual(MyFoods.grams(estimated: 150, usual: nil), 150)
    }

    func testTheModelIsToldYourUsualFoodsBriefly() {
        let prompt = GroundedFoodEstimate.sketchPrompt(note: "", eatenAt: now, photoCount: 1,
                                                       usual: (1...20).map { "Food \($0)" })
        XCTAssertTrue(prompt.contains("Food 12;") || prompt.contains("Food 12."))
        XCTAssertFalse(prompt.contains("Food 13"))
        XCTAssertFalse(GroundedFoodEstimate.sketchPrompt(note: "", eatenAt: now, photoCount: 1).contains("often have"))
    }
}
