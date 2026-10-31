import XCTest

/// Adding a food by searching for it (`FoodSearchView`), driven for real: typed words find the
/// bundled USDA food, its amount is chosen, and it lands in the meal as a row.
final class FoodSearchUITest: XCTestCase {
    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        // No iCloud from an unsigned Simulator app (see MealEditorUITest).
        app.launchArguments = arguments + ["--disable-icloud", "--no-space-sync", "--ui-audit", "-onboardingCompleted", "YES"]
        app.withoutSpaceSync()
        app.launch()
        return app
    }

    /// Search, in the page's + menu (it was a tile in the list, a scroll away).
    private func searchFoods(_ app: XCUIApplication) -> XCUIElement {
        let add = app.plus("wellness.add")
        if add.waitForExistence(timeout: 8) { add.tap() }
        let button = app.buttons["wellness.searchFood"]
        _ = button.waitForExistence(timeout: 4)
        return button
    }

    func testAFoodSearchedForIsAddedToTheMealAtTheAmountChosen() {
        let app = launch(["--wellness", "--meal-editor-preview"])
        XCTAssertTrue(scrolledTo(app.staticTexts["Greek yogurt"], in: app), app.debugDescription)
        let add = app.buttons["foodText.addItem"]
        if !add.waitForExistence(timeout: 2) { app.swipeUp() }
        add.tap()

        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.typeText("baby carrots")
        let carrots = app.staticTexts["Carrots, baby, raw"]
        XCTAssertTrue(carrots.waitForExistence(timeout: 8), "USDA's baby carrots, found offline")
        carrots.tap()

        let addButton = app.buttons["foodAmount.add"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 3), "a food opens on how much")
        // The meal's own rows, under the sheet, have the same amount control: the one on screen.
        let more = app.buttons.matching(identifier: "foodAmount.stepper-Increment").allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(more)
        more?.tap()   // 100 g → 110 g
        XCTAssertTrue(app.staticTexts["110 g"].waitForExistence(timeout: 2))
        addButton.tap()

        XCTAssertTrue(app.staticTexts["Carrots, baby, raw"].waitForExistence(timeout: 4), "the food is a row of the meal")
        XCTAssertFalse(app.searchFields.firstMatch.exists, "the search closed")
    }

    func testSearchFoodsStartsAMealFromWhatsPicked() {
        let app = launch(["--wellness"])
        let search = searchFoods(app)
        XCTAssertTrue(search.exists)
        search.tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3), "the search opens at once")
        field.typeText("scallops")
        let quickAdd = app.buttons["foodSearch.quickAdd"].firstMatch
        XCTAssertTrue(quickAdd.waitForExistence(timeout: 8))
        quickAdd.tap()

        let save = app.navigationBars["New meal"].buttons["Save"]
        XCTAssertTrue(save.waitForExistence(timeout: 3))
        XCTAssertTrue(save.isEnabled, "a searched food needs no \u{201C}I reviewed this\u{201D}")
        XCTAssertTrue(app.staticTexts["1 item"].exists)
        app.navigationBars["New meal"].buttons["Cancel"].tap()   // nothing logged by a test
    }

    func testCancellingTheFirstSearchLeavesNoEmptyMeal() {
        let app = launch(["--wellness"])
        let search = searchFoods(app)
        XCTAssertTrue(search.exists)
        search.tap()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 3))
        app.navigationBars["Add food"].buttons["Cancel"].tap()
        XCTAssertTrue(app.plus("wellness.add").waitForExistence(timeout: 3), "back on Nutrition, not on an empty meal")
        XCTAssertFalse(app.navigationBars["New meal"].waitForExistence(timeout: 2))
    }

    /// The list is lazy and the estimated row opens itself above: a row can start below the fold.
    private func scrolledTo(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        if element.waitForExistence(timeout: 8) { return true }
        app.swipeUp(velocity: .slow)
        return element.waitForExistence(timeout: 3)
    }
}
