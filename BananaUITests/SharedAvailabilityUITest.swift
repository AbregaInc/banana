import XCTest

final class SharedAvailabilityUITest: XCTestCase {
    func testProvenBusyMirrorsRenderAsOneDetailedEvent() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview", "--plan", "--ui-audit", "--modules", "plan", "--shared-mirror-preview",
                               "--reset-day-scroll-offset", "-planMode", "day", "--disable-icloud", "--no-space-sync", "-onboardingCompleted", "YES"]
        app.launch()
        let dinners = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Dinner,"))
        let grid = app.calendarTimeGrid()
        XCTAssertTrue(grid.waitForExistence(timeout: 20))
        for _ in 0..<10 where !(dinners.firstMatch.exists && dinners.firstMatch.isHittable) {
            if dinners.firstMatch.exists && dinners.firstMatch.frame.minY < grid.frame.minY { grid.swipeDown() } else { grid.swipeUp() }
        }
        XCTAssertTrue(dinners.firstMatch.isHittable, app.debugDescription)
        XCTAssertEqual(dinners.count, 1)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Busy,")).count, 0)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "One shared Dinner including proven Busy mirrors"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testSomeoneElsesPrivateBusyBlockStaysVisibleBesideMyOwnEvent() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview", "--plan", "--ui-audit", "--modules", "plan", "--shared-busy-preview",
                               "--reset-day-scroll-offset", "-planMode", "day", "--disable-icloud", "--no-space-sync", "-onboardingCompleted", "YES"]
        app.launch()
        let busy = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Busy,")).firstMatch
        let mine = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "My dentist,")).firstMatch
        let grid = app.calendarTimeGrid()
        XCTAssertTrue(grid.waitForExistence(timeout: 20))
        for _ in 0..<10 where !(busy.exists && busy.isHittable) {
            if busy.exists && busy.frame.minY < grid.frame.minY { grid.swipeDown() } else { grid.swipeUp() }
        }
        XCTAssertTrue(busy.isHittable, app.debugDescription)
        XCTAssertTrue(mine.isHittable, "an unrelated simultaneous appointment must remain separate")
        XCTAssertFalse(app.staticTexts["Private work address"].exists)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Shared private availability beside my own appointment"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
