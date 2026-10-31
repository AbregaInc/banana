import XCTest
import AppKit

/// Attaches only to an already-running isolated preview. Never launches or terminates Beta.
/// Run alongside tools/native-ui-trace.py. XCTest gesture wall time is NOT response latency.
final class NativeInteractionTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == "com.boris.banana.mac.stressreview"
        }
        guard running.count == 1, let url = running.first?.bundleURL else {
            throw NSError(domain: "NativePerformance", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Keep exactly one isolated Mac stress preview running"])
        }
        // Every retained preview has the same isolated bundle ID. Resolve the live URL instead
        // of allowing Launch Services to pick an older, stopped preview with that identifier.
        app = XCUIApplication(url: url)
        app.activate()
        XCTAssertTrue(app.staticTexts["stress.ready"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.sheets.firstMatch.exists, "A previous interaction left a blocking sheet open")
    }

    private func section(_ title: String) {
        let row = app.outlines["Sidebar"].staticTexts.matching(
            NSPredicate(format: "value == %@ OR label == %@", title, title)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3), "Missing sidebar section \(title)")
        row.click()
    }

    func testMailSelectionScrollAndTyping() {
        section("Mail")
        let list = app.tables["mail.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(list.tableRows.count, 1)
        list.tableRows.element(boundBy: 1).click()
        for _ in 0..<12 { app.typeKey("j", modifierFlags: []) }
        for _ in 0..<6 { app.typeKey("k", modifierFlags: []) }
        XCTAssertTrue(app.staticTexts["mail.conversation.title"].exists)
        for _ in 0..<4 { list.scroll(byDeltaX: 0, deltaY: -600) }
        for _ in 0..<4 { list.scroll(byDeltaX: 0, deltaY: 600) }
        app.buttons["mail.list.compose"].click()
        let body = app.textViews["mail.composer.body"]
        XCTAssertTrue(body.waitForExistence(timeout: 3))
        body.click()
        // Exercises the native rich editor, not the initially focused recipient field.
        body.typeText("performance typing burst")
        XCTAssertTrue((body.value as? String)?.contains("performance typing burst") == true)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "mail-after-typing"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.typeKey(.escape, modifierFlags: [])
    }

    func testPlanOverflowReachability() {
        section("Plan")
        let overflow = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'mac.week.overflow.' OR identifier BEGINSWITH 'mac.week.day.'")).firstMatch
        XCTAssertTrue(overflow.waitForExistence(timeout: 5), "Missing timed-event overflow control")
        overflow.click()
        let popover = app.popovers.firstMatch
        XCTAssertTrue(popover.waitForExistence(timeout: 3))
        let list = popover.scrollViews.firstMatch
        XCTAssertTrue(list.exists)
        for _ in 0..<5 { list.scroll(byDeltaX: 0, deltaY: -1000) }
        let last = popover.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Stress event 99,")).firstMatch
        XCTAssertTrue(last.waitForExistence(timeout: 3), "Wheel scrolling did not reach the last hidden event")
        last.click()
        let detail = app.staticTexts["mac.eventInspector.title"]
        XCTAssertTrue(detail.waitForExistence(timeout: 3))
        XCTAssertEqual(detail.value as? String ?? detail.label, "Stress event 99")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "calendar-last-overflow-event"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.typeKey(.escape, modifierFlags: [])
    }

    func testPlanPagingAndScrolling() {
        section("Plan")
        let grid = app.scrollViews["mac.week.timeGrid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 5))
        for _ in 0..<4 { grid.scroll(byDeltaX: 0, deltaY: -600) }
        for _ in 0..<4 { grid.scroll(byDeltaX: 0, deltaY: 600) }
        for _ in 0..<4 { app.typeKey("j", modifierFlags: []) }
        for _ in 0..<4 { app.typeKey("k", modifierFlags: []) }
        XCTAssertTrue(app.menuButtons["mac.planner.view"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "plan-after-paging"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testPlanPaletteInvalidation() throws {
        section("Plan")
        let change = app.buttons["calendar.audit.changePalette"]
        guard change.exists else {
            throw XCTSkip("Requires the isolated --calendar-observation-audit preview")
        }
        let palette = app.staticTexts["calendar.audit.palette"]
        let previous = palette.value as? String ?? palette.label
        let expected = previous == "FF0000" ? "00FF00" : "FF0000"
        let title = app.windows.firstMatch.title
        change.click()
        let changed = NSPredicate(format: "value == %@ OR label == %@", expected, expected)
        expectation(for: changed, evaluatedWith: palette)
        waitForExpectations(timeout: 3)
        XCTAssertEqual(app.windows.firstMatch.title, title, "Palette should update without navigating")
        let count = app.staticTexts["calendar.audit.renderCount"]
        let rendered = count.value as? String ?? count.label
        app.buttons["calendar.audit.repeatPalette"].click()
        let redraw = XCTNSPredicateExpectation(predicate: NSPredicate(
            format: "NOT (value == %@ OR label == %@)", rendered, rendered), object: count)
        redraw.isInverted = true
        wait(for: [redraw], timeout: 1)
    }

    func testPlanPagingRebindsEventActions() {
        section("Plan")
        let grid = app.scrollViews["mac.week.timeGrid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 5))
        grid.scroll(byDeltaX: 0, deltaY: 10_000)
        let event = grid.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH 'mac.week.occurrence.' AND label BEGINSWITH 'Stress event '")).firstMatch
        XCTAssertTrue(event.waitForExistence(timeout: 3))
        let previousID = event.identifier
        app.typeKey("j", modifierFlags: [])
        expectation(for: NSPredicate(format: "identifier != %@", previousID), evaluatedWith: event)
        waitForExpectations(timeout: 3)
        let title = String(event.label.split(separator: ",", maxSplits: 1)[0])
        event.click()
        let detail = app.staticTexts["mac.eventInspector.title"]
        XCTAssertTrue(detail.waitForExistence(timeout: 3), "New-page event must open its own detail")
        XCTAssertEqual(detail.value as? String ?? detail.label, title)
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey("k", modifierFlags: [])
    }

    func testPlanHoverRedraws() throws {
        section("Plan")
        let policy = app.staticTexts["calendar.audit.hoverPolicy"]
        let count = app.staticTexts["calendar.audit.renderCount"]
        guard count.exists else { throw XCTSkip("Requires the isolated observation-audit preview") }
        let grid = app.scrollViews["mac.week.timeGrid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 5))
        grid.scroll(byDeltaX: 0, deltaY: 10_000)
        let before = Int(count.value as? String ?? count.label)!
        // The first column's two-point right inset is empty even when events fill its lanes.
        let dayCount = Set(app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'mac.week.day.'"))
            .allElementsBoundByIndex.map(\.identifier)).count
        XCTAssertGreaterThan(dayCount, 0)
        let x = (58 + (grid.frame.width - 58) / CGFloat(dayCount) - 2) / grid.frame.width
        for fraction in [0.12, 0.24, 0.36, 0.48, 0.60, 0.72, 0.84, 0.72, 0.60, 0.48, 0.36, 0.24] {
            grid.coordinate(withNormalizedOffset: CGVector(dx: x, dy: fraction)).hover()
        }
        let after = Int(count.value as? String ?? count.label)!
        let mode = policy.exists ? (policy.value as? String ?? policy.label) : "original-inline"
        let evidence = XCTAttachment(string: "{\"policy\":\"\(mode)\",\"hoverActions\":12,\"weekBodyEvaluations\":\(after-before)}")
        evidence.name = "calendar-hover-redraws"
        evidence.lifetime = .keepAlways
        add(evidence)
        if mode == "local" { XCTAssertEqual(after, before, "Pointer-only state must not redraw the entire week") }
    }

    func testPlanDragFailureRecovery() throws {
        section("Plan")
        let count = app.staticTexts["calendar.audit.renderCount"]
        guard count.exists else { throw XCTSkip("Requires the isolated observation-audit preview") }
        let grid = app.scrollViews["mac.week.timeGrid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 5))
        grid.scroll(byDeltaX: 0, deltaY: 10_000)
        let event = grid.images.matching(NSPredicate(
            format: "identifier BEGINSWITH 'mac.week.occurrence.' AND label BEGINSWITH 'Stress event 2,'")).firstMatch
        XCTAssertTrue(event.waitForExistence(timeout: 3))
        let originalLabel = event.label
        let before = Int(count.value as? String ?? count.label)!
        let start = event.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.click(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 116)),
                    withVelocity: .slow, thenHoldForDuration: 0.1)
        // Fixture IDs cannot reach Google Calendar. Exercise explicit rejection and rollback.
        let failure = app.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@",
            "That event is no longer in your calendar.", "That event is no longer in your calendar.")).firstMatch
        XCTAssertTrue(failure.waitForExistence(timeout: 3), "Rejected fixture move must remain visible")
        app.sheets.firstMatch.buttons["OK"].click()
        XCTAssertEqual(event.label, originalLabel, "Rejected move must restore the event's original time")
        let after = Int(count.value as? String ?? count.label)!
        let policy = app.staticTexts["calendar.audit.dragPolicy"]
        let mode = policy.exists ? (policy.value as? String ?? policy.label) : "original-inline"
        let evidence = XCTAttachment(string: "{\"policy\":\"\(mode)\",\"dragPoints\":116,\"weekBodyEvaluations\":\(after-before),\"failureVisible\":true}")
        evidence.name = "calendar-drag-redraws"
        evidence.lifetime = .keepAlways
        add(evidence)
    }
}
