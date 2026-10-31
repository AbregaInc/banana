import XCTest
import UIKit

/// The first run, tap by tap, as a new person meets it, and the rules it now keeps: nothing is
/// asked for before it is explained, the way forward is a full-size button, the setup list is
/// reachable with or without a calendar, and what was refused is not called connected.
///
/// `ONBOARDING_SHOTS=<folder>` (as `TEST_RUNNER_ONBOARDING_SHOTS` to xcodebuild) keeps each step
/// there: a picture of the whole screen, system prompts included, and a text file with the words
/// and the size of everything that can be tapped. Start from an erased simulator
/// (`simctl erase <sim>`): a granted permission takes its screens away, the setup line stays
/// hidden once a walk has hidden it, and a simulator that has had the app removed and put back a
/// few times stops recording the answer to its location question.
///
/// Google's sign-in page is left alone. It is Banana's real sign-in, and a walk has no business
/// opening it by itself; with `ONBOARDING_GOOGLE=1`, and only when asked to, the walk opens the
/// page and closes it again without signing in.
final class OnboardingWalkUITest: XCTestCase {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "phone"
    private var walk = ""
    private var step = 0

    override func setUp() {
        continueAfterFailure = true   // a missing step is a finding; the rest is still wanted
        // A prompt the walk before this one asked for, that the system showed late (this Mac is
        // often compiling for other work): it would read here as one nobody asked for.
        while springboard.alerts.firstMatch.exists {
            let buttons = springboard.alerts.firstMatch.buttons
            buttons.element(boundBy: buttons.count - 1).tap()
            pause(1)
        }
    }

    private var folder: URL? {
        ProcessInfo.processInfo.environment["ONBOARDING_SHOTS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    // MARK: - Keeping what each step shows

    private func keep(_ app: XCUIApplication, _ name: String) {
        step += 1
        let title = String(format: "%@-%@-%02d-%@", device, walk, step, name)
        let shot = XCUIScreen.main.screenshot()
        guard let folder else {
            let attachment = XCTAttachment(screenshot: shot)
            attachment.name = title
            attachment.lifetime = .keepAlways
            add(attachment)
            return
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: folder.appendingPathComponent(title + ".png"))
        var lines = ["", "== \(title)"]
        if springboard.alerts.firstMatch.exists, let alert = try? springboard.alerts.firstMatch.snapshot() {
            lines.append("  SYSTEM PROMPT")
            collect(alert, into: &lines, indent: "    ")
        }
        if let tree = try? app.snapshot() { collect(tree, into: &lines, indent: "  ") }
        say(lines.joined(separator: "\n"))
    }

    /// The step after a first sign-in, which a simulator can't reach (it has no Google account):
    /// shown with one made-up account, then two. One account asks for the other; two offer the
    /// yes to busy blocks, and that yes opens the plan.
    func test3TheOtherCalendar() {
        walk = "other"
        let app = XCUIApplication()
        app.launchArguments = ["--disable-icloud", "--no-space-sync", "-onboardingCompleted", "NO", "--onboarding-other-calendar-preview"]
        app.withoutSpaceSync()
        app.launch()
        let add = app.buttons["onboarding.other.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 25), "the other-calendar step did not come")
        pause(1)
        keep(app, "one-account")
        XCTAssertTrue(app.staticTexts["Add your other calendar"].exists)
        XCTAssertTrue(app.buttons["google.continue"].exists, "one account in, and no button to add the other")
        XCTAssertFalse(app.buttons["onboarding.blockBusy"].exists, "busy blocks offered with one account")
        assertFullSize(add, "the row that adds an account")
        assertFullSize(app.buttons["onboarding.notNow"], "Not now")
        app.terminate()

        app.launchArguments = ["--disable-icloud", "--no-space-sync", "-onboardingCompleted", "NO", "--onboarding-two-calendars-preview"]
        app.withoutSpaceSync()
        app.launch()
        let block = app.buttons["onboarding.blockBusy"]
        XCTAssertTrue(block.waitForExistence(timeout: 25), "two accounts in, and no yes to busy blocks")
        pause(1)
        keep(app, "two-accounts")
        XCTAssertFalse(app.buttons["google.continue"].exists)
        assertFullSize(block, "Block busy time")
        block.tap()
        XCTAssertTrue(app.buttons["plan.calendar.connect"].waitForExistence(timeout: 15), "the yes did not open the plan")
    }

    private func say(_ text: String) {
        guard let folder else { return }
        let file = folder.appendingPathComponent("\(device)-\(walk)-walk.txt")
        let data = Data((text + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else {
            try? data.write(to: file)
        }
    }

    /// The words on screen and everything that takes a tap, with its size in points.
    private func collect(_ element: XCUIElementSnapshot, into lines: inout [String], indent: String) {
        let frame = element.frame
        let label = element.label.replacingOccurrences(of: "\n", with: " / ")
        let size = "\(Int(frame.width))x\(Int(frame.height))"
        switch element.elementType {
        case .staticText where !label.isEmpty:
            lines.append("\(indent)text    \(label)")
        case .button where !label.isEmpty || !element.identifier.isEmpty:
            lines.append("\(indent)button  \(label.isEmpty ? "(\(element.identifier))" : label)  [\(size)]\(element.isEnabled ? "" : " off")")
        case .switch, .toggle:
            lines.append("\(indent)switch  \(label) = \(element.value as? String ?? "?")  [\(size)]")
        case .link where !label.isEmpty:
            lines.append("\(indent)link    \(label)  [\(size)]")
        case .textField, .secureTextField, .searchField:
            lines.append("\(indent)field   \(label.isEmpty ? (element.placeholderValue ?? "") : label)  [\(size)]")
        default:
            break
        }
        for child in element.children { collect(child, into: &lines, indent: indent) }
    }

    private func pause(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }

    /// Apple's minimum for anything tapped. The way forward used to be 20 points tall.
    private func assertFullSize(_ element: XCUIElement, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        guard element.exists else { return XCTFail("\(name) isn't there", file: file, line: line) }
        // A layout lands a hair under now and then (43.99999…): half a point of grace.
        XCTAssertGreaterThanOrEqual(element.frame.height, 43.5, "\(name) is \(Int(element.frame.height)) points tall", file: file, line: line)
        XCTAssertGreaterThanOrEqual(element.frame.width, 43.5, "\(name) is \(Int(element.frame.width)) points wide", file: file, line: line)
    }

    private func text(containing words: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", words)).firstMatch
    }

    /// The small day on the first run's question pages, found by what it reads out.
    private func day(saying words: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Your day:' AND label CONTAINS %@", words)).firstMatch
    }

    /// Answer the system's prompt that a tap just asked for.
    @discardableResult
    private func answerPrompt(allow: Bool, _ app: XCUIApplication, at place: String) -> Bool {
        // Up to half a minute: the prompt is another process's, and late when the Mac is busy.
        guard springboard.alerts.firstMatch.waitForExistence(timeout: 30) else { return false }
        keep(app, "\(place)-the-systems-question")
        let buttons = springboard.alerts.firstMatch.buttons
        let wanted = buttons.matching(NSPredicate(format: allow ? "label BEGINSWITH 'Allow While' OR label == 'Allow' OR label == 'OK' OR label == 'Continue'"
                                                                : "label BEGINSWITH 'Don' OR label == 'Cancel'")).firstMatch
        (wanted.exists ? wanted : buttons.element(boundBy: buttons.count - 1)).tap()
        pause(1.2)
        return true
    }

    /// The sign-in sheet's own way out: its identifier is "Close", its label "Cancel".
    private static let googleSheetClose = NSPredicate(format: "identifier == 'Close' OR label == 'Cancel'")

    private func cancelGoogleSheet(_ app: XCUIApplication) -> Bool {
        let safari = XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")
        for host in [app, safari, springboard] {
            let cancel = host.buttons.matching(Self.googleSheetClose).firstMatch
            if cancel.waitForExistence(timeout: 3) { cancel.tap(); return true }
        }
        return false
    }

    /// Open Google's page from a "Continue with Google" button, look, and close it.
    private func openAndCancelGoogle(_ app: XCUIApplication, at place: String) {
        let tapped = Date()
        let sheet = app.buttons.matching(Self.googleSheetClose).firstMatch
        var systemAsked = false
        while Date().timeIntervalSince(tapped) < 45, !sheet.exists {
            if springboard.alerts.firstMatch.exists {
                systemAsked = true
                keep(app, "\(place)-the-systems-question")
                springboard.alerts.firstMatch.buttons["Continue"].tap()
            }
            pause(0.4)
        }
        say(String(format: "Google's page was there %.1f s after the tap; the system asked first: %@",
                   Date().timeIntervalSince(tapped), systemAsked ? "yes" : "no"))
        XCTAssertTrue(sheet.exists, "Google's page never came")
        pause(2.5)   // the page itself loads over the network
        keep(app, "\(place)-googles-page")
        XCTAssertTrue(cancelGoogleSheet(app), "Google's sheet had no Cancel the test could find")
        pause(1.5)
    }

    // MARK: - The walks

    /// A fresh install: the welcome, the calendar step, into the app, then the setup list with
    /// one permission refused, one allowed and Health declined.
    func test1TheFirstRunTapByTap() throws {
        // The whole first run, tap by tap, then every tab: longer than an ordinary test.
        executionTimeAllowance = 300
        walk = "first"
        let app = XCUIApplication()
        // Other UI tests may have stored an existing user's module choice. This walk
        // starts with Plan alone; its taps can still change the choice in memory.
        app.launchArguments = ["--disable-icloud", "--no-space-sync", "--modules", "plan",
                               "-onboardingCompleted", "NO", "-finishSetupDismissed", "NO",
                               "-remindersAskedNotAllowed", "NO"]
        app.withoutSpaceSync()
        app.launch()

        XCTAssertTrue(text(containing: "What should Banana look after?", in: app).waitForExistence(timeout: 25), "no welcome")
        XCTAssertFalse(springboard.alerts.firstMatch.exists, "a system prompt before anything was explained")
        keep(app, "welcome")

        let go = app.buttons["onboarding.continue"]
        assertFullSize(go, "Get started")
        // What Banana looks after is picked here (17 Oct 2026): Plan always, the rest ticked or
        // not, and Everything for all of it. Still one way on.
        XCTAssertTrue(text(containing: "Plan your day", in: app).exists, "the welcome doesn't mention the plan")
        let modules = ["workouts", "food", "notes", "podcasts"].map { app.buttons["onboarding.module.\($0)"] }
        let everything = app.buttons["onboarding.module.everything"]
        for row in modules + [everything] {
            XCTAssertTrue(row.exists, "the welcome is missing \(row.identifier)")
            XCTAssertFalse(row.isSelected, "a new install starts with more than the plan")
            XCTAssertFalse(row.label.contains("Beta"))
            XCTAssertFalse(row.label.contains("Coming soon"))
        }
        XCTAssertFalse(app.buttons["onboarding.module.email"].exists)
        // The public sample-data entry adds one visible action to the welcome page.
        XCTAssertLessThanOrEqual(app.staticTexts.count, 10, "the welcome has grown more to read")
        // On an iPad the phone's layout ran edge to edge: a button a thousand points wide.
        XCTAssertLessThanOrEqual(go.frame.width, 560, "the page isn't kept to a reading width")

        // One ticks on and off; Everything ticks them all.
        modules[1].tap()
        XCTAssertTrue(modules[1].isSelected, "Food didn't tick")
        modules[1].tap()
        XCTAssertFalse(modules[1].isSelected, "Food didn't untick")
        everything.tap()
        XCTAssertTrue(everything.isSelected && modules.allSatisfy(\.isSelected), "Everything didn't tick them all")
        keep(app, "welcome-everything")

        // The one path. First, two questions, each of which moves a block on the day above it.
        go.tap()
        XCTAssertTrue(text(containing: "When do you wake up?", in: app).waitForExistence(timeout: 6), "the wake question did not come")
        pause(0.6)
        keep(app, "wake-question")
        assertFullSize(go, "Continue")
        assertFullSize(app.buttons["Back"], "Back")
        XCTAssertTrue(day(saying: "wake at 6:30", in: app).exists, "the day doesn't start where the Wake routine is")
        if device == "phone" {
            // Turn the wheel: the day above follows it.
            app.pickerWheels.element(boundBy: 0).adjust(toPickerWheelValue: "7")
            XCTAssertTrue(day(saying: "wake at 7:30", in: app).waitForExistence(timeout: 4), "the answer didn't move the day's start")
            keep(app, "wake-answered")
        }
        XCTAssertEqual(app.buttons.count, 2, "a question offers more than Back and Continue")

        go.tap()
        XCTAssertTrue(text(containing: "When do you wind down?", in: app).waitForExistence(timeout: 6), "the wind-down question did not come")
        pause(0.6)
        if device == "phone" {
            app.pickerWheels.element(boundBy: 0).adjust(toPickerWheelValue: "10")
            XCTAssertTrue(day(saying: "wind down at 10:00", in: app).waitForExistence(timeout: 4), "the answer didn't move the day's end")
        }
        keep(app, "wind-down-question")

        // Then the calendar, shown by what Banana does between two of them.
        go.tap()
        let google = app.buttons["google.continue"]
        XCTAssertTrue(google.waitForExistence(timeout: 6), "the calendar step did not come")
        let title = text(containing: "Never double-booked", in: app)
        XCTAssertTrue(title.exists)
        // Big titles sit in the middle of the page, over the button, not at its left edge.
        XCTAssertEqual(title.frame.midX, google.frame.midX, accuracy: 2, "the title isn't centred")
        // Before above the title, after below it.
        let before = app.descendants(matching: .any).matching(identifier: "onboarding.busyBefore").firstMatch
        let after = app.descendants(matching: .any).matching(identifier: "onboarding.busyPicture").firstMatch
        XCTAssertTrue(before.exists && after.exists, "the calendar step doesn't show busy blocks before and after")
        XCTAssertTrue(before.label.contains("Before") && after.label.contains("After"))
        XCTAssertLessThanOrEqual(before.frame.maxY, title.frame.minY, "the before picture isn't above the title")
        XCTAssertGreaterThanOrEqual(after.frame.minY, title.frame.maxY, "the after picture isn't below the title")
        XCTAssertLessThanOrEqual(after.frame.maxY, google.frame.minY, "the after picture runs under the button")
        pause(0.6)
        keep(app, "calendar-step")
        assertFullSize(google, "Continue with Google")
        assertFullSize(app.buttons["onboarding.notNow"], "Not now")
        assertFullSize(app.buttons["Back"], "Back")

        app.buttons["Back"].tap()
        XCTAssertTrue(text(containing: "When do you wind down?", in: app).waitForExistence(timeout: 4), "Back did not return to the question")
        go.tap()
        XCTAssertTrue(google.waitForExistence(timeout: 6))

        // Google's own page, only when asked for (see the note at the top). Closing it is not a
        // failure, and the step says nothing about one.
        if ProcessInfo.processInfo.environment["ONBOARDING_GOOGLE"] == "1" {
            google.tap()
            pause(1)
            keep(app, "a-second-after-continue-with-google")
            openAndCancelGoogle(app, at: "first-run")
            keep(app, "after-closing-googles-page")
            XCTAssertFalse(app.staticTexts["onboarding.calendar.problem"].exists, "closing the page was reported as a problem")
        }

        // Into the app. Nothing has been asked for, so the system asks nothing.
        app.buttons["onboarding.notNow"].tap()
        XCTAssertTrue(app.buttons["plan.calendar.connect"].waitForExistence(timeout: 10), "the plan did not open")
        pause(1)
        keep(app, "first-sight-of-the-app")
        XCTAssertFalse(springboard.alerts.firstMatch.waitForExistence(timeout: 6),
                       "the system asked for something nobody had asked Banana for")
        keep(app, "the-plan-once-settled")
        if device == "phone" {
            // The answers are on the plan: the day winds down when the person said.
            let windDown = try revealCalendarButton("Wind down", in: app)
            let clock = windDown.label.lowercased().replacingOccurrences(of: ":00", with: "")
                .filter { $0.isLetter || $0.isNumber }
            XCTAssertTrue(clock.contains("10pm"), "The visible wind-down must use the chosen 10 PM time: \(windDown.label)")
        }

        // With no calendar, the rest of setup is still one tap away.
        let rest = app.buttons["plan.setup.rest"]
        XCTAssertTrue(rest.waitForExistence(timeout: 4), "no way to the rest of setup without a calendar")
        assertFullSize(rest, "Set up the rest")
        assertFullSize(app.buttons["plan.calendar.connect"], "Connect")
        rest.tap()
        XCTAssertTrue(app.navigationBars["Set up Banana"].waitForExistence(timeout: 5), "the setup list did not open")
        pause(0.8)
        keep(app, "setup-list")
        let items = device == "ipad" ? ["calendar", "reminders", "notifications", "location", "music"]
                                     : ["calendar", "reminders", "alarms", "notifications", "location", "health", "music"]
        for item in items {
            XCTAssertTrue(app.buttons["setup.row.\(item)"].exists, "the list has no \(item) row")
        }
        XCTAssertTrue(text(containing: "0 of \(items.count) set up", in: app).exists, "a fresh install isn't 0 of \(items.count)")

        // Notifications: the page explains first. It is left unanswered here, so the plan's own
        // card can ask in the next walk; a no is shown on Reminders instead.
        app.buttons["setup.row.notifications"].tap()
        let allow = app.buttons["setup.primer.allow"]
        XCTAssertTrue(allow.waitForExistence(timeout: 4), "no explanation page for notifications")
        XCTAssertFalse(springboard.alerts.firstMatch.exists, "the system asked before the page's button was pressed")
        pause(0.6)
        keep(app, "notifications-explained")
        assertFullSize(allow, "Turn on notifications")
        assertFullSize(app.buttons["setup.primer.notNow"], "Not now")
        app.buttons["setup.primer.notNow"].tap()

        // Reminders, refused: the page then says how to change a no.
        XCTAssertTrue(app.buttons["setup.row.reminders"].waitForExistence(timeout: 4))
        app.buttons["setup.row.reminders"].tap()
        XCTAssertTrue(allow.waitForExistence(timeout: 4), "no explanation page for Reminders")
        pause(0.6)
        keep(app, "reminders-explained")
        allow.tap()
        XCTAssertTrue(answerPrompt(allow: false, app, at: "reminders"), "no system prompt for Reminders")
        XCTAssertTrue(app.buttons["setup.primer.settings"].waitForExistence(timeout: 12), "a refusal has no way to Settings")
        keep(app, "reminders-refused")
        app.navigationBars.buttons.firstMatch.tap()

        // Location, allowed: this is the first time the system is asked, and it was asked for.
        XCTAssertTrue(app.buttons["setup.row.location"].waitForExistence(timeout: 4))
        app.buttons["setup.row.location"].tap()
        XCTAssertTrue(allow.waitForExistence(timeout: 4), "no explanation page for location")
        pause(0.6)
        keep(app, "location-explained")
        allow.tap()
        XCTAssertTrue(answerPrompt(allow: true, app, at: "location"), "no system prompt for location")
        XCTAssertTrue(app.buttons["setup.row.location"].waitForExistence(timeout: 8), "allowing did not return to the list")
        pause(0.8)
        keep(app, "setup-list-after-two")
        XCTAssertTrue(text(containing: "1 of \(items.count) set up", in: app).exists, "an allowed item didn't count, or a refused one did")

        // Health, declined on Apple's sheet: asked, and not called connected.
        if device == "phone" {
            app.buttons["setup.row.health"].tap()
            XCTAssertTrue(allow.waitForExistence(timeout: 4), "no explanation page for Health")
            pause(0.6)
            keep(app, "health-explained")
            allow.tap()
            // Health's sheet belongs to another process. On a simulator just erased it can take
            // most of a minute to come the first time, and now and then longer than this waits.
            let hosts = [app, springboard, XCUIApplication(bundleIdentifier: "com.apple.Health")]
            let asked = Date()
            var sheet: XCUIElement?
            while sheet == nil, Date().timeIntervalSince(asked) < 75 {
                sheet = hosts.flatMap { [$0.buttons["Don\u{2019}t Allow"].firstMatch, $0.staticTexts["Don\u{2019}t Allow"].firstMatch] }
                    .first { $0.exists && $0.isHittable }
                if sheet == nil {
                    // iOS 27 puts the action at the bottom of Health's data-type table, exposed
                    // as text inside a cell. Scroll that actual sheet until its action is ready.
                    if let host = hosts.first(where: { $0.navigationBars["Health Access"].exists }),
                       host.tables.firstMatch.exists { host.tables.firstMatch.swipeUp() }
                    pause(0.5)
                }
            }
            say(String(format: "Health's sheet: %@ after %.1f s", sheet == nil ? "never came" : "there", Date().timeIntervalSince(asked)))
            keep(app, "healths-own-sheet")
            if let sheet {
                sheet.tap()
                pause(1.5)
                for host in hosts {
                    let ok = host.buttons["OK"].firstMatch
                    if ok.exists, ok.isHittable { ok.tap(); break }
                }
                XCTAssertTrue(app.buttons["setup.primer.health"].waitForExistence(timeout: 6), "a declined Health has no way to the Health app")
                keep(app, "health-declined")
                app.navigationBars.buttons.firstMatch.tap()
                XCTAssertTrue(app.buttons["setup.row.health"].waitForExistence(timeout: 4))
                pause(0.6)
                keep(app, "setup-list-after-health")
                XCTAssertTrue(text(containing: "1 of \(items.count) set up", in: app).exists, "declining Health counted as setting it up")
            } else {
                // The Simulator's Health never answered: nothing about Banana to judge. The rule
                // itself is `HealthAccess`, covered by SetupChecklistTests.
                // If its sheet comes late after all, it covers the app: decline it there.
                // Health may complete without a sheet on Simulator and pop its primer. Only
                // navigate back while that primer is still visible; a blind tap dismissed Setup.
                if app.navigationBars["Apple Health"].exists { app.navigationBars.buttons.firstMatch.tap() }
                let waited = Date()
                while !app.buttons["setup.row.health"].exists, Date().timeIntervalSince(waited) < 60 {
                    let late = hosts.flatMap { [$0.buttons["Don\u{2019}t Allow"].firstMatch, $0.staticTexts["Don\u{2019}t Allow"].firstMatch, $0.buttons["OK"].firstMatch] }
                        .first { $0.exists && $0.isHittable }
                    if let late { late.tap() } else if app.navigationBars["Apple Health"].exists {
                        app.navigationBars.buttons.firstMatch.tap()
                    } else if app.buttons["plan.setup.rest"].exists {
                        app.buttons["plan.setup.rest"].tap()
                    } else if app.buttons["plan.setup.open"].exists {
                        app.buttons["plan.setup.open"].tap()
                    }
                    pause(1)
                }
                XCTAssertTrue(app.buttons["setup.row.health"].waitForExistence(timeout: 4))
            }
        }

        // The calendar's row opens the same explanation the first run has.
        app.buttons["setup.row.calendar"].tap()
        XCTAssertTrue(app.buttons["google.continue"].waitForExistence(timeout: 4), "the calendar row has no explanation page")
        pause(0.5)
        keep(app, "calendar-from-the-list")
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["Done"].firstMatch.tap()
        pause(1)

        // Each tab, as it is the first time it is opened. None of them asks the system anything.
        let tabs = app.tabBars.buttons.allElementsBoundByIndex.map(\.label).filter { !$0.isEmpty }
        say("tabs: \(tabs)")
        // Not Add: it isn't a tab but the + beside them, and its sheet left covering Plan stopped
        // the walk from coming back.
        for name in tabs.dropFirst() where name != "Add" {
            let tab = app.tabBars.buttons[name].firstMatch
            guard tab.exists, tab.isHittable else { continue }
            tab.tap()
            pause(2)
            keep(app, "tab-\(name.lowercased().replacingOccurrences(of: " ", with: "-"))")
            XCTAssertFalse(springboard.alerts.firstMatch.exists, "\(name) asked the system for something by itself")
        }
        if let first = tabs.first { app.tabBars.buttons[first].firstMatch.tap(); pause(1) }

        // The plan's menu keeps the setup list within reach.
        let more = app.buttons["mobile.week.more"].firstMatch
        guard more.waitForExistence(timeout: 4), more.isHittable else { keep(app, "no-more-menu"); return }
        more.tap()
        pause(0.8)
        keep(app, "plan-menu")
        XCTAssertTrue(app.buttons["Finish setup"].firstMatch.waitForExistence(timeout: 3), "the plan's menu has no Finish setup")
    }

    /// With a calendar connected (the sample day stands in for one), what the plan asks, one
    /// card at a time, each from its own button: which calendars keep each other busy, then
    /// alerts with a sample made from the next meeting. Then the one line of setup: it opens the
    /// list, hiding it only hides the line, and the menu brings the list back.
    func test2WhatThePlanAsksAndTheSetupLine() {
        walk = "line"
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview", "--tab", "plan", "--plan", "-planMode", "day", "--store-capture",
                               "--disable-icloud", "--no-space-sync", "-onboardingCompleted", "YES", "--busy-question-preview"]
        app.withoutSpaceSync()
        app.launch()

        // Which calendars keep each other busy: a card on the plan, not a sheet in the way.
        let choose = app.buttons["plan.busy.allow"]
        XCTAssertTrue(choose.waitForExistence(timeout: 25), "the plan doesn't ask about busy calendars")
        XCTAssertFalse(app.buttons["calendars.continue"].exists, "the question opened by itself")
        XCTAssertFalse(springboard.alerts.firstMatch.waitForExistence(timeout: 4), "the system asked for something by itself")
        pause(1)
        keep(app, "plan-asks-about-calendars")
        assertFullSize(choose, "Choose")
        assertFullSize(app.buttons["plan.busy.later"], "Not now, on the busy card")
        choose.tap()
        let yes = app.buttons["calendars.continue"]
        XCTAssertTrue(yes.waitForExistence(timeout: 6), "Choose did not open the question")
        pause(1)
        keep(app, "busy-calendars-question")
        XCTAssertTrue(app.staticTexts["Keep your calendars in step"].exists)
        XCTAssertFalse(text(containing: "write availability", in: app).exists, "the app's own jargon is back")
        assertFullSize(yes, "Continue")
        yes.tap()
        XCTAssertTrue(choose.waitForNonExistence(timeout: 6), "answered, and the plan still asks")

        // Alerts, opened by the alert itself: the next meeting, in the words Banana would send.
        let turnOn = app.buttons["plan.notifications.allow"]
        // The card shows while a meeting is still ahead today (`NextAlertSample`). Once the sample
        // day's meetings have begun (by mid-morning), the plan goes straight on to the setup line.
        if !turnOn.waitForExistence(timeout: 8), app.buttons["plan.setup.open"].exists {
            XCTAssertTrue(app.buttons["plan.setup.open"].waitForExistence(timeout: 10),
                          "with no meeting ahead the plan goes on to the setup line\n\(app.debugDescription)")
            say("no meeting left today: the alerts card is not asked for")
        } else {
            XCTAssertTrue(turnOn.exists, "the plan doesn't ask about alerts\n\(app.debugDescription)")
            let sample = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'A sample notification.'")).firstMatch
            XCTAssertTrue(sample.exists, "the ask has no sample")
            say("alert sample: \(sample.label)")
            XCTAssertFalse(springboard.alerts.firstMatch.exists, "the system asked before the card's button was pressed")
            pause(0.6)
            keep(app, "plan-asks-about-alerts")
            assertFullSize(app.buttons["plan.notifications.later"], "Not now, on the alerts card")
            turnOn.tap()
            XCTAssertTrue(answerPrompt(allow: true, app, at: "alerts"), "no system prompt for alerts")
            XCTAssertTrue(turnOn.waitForNonExistence(timeout: 8), "allowed, and the plan still asks")
        }

        let line = app.buttons["plan.setup.open"]
        XCTAssertTrue(line.waitForExistence(timeout: 25), "the plan has no setup line (a fresh install is needed: an earlier walk hides it)")
        XCTAssertFalse(springboard.alerts.firstMatch.waitForExistence(timeout: 4), "the system asked for something by itself")
        pause(1)
        keep(app, "plan-with-the-setup-line")
        assertFullSize(line, "the setup line")
        let hide = app.buttons["plan.setup.hide"]
        assertFullSize(hide, "Hide setup")

        line.tap()
        XCTAssertTrue(app.navigationBars["Set up Banana"].waitForExistence(timeout: 5), "the line did not open the list")
        pause(0.8)
        keep(app, "setup-list")
        XCTAssertTrue(app.buttons["setup.row.calendar"].exists, "a finished row lost its place")
        app.buttons["Done"].firstMatch.tap()
        pause(0.8)

        hide.tap()
        pause(0.8)
        keep(app, "line-hidden")
        XCTAssertFalse(line.exists, "the line is still there")
        XCTAssertTrue(text(containing: "Setup is in the", in: app).exists, "hiding didn't say where setup went")

        app.buttons["mobile.week.more"].firstMatch.tap()
        let item = app.buttons["Finish setup"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 3), "hidden meant gone: the menu has no Finish setup")
        item.tap()
        XCTAssertTrue(app.navigationBars["Set up Banana"].waitForExistence(timeout: 5), "the menu did not open the list")
        pause(0.6)
        keep(app, "setup-list-from-the-menu")
    }
}
