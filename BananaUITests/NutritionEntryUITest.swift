import XCTest

/// Every way to log food on the phone opens the one meal sheet the iPad and the Mac open. Scan
/// and "Enter by hand" opened an older sheet of the phone's own: no amount control, and a package
/// it scanned never became one of your foods.
final class NutritionEntryUITest: XCTestCase {
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--wellness", "--disable-icloud", "--no-space-sync", "--ui-audit", "-onboardingCompleted", "YES"]
        app.withoutSpaceSync()
        app.launch()
        return app
    }

    func testScanOpensTheSharedScanSheet() {
        let app = launch()
        XCTAssertTrue(app.plus("wellness.add").waitForExistence(timeout: 10), app.debugDescription)
        app.plus("wellness.add").tap()
        let scan = app.buttons["wellness.barcodeMeal"]
        XCTAssertTrue(scan.waitForExistence(timeout: 4), app.debugDescription)
        scan.tap()
        XCTAssertTrue(app.navigationBars["Scan a package"].waitForExistence(timeout: 5), app.debugDescription)
        // The label can be photographed where the camera can't scan (a Simulator has no camera).
        XCTAssertTrue(app.buttons["scan.labelPhoto"].firstMatch.exists)
    }

    func testEnterByHandOpensABlankRowInTheSharedSheet() {
        let app = launch()
        XCTAssertTrue(app.plus("wellness.add").waitForExistence(timeout: 10), app.debugDescription)
        app.plus("wellness.add").tap()
        let byHand = app.buttons["wellness.manualMeal"]
        XCTAssertTrue(byHand.waitForExistence(timeout: 4), app.debugDescription)
        byHand.tap()
        let name = app.textFields["foodText.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5), "one blank row, open\n\(app.debugDescription)")
        // The amount is its own control here, which the older sheet didn't have.
        XCTAssertTrue(app.descendants(matching: .any)["foodText.editor"].exists)
    }
}
