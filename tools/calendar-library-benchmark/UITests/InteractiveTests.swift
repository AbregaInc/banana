import XCTest

/// Attach to the already-launched isolated prototype so Instruments can attach before input.
/// Gesture wall clock includes automation overhead and is never used as a response budget.
final class InteractiveTests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "com.boris.banana.calendar-library-benchmark")
        app.activate()
        XCTAssertTrue(app.staticTexts["benchmark.interactive.ready"].waitForExistence(timeout: 10),
                      "Launch the isolated benchmark with --interactive before testing")
    }
    func testPagingScrollingAndEviction() {
        let date = app.staticTexts["benchmark.date"]
        let original = date.label
        var visited = [original]
        for _ in 0..<4 {
            let previous = date.label
            app.buttons["benchmark.next"].tap()
            let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", previous), object: date)
            XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 3), .completed)
            XCTAssertFalse(visited.contains(date.label), "Every forward page must advance")
            visited.append(date.label)
        }
        let scroll = app.scrollViews["benchmark.timeline"]
        XCTAssertTrue(scroll.exists)
        for _ in 0..<4 { scroll.swipeUp(); scroll.swipeDown() }
        app.buttons["benchmark.clearCache"].tap()
        for expected in visited.dropLast().reversed() {
            app.buttons["benchmark.previous"].tap()
            let restored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expected), object: date)
            XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 3), .completed)
        }
        XCTAssertEqual(date.label, original, "Returning after eviction must restore the same date")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "native-calendar-after-touch-and-eviction"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
