import XCTest

/// Exercises the real bundled `GenericFoods.json` — not a fixture — so a bad number typed into
/// the table fails the build. `GenericFoodCatalog.loadTable(from:)` is given the *test* bundle
/// explicitly: `GenericFoodCatalog.match(name:)`'s own default reads from `Bundle.main`, which
/// inside the test host doesn't carry the resource (mirrors `BarcodeProductLookup`'s explicit
/// `databaseURL` testing seam).
final class GenericFoodCatalogTests: XCTestCase {
    private func loadedTable() throws -> GenericFoodTable {
        try XCTUnwrap(GenericFoodCatalog.loadTable(from: Bundle(for: Self.self)))
    }

    func testBundledCatalogLoadsAndHasSubstantialCoverage() throws {
        let table = try loadedTable()
        XCTAssertGreaterThanOrEqual(table.foods.count, 150)
        XCTAssertFalse(table.source.isEmpty)
    }

    /// Spot-checks a handful of foods against their true USDA-sourced values. A typo in the JSON
    /// (a fat-fingered digit, a shifted decimal) fails one of these.
    func testKnownFoodsMatchTrueUSDAValues() throws {
        let table = try loadedTable()

        let egg = try XCTUnwrap(GenericFoodCatalog.match(name: "egg", in: table))
        XCTAssertEqual(egg.unitMacros.calories, 72, accuracy: 0.5)
        XCTAssertEqual(egg.unitMacros.proteinGrams, 6.3, accuracy: 0.1)

        let banana = try XCTUnwrap(GenericFoodCatalog.match(name: "banana", in: table))
        XCTAssertEqual(banana.unitMacros.calories, 105, accuracy: 0.5)
        XCTAssertEqual(banana.unitMacros.carbohydrateGrams, 27, accuracy: 0.5)

        let apple = try XCTUnwrap(GenericFoodCatalog.match(name: "apple", in: table))
        XCTAssertEqual(apple.unitMacros.calories, 95, accuracy: 0.5)

        let coffee = try XCTUnwrap(GenericFoodCatalog.match(name: "black coffee", in: table))
        XCTAssertEqual(coffee.unitMacros.calories, 2, accuracy: 0.5)

        let oliveOil = try XCTUnwrap(GenericFoodCatalog.match(name: "olive oil", in: table))
        XCTAssertEqual(oliveOil.unitMacros.calories, 119, accuracy: 0.5)
        XCTAssertEqual(oliveOil.unitMacros.fatGrams, 13.5, accuracy: 0.1)

        let chickenBreast = try XCTUnwrap(GenericFoodCatalog.match(name: "chicken breast", in: table))
        XCTAssertEqual(chickenBreast.unitMacros.proteinGrams, 26, accuracy: 0.5)
        XCTAssertEqual(chickenBreast.unitMacros.carbohydrateGrams, 0, accuracy: 0.01)
    }

    func testUnknownFoodReturnsNil() throws {
        let table = try loadedTable()
        XCTAssertNil(GenericFoodCatalog.match(name: "xyz-not-a-real-food-123", in: table))
    }

    /// The longer, more specific alternative name wins when an extracted name could plausibly
    /// match two rows — e.g. "wheat toast" also contains "toast" (a plain-white-bread alt name).
    func testLongestMatchingNameWinsOverAShorterGenericOne() throws {
        let table = try loadedTable()

        let plainToast = try XCTUnwrap(GenericFoodCatalog.match(name: "toast", in: table))
        let wheatToast = try XCTUnwrap(GenericFoodCatalog.match(name: "wheat toast", in: table))
        XCTAssertNotEqual(plainToast.unitLabel, wheatToast.unitLabel)

        let almondMilk = try XCTUnwrap(GenericFoodCatalog.match(name: "almond milk", in: table))
        XCTAssertTrue(almondMilk.names.contains("almond milk"))
    }

    func testNoDuplicateAlternativeNamesAcrossRows() throws {
        let table = try loadedTable()
        var seen = Set<String>()
        for food in table.foods {
            for name in food.names {
                XCTAssertTrue(seen.insert(name).inserted, "duplicate alt-name across rows: \(name)")
            }
        }
    }

    // MARK: - Whole words, not substrings

    func testAFoodInsideAnotherWordIsNotThatFood() throws {
        let table = try loadedTable()
        // Each was matched at full confidence: an egg, a tablespoon of butter, a cup of corn.
        XCTAssertNil(GenericFoodCatalog.match(name: "eggplant", in: table))
        XCTAssertNil(GenericFoodCatalog.match(name: "buttermilk", in: table))
        XCTAssertNil(GenericFoodCatalog.match(name: "cornbread", in: table))
    }

    func testAPluralAndExtraWordsStillMatch() throws {
        let table = try loadedTable()
        let egg = try XCTUnwrap(GenericFoodCatalog.match(name: "egg", in: table))
        XCTAssertEqual(GenericFoodCatalog.match(name: "Eggs", in: table), egg)
        XCTAssertEqual(GenericFoodCatalog.match(name: "two scrambled eggs", in: table), egg)
        let almonds = try XCTUnwrap(GenericFoodCatalog.match(name: "almonds", in: table))
        XCTAssertEqual(GenericFoodCatalog.match(name: "almond", in: table), almonds)
    }

    func testEveryNameInTheCatalogFindsItsOwnRow() throws {
        // The reading of words is the same for what's typed and for the catalog: no row is lost
        // to it.
        let table = try loadedTable()
        for food in table.foods {
            for name in food.names {
                XCTAssertNotNil(GenericFoodCatalog.match(name: name, in: table), name)
            }
        }
    }

    func testALabelThatIsNotAnAmountIsOneOfIt() throws {
        // "large egg", "2-inch slice (28 g)": no amount to read, so a number said is that many.
        let table = try loadedTable()
        let unread = table.foods.filter { $0.unitQuantity == nil }
        XCTAssertFalse(unread.isEmpty)
        for food in unread {
            XCTAssertEqual(food.units(in: FoodPhrase.quantity("2")), 2, food.unitLabel)
            XCTAssertEqual(food.units(in: nil), 1, food.unitLabel)
        }
        // And every label that does state a weight gives it.
        for food in table.foods where food.unitLabel.contains(" g)") {
            XCTAssertNotNil(food.unitGrams, food.unitLabel)
        }
    }
}
