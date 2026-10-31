import XCTest

/// On a phone the + is the tab bar's own, at the end of its row: the system keeps it there as the
/// bar shrinks, and it opens one list of everything that can be added. It takes one of the bar's
/// five places, so Workouts and Nutrition share the Body tab.
final class AddButtonRowUITest: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// The + is the page's, in its top bar, and opens the one list of everything. It was the tab
    /// bar's search slot: iOS took a tap there as going to a page, slid the selection across,
    /// flashed that empty page and snapped back before the list came up.
    func testThePlusIsInThePagesBarAndOpensOneList() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "the phone's shell")
        let app = launch()
        let add = app.buttons["wellness.add"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertFalse(app.tabBars.buttons["Add"].exists, "the tab bar has no + of its own")
        XCTAssertLessThan(add.frame.midY, app.windows.firstMatch.frame.height * 0.2, "the + is in the top bar")

        add.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "page.add.list").firstMatch.waitForExistence(timeout: 5))
        app.buttons["wellness.manualMeal"].tap()
        // A freshly erased simulator shows Apple's typing introduction on the first
        // focused field. Dismiss it before querying the editor underneath it.
        let typingIntroduction = app.staticTexts.matching(NSPredicate(format:
            "label BEGINSWITH %@", "Speed up your typing")).firstMatch
        if typingIntroduction.waitForExistence(timeout: 3) {
            app.buttons["Continue"].tap()
        }
        // Wait for each destination control independently: after Apple's keyboard introduction,
        // querying both full hierarchies in one five-second predicate can consume its deadline.
        XCTAssertTrue(app.navigationBars["New meal"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "page.add.list").firstMatch.exists)
        XCTAssertTrue(app.textFields["foodText.name"].waitForExistence(timeout: 5), app.debugDescription)
    }

    func testDescribeOpensThePhraseEditor() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "the phone's global Add list")
        let app = launch()
        let add = app.buttons["wellness.add"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 20))
        add.tap()
        let describe = app.buttons["wellness.textMeal"]
        XCTAssertTrue(describe.waitForExistence(timeout: 5))
        describe.tap()
        XCTAssertTrue(app.descendants(matching: .any)["foodText.phrase"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["page.add.list"].exists)
        XCTAssertTrue(app.buttons["capture.recentMeals"].exists)
    }

    func testWorkoutsAndNutritionShareTheBodyTab() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "an iPad's tab bar is at the top")
        let app = launch()
        let bar = app.tabBars.firstMatch
        XCTAssertTrue(bar.buttons["Body"].waitForExistence(timeout: 20), app.debugDescription)
        for tab in ["Plan", "Notes", "Library"] {
            XCTAssertTrue(bar.buttons[tab].exists, "\(tab) has its own place: \(bar.debugDescription)")
        }
        for gone in ["Browse", "Workouts", "Nutrition", "More", "Add"] {
            XCTAssertFalse(bar.buttons[gone].exists, "\(gone) is not on the bar")
        }

        // One switch across both pages, where the title was.
        let pages = app.segmentedControls["body.switch"]
        XCTAssertTrue(pages.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(pages.buttons.count, 3)
        XCTAssertTrue(pages.buttons.element(boundBy: 1).isSelected, "opened on Food")
        pages.buttons["Workouts"].tap()
        wait("Workouts shows, under the same tab") {
            app.segmentedControls["body.switch"].buttons["Workouts"].isSelected && bar.buttons["Body"].isSelected
        }
        app.segmentedControls["body.switch"].buttons.element(boundBy: 2).tap()
        wait("Taken shows") { app.segmentedControls["body.switch"].buttons.element(boundBy: 2).isSelected }

        // The tab comes back to the page last looked at.
        bar.buttons["Notes"].tap()
        wait("Notes opens") { bar.buttons["Notes"].isSelected }
        bar.buttons["Body"].tap()
        wait("Body is back on Taken") { app.segmentedControls["body.switch"].buttons.element(boundBy: 2).isSelected }
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview", "--tab", "nutrition", "--store-capture", "--disable-icloud", "--no-space-sync",
                               "-onboardingCompleted", "YES"]
        app.withoutSpaceSync()
        app.launch()
        return app
    }

    private func wait(_ what: String, timeout: TimeInterval = 5, _ ready: @escaping () -> Bool,
                      file: StaticString = #filePath, line: UInt = #line) {
        let done = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in ready() }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [done], timeout: timeout), .completed, what, file: file, line: line)
    }
}
