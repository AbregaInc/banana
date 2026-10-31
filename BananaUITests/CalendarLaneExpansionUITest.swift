import XCTest

final class CalendarLaneExpansionUITest: XCTestCase {
    func testAnEventUsesTheFreeLanesBesideALongEvent() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview", "--plan", "--ui-audit", "--modules", "plan", "--lane-expansion-preview",
            "--reset-day-scroll-offset", "-planMode", "day", "--disable-icloud", "--no-space-sync", "-onboardingCompleted", "YES"]
        app.launch()
        let grid = app.calendarTimeGrid()
        XCTAssertTrue(grid.waitForExistence(timeout: 20))
        func event(_ name: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", name + ",")).firstMatch
        }
        func reveal(_ item: XCUIElement) {
            for _ in 0..<10 where !(item.exists && item.isHittable) {
                let backwards = item.exists && item.frame.minY < grid.frame.minY
                let start = grid.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: backwards ? 0.35 : 0.65))
                let end = grid.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: backwards ? 0.55 : 0.45))
                start.press(forDuration: 0.05, thenDragTo: end)
            }
            XCTAssertTrue(item.isHittable)
        }
        let first = event("First overlap")
        reveal(first)
        let narrowWidth = first.frame.width
        let expanded = event("Expanded event")
        reveal(expanded)
        XCTAssertGreaterThan(expanded.frame.width, narrowWidth * 1.8)
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Event expands into unused columns"
        image.lifetime = .keepAlways
        add(image)
    }
}
