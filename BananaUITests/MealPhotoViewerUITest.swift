import XCTest

/// Tapping a meal photo in Nutrition shows it full size — driven for real, because the photo
/// sits inside a row that opens the meal's editor on tap, and only a real tap shows which one
/// wins. Then: swipe to the meal's next photo, close with ✕, close by pulling down.
final class MealPhotoViewerUITest: XCTestCase {

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--wellness", "--meal-backlog", "--disable-icloud", "--no-space-sync", "--ui-audit",
                               "-onboardingCompleted", "YES"]
        app.withoutSpaceSync()
        app.launch()
        return app
    }

    /// Its close button: there whenever the viewer is.
    private func viewer(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["mealPhoto.close"]
    }

    private func counter(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.staticTexts[text]
    }

    /// The logged meal's photo: the row's thumbnail sits after the time column.
    private func tapLoggedMealPhoto(_ app: XCUIApplication) {
        // Below "To log" in a lazy list: scroll until the row exists.
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Chicken grain bowl")).firstMatch
        _ = app.descendants(matching: .any).matching(identifier: "mealPhoto.thumb").firstMatch.waitForExistence(timeout: 10)
        for _ in 0..<6 where !(row.exists && row.isHittable) { app.swipeUp() }
        XCTAssertTrue(row.exists, app.debugDescription)
        let thumbs = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@ AND label BEGINSWITH %@", "mealPhoto.thumb", "Photo"))
        if let thumb = thumbs.allElementsBoundByIndex.first(where: {
            $0.exists && abs($0.frame.midY - row.frame.midY) < row.frame.height / 2
        }) {
            thumb.tap()
        } else {
            // Not separately exposed inside the row's button: tap where it's drawn (time column
            // 58 pt, then a 12 pt gap, then the 36 pt photo).
            row.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
                .withOffset(CGVector(dx: 58 + 12 + 18, dy: 0)).tap()
        }
    }

    func testALoggedMealsPhotoOpensFullSizeNotTheEditor() {
        let app = launch()
        tapLoggedMealPhoto(app)

        XCTAssertTrue(viewer(app).waitForExistence(timeout: 4), "tapping the photo must show it full size")
        XCTAssertFalse(app.staticTexts["Greek yogurt"].exists, "and not open the meal's editor")
        XCTAssertTrue(counter(app, "1 of 2").exists)

        app.swipeLeft()
        XCTAssertTrue(counter(app, "2 of 2").waitForExistence(timeout: 3), "swiping shows the meal's next photo")

        app.buttons["mealPhoto.close"].tap()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: viewer(app))
        waitForExpectations(timeout: 3)
        XCTAssertFalse(app.staticTexts["Greek yogurt"].exists, "closing it leaves Nutrition as it was")
    }

    func testPullingDownClosesIt() {
        let app = launch()
        tapLoggedMealPhoto(app)
        XCTAssertTrue(viewer(app).waitForExistence(timeout: 4))

        let middle = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        middle.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)),
                     withVelocity: .fast, thenHoldForDuration: 0)
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: viewer(app))
        waitForExpectations(timeout: 3)
    }

    func testAPhotoWaitingToBeLoggedOpensToo() {
        let app = launch()
        let thumbs = app.descendants(matching: .any).matching(identifier: "mealPhoto.thumb")
        XCTAssertTrue(thumbs.firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        // The last one on screen is in "To log", below the day's logged meals.
        for _ in 0..<4 where !thumbs.allElementsBoundByIndex.contains(where: { $0.isHittable }) { app.swipeUp() }
        guard let thumb = thumbs.allElementsBoundByIndex.last(where: { $0.isHittable }) else {
            return XCTFail("no meal photo on screen\n\(app.debugDescription)")
        }
        thumb.tap()
        XCTAssertTrue(viewer(app).waitForExistence(timeout: 4))
    }
}
