#if DEBUG && os(macOS)
import AppKit
import SwiftUI
import CoreGraphics

// A scripted key driver for the Mac's Mail, for a screen nobody is looking at.
//
//   Banana Beta --mail-key-script <file> --mail-key-out <dir> --ui-audit --disable-icloud ...
//
// It hosts the app's real Mac shell (`MacGatedRootView`, so `MacRootView`, `MacKeyMonitor`, the
// Mail section on the sample mailbox, the Plan section) in a window of its own: ordered in at the back,
// at (-30000, -30000), fully transparent, made key without the app being activated (a window that is
// never ordered in does not take text), then plays a script of steps: keys with modifiers, typed
// strings, clicks on an element by its accessibility identifier or label, window sizes, waits. After
// each step it writes a PNG of the window and the state to log.json, and `expect` lines check it.
//
// REAL: keys are `NSEvent`s handed to the application through its own event queue
// (`MailKeyDriver+Events.swift`), so the local key monitor, `MailKeyDispatch`, the type-ahead queue,
// AppKit's first responder and the text views all see them as they see a keyboard's.
// NOT REAL: the events do not come from the HID system (no auto-repeat, a fixed US layout); the window
// claims `isKeyWindow` while the app is never active, so for a Command chord the driver does what
// AppKit does for an active app (offers it to the window's views, then the menu), and the mouse reaches
// SwiftUI only in the same off-screen way; the main window's own (SwiftUI) window is never made.
//
// Debug only (Release has none of this), a Mac only, and an audit launch: it never starts
// `wireUp()` (nothing here is `configuredRoot`), it is in `CalendarWriteBack.diagnosticArguments`
// (no calendar write, no menu-bar item, no global hot key), and `MacRootView` leaves the
// CloudKit poll alone while it runs. `tools/mac-mail-keydriver.sh` runs a COPY of the app with
// another bundle identifier, no entitlements, a throwaway HOME and no network, so that it can run
// beside the installed Beta without sharing a preference, a file or a connection with it.
@MainActor
final class MailKeyDriver {

    static var requested: Bool { argument("--mail-key-script") != nil }

    nonisolated static func argument(_ flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private static var started = false

    /// Before the first window can exist: a process nobody is meant to see.
    static func prepareProcess() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    static func startIfNeeded(root: AnyView) {
        guard requested, !started, let script = argument("--mail-key-script") else { return }
        started = true
        let out = URL(fileURLWithPath: argument("--mail-key-out") ?? NSTemporaryDirectory() + "mail-key-out")
        let driver = MailKeyDriver(root: root, script: URL(fileURLWithPath: script), out: out)
        Task { @MainActor in await driver.run() }
    }

    // MARK: State of a run

    let root: AnyView
    let scriptURL: URL
    let out: URL
    var window: MailKeyDriverWindow!
    var steps: [Step] = []
    var number = 0
    var failures: [String] = []
    /// Milliseconds between two keys of one `type` line.
    var gap = 5
    /// Milliseconds the app is given after each step before it is photographed.
    var settle = 250
    var delivery = Delivery.post
    var log: [[String: Any]] = []
    var pressedKeys = 0
    /// What the recording monitor saw, since the last step.
    var seen: [String] = []
    private var seenMonitor: Any?

    enum Delivery: String { case post, send, window }

    struct Step {
        var line: Int
        var text: String
        var verb: String
        var rest: String
    }

    init(root: AnyView, script: URL, out: URL) {
        self.root = root
        self.scriptURL = script
        self.out = out
    }

    // MARK: The run

    func run() async {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // If the run hangs (a system prompt nobody can answer, a deadlock), it ends itself.
        let limit = Double(ProcessInfo.processInfo.environment["MAIL_KEY_TIMEOUT"] ?? "") ?? 150
        DispatchQueue.main.asyncAfter(deadline: .now() + limit) { [out] in
            try? "timed out after \(limit) s\n".write(to: out.appendingPathComponent("TIMEOUT.txt"), atomically: true, encoding: .utf8)
            exit(3)
        }
        guard let text = try? String(contentsOf: scriptURL, encoding: .utf8) else {
            fputs("mail-key-driver: cannot read \(scriptURL.path)\n", stderr)
            exit(2)
        }
        steps = Self.parse(text)
        await host()
        record(label: "environment", extra: environment())
        for step in steps {
            await perform(step)
        }
        writeSummary()
        exit(failures.isEmpty ? 0 : 1)
    }

    static func parse(_ text: String) -> [Step] {
        var result: [Step] = []
        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            result.append(Step(line: index + 1, text: line, verb: parts[0].lowercased(),
                               rest: parts.count > 1 ? String(parts[1]) : ""))
        }
        return result
    }

    // MARK: The window

    private func host() async {
        let size = CGSize(width: 1120, height: 780)
        window = MailKeyDriverWindow(contentRect: NSRect(origin: .zero, size: size),
                                     styleMask: [.titled, .closable, .resizable],
                                     backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Banana"
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        // A frame far from every screen, in case anything ever orders it in. It is not ordered in.
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        // Ordered in at the back, off every screen and invisible, and made key without the app being
        // activated: a window that was never ordered in does not take text (its input context is
        // not active). `--mail-key-never-ordered 1` leaves it unordered, for comparison.
        if Self.argument("--mail-key-never-ordered") == nil {
            window.alphaValue = 0
            window.ignoresMouseEvents = false
            window.orderBack(nil)
            // Key, though the app is not active: never `NSApp.activate`, never ordered front.
            window.makeKey()
        }
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        installRecorder()
        await pause(1.5)
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        window.announceKey()
        await pause(0.5)
    }

    /// A monitor installed before the app's own, which only writes down what reaches the app.
    ///
    /// It is the last monitor to be asked, so a key the app's own monitor took never gets here. It
    /// is also where the driver stands in for something AppKit does for an active app and skips for
    /// this one (which is never activated): a Command or Control chord is offered to the window's
    /// views (`performKeyEquivalent`: SwiftUI's hidden-button shortcuts, the text view's own) and
    /// then to the main menu (its item's target, or the first responder's chain), in AppKit's order.
    private func installRecorder() {
        seenMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return event }
                self.seen.append("keyDown \(event.charactersIgnoringModifiers ?? "?") code=\(event.keyCode) flags=\(event.modifierFlags.rawValue) window=\(event.window.map { String($0.windowNumber) } ?? "nil")")
                let chord = !event.modifierFlags.intersection([.command, .control]).isEmpty
                guard chord, let target = event.window else { return event }
                if target.performKeyEquivalent(with: event) {
                    self.seen.append("  chord taken by the window's views")
                    return nil
                }
                if let used = self.performMenuKeyEquivalent(event, window: target) {
                    self.seen.append("  chord taken by the menu item '\(used)'")
                    return nil
                }
                self.seen.append("  chord taken by nobody")
                return event
            }
        }
    }

    /// The main menu's answer to a chord, when the app is not active: find the item, run its action
    /// on its target, or on whatever of the first responder's chain takes it.
    private func performMenuKeyEquivalent(_ event: NSEvent, window: NSWindow) -> String? {
        guard let menu = NSApp.mainMenu, let wanted = event.charactersIgnoringModifiers?.lowercased(), !wanted.isEmpty else { return nil }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        func find(_ menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if let sub = item.submenu, let hit = find(sub) { return hit }
                let mask = item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control])
                if !item.keyEquivalent.isEmpty, item.keyEquivalent.lowercased() == wanted, mask == flags, item.action != nil { return item }
            }
            return nil
        }
        guard let item = find(menu), let action = item.action else { return nil }
        let ok: Bool
        if let target = item.target { ok = NSApp.sendAction(action, to: target, from: item) }
        else { ok = window.firstResponder?.tryToPerform(action, with: item) ?? window.tryToPerform(action, with: item) }
        return ok ? item.title : nil
    }

    // MARK: Steps

    func perform(_ step: Step) async {
        number += 1
        var label = step.text
        seen = []
        switch step.verb {
        case "name":
            break
        case "gap": gap = Int(step.rest) ?? gap
        case "settle": settle = Int(step.rest) ?? settle
        case "delivery": delivery = Delivery(rawValue: step.rest) ?? delivery
        case "wait", "sleep": await pause(Double(step.rest) ?? 0.5)
        case "idle": await pause(0.4)
        case "size":
            let numbers = step.rest.split(separator: " ").compactMap { Double($0) }
            if numbers.count >= 2 { resize(width: numbers[0], height: numbers[1]) }
            await pause(0.6)
        case "key": await press(spec: step.rest)
        case "type": await type(step.rest)
        case "click": await click(identifier: step.rest, count: 1)
        case "doubleclick": await click(identifier: step.rest, count: 2)
        case "axpress": axPress(identifier: step.rest)
        case "focus": focus(identifier: step.rest)
        case "refocus": refocus(field: step.rest)
        case "clickat":
            let numbers = step.rest.split(separator: " ").compactMap { Double($0) }
            if numbers.count >= 2 { await clickAt(NSPoint(x: numbers[0], y: numbers[1]), count: 1) }
        case "expect": checkExpectation(step.rest, line: step.line)
        case "shot": label = "shot " + step.rest
        case "note": break
        case "dumpax": dumpAccessibility(to: out.appendingPathComponent(String(format: "%03d-ax.txt", number)))
        default:
            failures.append("line \(step.line): unknown verb '\(step.verb)'")
        }
        if !["name", "gap", "settle", "delivery", "expect", "note"].contains(step.verb) {
            await pause(Double(settle) / 1000)
        }
        record(label: label, extra: [:])
    }

    func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    func resize(width: Double, height: Double) {
        window.setContentSize(NSSize(width: width, height: height))
        window.contentView?.frame = NSRect(x: 0, y: 0, width: width, height: height)
        window.contentView?.layoutSubtreeIfNeeded()
    }

    // MARK: Expectations

    /// `expect <field> is|isnot|contains|notcontains|exists|absent [value]`, against `state()`.
    func checkExpectation(_ text: String, line: Int) {
        let words = text.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
        guard words.count >= 2 else {
            failures.append("line \(line): malformed expect '\(text)'")
            return
        }
        let field = words[0], op = words[1], wanted = words.count > 2 ? words[2] : ""
        let actual = Self.flatten(state())[field] ?? ""
        let ok: Bool
        switch op {
        case "is": ok = actual == wanted
        case "isnot": ok = actual != wanted
        case "contains": ok = actual.contains(wanted)
        case "notcontains": ok = !actual.contains(wanted)
        case "exists": ok = !actual.isEmpty
        case "absent": ok = actual.isEmpty
        default:
            failures.append("line \(line): unknown operator '\(op)'")
            return
        }
        let verdict = ok ? "PASS" : "FAIL"
        expectations.append("\(verdict) line \(line): \(text)  [actual: \(actual.isEmpty ? "(empty)" : actual)]")
        if !ok { failures.append("line \(line): expected \(field) \(op) '\(wanted)', got '\(actual)'") }
    }

    var expectations: [String] = []
    /// Things a step noticed that are not state: where a click landed, and on what.
    var notes: [String] = []

    // MARK: Output

    func record(label: String, extra: [String: Any]) {
        var entry: [String: Any] = ["step": number, "label": label, "state": state(), "monitorSaw": seen]
        if !expectations.isEmpty { entry["expectations"] = expectations; expectations = [] }
        if !notes.isEmpty { entry["notes"] = notes; notes = [] }
        for (key, value) in extra { entry[key] = value }
        log.append(entry)
        let name = String(format: "%03d", number)
        snapshot(to: out.appendingPathComponent("\(name).png"))
        if let data = try? JSONSerialization.data(withJSONObject: log, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: out.appendingPathComponent("log.json"))
        }
        let summary = (entry["state"] as? [String: Any]).map { Self.oneLine($0) } ?? ""
        let line = "\(name) \(label)\n      \(summary)\n"
        FileHandle.standardError.write(Data(line.utf8))
        if let marks = entry["expectations"] as? [String] {
            for mark in marks { FileHandle.standardError.write(Data("      \(mark)\n".utf8)) }
        }
    }

    func writeSummary() {
        var text = "steps: \(number)\nfailures: \(failures.count)\n"
        for failure in failures { text += "  - \(failure)\n" }
        try? text.write(to: out.appendingPathComponent("SUMMARY.txt"), atomically: true, encoding: .utf8)
        FileHandle.standardError.write(Data(("\n" + text).utf8))
    }

    func snapshot(to url: URL) {
        guard let view = window?.contentView, view.bounds.width > 0,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }
}

/// The window the shell is hosted in. It is never shown, so it has to say what a window that was
/// would: that it can be key, that it is, and (instead of the beep an unhandled key makes) that a
/// key nobody wanted is nobody's business.
final class MailKeyDriverWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }

    /// The last responder in the chain: the default answer to a key is a beep.
    override func noResponder(for eventSelector: Selector) {}

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// What AppKit posts when a window becomes key, which SwiftUI listens for.
    func announceKey() {
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: self)
        NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: self)
    }
}
#endif
