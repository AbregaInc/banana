#if DEBUG && os(macOS)
import AppKit
import CoreGraphics

// What the driver writes down after each step: the app's own account of itself (which section is
// in front, where Mail's cursor is, what is open, what the composer holds, the toast's words, the
// counts in the control column), the first responder, and the accessibility tree's identifiers.
extension MailKeyDriver {

    struct AXNode {
        var id: String
        var label: String
        var role: String
        var frame: NSRect
        var depth = 0
        var kind = ""
        var object: NSObject?
        var selected = false
    }

    // MARK: The accessibility tree, from inside

    func accessibilityNodes() -> [AXNode] {
        guard let content = window?.contentView else { return [] }
        var found: [AXNode] = []
        var visited = 0
        func visit(_ object: Any, depth: Int) {
            guard depth < 60, visited < 6000 else { return }
            visited += 1
            var children: [Any] = []
            // Everything is asked by selector, as `Any`: a table's rows are `NSOutlineRow`s that the
            // typed API would trap on.
            if let element = object as? NSObject {
                func ask(_ name: String) -> Any? {
                    element.responds(to: Selector((name))) ? element.value(forKey: name) : nil
                }
                let frame = (ask("accessibilityFrame") as? NSValue)?.rectValue ?? .zero
                var isSelected = false
                if element.responds(to: Selector(("isAccessibilitySelected"))) {
                    isSelected = (element.value(forKey: "accessibilitySelected") as? Bool) ?? false
                }
                found.append(AXNode(id: ask("accessibilityIdentifier") as? String ?? "",
                                    label: ask("accessibilityLabel") as? String ?? "",
                                    role: ask("accessibilityRole") as? String ?? "?", frame: frame, depth: depth,
                                    kind: String(describing: Swift.type(of: element)), object: element,
                                    selected: isSelected))
                children = (element is NSTableView) ? [] : (ask("accessibilityChildren") as? [Any] ?? [])
                if let view = element as? NSView, !(element is NSTableView), children.isEmpty {
                    children = view.subviews.filter { !($0 is NSScroller) }
                }
                // A table's rows are proxies that say nothing by selector: go to the cells it has drawn.
                if let table = element as? NSTableView {
                    for row in 0..<table.numberOfRows {
                        if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) { children.append(cell) }
                    }
                }
            }
            for child in children { visit(child, depth: depth + 1) }
        }
        visit(content, depth: 0)
        return found
    }

    /// Every node, indented by depth: `dumpax` writes this beside the step's picture.
    func dumpAccessibility(to url: URL) {
        let lines = accessibilityNodes().map { node in
            String(repeating: "  ", count: node.depth) + "\(node.kind) role=\(node.role) id=\(node.id) label='\(node.label.prefix(60))' frame=\(NSStringFromRect(node.frame))"
        }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// The Mail identifiers on screen, and the rows of the list top to bottom.
    func identifiers() -> (ids: [String], rows: [String]) {
        let nodes = accessibilityNodes()
        let ids = Set(nodes.map(\.id).filter { !$0.isEmpty })
        let prefix = "mail.list.row."
        let rows = nodes.filter { $0.id.hasPrefix(prefix) && !$0.frame.isEmpty }
            .sorted { $0.frame.maxY > $1.frame.maxY }
            .map { String($0.id.dropFirst(prefix.count)) }
        var seenRows = Set<String>()
        return (ids.sorted(), rows.filter { seenRows.insert($0).inserted })
    }

    // MARK: State

    func state() -> [String: Any] {
        var state: [String: Any] = [:]
        state["section"] = MacNavigator.shared.section.rawValue
        state["shortcutsSheet"] = MacCommandCenter.shared.showsShortcuts
        state["commandMenu"] = MacCommandCenter.shared.showsCommandMenu
        state["windowSize"] = window.map { "\(Int($0.contentLayoutRect.width))x\(Int($0.contentLayoutRect.height))" } ?? ""
        state["sheet"] = window?.attachedSheet != nil
        if let toast = ToastCenter.shared.toast {
            state["toast"] = toast.message
            state["toastAction"] = toast.canUndo ? toast.actionTitle : ""
        } else {
            state["toast"] = ""
            state["toastAction"] = ""
        }
        state["firstResponder"] = firstResponderDescription()
        state["monitorInstalledAndKeysHandled"] = pressedKeys

        if let session = MailSession.existing {
            var mail: [String: Any] = [:]
            mail["place"] = MailPlacesModel.title(of: session.scope)
            mail["cursor"] = session.model.cursor?.thread ?? ""
            mail["open"] = session.navigation.open?.thread ?? ""
            mail["pane"] = session.pane.reader.map { $0.id.thread } ?? ""
            mail["title"] = session.pane.reader?.title ?? ""
            mail["showsPane"] = session.navigation.showsPane
            mail["showsDetails"] = session.navigation.showsDetails
            mail["counts"] = [
                "inbox": session.places.total(of: .inbox) ?? -1,
                "starred": session.places.total(of: .starred) ?? -1,
                "drafts": session.places.total(of: .drafts) ?? -1,
                "scheduled": session.places.total(of: .outbox) ?? -1,
                "done": session.places.total(of: .done) ?? -1,
            ]
            state["mail"] = mail
            if let composer = session.composer {
                var fields: [String: Any] = [:]
                fields["title"] = composer.title
                fields["host"] = composer.host?.thread ?? ""
                fields["ready"] = composer.isReady
                fields["to"] = composer.to.map(\.address).joined(separator: ",")
                fields["cc"] = composer.cc.map(\.address).joined(separator: ",")
                fields["bcc"] = composer.bcc.map(\.address).joined(separator: ",")
                fields["toText"] = composer.toText
                fields["ccText"] = composer.ccText
                fields["bccText"] = composer.bccText
                fields["subject"] = composer.subject
                fields["body"] = composer.body
                fields["awaitingCaret"] = composer.awaitingFocus
                fields["queued"] = composer.typedAhead
                fields["schedule"] = composer.scheduleLine ?? ""
                fields["picker"] = composer.timePicker.map { $0.text } ?? "(closed)"
                fields["suggestions"] = composer.suggestions.map(\.address).joined(separator: ",")
                fields["highlight"] = composer.highlighted
                fields["files"] = composer.files.shown.map(\.name).joined(separator: ",")
                state["composer"] = fields
            } else {
                state["composer"] = [String: Any]()
            }
        } else {
            state["mail"] = [String: Any]()
        }
        let found = identifiers()
        state["buttons"] = accessibilityNodes().filter { $0.role == "AXButton" && !$0.label.isEmpty && !$0.frame.isEmpty }
            .map(\.label).joined(separator: " | ")
        state["selectedButtons"] = accessibilityNodes().filter { $0.selected && !$0.label.isEmpty }.map(\.label).joined(separator: " | ")
        state["defaults"] = [
            "planMode": UserDefaults.standard.string(forKey: "planMode") ?? "",
            "macWeekSpan": UserDefaults.standard.object(forKey: "macWeekSpan").map { "\($0)" } ?? "",
        ]
        state["availabilityPanel"] = MacNavigator.shared.showsAvailability
        state["rows"] = found.rows.joined(separator: ",")
        state["ids"] = found.ids.filter { $0.hasPrefix("mail.") && !$0.hasPrefix("mail.list.row.") }.joined(separator: " ")
        return state
    }

    func firstResponderDescription() -> String {
        guard let responder = window?.firstResponder else { return "(none)" }
        var text = String(describing: Swift.type(of: responder))
        var view = responder as? NSView
        // A field's editor is a text view the field made: name the field.
        if let editor = responder as? NSTextView, let field = editor.delegate as? NSView { view = field }
        var depth = 0
        while let current = view, depth < 8 {
            let id = current.accessibilityIdentifier()
            if !id.isEmpty { text += " id=\(id)"; break }
            view = current.superview
            depth += 1
        }
        return text
    }

    func environment() -> [String: Any] {
        var info: [String: Any] = [:]
        info["bundleIdentifier"] = Bundle.main.bundleIdentifier ?? "?"
        info["home"] = NSHomeDirectory()
        info["appSupport"] = AppSupport.directory.path
        info["arguments"] = ProcessInfo.processInfo.arguments
        info["activationPolicy"] = NSApp.activationPolicy().rawValue
        info["appIsActive"] = NSApp.isActive
        info["hasICloudEntitlement"] = AppCloud.hasContainerEntitlement
        info["googleAccountsRead"] = GoogleAccountStore.load().count
        info["windowIsVisible"] = window.isVisible
        info["windowNumber"] = window.windowNumber
        info["appWindows"] = NSApp.windows.map { "\(String(describing: Swift.type(of: $0))) visible=\($0.isVisible) title='\($0.title)'" }
        let pid = ProcessInfo.processInfo.processIdentifier
        let onScreen = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
        info["onScreenWindowsOfThisProcess"] = onScreen.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }.count
        info["accessibilityNodesAtStart"] = accessibilityNodes().count
        // The main menu, one line per item with a key equivalent: whether Edit and Format are there.
        var menuLines: [String] = []
        func walk(_ menu: NSMenu, _ path: String) {
            for item in menu.items where !item.isSeparatorItem {
                let name = path.isEmpty ? item.title : path + " > " + item.title
                if let sub = item.submenu { walk(sub, name) }
                else if !item.keyEquivalent.isEmpty {
                    menuLines.append("\(name) [\(item.keyEquivalent) mask=\(item.keyEquivalentModifierMask.rawValue >> 17)] action=\(item.action.map { NSStringFromSelector($0) } ?? "-") target=\(item.target == nil ? "responder chain" : "set")")
                }
            }
        }
        if let menu = NSApp.mainMenu { walk(menu, "") }
        info["mainMenu"] = menuLines
        return info
    }

    // MARK: Flattening, for `expect`

    static func flatten(_ value: Any, prefix: String = "") -> [String: String] {
        var result: [String: String] = [:]
        if let dictionary = value as? [String: Any] {
            for (key, inner) in dictionary {
                let name = prefix.isEmpty ? key : prefix + "." + key
                for (innerKey, text) in flatten(inner, prefix: name) { result[innerKey] = text }
            }
        } else if let array = value as? [Any] {
            result[prefix] = array.map { "\($0)" }.joined(separator: ",")
        } else {
            result[prefix] = "\(value)"
        }
        return result
    }

    static func oneLine(_ state: [String: Any]) -> String {
        let flat = flatten(state)
        let wanted = ["section", "mail.place", "mail.cursor", "mail.open", "mail.title", "mail.counts.inbox", "mail.counts.starred",
                      "toast", "composer.title", "composer.body", "composer.toText", "composer.subject", "composer.queued",
                      "firstResponder", "windowSize", "mail.showsPane"]
        return wanted.compactMap { key in flat[key].flatMap { $0.isEmpty ? nil : "\(key)=\($0)" } }.joined(separator: " | ")
    }
}
#endif
