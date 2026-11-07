import XCTest

/// One shell for every width (docs/design/BOTTOM-BAR-SHELL.md): on an iPad the rail lists every
/// page the Mac's does; on an iPhone the switcher at the bottom left lists the same pages, with no
/// tab bar and no "More" overflow.
final class AdaptiveShellUITest: XCTestCase {

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-preview", "--dummy-health"]
        app.withoutSpaceSync()
        app.launch()
        XCTAssertTrue(app.buttons["shell.page.plan"].waitForExistence(timeout: 30)
                      || app.buttons["shell.switcher"].waitForExistence(timeout: 5), app.debugDescription)
        return app
    }

    func testTheRailOrSwitcherShowsTheRightPages() throws {
        let app = launch()
        // The bar's switcher (a phone, an iPad upright) or the rail (an iPad on its side).
        if app.buttons["shell.switcher"].exists { app.buttons["shell.switcher"].tap() }
        for page in ["plan", "body", "notes", "library", "review", "settings"] {
            XCTAssertTrue(app.buttons["shell.page.\(page)"].waitForExistence(timeout: 5), "\(page) missing")
        }
        // Sleep and Trends had places of their own; both are inside Review.
        for gone in ["Sleep", "Trends"] {
            XCTAssertFalse(app.buttons[gone].firstMatch.exists, "\(gone) is back as a page")
        }
        XCTAssertFalse(app.tabBars.firstMatch.exists, "the tab bar is gone")
        app.buttons["shell.page.review"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["review.fitness"].firstMatch.waitForExistence(timeout: 10),
                      "Review didn't open")
    }
}
