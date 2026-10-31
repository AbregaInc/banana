import XCTest

/// One shell for every width. On an iPad the sidebar lists every section the Mac's does; on an
/// iPhone the tab bar keeps its five tabs, with no "More" overflow.
final class AdaptiveShellUITest: XCTestCase {

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-preview", "--dummy-health"]
        app.withoutSpaceSync()
        app.launch()
        XCTAssertTrue(app.buttons["Plan"].waitForExistence(timeout: 30))
        return app
    }

    func testTheSidebarOrTabBarShowsTheRightSections() throws {
        let app = launch()
        if UIDevice.current.userInterfaceIdiom == .pad {
            let toggle = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'sidebar'")).firstMatch
            XCTAssertTrue(toggle.waitForExistence(timeout: 10), "no sidebar button on iPad")
            toggle.tap()
            for section in ["Mail", "Review", "Routines", "Settings"] {
                XCTAssertTrue(app.buttons[section].firstMatch.waitForExistence(timeout: 5)
                              || app.staticTexts[section].firstMatch.exists,
                              "\(section) missing from the iPad sidebar")
            }
            // Sidebar rows are cells with a text label rather than buttons.
            // Sleep and Trends had rows of their own; both are inside Review.
            for gone in ["Sleep", "Trends"] {
                XCTAssertFalse(app.staticTexts[gone].firstMatch.exists && app.buttons[gone].firstMatch.exists,
                               "\(gone) still has a sidebar row")
            }
            // The chart button at the top left is "Review" too, and sits under the open sidebar:
            // the row is the one a finger can reach.
            let review = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Review"))
                .allElementsBoundByIndex.first { $0.isHittable }
            XCTAssertNotNil(review, "no Review row a finger can reach")
            review?.tap()
            XCTAssertTrue(app.descendants(matching: .any)["review.fitness"].firstMatch.waitForExistence(timeout: 10),
                          "Review didn't open from the sidebar")
        } else {
            for tab in ["Plan", "Body", "Notes", "Library"] {
                XCTAssertTrue(app.tabBars.buttons[tab].exists, "\(tab) missing from the tab bar")
            }
            // In the tab bar only: the Day view's own ⋯ menu is also labelled "More".
            let tabBar = app.tabBars.firstMatch
            XCTAssertFalse(tabBar.buttons["More"].exists, "the phone's tab bar overflowed into More")
            XCTAssertFalse(tabBar.buttons["Review"].exists, "Review leaked into the phone's tab bar")
        }
    }
}
