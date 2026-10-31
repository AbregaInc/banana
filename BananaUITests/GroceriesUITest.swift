import XCTest

/// After shopping: My foods › Scan what you bought keeps scanning, each package joins your foods
/// once however often it's read, and what you bought is suggested when you log a meal.
/// `--grocery-codes` reads barcodes from the bundled catalog as the camera would (the Simulator
/// has no camera): Trader Joe's Greek yogurt twice, and dried bananas.
final class GroceriesUITest: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "the phone's Food page")
        continueAfterFailure = false
    }

    func testScannedGroceriesJoinYourFoodsAndAreSuggested() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview", "--tab", "nutrition", "--wellness",
                               "--grocery-codes", "00772914,00646659,00772914",
                               "--disable-icloud", "--no-space-sync", "--ui-audit", "-onboardingCompleted", "YES"]
        app.withoutSpaceSync()
        app.launch()
        // Opened as a person opens it: `--my-foods` opens it at launch, and the top bar's + then
        // misses its first tap after it closes (only on that debug path).
        openMyFoods(app)

        let scan = app.buttons["myFoods.scan"]
        XCTAssertTrue(scan.waitForExistence(timeout: 20), app.debugDescription)
        scan.tap()
        let rows = app.descendants(matching: .any).matching(identifier: "groceries.row")
        XCTAssertTrue(app.navigationBars["Groceries"].waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil(timeout: 20) {
            rows.count == 2 && rows.allElementsBoundByIndex.allSatisfy { $0.label.contains("Added") }
        }, "two packages, the yogurt once\n\(app.debugDescription)")
        app.buttons["Done"].firstMatch.tap()

        // In your foods, bought today.
        let yogurt = app.descendants(matching: .any).matching(identifier: "myFoods.row")
            .matching(NSPredicate(format: "label CONTAINS[c] 'greek yogurt'")).firstMatch
        XCTAssertTrue(yogurt.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(yogurt.label.contains("bought"), yogurt.label)
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !yogurt.exists }, "My foods didn't close")

        // Suggested when you describe a meal, before you've had any.
        let add = app.plus("wellness.add")
        add.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "page.add.list").firstMatch.waitForExistence(timeout: 10))
        let describe = app.buttons.matching(NSPredicate(format: "label == 'Describe'")).firstMatch
        XCTAssertTrue(describe.waitForExistence(timeout: 10), app.debugDescription)
        describe.tap()
        let suggested = app.buttons.matching(identifier: "foodText.usual")
            .matching(NSPredicate(format: "label CONTAINS[c] 'greek yogurt'")).firstMatch
        XCTAssertTrue(suggested.waitForExistence(timeout: 10), app.debugDescription)
    }

    /// Photos picked from Photos instead of the camera (`--grocery-photo-codes` stands in for the
    /// picker): one with no barcode waits for its label to be read. (The Simulator can't read a
    /// barcode off a photo; `PackagePhotoTests` covers that.)
    func testAPhotoWithNoBarcodeWaitsForItsLabel() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview", "--tab", "nutrition", "--wellness",
                               "--grocery-photo-codes", "-",
                               "--disable-icloud", "--no-space-sync", "--ui-audit", "-onboardingCompleted", "YES"]
        app.withoutSpaceSync()
        app.launch()
        openMyFoods(app)
        let scan = app.buttons["myFoods.scan"]
        XCTAssertTrue(scan.waitForExistence(timeout: 20), app.debugDescription)
        scan.tap()

        XCTAssertTrue(app.descendants(matching: .any)["groceries.photos"].waitForExistence(timeout: 10), app.debugDescription)
        let rows = app.descendants(matching: .any).matching(identifier: "groceries.row")
        XCTAssertTrue(waitUntil(timeout: 20) {
            rows.count == 1 && rows.firstMatch.label.contains("No barcode in it")
        }, app.debugDescription)
    }

    /// My foods is lower down the Food page's list, which builds its rows as they come into view.
    private func openMyFoods(_ app: XCUIApplication) {
        XCTAssertTrue(app.descendants(matching: .any)["nutrition.day"].waitForExistence(timeout: 20), app.debugDescription)
        let myFoods = app.descendants(matching: .any).matching(identifier: "wellness.myFoods").firstMatch
        for _ in 0..<8 where !(myFoods.exists && myFoods.isHittable) { app.swipeUp() }
        XCTAssertTrue(myFoods.waitForExistence(timeout: 5), app.debugDescription)
        myFoods.tap()
    }
}
