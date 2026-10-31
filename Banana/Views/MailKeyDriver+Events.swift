#if DEBUG && os(macOS)
import AppKit

// How the driver makes a key, and how it gets to the app.
//
// REAL: an `NSEvent` of type keyDown/keyUp, with a US keyboard's key code, characters,
// charactersIgnoringModifiers (the shifted character when Shift is held, as AppKit documents),
// modifier flags and the window's number, handed to the application with `NSApp.postEvent`: the
// application's own event queue, which its run loop empties through `NSApplication.sendEvent` and so
// through every local monitor (`MacKeyMonitor`'s, whose answer decides whether the window sees
// the key) and then `NSWindow.sendEvent`: first responder, `interpretKeyEvents`, key equivalents
// (`performKeyEquivalent`: the main menu's and SwiftUI's hidden-button shortcuts). Keys are separated
// by `gap` milliseconds on the real clock, so "R then Each at once" is a few milliseconds apart and
// the run loop turns between them, as it does for a typist.
//
// NOT REAL: the events do not come from the HID system, so `isARepeat` is false unless a step says
// otherwise (`repeat`), the keyboard layout is fixed (US), no input method is involved, and the
// window answers `isKeyWindow` itself. A key the window does not take is silent (no beep).
extension MailKeyDriver {

    struct Key {
        var code: UInt16
        var base: String
        /// What Shift makes of `base`.
        var shifted: String
    }

    static let keys: [String: Key] = {
        var table: [String: Key] = [:]
        let letters: [(String, UInt16)] = [
            ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7), ("c", 8), ("v", 9),
            ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15), ("y", 16), ("t", 17), ("o", 31), ("u", 32),
            ("i", 34), ("p", 35), ("l", 37), ("j", 38), ("k", 40), ("n", 45), ("m", 46),
        ]
        for (letter, code) in letters { table[letter] = Key(code: code, base: letter, shifted: letter.uppercased()) }
        let digits: [(String, UInt16, String)] = [
            ("1", 18, "!"), ("2", 19, "@"), ("3", 20, "#"), ("4", 21, "$"), ("5", 23, "%"), ("6", 22, "^"),
            ("7", 26, "&"), ("8", 28, "*"), ("9", 25, "("), ("0", 29, ")"),
        ]
        for (digit, code, shifted) in digits { table[digit] = Key(code: code, base: digit, shifted: shifted) }
        let symbols: [(String, UInt16, String)] = [
            ("=", 24, "+"), ("-", 27, "_"), ("]", 30, "}"), ("[", 33, "{"), ("'", 39, "\""), (";", 41, ":"),
            ("\\", 42, "|"), (",", 43, "<"), ("/", 44, "?"), (".", 47, ">"), ("`", 50, "~"),
        ]
        for (symbol, code, shifted) in symbols { table[symbol] = Key(code: code, base: symbol, shifted: shifted) }
        table["return"] = Key(code: 36, base: "\r", shifted: "\r")
        table["tab"] = Key(code: 48, base: "\t", shifted: "\t")
        table["space"] = Key(code: 49, base: " ", shifted: " ")
        table["delete"] = Key(code: 51, base: "\u{7F}", shifted: "\u{7F}")
        table["escape"] = Key(code: 53, base: "\u{1B}", shifted: "\u{1B}")
        table["left"] = Key(code: 123, base: String(UnicodeScalar(NSLeftArrowFunctionKey)!), shifted: String(UnicodeScalar(NSLeftArrowFunctionKey)!))
        table["right"] = Key(code: 124, base: String(UnicodeScalar(NSRightArrowFunctionKey)!), shifted: String(UnicodeScalar(NSRightArrowFunctionKey)!))
        table["down"] = Key(code: 125, base: String(UnicodeScalar(NSDownArrowFunctionKey)!), shifted: String(UnicodeScalar(NSDownArrowFunctionKey)!))
        table["up"] = Key(code: 126, base: String(UnicodeScalar(NSUpArrowFunctionKey)!), shifted: String(UnicodeScalar(NSUpArrowFunctionKey)!))
        table["esc"] = table["escape"]
        return table
    }()

    /// "cmd+shift+return", "e", "shift+e", "\\", "]".
    func parse(spec: String) -> (key: Key, flags: NSEvent.ModifierFlags)? {
        var flags: NSEvent.ModifierFlags = []
        var words = spec.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        // "cmd+," and "cmd++" keep their last word as the key.
        while words.count > 1 {
            let word = words[0].lowercased()
            switch word {
            case "cmd", "command": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "opt", "option", "alt": flags.insert(.option)
            case "ctrl", "control": flags.insert(.control)
            default: return nil
            }
            words.removeFirst()
        }
        let name = words.first ?? ""
        guard let key = Self.keys[name.lowercased()] ?? Self.keys[name] else { return nil }
        return (key, flags)
    }

    func event(_ type: NSEvent.EventType, key: Key, flags: NSEvent.ModifierFlags, isRepeat: Bool = false) -> NSEvent? {
        let shift = flags.contains(.shift)
        let command = flags.contains(.command) || flags.contains(.control)
        var produced = shift ? key.shifted : key.base
        var ignoring = produced
        // With Command held the key is named by its base character, whatever Shift made of it: that
        // is what a key equivalent is written in (`.keyboardShortcut(",", modifiers: [.command, .shift])`).
        if command {
            produced = key.base
            ignoring = key.base
        }
        // Keys go to the key window: a sheet, when one is attached.
        let keyWindow = window.attachedSheet ?? window!
        return NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: keyWindow.windowNumber,
                                context: nil, characters: produced, charactersIgnoringModifiers: ignoring,
                                isARepeat: isRepeat, keyCode: key.code)
    }

    /// One key, down and up.
    func press(spec: String, isRepeat: Bool = false) async {
        guard let parsed = parse(spec: spec.trimmingCharacters(in: .whitespaces)) else {
            failures.append("cannot read the key '\(spec)'")
            return
        }
        pressedKeys += 1
        let flags = parsed.flags
        // The modifier keys themselves are not sent: a chord arrives as one key with its flags.
        if let down = event(.keyDown, key: parsed.key, flags: flags, isRepeat: isRepeat) { await deliver(down) }
        await pause(0.004)
        if let up = event(.keyUp, key: parsed.key, flags: flags) { await deliver(up) }
    }

    /// A string, one key per character, `gap` milliseconds apart, no longer between them than that.
    func type(_ text: String) async {
        for character in text {
            let string = String(character)
            if let spec = spec(forCharacter: string) { await press(spec: spec) }
            else { failures.append("cannot type '\(string)'") }
            await pause(Double(gap) / 1000)
        }
    }

    private func spec(forCharacter string: String) -> String? {
        if string == " " { return "space" }
        if string == "\n" { return "return" }
        if Self.keys[string] != nil { return string }
        if string.count == 1, string.first?.isUppercase == true, Self.keys[string.lowercased()] != nil {
            return "shift+" + string.lowercased()
        }
        for (name, key) in Self.keys where key.shifted == string && key.base != key.shifted && name.count == 1 {
            return "shift+" + name
        }
        return nil
    }

    // MARK: Delivering

    func deliver(_ event: NSEvent) async {
        switch delivery {
        case .post:
            NSApp.postEvent(event, atStart: false)
            // The run loop takes it, and whatever it starts.
            await pause(0.012)
        case .send:
            NSApp.sendEvent(event)
            await pause(0.004)
        case .window:
            window.sendEvent(event)
            await pause(0.004)
        }
    }

    // MARK: The mouse

    /// `identifier` is an accessibility identifier, or `label:<start of the label>`: a container's
    /// identifier replaces its buttons' own in this tree (`mail.control` for all five places), so
    /// those are found by what they say.
    func click(identifier: String, count: Int) async {
        let all = accessibilityNodes()
        let nodes: [AXNode]
        if identifier.hasPrefix("label:") {
            let start = String(identifier.dropFirst("label:".count))
            nodes = all.filter { $0.label.hasPrefix(start) && !$0.frame.isEmpty && ($0.role == "AXButton" || $0.role == "AXMenuButton") }
        } else {
            nodes = all.filter { $0.id == identifier && !$0.frame.isEmpty }
        }
        guard let node = nodes.first else {
            failures.append("click: no element '\(identifier)' (the tree has \(all.count) elements)")
            return
        }
        // The frame is in screen coordinates (origin bottom left); the window's are too.
        let screenPoint = NSPoint(x: node.frame.midX, y: node.frame.midY)
        let inWindow = window.convertPoint(fromScreen: screenPoint)
        await clickAt(inWindow, count: count)
    }

    /// The assistive "press" action on the element (`axpress <id|label:...>`): what VoiceOver does,
    /// not a mouse. SwiftUI buttons in a window that is never shown do not take a mouse event.
    func axPress(identifier: String) {
        let all = accessibilityNodes()
        let nodes: [AXNode]
        if identifier.hasPrefix("label:") {
            let start = String(identifier.dropFirst("label:".count))
            nodes = all.filter { $0.label.hasPrefix(start) && ($0.role == "AXButton" || $0.role == "AXMenuButton") }
        } else {
            nodes = all.filter { $0.id == identifier }
        }
        guard let object = nodes.first?.object, object.responds(to: Selector(("accessibilityPerformPress"))) else {
            failures.append("axpress: no pressable element '\(identifier)'")
            return
        }
        _ = object.perform(Selector(("accessibilityPerformPress")))
    }

    /// `refocus [to|cc|bcc|subject|body]`: asks the open composer for the caret again, as a second
    /// typed key does (`MailSession.typing`). Stands in for a click into a field, which reaches
    /// SwiftUI's focus (the AppKit-level `focus` does not tell `@FocusState`).
    func refocus(field: String) {
        guard let composer = MailSession.existing?.composer else {
            failures.append("refocus: no composer is open")
            return
        }
        switch field {
        case "to": composer.askForFocus(.to)
        case "cc": composer.askForFocus(.cc)
        case "bcc": composer.askForFocus(.bcc)
        case "subject": composer.askForFocus(.subject)
        case "body": composer.askForFocus(.body)
        default: composer.askForFocus()
        }
    }

    /// `focus <identifier>`: what a click into a text field does to the first responder, done at
    /// the AppKit level (`makeFirstResponder`), because a mouse event does not reach SwiftUI
    /// content in a window that is never shown. Finds the text view or field by its identifier.
    func focus(identifier: String) {
        // `label:To`: by what the field says, since a container's identifier replaces its fields' own.
        let byLabel = identifier.hasPrefix("label:") ? String(identifier.dropFirst("label:".count)) : nil
        func find(_ view: NSView) -> NSView? {
            if view is NSTextView || view is NSTextField {
                if let byLabel { if view.accessibilityLabel() == byLabel { return view } }
                else if view.accessibilityIdentifier() == identifier { return view }
            }
            for sub in view.subviews { if let hit = find(sub) { return hit } }
            return nil
        }
        guard let content = window.contentView, let target = find(content) else {
            failures.append("focus: no text view or field with the identifier '\(identifier)'")
            return
        }
        if !window.makeFirstResponder(target) { failures.append("focus: '\(identifier)' refused the first responder") }
    }

    /// `point` is in window coordinates, origin bottom left.
    func clickAt(_ point: NSPoint, count: Int) async {
        if let content = window.contentView {
            let hit = content.hitTest(point)
            notes.append("click at window point \(NSStringFromPoint(point)) hits \(hit.map { String(describing: Swift.type(of: $0)) } ?? "nothing"); window frame \(NSStringFromRect(window.frame))")
        }
        for index in 1...count {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: window.windowNumber, context: nil,
                                                     eventNumber: index, clickCount: index, pressure: type == .leftMouseDown ? 1 : 0)
                else { continue }
                // How a mouse event arrives is the `delivery` the script chose (default: the window's
                // own `sendEvent`, which is where AppKit hands a mouse event it has routed).
                if delivery == .post { NSApp.postEvent(event, atStart: false) }
                else if delivery == .send { NSApp.sendEvent(event) }
                else { window.sendEvent(event) }
                await pause(0.05)
            }
        }
    }
}
#endif
