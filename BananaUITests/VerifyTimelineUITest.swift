import XCTest

/// Zero-touch on-device verification. Launches the app under `--verify-timeline`, auto-taps
/// the system permission dialogs (Calendar / Reminders / AlarmKit) via SpringBoard, waits
/// for the harness to finish, and asserts 0 failures. This is what closes the AlarmKit
/// runtime gap that the Simulator can't cover.
final class VerifyTimelineUITest: XCTestCase {

    /// The day grid: the scroll view that carries the grid's identifier. It was found as "the
    /// third element with that identifier", which counted the strips above it; when the List and
    /// its weather stripe went, the grid became the second and every test here lost it.
    /// How long XCTest's own flick and the wait after it may take. A 13-inch iPad's grid is
    /// three times a phone's, and the synthesized drag crosses it at the same speed: the same
    /// gesture measures about half a second longer there with nothing in its way.
    private var flickLimit: TimeInterval { UIDevice.current.userInterfaceIdiom == .pad ? 5.5 : 4.5 }
    /// The same for a sideways page.
    private var pageLimit: TimeInterval { UIDevice.current.userInterfaceIdiom == .pad ? 2.5 : 1.5 }

    private func timeGrid(_ app: XCUIApplication) -> XCUIElement {
        app.calendarTimeGrid()
    }

    func testPhysicalBarcodeScannerPresents() throws {
        // `DataScannerViewController.isSupported` is false without camera hardware, and
        // `requestBarcodeCameraAccess` correctly refuses to present the sheet in that case — so on
        // a Simulator this can only ever fail. Skip rather than stay permanently red, which is how
        // a genuine break here would have been lost in the noise.
        #if targetEnvironment(simulator)
        throw XCTSkip("Barcode scanning needs camera hardware; not available on the Simulator.")
        #endif
        let app = XCUIApplication()
        app.launchArguments = ["--wellness", "--ui-audit", "-onboardingCompleted", "YES"]
        addUIInterruptionMonitor(withDescription: "Camera permission") { alert in
            let allow = alert.buttons["Allow"]
            if allow.exists { allow.tap(); return true }
            return false
        }
        app.withoutSpaceSync()
        app.launch()

        XCTAssertTrue(app.plus("wellness.add").waitForExistence(timeout: 8))
        app.plus("wellness.add").tap()
        let scan = app.buttons["wellness.barcodeMeal"]
        XCTAssertTrue(scan.waitForExistence(timeout: 4))
        scan.tap()
        // The one scan sheet every device opens; its barcode button starts the camera.
        XCTAssertTrue(app.navigationBars["Scan a package"].waitForExistence(timeout: 3))
        let scanner = app.buttons["scan.barcode"]
        XCTAssertTrue(scanner.waitForExistence(timeout: 5))
        scanner.tap()
        app.tap() // lets XCTest service a first-run camera permission interruption
        keepScreenshot(of: app, named: "Wellness - physical barcode scanner")
    }

    func testWellnessPhotoConfirmationAndCachedCoachRender() {
        let app = XCUIApplication()
        app.launchArguments = ["--wellness", "--ui-audit", "-onboardingCompleted", "YES"]
        app.withoutSpaceSync()
        app.launch()

        XCTAssertTrue(app.navigationBars["Food"].waitForExistence(timeout: 8))
        let meal = app.buttons.matching(identifier: "nutrition.meal").matching(
            NSPredicate(format: "label CONTAINS[c] %@ AND label CONTAINS %@", "Chicken grain bowl", "800")).firstMatch
        XCTAssertTrue(scrollUntilHittable(meal, in: app),
                      "The saved 800 kcal meal must be reachable in the overview\n\(app.debugDescription)")
        XCTAssertTrue(app.plus("wellness.add").exists)
        keepScreenshot(of: app, named: "Wellness - nutrition overview")

        // The segments carry their counts now ("Taken · 2").
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Taken")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Vitamin D"].waitForExistence(timeout: 1))
        XCTAssertTrue(app.staticTexts["Magnesium"].exists)
        app.plus("wellness.addSupplement").tap()
        // From the top bar's + it is picked from the list.
        if app.buttons["add.supplement"].waitForExistence(timeout: 2) { app.buttons["add.supplement"].tap() }
        XCTAssertTrue(app.buttons["wellness.scanSupplementBarcode"].waitForExistence(timeout: 1))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["Vitamin D"].waitForExistence(timeout: 3))
        keepScreenshot(of: app, named: "Wellness - supplement schedule")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Food")).firstMatch.tap()

        app.plus("wellness.add").tap()
        let photo = app.buttons["wellness.photoMeal"]
        XCTAssertTrue(photo.waitForExistence(timeout: 4))
        photo.tap()
        // Photos go to the backlog to be estimated; with none chosen there is nothing to add.
        XCTAssertTrue(app.navigationBars["Add photos & notes"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["mealDump.add"].isEnabled, "Nothing chosen, nothing to add")
        app.buttons["Cancel"].firstMatch.tap()
    }

    /// Guided plans are switched off (`Features.guidedPlans`): the Workouts tab has no row for
    /// them, however far down it is scrolled.
    func testGuidedPlansAreOffInWorkouts() {
        let app = XCUIApplication()
        app.launchArguments = ["--workout", "--dummy-health", "--ui-audit", "-onboardingCompleted", "YES"]
        app.withoutSpaceSync()
        app.launch()

        XCTAssertTrue(app.navigationBars["Workouts"].waitForExistence(timeout: 8))
        for _ in 0..<6 { app.swipeUp() }
        XCTAssertFalse(app.buttons["Guided plans"].exists)
        XCTAssertFalse(app.buttons["workouts.guidedPlans"].exists)
    }

    /// Five tabs, no "More" overflow: Rhythm is gone and Routines moved under Plan's "…" menu.
    func testTabBarIsPlanWorkoutsNutritionNotesLibrary() throws {
        // An iPad's sections are its sidebar's: `AdaptiveShellUITest`.
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "the phone's tab bar")
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview", "--ui-audit", "-onboardingCompleted", "YES"]
        app.withoutSpaceSync()
        app.launch()

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 8))
        for tab in ["Plan", "Body", "Notes", "Library"] {
            XCTAssertTrue(tabBar.buttons[tab].exists, "Missing tab: \(tab)")
        }
        for gone in ["Rhythm", "Routines", "More", "Workouts", "Nutrition", "Add"] {
            XCTAssertFalse(tabBar.buttons[gone].exists, "Tab should be gone: \(gone)")
        }

        // Workouts and Nutrition share Body, with one switch across both. It launches on Plan:
        // the switch is Body's, so open Body first.
        tabBar.buttons["Body"].tap()
        let pages = app.segmentedControls["body.switch"]
        XCTAssertTrue(pages.waitForExistence(timeout: 4), app.debugDescription)
        pages.buttons["Workouts"].tap()
        XCTAssertTrue(app.navigationBars["Workouts"].waitForExistence(timeout: 3))
        app.segmentedControls["body.switch"].buttons.element(boundBy: 1).tap()
        XCTAssertTrue(app.navigationBars["Food"].waitForExistence(timeout: 3))
        keepScreenshot(of: app, named: "Shell - five tabs")
    }

    func testPodcastConfigurationLivesBehindCog() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--library-detail", "--ui-audit",
            "-onboardingCompleted", "YES"
        ]
        app.withoutSpaceSync()
        app.launch()

        let settings = app.buttons["podcast.settings.button"]
        XCTAssertTrue(settings.waitForExistence(timeout: 8))
        XCTAssertFalse(app.descendants(matching: .any)["podcast.settings.autoSkip"].exists)
        settings.tap()

        XCTAssertTrue(app.navigationBars["Podcast settings"].waitForExistence(timeout: 3))
        let autoSkip = app.descendants(matching: .any)["podcast.settings.autoSkip"]
        XCTAssertTrue(autoSkip.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@",
            "Automatically skips publisher pre-roll when starting a new episode. Resuming keeps your saved position.")).firstMatch.exists)

        // Exercise the setting instead of treating a visible picker as proof. The value must
        // survive dismissing and reopening the configuration sheet in the same catalogue session.
        autoSkip.tap()
        let thirtySeconds = app.buttons["30 seconds"]
        XCTAssertTrue(thirtySeconds.waitForExistence(timeout: 3))
        thirtySeconds.tap()
        XCTAssertTrue(app.staticTexts["30 seconds"].waitForExistence(timeout: 3))
        app.buttons["Done"].tap()
        settings.tap()
        XCTAssertTrue(app.navigationBars["Podcast settings"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["30 seconds"].exists)
        keepScreenshot(of: app, named: "Podcast - settings behind cog")
    }

    func testMobileDayPagesRenderDifferentDatesAndEventIDs() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--day", "--ui-audit", "--calendar-viewport-audit", "--calendar-business-hours-sample",
            "-mobileDayScrollOffset", "560", "-mobileWeekHourHeight", "56",
            "-onboardingCompleted", "YES"
        ]
        app.withoutSpaceSync()
        app.launch()

        let grid = timeGrid(app)
        XCTAssertTrue(grid.waitForExistence(timeout: 8))
        func snapshot() -> String { app.calendarDaySnapshot(referenceID: "mobile.day.surface.1") ?? "" }
        XCTAssertTrue(waitUntil {
            let value = snapshot().split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            return value.count == 2 && !value[1].isEmpty
        }, "Wait for today's fixture events, not only the day header")
        func page(forward: Bool) {
            let startX = forward ? 0.72 : 0.12
            let endX = forward ? 0.12 : 0.72
            let before = snapshot()
            grid.coordinate(withNormalizedOffset: CGVector(dx: startX, dy: 0.80))
                .press(
                    forDuration: 0,
                    thenDragTo: grid.coordinate(
                        withNormalizedOffset: CGVector(dx: endX, dy: 0.80)
                    )
                )
            XCTAssertTrue(waitUntil(timeout: 4) { snapshot() != before })
        }

        let today = snapshot()
        XCTAssertFalse(today.isEmpty)
        page(forward: true)
        let tomorrow = snapshot()
        page(forward: false)
        page(forward: false)
        let yesterday = snapshot()

        let snapshots = [yesterday, today, tomorrow]
        XCTAssertEqual(Set(snapshots).count, 3, "Each page must expose its own date and event IDs")
        let eventIDs = snapshots.map { value in
            value.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                .last.map(String.init) ?? ""
        }
        XCTAssertFalse(eventIDs[1].isEmpty, "Today's fixture should contain event IDs")
        XCTAssertNotEqual(eventIDs[0], eventIDs[1], "Yesterday rendered today's events")
        XCTAssertNotEqual(eventIDs[1], eventIDs[2], "Tomorrow rendered today's events")
    }

    func testMobileDayPagesWhenSwipeStartsOnBlankTime() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--day", "--ui-audit", "--reset-day-scroll-offset",
            "-onboardingCompleted", "YES"
        ]
        app.withoutSpaceSync()
        app.launch()

        // The identifier decorates the header's two labels as well as the container. The third
        // matching accessibility node is the actual page/grid surface used for the drag.
        let grid = timeGrid(app)
        XCTAssertTrue(grid.waitForExistence(timeout: 8))
        // The title HStack contains both “Today” and the date; target its visible leading text.
        let title = app.staticTexts.matching(identifier: "mobile.day.title").firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        let before = title.value as? String
        XCTAssertNotNil(before)

        // This is deliberately blank in the deterministic fixture. The drag has to begin in
        // the empty grid, not on an event, because that is the interaction users depend on.
        let start = grid.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.80))
        let end = grid.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.80))
        start.press(forDuration: 0, thenDragTo: end)

        let changed = NSPredicate(format: "value != %@", before ?? "")
        expectation(for: changed, evaluatedWith: title)
        waitForExpectations(timeout: 4)
    }

    func testMobileDayTimeGridStillScrollsVertically() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--day", "--ui-audit", "--reset-day-scroll-offset",
            "-onboardingCompleted", "YES"
        ]
        app.withoutSpaceSync()
        app.launch()

        let grid = timeGrid(app)
        XCTAssertTrue(grid.waitForExistence(timeout: 8))
        let hour = app.staticTexts["1 AM"]
        XCTAssertTrue(hour.waitForExistence(timeout: 3))
        XCTAssertTrue(hour.isHittable, "Expected the initial hour to be visible")

        // Inject into the visible blank canvas rather than an accessibility proxy: this is the
        // same target a finger uses and avoids XCTest choosing the nested horizontal scroller.
        let start = grid.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.78))
        let end = grid.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.32))
        start.press(forDuration: 0, thenDragTo: end)
        let moved = NSPredicate(format: "isHittable == false")
        expectation(for: moved, evaluatedWith: hour)
        waitForExpectations(timeout: 3)
    }

    func testMobileDayLongPressDragCreatesEvent() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--day", "--ui-audit", "--reset-day-scroll-offset",
            "-onboardingCompleted", "YES"
        ]
        app.withoutSpaceSync()
        app.launch()

        let grid = timeGrid(app)
        XCTAssertTrue(grid.waitForExistence(timeout: 8))

        // The reset route starts at midnight. Hold in the blank early-hours column, then drag
        // downward to select a duration. This is the interaction the UIKit Day host accidentally
        // dropped while its single-tap shortcut continued to work.
        grid.coordinate(withNormalizedOffset: CGVector(dx: 0.78, dy: 0.18))
            .press(
                forDuration: 0.55,
                thenDragTo: grid.coordinate(withNormalizedOffset: CGVector(dx: 0.78, dy: 0.38))
            )

        XCTAssertTrue(
            app.navigationBars["New event"].waitForExistence(timeout: 4),
            "Long-pressing and dragging an empty Day slot did not create an event"
        )
        XCTAssertTrue(app.textFields["What’s happening?"].exists)
        keepScreenshot(of: app, named: "Day - long press drag creates event")
    }

    func testMobileDayPagingPreservesTimePosition() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--day", "--ui-audit", "--reset-day-scroll-offset",
            "-onboardingCompleted", "YES"
        ]
        app.withoutSpaceSync()
        app.launch()

        let grid = timeGrid(app)
        XCTAssertTrue(grid.waitForExistence(timeout: 8))
        let earlyHour = app.staticTexts["1 AM"]
        XCTAssertTrue(earlyHour.waitForExistence(timeout: 3))

        let verticalStart = grid.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.78))
        let verticalEnd = grid.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.32))
        verticalStart.press(forDuration: 0, thenDragTo: verticalEnd)
        XCTAssertFalse(earlyHour.isHittable)

        let title = app.staticTexts.matching(identifier: "mobile.day.title").firstMatch
        let before = title.value as? String
        let horizontalStart = grid.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.80))
        let horizontalEnd = grid.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.80))
        horizontalStart.press(forDuration: 0, thenDragTo: horizontalEnd)
        expectation(for: NSPredicate(format: "value != %@", before ?? ""), evaluatedWith: title)
        waitForExpectations(timeout: 4)
        XCTAssertFalse(earlyHour.isHittable, "Paging must keep the current vertical time position")
    }

    func testMobileDayRepeatedPagingPreservesExactTimePosition() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--day", "--ui-audit", "--reset-day-scroll-offset",
            "-onboardingCompleted", "YES"
        ]
        app.withoutSpaceSync()
        app.launch()

        let grid = timeGrid(app)
        XCTAssertTrue(grid.waitForExistence(timeout: 8))
        let surface = app.descendants(matching: .any)
            .matching(identifier: "mobile.day.surface.1")
            .firstMatch
        XCTAssertTrue(surface.waitForExistence(timeout: 3))

        grid.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.78))
            .press(
                forDuration: 0,
                thenDragTo: grid.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.38))
            )

        let hourLabels = [
            "6 AM", "7 AM", "8 AM", "9 AM", "10 AM", "11 AM", "12 PM",
            "1 PM", "2 PM", "3 PM", "4 PM", "5 PM", "6 PM", "7 PM"
        ]
        guard let referenceHour = hourLabels.lazy.map({ app.staticTexts[$0] }).first(where: {
            $0.exists && $0.isHittable
        }) else {
            return XCTFail("Vertical scroll left no visible hour label to compare across pages")
        }
        // Measured from the top of the grid, not of the screen: a day with something above its
        // hours (an all-day event, a routine moment that's due) sits lower on the screen than one
        // without, and that is not the grid losing its place.
        let positionInGrid = { referenceHour.frame.minY - self.timeGrid(app).frame.minY }
        let referenceY = positionInGrid()

        for forward in [true, true, false, false] {
            let before = surface.value as? String ?? ""
            let started = Date()
            grid.coordinate(
                withNormalizedOffset: CGVector(dx: forward ? 0.72 : 0.12, dy: 0.80)
            ).press(
                forDuration: 0,
                thenDragTo: grid.coordinate(
                    withNormalizedOffset: CGVector(dx: forward ? 0.12 : 0.72, dy: 0.80)
                ),
                // This measures a page flick, as the vertical checks do. A slow
                // synthesized drag consumes most of the response limit itself.
                withVelocity: .fast, thenHoldForDuration: 0
            )
            let deadline = started.addingTimeInterval(pageLimit)
            var after = surface.value as? String
            while Date() < deadline, after == before {
                usleep(20_000)
                after = surface.value as? String
            }
            // Stop the clock when the new page is observed. Another accessibility read
            // inside the assertion measures XCTest's round trip after the page is ready.
            let elapsed = Date().timeIntervalSince(started)
            XCTAssertNotEqual(after, before, "Adjacent-day swipe did not change date")
            XCTAssertLessThan(
                elapsed,
                pageLimit,
                "Adjacent-day swipe did not update promptly"
            )
            XCTAssertEqual(
                positionInGrid(),
                referenceY,
                accuracy: 2,
                "Adjacent-day swipe changed the visible time position"
            )
        }
        keepScreenshot(of: app, named: "Day - repeated paging preserves exact time position")
    }

    func testMobileDayDenseCalendarScrollAndPagingPerformance() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--day", "--ui-audit", "--dense-day-regression", "--perf-trace",
            "--reset-day-scroll-offset", "-onboardingCompleted", "YES"
        ]
        app.withoutSpaceSync()
        app.launch()

        func grid() -> XCUIElement {
            timeGrid(app)
        }
        XCTAssertTrue(grid().waitForExistence(timeout: 10))
        let surface = app.descendants(matching: .any)
            .matching(identifier: "mobile.day.surface.1")
            .firstMatch
        XCTAssertTrue(surface.waitForExistence(timeout: 3))
        let eventIDs = (surface.value as? String ?? "")
            .split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            .last?
            .split(separator: ",") ?? []
        XCTAssertGreaterThan(eventIDs.count, 50, "Dense-day route did not load its stress calendar")

        let probe = app.descendants(matching: .any)["day.performance.renderCount"]
        XCTAssertTrue(probe.waitForExistence(timeout: 2))
        let renderBaseline = Int(probe.value as? String ?? "") ?? .max
        XCTAssertNotEqual(renderBaseline, .max)

        let options = XCTMeasureOptions()
        options.iterationCount = 6
        var iteration = 0
        measure(
            metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric],
            options: options
        ) {
            if iteration.isMultiple(of: 2) {
                grid().swipeUp(velocity: .fast)
            } else {
                grid().swipeDown(velocity: .fast)
            }
            iteration += 1
        }

        sleep(2)
        let renderDelta = (Int(probe.value as? String ?? "") ?? .max) - renderBaseline
        XCTAssertLessThan(renderDelta, 20, "Dense vertical scrolling rebuilt Day \(renderDelta) times")

        let before = surface.value as? String ?? ""
        grid().coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.80))
            .press(
                forDuration: 0,
                thenDragTo: grid().coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.80))
            )
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline, surface.value as? String == before { usleep(20_000) }
        XCTAssertNotEqual(surface.value as? String, before, "Dense adjacent day did not appear promptly")
        keepScreenshot(of: app, named: "Day - dense calendar after measured scroll and page")
    }

    func testMobileDaySparseCalendarScrollPerformanceBaseline() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--day", "--ui-audit", "--reset-day-scroll-offset",
            "-onboardingCompleted", "YES"
        ]
        app.withoutSpaceSync()
        app.launch()

        let grid = timeGrid(app)
        XCTAssertTrue(grid.waitForExistence(timeout: 10))

        let options = XCTMeasureOptions()
        options.iterationCount = 6
        var iteration = 0
        measure(
            metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric],
            options: options
        ) {
            if iteration.isMultiple(of: 2) {
                grid.swipeUp(velocity: .fast)
            } else {
                grid.swipeDown(velocity: .fast)
            }
            iteration += 1
        }
    }

    func testMobileDayAdjacentPageUsesCacheThenBackfillsWithoutJumping() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--day", "--ui-audit", "--day-cache-backfill-regression",
            "--simulate-planning-provider-delay-ms", "2000",
            "--reset-day-scroll-offset", "-onboardingCompleted", "YES"
        ]
        app.withoutSpaceSync()
        app.launch()

        let grid = timeGrid(app)
        XCTAssertTrue(grid.waitForExistence(timeout: 8))
        let surface = app.descendants(matching: .any)
            .matching(identifier: "mobile.day.surface.1")
            .firstMatch
        XCTAssertTrue(surface.waitForExistence(timeout: 3))

        grid.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.78))
            .press(
                forDuration: 0,
                thenDragTo: grid.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.38))
            )
        let hourLabels = [
            "6 AM", "7 AM", "8 AM", "9 AM", "10 AM", "11 AM", "12 PM",
            "1 PM", "2 PM", "3 PM", "4 PM", "5 PM", "6 PM", "7 PM"
        ]
        guard let referenceHour = hourLabels.lazy.map({ app.staticTexts[$0] }).first(where: {
            $0.exists && $0.isHittable
        }) else {
            return XCTFail("Vertical scroll left no visible hour label to compare across pages")
        }
        // Measured from the top of the grid, not of the screen: a day with something above its
        // hours (an all-day event, a routine moment that's due) sits lower on the screen than one
        // without, and that is not the grid losing its place.
        let positionInGrid = { referenceHour.frame.minY - self.timeGrid(app).frame.minY }
        let referenceY = positionInGrid()

        grid.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.80))
            .press(
                forDuration: 0,
                thenDragTo: grid.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.80))
            )
        let cacheDeadline = Date().addingTimeInterval(0.45)
        while Date() < cacheDeadline,
              !(surface.value as? String ?? "").contains("cache-neighbor") {
            usleep(20_000)
        }
        XCTAssertTrue(
            (surface.value as? String ?? "").contains("cache-neighbor"),
            "Adjacent Day did not paint from the overlapping cache immediately"
        )
        XCTAssertEqual(
                positionInGrid(),
                referenceY, accuracy: 2)

        let prematureDeadline = Date().addingTimeInterval(0.75)
        while Date() < prematureDeadline,
              !(surface.value as? String ?? "").contains("fresh-neighbor") {
            usleep(20_000)
        }
        XCTAssertFalse(
            (surface.value as? String ?? "").contains("fresh-neighbor"),
            "Simulated provider delay did not hold back fresh data"
        )

        let freshDeadline = Date().addingTimeInterval(5)
        while Date() < freshDeadline,
              !(surface.value as? String ?? "").contains("fresh-neighbor") {
            usleep(20_000)
        }
        let backfilled = surface.value as? String ?? ""
        XCTAssertTrue(backfilled.contains("fresh-neighbor"), "Fresh provider data never backfilled")
        XCTAssertTrue(backfilled.contains("cache-neighbor"), "Backfill blanked cached Day content: \(backfilled)")
        XCTAssertEqual(
                positionInGrid(),
                referenceY,
            accuracy: 2,
            "Backfill changed the visible time position"
        )
        sleep(1) // Let XCTest's compositor settle after the insertion animation.
        keepScreenshot(of: app, named: "Day - adjacent cache with smooth backfill")
    }

    func testMobileDayPinchZoomStillChangesHourDensity() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--day", "--ui-audit",
            "--reset-day-scroll-offset",
            "-mobileWeekHourHeight", "56",
            "-onboardingCompleted", "YES"
        ]
        app.withoutSpaceSync()
        app.launch()

        let grid = timeGrid(app)
        XCTAssertTrue(grid.waitForExistence(timeout: 8))
        let firstHour = app.staticTexts["1 AM"]
        let secondHour = app.staticTexts["2 AM"]
        XCTAssertTrue(firstHour.waitForExistence(timeout: 3))
        XCTAssertTrue(secondHour.exists)
        let originalSpacing = secondHour.frame.minY - firstHour.frame.minY

        grid.pinch(withScale: 1.5, velocity: 1)
        let expanded = NSPredicate { _, _ in
            secondHour.frame.minY - firstHour.frame.minY > originalSpacing * 1.25
        }
        expectation(for: expanded, evaluatedWith: grid)
        waitForExpectations(timeout: 3)
        keepScreenshot(of: app, named: "Day - pinch zoomed hour density")
    }

    func testMobileDayScrollPositionSurvivesProcessRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--day", "--ui-audit", "--reset-day-scroll-offset",
            "-onboardingCompleted", "YES"
        ]
        app.withoutSpaceSync()
        app.launch()

        let grid = timeGrid(app)
        XCTAssertTrue(grid.waitForExistence(timeout: 8))
        let earlyHour = app.staticTexts["1 AM"]
        XCTAssertTrue(earlyHour.waitForExistence(timeout: 3))
        XCTAssertTrue(earlyHour.isHittable)

        grid.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.78))
            .press(
                forDuration: 0,
                thenDragTo: grid.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.24))
            )
        expectation(for: NSPredicate(format: "isHittable == false"), evaluatedWith: earlyHour)
        waitForExpectations(timeout: 3)
        app.terminate()

        app.launchArguments.removeAll { $0 == "--reset-day-scroll-offset" }
        app.withoutSpaceSync()
        app.launch()
        let relaunchedGrid = timeGrid(app)
        XCTAssertTrue(relaunchedGrid.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["1 AM"].exists)
        XCTAssertFalse(
            app.staticTexts["1 AM"].isHittable,
            "Relaunch reconstructed Day at the top instead of its saved time position"
        )
    }

    func testMobileDayStaysResponsiveDuringUnrelatedLibraryPublishStorm() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-preview", "--day", "--ui-audit",
            "--library-publish-regression", "--reset-day-scroll-offset",
            "-onboardingCompleted", "YES"
        ]
        app.withoutSpaceSync()
        app.launch()

        let grid = timeGrid(app)
        XCTAssertTrue(grid.waitForExistence(timeout: 8))
        let earlyHour = app.staticTexts["1 AM"]
        XCTAssertTrue(earlyHour.waitForExistence(timeout: 3))

        let started = Date()
        grid.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.78))
            .press(
                forDuration: 0,
                thenDragTo: grid.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.24))
            )
        expectation(for: NSPredicate(format: "isHittable == false"), evaluatedWith: earlyHour)
        waitForExpectations(timeout: 3)
        XCTAssertLessThan(Date().timeIntervalSince(started), flickLimit)

        // The synthetic source publishes for six seconds. In the broken build it invalidated the
        // root and rebuilt WeekView roughly once per publication; the isolated Plan subtree should
        // remain in the low single digits.
        sleep(7)
        let probe = app.descendants(matching: .any)["day.performance.renderCount"]
        XCTAssertTrue(probe.exists)
        let renders = Int(probe.value as? String ?? "") ?? .max
        XCTAssertLessThan(renders, 20, "Library changes rebuilt the Day calendar \(renders) times")
    }

    /// The production failure repeatedly invalidated WeekView while a native scroll was in flight.
    /// A UIKit-owned gesture is not enough if every parent update replaces its hosted SwiftUI grid.
    func testMobileDayScrollStaysResponsiveDuringCalendarPublicationStorm() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--day", "--ui-audit", "--storm-selftest", "--reset-day-scroll-offset",
            "-onboardingCompleted", "YES"
        ]
        app.withoutSpaceSync()
        app.launch()

        let grid = timeGrid(app)
        XCTAssertTrue(grid.waitForExistence(timeout: 8))
        let earlyHour = app.staticTexts["1 AM"]
        XCTAssertTrue(earlyHour.waitForExistence(timeout: 3))

        let started = Date()
        grid.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.78))
            .press(
                forDuration: 0,
                thenDragTo: grid.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.24))
            )
        expectation(for: NSPredicate(format: "isHittable == false"), evaluatedWith: earlyHour)
        waitForExpectations(timeout: 3)
        XCTAssertLessThan(
            Date().timeIntervalSince(started),
            flickLimit,
            "Calendar publications prevented XCTest from delivering the vertical flick"
        )

        sleep(7)
        let probe = app.descendants(matching: .any)["day.performance.renderCount"]
        XCTAssertTrue(probe.exists)
        let renders = Int(probe.value as? String ?? "") ?? .max
        XCTAssertLessThan(
            renders,
            20,
            "Transient calendar publications rebuilt the full Day calendar \(renders) times"
        )
    }

    /// Smart Schedule legitimately publishes several non-calendar fields while launch settles.
    /// Those status-only publications must not rebuild the separately hosted 24-hour Day surface.
    func testMobileDayIgnoresInvisibleSmartSchedulePublications() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-preview", "--ui-audit", "--smart-publish-regression",
            "--reset-day-scroll-offset", "-planMode", "day", "-onboardingCompleted", "YES"
        ]
        app.withoutSpaceSync()
        app.launch()

        let grid = timeGrid(app)
        XCTAssertTrue(grid.waitForExistence(timeout: 8))
        let earlyHour = app.staticTexts["1 AM"]
        XCTAssertTrue(earlyHour.waitForExistence(timeout: 3))

        grid.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.78))
            .press(
                forDuration: 0,
                thenDragTo: grid.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.24))
            )
        expectation(for: NSPredicate(format: "isHittable == false"), evaluatedWith: earlyHour)
        waitForExpectations(timeout: 3)

        sleep(7)
        let probe = app.descendants(matching: .any)["day.performance.renderCount"]
        XCTAssertTrue(probe.exists)
        let renders = Int(probe.value as? String ?? "") ?? .max
        XCTAssertLessThan(
            renders,
            20,
            "Invisible Smart Schedule publications rebuilt the Day calendar \(renders) times"
        )
    }

    /// Unlike the deterministic audit routes, this starts the complete production object graph,
    /// exercises the visible calendar after launch work has settled, backgrounds the app, and
    /// verifies the reconstructed tree returns to the saved time. Run on a test phone, never a simulator.
    func testMobileDayProductionStartupBackgroundAndVisualPerformance() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--perf-trace", "--reset-day-scroll-offset",
            "-planMode", "day", "-onboardingCompleted", "YES"
        ]
        app.withoutSpaceSync()
        app.launch()

        let grid = timeGrid(app)
        XCTAssertTrue(grid.waitForExistence(timeout: 20), "Production startup did not reach Day")
        sleep(18) // include the full launch publication/service burst in the on-device trace
        keepScreenshot(of: app, named: "Device production Day after startup")

        let earlyHour = app.staticTexts["1 AM"]
        let started = Date()
        grid.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.78))
            .press(
                forDuration: 0,
                thenDragTo: grid.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.24))
            )
        expectation(for: NSPredicate(format: "isHittable == false"), evaluatedWith: earlyHour)
        waitForExpectations(timeout: 3)
        XCTAssertLessThan(
            Date().timeIntervalSince(started),
            flickLimit,
            "Production startup work left vertical scrolling unresponsive"
        )

        XCUIDevice.shared.press(.home)
        sleep(12)
        app.activate()
        let restoredGrid = timeGrid(app)
        XCTAssertTrue(restoredGrid.waitForExistence(timeout: 12))
        XCTAssertFalse(
            app.staticTexts["1 AM"].isHittable,
            "Background reconstruction discarded the saved time position"
        )
        keepScreenshot(of: app, named: "Device production Day after background return")
    }

    /// Regression for the production-only failure seen on a large real calendar. The old
    /// 18-second/one-flick test passed while a chain of calendar recomputes was still gathering
    /// momentum. This keeps the full object graph alive long enough to catch that chain, stresses
    /// native vertical scrolling repeatedly, then verifies both background and process restoration.
    func testMobileDayProductionSustainedScrollingBackgroundAndRelaunch() {
        // Startup settling, 45 quiet seconds and a minute in the background already
        // consume most of three minutes before the gestures and relaunch are counted.
        executionTimeAllowance = 300
        let app = XCUIApplication()
        app.launchArguments = [
            "--perf-trace", "--reset-day-scroll-offset",
            "-planMode", "day", "-onboardingCompleted", "YES"
        ]
        app.withoutSpaceSync()
        app.launch()

        func grid() -> XCUIElement {
            timeGrid(app)
        }
        func renderCount() -> Int {
            let probe = app.descendants(matching: .any)["day.performance.renderCount"]
            return Int(probe.value as? String ?? "") ?? .max
        }

        XCTAssertTrue(grid().waitForExistence(timeout: 20), "Production startup did not reach Day")
        sleep(25)
        keepScreenshot(of: app, named: "Device sustained production Day after startup")
        let idleBaseline = renderCount()
        XCTAssertNotEqual(idleBaseline, .max, "Missing production render-count probe")

        // Alternate long, fast vertical flicks. The UIScrollView should consume these without
        // waiting for calendar work or causing WeekView itself to rebuild per frame.
        for index in 0..<12 {
            let down = index.isMultiple(of: 2)
            let startY = down ? 0.78 : 0.25
            let endY = down ? 0.25 : 0.78
            let started = Date()
            grid().coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: startY))
                .press(
                    forDuration: 0,
                    thenDragTo: grid().coordinate(
                        withNormalizedOffset: CGVector(dx: 0.72, dy: endY)
                    )
                )
            XCTAssertLessThan(
                Date().timeIntervalSince(started),
                flickLimit,
                "Vertical flick \(index + 1) blocked behind production calendar work"
            )
        }

        // The phone failure accumulated five full recomputes and >400 Week bodies in one minute.
        // Forty-five quiet seconds after the interaction burst must remain genuinely quiet.
        sleep(45)
        let idleRenders = renderCount() - idleBaseline
        XCTAssertLessThan(
            idleRenders,
            30,
            "Day rebuilt \(idleRenders) times during a quiet production minute"
        )
        keepScreenshot(of: app, named: "Device sustained production Day after repeated flicks")

        // Finish at a clearly non-zero offset, then hold the app in the background long enough
        // for EventKit/provider echoes and the watchdog's background sample to fire.
        grid().coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.78))
            .press(
                forDuration: 0,
                thenDragTo: grid().coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.18))
            )
        let earlyHour = app.staticTexts["1 AM"]
        expectation(for: NSPredicate(format: "isHittable == false"), evaluatedWith: earlyHour)
        waitForExpectations(timeout: 3)

        XCUIDevice.shared.press(.home)
        sleep(60)
        app.activate()
        XCTAssertTrue(grid().waitForExistence(timeout: 15))
        XCTAssertFalse(earlyHour.isHittable, "Background return reset Day to the top")
        keepScreenshot(of: app, named: "Device sustained production Day after one-minute background")

        app.terminate()
        app.launchArguments.removeAll { $0 == "--reset-day-scroll-offset" }
        app.withoutSpaceSync()
        app.launch()
        XCTAssertTrue(grid().waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["1 AM"].exists)
        XCTAssertFalse(app.staticTexts["1 AM"].isHittable, "Process relaunch reset Day to the top")
        sleep(20)
        keepScreenshot(of: app, named: "Device sustained production Day after process relaunch")
    }

    /// The test phone's EventKit store is too small to reproduce a large calendar's multi-second recompute naturally.
    /// Hold each pass open so launch, wake-plan, and EventKit callbacks overlap exactly as they do
    /// on a large calendar, then prove the drain is bounded and native scrolling stays available.
    func testMobileDaySlowCalendarRecomputeDoesNotChainOrBlockScrolling() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--perf-trace", "--slow-occurrence-recompute-regression",
            "--reset-day-scroll-offset", "-planMode", "day", "-onboardingCompleted", "YES"
        ]
        app.withoutSpaceSync()
        app.launch()

        let grid = timeGrid(app)
        XCTAssertTrue(grid.waitForExistence(timeout: 20))

        let started = Date()
        grid.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.78))
            .press(
                forDuration: 0,
                thenDragTo: grid.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.22))
            )
        expectation(
            for: NSPredicate(format: "isHittable == false"),
            evaluatedWith: app.staticTexts["1 AM"]
        )
        waitForExpectations(timeout: 3)
        XCTAssertLessThan(
            Date().timeIntervalSince(started),
            flickLimit,
            "A deliberately slow calendar pass blocked native vertical scrolling"
        )

        sleep(24) // two five-second passes plus both debounce windows would have settled by now
        let probe = app.descendants(matching: .any)["day.performance.recomputeCount"]
        XCTAssertTrue(probe.exists)
        let passes = Int(probe.value as? String ?? "") ?? .max
        XCTAssertLessThanOrEqual(
            passes,
            2,
            "Overlapping startup/calendar callbacks chained \(passes) full occurrence passes"
        )
    }

    /// Focused physical-device evidence using the installed app's EventKit store, not fixtures.
    /// This test is intentionally selected by name in the device validation command rather than
    /// included in broad screenshot runs, because its contents depend on that phone's calendar.
    func testMobileDayRealCalendarVisualAndInteractionPerformance() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Reads the phone's own calendar; a simulator has none.")
        #endif
        let app = XCUIApplication()
        app.launchArguments = [
            "--day-real-calendar",
            "--reset-day-scroll-offset",
            "-mobileWeekHourHeight", "56",
            "-onboardingCompleted", "YES"
        ]
        app.withoutSpaceSync()
        app.launch()

        let grid = timeGrid(app)
        XCTAssertTrue(grid.waitForExistence(timeout: 12), "The phone did not reach the Day calendar")
        let surface = app.descendants(matching: .any)
            .matching(identifier: "mobile.day.surface.1")
            .firstMatch
        XCTAssertTrue(surface.waitForExistence(timeout: 4))

        // Let the normal (non-fixture) EventKit refresh settle before recording its evidence.
        sleep(2)
        let today = surface.value as? String ?? ""
        XCTAssertFalse(today.isEmpty)
        keepScreenshot(of: app, named: "Device real calendar - today")

        let scrollStarted = Date()
        grid.coordinate(withNormalizedOffset: CGVector(dx: 0.10, dy: 0.78))
            .press(
                forDuration: 0,
                thenDragTo: grid.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.10, dy: 0.24)
                )
            )
        let verticalFlickDuration = Date().timeIntervalSince(scrollStarted)
        XCTAssertLessThan(
            verticalFlickDuration,
            flickLimit,
            "A single vertical flick blocked the UI instead of scrolling responsively"
        )
        let earlyHour = app.staticTexts["1 AM"]
        expectation(for: NSPredicate(format: "isHittable == false"), evaluatedWith: earlyHour)
        waitForExpectations(timeout: 3)
        usleep(500_000) // keep screenshot capture outside the measured interaction interval
        keepScreenshot(of: app, named: "Device real calendar - after vertical flick")

        var pageDurations: [TimeInterval] = []
        func page(forward: Bool, screenshotName: String) -> String {
            let before = surface.value as? String ?? ""
            let started = Date()
            grid.coordinate(
                withNormalizedOffset: CGVector(dx: forward ? 0.72 : 0.12, dy: 0.80)
            ).press(
                forDuration: 0,
                thenDragTo: grid.coordinate(
                    withNormalizedOffset: CGVector(dx: forward ? 0.12 : 0.72, dy: 0.80)
                )
            )
            expectation(for: NSPredicate(format: "value != %@", before), evaluatedWith: surface)
            waitForExpectations(timeout: 3)
            let duration = Date().timeIntervalSince(started)
            pageDurations.append(duration)
            XCTAssertLessThan(
                duration,
                3.5,
                "Changing days did not render the destination promptly"
            )
            keepScreenshot(of: app, named: screenshotName)
            return surface.value as? String ?? ""
        }

        let tomorrow = page(forward: true, screenshotName: "Device real calendar - tomorrow")
        _ = page(forward: false, screenshotName: "Device real calendar - today restored")
        let yesterday = page(forward: false, screenshotName: "Device real calendar - yesterday")
        XCTAssertEqual(
            Set([today, tomorrow, yesterday]).count,
            3,
            "Adjacent real-calendar pages exposed the same date/event snapshot"
        )

        let timingEvidence = ([verticalFlickDuration] + pageDurations)
            .map { String(format: "%.3f", $0) }
            .joined(separator: ", ")
        let evidence = """
        INTERACTION SECONDS (vertical, next, previous, previous)
        \(timingEvidence)

        TODAY
        \(today)

        TOMORROW
        \(tomorrow)

        YESTERDAY
        \(yesterday)
        """
        let attachment = XCTAttachment(string: evidence)
        attachment.name = "Device real-calendar date and ordered event IDs"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testPlanCanOpenNewReminderSheet() {
        let app = XCUIApplication()
        // As a person opens it: the Plan tab, whose top bar holds the +.
        app.launchArguments = ["--ui-preview", "--plan", "-planMode", "day", "--tab", "plan", "--ui-audit", "--disable-icloud", "--no-space-sync",
                               "-onboardingCompleted", "YES", "-finishSetupDismissed", "YES"]
        app.withoutSpaceSync()
        app.launch()

        let add = app.plus("mobile.week.newEvent")
        XCTAssertTrue(add.waitForExistence(timeout: 8), "the plan has no creation entry point")
        add.tap()
        let newTask = app.buttons["mobile.week.newTask"]
        XCTAssertTrue(newTask.waitForExistence(timeout: 3))
        newTask.tap()

        XCTAssertTrue(app.navigationBars["New reminder"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.textFields["What needs doing?"].exists)
        XCTAssertTrue(app.switches["Schedule a time"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["task.duration"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["task.priority"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["task.recurrence"].exists)

        // The title field autofocuses on open, so the keyboard covers roughly the bottom half
        // of the sheet before Notes (the form's last section) is ever laid out. A drag has to
        // start on real form content above the keyboard — one starting on the keyboard itself
        // is just a swipe across keys — to both scroll the form and interactively dismiss the
        // keyboard the way a person's own drag would.
        let formAboveKeyboard = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.32))
        let nearTop = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08))
        formAboveKeyboard.press(forDuration: 0.05, thenDragTo: nearTop)

        let notes = app.descendants(matching: .any)["task.notes"]
        XCTAssertTrue(
            scrollUntilHittable(notes, in: app),
            "Notes should be reachable by dismissing the keyboard and scrolling, not permanently hidden below the fold"
        )
        XCTAssertTrue(app.buttons["Save"].exists)
        keepScreenshot(of: app, named: "Plan - New reminder")
    }

    func testPlanCanOpenNewCalendarEventSheet() {
        let app = XCUIApplication()
        // As a person opens it: the Plan tab, whose top bar holds the +.
        app.launchArguments = ["--ui-preview", "--plan", "-planMode", "day", "--tab", "plan", "--ui-audit", "--disable-icloud", "--no-space-sync",
                               "-onboardingCompleted", "YES", "-finishSetupDismissed", "YES"]
        app.withoutSpaceSync()
        app.launch()

        let add = app.plus("mobile.week.newEvent")
        XCTAssertTrue(add.waitForExistence(timeout: 8), "the plan has no creation entry point")
        add.tap()
        let newEvent = app.buttons["mobile.week.add.event"]
        XCTAssertTrue(newEvent.waitForExistence(timeout: 3))
        newEvent.tap()

        // The sheet's own fields have their own tests (EventPhrase, EventGuests, EventRepeat,
        // TimeWheelTap); this one is that the plan opens it.
        XCTAssertTrue(app.navigationBars["New event"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.textFields["event.title"].exists)
        XCTAssertTrue(app.staticTexts["Starts"].exists)
        XCTAssertTrue(app.buttons["event.save"].exists)
        keepScreenshot(of: app, named: "Plan - New calendar event")
    }

    func testMobileWeekIsSchedulableAndCreatesAFullEvent() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--week", "--ui-audit",
            "-planMode", "week",
            "-mobileWeekLayout", "calendar",
            "-onboardingCompleted", "YES"
        ]
        app.withoutSpaceSync()
        app.launch()

        XCTAssertTrue(app.plus("mobile.week.newEvent").waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any)["mobile.week.timeGrid"].exists)
        XCTAssertTrue(app.buttons["mobile.week.more"].exists)
        XCTAssertTrue(app.buttons["Previous week"].exists)
        XCTAssertTrue(app.buttons["Next week"].exists)

        // "…" ends with Settings on every page; a reminder is added from + and nowhere else.
        app.buttons["mobile.week.more"].tap()
        XCTAssertTrue(app.buttons["page.more.settings"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["New task"].exists)
        // Dismiss the "more" menu without risking a landing on the day grid: any tap on the
        // grid's background — not just its empty cells, the whole column — opens a new-event
        // sheet via its tap-to-create gesture (`mobileDayColumn`'s `SpatialTapGesture`), so a
        // coordinate picked to graze "empty space" is only as safe as the grid's own layout
        // (gutter width, header height) happens to be that day. The already-selected "Week"
        // segment is a real, always-present control outside the grid entirely — tapping it
        // dismisses the menu like any outside tap, and re-selecting the current segment is a
        // no-op, so it cannot itself change what's on screen.
        XCTAssertTrue(app.dismissNativeMenu(item: app.buttons["page.more.settings"]),
                      "More must be dismissed before opening a different menu")
        XCTAssertTrue(app.plus("mobile.week.newEvent").isHittable)

        app.plus("mobile.week.newEvent").tap()
        let newCalendarEvent = app.buttons["mobile.week.add.event"]
        XCTAssertTrue(newCalendarEvent.waitForExistence(timeout: 3), "The + menu should offer an event")
        newCalendarEvent.tap()
        XCTAssertTrue(app.navigationBars["New event"].waitForExistence(timeout: 3))
        // (It looked for a place field by an identifier the sheet no longer has.)
        XCTAssertTrue(app.textFields["event.title"].exists)
        XCTAssertTrue(app.buttons["event.save"].exists)
        keepScreenshot(of: app, named: "Mobile Week - Full calendar event")
    }

    func testFlightBoardingParserUsesOnlyExplicitSourceTimes() {
        let app = XCUIApplication()
        app.launchArguments = ["--verify-flight-boarding", "--ui-audit"]
        app.withoutSpaceSync()
        app.launch()
        XCTAssertTrue(app.staticTexts["BOARDING PARSER PASS"].waitForExistence(timeout: 8))
    }

    func testReturningUserDoesNotReplayOnboarding() {
        let app = XCUIApplication()
        app.launchArguments = ["-onboardingCompleted", "YES"]
        app.withoutSpaceSync()
        app.launch()

        XCTAssertFalse(
            app.buttons["onboarding.continue"].waitForExistence(timeout: 3),
            "A returning user was sent through the new-user onboarding story"
        )

        // Alarm authorization may or may not survive an app-identity migration. Either way the
        // returning user lands IN the app — a missing grant is an inline card on Today now, not a
        // screen in front of the product. Replaying unrelated permission pages is still wrong.
        let planner = app.buttons["Plan"]
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline, !planner.exists {
            usleep(100_000)
        }
        XCTAssertTrue(planner.exists,
                      "Returning user did not reach the app; a permission is still gating it")
        XCTAssertFalse(app.buttons["Get started"].exists)
        keepScreenshot(of: app, named: "Returning user - no repeated onboarding")
    }

    func testTimelineAssumptionsOnDevice() {
        let app = XCUIApplication()
        app.launchArguments = ["--verify-timeline"]
        app.withoutSpaceSync()
        app.launch()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allowLabels = ["Allow Full Access", "Allow", "Allow While Using App", "OK", "Continue"]

        // The harness waits up to ~45s for the alarm to fire, plus a count-limit sweep — give
        // it generous headroom. Poll: grant any pending permission dialog, then check for DONE.
        let deadline = Date().addingTimeInterval(180)
        var finished = false
        while Date() < deadline {
            for label in allowLabels {
                let button = springboard.buttons[label]
                if button.exists && button.isHittable { button.tap() }
            }
            let status = app.staticTexts["verify.status"]
            if status.exists && status.label == "DONE" { finished = true; break }
            sleep(1)
        }

        let summary = app.staticTexts["verify.summary"].exists ? app.staticTexts["verify.summary"].label : "(no summary)"
        let report = app.staticTexts["verify.report"].exists ? app.staticTexts["verify.report"].label : "(no report)"
        print("=== VERIFY SUMMARY ===\n\(summary)")
        print("=== VERIFY REPORT ===\n\(report)")
        add(XCTAttachment(string: "SUMMARY: \(summary)\n\nREPORT:\n\(report)"))

        XCTAssertTrue(finished, "verification harness did not reach DONE within the time budget")
        XCTAssertTrue(summary.contains("0 failed"), "assumptions failed — \(summary)")
    }

    private func allowPendingSystemPrompt(in springboard: XCUIApplication) {
        let labels = ["Allow Full Access", "Allow", "Allow While Using App", "OK", "Continue"]
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            for label in labels {
                let button = springboard.buttons[label]
                if button.exists && button.isHittable {
                    button.tap()
                    return
                }
            }
            usleep(100_000)
        }
    }

    private func keepScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Scrolls `app` upward until `element` is hittable, or gives up after `maxAttempts` swipes.
    /// A single blind swipe assumes a fixed amount of content sits above the target — that
    /// assumption breaks the moment a card, a chart, or an extra row is inserted upstream of it.
    /// Below-the-fold content in a scrollable list/form is normal; a real person reaches it by
    /// scrolling, so the test should too, however many swipes that takes.
    @discardableResult
    private func scrollUntilHittable(
        _ element: XCUIElement,
        in app: XCUIApplication,
        maxAttempts: Int = 8
    ) -> Bool {
        var attempts = 0
        while !element.isHittable && attempts < maxAttempts {
            app.swipeUp()
            attempts += 1
        }
        return element.isHittable
    }
}
