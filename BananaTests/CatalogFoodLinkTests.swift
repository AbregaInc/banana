import XCTest

final class CatalogFoodLinkTests: XCTestCase {
    private let egg = FoodMatch(
        reference: FoodReference(id: "sr:1", name: "Egg, whole, raw, fresh",
                                 per100g: NutritionMacros(calories: 143, proteinGrams: 12.6, carbohydrateGrams: 0.7, fatGrams: 9.5)),
        category: "Eggs", portions: [FoodPortion(label: "1 large", grams: 50), FoodPortion(label: "1 cup", grams: 243)])

    private func catalogEggs() -> ResolvedFoodItem {
        ResolvedFoodItem(name: "eggs", serving: "2",
                         macros: NutritionMacros(calories: 144, proteinGrams: 12.6, carbohydrateGrams: 0.8, fatGrams: 9.6),
                         confidence: 1, source: .catalog)
    }

    func testACatalogFoodIsLinkedAndCountedInItsOwnMeasure() {
        let linked = CatalogFoodLink.link(catalogEggs(), search: { _ in [self.egg] })
        XCTAssertEqual(linked.reference?.id, "sr:1")
        XCTAssertEqual(linked.grams ?? 0, 100.7, accuracy: 0.5)
        XCTAssertTrue(linked.serving.hasPrefix("2 large"), linked.serving)
        XCTAssertEqual(linked.macros, catalogEggs().macros, "the numbers stay until the amount changes")
    }

    func testAMatchAboutAnotherFoodIsNotLinked() {
        let crackers = FoodMatch(reference: FoodReference(id: "sr:2", name: "Rice crackers",
                                                          per100g: NutritionMacros(calories: 400, proteinGrams: 8, carbohydrateGrams: 80, fatGrams: 4)),
                                 category: "Snacks", portions: [])
        let linked = CatalogFoodLink.link(catalogEggs(), search: { _ in [crackers] })
        XCTAssertNil(linked.reference)
        XCTAssertEqual(linked.serving, "2")
    }

    func testOnlyCatalogRowsAreLinked() {
        var estimate = catalogEggs(); estimate.source = .aiEstimate
        XCTAssertNil(CatalogFoodLink.link(estimate, search: { _ in [self.egg] }).reference)
    }

    func testHeadWordAndCount() {
        XCTAssertEqual(CatalogFoodLink.headWord("eggs"), "egg")
        XCTAssertEqual(CatalogFoodLink.headWord("a ripe banana"), "banana")
        XCTAssertEqual(CatalogFoodLink.headWord("berries"), "berry")
        XCTAssertEqual(CatalogFoodLink.leadingCount("2 large"), 2)
        XCTAssertNil(CatalogFoodLink.leadingCount("a cup"))
    }
}

/// What an agent's event draft takes from the words when the model left the place out.
final class EventWordsLocationTests: XCTestCase {
    func testThePlaceSaidAfterTheTimeIsRead() {
        XCTAssertEqual(EventPhrase.parse("Dinner with Noor at 5 at Taco Bell").location, "Taco Bell")
    }
}

/// One field for where: a link is the video call, a place is a place.
final class EventWhereTests: XCTestCase {
    func testLinksAreVideoCallsAndPlacesArePlaces() {
        XCTAssertEqual(EventWhere.link(in: "meet.google.com/abc-defg-hij"), "meet.google.com/abc-defg-hij")
        XCTAssertEqual(EventWhere.link(in: "https://zoom.us/j/123"), "https://zoom.us/j/123")
        XCTAssertEqual(EventWhere.link(in: "zoom.us"), "zoom.us")
        XCTAssertNil(EventWhere.link(in: "https://"))
        XCTAssertNil(EventWhere.link(in: "http://"))
        XCTAssertNil(EventWhere.link(in: "Taco Bell"))
        XCTAssertNil(EventWhere.link(in: "12 Main St."))
        XCTAssertNil(EventWhere.link(in: "St.Marks"))
    }
}
