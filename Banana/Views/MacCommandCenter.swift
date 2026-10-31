#if os(macOS)
import AppKit
import SwiftUI

/// Everything the keyboard, the ⌘K menu and the menu bar can ask the planner to do.
enum MacCalendarAction: Equatable {
    case today, nextPeriod, previousPeriod
    case goTo(Date)
    case dayView, weekView, span(Int)
    case newEvent, newTask, refresh, shareAvailability
    case nextEvent, previousEvent, closeInspector
    case respond(GoogleCalendarRSVP)
    case joinNextMeeting
}

extension Notification.Name {
    /// Paging and creation that only the visible planner can do; `object` is a `MacCalendarAction`.
    static let macCalendarAction = Notification.Name("macCalendarAction")
}

/// One place that carries out a `MacCalendarAction`, whoever asked for it.
@MainActor
final class MacCommandCenter: ObservableObject {
    static let shared = MacCommandCenter()

    @Published var showsCommandMenu = false
    @Published var showsShortcuts = false
    /// A reply that could not be sent, shown by the inspector.
    @Published var lastError: String?

    func perform(_ action: MacCalendarAction) {
        let nav = MacNavigator.shared
        switch action {
        case .dayView:
            nav.section = .plan
            UserDefaults.standard.set(PlanMode.day.rawValue, forKey: "planMode")
        case .weekView:
            nav.section = .plan
            UserDefaults.standard.set(PlanMode.week.rawValue, forKey: "planMode")
        case .span(let days):
            nav.section = .plan
            if days <= 1 {
                UserDefaults.standard.set(PlanMode.day.rawValue, forKey: "planMode")
            } else if let span = MacWeekSpan(rawValue: min(days, 7)) {
                UserDefaults.standard.set(PlanMode.week.rawValue, forKey: "planMode")
                UserDefaults.standard.set(span.rawValue, forKey: "macWeekSpan")
            }
        case .nextEvent, .previousEvent:
            stepInspectedEvent(forward: action == .nextEvent)
        case .closeInspector:
            nav.inspectedMeeting = nil
        case .respond(let response):
            guard let meeting = nav.inspectedMeeting else { NSSound.beep(); return }
            Task { await reply(to: meeting, with: response) }
        case .joinNextMeeting:
            JoinMeetingHotKey.joinNext()
        case .refresh:
            NotificationCenter.default.post(name: .macForceRefreshRequested, object: nil)
        case .today, .nextPeriod, .previousPeriod, .goTo, .newEvent, .newTask, .shareAvailability:
            nav.section = .plan
            NotificationCenter.default.post(name: .macCalendarAction, object: action)
        }
    }

    /// N / B: the next or previous meeting after the one being inspected (or after now).
    private func stepInspectedEvent(forward: Bool) {
        let nav = MacNavigator.shared
        let meetings = OccurrenceStore.shared.occurrences
            .compactMap(\.meeting)
            .sorted { $0.start < $1.start }
        let anchor = nav.inspectedMeeting?.start ?? Date()
        let pick = forward
            ? meetings.first { $0.start > anchor }
            : meetings.last { $0.start < anchor }
        guard let pick else { NSSound.beep(); return }
        nav.section = .plan
        nav.inspectedMeeting = pick
    }

    /// Reply to an invitation — from the inspector, the keyboard (E then Y/N/M) or an event's
    /// right-click menu.
    func reply(to meeting: MeetingInfo, with response: GoogleCalendarRSVP) async {
        if response == .declined {
            // Off the week at once, with Undo; the drawer closes with it.
            if MacNavigator.shared.inspectedMeeting?.eventID == meeting.eventID {
                MacNavigator.shared.inspectedMeeting = nil
            }
            await InvitationReply.decline(meeting)
            return
        }
        do {
            try await InvitationReply.send(response, to: meeting)
            lastError = nil
            ToastCenter.shared.notify(response.confirmation(title: meeting.title))
        } catch {
            lastError = error.localizedDescription
            ToastCenter.shared.notify("Couldn\u{2019}t reply: \(error.localizedDescription)")
            NSSound.beep()
        }
    }
}

/// Single-key shortcuts, Cron-style: T today, J/K next/previous, 1–7 days shown, D/W day/week,
/// N/B next/previous event, C new event, S share availability, ? shortcuts, E then Y/N/M to reply.
///
/// A local key monitor rather than SwiftUI key handlers: it sees keys whichever view has focus,
/// and it steps aside whenever a text field is being edited or a sheet is up — a single letter
/// must never be stolen from typing.
@MainActor
final class MacKeyMonitor {
    static let shared = MacKeyMonitor()
    private var monitor: Any?
    private var pendingPrefix: (key: String, at: Date)?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        // ⌘Z undoes the change the toast is offering — but never while typing: as a button
        // shortcut it took ⌘Z away from every text field for as long as a toast was up.
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "z",
           ToastCenter.shared.toast?.canUndo == true,
           !(event.window?.firstResponder is NSText) {
            ToastCenter.shared.undo()
            return true
        }
        // A chord the composer owns (⌘↩, ⇧⌘↩, ⌘B, ⇧⌘L and the rest, MAIL-UX 4.2.6), read from the
        // exact modifiers here and not from buttons' shortcuts, which SwiftUI matches without Shift.
        // Not while the command menu is up, and not for a key typed in the file panel: there the
        // same chords are somebody else's (`MailComposerChord.isOffered`).
        #if BANANA_UNRELEASED
        if event.type == .keyDown, MacNavigator.shared.section == .mail,
           MailComposerChord.isOffered(commandMenuShown: MacCommandCenter.shared.showsCommandMenu,
                                       inFilePanel: event.window is NSSavePanel),
           MailKeyDispatch.handleComposerChord(event) {
            return true
        }
        #endif
        guard modifiers.isEmpty else { return false }
        // A composer that has asked for the caret and has not got it owns every key until it has,
        // whoever has focus meanwhile, and a sheet's composer too: a reply that begins "Each" must
        // not mark the conversation Done (MAIL-UX K12). Mail is in front when one is open.
        #if BANANA_UNRELEASED
        if MacNavigator.shared.section == .mail, MailKeyDispatch.composerWaitsForTheCaret {
            return MailKeyDispatch.handle(event)
        }
        #endif
        guard let window = event.window, window.attachedSheet == nil,
              window.sheetParent == nil, !(window is NSPanel) else { return false }
        if window.firstResponder is NSText { return false }   // typing into a field
        let center = MacCommandCenter.shared
        guard !center.showsCommandMenu else { return false }
        // Mail in front: its keys, and only its keys. Every guard above has already stepped aside
        // for a text field, a sheet and the command menu, and a calendar key (T, D, W, C, a digit)
        // must not act on a calendar nobody is looking at — most of them would switch to Plan.
        // A key Mail does not know is passed on untouched. In every other section this line is
        // never reached, and the table below is exactly what it was.
        #if BANANA_UNRELEASED
        if MacNavigator.shared.section == .mail { return MailKeyDispatch.handle(event) }
        #endif
        if event.keyCode == 53 {   // Escape
            if MacNavigator.shared.inspectedMeeting != nil {
                center.perform(.closeInspector)
                return true
            }
            return false
        }
        guard let key = event.charactersIgnoringModifiers?.lowercased(), key.count == 1 else { return false }

        // Two-key sequences: E then Y/N/M replies to the inspected invitation.
        if let prefix = pendingPrefix, Date().timeIntervalSince(prefix.at) < 1.5, prefix.key == "e" {
            pendingPrefix = nil
            switch key {
            case "y": center.perform(.respond(.accepted)); return true
            case "n": center.perform(.respond(.declined)); return true
            case "m": center.perform(.respond(.tentative)); return true
            default: break
            }
        }
        pendingPrefix = nil

        switch key {
        case "t": center.perform(.today)
        case "j": center.perform(.nextPeriod)
        case "k": center.perform(.previousPeriod)
        case "d": center.perform(.dayView)
        case "w": center.perform(.weekView)
        case "1", "2", "3", "4", "5", "6", "7": center.perform(.span(Int(key) ?? 7))
        case "n": center.perform(.nextEvent)
        case "b": center.perform(.previousEvent)
        case "c": center.perform(.newEvent)
        case "s": center.perform(.shareAvailability)
        case "?", "/": center.showsShortcuts = true
        case "e":
            guard MacNavigator.shared.inspectedMeeting != nil else { return false }
            pendingPrefix = ("e", Date())
        default: return false
        }
        return true
    }
}

/// A command the ⌘K menu can run.
struct MacCommand: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let shortcut: String?
    let run: @MainActor () -> Void

    /// The group it is listed under when nothing is typed.
    var section: String {
        switch id {
        case "new-event", "new-task", "share", "booking-link": return "Create"
        case "join", "accept", "decline", "maybe", "next-event", "previous-event": return "Events"
        case "today", "next", "previous", "goto": return "Go to"
        case "day", "week": return "View"
        default:
            if id.hasPrefix("span-") { return "View" }
            if id.hasPrefix("section-") { return "Open" }
            return "Banana"
        }
    }

    static let sectionOrder = ["Go to", "Create", "Events", "View", "Open", "Banana"]

    /// Everything reachable from ⌘K. Order is the order shown for an empty query.
    @MainActor static var all: [MacCommand] {
        let center = MacCommandCenter.shared
        let nav = MacNavigator.shared
        var commands: [MacCommand] = [
            .init(id: "new-event", title: "New event", symbol: "plus", shortcut: "C") { center.perform(.newEvent) },
            .init(id: "share", title: "Share availability…", symbol: "calendar.badge.checkmark", shortcut: "S") { center.perform(.shareAvailability) },
            .init(id: "join", title: "Join next meeting", symbol: "video.fill", shortcut: "⌃⌘J") { center.perform(.joinNextMeeting) },
            .init(id: "today", title: "Go to today", symbol: "calendar", shortcut: "T") { center.perform(.today) },
            .init(id: "next", title: "Next week", symbol: "chevron.right", shortcut: "J") { center.perform(.nextPeriod) },
            .init(id: "previous", title: "Previous week", symbol: "chevron.left", shortcut: "K") { center.perform(.previousPeriod) },
            .init(id: "day", title: "Day view", symbol: "rectangle", shortcut: "D") { center.perform(.dayView) },
            .init(id: "week", title: "Week view", symbol: "rectangle.split.3x1", shortcut: "W") { center.perform(.weekView) },
            .init(id: "next-event", title: "Next event", symbol: "arrow.down", shortcut: "N") { center.perform(.nextEvent) },
            .init(id: "previous-event", title: "Previous event", symbol: "arrow.up", shortcut: "B") { center.perform(.previousEvent) },
            .init(id: "new-task", title: "New reminder", symbol: "checklist", shortcut: "⇧⌘N") { center.perform(.newTask) },
            .init(id: "refresh", title: "Refresh calendar", symbol: "arrow.clockwise", shortcut: "⌘R") { center.perform(.refresh) },
            .init(id: "briefing", title: "Morning briefing", symbol: "sun.max", shortcut: "⇧⌘M") { nav.showMorningBriefing = true },
            .init(id: "shortcuts", title: "Keyboard shortcuts", symbol: "keyboard", shortcut: "?") { center.showsShortcuts = true },
        ]
        // Only with a link to copy.
        if BookingCenter.shared.canShare {
            commands.insert(.init(id: "booking-link", title: "Copy booking link", symbol: "link", shortcut: "⇧⌘L") {
                BookingCenter.shared.copyLink()
            }, at: min(2, commands.count))
        }
        for days in 2...7 {
            commands.append(.init(id: "span-\(days)", title: "Show \(days) days", symbol: "calendar.day.timeline.left",
                                  shortcut: "\(days)") { center.perform(.span(days)) })
        }
        if nav.inspectedMeeting != nil {
            commands.insert(contentsOf: [
                .init(id: "accept", title: "Reply Yes to this invitation", symbol: "checkmark.circle", shortcut: "E Y") { center.perform(.respond(.accepted)) },
                .init(id: "decline", title: "Reply No to this invitation", symbol: "xmark.circle", shortcut: "E N") { center.perform(.respond(.declined)) },
                .init(id: "maybe", title: "Reply Maybe to this invitation", symbol: "questionmark.circle", shortcut: "E M") { center.perform(.respond(.tentative)) },
            ], at: 3)
        }
        for section in AppSection.macSidebar(with: ModuleStore.shared.choice) {
            commands.append(.init(id: "section-\(section.rawValue)", title: "Open \(section.title)",
                                  symbol: section.symbol, shortcut: nil) { nav.section = section })
        }
        return commands
    }
}

/// The ⌘K menu: type to filter, ↑/↓ to choose, Return to run. A date typed in plain words
/// ("next friday", "oct 12") offers to jump there.
struct MacCommandMenu: View {
    @ObservedObject private var center = MacCommandCenter.shared
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    private var matches: [MacCommand] {
        var result: [MacCommand] = []
        if let date = CommandMenuDateParser.date(in: query) {
            result.append(.init(id: "goto", title: "Go to \(date.formatted(date: .complete, time: .omitted))",
                                symbol: "arrow.right.circle", shortcut: nil) {
                MacCommandCenter.shared.perform(.goTo(date))
            })
        }
        let words = query.lowercased().split(separator: " ")
        result += MacCommand.all.filter { command in
            words.allSatisfy { command.title.lowercased().contains($0) }
        }
        return result
    }

    /// With nothing typed, commands are grouped; while typing, results are one ranked list.
    private func grouped(_ items: [MacCommand]) -> [(title: String?, rows: [(index: Int, command: MacCommand)])] {
        let indexed = Array(items.enumerated()).map { (index: $0.offset, command: $0.element) }
        guard query.isEmpty else { return [(nil, indexed)] }
        return MacCommand.sectionOrder.compactMap { title in
            let rows = indexed.filter { $0.command.section == title }
            return rows.isEmpty ? nil : (title, rows)
        }
    }

    /// Items in the order they are drawn, so ↑/↓ moves through what you see.
    private func ordered(_ items: [MacCommand]) -> [MacCommand] {
        grouped(items).flatMap { $0.rows.map(\.command) }
    }

    var body: some View {
        let items = ordered(matches)
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Type a command or a date…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
                    .onSubmit { run(items) }
                    .onKeyPress(.downArrow) { selection = min(selection + 1, max(items.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
                    .onKeyPress(.escape) { center.showsCommandMenu = false; return .handled }
                KeyCap(key: "Esc")
            }
            .padding(.horizontal, DS.Space.l)
            .frame(height: 48)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(grouped(items).enumerated()), id: \.offset) { _, group in
                            if let title = group.title {
                                Text(title.uppercased())
                                    .font(DS.Typeface.eyebrow)
                                    .tracking(DS.Typeface.eyebrowTracking)
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, DS.Space.m)
                                    .padding(.top, DS.Space.m)
                                    .padding(.bottom, DS.Space.xs)
                            }
                            ForEach(group.rows, id: \.command.id) { row in
                                let position = items.firstIndex { $0.id == row.command.id } ?? 0
                                commandRow(row.command, selected: position == selection)
                                    .onTapGesture { selection = position; run(items) }
                                    .onHover { if $0 { selection = position } }
                                    .id(position)
                            }
                        }
                        if items.isEmpty {
                            Text("No matching command")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(DS.Space.xl)
                        }
                    }
                    .padding(DS.Space.xs + 2)
                }
                .onChange(of: selection) { _, new in proxy.scrollTo(new) }
            }
            .frame(height: 340)
            Divider()
            HStack(spacing: DS.Space.m) {
                hint(["↑", "↓"], "Navigate")
                hint(["↵"], "Run")
                Spacer()
                Text(items.count == 1 ? "1 command" : "\(items.count) commands")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .padding(.horizontal, DS.Space.l)
            .frame(height: 36)
        }
        .frame(width: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
            .strokeBorder(Color.primary.opacity(DS.Tint.subtle), lineWidth: 0.5))
        .shadow(color: .black.opacity(DS.Tint.strong), radius: 30, y: 12)
        .onAppear { query = ""; selection = 0; focused = true }
        .onChange(of: query) { selection = 0 }
    }

    /// One command: icon, title, and its shortcut as key caps. Selection is a quiet fill, not
    /// a slab of accent colour — the accent marks the icon instead.
    private func commandRow(_ command: MacCommand, selected: Bool) -> some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: command.symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 18)
                .foregroundStyle(selected ? DS.Palette.accent : .secondary)
            Text(command.title)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
            Spacer(minLength: DS.Space.s)
            if let shortcut = command.shortcut {
                KeyCombo(combo: shortcut)
            }
        }
        .padding(.horizontal, DS.Space.m - 2)
        .frame(height: 32)
        .background(selected ? DS.Palette.selection : .clear,
                    in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        .contentShape(Rectangle())
    }

    private func hint(_ keys: [String], _ label: String) -> some View {
        HStack(spacing: DS.Space.xs) {
            ForEach(keys, id: \.self) { KeyCap(key: $0) }
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func run(_ items: [MacCommand]) {
        guard items.indices.contains(selection) else { return }
        center.showsCommandMenu = false
        items[selection].run()
    }
}

/// `?`: every shortcut, on one sheet.
struct MacShortcutsSheet: View {
    @ObservedObject private var center = MacCommandCenter.shared

    private let groups: [(String, [(String, String)])] = [
        ("Anywhere", [("⌘K", "Command menu"), ("?", "This list"), ("⌃⌘J", "Join the next meeting (from any app)"),
                      ("⌘N", "New event"), ("⇧⌘N", "New reminder"), ("⌘R", "Refresh calendar"),
                      ("⇧⌘L", "Copy booking link")]),
        ("Calendar", [("T", "Today"), ("J / K", "Next / previous week"), ("D / W", "Day / week view"),
                      ("2 – 7", "Number of days shown"), ("C", "New event"), ("S", "Share availability")]),
        ("Events", [("N / B", "Next / previous event"), ("E then Y / N / M", "Reply Yes / No / Maybe"),
                    ("Esc", "Close the event panel")]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Keyboard shortcuts").font(.system(size: 15, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, DS.Space.xl)
            .frame(height: 52)
            Divider()
            VStack(alignment: .leading, spacing: DS.Space.l) {
                ForEach(groups, id: \.0) { group in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(group.0.uppercased())
                            .font(DS.Typeface.eyebrow)
                            .tracking(DS.Typeface.eyebrowTracking)
                            .foregroundStyle(.tertiary)
                            .padding(.bottom, DS.Space.xs)
                        ForEach(group.1, id: \.0) { row in
                            // What it does on the left, the keys on the right — read the action,
                            // glance at the keys.
                            HStack {
                                Text(row.1).font(.system(size: 13))
                                Spacer(minLength: DS.Space.m)
                                KeyCombo(combo: row.0)
                            }
                            .frame(height: 30)
                            if row.0 != group.1.last?.0 { Divider().opacity(0.6) }
                        }
                    }
                }
            }
            .padding(DS.Space.xl)
        }
        .frame(width: 440)
        // Only looked at: the system's Done, where a Mac sheet puts it. Return closes.
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { center.showsShortcuts = false }
            }
        }
    }
}
#endif
