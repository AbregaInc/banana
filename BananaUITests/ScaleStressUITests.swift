import XCTest

/// Runs the real screen with every store overloaded at the same time. No provider services run.
final class ScaleStressUITests: XCTestCase {
    #if PHYSICAL_STRESS_UI_TESTS
    override func setUpWithError() throws {
        try super.setUpWithError()
        try PhysicalSystemIdlePolicy.installIfRequested()
    }
    #endif

    // These cases keep the full physical review history and the unchanged
    // Simulator baseline. Assert the intended workload, never the observed count.
    private var variedCalendarDays: Int {
        #if PHYSICAL_STRESS_UI_TESTS
        365
        #else
        30
        #endif
    }
    private func launch(_ route: String, extra: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        #if PHYSICAL_STRESS_UI_TESTS
        // This runner can only drive the separately installed physical review app.
        let app = XCUIApplication(bundleIdentifier: "com.boris.banana.stressreview")
        let defaultDays = "90"
        #else
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        let defaultDays = "30"
        #endif
        let days = ProcessInfo.processInfo.environment["STRESS_DAYS"] ?? defaultDays
        app.launchArguments = [route, "--stress-days", days, "--disable-icloud", "--mail-fresh",
                               "-onboardingCompleted", "YES"] + extra
        #if PHYSICAL_STRESS_UI_TESTS
        // Mail uses the same isolated fixture and provider-write guards as Calendar.
        if route == "--mail" { app.launchArguments += ["--stress-actionable-calendar"] }
        // Preserve the email/calendar-focused physical review workload. Individual
        // cases may explicitly choose another fixture; do not overwrite their flags.
        for (flag, value) in [("--stress-mail-days", "90"), ("--stress-event-days", "365"),
                              ("--stress-notes", "5000"), ("--stress-podcasts", "20"),
                              ("--stress-episodes-per-show", "1000")] where !app.launchArguments.contains(flag) {
            app.launchArguments += [flag, value]
        }
        #endif
        if route == "--plan" {
            if extra.contains("--calendar-prepared-artwork") {
                app.launchArguments += ["--calendar-artwork-test-probe"]
            }
            if ProcessInfo.processInfo.environment["CALENDAR_ARTWORK_ADMISSION"] == "immediate" {
                app.launchArguments += ["--calendar-immediate-artwork-admission"]
            }
            app.launchEnvironment["STRESS_INITIAL_PLAN_MODE"] = "week"
            if !app.launchArguments.contains("-mobileWeekLayout") {
                app.launchArguments += ["-mobileWeekLayout", "calendar"]
            }
            app.launchArguments += ["-mobileWeekHourHeight", "56", "--stress-actionable-calendar"]
        }
        app.launch()
        #if !PHYSICAL_STRESS_UI_TESTS
        if !waitUntil { app.windows.firstMatch.frame.height > app.windows.firstMatch.frame.width } {
            XCUIDevice.shared.orientation = .landscapeLeft
            XCTAssertTrue(waitUntil { app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height })
            XCUIDevice.shared.orientation = .portrait
            XCTAssertTrue(waitUntil { app.windows.firstMatch.frame.height > app.windows.firstMatch.frame.width })
        }
        #endif
        XCTAssertTrue(app.staticTexts["stress.ready"].waitForExistence(timeout: 120),
                      "All four stress datasets must finish loading; an empty screen is not a pass")
        return app
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "scale-stress-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    #if !PHYSICAL_STRESS_UI_TESTS
    func testMailRemovalReviewPagesKeepsAndPersists() {
        let app = launch("--mail", extra: ["--mail-removal-review", "--reset-mail-removal-review"])
        let notice = app.buttons["mail.removal.review"].firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 15))
        notice.tap()
        XCTAssertTrue(app.staticTexts["52 messages in this review"].waitForExistence(timeout: 10))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["Next"])], timeout: 5), .completed)
        app.buttons["Next"].tap()
        let reviewRows = app.descendants(matching: .any)["mail.removal.rows"].firstMatch
        let last = reviewRows.staticTexts["Removed fixture 052"].firstMatch
        XCTAssertTrue(last.waitForExistence(timeout: 5))
        last.tap()
        let body = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Saved fixture body 52")).firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        app.buttons["mail.removal.preview.close"].tap()
        app.buttons["mail.removal.keep"].tap()
        let kept = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "No longer in Gmail · Kept on this device")).firstMatch
        XCTAssertTrue(kept.waitForExistence(timeout: 10))
        XCTAssertFalse(notice.exists)
        capture("mail-removal-kept")
        app.terminate()
        app.launchArguments.removeAll { $0 == "--reset-mail-removal-review" }
        app.launch()
        XCTAssertTrue(kept.waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["mail.removal.review"].firstMatch.exists)
    }
    #endif

    func testMailSearchFindsRetainedConversationAndClears() {
        let app = launch("--mail")
        let field = app.textFields["mail.search.query"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap(); field.typeText("Stress email 59999\n")
        let target = app.descendants(matching: .any)[MailID.row("stress-59999")].firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 10), "Search must reach beyond the loaded page")
        app.buttons["Clear mail search"].tap()
        XCTAssertTrue(app.staticTexts["Inbox"].firstMatch.waitForExistence(timeout: 5))
        field.tap(); field.typeText("Stress email 59999\n")
        XCTAssertTrue(target.waitForExistence(timeout: 10))
        target.tap()
        if UIDevice.current.userInterfaceIdiom == .pad {
            let expand = app.descendants(matching: .any)[MailID.expand].firstMatch
            XCTAssertTrue(expand.waitForExistence(timeout: 5)); expand.tap()
        }
        XCTAssertTrue(app.descendants(matching: .any)[MailID.conversation].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Stress email 59999"].firstMatch.exists)
        capture("mail-search-retained")
    }

    func testCalendarSearchEntryAndDismissal() {
        let app = launch("--plan")
        app.buttons["calendar.search.open"].tap()
        let field = app.textFields["filters.plan.query"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText("meetings next week")
        XCTAssertTrue(app.buttons["Edit Date: Next week"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Edit Type: meeting"].exists)
        XCTAssertFalse(app.buttons["Interpret"].exists)
        XCTAssertFalse(app.buttons["Apply filters"].exists)
        app.buttons["Clear filters"].tap()
        XCTAssertTrue(app.staticTexts["Find events by title, location or description."].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["calendar.search.open"].waitForExistence(timeout: 5))
    }

    func testMailScrollAndOpen() {
        let app = launch("--mail")
        let rows = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "mail.list.row."))
        // Use the screen's shared identifier rather than relying on a fixture's incidental order.
        let list = app.descendants(matching: .any)[MailID.list].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric(application: app), XCTOSSignpostMetric.scrollingAndDecelerationMetric], options: options) {
            list.swipeUp()
            list.swipeDown()
        }
        XCTAssertGreaterThan(rows.count, 0)
        rows.firstMatch.tap()
        let expand = app.descendants(matching: .any)[MailID.expand].firstMatch
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCTAssertTrue(expand.waitForExistence(timeout: 5))
            expand.tap()
        }
        XCTAssertTrue(app.descendants(matching: .any)[MailID.conversation].firstMatch.waitForExistence(timeout: 5))
        capture("mail")
    }

    func testMailHistoryNavigationCrossesTwoThousandRowsAndOpens() {
        let app = launch("--mail")
        let older = app.buttons["mail.history.older"]
        XCTAssertTrue(older.waitForExistence(timeout: 10))
        let rows = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "mail.list.row.stress-"))
        var priorFirst = ""
        var currentFirst = ""
        for _ in 0..<21 {
            guard let first = rows.allElementsBoundByIndex.first(where: \.isHittable) else {
                return XCTFail("A history page must have a visible row")
            }
            priorFirst = first.identifier
            XCTAssertTrue(older.isEnabled)
            older.tap()
            let retired = app.descendants(matching: .any)[priorFirst].firstMatch
            XCTAssertTrue(retired.waitForNonExistence(timeout: 5), "Older must replace the previous bounded window")
        }
        guard let first = rows.allElementsBoundByIndex.first(where: \.isHittable) else {
            return XCTFail("No row after crossing the previous history cap")
        }
        currentFirst = first.identifier
        let prefix = "mail.list.row.stress-"
        guard let index = Int(currentFirst.dropFirst(prefix.count)) else { return XCTFail("Unexpected fixture row identity") }
        XCTAssertGreaterThanOrEqual(index, 2000, "Day-zero's 2,000 messages must all be behind this window")
        app.buttons["mail.history.newer"].tap()
        XCTAssertTrue(app.descendants(matching: .any)[priorFirst].firstMatch.waitForExistence(timeout: 5))
        older.tap()
        let target = app.descendants(matching: .any)[currentFirst].firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        XCTAssertTrue(target.isHittable)
        target.tap()
        if UIDevice.current.userInterfaceIdiom == .pad {
            let expand = app.descendants(matching: .any)[MailID.expand].firstMatch
            XCTAssertTrue(expand.waitForExistence(timeout: 5)); expand.tap()
        }
        XCTAssertTrue(app.descendants(matching: .any)[MailID.conversation].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Stress email \(index)"].firstMatch.exists)
        capture("mail-history-beyond-cap")
    }

    func testMailScrollLoadsOlderThanFirstPage() {
        let app = launch("--mail")
        let list = app.descendants(matching: .any)[MailID.list].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        // Day zero has 152 messages at hours 22/23. This message is at hour 21,
        // minute zero, so it cannot be one of the initial 100 newest rows.
        let target = app.descendants(matching: .any)[MailID.row("stress-1800")].firstMatch
        let rows = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "mail.list.row."))
        var previous: [String] = []
        var unchanged = 0
        for _ in 0..<45 {
            if target.exists && target.isHittable { break }
            let visible = rows.allElementsBoundByIndex.filter(\.isHittable).map(\.identifier).sorted()
            unchanged = visible == previous ? unchanged + 1 : 0
            if unchanged >= 3 { break }
            previous = visible
            list.swipeUp(velocity: .slow)
        }
        capture("mail-older-page")
        XCTAssertTrue(target.exists && target.isHittable,
                      "Scrolling must load mail older than the initial 100 rows")
        target.tap()
        if UIDevice.current.userInterfaceIdiom == .pad {
            let expand = app.descendants(matching: .any)[MailID.expand].firstMatch
            XCTAssertTrue(expand.waitForExistence(timeout: 5))
            expand.tap()
        }
        XCTAssertTrue(app.descendants(matching: .any)[MailID.conversation].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Stress email 1800"].firstMatch.exists)
    }

    func testNotesOpen() {
        let app = launch("--notes")
        let row = app.descendants(matching: .any)["notes.row.51515151-0000-0000-0000-000000000001"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["notes.detail.51515151-0000-0000-0000-000000000001"].firstMatch.waitForExistence(timeout: 5))
        capture("notes")
    }

    func testPodcastOpenAndScroll() {
        let app = launch("--library")
        let row = app.descendants(matching: .any)["library.podcast.51515151-0000-0000-0000-000000000000"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let episodes = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Episodes (")).firstMatch
        XCTAssertTrue(episodes.waitForExistence(timeout: 5))
        XCTAssertTrue(episodes.label.contains("1,000") || episodes.label.contains("1000"))
        app.swipeUp()
        capture("podcasts")
    }

    func testNotesPagesAndReturnsToFirstPage() {
        let app = launch("--notes")
        let first = app.descendants(matching: .any)["notes.row.51515151-0000-0000-0000-000000000001"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        app.buttons["notes.page.next"].tap()
        let secondPage = app.descendants(matching: .any)["notes.row.51515151-0000-0000-0000-000000000126"].firstMatch
        XCTAssertTrue(secondPage.waitForExistence(timeout: 10))
        app.buttons["notes.page.previous"].tap()
        XCTAssertTrue(first.waitForExistence(timeout: 10))
    }

    func testPodcastScrollsAcrossPagesWithoutNextButtons() {
        let app = launch("--library-detail")
        let heading = app.staticTexts["library.episodes.heading"]
        XCTAssertTrue(heading.waitForExistence(timeout: 10))
        let first = app.descendants(matching: .any)["podcast.episode.stress-0-0"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["library.episodes.next"].exists)
        XCTAssertFalse(app.buttons["library.episodes.previous"].exists)
        let ordered = (0..<1000).sorted { ($0 * 7919) % 1000 < ($1 * 7919) % 1000 }
        let laterIDs = ordered.dropFirst(100).prefix(100).map { "podcast.episode.stress-0-\($0)" }
        let later = app.descendants(matching: .any).matching(NSPredicate(format: "identifier IN %@", laterIDs as NSArray)).firstMatch
        for _ in 0..<30 where !later.exists { app.swipeUp(velocity: .fast) }
        XCTAssertTrue(later.waitForExistence(timeout: 10), "scrolling reaches episodes after the first hundred without a page action")
        capture("podcasts-continuous-scroll")
    }

    func testDenseCalendarScroll() {
        checkDenseCalendarScroll(extra: ["--calendar-reference-week"])
    }

    func testNativeWeekCalendarScroll() {
        checkDenseCalendarScroll(extra: [])
    }

    #if PHYSICAL_STRESS_UI_TESTS
    func testDefaultVariedWeekArtwork() { checkDefaultVariedArtwork(mode: "Week") }
    func testDefaultVariedDayArtwork() { checkDefaultVariedArtwork(mode: "Day") }

    private func checkDefaultVariedArtwork(mode: String) {
        XCUIDevice.shared.orientation = .portrait
        let app = launch("--plan", extra: ["--stress-calendar-fixture", "varied-v1",
                                          "-mobileDayScrollOffset", "560"])
        let metadata = app.staticTexts["stress.ready"].value as? String ?? ""
        guard let data = metadata.data(using: .utf8),
              let fixture = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Installed fixture metadata is required"); return
        }
        XCTAssertEqual(fixture["profile"] as? String, "varied-v1")
        XCTAssertEqual(fixture["retainedEvents"] as? Int, variedCalendarDays * 100)
        XCTAssertEqual((fixture["installedCalendarCounts"] as? [String: Int])?.count, 12)
        XCTAssertEqual(fixture["distinctDailyPatterns"] as? Int, variedCalendarDays)
        XCTAssertEqual(fixture["distinctWeeklyPatterns"] as? Int, variedCalendarDays / 7)
        let evidence = XCTAttachment(string: metadata)
        evidence.name = "default-\(mode)-installed-workload"
        evidence.lifetime = .keepAlways; add(evidence)
        app.segmentedControls.buttons[mode].tap()
        let viewport = app.collectionViews.firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 10))
        let artwork = app.descendants(matching: .any).matching(NSPredicate(format: "identifier IN %@", ["calendar.preparedArtwork", "calendar.nativeArtwork.direct"]))
        func visibleArtwork() -> XCUIElement? {
            let bounds = viewport.frame
            // Stop at the first visible event. Enumerating every remote AX frame
            // inside a readiness predicate can consume the entire XCTest timeout
            // on a large iPad viewport even when the first event is already ready.
            return artwork.allElementsBoundByIndex.first {
                $0.isHittable && !$0.frame.intersection(bounds).isEmpty
            }
        }
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            visibleArtwork() != nil
        }, object: app)
        let readiness = XCTWaiter.wait(for: [ready], timeout: 15)
        if readiness != .completed {
            capture("default-varied-\(mode)-readiness-failure")
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "default-\(mode)-readiness-failure-hierarchy"
            hierarchy.lifetime = .keepAlways; add(hierarchy)
        }
        XCTAssertEqual(readiness, .completed,
                       "Default Beta must render populated events without renderer flags")
        viewport.swipeUp(); viewport.swipeDown()
        XCTAssertEqual(app.descendants(matching: .any)
            .matching(identifier: "calendar.preparedArtwork.failed").count, 0)
        guard let event = visibleArtwork(),
              let suffix = event.label.range(of: #" · [0-9]+-[0-9]+"#, options: .regularExpression) else {
            XCTFail("Replacement artwork must remain visible after scrolling"); return
        }
        let title = String(event.label[..<suffix.upperBound])
        capture("default-varied-\(mode)-artwork")
        let visible = event.frame.intersection(viewport.frame)
        event.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: visible.midX - event.frame.minX,
                                 dy: visible.midY - event.frame.minY)).tap()
        XCTAssertTrue(app.buttons["eventDetail.edit"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[title].exists, "The exact rendered event must open")
        capture("default-varied-\(mode)-detail")
        app.buttons["Done"].tap()
    }

    func testPreservedHostNativeWeekCalendarScroll() {
        checkDenseCalendarScroll(extra: ["--calendar-preserve-cell-host"])
    }
    func testPreservedHostNativeDayCalendarScroll() {
        checkDenseCalendarScroll(extra: ["--calendar-preserve-cell-host"], mode: "Day")
    }
    #endif

    #if PHYSICAL_STRESS_UI_TESTS
    // A sustained interaction window for an external Instruments capture of the
    // integrated app. XCTest gesture durations are not frame/input measurements.
    func testPhysicalWeekScrollTrace() { checkPhysicalScrollTrace(mode: "Week") }
    func testPhysicalDayScrollTrace() { checkPhysicalScrollTrace(mode: "Day") }
    // The matched comparison for the renderer article: the pre-virtualization Day/Week host,
    // same fixture, same device, same interaction window, chosen by the DEBUG reference flags.
    func testPhysicalWeekReferenceScrollTrace() {
        checkPhysicalScrollTrace(mode: "Week", extra: ["--calendar-reference-week"], reference: true)
    }
    func testPhysicalDayReferenceScrollTrace() {
        checkPhysicalScrollTrace(mode: "Day", extra: ["--calendar-reference-day"], reference: true)
    }
    func testPhysicalWeekPreservedHostScrollTrace() {
        checkPhysicalScrollTrace(mode: "Week", extra: ["--calendar-preserve-cell-host"])
    }
    func testPhysicalDayPreservedHostScrollTrace() {
        checkPhysicalScrollTrace(mode: "Day", extra: ["--calendar-preserve-cell-host"])
    }
    // UIKit cell prefetching experiment (off in production): cells prepared ahead of display.
    func testPhysicalWeekPrefetchScrollTrace() {
        checkPhysicalScrollTrace(mode: "Week", extra: ["--calendar-prefetch-cells"])
    }
    func testPhysicalDayPrefetchScrollTrace() {
        checkPhysicalScrollTrace(mode: "Day", extra: ["--calendar-prefetch-cells"])
    }

    // Supplementary capacity probes leave the default 100/day acceptance case intact.
    func testPhysicalWeekDensity1ScrollTrace() { checkPhysicalScrollTrace(mode: "Week", density: 1) }
    func testPhysicalWeekDensity10ScrollTrace() { checkPhysicalScrollTrace(mode: "Week", density: 10) }
    func testPhysicalWeekDensity30ScrollTrace() { checkPhysicalScrollTrace(mode: "Week", density: 30) }
    func testPhysicalDayDensity1ScrollTrace() { checkPhysicalScrollTrace(mode: "Day", density: 1) }
    func testPhysicalDayDensity10ScrollTrace() { checkPhysicalScrollTrace(mode: "Day", density: 10) }
    func testPhysicalDayDensity30ScrollTrace() { checkPhysicalScrollTrace(mode: "Day", density: 30) }

    private func checkPhysicalScrollTrace(mode: String, density: Int = 100, extra: [String] = [], reference: Bool = false) {
        // The orientation is an input of the trace (STRESS_ORIENTATION=portrait|landscape, from the
        // xctestrun the profiler writes), never an accident of how the device was lying. The device
        // must comply before any scrolling is measured, so a trace cannot be mislabelled.
        let requested = ProcessInfo.processInfo.environment["STRESS_ORIENTATION"] ?? "portrait"
        XCTAssertTrue(["portrait", "landscape"].contains(requested), "Unknown STRESS_ORIENTATION \(requested)")
        let wantsPortrait = requested == "portrait"
        XCUIDevice.shared.orientation = wantsPortrait ? .portrait : .landscapeLeft
        let densityArguments = density == 100 ? [] : ["--stress-events-per-day", String(density)]
        let app = launch("--plan", extra: ["--stress-calendar-fixture", "varied-v1"] + densityArguments + extra)
        let oriented = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            wantsPortrait ? app.frame.height > app.frame.width : app.frame.width > app.frame.height
        }, object: app)
        if XCTWaiter.wait(for: [oriented], timeout: 10) != .completed {
            // One more request (the other landscape side for landscape) before giving up.
            XCUIDevice.shared.orientation = wantsPortrait ? .portrait : .landscapeRight
            if XCTWaiter.wait(for: [oriented], timeout: 10) != .completed {
                let state = XCTAttachment(string: "requested=\(requested) device=\(XCUIDevice.shared.orientation.rawValue) app=\(app.frame)")
                state.name = "physical-scroll-trace-orientation-refused"; state.lifetime = .keepAlways; add(state)
                XCTFail("Device did not rotate to \(requested); frame \(app.frame). Check rotation lock.")
                return
            }
        }
        let orientation = requested
        if mode == "Day" { app.segmentedControls.buttons["Day"].tap() }
        // The reference host is a SwiftUI ScrollView; the native viewport is a collection view.
        let viewport = reference ? app.scrollViews.firstMatch : app.collectionViews.firstMatch
        if !viewport.waitForExistence(timeout: 10) {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "physical-scroll-trace-missing-viewport-hierarchy"
            hierarchy.lifetime = .keepAlways; add(hierarchy)
            XCTFail("\(reference ? "Reference scroll view" : "Native collection viewport") did not appear")
            return
        }
        let metadata = app.staticTexts["stress.ready"].value as? String ?? ""
        let fixture = metadata.data(using: .utf8).flatMap {
            (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
        }
        XCTAssertEqual(fixture?["retainedEvents"] as? Int, 365 * density)
        XCTAssertEqual(fixture?["meanDailyEvents"] as? Int, density)
        XCTAssertEqual(fixture?["sevenDayBlockEvents"] as? Int, 7 * density)
        XCTAssertEqual((fixture?["installedCalendarCounts"] as? [String: Int])?.count, 12)
        if density == 100 {
            XCTAssertEqual(fixture?["distinctDailyPatterns"] as? Int, 365)
        } else {
            // At sparse densities some empty/single-event days can share a shape.
            XCTAssertGreaterThan(fixture?["distinctDailyPatterns"] as? Int ?? 0, 1)
        }
        let workload = XCTAttachment(string: metadata)
        workload.name = "physical-scroll-trace-workload"; workload.lifetime = .keepAlways; add(workload)
        // The reference host does not expose hour labels as elements; record absence instead of failing.
        let tenAM = app.staticTexts["10 AM"].firstMatch
        let tenAMFrame = tenAM.exists ? "\(tenAM.frame)" : "absent"
        let geometry = XCTAttachment(string: "mode=\(mode) flags=\(extra) viewport=\(reference ? "reference" : "native") orientation=\(orientation) app=\(app.frame) frame=\(viewport.frame) tenAM=\(tenAMFrame) cells=\(reference ? -1 : viewport.cells.count)")
        geometry.name = "physical-scroll-trace-initial-geometry"
        geometry.lifetime = .keepAlways; add(geometry)
        for _ in 0..<16 { viewport.swipeUp(); viewport.swipeDown() }
        capture("physical-\(mode.lowercased())-scroll-trace")
    }
    #endif

    func testNativeWeekInitialSelectedDayVisible() {
        let app = launch("--plan", extra: ["--calendar-viewport-audit"])
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let today = app.buttons["calendar.day.items." + formatter.string(from: Date())]
        XCTAssertTrue(today.waitForExistence(timeout: 3))
        let viewport = app.collectionViews.firstMatch
        let snapshot = XCTAttachment(string: "viewport=\(viewport.value ?? "missing")\n\(app.debugDescription)")
        snapshot.name = "initial-week-selected-day"
        snapshot.lifetime = .keepAlways
        add(snapshot)
        capture("initial-week-selected-day")
        let frame = today.frame
        XCTAssertTrue(viewport.frame.minX <= frame.midX && frame.midX <= viewport.frame.maxX,
                      "The initially selected day must be visible, not offscreen at \(frame)")
        XCTAssertTrue(today.isHittable)
    }

    func testNativeWeekNavigation() {
        let app = launch("--plan", extra: ["--calendar-viewport-audit",
                                           "--stress-calendar-fixture", "varied-v1"])
        let metadata = app.staticTexts["stress.ready"].value as? String ?? ""
        let fixture = metadata.data(using: .utf8).flatMap {
            (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
        }
        XCTAssertEqual(fixture?["retainedEvents"] as? Int, variedCalendarDays * 100)
        XCTAssertEqual((fixture?["installedCalendarCounts"] as? [String: Int])?.count, 12)
        XCTAssertEqual(fixture?["distinctDailyPatterns"] as? Int, variedCalendarDays)
        let workload = XCTAttachment(string: metadata)
        workload.name = "native-week-varied-workload"; workload.lifetime = .keepAlways; add(workload)
        let viewport = app.collectionViews.firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 10))
        func snapshot() -> [String: Any] {
            guard let value = viewport.value as? String, let data = value.data(using: .utf8),
                  let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                XCTFail("Native viewport audit must be available"); return [:]
            }
            return result
        }
        func number(_ key: String) -> Double { (snapshot()[key] as? NSNumber)?.doubleValue ?? -1 }
        let initial = snapshot()
        let attachment = XCTAttachment(string: String(describing: initial))
        attachment.name = "native-week-initial-viewport"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertGreaterThan(number("visibleCells"), 0)
        XCTAssertLessThanOrEqual(number("visibleCells"), number("descriptors"))
        let ids = initial["visibleIDs"] as? [String] ?? []
        XCTAssertEqual(ids.count, Set(ids).count, "Overnight continuations need per-day identities")
        XCTAssertEqual(number("x"), number("gutterX"), accuracy: 1)
        if number("contentWidth") > number("width") + 1 {
            let x = number("x"), y = number("y")
            if x > 1 { viewport.swipeRight() } else { viewport.swipeLeft() }
            let moved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in abs(number("x") - x) > 10 }, object: viewport)
            XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 5), .completed)
            XCTAssertEqual(number("y"), y, accuracy: 5, "Column paging must retain the time position")
            XCTAssertEqual(number("x"), number("gutterX"), accuracy: 1)
        }
        let height = number("contentHeight")
        // A 13-inch iPad can initially show almost all 24 hours. Create a genuinely
        // smaller viewport into the day before asserting offscreen cell recycling.
        viewport.pinch(withScale: 2.5, velocity: 1)
        XCTAssertGreaterThan(number("contentHeight"), height * 1.1, "Pinch must resize the real native content")
        XCTAssertLessThan(number("visibleCells"), number("descriptors"), "Zoomed offscreen cells must be recycled")
        func daySnapshot() -> String? { app.calendarDaySnapshot(referenceID: "mobile.day.surface.0") }
        let original = daySnapshot()
        XCTAssertNotNil(original)
        app.buttons["Next week"].tap()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in daySnapshot() != original }, object: viewport)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
        XCTAssertGreaterThan(number("visibleCells"), 0)
        app.buttons["Previous week"].tap()
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in daySnapshot() == original }, object: viewport)
        let restoreResult = XCTWaiter.wait(for: [restored], timeout: 5)
        if restoreResult != .completed {
            let detail = XCTAttachment(string: "original=\(original ?? "nil")\nrestored=\(daySnapshot() ?? "nil")\nviewport=\(viewport.value ?? "nil")")
            detail.name = "native-week-restoration-state"; detail.lifetime = .keepAlways; add(detail)
        }
        XCTAssertEqual(restoreResult, .completed)
        XCTAssertEqual(number("x"), number("gutterX"), accuracy: 1)
        capture("native-week-navigation")
    }

    func testNativeWeekRotation() { checkNativeWeekRotation(extra: []) }

    func testReferenceWeekHeaderPublication() {
        checkNativeWeekRotation(extra: ["--calendar-reference-header-publication"])
    }

    private func checkNativeWeekRotation(extra: [String]) {
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launch("--plan", extra: ["--calendar-viewport-audit",
                                           "--stress-calendar-fixture", "varied-v1"] + extra)
        let viewport = app.collectionViews.firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 10))
        func number(_ key: String) -> Double {
            guard let value = viewport.value as? String, let data = value.data(using: .utf8),
                  let snapshot = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                XCTFail("Missing native viewport audit"); return -1
            }
            return (snapshot[key] as? NSNumber)?.doubleValue ?? -1
        }
        // Establish a user-selected column instead of relying on today's weekday.
        if number("contentWidth") > number("width") + 1 {
            if number("x") > 1 { viewport.swipeRight() } else { viewport.swipeLeft() }
        }
        let column = (number("x") / ((number("contentWidth") - 36) / 7)).rounded()
        let portraitWidth = number("width")
        func retainRotationState(_ label: String) {
            let state = XCTAttachment(string: "orientation=\(XCUIDevice.shared.orientation.rawValue) appFrame=\(app.frame) viewport=\(viewport.value ?? "missing")")
            state.name = label; state.lifetime = .keepAlways; add(state)
        }
        retainRotationState("week-before-rotation")
        for orientation: UIDeviceOrientation in [.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            let expectedPortrait = orientation == .portrait
            let resized = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                expectedPortrait ? abs(number("width") - portraitWidth) < 2
                                 : abs(number("width") - portraitWidth) > 20
            }, object: viewport)
            let resizeResult = XCTWaiter.wait(for: [resized], timeout: 10)
            retainRotationState("week-after-rotation-\(orientation.rawValue)")
            XCTAssertEqual(resizeResult, .completed)
            let aligned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let expectedX = min(column * ((number("contentWidth") - 36) / 7),
                                    max(0, number("contentWidth") - number("width")))
                return abs(number("x") - expectedX) < 2
            }, object: viewport)
            XCTAssertEqual(XCTWaiter.wait(for: [aligned], timeout: 5), .completed,
                           "Resize must preserve the selected column using its new width")
            XCTAssertEqual(number("gutterX"), number("x"), accuracy: 1)
            XCTAssertGreaterThan(number("visibleCells"), 0)
        }
        capture("native-week-rotation")
    }

    func testPreparedDenseCalendarScroll() {
        checkDenseCalendarScroll(extra: ["--calendar-reference-week", "--calendar-cache-layout"])
    }

    func testPreparedArtworkDenseCalendarScroll() {
        checkDenseCalendarScroll(extra: ["--calendar-reference-week", "--calendar-prepared-artwork"])
    }

    func testPreparedArtworkDayScroll() {
        checkDenseCalendarScroll(extra: ["--calendar-reference-day", "--calendar-prepared-artwork", "-mobileDayScrollOffset", "560"], mode: "Day")
    }

    func testDenseDayCalendarScroll() {
        checkDenseCalendarScroll(extra: ["--calendar-reference-day", "-mobileDayScrollOffset", "560"], mode: "Day")
    }

    func testDayMidnightExtent() {
        let app = launch("--plan", extra: ["-mobileDayScrollOffset", "560"])
        app.segmentedControls.buttons["Day"].tap()
        let viewport = app.collectionViews.firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 10))
        for number in [0, 10] {
            let event = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Stress event \(number),")).firstMatch
            XCTAssertTrue(event.waitForExistence(timeout: 5), "Overnight timed events must intersect the midday viewport")
            XCTAssertTrue(event.isHittable)
            XCTAssertGreaterThan(event.frame.height, min(300, viewport.frame.height / 2),
                                 "Clipping at next midnight must retain the visible duration")
        }
        capture("day-midnight-extent")
    }

    func testNativeDayCalendarScroll() {
        checkDenseCalendarScroll(extra: ["-mobileDayScrollOffset", "560"], mode: "Day")
    }

    func testNativePreparedDayCalendarScroll() {
        checkDenseCalendarScroll(extra: ["--calendar-prepared-artwork",
                                        "-mobileDayScrollOffset", "560"], mode: "Day")
    }

    func testNativeDayPagingAndZoom() {
        let app = launch("--plan", extra: ["-mobileDayScrollOffset", "560", "--calendar-viewport-audit"])
        app.segmentedControls.buttons["Day"].tap()
        let viewport = app.collectionViews.firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 10))
        func snapshot() -> String? { app.calendarDaySnapshot(referenceID: "mobile.day.surface.1") }
        let originalDay = snapshot()
        XCTAssertNotNil(originalDay)
        let hour = app.staticTexts["11 AM"].firstMatch
        let nextHour = app.staticTexts["12 PM"].firstMatch
        XCTAssertTrue(hour.isHittable)
        let originalY = hour.frame.minY
        for forward in [true, true, false, false] {
            let previous = snapshot()
            viewport.coordinate(withNormalizedOffset: CGVector(dx: forward ? 0.8 : 0.2, dy: 0.7))
                .press(forDuration: 0, thenDragTo: viewport.coordinate(
                    withNormalizedOffset: CGVector(dx: forward ? 0.2 : 0.8, dy: 0.7)))
            let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                snapshot() != previous
            }, object: viewport)
            let result = XCTWaiter.wait(for: [changed], timeout: 3)
            if result != .completed {
                capture("native-day-paging-failure")
                let detail = XCTAttachment(string: "before=\(previous ?? "nil")\nafter=\(snapshot() ?? "nil")\n\(app.debugDescription)")
                detail.name = "native-day-paging-failure-state"; detail.lifetime = .keepAlways; add(detail)
            }
            XCTAssertEqual(result, .completed)
            XCTAssertEqual(hour.frame.minY, originalY, accuracy: 2, "Paging must preserve the live time offset")
        }
        XCTAssertEqual(snapshot(), originalDay, "Returning must restore the same date and event IDs")
        let spacing = nextHour.frame.minY - hour.frame.minY
        XCTAssertGreaterThan(spacing, 0)
        func contentHeight() -> Double {
            guard let raw = viewport.value as? String, let data = raw.data(using: .utf8),
                  let audit = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return 0 }
            return (audit["contentHeight"] as? NSNumber)?.doubleValue ?? 0
        }
        let heightBeforeZoom = contentHeight()
        XCTAssertGreaterThan(heightBeforeZoom, 0)
        viewport.pinch(withScale: 1.5, velocity: 1)
        // Zoom can recycle the 11 AM ruler. Require the real content geometry to grow,
        // rather than querying an hour that is no longer in the visible native viewport.
        let zoomed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            contentHeight() > heightBeforeZoom * 1.25
        }, object: viewport)
        XCTAssertEqual(XCTWaiter.wait(for: [zoomed], timeout: 3), .completed)
        capture("native-day-paging-zoom")
    }

    func testNativeDayCreateGesture() {
        // The dense fixture contains 24-hour timed events, so use the existing empty audit
        // route to exercise the blank-slot gesture without changing the stress workload.
        continueAfterFailure = false
        #if PHYSICAL_STRESS_UI_TESTS
        let app = launch("--plan", extra: ["--calendar-viewport-audit"])
        app.segmentedControls.buttons["Day"].tap()
        app.buttons["Previous day"].tap()
        #else
        let app = XCUIApplication()
        app.launchArguments = ["--day", "--ui-audit", "--empty-create-grid-preview", "--calendar-viewport-audit",
                               "-planMode", "day", "--reset-day-scroll-offset", "--disable-icloud", "-onboardingCompleted", "YES"]
        app.launch()
        app.buttons["Previous day"].tap()
        #endif
        let viewport = app.collectionViews.firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 10))
        verifyEmptyCreationViewport(viewport)
        viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.78, dy: 0.18))
            .press(forDuration: 0.55, thenDragTo: viewport.coordinate(
                withNormalizedOffset: CGVector(dx: 0.78, dy: 0.38)))
        XCTAssertTrue(app.navigationBars["New event"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["event.title"].exists)
        capture("native-day-create")
    }

    func testNativeWeekCreateGesture() {
        // Exercise the production Week gesture/editor bridge on the isolated empty audit
        // route. This supplements the unchanged dense scroll workload; it does not save.
        continueAfterFailure = false
        #if PHYSICAL_STRESS_UI_TESTS
        let app = launch("--plan", extra: ["--calendar-viewport-audit"])
        app.buttons["Previous week"].tap()
        #else
        let app = XCUIApplication()
        app.launchArguments = ["--week", "--ui-audit", "--empty-create-grid-preview", "--calendar-viewport-audit",
                               "-planMode", "week", "-mobileWeekLayout", "calendar", "--disable-icloud",
                               "-onboardingCompleted", "YES"]
        app.launch()
        app.buttons["Previous week"].tap()
        #endif
        let viewport = app.collectionViews.firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 10))
        verifyEmptyCreationViewport(viewport)
        viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.78, dy: 0.18))
            .press(forDuration: 0.55, thenDragTo: viewport.coordinate(
                withNormalizedOffset: CGVector(dx: 0.78, dy: 0.38)))
        XCTAssertTrue(app.navigationBars["New event"].waitForExistence(timeout: 5))
        let title = app.textFields["event.title"]
        XCTAssertTrue(title.exists)
        title.tap()
        title.typeText("Native Week creation review")
        XCTAssertEqual(title.value as? String, "Native Week creation review")
        capture("native-week-create")
    }

    private func verifyEmptyCreationViewport(_ viewport: XCUIElement) {
        // The full fixture history remains loaded. Navigate before its first day
        // to find blank slots; never remove events to make a gesture test pass.
        let empty = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let value = viewport.value as? String, let data = value.data(using: .utf8),
                  let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return (state["descriptors"] as? Int) == 0
        }, object: viewport)
        XCTAssertEqual(XCTWaiter.wait(for: [empty], timeout: 5), .completed)
    }

    func testNativeDayEventAccessibility() { checkDayEventAccessibility(extra: []) }
    func testReferenceDayEventAccessibility() { checkDayEventAccessibility(extra: ["--calendar-reference-day"]) }
    func testPreparedDayEventAccessibility() { checkDayEventAccessibility(extra: ["--calendar-prepared-artwork"]) }

    func testLegacyEventAccessibilityFlagKeepsSingleAnnouncement() {
        checkDayEventAccessibility(extra: ["--calendar-reference-day", "--calendar-reference-event-accessibility"])
    }

    private func checkDayEventAccessibility(extra: [String]) {
        let app = launch("--plan", extra: ["-mobileDayScrollOffset", "560"] + extra)
        app.segmentedControls.buttons["Day"].tap()
        for title in ["Stress event 61", "Stress event 60"] {
            // A short block has one text child; the tall block has title, time and location.
            // The original bug is exposed only by the latter, so cover both.
            let event = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title + ",")).firstMatch
            XCTAssertTrue(event.waitForExistence(timeout: 10))
            XCTAssertTrue(event.isHittable)
            if extra.contains("--calendar-prepared-artwork") {
                requireMountedArtwork(in: app, title: title)
            }
            let label = event.label
            let repetitions = label.components(separatedBy: title + ",").count - 1
            print("DAY_EVENT_ACCESSIBILITY=\(label)")
            // The outer cell has ignored child accessibility since 7d3733519. Even
            // the inner-artwork legacy flag must not reintroduce repeated announcements.
            XCTAssertEqual(repetitions, 1, "One event must announce its title/time once")
            event.tap()
            XCTAssertTrue(app.buttons["eventDetail.edit"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts[title].exists)
            app.buttons["Done"].tap()
        }
    }

    func testLegacyNativeDayAccessibilityScroll() {
        checkDenseCalendarScroll(extra: ["-mobileDayScrollOffset", "560", "--calendar-reference-event-accessibility"], mode: "Day")
    }

    func testVariedNativeDayScroll() { checkVariedDay(reference: false) }
    func testCachedVariedNativeDayScroll() {
        checkVariedDay(reference: false, extra: ["--calendar-cache-layout"])
    }
    func testVariedReferenceDayScroll() { checkVariedDay(reference: true) }

    func testReferenceNeighborsVariedNativeDayScroll() {
        checkVariedDay(reference: false, extra: ["--calendar-reference-neighbors"])
    }
    func testReferenceNeighborsWeekScroll() {
        checkDenseCalendarScroll(extra: ["--calendar-reference-week", "--calendar-reference-neighbors"])
    }

    private func checkVariedDay(reference: Bool, extra: [String] = []) {
        let app = launch("--plan", extra: ["--stress-calendar-fixture", "varied-v1", "-mobileDayScrollOffset", "560"]
                         + (reference ? ["--calendar-reference-day"] : []) + extra)
        let metadata = app.staticTexts["stress.ready"].value as? String ?? ""
        guard let data = metadata.data(using: .utf8),
              let fixture = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Varied fixture metadata must come from the app"); return
        }
        XCTAssertEqual(fixture["profile"] as? String, "varied-v1")
        XCTAssertEqual(fixture["retainedEvents"] as? Int, variedCalendarDays * 100)
        XCTAssertEqual((fixture["installedCalendarCounts"] as? [String: Int])?.count, 12)
        XCTAssertEqual(fixture["distinctDailyPatterns"] as? Int, variedCalendarDays)
        XCTAssertEqual(fixture["distinctWeeklyPatterns"] as? Int, variedCalendarDays / 7)
        let attachment = XCTAttachment(string: metadata)
        attachment.name = "varied-calendar-fixture"; attachment.lifetime = .keepAlways; add(attachment)
        app.segmentedControls.buttons["Day"].tap()
        let viewport = reference ? app.scrollViews.firstMatch : app.collectionViews.firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 10))
        let events = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", " · "))
        XCTAssertTrue(events.allElementsBoundByIndex.contains(where: { $0.isHittable }), "Initial viewport must contain actual varied events")
        let options = XCTMeasureOptions(); options.iterationCount = 3
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric(application: app), XCTOSSignpostMetric.scrollingAndDecelerationMetric], options: options) {
            viewport.swipeUp(); viewport.swipeDown()
        }
        guard let event = events.allElementsBoundByIndex.first(where: { $0.isHittable }),
              let suffix = event.label.range(of: #" · [0-9]+-[0-9]+"#, options: .regularExpression) else {
            XCTFail("A varied event must remain available after scrolling"); return
        }
        // The fixture suffix identifies the complete title even when it contains commas
        // or SwiftUI duplicates a descendant accessibility label. Do not weaken identity
        // checking to merely finding an open detail sheet.
        let title = String(event.label[..<suffix.upperBound])
        capture(reference ? "varied-reference-day" : "varied-native-day")
        event.tap()
        XCTAssertTrue(app.buttons["eventDetail.edit"].waitForExistence(timeout: 5))
        capture("varied-selected-detail")
        XCTAssertTrue(app.staticTexts[title].exists, "The selected varied event must open")
        app.buttons["Done"].tap()
        let day = app.staticTexts["mobile.day.title"].firstMatch
        let first = day.label
        app.buttons["Next day"].tap()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in day.label != first }, object: day)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 3), .completed)
        XCTAssertTrue(events.allElementsBoundByIndex.contains(where: { $0.isHittable }))
        capture(reference ? "varied-reference-next-day" : "varied-native-next-day")
    }

    func testNativeDayContinuationMove() {
        let app = launch("--plan", extra: ["-mobileDayScrollOffset", "0"])
        app.segmentedControls.buttons["Day"].tap()
        let viewport = app.collectionViews.firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 10))
        app.buttons["Next day"].tap()
        // Event 10 started yesterday at 01:40 and ends today at 01:40. Moving its
        // continuation one hour must retain yesterday as the original start date.
        let event = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Stress event 10,")).firstMatch
        XCTAssertTrue(event.waitForExistence(timeout: 10))
        XCTAssertTrue(event.isHittable)
        let start = event.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.55, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 56)),
                    withVelocity: .slow, thenHoldForDuration: 0.3)
        let failure = app.alerts["Couldn’t move that event"]
        XCTAssertTrue(failure.waitForExistence(timeout: 5))
        failure.buttons["OK"].tap()
        app.buttons["calendar.moveRecovery"].tap()
        let expected = Calendar.current.date(bySettingHour: 2, minute: 40, second: 0, of: Date())!
        XCTAssertTrue(app.staticTexts["Move to \(expected.formatted(date: .abbreviated, time: .shortened))"].exists,
                      "Continuation drag must move the original event by one hour, not one day plus one hour")
        capture("native-day-continuation-move")
    }

    func testNativeWeekMoveRecovery() {
        let app = launch("--plan", extra: ["--calendar-native-move-audit",
            "--calendar-recovery-fixture", UUID().uuidString])
        let week = app.segmentedControls.buttons["Week"]
        XCTAssertTrue(week.waitForExistence(timeout: 10))
        if !week.isSelected { week.tap() }
        XCTAssertTrue(waitUntil { week.isSelected })
        let viewport = app.collectionViews.firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 10), "Week must use the native default")
        let clock = app.staticTexts["10 AM"].firstMatch
        XCTAssertTrue(clock.waitForExistence(timeout: 10))
        func clockVisible() -> Bool {
            clock.frame.height > 0 && clock.frame.midY > viewport.frame.minY + 16
                && clock.frame.midY < viewport.frame.maxY - 30
        }
        for _ in 0..<12 where !clockVisible() {
            let bounds = app.calendarGridViewport() ?? viewport.frame
            // Move toward the viewport's centre by a bounded distance. Full flings can
            // overshoot the clock and oscillate when toolbars leave a short viewport.
            let shift = min(bounds.height * 0.4, max(-bounds.height * 0.4,
                                                    bounds.midY - clock.frame.midY))
            let origin = app.calendarPoint(in: bounds, y: 0.5)
            origin.press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: 0, dy: shift)),
                         withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        XCTAssertTrue(clockVisible())
        let events = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Stress event"))
        guard let event = events.allElementsBoundByIndex.first(where: {
            $0.isHittable && $0.frame.midY > viewport.frame.minY + 30
                && $0.frame.midY < viewport.frame.maxY - 90
        }) else { XCTFail("The default Week must expose a movable event"); return }
        let original = event.frame
        let title = String(event.label.split(separator: ",")[0])
        let start = event.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.55, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 56)),
                    withVelocity: .slow, thenHoldForDuration: 0.3)
        let failure = app.alerts["Couldn’t move that event"]
        XCTAssertTrue(failure.waitForExistence(timeout: 5), "Week drag must commit through the provider boundary")
        failure.buttons["OK"].tap()
        XCTAssertEqual(event.frame.minY, original.minY, accuracy: 2)
        XCTAssertFalse(app.buttons["eventDetail.edit"].exists, "Moving must not also open detail")
        let recovery = app.buttons["calendar.moveRecovery"]
        XCTAssertTrue(recovery.waitForExistence(timeout: 5))
        recovery.tap()
        XCTAssertTrue(app.staticTexts[title].exists, "Recovery must identify the event actually moved")
        let retry = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "calendar.moveRetry.")).firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        let operationID = retry.identifier
        app.buttons["Done"].tap()
        app.terminate(); app.launch()
        XCTAssertTrue(app.staticTexts["stress.ready"].waitForExistence(timeout: 120))
        XCTAssertTrue(app.collectionViews.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(recovery.waitForExistence(timeout: 5))
        recovery.tap()
        XCTAssertTrue(app.buttons[operationID].waitForExistence(timeout: 5), "Week failure must survive relaunch")
        app.buttons[operationID].tap()
        let error = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "This move is kept for retry.")).firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons[operationID].exists, "Rejected retry must remain durable")
        capture("native-week-move-recovery")
    }

    func testReferenceDayMoveFailure() { checkDayMoveFailure(native: false) }
    func testNativeDayParentMoveControl() { checkDayMoveFailure(native: true, parentFeedback: true) }
    func testNativeDayParentLongMoveControl() { checkDayMoveFailure(native: true, beyondViewport: true, parentFeedback: true) }
    func testNativeDayMoveRecovery() { checkDayMoveFailure(native: true, recovery: true) }
    func testNativeDayMoveFailure() { checkDayMoveFailure(native: true) }
    func testNativeDayMoveBeyondViewport() { checkDayMoveFailure(native: true, beyondViewport: true) }
    func testNativeDayExclusiveMoveControl() { checkDayMoveFailure(native: true, exclusive: true) }
    func testNativeDaySwiftUIMoveControl() { checkDayMoveFailure(native: true, swiftUIControl: true) }

    private func checkDayMoveFailure(native: Bool, swiftUIControl: Bool = false, beyondViewport: Bool = false,
                                     exclusive: Bool = false, parentFeedback: Bool = false, recovery: Bool = false) {
        let app = launch("--plan", extra: ["-mobileDayScrollOffset", "560", "--calendar-native-move-audit",
                                         "--calendar-move-render-probe"]
                         + (native ? [] : ["--calendar-reference-day"])
                         + (swiftUIControl ? ["--calendar-swiftui-day-move"] : [])
                         + (exclusive ? ["--calendar-move-exclusive"] : [])
                         + (parentFeedback ? ["--calendar-parent-move-feedback"] : [])
                         + (recovery ? ["--calendar-recovery-fixture", UUID().uuidString] : []))
        app.segmentedControls.buttons["Day"].tap()
        let viewport = native ? app.collectionViews.firstMatch
            : app.scrollViews.firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 10))
        if native { XCTAssertTrue(app.collectionViews.firstMatch.exists) }
        let event = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Stress event 73,")).firstMatch
        XCTAssertTrue(event.waitForExistence(timeout: 10))
        XCTAssertTrue(event.isHittable)
        let originalFrame = event.frame
        let hour = app.staticTexts["12 PM"].firstMatch
        let control = swiftUIControl || !native || exclusive
        if control { XCTAssertTrue(hour.exists) }
        let originalHourY = control ? hour.frame.minY - viewport.frame.minY : 0
        let originalEventToHour = control ? originalFrame.minY - hour.frame.minY : 0
        func assertControlScrolled() {
            XCTAssertGreaterThan(hour.frame.minY - viewport.frame.minY, originalHourY + 20,
                                 "The old control scrolls the grid down with the finger")
            XCTAssertEqual(event.frame.minY - hour.frame.minY, originalEventToHour, accuracy: 2,
                           "The event must stay at its original time within the scrolled grid")
        }
        let probe = app.descendants(matching: .any)["day.performance.renderCount"].firstMatch
        XCTAssertTrue(probe.exists)
        let rendersBefore = Int(probe.value as? String ?? "")
        XCTAssertNotNil(rendersBefore)
        let start = event.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let distance = beyondViewport
            ? min(app.frame.maxY - 10, viewport.frame.maxY + 20) - originalFrame.midY : 56
        start.press(forDuration: 0.55, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)),
                    withVelocity: .slow, thenHoldForDuration: 0.3)
        // The actionable fixture rejects provider lookup before account restore/networking.
        // Reaching this error proves the move gesture committed, rather than merely scrolling.
        let failure = app.alerts["Couldn’t move that event"]
        let failed = failure.waitForExistence(timeout: 5)
        print("CALENDAR_MOVE_AUDIT=\(viewport.value ?? "missing")")
        print("CALENDAR_MOVE_RENDERS before=\(rendersBefore ?? -1) after=\(probe.value ?? "missing") beyondViewport=\(beyondViewport)")
        if swiftUIControl || !native {
            XCTAssertFalse(failed, "The retained SwiftUI control must reproduce its lost move")
            XCTAssertTrue(viewport.exists)
            assertControlScrolled()
            XCTAssertFalse(app.buttons["eventDetail.edit"].exists)
            capture("swiftui-day-move-negative-control")
            return
        }
        if exclusive {
            // Documented negative control, not the shipping cooperative policy:
            // docs/performance/scale-results/calendar-native-drag-20261010/README.md.
            let audit = viewport.value as? String ?? ""
            XCTAssertFalse(failed, "Exclusive recognition must reproduce its blocked move")
            XCTAssertTrue(audit.contains("preventedBy ") && audit.contains("allowed=true"),
                          "The control must record actual gesture prevention, not an empty interaction")
            XCTAssertTrue(viewport.exists)
            assertControlScrolled()
            XCTAssertFalse(app.buttons["eventDetail.edit"].exists)
            capture("native-day-exclusive-negative-control")
            return
        }
        XCTAssertTrue(failed, "Dragging must reach the existing move-failure path")
        capture(native ? "native-day-move-failure" : "reference-day-move-failure")
        failure.buttons["OK"].tap()
        XCTAssertEqual(event.frame.minY, originalFrame.minY, accuracy: 2,
                       "Rejected movement must restore its original position")
        XCTAssertFalse(app.buttons["eventDetail.edit"].exists, "Moving must not also open the event")
        let day = app.staticTexts["mobile.day.title"].firstMatch
        let previous = day.label
        viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.7))
            .press(forDuration: 0, thenDragTo: viewport.coordinate(
                withNormalizedOffset: CGVector(dx: 0.2, dy: 0.7)))
        let paged = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            day.label != previous
        }, object: day)
        XCTAssertEqual(XCTWaiter.wait(for: [paged], timeout: 3), .completed,
                       "A finished move must release the gesture gate")
        if recovery {
            let recover = app.buttons["calendar.moveRecovery"]
            XCTAssertTrue(recover.waitForExistence(timeout: 5), "Dismissed error must retain recovery access")
            recover.tap()
            let retry = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "calendar.moveRetry.")).firstMatch
            XCTAssertTrue(retry.waitForExistence(timeout: 5))
            let savedID = retry.identifier
            app.buttons["Done"].tap()
            app.terminate()
            app.launch()
            XCTAssertTrue(app.staticTexts["stress.ready"].waitForExistence(timeout: 120))
            app.segmentedControls.buttons["Day"].tap()
            XCTAssertTrue(recover.waitForExistence(timeout: 10), "Pending move must survive relaunch")
            recover.tap()
            XCTAssertTrue(app.buttons[savedID].waitForExistence(timeout: 5), "Same durable operation must be restored")
            capture("calendar-move-recovery-restored")
            app.buttons[savedID].tap()
            let retryError = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "This move is kept for retry.")).firstMatch
            XCTAssertTrue(retryError.waitForExistence(timeout: 10), "Retry must complete with a retained failure")
            XCTAssertTrue(app.buttons[savedID].exists, "Failed retry must remain recoverable")
            let discardID = savedID.replacingOccurrences(of: "calendar.moveRetry.", with: "calendar.moveDiscard.")
            app.buttons[discardID].tap()
            app.buttons["Discard move"].tap()
            XCTAssertTrue(app.staticTexts["No pending calendar moves."].waitForExistence(timeout: 5))
            app.buttons["Done"].tap()
            XCTAssertFalse(recover.exists)
            app.terminate()
            app.launch()
            XCTAssertTrue(app.staticTexts["stress.ready"].waitForExistence(timeout: 120))
            app.segmentedControls.buttons["Day"].tap()
            XCTAssertFalse(recover.exists, "Discard must survive relaunch")
        }
    }

    // List/Agenda was retired in 462fbb35. Exercise real retained settings against the
    // current planner instead of benchmarking an unreachable third picker option.
    func testRetiredListSettingUsesDay() {
        checkRetiredAgendaSetting(["-planMode", "list"])
    }

    func testRetiredAgendaLayoutUsesDay() {
        checkRetiredAgendaSetting(["-mobileWeekLayout", "agenda"])
    }

    private func checkRetiredAgendaSetting(_ settings: [String]) {
        let app = launch("--plan", extra: ["--calendar-viewport-audit", "-mobileDayScrollOffset", "560"] + settings)
        XCTAssertTrue(app.segmentedControls.buttons["Day"].isSelected)
        XCTAssertTrue(app.segmentedControls.buttons["Week"].exists)
        XCTAssertFalse(app.segmentedControls.buttons["List"].exists)
        let viewport = app.collectionViews.firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 10))
        let value = viewport.value as? String ?? ""
        let data = value.data(using: .utf8).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        XCTAssertGreaterThan(data?["descriptors"] as? Int ?? 0, 0, "Migration must show the populated native day")
        let event = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Stress event 61,")).firstMatch
        XCTAssertTrue(event.waitForExistence(timeout: 10))
        XCTAssertTrue(event.isHittable)
        event.tap()
        XCTAssertTrue(app.buttons["eventDetail.edit"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Stress event 61"].exists)
        app.buttons["Done"].tap()
    }

    /// The actionable element deliberately ignores decorative children for VoiceOver. Read
    /// actual renderer-branch mount evidence, rather than asking AX for hidden image identifiers.
    private func requireMountedArtwork(in app: XCUIApplication, title: String? = nil) {
        let probe = app.descendants(matching: .any)["calendar.artwork.mounted"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil(timeout: 10) {
            guard let raw = probe.value as? String, let data = raw.data(using: .utf8),
                  let counts = try? JSONDecoder().decode([String: Int].self, from: data) else { return false }
            if let title {
                return counts["Calendar.artwork.raster:" + title, default: 0]
                    + counts["Calendar.artwork.direct:" + title, default: 0] > 0
            }
            return counts.values.contains { $0 > 0 }
        }, "The selected event must mount real prepared artwork; fallback is not coverage")
        let evidence = XCTAttachment(string: probe.value as? String ?? "missing")
        evidence.name = "mounted-calendar-artwork"; evidence.lifetime = .keepAlways; add(evidence)
    }

    private func checkDenseCalendarScroll(extra: [String], mode: String = "Week") {
        // Exercise the actual mode-switching container. The old standalone --week audit
        // route bypasses PlannerTab and can show a picker inherited from another launch.
        print("CALENDAR_SCROLL_PROTOCOL=4 explicit-week-event-61-reachability/clock-anchor/actionable-offline-fixture")
        let app = launch("--plan", extra: extra)
        XCTAssertTrue(app.segmentedControls.buttons["Week"].isSelected)
        if mode != "Week" {
            app.segmentedControls.buttons[mode].tap()
            XCTAssertTrue(app.segmentedControls.buttons[mode].isSelected)
        }
        let surface = mode == "Day" ? "plan.surface.day" : "plan.surface.week"
        XCTAssertTrue(app.descendants(matching: .any)[surface].firstMatch.waitForExistence(timeout: 10),
                      "The actual content must change, not just the picker highlight")
        print("CALENDAR_SCROLL_MODE=\(mode)")
        if mode == "Week" && !extra.contains("--calendar-reference-week") {
            XCTAssertTrue(app.collectionViews.firstMatch.waitForExistence(timeout: 10),
                          "The default Week view must install its native viewport without an opt-in flag")
        } else if mode == "Week" {
            XCTAssertFalse(app.collectionViews.firstMatch.exists,
                           "The explicit reference must retain the original host")
        }
        if mode == "Day" && !extra.contains("--calendar-reference-day") {
            // Require the reusable collection viewport, rather than the SwiftUI parent identifier.
            XCTAssertTrue(app.collectionViews.firstMatch.waitForExistence(timeout: 10),
                          "The default Day view must install its native reusable viewport without an opt-in flag")
        } else if mode == "Day" {
            XCTAssertTrue(app.scrollViews.firstMatch.exists,
                          "The explicit reference must retain the original scroll host")
            XCTAssertFalse(app.collectionViews.firstMatch.exists)
        }
        // The app initially scrolls to the current hour. Late-night runs used to measure
        // empty hours because fixture events end at 16:30; existence alone accepted offscreen
        // rows. Center the same 10:10 fixture event for both renderer policies.
        if mode == "Week" {
            // The old test accepted event 61's AX hit box outside its clipped column,
            // then opened another event. Require this exact event through the day list.
            let lists = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "calendar.day.items."))
            let window = app.windows.firstMatch.frame
            guard let list = lists.allElementsBoundByIndex.first(where: {
                let frame = $0.frame
                return frame.width > 0 && frame.height > 0
                    && window.contains(CGPoint(x: frame.midX, y: frame.midY))
            }) else {
                XCTFail("Dense days must expose all their items"); return
            }
            app.pointAtCenter(of: list).tap()
            XCTAssertTrue(app.descendants(matching: .any)["calendar.day.items.list"].firstMatch.waitForExistence(timeout: 5))
            let search = app.searchFields.firstMatch
            search.tap(); search.typeText("Stress event 61")
            let row = app.staticTexts["Stress event 61"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            row.tap()
            XCTAssertTrue(app.buttons["eventDetail.edit"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["Stress event 61"].exists)
            app.buttons["Done"].tap()
        }
        let viewport = app.calendarTimeGrid()
        // Match the actual timeline position across virtualized/reference Week hosts.
        let target = mode == "Week" ? app.staticTexts["10 AM"].firstMatch
            : app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Stress event 61,")).firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 10))
        func targetVisible() -> Bool {
            let frame = target.frame
            return mode == "Week" ? frame.height > 0 && frame.midY > viewport.frame.minY + 16
                && frame.midY < viewport.frame.maxY - 30 : target.isHittable
        }
        for _ in 0..<12 where !targetVisible() {
            // Full flings can alternate past the required starting hour. Use the same
            // bounded centering as the native Week recovery check, before measuring.
            let bounds = app.calendarGridViewport() ?? viewport.frame
            let shift = min(bounds.height * 0.4, max(-bounds.height * 0.4,
                                                    bounds.midY - target.frame.midY))
            let origin = app.calendarPoint(in: bounds, y: 0.5)
            origin.press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: 0, dy: shift)),
                         withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        XCTAssertTrue(targetVisible(), "Dense scrolling must start with the actual target time/event visible")
        if extra.contains("--calendar-prepared-artwork") {
            requireMountedArtwork(in: app)
        }
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric(application: app), XCTOSSignpostMetric.scrollingAndDecelerationMetric], options: options) {
            viewport.swipeUp()
            viewport.swipeDown()
        }
        capture("calendar")
        let sprites = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Stress event"))
        guard let sprite = sprites.allElementsBoundByIndex.first(where: { $0.isHittable }) else {
            XCTFail("Event artwork must remain visible after scrolling"); return
        }
        let expectedTitle = String(sprite.label.split(separator: ",")[0])
        if extra.contains("--calendar-prepared-artwork") { requireMountedArtwork(in: app, title: expectedTitle) }
        print("CALENDAR_SELECTED_EVENT=\(sprite.label) frame=\(sprite.frame)")
        let beforeTap = XCTAttachment(string: app.debugDescription)
        beforeTap.name = "calendar-before-event-tap"; beforeTap.lifetime = .keepAlways
        add(beforeTap)
        sprite.tap()
        XCTAssertTrue(app.buttons["eventDetail.edit"].waitForExistence(timeout: 5),
                      "Both renderers must preserve event activation")
        let afterTap = XCTAttachment(string: app.debugDescription)
        afterTap.name = "calendar-after-event-tap"; afterTap.lifetime = .keepAlways
        add(afterTap)
        XCTAssertTrue(app.staticTexts[expectedTitle].exists, "The selected event must open")
        app.buttons["Done"].tap()
    }
}
