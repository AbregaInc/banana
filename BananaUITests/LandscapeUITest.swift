import XCTest

/// An iPhone on its side shows the app, as it does upright: every tab is there and opens its
/// page. Landscape used to replace the whole app with a bedside clock.
final class LandscapeUITest: XCTestCase {
    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    /// `TEST_RUNNER_BANANA_SHOT_DIR=<folder>` on the `xcodebuild test` line keeps a picture of
    /// each page there, to look at.
    private func keep(_ app: XCUIApplication, _ name: String) {
        guard let folder = ProcessInfo.processInfo.environment["BANANA_SHOT_DIR"] else { return }
        // The screen, not the app: an app's own screenshot comes back turned and cut off when
        // the device is on its side.
        try? XCUIScreen.main.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }

    func testEveryPageOpensOnItsSide() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "an iPad was never replaced by the clock")
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview", "--tab", "plan", "--plan", "-planMode", "day", "--dummy-health",
                               "--library", "--notes", "--wellness", "--disable-icloud", "--no-space-sync", "--ui-audit",
                               "-onboardingCompleted", "YES"]
        app.withoutSpaceSync()
        app.launch()
        XCTAssertTrue(app.buttons["shell.switcher"].waitForExistence(timeout: 15), app.debugDescription)

        // On its side a phone keeps the bar (the rail is a landscape iPad's room,
        // docs/design/BOTTOM-BAR-SHELL.md), never a bedside clock.
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitUntil(timeout: 8) { app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height })
        XCTAssertTrue(app.buttons["shell.switcher"].waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertFalse(app.descendants(matching: .any)["shell.rail"].exists)
        for page in ["plan", "body", "notes", "library"] {
            app.openPage(page)
            app.buttons["shell.switcher"].tap()
            XCTAssertTrue(waitUntil(timeout: 5) { app.buttons["shell.page.\(page)"].isSelected }, "\(page) didn't open on its side")
            app.buttons["shell.switcher"].tap()
            keep(app, "landscape-\(page)")
        }
        app.openPage("plan")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "mobile.week.timeGrid").firstMatch
            .waitForExistence(timeout: 5) || app.collectionViews.firstMatch.waitForExistence(timeout: 2),
                      "the day's grid is there on its side")

        // And back upright, the bar again.
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.buttons["shell.switcher"].waitForExistence(timeout: 8))
    }
}
