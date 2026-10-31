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

    func testEveryTabOpensOnItsSide() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "an iPad was never replaced by the clock")
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview", "--tab", "plan", "--plan", "-planMode", "day", "--dummy-health",
                               "--library", "--notes", "--wellness", "--disable-icloud", "--no-space-sync", "--ui-audit",
                               "-onboardingCompleted", "YES"]
        app.withoutSpaceSync()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Plan"].waitForExistence(timeout: 15), app.debugDescription)

        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        // Still the app: its tabs, and the day's grid.
        for tab in ["Plan", "Body", "Notes", "Library"] {
            let button = app.tabBars.buttons[tab]
            XCTAssertTrue(button.waitForExistence(timeout: 5), "no \(tab) tab on its side")
            button.tap()
            sleep(2)
            keep(app, "landscape-\(tab.lowercased())")
        }
        app.tabBars.buttons["Plan"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "mobile.week.timeGrid").firstMatch
            .waitForExistence(timeout: 5), "the day's grid is there on its side")

        // And back upright, the same app.
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.tabBars.buttons["Plan"].waitForExistence(timeout: 5))
    }
}
