import XCTest

/// One item of a meal scanned from its package: the scan replaces the item it was asked for,
/// whatever the names say — here the side salad, though the food is gnocchi.
final class ScanOneItemUITest: XCTestCase {
    func testScanningForOneItemReplacesThatItem() {
        let app = XCUIApplication()
        app.launchArguments = ["--scan-correct-preview", "--disable-icloud", "--no-space-sync", "--ui-audit", "-onboardingCompleted", "YES"]
        app.withoutSpaceSync()
        app.launch()

        XCTAssertTrue(app.staticTexts["Gnocchi"].waitForExistence(timeout: 10), app.debugDescription)
        // A Form is lazy: a row scrolled past is absent, not just off screen.
        func reveal(_ element: XCUIElement) {
            var swipes = 0
            while !(element.exists && element.isHittable), swipes < 6 { app.swipeUp(); swipes += 1 }
        }
        let scanItem = app.buttons.matching(NSPredicate(format: "identifier == %@ AND value == %@",
                                                        "foodText.scanItem", "Side salad")).firstMatch
        reveal(scanItem)
        if !scanItem.exists {
            // Closed: open the salad's row first.
            let salad = app.staticTexts["Side salad"]
            reveal(salad)
            salad.tap()
            reveal(scanItem)
        }
        XCTAssertTrue(scanItem.waitForExistence(timeout: 3), "an open item can be scanned on its own\n\(app.debugDescription)")
        scanItem.tap()

        XCTAssertTrue(app.navigationBars["Scan for Side salad"].waitForExistence(timeout: 5), app.debugDescription)
        let mine = app.buttons["scan.myFood"].firstMatch
        XCTAssertTrue(mine.waitForExistence(timeout: 5))
        mine.tap()

        XCTAssertTrue(app.staticTexts["Trader Joe's Pumpkin Gnocchi"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Side salad"].exists, "the item it was scanned for is the one replaced")
        XCTAssertFalse(app.buttons["scan.choose"].exists, "and it didn't ask which")
    }

    func testAReviewItemOffersItsOwnScan() {
        let app = XCUIApplication()
        app.launchArguments = ["--wellness", "--meal-backlog", "--meal-review", "--disable-icloud", "--no-space-sync", "-onboardingCompleted", "YES"]
        app.withoutSpaceSync()
        app.launch()

        let rice = app.buttons.matching(identifier: "mealReview.food").matching(NSPredicate(format: "label CONTAINS %@", "White rice")).firstMatch
        // `--meal-review` opens the day's review at launch; now and then a sheet asked for that
        // early isn't shown, and the page's own row opens it as a finger would.
        if !rice.waitForExistence(timeout: 6) {
            let day = app.buttons["mealInbox.reviewDay"].firstMatch
            if day.waitForExistence(timeout: 5) { day.tap() }
        }
        XCTAssertTrue(rice.waitForExistence(timeout: 10), app.debugDescription)
        rice.tap()
        let scan = app.buttons["Scan its package"]
        XCTAssertTrue(scan.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.buttons["Take it out"].exists)
        scan.tap()
        XCTAssertTrue(app.navigationBars["Scan for White rice"].waitForExistence(timeout: 5), app.debugDescription)
    }
}
