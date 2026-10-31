import XCTest
import AppKit
import ApplicationServices

// The Mac's Mail, driven with real key presses, clicks and window drags.
//
// READ THIS BEFORE RUNNING ANYTHING. These cases launch Banana Beta on the owner's desktop and take
// his keyboard and mouse. Nobody runs them but `tools/mac-mail-uitest.sh`, which says so, waits for
// Return, and refuses to start if a Banana Beta is already running. Mail is in front of them for
// about fifteen minutes.
//
// What the cases hold the build to: `docs/design/MAIL-UX.md` section 4 (the key map, K1-K12) and
// section 3 (the triage rules), as far as the build has them. Where the build has less than the
// design, the case tests what the build says it does (`MailKeymap`, `MailKeyDispatch`) and the
// difference is listed here, so that a missing key is not a failing case:
//   - `?` and `/` do nothing in Mail (the design makes them the shortcut sheet and search);
//   - Tab / Shift-Tab do not change split; Cmd-Up / Cmd-Down, Space, X, Shift-J/K, Cmd-A, the filters,
//     the G prefix, # ! L V H and Cmd-F are not in the keymap;
//   - Cmd-R in Mail still jumps to Plan and refreshes the calendar (design 4.3: "Check Mail");
//   - Option-Cmd-S / P / I (the columns) are not built: `\` and `]` are the column keys;
//   - an unmapped letter is passed on, not swallowed (design K5).

// MARK: - What the suite may touch

enum MacMail {
    /// The installed Beta's bundle identifier, which the test app shares (`BananaMacBeta`).
    static let betaBundleID = "com.boris.banana.mac.beta"
    static let betaName = "Banana Beta"

    /// Every launch argument has a reason.
    ///
    /// `--ui-audit` is the Mac's own route that keeps the production graph from starting
    /// (BananaApp.swift: the Mac branch of `mainScene` uses `configuredPlatformRoot`, not
    /// `configuredRoot`, so `wireUp()` never runs; and it seeds `OccurrenceStore`'s preview, after
    /// which every recompute returns before `CalendarWriteBack.sync`). `--mail` is in
    /// `VisualAuditRoute.flags`, but that type is `#if DEBUG && os(iOS)`: on the Mac `--mail` does
    /// nothing at all, so it cannot be what keeps this launch safe. It is passed all the same.
    /// `--mac-section mail` lands on Mail (MacNavigator). `--disable-icloud` stops the CloudKit
    /// syncs that App.init starts. `--mail-fresh` gives Mail's sample source no `UserDefaults`, so
    /// scheduled messages are neither read nor kept.
    static func launchArguments(open: String? = nil, state: String? = nil, extra: [String] = []) -> [String] {
        var arguments = ["--ui-audit", "--disable-icloud", "--mac-section", "mail",
                         "--mail", "--mail-fresh",
                         "-onboardingCompleted", "YES",
                         "-ApplePersistenceIgnoreState", "YES"]
        if let open { arguments += ["--mail-open", open] }
        if let state { arguments += ["--mail-state", state] }
        return arguments + extra
    }

    /// Banana Beta processes that are not ours.
    static func runningBetas(excluding ours: Set<pid_t> = []) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { app in
            guard !ours.contains(app.processIdentifier), !app.isTerminated else { return false }
            return app.bundleIdentifier == betaBundleID || app.localizedName == betaName
        }
    }
}

/// Thrown from `setUp` when the suite must not start. It is never turned into a skip: a suite that
/// quietly did not run is not a suite that passed.
struct MacMailRefusal: Error, CustomStringConvertible {
    let description: String

    static func betaIsRunning(_ running: [NSRunningApplication]) -> MacMailRefusal {
        let pids = running.map { String($0.processIdentifier) }.joined(separator: ", ")
        let text = """

        REFUSING TO START: "Banana Beta" is already running (pid \(pids)).
        These tests launch the same app, with the same bundle identifier and the same data folder, and
        would attach to it or fight it. Quit Banana Beta (Cmd-Q) and run the suite again.
        The suite does not quit it for you and has touched nothing.

        """
        FileHandle.standardError.write(Data(text.utf8))
        return MacMailRefusal(description: text)
    }
}

// MARK: - The sample mailbox, as the tests know it

/// `MailFixtureConversations`, written down: the order the Inbox has and what each conversation is
/// called. The fixtures are not compiled into the tests (they need the app's types), so this is a
/// copy, and `MacMailTestCase.launchMail` checks the order on screen against it at every launch:
/// when the fixtures change this says so by name, and the cases that follow are not trusted.
///
/// Newest first, as the list shows it: the newest message's time, "now" being Monday 5 October 2026
/// at 9:41 AM.
enum MacMailFixture {
    static let inbox: [String] = [
        "q3", "invite", "plain-chain", "receipt", "me-newest", "vip-1", "newsletter", "standup",
        "no-name", "github-8", "github-7", "github-6", "vip-2", "github-5", "github-4", "github-3",
        "github-2", "github-1", "linear", "flight",
        "emoji", "forty", "lunch", "rtl", "attachments", "attachments-many",
        "long", "big-image", "reply-to", "vip-3", "three-newsletters", "lookalike", "no-subject",
        "dentist", "digest", "taxes", "parking", "photos", "hiring", "intro",
    ]

    /// What the reading pane calls a conversation: its subject without "Re:" (`cleanSubject`).
    static let titles: [String: String] = [
        "q3": "Q3 numbers before Thursday",
        "invite": "Invitation: Design review",
        "plain-chain": "Northwind kickoff",
        "receipt": "Your receipt from Stripe",
        "me-newest": "Contract draft",
        "vip-1": "Kickoff agenda",
        "newsletter": "Dispatch no. 212: the week in review",
        "standup": "Standup notes: Monday",
        "no-name": "Your sign-in code is 481 220",
        "vip-2": "Pilot numbers",
        "linear": "Noor, 3 issues are waiting on you",
        "flight": "Your trip to Lisbon: check-in opens tomorrow",
        "lunch": "Lunch Thursday?",
        "attachments": "Signed documents and the logo pack",
        "three-newsletters": "Your weekly reading",
        "hiring": "Senior engineer shortlist",
        "intro": "Intro: Noor and Dewey",
    ]

    static func title(_ key: String) -> String { titles[key] ?? key }

    /// Who the reply to q3 goes to, and who a reply to all adds (Jane; he is left out).
    static let sam = "sam@lee.example"
    static let jane = "jane@parkdesign.example"

    static var inboxCount: Int { inbox.count }
    static let starredCount = 2
}

// MARK: - The accessibility API, for the three things XCUITest cannot say

/// The test runner is an accessibility client already (XCUITest needs it), so it can ask the system
/// what has the keyboard focus, and set the size of the app's window. When it is not trusted every
/// call here answers nil/false and the callers fall back or say so.
enum MacAX {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    private static func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }

    private static func text(_ element: AXUIElement, _ name: String) -> String? {
        value(element, name) as? String
    }

    /// The element with the keyboard focus, in the frontmost app, as "role identifier 'title'".
    static func focusedDescription() -> String {
        guard isTrusted else { return "(not an accessibility client, so focus cannot be read)" }
        let system = AXUIElementCreateSystemWide()
        guard let ref = value(system, kAXFocusedUIElementAttribute as String) else { return "(nothing has focus)" }
        let element = ref as! AXUIElement
        let role = text(element, kAXRoleAttribute as String) ?? "?"
        let identifier = identifierWalkingUp(from: element) ?? "-"
        let title = text(element, kAXTitleAttribute as String) ?? ""
        return "\(role) id=\(identifier) title='\(title)'"
    }

    /// The identifier of the focused element, or of the nearest ancestor that has one.
    static func focusedIdentifier() -> String? {
        guard isTrusted else { return nil }
        let system = AXUIElementCreateSystemWide()
        guard let ref = value(system, kAXFocusedUIElementAttribute as String) else { return nil }
        return identifierWalkingUp(from: ref as! AXUIElement)
    }

    /// The titles and descriptions of the focused element and its first ancestors.
    static func focusedNames() -> [String] {
        guard isTrusted else { return [] }
        let system = AXUIElementCreateSystemWide()
        guard let ref = value(system, kAXFocusedUIElementAttribute as String) else { return [] }
        var element = ref as! AXUIElement
        var names: [String] = []
        for _ in 0..<3 {
            for attribute in [kAXTitleAttribute, kAXDescriptionAttribute] {
                if let name = text(element, attribute as String), !name.isEmpty { names.append(name) }
            }
            guard let parent = value(element, kAXParentAttribute as String) else { break }
            element = parent as! AXUIElement
        }
        return names
    }

    private static func identifierWalkingUp(from start: AXUIElement) -> String? {
        var element = start
        for _ in 0..<5 {
            if let identifier = text(element, kAXIdentifierAttribute as String), !identifier.isEmpty {
                return identifier
            }
            guard let parent = value(element, kAXParentAttribute as String) else { return nil }
            element = parent as! AXUIElement
        }
        return nil
    }

    // MARK: Windows

    private static func windows(of pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        return (value(app, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []
    }

    /// The biggest window of the process: the main one, not a panel or a sheet.
    private static func mainWindow(of pid: pid_t) -> AXUIElement? {
        windows(of: pid).max { area($0) < area($1) }
    }

    private static func size(_ window: AXUIElement) -> CGSize? {
        guard let ref = value(window, kAXSizeAttribute as String) else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(ref as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    private static func position(_ window: AXUIElement) -> CGPoint? {
        guard let ref = value(window, kAXPositionAttribute as String) else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(ref as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private static func area(_ window: AXUIElement) -> CGFloat {
        let size = size(window) ?? .zero
        return size.width * size.height
    }

    static func frame(ofMainWindowOf pid: pid_t) -> CGRect? {
        guard isTrusted, let window = mainWindow(of: pid), let size = size(window),
              let position = position(window) else { return nil }
        return CGRect(origin: position, size: size)
    }

    /// Sets the main window's frame, position first, so that a wide window is not clamped against
    /// the edge of the screen. True when it has taken what was asked for, to a few points (a window
    /// has a smallest size, and a screen a biggest).
    @discardableResult
    static func setFrame(_ frame: CGRect, ofMainWindowOf pid: pid_t) -> Bool {
        guard isTrusted, let window = mainWindow(of: pid) else { return false }
        var origin = frame.origin
        var size = frame.size
        if let position = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
        }
        if let wanted = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, wanted)
        }
        guard let now = Self.size(window) else { return false }
        return abs(now.width - frame.width) < 4 && abs(now.height - frame.height) < 4
    }
}

// MARK: - The clipboard is his

/// What was on the pasteboard, put back. A case that needs something to paste takes the pasteboard
/// and gives it back, however it ends.
final class MacPasteboardLoan {
    private let saved: [[NSPasteboard.PasteboardType: Data]]

    init() {
        var items: [[NSPasteboard.PasteboardType: Data]] = []
        for item in NSPasteboard.general.pasteboardItems ?? [] {
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { entry[type] = data }
            }
            items.append(entry)
        }
        saved = items
    }

    func giveBack() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let items = saved.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }
}

// MARK: - The base case

/// One launch of Mail on the sample mailbox, a window to look at, keys to press, and the evidence
/// kept: a screenshot of the app's own window at each step (never the screen, which has his other
/// windows on it), and on a failure what had the focus and the window's accessibility hierarchy.
class MacMailTestCase: XCTestCase {

    private(set) var app: XCUIApplication!
    /// The processes this case launched, so that they are not mistaken for his Beta.
    private var ours: Set<pid_t> = []
    private var step = 0
    private var originalFrame: CGRect?
    private var pasteboardLoan: MacPasteboardLoan?

    /// The window every case starts from: wide enough for control, list and reading pane, whatever
    /// size the Beta last closed at.
    static let startingSize = CGSize(width: 1120, height: 780)

    // MARK: Life

    override func setUpWithError() throws {
        continueAfterFailure = false
        let running = MacMail.runningBetas(excluding: ours)
        guard running.isEmpty else { throw MacMailRefusal.betaIsRunning(running) }
    }

    override func tearDownWithError() throws {
        if let run = testRun, run.totalFailureCount > 0 { keepEvidenceOfFailure() }
        pasteboardLoan?.giveBack()
        pasteboardLoan = nil
        guard let app else { return }
        // Put his window back the way it was: a Beta that closes at another size reopens at it.
        if let originalFrame, let pid = ours.first {
            MacAX.setFrame(originalFrame, ofMainWindowOf: pid)
        }
        app.terminate()
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline, !MacMail.runningBetas().isEmpty { Thread.sleep(forTimeInterval: 0.2) }
        for stray in MacMail.runningBetas(excluding: []) where ours.contains(stray.processIdentifier) {
            stray.forceTerminate()
        }
    }

    // MARK: Launching

    /// Mail, on the sample mailbox, in a window of `startingSize`. `open` and `state` are
    /// `--mail-open` and `--mail-state` (`MailSession+App`).
    func launchMail(open: String? = nil, state: String? = nil, extra: [String] = [],
                    size: CGSize? = MacMailTestCase.startingSize, expectList: Bool = true) {
        continueAfterFailure = false
        let before = Set(MacMail.runningBetas().map(\.processIdentifier))
        app = XCUIApplication()
        app.launchArguments = MacMail.launchArguments(open: open, state: state, extra: extra)
        app.launch()
        for application in MacMail.runningBetas() where !before.contains(application.processIdentifier) {
            ours.insert(application.processIdentifier)
        }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 40),
                      "The Beta opened no window.\n\(app.debugDescription)")
        if let pid = ours.first {
            originalFrame = MacAX.frame(ofMainWindowOf: pid)
        }
        if let size { resizeWindow(to: size, quietly: true) }
        guard expectList else { return }
        XCTAssertTrue(el(MailID.list).waitForExistence(timeout: 40),
                      "Mail's list never appeared. Launch arguments: \(app.launchArguments)\n\(app.debugDescription)")
        XCTAssertTrue(el(MailID.sampleNote).waitForExistence(timeout: 10),
                      "The sample-mail note is not there: this is not the sample mailbox, and nothing should be pressed.")
        verifyTheFixtureIsTheOneThisSuiteWasWrittenFor()
        settle(0.4)
        shot("launched")
    }

    /// The first rows on screen must be the first of `MacMailFixture.inbox`, in that order.
    private func verifyTheFixtureIsTheOneThisSuiteWasWrittenFor() {
        guard eventually("rows in the list", timeout: 15, report: false, { visibleRowKeys().count >= 5 }) else {
            XCTFail("No rows in Mail's list.\n\(app.debugDescription)")
            return
        }
        let seen = visibleRowKeys()
        let expected = Array(MacMailFixture.inbox.prefix(seen.count))
        XCTAssertEqual(seen, expected,
                       "The sample mailbox is not in the order this suite was written for: update MacMailFixture (MacMailSupport.swift) from MailFixtureConversations before trusting any case.")
    }

    // MARK: Looking

    /// Any element with the identifier, whatever it is.
    func el(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func elements(withPrefix prefix: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
    }

    func has(_ identifier: String) -> Bool { el(identifier).exists }

    func row(_ key: String) -> XCUIElement { el(MailID.row(key)) }

    /// The conversations the list has on screen, top to bottom (a table draws the rows it shows).
    func visibleRowKeys() -> [String] {
        let prefix = MailID.list + ".row."
        let found = elements(withPrefix: prefix).allElementsBoundByIndex
        var seen = Set<String>()
        return found
            .filter { $0.exists }
            .map { (key: String($0.identifier.dropFirst(prefix.count)), top: $0.frame.minY) }
            .sorted { $0.top < $1.top }
            .map(\.key)
            .filter { seen.insert($0).inserted }   // a row may be offered twice by the table and its cell
    }

    /// The subject at the top of the conversation the pane shows, or the one that is open.
    func shownTitle() -> String? {
        let title = el(MailID.conversationTitle)
        guard title.exists else { return nil }
        let text = title.label.isEmpty ? ((title.value as? String) ?? "") : title.label
        return text.isEmpty ? nil : text
    }

    /// A conversation open full width. A container's identifier replaces its buttons' own in the Mac's
    /// accessibility tree (found by the offscreen driver: every button of the header says
    /// `mail.conversation`, every place says `mail.control`, the pane's say `mail.pane`), so the
    /// buttons are found by what they say (`button(labelStarting:)`) and the open screen by its container.
    var isOpen: Bool { has(MailID.conversation) }
    var paneIsShowing: Bool { has(MailID.pane) }
    var hasComposer: Bool { has(MailID.composer) }

    var mainWindow: XCUIElement {
        let windows = app.windows
        if windows.count <= 1 { return windows.firstMatch }
        return windows.allElementsBoundByIndex.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
            ?? windows.firstMatch
    }

    /// The composer's body, wherever the identifier landed.
    var composerBody: XCUIElement {
        let direct = app.textViews[MailID.composerBody]
        if direct.exists { return direct }
        let inside = el(MailID.composer).textViews.firstMatch
        return inside.exists ? inside : el(MailID.composerBody)
    }

    func bodyText() -> String { (composerBody.value as? String) ?? "" }

    func fieldText(_ identifier: String) -> String {
        let field = app.textFields[identifier]
        if field.exists { return (field.value as? String) ?? "" }
        return (el(identifier).value as? String) ?? ""
    }

    /// A button that is "on": the format bar marks a button by `isSelected`.
    func isOn(_ identifier: String) -> Bool {
        let button = el(identifier)
        if button.isSelected { return true }
        if let number = button.value as? NSNumber { return number.boolValue }
        return (button.value as? String) == "1"
    }

    func focusedIdentifier() -> String? { MacAX.focusedIdentifier() }

    /// A button by the start of what it says. The places of the control column are "Inbox, 40".
    func button(labelStarting prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    func place(_ title: String) -> XCUIElement { button(labelStarting: title + ",") }

    /// How many conversations a place says it holds (the control column), or nil.
    func placeCount(_ title: String) -> Int? {
        let button = place(title)
        guard button.exists else { return nil }
        for text in [button.label, button.title, (button.value as? String) ?? ""].reversed() {
            if let number = Self.lastNumber(in: text) { return number }
        }
        return nil
    }

    private static func lastNumber(in text: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: "[0-9][0-9,]*") else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.matches(in: text, range: range).last,
              let found = Range(match.range, in: text) else { return nil }
        return Int(text[found].replacingOccurrences(of: ",", with: ""))
    }

    // MARK: Toasts

    /// The toast whose words contain every fragment, if one is up.
    func toast(containing fragments: String...) -> XCUIElement? {
        let found = app.staticTexts.matching(Self.containing(fragments)).firstMatch
        return found.exists ? found : nil
    }

    /// Every fragment, in the label or in the value (a static text keeps its words in either).
    private static func containing(_ fragments: [String]) -> NSPredicate {
        NSCompoundPredicate(andPredicateWithSubpredicates: fragments.map {
            NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", $0, $0)
        })
    }

    var anyToastIsUp: Bool { app.buttons["Dismiss"].exists }

    @discardableResult
    func waitForToast(containing fragments: String..., timeout: TimeInterval = 5) -> Bool {
        let wanted = fragments
        let appeared = app.staticTexts.matching(Self.containing(wanted)).firstMatch.waitForExistence(timeout: timeout)
        if !appeared {
            let said = app.staticTexts.allElementsBoundByIndex.prefix(80).map { $0.label.isEmpty ? (($0.value as? String) ?? "") : $0.label }.filter { !$0.isEmpty }
            XCTFail("No toast with \(wanted) within \(timeout)s. Static texts on screen: \(said)")
        }
        return appeared
    }

    // MARK: Keys

    @nonobjc func press(_ key: String, _ flags: XCUIElement.KeyModifierFlags = []) {
        front()
        app.typeKey(key, modifierFlags: flags)
    }

    @nonobjc func press(_ key: XCUIKeyboardKey, _ flags: XCUIElement.KeyModifierFlags = []) {
        front()
        app.typeKey(key, modifierFlags: flags)
    }

    func type(_ text: String) {
        front()
        app.typeText(text)
    }

    /// The same key `count` times, one press each (a held key's auto-repeat cannot be sent).
    func press(_ key: String, times count: Int) {
        for _ in 0..<count { press(key) }
    }

    func front() {
        if app.state != .runningForeground { app.activate() }
    }

    func settle(_ seconds: TimeInterval = 0.25) { Thread.sleep(forTimeInterval: seconds) }

    // MARK: Waiting

    /// Polls until `condition` holds. Fails the case, with `what`, if it never does (unless `report`
    /// is false, when it only answers).
    @discardableResult
    func eventually(_ what: @autoclosure () -> String, timeout: TimeInterval = 5, report: Bool = true,
                    file: StaticString = #filePath, line: UInt = #line,
                    _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        if report { XCTFail("Timed out after \(timeout)s waiting for: \(what())", file: file, line: line) }
        return false
    }

    /// The pane (or the open conversation) shows this conversation.
    func expectShown(_ key: String, _ context: String = "", timeout: TimeInterval = 6,
                     file: StaticString = #filePath, line: UInt = #line) {
        let wanted = MacMailFixture.title(key)
        var last: String?
        let ok = eventually("the conversation shown to be '\(wanted)' \(context)", timeout: timeout, report: false) {
            last = shownTitle()
            return last == wanted
        }
        if !ok {
            XCTFail("Expected the conversation shown to be '\(wanted)' (\(key)) \(context), but it shows \(String(describing: last)). Rows on screen: \(visibleRowKeys())",
                    file: file, line: line)
        }
    }

    func expectNothingHappenedToTheList(_ context: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(anyToastIsUp, "A toast came up \(context): something was done.", file: file, line: line)
        XCTAssertEqual(placeCount("Inbox"), MacMailFixture.inboxCount,
                       "The Inbox count moved \(context)", file: file, line: line)
    }

    // MARK: Evidence

    /// A picture of the app's window, and only it.
    func shot(_ name: String) {
        guard let app, app.state == .runningForeground || app.state == .runningBackground else { return }
        step += 1
        let window = mainWindow
        guard window.exists else { return }
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = String(format: "%02d %@", step, name)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func keepEvidenceOfFailure() {
        guard let app else { return }
        let focus = "Focused: \(MacAX.focusedDescription())\nFrontmost app: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")\nApp state: \(app.state.rawValue)\nAccessibility client: \(MacAX.isTrusted)\n"
        let notes = XCTAttachment(string: focus)
        notes.name = "focus at failure"
        notes.lifetime = .keepAlways
        add(notes)
        guard app.state == .runningForeground || app.state == .runningBackground else { return }
        shot("at failure")
        let hierarchy = XCTAttachment(string: app.windows.allElementsBoundByIndex.map(\.debugDescription).joined(separator: "\n\n"))
        hierarchy.name = "window hierarchy at failure"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }

    // MARK: The window

    var windowFrame: CGRect { mainWindow.frame }

    /// Sets the main window's size. Without the accessibility API it drags the window's right edge.
    @discardableResult
    func resizeWindow(to size: CGSize, quietly: Bool = false) -> Bool {
        let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let wanted = CGSize(width: min(size.width, screen.width), height: min(size.height, screen.height))
        var done = false
        if let pid = ours.first {
            // AX coordinates have their origin at the top left of the main screen.
            let primary = NSScreen.screens.first?.frame.height ?? screen.maxY
            let origin = CGPoint(x: screen.minX + 20, y: primary - screen.maxY + 20)
            done = MacAX.setFrame(CGRect(origin: origin, size: wanted), ofMainWindowOf: pid)
        }
        if !done { done = dragRightEdge(to: wanted.width) }
        settle(0.6)
        if !done && !quietly {
            XCTFail("The window could not be resized to \(wanted) (accessibility API: \(MacAX.isTrusted); window now \(windowFrame.size)). Test the window sizes by hand.")
        }
        return done
    }

    /// The fallback: press on the right edge of the window and drag.
    private func dragRightEdge(to width: CGFloat) -> Bool {
        let window = mainWindow
        guard window.exists else { return false }
        let delta = width - window.frame.width
        guard abs(delta) > 4 else { return true }
        for inset in [CGFloat(-1), 2] {
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5)).withOffset(CGVector(dx: inset, dy: 0))
            let end = start.withOffset(CGVector(dx: delta, dy: 0))
            start.press(forDuration: 0.2, thenDragTo: end)
            settle(0.4)
            if abs(mainWindow.frame.width - width) < 6 { return true }
        }
        return false
    }

    /// How wide Mail's own area is: from the left edge of its first column to the window's right edge.
    func mailWidth() -> Double? {
        let left = [MailID.control, MailID.list]
            .map { el($0) }
            .filter { $0.exists }
            .map { $0.frame.minX }
            .min()
        guard let left else { return nil }
        return Double(windowFrame.maxX - left)
    }

    // MARK: Borrowing the clipboard

    func borrowPasteboard() {
        if pasteboardLoan == nil { pasteboardLoan = MacPasteboardLoan() }
    }

    // MARK: Things that must not happen

    /// A chord must do what it says and nothing else: no panel opened, no sheet, still Mail.
    func expectOnlyTheMainWindow(_ context: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(app.windows.count, 1, "An extra window came up \(context): \(app.windows.allElementsBoundByIndex.map(\.title))",
                       file: file, line: line)
        XCTAssertEqual(app.sheets.count, 0, "A sheet came up \(context)", file: file, line: line)
        XCTAssertTrue(has(MailID.control) || has(MailID.list), "Mail is no longer in front \(context)", file: file, line: line)
    }

    /// The ⌘K menu's own words: a command title nothing else on screen says.
    var commandMenuIsUp: Bool { app.staticTexts["Go to today"].exists }

    // MARK: Reaching the composer

    @discardableResult
    func openReplyComposer(_ key: String = "q3") -> Bool {
        press("r")
        let up = el(MailID.composer).waitForExistence(timeout: 8)
        XCTAssertTrue(up, "R did not open a composer.\n\(app.debugDescription)")
        return up
    }

    /// What each field says of itself (its accessibility label), for when the system names the focused
    /// element by its container's identifier: the offscreen driver found a field's editor reporting
    /// `mail.pane` for every field in the pane.
    private static let fieldLabels: [String: String] = [
        MailID.composerTo: "To", MailID.composerCc: "Cc", MailID.composerBcc: "Bcc",
        MailID.composerSubject: "Subject", MailID.composerBody: "Message",
        MailID.timePickerField: "Send later\u{2026}",
    ]

    /// Whether the keyboard is in the element with this identifier, by what the system says is focused:
    /// its identifier, or the label it carries.
    func hasFocus(_ identifier: String) -> Bool {
        if MacAX.focusedIdentifier() == identifier { return true }
        guard let label = Self.fieldLabels[identifier] else { return false }
        return MacAX.focusedNames().contains(label)
    }

    /// Clicks into a field and waits for the keyboard to be there.
    func focus(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        let target = identifier == MailID.composerBody ? composerBody : el(identifier)
        XCTAssertTrue(target.waitForExistence(timeout: 8), "\(identifier) is not on screen", file: file, line: line)
        target.click()
        eventually("\(identifier) to have the keyboard (the system says: \(MacAX.focusedDescription()))", timeout: 4,
                   file: file, line: line) { hasFocus(identifier) }
    }
}
