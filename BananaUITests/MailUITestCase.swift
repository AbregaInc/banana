import XCTest

/// What every Mail UI test shares: launching onto the sample mail, finding rows and controls by
/// their identifiers (never by position), the swipes a thumb makes, the toast, backgrounding, and
/// screenshots that are attached to the test and also written to disk, so that a person can look
/// at them — a test can pass while the screen is visibly wrong.
///
/// Every launch is `--mail --disable-icloud --mail-fresh`: a route outside `VisualAuditRoute`
/// starts the production graph and crashes an unsigned Simulator build, and `--mail-fresh` keeps
/// one run's scheduled messages out of the next.
class MailUITestCase: XCTestCase {
    var app: XCUIApplication!

    /// Where screenshots go as files, beside the bug list. `MAIL_SHOTS` in the test's environment
    /// names the folder; without it they go under the temporary directory.
    static let shotsDirectory: URL = {
        let base = ProcessInfo.processInfo.environment["MAIL_SHOTS"]
            ?? "/private/tmp/claude-501/-Users-owner-orca-workspaces-gtfuwgth-stingray/a2258f59-13ec-4139-b1e4-fd8203198777/scratchpad/uitest/shots"
        return URL(fileURLWithPath: base, isDirectory: true)
    }()

    // MARK: The device

    var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    /// "iphone", "ipad-portrait" or "ipad-landscape": the arrangement the screen has.
    var deviceTag: String {
        guard isPad else { return "iphone" }
        return XCUIDevice.shared.orientation.isLandscape ? "ipad-landscape" : "ipad-portrait"
    }

    /// Whether the screen has a reading pane: a tap on a row then places the cursor and does not
    /// open, and a reply is a card in the pane rather than a sheet. True on the iPad in both
    /// orientations (1032 and 1376 points are both past the pane's 660).
    var hasPane: Bool { isPad }

    // MARK: Launching

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
        try? FileManager.default.createDirectory(at: Self.shotsDirectory, withIntermediateDirectories: true)
    }

    /// Leaves the iPad the way the run starts every test — not always upright. Turning it upright
    /// after each test and on its side again at the next launch put two turns into the simulator's
    /// queue per test, and on a loaded machine the later one often landed after the launch (or in
    /// the middle of the test): half of a "landscape" run was shot upright.
    override func tearDown() {
        if isPad { MailTurn.ask(landscape: MailTurn.startsOnItsSide) }
        super.tearDown()
    }

    /// Launches onto the sample mail. `open` is a fixture key for `--mail-open`; `state` a
    /// `--mail-state`; `landscape` turns the iPad before the launch.
    @discardableResult
    func launch(open: String? = nil, cursor: String? = nil, state: String? = nil, place: String? = nil,
                landscape: Bool? = nil, extra: [String] = [], waitForList: Bool = true) -> XCUIApplication {
        // `MAIL_LANDSCAPE=1` in the runner's environment (`TEST_RUNNER_MAIL_LANDSCAPE=1` to
        // xcodebuild) runs every journey with the iPad on its side, where Mail has four columns.
        let onItsSide = landscape ?? MailTurn.startsOnItsSide
        if isPad {
            MailTurn.ask(landscape: onItsSide)
        } else {
            // Phone journeys below expect a full-width conversation. A previous class may
            // have rotated this reused worker; declare the layout instead of inheriting it.
            XCUIDevice.shared.orientation = onItsSide ? .landscapeLeft : .portrait
        }
        app = XCUIApplication()
        var arguments = ["--mail", "--disable-icloud", "--mail-fresh", "-onboardingCompleted", "YES"]
        if let place { arguments += ["--mail-place", place] }
        if let cursor { arguments += ["--mail-cursor", cursor] }
        if let open { arguments += ["--mail-open", open] }
        if let state { arguments += ["--mail-state", state] }
        app.launchArguments = arguments + extra
        app.launch()
        if isPad {
            XCTAssertTrue(MailTurn.settle(app, landscape: onItsSide),
                          "the requested iPad orientation must be exercised")
        }
        if waitForList {
            XCTAssertTrue(element(MailID.list).waitForExistence(timeout: 30), "the list came up\n\(app.debugDescription)")
        }
        return app
    }

    // MARK: Finding things

    /// Any element with this identifier, whatever its type. Where there are several — on an iPad
    /// the reading pane's controls sit under a conversation open full width — the one that can be
    /// tapped, when one can.
    func element(_ identifier: String) -> XCUIElement {
        // A conversation open full width covers the pane; its own controls come first. (The
        // covered pane's buttons still answer a hit test where the screen over them is empty.)
        if identifier != MailID.conversation {
            let screen = app.descendants(matching: .any)[MailID.conversation]
            if screen.exists {
                let inside = screen.descendants(matching: .any)[identifier]
                if inside.exists { return inside.firstMatch }
            }
        }
        let all = app.descendants(matching: .any).matching(identifier: identifier).allElementsBoundByIndex
        if all.count > 1, let hittable = all.first(where: { $0.isHittable }) { return hittable }
        return app.descendants(matching: .any)[identifier].firstMatch
    }

    func button(_ identifier: String) -> XCUIElement { app.buttons[identifier].firstMatch }

    func row(_ key: String) -> XCUIElement { element(MailID.row(key)) }

    /// Scrolls the list in half-screen steps until the row is on screen: down the list, and back
    /// up if it was passed. True when it is.
    @discardableResult
    func scrollToRow(_ key: String, steps: Int = 24) -> Bool {
        if row(key).exists && row(key).isHittable { return true }
        let list = element(MailID.list)
        func step(_ down: Bool) {
            let from = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.75 : 0.25))
            let to = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.25 : 0.75))
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .default, thenHoldForDuration: 0.3)
        }
        for _ in 0..<steps {
            step(true)
            if row(key).exists && row(key).isHittable { return true }
        }
        for _ in 0..<steps {
            step(false)
            if row(key).exists && row(key).isHittable { return true }
        }
        return false
    }

    /// The keys of the rows on screen, top to bottom.
    func visibleRowKeys() -> [String] {
        let prefix = MailID.list + ".row."
        // One immutable snapshot avoids resolving every row repeatedly while Done animates.
        guard let list = try? element(MailID.list).snapshot() else { return [] }
        var found: [String: CGFloat] = [:]
        func visit(_ seen: XCUIElementSnapshot) {
            let frame = seen.frame
            if seen.identifier.hasPrefix(prefix), frame.height > 0,
               frame.minY >= list.frame.minY - 1, frame.maxY <= list.frame.maxY + 1 {
                found[String(seen.identifier.dropFirst(prefix.count))] = frame.minY
            }
            for child in seen.children { visit(child) }
        }
        visit(list)
        return found.sorted { $0.value < $1.value }.map(\.key)
    }

    /// The count the list's header shows beside the place's name, or nil when there is none.
    func headerCount() -> Int? {
        let list = element(MailID.list).frame
        // Each text is read through a snapshot taken once: a text that leaves while the list is
        // still animating (right after a Done) is skipped. Reading `frame` and `label` off the
        // element would resolve it again each time and fail the test when it had gone.
        for text in app.staticTexts.allElementsBoundByIndex {
            guard let seen = try? text.snapshot() else { continue }
            let frame = seen.frame
            guard frame.maxY <= list.minY + 1, frame.minY > list.minY - 60, frame.minX < list.midX else { continue }
            let digits = seen.label.replacingOccurrences(of: ",", with: "")
            if let number = Int(digits) { return number }
        }
        return nil
    }

    /// Text the open conversation or the pane shows, scrolling down a few screens for it when it
    /// is below the fold.
    func conversationShows(_ text: String, timeout: TimeInterval = 5) -> Bool {
        let match = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        if match.waitForExistence(timeout: timeout) { return true }
        for _ in 0..<3 {
            app.swipeUp()
            if match.waitForExistence(timeout: 1) { return true }
        }
        return false
    }

    // MARK: The composer

    var composer: XCUIElement { element(MailID.composer) }
    var bodyText: String { (body.value as? String) ?? "" }
    var toField: XCUIElement { app.textFields[MailID.composerTo].firstMatch }
    var subjectField: XCUIElement { app.textFields[MailID.composerSubject].firstMatch }
    func chip(_ address: String) -> XCUIElement { element(MailID.chip(address)) }

    /// Opens the reply menu of whatever is showing and picks one of its three.
    func reply(_ title: String) {
        let menu = element(MailID.replyMenu)
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "the reply menu\n\(app.debugDescription)")
        menu.tap()
        let item = menuItem(title)
        XCTAssertTrue(item.waitForExistence(timeout: 3), "\(title) in the menu")
        item.tap()
        XCTAssertTrue(body.waitForExistence(timeout: 10), "the composer came up\n\(app.debugDescription)")
    }

    /// Types into the body, tapping it first so the caret is there.
    func typeIntoBody(_ text: String) {
        XCTAssertTrue(body.waitForExistence(timeout: 10), "the body")
        body.tap()
        Thread.sleep(forTimeInterval: 0.4)
        body.typeText(text)
    }

    /// Leaves the composer the way a finger does, keeping the draft: on a phone the sheet is
    /// dragged down; with a card, Back closes the conversation and the composer with it.
    func leaveComposerKeepingDraft() {
        if hasPane {
            if element(MailID.back).exists {
                element(MailID.back).tap()
            } else {
                // A card in the pane: moving the cursor to another row leaves it (the draft is kept).
                let keys = visibleRowKeys()
                if keys.count > 1 { row(keys[1]).tap() }
            }
        } else {
            let top = composer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02))
            let bottom = top.withOffset(CGVector(dx: 0, dy: 900))
            top.press(forDuration: 0.1, thenDragTo: bottom)
        }
        _ = waitGone(body, timeout: 5)
    }

    func exists(_ identifier: String, within timeout: TimeInterval = 5) -> Bool {
        element(identifier).waitForExistence(timeout: timeout)
    }

    /// Waits until an element is gone. True if it went within the timeout.
    @discardableResult
    func waitGone(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        if !element.exists { return true }
        let gone = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: gone, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// An item of a menu that has just been opened: SwiftUI's menus show their items as buttons
    /// with no identifier of their own — never one of Mail's controls, whose label may be the
    /// same word ("Reply" names the menu's button too).
    func menuItem(_ title: String) -> XCUIElement {
        let items = app.buttons.matching(NSPredicate(format: "label == %@ AND NOT (identifier BEGINSWITH 'mail.')", title))
        let button = items.firstMatch
        if button.waitForExistence(timeout: 3) { return button }
        let item = app.menuItems[title].firstMatch
        if item.exists { return item }
        return app.staticTexts[title].firstMatch
    }

    var body: XCUIElement {
        let all = app.textViews.matching(identifier: MailID.composerBody).allElementsBoundByIndex
        if all.count > 1, let hittable = all.first(where: { $0.isHittable }) { return hittable }
        return app.textViews[MailID.composerBody].firstMatch
    }

    /// The toast's line, if one is showing.
    var toastText: String? {
        let undo = app.buttons["toast.undo"].firstMatch
        let dismiss = app.buttons["Dismiss"].firstMatch
        guard undo.exists || dismiss.exists else { return nil }
        // The toast is an HStack: its text is the static text nearest the Dismiss button.
        let texts = app.staticTexts.allElementsBoundByIndex
        let anchor = (undo.exists ? undo : dismiss).frame
        return texts.first { abs($0.frame.midY - anchor.midY) < 4 && $0.frame.maxX <= anchor.minX + 1 }?.label
    }

    func waitForToast(containing text: String, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        return app.staticTexts.matching(predicate).firstMatch.waitForExistence(timeout: timeout)
    }

    /// The toast's Undo. With a composer sheet up the toast is drawn twice — in the section under
    /// the sheet and on the sheet — and only the sheet's can be tapped: that one.
    var undoButton: XCUIElement {
        let all = app.buttons.matching(identifier: "toast.undo").allElementsBoundByIndex
        return all.first { $0.isHittable } ?? app.buttons["toast.undo"].firstMatch
    }

    // MARK: Places

    /// Shows a place: by the control column where there is one, by the header's menu where not.
    /// A conversation open full width is closed first: the places are behind it.
    func show(place title: String) {
        if element(MailID.back).exists {
            element(MailID.back).tap()
            _ = waitGone(element(MailID.back), timeout: 3)
        }
        if element(MailID.control).exists {
            element(MailID.place(title)).tap()
        } else {
            element(MailID.placeMenu).tap()
            menuItem(title).tap()
        }
    }

    // MARK: Turning the iPad

    /// Turns the iPad while the app is up, and waits until the screen has followed.
    func turn(toLandscape landscape: Bool) {
        MailTurn.ask(landscape: landscape)
        XCTAssertTrue(MailTurn.settle(app, landscape: landscape), "the iPad must complete the turn")
        Thread.sleep(forTimeInterval: 0.5)
    }

    // MARK: Touch

    /// A full swipe from the trailing edge: Done, in one motion (MAIL-UX 6.1.6, T40). A synthetic
    /// swipe that lands while the row above is still animating out is sometimes lost by the
    /// collection view (it revealed nothing, not even the Done button); one more is made then.
    ///
    /// `staysInPlace` is for a row that a Done does not take away — a starred conversation in
    /// Starred (T16): the swipe is known to have taken by the toast that names Done, not by the
    /// row leaving. (Waiting for it to leave there swipes a second time at a conversation already
    /// done, and by then the first toast has gone.)
    @discardableResult
    func fullSwipeDone(_ row: XCUIElement, staysInPlace: Bool = false) -> Bool {
        let identifier = row.identifier
        for attempt in 0..<2 {
            guard row.exists else { return true }
            // Freeze the measured endpoints before dragging. Row-relative coordinates resolve
            // the entire row hierarchy repeatedly while the finger is already moving.
            let frame = row.frame, appOrigin = app.frame.origin
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: frame.minX + frame.width * 0.92 - appOrigin.x,
                                                  dy: frame.midY - appOrigin.y))
            let end = origin.withOffset(CGVector(dx: frame.minX - frame.width * 0.7 - appOrigin.x,
                                                dy: frame.midY - appOrigin.y))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0.05)
            let took = staysInPlace ? waitForToast(containing: "Done", timeout: 3) : waitGone(row, timeout: 3)
            if took || !row.exists { return true }
            if app.buttons["Done"].firstMatch.exists { return false }
            if attempt == 0 { note("a full swipe on \(identifier) was lost (nothing revealed); swiping again") }
        }
        return false
    }

    /// A short swipe from the trailing edge: reveals Done without committing.
    func shortSwipeTrailing(_ row: XCUIElement) {
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        let end = row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .default, thenHoldForDuration: 0.05)
    }

    /// A short swipe from the leading edge: reveals Read/Unread and Star.
    func shortSwipeLeading(_ row: XCUIElement) {
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5))
        let end = row.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .default, thenHoldForDuration: 0.05)
    }

    /// Opens a conversation the way a finger does: a tap, and where there is a pane, the expand
    /// button after it (a tap only places the cursor there, T49).
    func openConversation(_ key: String) {
        row(key).tap()
        if hasPane {
            let expand = element(MailID.expand)
            XCTAssertTrue(expand.waitForExistence(timeout: 5), "the pane's expand button")
            expand.tap()
        }
        XCTAssertTrue(element(MailID.conversation).waitForExistence(timeout: 5), "the conversation opened\n\(app.debugDescription)")
    }

    /// Sends the app to the background for `seconds` and brings it back.
    func background(for seconds: TimeInterval) {
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: seconds)
        app.activate()
        _ = app.wait(for: .runningForeground, timeout: 10)
        Thread.sleep(forTimeInterval: 0.8)
    }

    /// Scrolls the open conversation until the scheduled message's card is on screen, whose
    /// buttons are made only when it is (a lazy grid). True when it is.
    @discardableResult
    func revealScheduledBanner() -> Bool {
        let banner = element(MailID.scheduledBanner)
        for _ in 0..<8 {
            if banner.exists && banner.isHittable && element(MailID.scheduledSendNow).exists { return true }
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.4)
        }
        return banner.exists && element(MailID.scheduledSendNow).exists
    }

    /// Dismisses the keyboard, if one is up, without pressing anything that acts.
    func hideKeyboard() {
        let hide = app.keyboards.buttons["Hide keyboard"].firstMatch
        if hide.exists { hide.tap(); return }
        let done = app.toolbars.buttons["Done"].firstMatch
        if done.exists { done.tap() }
    }

    // MARK: Screenshots

    /// A screenshot, attached to the test and written to disk as `<test>-<step>-<device>.png`.
    @discardableResult
    func snap(_ step: String) -> URL? {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "\(step)-\(deviceTag)"
        attachment.lifetime = .keepAlways
        add(attachment)
        let testName = name.split(separator: " ").last.map { $0.replacingOccurrences(of: "]", with: "") } ?? "test"
        let file = Self.shotsDirectory.appendingPathComponent("\(testName)-\(step)-\(deviceTag).png")
        do {
            try shot.pngRepresentation.write(to: file, options: .atomic)
            return file
        } catch {
            return nil
        }
    }

    /// A finding: recorded in the test's output and the attachment, without failing the run.
    func note(_ text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = "note-\(deviceTag)"
        attachment.lifetime = .keepAlways
        add(attachment)
        NSLog("MAIL-UI-NOTE [%@] %@", deviceTag, text)
    }
}

/// Turning the iPad, and knowing that it has turned. `XCUIDevice.shared.orientation = …` returns
/// at once; the screen follows later, and on a loaded machine much later or not at all (the device
/// reports landscape while the app stays upright), and asking for the orientation the device
/// already reports does nothing. So a turn is asked for only when the device is not in the
/// arrangement, and the app's own window is looked at: its shape is the fact.
enum MailTurn {
    /// `MAIL_LANDSCAPE=1` in the runner's environment (`TEST_RUNNER_MAIL_LANDSCAPE=1` to
    /// xcodebuild): every test starts with the iPad on its side, where Mail has four columns.
    static var startsOnItsSide: Bool { ProcessInfo.processInfo.environment["MAIL_LANDSCAPE"] == "1" }

    /// Asks for the arrangement, unless the device already reports it.
    static func ask(landscape: Bool) {
        let device = XCUIDevice.shared
        let already = landscape ? device.orientation.isLandscape : device.orientation == .portrait
        if !already { device.orientation = landscape ? .landscapeLeft : .portrait }
    }

    /// How many times a turn has not come. A simulator that has stopped turning (a long-lived one
    /// does) is not waited for at every launch: after three, `settle` only looks.
    private nonisolated(unsafe) static var misses = 0

    /// Waits, with the app up, until its window has the shape asked for. When the screen has not
    /// followed the device, turns it the other way and back and waits again. False if it never does.
    static func settle(_ app: XCUIApplication, landscape: Bool, timeout: TimeInterval = 10) -> Bool {
        func shapeIsRight() -> Bool {
            let frame = app.windows.firstMatch.frame
            return frame.width > 0 && (frame.width > frame.height) == landscape
        }
        if misses >= 3 { return shapeIsRight() }
        defer { if !shapeIsRight() { misses += 1 } }
        for attempt in 0..<2 {
            let end = Date().addingTimeInterval(timeout)
            while Date() < end {
                if shapeIsRight() { return true }
                Thread.sleep(forTimeInterval: 0.5)
            }
            if attempt == 0 {
                XCUIDevice.shared.orientation = landscape ? .portrait : .landscapeLeft
                Thread.sleep(forTimeInterval: 2)
                XCUIDevice.shared.orientation = landscape ? .landscapeLeft : .portrait
            }
        }
        return false
    }
}
