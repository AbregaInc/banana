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

    private func chooseCalendarView(_ title: String) {
        let picker = app.radioGroups["mac.planner.view"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        let choice = picker.radioButtons[title]
        XCTAssertTrue(choice.exists)
        XCTAssertTrue(choice.isEnabled, "Calendar view choices must be actionable")
        choice.click()
    }

    /// One coherent AX snapshot avoids per-element queries racing a changing header tree.
    private func renderedCalendarDays() -> Set<String> {
        guard let snapshot = try? app.snapshot() else { return [] }
        var pending: [any XCUIElementSnapshot] = [snapshot]
        var result = Set<String>()
        while let node = pending.popLast() {
            if node.identifier.hasPrefix("mac.week.day.") { result.insert(node.identifier) }
            pending.append(contentsOf: node.children)
        }
        return result
    }

    func testCalendarSearchReturnKeepsSheetOpen() {
        section("Plan")
        app.buttons["calendar.search.open"].click()
        let field = app.textFields["filters.plan.query"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        // Keep the isolated fixture offline while exercising Return handling.
        field.typeText("   ")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(field.exists, "Return in search must not activate Done")
        app.typeKey("a", modifierFlags: .command)
        app.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["Find events by title, location or description."].exists)
        app.typeKey(.escape, modifierFlags: [])
        if app.textFields["filters.plan.query"].exists { app.buttons["Done"].click() }
        XCTAssertFalse(app.textFields["filters.plan.query"].exists)
        XCTAssertTrue(app.buttons["calendar.search.open"].waitForExistence(timeout: 5))
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

    func testNativeDayPersistsScrollWhileVisible() throws {
        section("Plan")
        chooseCalendarView("Day")
        let day = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.renderedCalendarDays().count == 1
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [day], timeout: 3), .completed)
        XCTAssertTrue(app.collectionViews["mac.calendar.viewport"].exists)
        let grid = app.scrollViews["mac.week.timeGrid"]
        let saved = app.staticTexts["calendar.audit.savedDayOffset"]
        XCTAssertTrue(saved.waitForExistence(timeout: 3), "Requires isolated observation-audit preview")
        func savedOffset() -> Double? {
            Double(saved.value as? String ?? saved.label)
        }
        grid.scroll(byDeltaX: 0, deltaY: 10_000)
        let topSaved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            savedOffset() == 0
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [topSaved], timeout: 3), .completed)
        grid.scroll(byDeltaX: 0, deltaY: -400)
        let movedSaved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (savedOffset() ?? 0) > 0
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [movedSaved], timeout: 3), .completed,
                       "Native Day must persist after scrolling without leaving the screen")
        let evidence = XCTAttachment(string: "Persisted visible Day offset: \(savedOffset().map(String.init(describing:)) ?? "missing")")
        evidence.lifetime = .keepAlways
        add(evidence)
        chooseCalendarView("Week")
    }

    func testDefaultDayAndWeekNativeViewport() {
        section("Plan")
        for title in ["Day", "Week"] {
            chooseCalendarView(title)
            let native = app.collectionViews["mac.calendar.viewport"]
            XCTAssertTrue(native.waitForExistence(timeout: 5), "\(title) must install the native viewport by default")
            let expectedDays = title == "Day" ? 1 : 7
            let switched = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                self.renderedCalendarDays().count == expectedDays
            }, object: app)
            XCTAssertEqual(XCTWaiter.wait(for: [switched], timeout: 3), .completed,
                           "The rendered column count must follow the picker")
            let scroll = app.scrollViews["mac.week.timeGrid"]
            XCTAssertTrue(scroll.exists)
            scroll.scroll(byDeltaX: 0, deltaY: -400)
            scroll.scroll(byDeltaX: 0, deltaY: 400)
            XCTAssertTrue(native.exists)
            // The stress fixture includes 24-hour appointments. Move before its date
            // range so this gesture starts on genuinely empty calendar background.
            app.typeKey("t", modifierFlags: [])
            app.typeKey("k", modifierFlags: [])
            scroll.scroll(byDeltaX: 0, deltaY: -10_000)
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.9)).click()
            let eventTitle = app.textFields["event.title"]
            XCTAssertTrue(eventTitle.waitForExistence(timeout: 3),
                          "\(title) blank-slot click must open the existing event editor")
            eventTitle.click()
            eventTitle.typeText("Native \(title) creation")
            XCTAssertEqual(eventTitle.value as? String, "Native \(title) creation")
            app.sheets.firstMatch.buttons["Cancel"].click()
            XCTAssertFalse(app.sheets.firstMatch.exists)
            app.typeKey("j", modifierFlags: [])
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "default-native-\(title.lowercased())"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
    }

    func testPlanPagingAndScrolling() {
        section("Plan")
        let grid = app.scrollViews["mac.week.timeGrid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 5))
        grid.scroll(byDeltaX: 0, deltaY: 10_000)
        for _ in 0..<4 { grid.scroll(byDeltaX: 0, deltaY: -600) }
        for _ in 0..<4 { grid.scroll(byDeltaX: 0, deltaY: 600) }
        func visibleDays() -> Set<String> { renderedCalendarDays() }
        let originalDays = visibleDays()
        XCTAssertFalse(originalDays.isEmpty)
        print("MAC_PAGING_BEFORE=\(originalDays.sorted())")
        for _ in 0..<4 { app.typeKey("j", modifierFlags: []) }
        let advanced = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let current = visibleDays()
            return !current.isEmpty && current.isDisjoint(with: originalDays)
        }, object: app)
        let advancedResult = XCTWaiter.wait(for: [advanced], timeout: 3)
        print("MAC_PAGING_AFTER=\(visibleDays().sorted()) result=\(advancedResult.rawValue)")
        let pagingEvidence = XCTAttachment(string: app.debugDescription)
        pagingEvidence.name = "native-paging-after-forward"; pagingEvidence.lifetime = .keepAlways
        add(pagingEvidence)
        XCTAssertEqual(advancedResult, .completed,
                       "Paging must replace the dates on screen, not merely handle a key")
        for _ in 0..<4 { app.typeKey("k", modifierFlags: []) }
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            visibleDays() == originalDays
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 3), .completed)
        XCTAssertTrue(app.radioGroups["mac.planner.view"].exists)
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
        assertPagingRebindsEventActions(pageCount: 1)
    }

    func testNativeCalendarWindowResizePreservesEventActions() {
        section("Plan")
        let window = app.windows.firstMatch
        let initial = window.frame
        let days = renderedCalendarDays()
        XCTAssertFalse(days.isEmpty)
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
            .withOffset(CGVector(dx: -2, dy: -2))
        corner.press(forDuration: 0.1, thenDragTo: corner.withOffset(CGVector(dx: -140, dy: -90)))
        let resized = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            window.frame.width < initial.width - 30 || window.frame.height < initial.height - 30
        }, object: window)
        XCTAssertEqual(XCTWaiter.wait(for: [resized], timeout: 3), .completed,
                       "Resize must change the actual native window dimensions")
        XCTAssertEqual(renderedCalendarDays(), days)
        XCTAssertTrue(app.collectionViews["mac.calendar.viewport"].exists)
        let grid = app.scrollViews["mac.week.timeGrid"]
        grid.scroll(byDeltaX: 0, deltaY: 10_000)
        let event = grid.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH 'mac.week.occurrence.' AND label BEGINSWITH 'Stress event '")).firstMatch
        XCTAssertTrue(event.waitForExistence(timeout: 3))
        let title = String(event.label.split(separator: ",", maxSplits: 1)[0])
        event.click()
        let detail = app.staticTexts["mac.eventInspector.title"]
        XCTAssertTrue(detail.waitForExistence(timeout: 3))
        XCTAssertEqual(detail.value as? String ?? detail.label, title)
        app.typeKey(.escape, modifierFlags: [])
        let current = window.frame
        let restore = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
            .withOffset(CGVector(dx: -2, dy: -2))
        restore.press(forDuration: 0.1, thenDragTo: restore.withOffset(CGVector(
            dx: initial.width - current.width, dy: initial.height - current.height)))
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            abs(window.frame.width - initial.width) < 3 && abs(window.frame.height - initial.height) < 3
        }, object: window)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 3), .completed)
        XCTAssertEqual(renderedCalendarDays(), days)
    }

    func testPlanRepeatedPagingRebindsEventActions() {
        assertPagingRebindsEventActions(pageCount: 3)
    }

    private func assertPagingRebindsEventActions(pageCount: Int) {
        section("Plan")
        let grid = app.scrollViews["mac.week.timeGrid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 5))
        grid.scroll(byDeltaX: 0, deltaY: 10_000)
        let event = grid.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH 'mac.week.occurrence.' AND label BEGINSWITH 'Stress event '")).firstMatch
        XCTAssertTrue(event.waitForExistence(timeout: 3))
        let initialID = event.identifier
        for _ in 0..<pageCount {
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
        }
        for _ in 0..<pageCount { app.typeKey("k", modifierFlags: []) }
        expectation(for: NSPredicate(format: "identifier == %@", initialID), evaluatedWith: event)
        waitForExpectations(timeout: 3)
    }

    func testNativeEmptySlotContextMenuAfterPaging() throws {
        try assertNativeSlotMenuAfterPaging(mode: "Day")
    }

    func testNativeWeekSlotContextMenuAfterPaging() throws {
        try assertNativeSlotMenuAfterPaging(mode: "Week")
    }

    func testNativeSlotControlClickAfterPaging() throws {
        try assertNativeSlotMenuAfterPaging(mode: "Day", controlClick: true)
    }

    private func assertNativeSlotMenuAfterPaging(mode: String, controlClick: Bool = false) throws {
        section("Plan")
        chooseCalendarView(mode)
        app.typeKey("t", modifierFlags: [])
        app.typeKey("k", modifierFlags: [])
        let grid = app.scrollViews["mac.week.timeGrid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 3))
        XCTAssertTrue(grid.frame.minX.isFinite && grid.frame.minY.isFinite)
        XCTAssertGreaterThan(grid.frame.width, 100)
        XCTAssertGreaterThan(grid.frame.height, 100)
        grid.scroll(byDeltaX: 0, deltaY: 10_000)
        let slot = grid.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.3))
        func openMenu() {
            if controlClick {
                XCUIElement.perform(withKeyModifiers: [.control]) { slot.click() }
            } else { slot.rightClick() }
        }
        slot.hover()
        openMenu()
        let menuSnapshot = XCTAttachment(string: grid.debugDescription)
        menuSnapshot.name = "slot-menu-hierarchy"
        menuSnapshot.lifetime = .keepAlways
        add(menuSnapshot)
        let create = app.menuItems.matching(NSPredicate(format: "title BEGINSWITH %@ OR label BEGINSWITH %@", "New event at", "New event at")).firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 3), "Empty native calendar slots must expose creation actions")
        XCTAssertTrue(app.menuItems.matching(NSPredicate(format: "title BEGINSWITH %@ OR label BEGINSWITH %@", "New reminder at", "New reminder at")).firstMatch.exists)
        app.typeKey(.escape, modifierFlags: [])
        let originalDays = renderedCalendarDays()
        app.typeKey("k", modifierFlags: [])
        XCTAssertNotEqual(renderedCalendarDays(), originalDays)
        let displayedDays = renderedCalendarDays().sorted()
        XCTAssertEqual(displayedDays.count, mode == "Day" ? 1 : 7)
        // The fixture has the standard 58-point gutter. At this window width,
        // 55% of the grid is inside the fourth Week column.
        XCTAssertGreaterThan(grid.frame.width, 600)
        let displayedDay = displayedDays[mode == "Day" ? 0 : 3]
        openMenu()
        XCTAssertTrue(create.waitForExistence(timeout: 3))
        create.click()
        XCTAssertTrue(app.textFields["event.title"].waitForExistence(timeout: 3))
        let editorSnapshot = XCTAttachment(string: app.sheets.firstMatch.debugDescription)
        editorSnapshot.name = "slot-editor-hierarchy"
        editorSnapshot.lifetime = .keepAlways
        add(editorSnapshot)
        let datePickers = app.sheets.firstMatch.datePickers
        XCTAssertEqual(datePickers.count, 2, "The timed editor must expose its start and end pickers")
        // AppKit exposes the Starts/Ends labels as adjacent static text; XCTest
        // does not attach those labels to the NSDatePicker elements themselves.
        let startPicker = datePickers.element(boundBy: 0)
        XCTAssertTrue(startPicker.exists)
        let draftDate: Date
        if let value = startPicker.value as? Date {
            draftDate = value
        } else {
            let dateText = try XCTUnwrap(startPicker.value as? String)
            let pickerFormat = DateFormatter()
            // XCTest serializes AppKit's NSDate AX value as this diagnostic
            // string on this runner. Preserve its explicit timezone when parsing.
            let prefix = "Unsafe value, description '"
            if dateText.hasPrefix(prefix), dateText.hasSuffix("'") {
                pickerFormat.locale = Locale(identifier: "en_US_POSIX")
                pickerFormat.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
                let timestamp = String(dateText.dropFirst(prefix.count).dropLast())
                draftDate = try XCTUnwrap(pickerFormat.date(from: timestamp), "Unrecognized editor date: \(dateText)")
            } else {
                pickerFormat.dateStyle = .short
                pickerFormat.timeStyle = .short
                draftDate = try XCTUnwrap(pickerFormat.date(from: dateText), "Unrecognized editor date: \(dateText)")
            }
        }
        let dayFormat = DateFormatter()
        dayFormat.locale = Locale(identifier: "en_US_POSIX")
        dayFormat.dateFormat = "yyyy-MM-dd"
        XCTAssertEqual("mac.week.day." + dayFormat.string(from: draftDate), displayedDay,
                       "Stationary-pointer creation must use the new page's day")
        let evidence = XCTAttachment(string: app.debugDescription)
        evidence.name = "paged-slot-editor"
        evidence.lifetime = .keepAlways
        add(evidence)
        app.sheets.firstMatch.buttons["Cancel"].click()
        app.typeKey("t", modifierFlags: [])
        chooseCalendarView("Week")
    }

    func testNativeEventContextMenuKeepsEventActions() {
        section("Plan")
        chooseCalendarView("Week")
        app.typeKey("t", modifierFlags: [])
        let grid = app.scrollViews["mac.week.timeGrid"]
        grid.scroll(byDeltaX: 0, deltaY: 10_000)
        let event = grid.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH 'mac.week.occurrence.' AND label BEGINSWITH 'Stress event '")).firstMatch
        XCTAssertTrue(event.waitForExistence(timeout: 3))
        let title = String(event.label.split(separator: ",", maxSplits: 1)[0])
        event.rightClick()
        let open = app.menuItems["Open event"]
        XCTAssertTrue(open.waitForExistence(timeout: 3), "Event menus must not become empty-slot creation menus")
        open.click()
        let detail = app.staticTexts["mac.eventInspector.title"]
        XCTAssertTrue(detail.waitForExistence(timeout: 3))
        XCTAssertEqual(detail.value as? String ?? detail.label, title)
        app.typeKey(.escape, modifierFlags: [])
    }

    func testPlanHoverRedraws() throws {
        section("Plan")
        chooseCalendarView("Week")
        app.typeKey("t", modifierFlags: [])
        let policy = app.staticTexts["calendar.audit.hoverPolicy"]
        let count = app.staticTexts["calendar.audit.renderCount"]
        guard count.exists else { throw XCTSkip("Requires the isolated observation-audit preview") }
        let grid = app.scrollViews["mac.week.timeGrid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 5))
        let nativeViewport = app.collectionViews["mac.calendar.viewport"].exists
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
        let evidence = XCTAttachment(string: "{\"policy\":\"\(mode)\",\"nativeViewport\":\(nativeViewport),\"hoverActions\":12,\"weekBodyEvaluations\":\(after-before)}")
        evidence.name = "calendar-hover-redraws"
        evidence.lifetime = .keepAlways
        add(evidence)
        if nativeViewport || mode == "local" {
            XCTAssertEqual(after, before, "Pointer-only state must not redraw the entire week")
        }
    }

    func testPlanDragFailureRecovery() throws {
        section("Plan")
        let count = app.staticTexts["calendar.audit.renderCount"]
        guard count.exists else { throw XCTSkip("Requires the isolated observation-audit preview") }
        let grid = app.scrollViews["mac.week.timeGrid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 5))
        grid.scroll(byDeltaX: 0, deltaY: 10_000)
        let eventPredicate = NSPredicate(
            format: "identifier BEGINSWITH 'mac.week.occurrence.' AND label BEGINSWITH 'Stress event 2,'")
        let groupedEvent = grid.buttons.matching(eventPredicate).firstMatch
        let event = groupedEvent.exists ? groupedEvent : grid.images.matching(eventPredicate).firstMatch
        XCTAssertTrue(event.waitForExistence(timeout: 3))
        let originalLabel = event.label
        let before = Int(count.value as? String ?? count.label)!
        // The overflow badge can cover the center of the full event button. Its leading
        // interior is visible; the former image-only element had a much smaller frame.
        let start = event.coordinate(withNormalizedOffset: CGVector(dx: groupedEvent.exists ? 0.1 : 0.5, dy: 0.5))
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

    func testPlanEventAccessibilityGrouping() throws {
        section("Plan")
        let policy = app.staticTexts["calendar.audit.eventAccessibilityPolicy"]
        guard policy.exists else { throw XCTSkip("Requires the event-accessibility audit preview") }
        let grid = app.scrollViews["mac.week.timeGrid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 5))
        grid.scroll(byDeltaX: 0, deltaY: 10_000)
        let elements = grid.descendants(matching: .any).matching(identifier: "mac.week.occurrence.ext:stress-event-2")
        let mode = policy.value as? String ?? policy.label
        let count = elements.count
        let evidence = XCTAttachment(string: "{\"policy\":\"\(mode)\",\"eventElementCount\":\(count)}")
        evidence.name = "calendar-event-accessibility"
        evidence.lifetime = .keepAlways
        add(evidence)
        if mode == "grouped" {
            XCTAssertEqual(count, 1, "One rendered event must expose one actionable element")
            let event = grid.buttons["mac.week.occurrence.ext:stress-event-2"]
            XCTAssertTrue(event.exists)
            XCTAssertTrue(event.label.hasPrefix("Stress event 2,"))
            event.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).click()
            let detail = app.staticTexts["mac.eventInspector.title"]
            XCTAssertTrue(detail.waitForExistence(timeout: 3))
            XCTAssertEqual(detail.value as? String ?? detail.label, "Stress event 2")
            app.typeKey(.escape, modifierFlags: [])
        } else {
            XCTAssertGreaterThan(count, 0)
        }
    }

    func testCalendarDraftSurvivesLocalWriteFailure() throws {
        section("Plan")
        guard app.staticTexts["calendar.audit.localWriteFailure"].exists else {
            throw XCTSkip("Requires the isolated local-write-failure preview")
        }
        app.typeKey("c", modifierFlags: [])
        let title = app.textFields["event.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        title.click()
        title.typeText("Durable failure draft")
        app.sheets.firstMatch.buttons["Save"].click()
        let failure = app.staticTexts.matching(NSPredicate(
            format: "value CONTAINS %@ OR label CONTAINS %@",
            "Your draft is still here", "Your draft is still here")).firstMatch
        XCTAssertTrue(failure.waitForExistence(timeout: 3))
        app.sheets.firstMatch.buttons["OK"].click()
        XCTAssertEqual(title.value as? String, "Durable failure draft")
        XCTAssertTrue(app.sheets.firstMatch.buttons["Save"].isEnabled)
        app.sheets.firstMatch.buttons["Cancel"].click()
        XCTAssertFalse(app.sheets.firstMatch.exists)
    }
}
