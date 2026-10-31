import XCTest

/// What you've listened to, and where, is looking back: it opens from Review, which the chart
/// button at the top left of every tab opens. (It was a clock menu in the Library, and two levels
/// down in Settings before that.)
final class LibraryListeningUITest: XCTestCase {
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--tab", "library", "--disable-icloud", "--no-space-sync", "--ui-audit", "-onboardingCompleted", "YES"]
        app.withoutSpaceSync()
        app.launch()
        return app
    }

    func testListeningOpensFromTheLibrarysChartButton() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else { throw XCTSkip("a sidebar lists Review itself") }
        let app = launch()
        let chart = app.buttons["page.review"].firstMatch
        XCTAssertTrue(chart.waitForExistence(timeout: 10), "the Library has no chart button")
        XCTAssertFalse(app.buttons["library.listening"].exists, "the Library still has its own listening menu")
        chart.tap()
        // Opened from the Library, Review leads with Listening.
        let listening = app.descendants(matching: .any)["review.listening"].firstMatch
        let fitness = app.descendants(matching: .any)["review.fitness"].firstMatch
        XCTAssertTrue(listening.waitForExistence(timeout: 6), "Review didn't open")
        XCTAssertLessThan(listening.frame.minY, fitness.frame.minY, "Listening isn't first when opened from the Library")
        listening.tap()
        XCTAssertTrue(app.navigationBars["Listening"].waitForExistence(timeout: 5))
    }
}
