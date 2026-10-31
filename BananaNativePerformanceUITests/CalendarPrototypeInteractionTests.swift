import XCTest
import AppKit

/// Real mouse/wheel interaction with the isolated renderer only. Pair with a trace;
/// XCTest's gesture duration and polling are not input-to-visible measurements.
final class CalendarPrototypeInteractionTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == "com.boris.banana.calendar-surface-review"
        }
        guard running.count == 1, let url = running.first?.bundleURL else {
            throw NSError(domain: "CalendarPrototypePerformance", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Keep exactly one isolated calendar surface preview running"])
        }
        app = XCUIApplication(url: url)
        app.activate()
        XCTAssertTrue(app.buttons["Next"].waitForExistence(timeout: 5))
    }

    private var heading: XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "value MATCHES %@ OR label MATCHES %@",
            "[A-Z][a-z]{2} [0-9]{1,2}, [0-9]{4}", "[A-Z][a-z]{2} [0-9]{1,2}, [0-9]{4}")).firstMatch
    }

    private func headingValue() -> String {
        let element = heading
        return element.value as? String ?? element.label
    }

    func testCacheRecoveryAndPaging() {
        XCTAssertTrue(heading.waitForExistence(timeout: 5))
        let original = headingValue()
        for _ in 0..<6 {
            app.buttons["Clear cache"].click()
            app.buttons["Next"].click()
            let changed = XCTNSPredicateExpectation(predicate: NSPredicate { [weak self] _, _ in
                guard let self else { return false }
                return self.heading.exists && self.headingValue() != original
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
            app.buttons["Previous"].click()
            let restored = XCTNSPredicateExpectation(predicate: NSPredicate { [weak self] _, _ in
                self?.headingValue() == original
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 5), .completed)
        }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "prototype-after-cache-recovery"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testRepeatedWheelScrolling() {
        let timeline = app.scrollViews.firstMatch
        XCTAssertTrue(timeline.waitForExistence(timeout: 5))
        for _ in 0..<6 { timeline.scroll(byDeltaX: 0, deltaY: -400) }
        for _ in 0..<6 { timeline.scroll(byDeltaX: 0, deltaY: 400) }
        XCTAssertTrue(heading.exists)
        XCTAssertGreaterThan(timeline.buttons.count, 0)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "prototype-after-wheel-scroll"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
