import XCTest

/// Runs the real screen with every store overloaded at the same time. No provider services run.
final class ScaleStressUITests: XCTestCase {
    #if PHYSICAL_STRESS_UI_TESTS
    private var requestedOrientation: UIDeviceOrientation?
    private var originalOrientation: UIDeviceOrientation?

    override func setUpWithError() throws {
        try super.setUpWithError()
        try PhysicalSystemIdlePolicy.installIfRequested()
        if let name = ProcessInfo.processInfo.environment["STRESS_DEVICE_ORIENTATION"] {
            let modes: [String: UIDeviceOrientation] = ["portrait": .portrait, "landscape": .landscapeLeft]
            requestedOrientation = try XCTUnwrap(modes[name], "Expected portrait or landscape")
            originalOrientation = XCUIDevice.shared.orientation
        }
    }

    override func tearDownWithError() throws {
        if let originalOrientation, originalOrientation.isPortrait || originalOrientation.isLandscape {
            XCUIDevice.shared.orientation = originalOrientation
        }
        try super.tearDownWithError()
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
        if route == "--plan", ProcessInfo.processInfo.environment["STRESS_CALENDAR_PRESS"] == "race" {
            app.launchArguments.append("--stress-calendar-press-race")
        }
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
        // `MAIL_SENDER_IMAGES=1` (TEST_RUNNER_MAIL_SENDER_IMAGES to xcodebuild): the Mail cases with
        // sender pictures on every third face (drawn stand-ins, MAIL-UX "Sender images"), for an
        // ablation against the same build without them.
        if route == "--mail", ProcessInfo.processInfo.environment["MAIL_SENDER_IMAGES"] == "1" {
            app.launchArguments += ["--mail-sender-images"]
        }
        if route == "--plan" {
            // Older comparison builds used an opt-in fast rate on both axes.
            if ProcessInfo.processInfo.environment["STRESS_FAST_DAY_SNAP"] == "1" {
                app.launchArguments += ["--calendar-fast-day-snap"]
            }
            if ProcessInfo.processInfo.environment["STRESS_REFERENCE_DAY_COAST"] == "1" {
                app.launchArguments += ["--calendar-reference-day-deceleration"]
            }
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
        #if PHYSICAL_STRESS_UI_TESTS
        if let requestedOrientation {
            XCUIDevice.shared.orientation = requestedOrientation
            XCTAssertTrue(waitUntil {
                let size = app.windows.firstMatch.frame.size
                return requestedOrientation.isPortrait ? size.height > size.width : size.width > size.height
            })
        }
        #else
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
        openSelectedMailFullWidth(in: app)
        XCTAssertTrue(app.staticTexts["Stress email 59999"].firstMatch.exists)
        capture("mail-search-retained")
    }

    func testEmptyPowerControlPreparesTheSameFixtureWithoutMountingCalendar() {
        let app = launch("--plan", extra: ["--stress-empty-scene"])
        XCTAssertTrue(app.descendants(matching: .any)["stress.emptyScene"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.segmentedControls.buttons["Day"].exists)
        XCTAssertFalse(app.collectionViews.firstMatch.exists)
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
        app.buttons["sheet.close"].tap()
        XCTAssertTrue(app.buttons["calendar.search.open"].waitForExistence(timeout: 5))
    }

    private func openSelectedMailFullWidth(in app: XCUIApplication) {
        let reader = app.descendants(matching: .any)[MailID.conversation].firstMatch
        let expand = app.descendants(matching: .any)[MailID.expand].firstMatch
        let more = app.buttons["mail.pane.more"]
        // Window width and the pane preference determine how a row opens. A landscape
        // phone can show the same reading pane as a tablet.
        XCTAssertTrue(waitUntil { reader.exists || expand.isHittable || more.isHittable })
        if !reader.exists {
            if !expand.isHittable { more.tap() }
            XCTAssertTrue(expand.waitForExistence(timeout: 5))
            expand.tap()
        }
        XCTAssertTrue(reader.waitForExistence(timeout: 5))
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
        openSelectedMailFullWidth(in: app)
        capture("mail")
    }

    func testLongMailBodyOpensAndScrollsBackToItsBeginning() throws {
        try checkLongMailBody(withPresentationClock: false)
    }

    #if PHYSICAL_STRESS_UI_TESTS
    func testLongMailBodyPresentationAfterARealRowTap() throws {
        try checkLongMailBody(withPresentationClock: true)
    }
    func testPreparedMailBodyPresentationAfterADiskRead() throws {
        try checkLongMailBody(withPresentationClock: true, diskBody: true)
    }

    func testMailBodyPresentationAfterRebuildingAnEvictedCopy() throws {
        try checkLongMailBody(withPresentationClock: true, diskBody: true, originalOnly: true)
    }

    func testDiskBackedMailScrollPastOpeningParagraphs() throws {
        let app = launch("--mail", extra: ["--stress-mail-long-body", "--stress-mail-disk-reader"])
        let row = app.descendants(matching: .any)[MailID.row("long-reader")].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        openSelectedMailFullWidth(in: app)
        let reader = app.descendants(matching: .any)[MailID.conversation].firstMatch
        let first = reader.staticTexts["Section 1. The team reviewed the calendar and travel arrangements."].firstMatch
        XCTAssertTrue(waitUntil { first.isHittable })
        let openingY = first.frame.minY
        let paragraphs = reader.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Section "))
        func firstVisibleSection() -> Int? {
            guard let paragraph = paragraphs.allElementsBoundByIndex.first(where: { $0.isHittable }) else { return nil }
            return Int(paragraph.label.dropFirst("Section ".count).prefix(while: { $0.isNumber }))
        }
        for _ in 0..<18 {
            if (firstVisibleSection() ?? 0) > 90 { break }
            reader.swipeUp()
        }
        XCTAssertGreaterThan(try XCTUnwrap(firstVisibleSection()), 90)
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        var metrics: [XCTMetric] = [XCTCPUMetric(application: app), XCTMemoryMetric(application: app),
                                    XCTOSSignpostMetric.scrollingAndDecelerationMetric]
        if #available(iOS 26, macOS 26, *) { metrics.append(XCTHitchMetric(application: app)) }
        measure(metrics: metrics, options: options) {
            let start = firstVisibleSection() ?? 0
            reader.swipeUp()
            let forward = firstVisibleSection() ?? 0
            XCTAssertGreaterThan(forward, start)
            reader.swipeDown()
            let returned = firstVisibleSection() ?? 0
            XCTAssertGreaterThan(returned, 0)
            XCTAssertLessThan(returned, forward)
        }
        for _ in 0..<32 where !first.isHittable { reader.swipeDown() }
        XCTAssertTrue(first.isHittable)
        reader.swipeDown()
        XCTAssertTrue(waitUntil { abs(first.frame.minY - openingY) < 3 })
    }
    #endif

    private func checkLongMailBody(withPresentationClock clocked: Bool, diskBody: Bool = false,
                                   originalOnly: Bool = false) throws {
        var flags = ["--stress-mail-long-body"]
        if clocked { flags.append("--stress-mail-presentation-clock") }
        if diskBody { flags.append("--stress-mail-disk-reader") }
        if originalOnly { flags.append("--stress-mail-original-only") }
        let app = launch("--mail", extra: flags)
        let clock = app.descendants(matching: .any)["stress.mail.presentationClock"].firstMatch
        func clockReading() -> [String: Any]? {
            guard clock.exists, let raw = clock.value as? String else { return nil }
            return (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any]
        }
        if clocked { XCTAssertTrue(waitUntil { clockReading()?["ready"] as? Bool == true }) }
        let row = app.descendants(matching: .any)[MailID.row("long-reader")].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let start = ProcessInfo.processInfo.systemUptime
        row.tap()
        openSelectedMailFullWidth(in: app)
        let reader = app.descendants(matching: .any)[MailID.conversation].firstMatch
        let paragraphs = reader.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Section "))
        let firstParagraph = "Section 1. The team reviewed the calendar and travel arrangements."
        let first = reader.staticTexts[firstParagraph].firstMatch
        XCTAssertTrue(waitUntil { first.isHittable }, "The first paragraph must be readable")
        let opened = ProcessInfo.processInfo.systemUptime
        let firstY = first.frame.minY
        if clocked {
            let reading = try XCTUnwrap(clockReading())
            XCTAssertNotNil(reading["selected"])
            let lift = try XCTUnwrap(reading["up"] as? Double)
            if diskBody {
                let reads = try XCTUnwrap(reading["diskReads"] as? [[String: Double]])
                XCTAssertEqual(reads.count, 1)
                let read = try XCTUnwrap(reads.first)
                XCTAssertGreaterThan(try XCTUnwrap(read["began"]), lift)
                XCTAssertEqual(read["blocks"], 1200)
                XCTAssertEqual(read["preparedHit"], originalOnly ? 0 : 1)
            }
            try attachGeometry([reading], name: "Mail touch and recording clock")
        }
        for _ in 0..<3 { reader.swipeUp() }
        XCTAssertFalse(first.isHittable)
        let mid = try XCTUnwrap(paragraphs.allElementsBoundByIndex.first(where: { $0.isHittable }))
        XCTAssertNotEqual(mid.label, firstParagraph)
        for _ in 0..<10 where !first.isHittable { reader.swipeDown() }
        XCTAssertTrue(first.isHittable)
        reader.swipeDown()
        XCTAssertTrue(waitUntil { abs(first.frame.minY - firstY) < 3 }, "Return to the same beginning")
        let stats: [String: Any] = ["paragraphs": 1200, "openStart": start, "firstAccessible": opened,
                                    "completed": ProcessInfo.processInfo.systemUptime, "returnedY": first.frame.minY,
                                    "initialY": firstY]
        let metrics = XCTAttachment(data: try JSONSerialization.data(withJSONObject: stats, options: [.sortedKeys]),
                                    uniformTypeIdentifier: "public.json")
        metrics.name = "Long mail reading geometry and timestamps"
        metrics.lifetime = .keepAlways
        add(metrics)
    }

    func testReadingFoldedHistoryKeepsTheReplyAndSignatureAccessible() {
        let app = launch("--mail", extra: ["--stress-mail-long-body"])
        let row = app.descendants(matching: .any)[MailID.row("quoted-reader")].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        openSelectedMailFullWidth(in: app)
        let reader = app.descendants(matching: .any)[MailID.conversation].firstMatch
        let reply = reader.staticTexts["Here is the latest reply."].firstMatch
        let signature = reader.staticTexts["Planning team signature"].firstMatch
        let firstQuote = reader.staticTexts["Previous note 1."].firstMatch
        let reveal = reader.buttons["mail.body.quote"].firstMatch
        XCTAssertTrue(waitUntil { reply.isHittable && reveal.isHittable && signature.isHittable })
        XCTAssertFalse(firstQuote.exists)
        let replyY = reply.frame.minY
        reveal.tap()
        XCTAssertTrue(waitUntil { firstQuote.isHittable && !reveal.exists })
        XCTAssertEqual(reply.frame.minY, replyY, accuracy: 2)
        reader.swipeUp()
        XCTAssertFalse(firstQuote.isHittable)
        for _ in 0..<5 where !firstQuote.isHittable { reader.swipeDown() }
        XCTAssertTrue(firstQuote.isHittable)
        XCTAssertFalse(reveal.exists)
    }

    private static let stressRow = "mail.list.row.stress-"

    /// The first stress row on screen whose number is in `numbers`, found by one query.
    private func stressRow(in numbers: [Int], of app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier IN %@", numbers.map { Self.stressRow + String($0) }))
            .firstMatch
    }

    /// Day zero's hour 21 (rows 1764...1847) lies 152 to 236 rows below the newest mail: with a
    /// 100-row window (`--mail-window-rows 100`) reaching it crosses at least two slides.
    private static let hour21 = Array(1764...1847)

    /// No buttons page the list: flinging alone goes down through several slides of the window,
    /// and flinging back up brings the newest mail back.
    func testMailScrollCrossesSlidingWindowsAndComesBack() {
        executionTimeAllowance = 300
        let app = launch("--mail", extra: ["--mail-window-rows", "100"])
        let list = app.descendants(matching: .any)[MailID.list].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", Self.stressRow))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
        let newest = rows.allElementsBoundByIndex.prefix(3).map {
            Int($0.identifier.dropFirst(Self.stressRow.count)) ?? -1
        }
        XCTAssertFalse(app.buttons["mail.history.older"].exists, "There is no Older button")
        let deep = stressRow(in: Self.hour21, of: app)
        for _ in 0..<60 where !deep.exists { list.swipeUp(velocity: .fast) }
        capture("mail-scroll-deep")
        XCTAssertTrue(deep.exists, "Flinging alone must reach mail 150 rows down, past two slides")
        let top = stressRow(in: newest, of: app)
        for _ in 0..<60 where !top.exists { list.swipeDown(velocity: .fast) }
        XCTAssertTrue(top.exists, "Flinging back up must bring the newest mail back")
        capture("mail-scroll-back")
    }

    /// A search's results keep coming as they are scrolled, past several windows, with no Again
    /// or Older, and a result found that way opens.
    func testMailSearchScrollsThroughItsPagesAndOpens() {
        executionTimeAllowance = 300
        let app = launch("--mail", extra: ["--mail-window-rows", "100"])
        let field = app.textFields["mail.search.query"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap(); field.typeText("Stress email 1\n")
        let list = app.descendants(matching: .any)[MailID.list].firstMatch
        let anyRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", Self.stressRow)).firstMatch
        XCTAssertTrue(anyRow.waitForExistence(timeout: 20))
        // Every row of day zero's hours 21 to 23 matches "1"; hour 21 is 152 results down.
        let deep = stressRow(in: Self.hour21, of: app)
        for _ in 0..<60 where !deep.exists { list.swipeUp(velocity: .fast) }
        capture("mail-search-scroll-deep")
        XCTAssertTrue(deep.exists, "Scrolling a search must load its later pages")
        guard deep.exists, let number = Int(deep.identifier.dropFirst(Self.stressRow.count)) else { return }
        deep.tap()
        openSelectedMailFullWidth(in: app)
        XCTAssertTrue(app.staticTexts["Stress email \(number)"].firstMatch.exists)
    }

    /// Frame hitches while flinging down through pages of older mail: every iteration goes on
    /// from where the last one stopped, so the list appends pages under the fling. Simulator
    /// evidence for comparison only, not 120 Hz acceptance.
    func testMailScrollThroughPagesHitches() {
        let app = launch("--mail")
        let list = app.descendants(matching: .any)[MailID.list].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        let rows = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "mail.list.row.stress-"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
        let first = Set(rows.allElementsBoundByIndex.filter(\.isHittable).map(\.identifier))
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric], options: options) {
            for _ in 0..<4 { list.swipeUp(velocity: .fast) }
        }
        let last = Set(rows.allElementsBoundByIndex.filter(\.isHittable).map(\.identifier))
        XCTAssertFalse(last.isEmpty, "Rows must still be on screen after flinging through pages")
        XCTAssertTrue(first.isDisjoint(with: last), "The flings must have travelled through pages")
    }

    /// The same flings through a 300-row window, so the list also slides under them
    /// (`--mail-window-rows`; the commit before continuous scrolling ignores the argument).
    func testMailScrollThroughSlidingWindowsHitches() {
        let app = launch("--mail", extra: ["--mail-window-rows", "300"])
        let list = app.descendants(matching: .any)[MailID.list].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        let rows = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "mail.list.row.stress-"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
        let first = Set(rows.allElementsBoundByIndex.filter(\.isHittable).map(\.identifier))
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric], options: options) {
            for _ in 0..<4 { list.swipeUp(velocity: .fast) }
        }
        let last = Set(rows.allElementsBoundByIndex.filter(\.isHittable).map(\.identifier))
        XCTAssertFalse(last.isEmpty, "Rows must still be on screen after flinging through windows")
        XCTAssertTrue(first.isDisjoint(with: last), "The flings must have travelled through windows")
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
        openSelectedMailFullWidth(in: app)
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

    func testMarkPlayedKeepsNeighbourAndUndoRestoresEpisode() {
        let app = launch("--library-detail")
        let heading = app.staticTexts["library.episodes.heading"]
        let first = app.descendants(matching: .any)["podcast.episode.stress-0-0"].firstMatch
        let ordered = (0..<1000).sorted { ($0 * 7919) % 1000 < ($1 * 7919) % 1000 }
        let neighbour = app.descendants(matching: .any)["podcast.episode.stress-0-\(ordered[1])"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        for _ in 0..<4 where !first.isHittable { app.swipeUp() }
        XCTAssertTrue(first.isHittable)
        XCTAssertTrue(neighbour.exists)
        let initialCount = heading.label
        let menu = app.buttons["Download"].firstMatch
        XCTAssertTrue(menu.isHittable)
        menu.press(forDuration: 1.1)
        let mark = app.buttons["Mark as Played"].firstMatch
        XCTAssertTrue(mark.waitForExistence(timeout: 3))
        mark.tap()
        XCTAssertTrue(waitUntil { !first.exists && neighbour.exists && heading.label != initialCount })
        XCTAssertFalse(app.staticTexts["Loading episodes…"].exists)
        let undo = app.buttons["toast.undo"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 3))
        undo.tap()
        XCTAssertTrue(waitUntil { first.exists && neighbour.exists && heading.label == initialCount })
        capture("podcasts-mark-played-undo")
    }


    func testNativeWeekCalendarScroll() {
        checkDenseCalendarScroll(extra: [])
    }

    #if PHYSICAL_STRESS_UI_TESTS
    func testDefaultVariedWeekArtwork() { checkVariedArtwork(mode: "Week", prepared: false) }
    func testDefaultVariedDayArtwork() { checkVariedArtwork(mode: "Day", prepared: false) }

    func testPreparedVariedWeekArtwork() { checkVariedArtwork(mode: "Week", prepared: true) }
    func testPreparedVariedDayArtwork() { checkVariedArtwork(mode: "Day", prepared: true) }

    private func checkVariedArtwork(mode: String, prepared: Bool) {
        let renderer = prepared ? "prepared" : "default"
        XCUIDevice.shared.orientation = .portrait
        let app = launch("--plan", extra: ["--stress-calendar-fixture", "varied-v1",
                                          "-mobileDayScrollOffset", "560"] + (prepared ? ["--calendar-prepared-artwork"] : []))
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
        evidence.name = "\(renderer)-\(mode)-installed-workload"
        evidence.lifetime = .keepAlways; add(evidence)
        app.segmentedControls.buttons[mode].tap()
        let viewport = app.collectionViews.firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 10))
        let preparedArtwork = viewport.descendants(matching: .any).matching(NSPredicate(format: "identifier IN %@",
            ["calendar.preparedArtwork", "calendar.nativeArtwork.direct"]))
        // The normal renderer makes the event itself an accessible button. Prepared images
        // and direct canvases belong to the opt-in renderer and have their own readiness check.
        let artwork = prepared ? preparedArtwork : viewport.buttons.matching(
            NSPredicate(format: "label MATCHES %@", #".+ · [0-9]+-[0-9]+, .+"#))
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
            capture("\(renderer)-varied-\(mode)-readiness-failure")
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "\(renderer)-\(mode)-readiness-failure-hierarchy"
            hierarchy.lifetime = .keepAlways; add(hierarchy)
        }
        XCTAssertEqual(readiness, .completed,
                       "The selected renderer must show populated events")
        if !prepared { XCTAssertFalse(preparedArtwork.firstMatch.exists) }
        viewport.swipeUp(); viewport.swipeDown()
        XCTAssertEqual(app.descendants(matching: .any)
            .matching(identifier: "calendar.preparedArtwork.failed").count, 0)
        guard let event = visibleArtwork(),
              let suffix = event.label.range(of: #" · [0-9]+-[0-9]+"#, options: .regularExpression) else {
            XCTFail("Replacement artwork must remain visible after scrolling"); return
        }
        let title = String(event.label[..<suffix.upperBound])
        capture("\(renderer)-varied-\(mode)-artwork")
        let visible = event.frame.intersection(viewport.frame)
        event.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: visible.midX - event.frame.minX,
                                 dy: visible.midY - event.frame.minY)).tap()
        XCTAssertTrue(app.buttons["eventDetail.edit"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[title].exists, "The exact rendered event must open")
        capture("\(renderer)-varied-\(mode)-detail")
        app.buttons["sheet.close"].tap()
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
    // same fixture, device and interaction window for both native calendar modes.
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

    private func checkPhysicalScrollTrace(mode: String, density: Int = 100, extra: [String] = []) {
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
        let viewport = app.collectionViews.firstMatch
        if !viewport.waitForExistence(timeout: 10) {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "physical-scroll-trace-missing-viewport-hierarchy"
            hierarchy.lifetime = .keepAlways; add(hierarchy)
            XCTFail("Native collection viewport did not appear")
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
        let tenAM = app.staticTexts["10 AM"].firstMatch
        let tenAMFrame = tenAM.exists ? "\(tenAM.frame)" : "absent"
        let geometry = XCTAttachment(string: "mode=\(mode) flags=\(extra) viewport=native orientation=\(orientation) app=\(app.frame) frame=\(viewport.frame) tenAM=\(tenAMFrame) cells=\(viewport.cells.count)")
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

    func testNativeWeekEdgePullPagesAndReturnsWithoutChangingTheTime() {
        let app = launch("--plan", extra: ["--calendar-viewport-audit", "--calendar-opening-hour", "9"])
        let viewport = app.collectionViews.firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 10))
        func number(_ key: String) -> CGFloat {
            guard let text = viewport.value as? String, let data = text.data(using: .utf8),
                  let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let value = state[key] as? NSNumber else { return -1 }
            return CGFloat(value.doubleValue)
        }
        let title = app.staticTexts["mobile.day.title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        // Scrolling virtualizes the visible cells. The date range identifies the week.
        func week() -> String? { title.exists ? title.label : nil }
        let original = week()
        XCTAssertNotNil(original)
        // Ordinary swipes still browse the current week's columns before its boundary.
        for _ in 0..<8 {
            if number("x") >= max(0, number("contentWidth") - number("width")) - 2 { break }
            let before = number("x")
            viewport.swipeLeft()
            XCTAssertTrue(waitUntil { number("x") > before + 2 })
            XCTAssertEqual(week(), original)
        }
        let maximum = max(0, number("contentWidth") - number("width"))
        XCTAssertEqual(number("x"), maximum, accuracy: 2)
        let y = number("y")
        func pull(from: CGFloat, to: CGFloat) {
            viewport.coordinate(withNormalizedOffset: CGVector(dx: from, dy: 0.3))
                .press(forDuration: 0.02, thenDragTo: viewport.coordinate(withNormalizedOffset: CGVector(dx: to, dy: 0.3)),
                       withVelocity: .fast, thenHoldForDuration: 0)
        }
        pull(from: 0.65, to: 0.55)
        XCTAssertTrue(waitUntil { abs(number("x") - maximum) < 2 })
        XCTAssertEqual(week(), original, "A short extension springs back into the same week")
        pull(from: 0.85, to: 0.15)
        XCTAssertTrue(waitUntil {
            guard let visibleWeek = week() else { return false }
            return visibleWeek != original && abs(number("x")) < 2
        })
        XCTAssertEqual(number("y"), y, accuracy: 3)
        XCTAssertEqual(number("gutterX"), number("x"), accuracy: 1)
        pull(from: 0.15, to: 0.85)
        XCTAssertTrue(waitUntil { week() == original && abs(number("x") - maximum) < 2 })
        XCTAssertEqual(number("y"), y, accuracy: 3)
        let beforeScroll = number("y")
        viewport.swipeUp()
        XCTAssertTrue(waitUntil { number("y") > beforeScroll })
        XCTAssertEqual(week(), original, "Vertical scrolling at a week edge never changes weeks")
        capture("native-week-edge-pull")
    }

    func testNativeWeekRotation() { checkNativeWeekRotation(extra: []) }

    func testReferenceWeekHeaderPublication() {
        checkNativeWeekRotation(extra: ["--calendar-reference-header-publication"])
    }

    private func checkNativeWeekRotation(extra: [String]) {
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launch("--plan", extra: ["--calendar-viewport-audit", "--calendar-opening-hour", "9",
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
        // The fixture starts today. Use the following week so a selected column
        // has real events even late in the current week, before rotating.
        let initialWeek = app.calendarDaySnapshot(referenceID: "mobile.day.surface.0")
        app.buttons["Next week"].tap()
        XCTAssertTrue(waitUntil {
            app.calendarDaySnapshot(referenceID: "mobile.day.surface.0") != initialWeek && number("visibleCells") > 0
        })
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

    func testNativeDayPagingAndZoom() throws {
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
        #if PHYSICAL_STRESS_UI_TESTS
        let orientation = try XCTUnwrap(UIInterfaceOrientation(rawValue: XCUIDevice.shared.orientation.rawValue))
        let delivered = expectation(description: "Delivered the two-finger spread")
        var spreadError: Error?
        PhysicalCalendarFlicks.spread(in: viewport.frame, screenSize: XCUIScreen.main.screenshot().image.size,
                                      orientation: orientation) { error in
            spreadError = error
            delivered.fulfill()
        }
        wait(for: [delivered], timeout: 5)
        if let spreadError { throw spreadError }
        #else
        viewport.pinch(withScale: 1.5, velocity: 1)
        #endif
        // Zoom can recycle the 11 AM ruler. Require the real content geometry to grow,
        // rather than querying an hour that is no longer in the visible native viewport.
        let zoomed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            contentHeight() > heightBeforeZoom * 1.25
        }, object: viewport)
        let zoomResult = XCTWaiter.wait(for: [zoomed], timeout: 3)
        if zoomResult != .completed, let geometry = viewport.value as? String {
            let diagnostic = XCTAttachment(string: geometry)
            diagnostic.name = "Day pinch recognizer and resulting geometry"
            diagnostic.lifetime = .keepAlways
            add(diagnostic)
        }
        XCTAssertEqual(zoomResult, .completed)
        capture("native-day-paging-zoom")
    }

    func testVerticalCalendarFlingKeepsTheSelectedDate() throws {
        let app = launch("--plan", extra: ["-mobileDayScrollOffset", "560", "--calendar-viewport-audit"])
        app.segmentedControls.buttons["Day"].tap()
        let grid = app.collectionViews.firstMatch
        XCTAssertTrue(grid.waitForExistence(timeout: 10))
        func sample() throws -> [String: Any] {
            let raw = try XCTUnwrap(grid.value as? String)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        }
        let start = try sample()
        let y = try XCTUnwrap(start["y"] as? Double)
        XCTAssertGreaterThan(y, 40)
        let from = grid.coordinate(withNormalizedOffset: CGVector(dx: 0.63, dy: 0.25))
        let distance = min(90, grid.frame.height * 0.4)
        from.press(forDuration: 0, thenDragTo: from.withOffset(CGVector(dx: 0, dy: distance)),
                   withVelocity: .fast, thenHoldForDuration: 0)
        let end = try sample()
        XCTAssertLessThan(try XCTUnwrap(end["y"] as? Double), y - 20)
        XCTAssertEqual(end["page"] as? String, start["page"] as? String)
        XCTAssertEqual(try XCTUnwrap(end["x"] as? Double), try XCTUnwrap(start["x"] as? Double), accuracy: 1)
        try attachGeometry([start, end], name: "Vertical day fling geometry")
    }

    func testDayZoomTracksTheDeliveredPinch() throws {
        let app = launch("--plan", extra: ["-mobileDayScrollOffset", "560", "--calendar-viewport-audit"])
        app.segmentedControls.buttons["Day"].tap()
        let viewport = app.collectionViews.firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 10))
        func audit() -> [String: Any] {
            guard let raw = viewport.value as? String,
                  let values = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
            else { return [:] }
            return values
        }
        var measurements = [audit()]
        for scale: CGFloat in [1.5, 2.0] {
            let before = try XCTUnwrap(measurements.last)
            let height = try XCTUnwrap(before["contentHeight"] as? Double)
            let starts = try XCTUnwrap(before["pinchStarts"] as? Int)
            viewport.pinch(withScale: scale, velocity: 1)
            XCTAssertTrue(waitUntil { (audit()["pinchStarts"] as? Int ?? 0) > starts })
            let after = audit()
            let delivered = try XCTUnwrap(after["pinchEndScale"] as? Double)
            let actual = try XCTUnwrap(after["contentHeight"] as? Double)
            XCTAssertGreaterThan(delivered, 1)
            XCTAssertEqual(actual / 24, min(160, max(44, height * delivered / 24)), accuracy: 1,
                           "Draw the hour height requested by the two fingers within the supported zoom range")
            measurements.append(after)
        }
        let initial = try XCTUnwrap(measurements.first?["contentHeight"] as? Double)
        let final = try XCTUnwrap(measurements.last?["contentHeight"] as? Double)
        XCTAssertGreaterThan(final, initial * 1.25)
        try attachGeometry(measurements, name: "Day delivered pinch scales and displayed hour heights")
    }

    func testDaySwipesKeepTheTimeInPortrait() throws {
        try checkDaySwipes(orientation: .portrait)
    }

    func testDaySwipesKeepTheTimeInLandscape() throws {
        try checkDaySwipes(orientation: .landscapeLeft)
    }

    /// UIKit's scrolling signposts cover the drag and deceleration. Check both destinations on
    /// every iteration so a motionless or repeated page cannot produce a fast passing sample.
    func testDaySwipeRoundTripHitches() throws {
        let app = launch("--plan", extra: ["-mobileDayScrollOffset", "560", "--calendar-viewport-audit"])
        app.segmentedControls.buttons["Day"].tap()
        let grid = app.collectionViews.firstMatch
        XCTAssertTrue(grid.waitForExistence(timeout: 10))
        func page() -> String? {
            guard let value = grid.value as? String,
                  let state = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any]
            else { return nil }
            return state["page"] as? String
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        let initial = try XCTUnwrap(page())
        let date = try XCTUnwrap(formatter.date(from: initial))
        let next = formatter.string(from: try XCTUnwrap(formatter.calendar.date(byAdding: .day, value: 1, to: date)))
        let leading = grid.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.65))
        let trailing = grid.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.65))
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        var metrics: [XCTMetric] = [XCTOSSignpostMetric.scrollingAndDecelerationMetric]
        if #available(iOS 26, macOS 26, *) { metrics.append(XCTHitchMetric(application: app)) }
        measure(metrics: metrics, options: options) {
            trailing.press(forDuration: 0, thenDragTo: leading)
            XCTAssertTrue(waitUntil { page() == next })
            leading.press(forDuration: 0, thenDragTo: trailing)
            XCTAssertTrue(waitUntil { page() == initial })
        }
    }

    func testDaySwipesAcrossAllDayBandsInPortrait() throws {
        try checkDaySwipes(orientation: .portrait, changingBands: true)
    }

    func testDaySwipesAcrossAllDayBandsInLandscape() throws {
        try checkDaySwipes(orientation: .landscapeLeft, changingBands: true)
    }

    private func checkDaySwipes(orientation: UIDeviceOrientation, changingBands: Bool = false) throws {
        let originalOrientation = XCUIDevice.shared.orientation
        defer {
            if originalOrientation.isPortrait || originalOrientation.isLandscape {
                XCUIDevice.shared.orientation = originalOrientation
            }
        }
        let app = launch("--plan", extra: ["-mobileDayScrollOffset", "560", "--calendar-viewport-audit"]
                         + (changingBands ? ["--stress-calendar-day-bands"] : []))
        XCUIDevice.shared.orientation = orientation
        XCTAssertTrue(waitUntil {
            let frame = app.windows.firstMatch.frame
            return orientation.isPortrait ? frame.height > frame.width : frame.width > frame.height
        })
        app.segmentedControls.buttons["Day"].tap()
        let viewport = app.collectionViews.firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 10))
        let windowSize = app.windows.firstMatch.frame.size
        func state() -> [String: Any]? {
            guard let value = viewport.value as? String,
                  var state = (try? JSONSerialization.jsonObject(with: Data(value.utf8))) as? [String: Any]
            else { return nil }
            state["windowWidth"] = windowSize.width
            state["windowHeight"] = windowSize.height
            return state
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        let initial = try XCTUnwrap(state())
        var date = try XCTUnwrap((initial["page"] as? String).flatMap(formatter.date(from:)))
        let initialY = try XCTUnwrap(initial["y"] as? Double)
        let height = try XCTUnwrap(initial["height"] as? Double)
        let contentHeight = try XCTUnwrap(initial["contentHeight"] as? Double)
        XCTAssertEqual(initialY, min(560, max(0, contentHeight - height)), accuracy: 2,
                       "Open at the saved hour, clamped only by the final viewport")
        let initialRulerY = try XCTUnwrap(initial["windowY"] as? Double) - initialY
        func eventIDs(_ state: [String: Any]) -> [String] {
            (state["visibleIDs"] as? [String] ?? []).filter { !$0.contains("calendar.currentTime") }.sorted()
        }
        let originalIDs = eventIDs(initial)
        XCTAssertFalse(originalIDs.isEmpty)
        var observations = [initial]
        func attachObservations() {
            do {
                try attachGeometry(observations, name: "Day swipe geometry and redraw counts")
            } catch { XCTFail("Could not save swipe geometry: \(error)") }
        }
        var daysFromStart = 0
        for direction in [1, 1, -1, -1] {
            daysFromStart += direction
            date = try XCTUnwrap(formatter.calendar.date(byAdding: .day, value: direction, to: date))
            let expected = formatter.string(from: date)
            func point(_ x: CGFloat) -> XCUICoordinate {
                viewport.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.65))
            }
            point(direction > 0 ? 0.8 : 0.2).press(forDuration: 0, thenDragTo: point(direction > 0 ? 0.2 : 0.8))
            let reachedExpectedDay = waitUntil { state()?["page"] as? String == expected }
            if !reachedExpectedDay {
                if let stalled = state() { observations.append(stalled) }
                attachObservations()
            }
            XCTAssertTrue(reachedExpectedDay)
            let landed = try XCTUnwrap(state())
            observations.append(landed)
            let landedY = try XCTUnwrap(landed["y"] as? Double)
            let rulerY = try XCTUnwrap(landed["windowY"] as? Double) - landedY
            let gutterX = try XCTUnwrap(landed["gutterX"] as? Double) - (try XCTUnwrap(landed["x"] as? Double))
            // A changing band can resize the viewport. The hour's absolute screen
            // position is the invariant; unchanged chrome also preserves its raw offset.
            if (!changingBands && abs(landedY - initialY) > 2) || abs(rulerY - initialRulerY) > 2 || abs(gutterX) > 2 {
                attachObservations()
            }
            if changingBands {
                let title = "Calendar workshop \(daysFromStart)-1"
                let chip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
                XCTAssertEqual(chip.exists, daysFromStart != 0)
            } else { XCTAssertEqual(landedY, initialY, accuracy: 2) }
            XCTAssertEqual(rulerY, initialRulerY, accuracy: 2, "The same hour must stay at the same window position")
            XCTAssertEqual(gutterX, 0, accuracy: 2, "The ruler must stay at the leading edge of the viewport")
        }
        attachObservations()
        XCTAssertEqual(eventIDs(try XCTUnwrap(observations.last)), originalIDs)
        // A short lateral drag can be abandoned over an event without opening it or changing day.
        let middle = viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
        middle.press(forDuration: 0, thenDragTo: middle.withOffset(CGVector(dx: 22, dy: 0)),
                     withVelocity: .slow, thenHoldForDuration: 0.2)
        let afterShortDrag = try XCTUnwrap(state())
        try attachGeometry([initial, afterShortDrag], name: "Day cancelled swipe resting geometry")
        XCTAssertEqual(afterShortDrag["page"] as? String, initial["page"] as? String)
        XCTAssertEqual(try XCTUnwrap(afterShortDrag["x"] as? Double),
                       try XCTUnwrap(initial["x"] as? Double), accuracy: 2)
        XCTAssertEqual(try XCTUnwrap(afterShortDrag["y"] as? Double), initialY, accuracy: 2)
        XCTAssertEqual(eventIDs(afterShortDrag), originalIDs)
    }

    private func attachGeometry(_ states: [[String: Any]], name: String) throws {
        let data = try JSONSerialization.data(withJSONObject: states, options: [.sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        #if PHYSICAL_STRESS_UI_TESTS
        // The paired XCTest service can deliver a verdict without delivering attachment bytes.
        // Mirror this fixture's numeric audit into the test runner's own temporary directory.
        if let key = ProcessInfo.processInfo.environment["STRESS_GEOMETRY_RUN"], let run = UUID(uuidString: key) {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(run.uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let filename = self.name.replacingOccurrences(of: "/", with: "-") + "-" + name + "-" + UUID().uuidString + ".json"
            try data.write(to: directory.appendingPathComponent(filename), options: .atomic)
        }
        #endif
    }

    #if PHYSICAL_STRESS_UI_TESTS
    func testFirstVisibleDayMotionDuringARealFlick() throws {
        let app = launch("--plan", extra: ["-mobileDayScrollOffset", "560", "--calendar-viewport-audit",
                                          "--calendar-flick-trace", "--stress-calendar-presentation-clock"])
        app.segmentedControls.buttons["Day"].tap()
        let grid = app.collectionViews["calendar.nativeDay.viewport"]
        let clock = app.descendants(matching: .any)["stress.calendar.presentationClock"].firstMatch
        func read(_ element: XCUIElement) -> [String: Any]? {
            guard element.exists, let raw = element.value as? String else { return nil }
            return try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
        }
        XCTAssertTrue(waitUntil { read(clock)?["ready"] as? Bool == true && grid.exists })
        let initial = try XCTUnwrap(read(grid))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        let firstPage = try XCTUnwrap(initial["page"] as? String)
        let firstDate = try XCTUnwrap(formatter.date(from: firstPage))
        let nextDate = try XCTUnwrap(formatter.calendar.date(byAdding: .day, value: 1, to: firstDate))
        let nextPage = formatter.string(from: nextDate)
        let initialY = try XCTUnwrap(initial["y"] as? Double)
        let orientation = try XCTUnwrap(UIInterfaceOrientation(rawValue: XCUIDevice.shared.orientation.rawValue))
        let screen = XCUIScreen.main.screenshot().image.size
        for index in 0..<4 {
            let before = try XCTUnwrap(read(grid))
            let forward = index.isMultiple(of: 2)
            let done = expectation(description: "Physical test driver delivered the drag")
            var failure: Error?
            PhysicalCalendarFlicks.send(in: grid.frame, screenSize: screen, orientation: orientation,
                                        directions: [NSNumber(value: forward)]) { error in failure = error; done.fulfill() }
            wait(for: [done], timeout: 5)
            if let failure { throw failure }
            XCTAssertTrue(waitUntil {
                guard let after = read(grid), let page = after["page"] as? String,
                      let old = before["page"] as? String, let drag = after["lastDayDrag"] as? [String: Double],
                      let settled = drag["settled"], let released = drag["release"], settled >= released else { return false }
                return page != old && page == (forward ? nextPage : firstPage)
            })
            let input = try XCTUnwrap(read(clock))
            let contact = try XCTUnwrap(input["contact"] as? [[Double]])
            XCTAssertGreaterThan(contact.count, 2)
            XCTAssertNotNil(input["up"])
            let after = try XCTUnwrap(read(grid))
            XCTAssertEqual(try XCTUnwrap(after["y"] as? Double), initialY, accuracy: 2)
            try attachGeometry([before, after, input], name: "Calendar input and recording clock " + String(index))
        }
    }

    func testConsecutiveDayFlicksDuringTheCoast() throws {
        let app = launch("--plan", extra: ["-mobileDayScrollOffset", "560", "--calendar-viewport-audit", "--calendar-flick-trace"])
        app.segmentedControls.buttons["Day"].tap()
        let viewport = app.collectionViews["calendar.nativeDay.viewport"]
        XCTAssertTrue(viewport.waitForExistence(timeout: 10))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        func geometry() -> [String: Any]? {
            guard viewport.exists, let raw = viewport.value as? String else { return nil }
            return try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
        }
        let initial = try XCTUnwrap(geometry())
        let firstDate = try XCTUnwrap((initial["page"] as? String).flatMap(formatter.date(from:)))
        let y = try XCTUnwrap(initial["y"] as? Double)
        let orientation = try XCTUnwrap(UIInterfaceOrientation(rawValue: XCUIDevice.shared.orientation.rawValue))
        let screen = XCUIScreen.main.screenshot().image.size
        let centeredX = try XCTUnwrap(initial["x"] as? Double)
        // Uninterrupted forward, reverse, then a change of mind during the coast.
        let chains = [[true, true], [false, false], [true, false],
                      [true, true, true, true], [false, false, true, false], [false, false],
                      Array(repeating: true, count: 8), Array(repeating: false, count: 8)]
        var offset = 0
        var trackedRecycles = 0
        for directions in chains {
            offset += directions.reduce(0) { $0 + ($1 ? 1 : -1) }
            let previousRelease = ((geometry()?["lastDayDrag"] as? [String: Double])?["release"]) ?? 0
            let done = expectation(description: "XCTest delivered the flick sequence")
            var deliveryError: Error?
            XCTAssertEqual(app.state, .runningForeground)
            PhysicalCalendarFlicks.send(in: viewport.frame, screenSize: screen, orientation: orientation,
                                       directions: directions.map { NSNumber(value: $0) }) { error in
                deliveryError = error
                done.fulfill()
            }
            wait(for: [done], timeout: 8)
            if let deliveryError { throw deliveryError }
            let expected = formatter.string(from: try XCTUnwrap(formatter.calendar.date(byAdding: .day, value: offset, to: firstDate)))
            let reached = waitUntil {
                guard let view = geometry(), view["page"] as? String == expected,
                      let x = view["x"] as? Double, abs(x - centeredX) < 1,
                      let drag = view["lastDayDrag"] as? [String: Double],
                      let released = drag["release"], released > previousRelease,
                      let settled = drag["settled"], settled >= released else { return false }
                let phases = (view["dayGestureHistory"] as? [[String: Any]]) ?? []
                return phases.isEmpty || phases.filter {
                    $0["phase"] as? String == "released" && ($0["time"] as? Double ?? 0) > previousRelease
                }.count >= directions.count
            }
            let after = try XCTUnwrap(geometry())
            try attachGeometry([initial, after], name: "Consecutive day flicks approaching " + expected)
            XCTAssertTrue(reached, "Every deliberate flick must count, including a reversal. Expected \(expected), displayed \(after["page"] ?? "unknown").")
            let phases = try XCTUnwrap(after["dayGestureHistory"] as? [[String: Any]])
            for index in phases.indices.dropFirst() {
                let before = phases[index - 1], rebased = phases[index]
                guard rebased["phase"] as? String == "page after", let shift = rebased["shift"] as? Double,
                      (rebased["time"] as? Double ?? 0) > previousRelease,
                      before["phase"] as? String == "page before" else { continue }
                let newX = try XCTUnwrap(rebased["x"] as? Double)
                XCTAssertEqual(newX + shift, try XCTUnwrap(before["x"] as? Double), accuracy: 1,
                               "Reusing the columns must leave the visible date at the same position.")
                guard index + 1 < phases.count else { continue }
                let next = phases[index + 1]
                guard next["phase"] as? String == "scroll after rebase" else { continue }
                let finger = try XCTUnwrap(next["dx"] as? Double) - XCTUnwrap(rebased["dx"] as? Double)
                let motion = try XCTUnwrap(next["x"] as? Double) - newX
                // At an edge UIKit can resist the finger. In the interior it follows it directly.
                XCTAssertLessThanOrEqual(abs(motion), abs(finger) + 2)
                if min(newX, newX + motion) > 16, max(newX, newX + motion) < 2 * abs(shift) - 16 {
                    XCTAssertEqual(motion, -finger, accuracy: 2)
                }
                trackedRecycles += 1
            }
            XCTAssertEqual(try XCTUnwrap(after["y"] as? Double), y, accuracy: 2)
            if offset == 0 {
                XCTAssertEqual(Set(try XCTUnwrap(initial["visibleIDs"] as? [String])),
                               Set(try XCTUnwrap(after["visibleIDs"] as? [String])))
            }
        }
        XCTAssertGreaterThan(trackedRecycles, 0, "The touches must interrupt at least one moving date.")
    }
    #endif

    func testShortDayFlickMovesOneDateAndReturns() throws {
        let app = launch("--plan", extra: ["-mobileDayScrollOffset", "560", "--calendar-viewport-audit"])
        app.segmentedControls.buttons["Day"].tap()
        let viewport = app.collectionViews.firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 10))
        func page() -> String? {
            guard let raw = viewport.value as? String,
                  let audit = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
            else { return nil }
            return audit["page"] as? String
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        let initial = try XCTUnwrap(page())
        let today = try XCTUnwrap(formatter.date(from: initial))
        let tomorrow = try XCTUnwrap(formatter.calendar.date(byAdding: .day, value: 1, to: today))
        let length = min(140, viewport.frame.width / 4)
        for (delta, target) in [(-length, formatter.string(from: tomorrow)), (length, initial)] {
            let start = viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
            start.press(forDuration: 0, thenDragTo: start.withOffset(CGVector(dx: delta, dy: 0)),
                        withVelocity: .fast, thenHoldForDuration: 0)
            XCTAssertTrue(waitUntil { page() == target }, "A short, fast flick must page exactly once")
        }
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
            return (state["displayedColumnDescriptors"] as? Int ?? state["descriptors"] as? Int) == 0
        }, object: viewport)
        XCTAssertEqual(XCTWaiter.wait(for: [empty], timeout: 5), .completed)
    }

    func testNativeDayEventAccessibility() { checkDayEventAccessibility(extra: []) }
    func testPreparedDayEventAccessibility() { checkDayEventAccessibility(extra: ["--calendar-prepared-artwork"]) }


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
            app.buttons["sheet.close"].tap()
        }
    }

    func testLegacyNativeDayAccessibilityScroll() {
        checkDenseCalendarScroll(extra: ["-mobileDayScrollOffset", "560", "--calendar-reference-event-accessibility"], mode: "Day")
    }

    func testVariedNativeDayScroll() { checkVariedDay() }
    func testCachedVariedNativeDayScroll() {
        checkVariedDay(extra: ["--calendar-cache-layout"])
    }

    func testReferenceNeighborsVariedNativeDayScroll() {
        checkVariedDay(extra: ["--calendar-reference-neighbors"])
    }

    private func checkVariedDay(extra: [String] = []) {
        let app = launch("--plan", extra: ["--stress-calendar-fixture", "varied-v1", "-mobileDayScrollOffset", "560"]
                         + extra)
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
        let viewport = app.collectionViews.firstMatch
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
        capture("varied-native-day")
        event.tap()
        XCTAssertTrue(app.buttons["eventDetail.edit"].waitForExistence(timeout: 5))
        capture("varied-selected-detail")
        XCTAssertTrue(app.staticTexts[title].exists, "The selected varied event must open")
        app.buttons["sheet.close"].tap()
        let day = app.staticTexts["mobile.day.title"].firstMatch
        let first = day.label
        app.buttons["Next day"].tap()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in day.label != first }, object: day)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 3), .completed)
        XCTAssertTrue(events.allElementsBoundByIndex.contains(where: { $0.isHittable }))
        capture("varied-native-next-day")
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

    func testWeekEventAccessibilityFramesStayInsideTheirDay() throws {
        let app = launch("--plan", extra: ["--calendar-viewport-audit"])
        let week = app.segmentedControls.buttons["Week"]
        XCTAssertTrue(week.waitForExistence(timeout: 10))
        if !week.isSelected { week.tap() }
        let grid = app.collectionViews.firstMatch
        XCTAssertTrue(grid.waitForExistence(timeout: 10))
        // Read the cell and its descendants in one snapshot. Index-based live queries
        // can resolve to a different reusable cell between successive frame reads.
        let tree = try grid.snapshot()
        var checked = 0, clipped = 0
        var widestSpill: CGFloat = 0
        var violations: [String] = []
        func visit(_ node: XCUIElementSnapshot, in cell: CGRect?) {
            let bounds = node.elementType == .cell ? node.frame : cell
            if node.elementType == .button, node.label.hasPrefix("Stress event"),
               let bounds, !bounds.intersection(tree.frame).isEmpty {
                let button = node.frame
                let spill = max(bounds.minX - button.minX, button.maxX - bounds.maxX)
                if spill > 1 {
                    violations.append("\(node.label) cell=\(bounds) button=\(button)")
                }
                widestSpill = max(widestSpill, spill)
                if bounds.width < 23.5 { clipped += 1 }
                checked += 1
            }
            for child in node.children { visit(child, in: bounds) }
        }
        visit(tree, in: nil)
        XCTAssertGreaterThan(checked, 0)
        XCTAssertGreaterThan(clipped, 0, "Exercise an event clipped at the end of its day column")
        let evidence = XCTAttachment(string: (["checked=\(checked) clipped=\(clipped) widestSpill=\(widestSpill)"] + violations).joined(separator: "\n"))
        evidence.name = "Week visible event accessibility bounds"
        evidence.lifetime = .keepAlways
        add(evidence)
        XCTAssertLessThanOrEqual(widestSpill, 1, "The exposed event must end at its visible cell boundary")
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
        let didCommit = failure.waitForExistence(timeout: 5)
        if !didCommit {
            let evidence = XCTAttachment(string: "target=\(title) frame=\(original) viewport=\(viewport.frame)\n\(viewport.value ?? "missing")")
            evidence.name = "Week event press and recognizer outcome"
            evidence.lifetime = .keepAlways
            add(evidence)
        }
        XCTAssertTrue(didCommit, "Week drag must commit through the provider boundary")
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
        app.buttons["sheet.close"].tap()
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

    func testNativeDayParentMoveControl() { checkDayMoveFailure(parentFeedback: true) }
    func testNativeDayParentLongMoveControl() { checkDayMoveFailure(beyondViewport: true, parentFeedback: true) }
    func testNativeDayMoveRecovery() { checkDayMoveFailure(recovery: true) }
    func testNativeDayMoveFailure() { checkDayMoveFailure() }
    func testNativeDayMoveBeyondViewport() { checkDayMoveFailure(beyondViewport: true) }
    func testNativeDayExclusiveMoveControl() { checkDayMoveFailure(exclusive: true) }
    func testNativeDaySwiftUIMoveControl() { checkDayMoveFailure(swiftUIControl: true) }

    private func checkDayMoveFailure(swiftUIControl: Bool = false, beyondViewport: Bool = false,
                                     exclusive: Bool = false, parentFeedback: Bool = false, recovery: Bool = false) {
        // Start at noon. The synthetic 12:10 meeting and its drag destination must both
        // fit on screen, including when the landscape grid shows only part of an hour.
        let app = launch("--plan", extra: ["-mobileDayScrollOffset", "672", "--calendar-native-move-audit",
                                         "--calendar-move-render-probe"]
                         + (swiftUIControl ? ["--calendar-swiftui-day-move"] : [])
                         + (exclusive ? ["--calendar-move-exclusive"] : [])
                         + (parentFeedback ? ["--calendar-parent-move-feedback"] : [])
                         + (recovery ? ["--calendar-recovery-fixture", UUID().uuidString] : []))
        app.segmentedControls.buttons["Day"].tap()
        let viewport = app.collectionViews.firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 10))
        let event = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Stress event 73,")).firstMatch
        XCTAssertTrue(event.waitForExistence(timeout: 10))
        XCTAssertTrue(event.isHittable)
        let originalFrame = event.frame
        let hour = app.staticTexts["12 PM"].firstMatch
        let control = swiftUIControl || exclusive
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
        if swiftUIControl {
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
        capture("native-day-move-failure")
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
            app.buttons["sheet.close"].tap()
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
            app.buttons["sheet.close"].tap()
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
        app.buttons["sheet.close"].tap()
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
        XCTAssertTrue(app.collectionViews.firstMatch.waitForExistence(timeout: 10),
                      "The calendar must install the native viewport without an opt-in flag")
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
            app.buttons["sheet.close"].tap()
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
        app.buttons["sheet.close"].tap()
    }
}
