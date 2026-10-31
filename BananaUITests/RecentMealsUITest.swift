import XCTest

final class RecentMealsUITest: XCTestCase {
    private func launch(preview: Bool, narrow: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--disable-icloud", "--no-space-sync", "--ui-audit", "--modules", "food", "-onboardingCompleted", "YES"]
        if narrow { app.launchArguments += ["--wellness"] }
        else { app.launchArguments += ["--ui-preview", "--tab", "nutrition"]; if preview { app.launchArguments += ["--wellness"] } }
        app.launch()
        return app
    }

    private func countMeals(_ app: XCUIApplication) -> Int {
        app.buttons.matching(NSPredicate(format: "identifier == 'nutrition.meal' AND label CONTAINS 'Chicken grain bowl'")).count
    }

    private func showBothMeals(_ app: XCUIApplication) -> Bool {
        // Today's later entries can fall below the lazy list's viewport. Scroll to the two
        // adjacent meal rows before counting; absent offscreen cells do not mean missing saves.
        for _ in 0..<4 {
            if countMeals(app) == 2 { return true }
            app.swipeUp(velocity: .slow)
        }
        return countMeals(app) == 2
    }

    private func repeatMeal(_ app: XCUIApplication) {
        let recent = app.buttons["nutrition.recentMeals"].firstMatch
        XCTAssertTrue(recent.waitForExistence(timeout: 15), app.debugDescription)
        recent.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("chicken grain")
        let choices = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'recentMeals.meal.'"))
        let original = choices.matching(identifier: "recentMeals.meal.BA9A9A00-0000-4000-8000-000000000001").firstMatch
        XCTAssertTrue(original.waitForExistence(timeout: 5), app.debugDescription)
        // The week fixture also has a smaller lunch with the same food; keep both portions.
        original.tap()
        XCTAssertTrue(app.buttons["toast.undo"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(showBothMeals(app), app.debugDescription)
    }

    func testRepeatedMealIsSavedAndStillPresentAfterRelaunch() {
        let app = launch(preview: true)
        repeatMeal(app)
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Past meal logged without a new photo"
        image.lifetime = .keepAlways
        add(image)
        app.terminate()
        let reopened = launch(preview: false)
        XCTAssertTrue(reopened.buttons["nutrition.recentMeals"].waitForExistence(timeout: 15))
        XCTAssertTrue(showBothMeals(reopened), reopened.debugDescription)
    }

    func testNarrowFoodPageCanRepeatAndUndoWithoutChangingOriginalMeal() {
        let app = launch(preview: true, narrow: true)
        repeatMeal(app)
        app.buttons["toast.undo"].tap()
        XCTAssertTrue(waitUntil { self.countMeals(app) == 1 }, app.debugDescription)
    }
}
