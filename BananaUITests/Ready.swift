import XCTest

extension XCTestCase {
    /// Goes on as soon as `ready` is true, instead of sleeping for a guessed time. Returns
    /// whether it became true within `timeout`; the caller asserts when that matters.
    @discardableResult
    func waitUntil(timeout: TimeInterval = 5, _ ready: @escaping () -> Bool) -> Bool {
        if ready() { return true }
        let done = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in ready() }, object: nil)
        return XCTWaiter().wait(for: [done], timeout: timeout) == .completed
    }
}

extension XCUIApplication {
    /// Convert measured element geometry into a screen coordinate.
    func pointAtCenter(of element: XCUIElement) -> XCUICoordinate {
        let target = element.frame, origin = frame.origin
        return coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: target.midX - origin.x, dy: target.midY - origin.y))
    }

    /// The bare toolbar point used by ControlRulesWalkUITest; tapping a menu's own
    /// anchor can select an item laid out over it instead of dismissing the menu.
    func dismissNativeMenu(item: XCUIElement) -> Bool {
        coordinate(withNormalizedOffset: CGVector(dx: 0.24, dy: 0.095)).tap()
        return item.waitForNonExistence(timeout: 3)
    }

    /// Every UI test runs the app as it was before the data platform: no engine, iCloud as today
    /// (`--no-space-sync`, docs/design/DATA-PLATFORM.md §2). Called right before each launch.
    func withoutSpaceSync() {
        if !launchArguments.contains("--no-space-sync") { launchArguments.append("--no-space-sync") }
    }
}

extension XCUIApplication {
    /// Native calendars virtualize cells in a collection view; the reference renderer scrolls.
    func calendarTimeGrid() -> XCUIElement {
        let native = collectionViews.firstMatch
        let reference = scrollViews.matching(identifier: "mobile.week.timeGrid").firstMatch
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            native.exists || reference.exists || self.scrollViews.firstMatch.exists
        }, object: nil)
        _ = XCTWaiter().wait(for: [ready], timeout: 20)
        if native.exists { return native }
        if reference.exists { return reference }
        let window = windows.firstMatch.frame
        return scrollViews.allElementsBoundByIndex.max {
            let a = $0.frame.intersection(window), b = $1.frame.intersection(window)
            return max(0, a.width) * max(0, a.height) < max(0, b.width) * max(0, b.height)
        } ?? reference
    }

    /// The identifier is inherited by the weekday header scroll view too. Choose visible timed
    /// canvas, and clip to the window so gestures never start in that header or end off screen.
    func calendarGridViewport() -> CGRect? {
        let grid = calendarTimeGrid()
        guard grid.exists else { return nil }
        let candidates = grid.elementType == .collectionView
            ? collectionViews : scrollViews
        let window = windows.firstMatch.frame
        // UIKit already lays out the timed viewport inside the native screen chrome.
        // The reference renderer's guessed 180pt exclusion cuts this short landscape
        // viewport almost in half, producing tiny drags that fail to reveal evicted cells.
        if grid.elementType == .collectionView {
            let visible = grid.frame.intersection(window)
            let minimumHeight: CGFloat = window.width > window.height ? 40 : 200
            return !visible.isNull && visible.height > minimumHeight && visible.width > 150 ? visible : nil
        }
        let safe = CGRect(x: window.minX, y: window.minY + 80, width: window.width, height: window.height - 180)
        return candidates.allElementsBoundByIndex.map { $0.frame.intersection(safe) }
            .filter { !$0.isNull && $0.height > (window.width > window.height ? 40 : 200) && $0.width > 150 }
            .max { $0.height * $0.width < $1.height * $1.width }
    }

    func calendarPoint(in viewport: CGRect, y: CGFloat) -> XCUICoordinate {
        coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: viewport.midX, dy: viewport.minY + viewport.height * y))
    }
}


extension XCTestCase {
    /// Native cells exist only in the viewport; scroll before asking for their buttons.
    func revealCalendarButton(_ prefix: String, in app: XCUIApplication,
                              referenceLabelPattern: String? = nil) throws -> XCUIElement {
        // SwiftUI event tiles with a context menu can be PopUpButton in modern AX.
        let buttons = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", prefix))
        XCTAssertTrue(app.calendarTimeGrid().waitForExistence(timeout: 20))
        for _ in 0..<16 {
            if let item = buttons.allElementsBoundByIndex.first(where: { $0.isHittable }),
               let viewport = app.calendarGridViewport(),
               item.frame.height > viewport.height || (item.frame.minY >= viewport.minY && item.frame.maxY <= viewport.maxY) { return item }
            let viewport = try XCTUnwrap(app.calendarGridViewport(),
                "No timed viewport: app \(app.frame), window \(app.windows.firstMatch.frame), grid \(app.calendarTimeGrid().frame)\n\(app.debugDescription)")
            // A zoom can evict the target's native cell. A known fixture hour remains in the
            // grid background, so use its position instead of always searching toward midnight.
            let reference = referenceLabelPattern.map {
                app.calendarTimeGrid().staticTexts.matching(NSPredicate(format: "label MATCHES %@", $0)).firstMatch
            }
            let above: Bool
            if buttons.firstMatch.exists {
                above = buttons.firstMatch.frame.minY < viewport.minY
            } else if let reference, reference.exists {
                above = reference.frame.minY < viewport.minY
            } else {
                above = false
            }
            if referenceLabelPattern == nil {
                // Without an hour anchor this is an exploratory search for an
                // unmounted item. Preserve its ordinary scrolling gesture.
                let start = app.calendarPoint(in: viewport, y: above ? 0.3 : 0.75)
                let end = app.calendarPoint(in: viewport, y: above ? 0.75 : 0.3)
                start.press(forDuration: 0.05, thenDragTo: end)
                continue
            }
            let targetFrame = buttons.firstMatch.exists && buttons.firstMatch.frame.height > 0
                ? buttons.firstMatch.frame : reference.flatMap { $0.exists ? $0.frame : nil }
            let delta = targetFrame.map { viewport.midY - $0.midY }
                ?? viewport.height * (above ? 0.4 : -0.4)
            let shift = min(viewport.height * 0.4, max(-viewport.height * 0.4, delta))
            let start = app.calendarPoint(in: viewport, y: 0.5)
            // End the pan at rest. A flick's deceleration can jump past a short
            // landscape viewport and make the search alternate forever.
            start.press(forDuration: 0.05,
                        thenDragTo: start.withOffset(CGVector(dx: 0, dy: shift)),
                        withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        return try XCTUnwrap(buttons.allElementsBoundByIndex.first(where: { $0.isHittable }),
                            "No visible calendar button for \(prefix)\n\(app.debugDescription)")
    }
}


extension XCUIApplication {
    /// The native viewport exposes actual visible descriptor identities under its audit flag.
    /// Reference renderers retain their day container; both return date|event-identities.
    func calendarDaySnapshot(referenceID: String) -> String? {
        let native = collectionViews.firstMatch
        if native.exists {
            guard let value = native.value as? String, let bytes = value.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  let ids = payload["visibleIDs"] as? [String] else { return nil }
            let title = staticTexts["mobile.day.title"].firstMatch
            guard title.exists else { return nil }
            return title.label + "|" + ids.filter { !$0.contains("calendar.currentTime") }.sorted().joined(separator: ",")
        }
        let reference = descendants(matching: .any)[referenceID].firstMatch
        return reference.exists ? reference.value as? String : nil
    }
}
