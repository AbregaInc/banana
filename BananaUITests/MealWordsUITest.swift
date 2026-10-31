import XCTest

/// What you said a meal was can be changed after it's estimated: tap the words, change them, and
/// it's estimated again — with Undo putting back the words and the estimate it had.
final class MealWordsUITest: XCTestCase {
    func testChangingTheWordsEstimatesItAgainAndUndoPutsItBack() {
        let app = XCUIApplication()
        app.launchArguments = ["--wellness", "--meal-backlog", "--meal-review", "--disable-icloud", "--no-space-sync", "-onboardingCompleted", "YES"]
        app.withoutSpaceSync()
        app.launch()

        let words = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "curry and rice from the indian place")).firstMatch
        XCTAssertTrue(words.waitForExistence(timeout: 10), "the words are there to tap\n\(app.debugDescription)")
        words.tap()

        let field = app.textViews["mealWords.field"].exists ? app.textViews["mealWords.field"] : app.textFields["mealWords.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 3), app.debugDescription)
        field.tap()
        field.press(forDuration: 1.2)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        field.typeText("lamb curry and rice")
        app.buttons["mealWords.save"].tap()

        let changed = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "lamb curry and rice")).firstMatch
        XCTAssertTrue(changed.waitForExistence(timeout: 5), "estimating again, with the new words\n\(app.debugDescription)")
        // The toast shows in the sheet and in the app beneath it: the one that can be tapped.
        XCTAssertTrue(app.buttons["toast.undo"].firstMatch.waitForExistence(timeout: 2))
        let undo = app.buttons.matching(identifier: "toast.undo").allElementsBoundByIndex.first { $0.isHittable }
            ?? app.buttons["toast.undo"].firstMatch
        undo.tap()
        XCTAssertTrue(words.waitForExistence(timeout: 5), "Undo puts the words and the estimate back")
        XCTAssertTrue(app.staticTexts["Chicken curry with rice"].exists, app.debugDescription)
    }
}
