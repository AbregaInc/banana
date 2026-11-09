import Foundation

// The decisions behind the app's one navigation layer (docs/design/BOTTOM-BAR-SHELL.md): which
// pages the switcher (phone) and the rail (iPad, Mac) list, what the "Search or ask" field shows,
// and where the podcast player sits. Pure, so they are tested without a screen.

/// A page the switcher or the rail opens. Body is Workouts and Food together, as the phone's tab
/// was; on a wide screen it opens whichever of the two was looked at last.
enum ShellPage: String, CaseIterable, Identifiable, Sendable {
    case plan, mail, body, notes, library, review, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .plan: "Plan"
        case .mail: "Mail"
        case .body: "Body"
        case .notes: "Notes"
        case .library: "Library"
        case .review: "Review"
        case .settings: "Settings"
        }
    }

    /// Outline symbols: the switcher and the rail draw them on round glass buttons. Taken from
    /// the sections' own table (`AppSection.outlineSymbol`; Body's from `BodyPage`), never a
    /// table of their own.
    var symbol: String {
        switch self {
        case .plan: AppSection.plan.outlineSymbol
        case .mail: AppSection.mail.outlineSymbol
        case .body: BodyPage.symbol.replacingOccurrences(of: ".fill", with: "")
        case .notes: AppSection.notes.outlineSymbol
        case .library: AppSection.library.outlineSymbol
        case .review: AppSection.review.outlineSymbol
        case .settings: AppSection.settings.outlineSymbol
        }
    }

    /// The rail's pages. On the Mac, Settings is the app menu's (⌘,), its own window as in every
    /// Mac app, not a rail button (owner, 9 Nov 2026); an iPad keeps it at the rail's foot.
    static func rail(_ on: Modules, mac: Bool) -> [ShellPage] {
        mac ? listed(on).filter { $0 != .settings } : listed(on)
    }

    /// The page lit in the rail or the switcher while `section` shows, on every device. A section
    /// with no page of its own (Routines, opened from "…") lights none: lighting Plan said the
    /// person was on Plan.
    static func showing(_ section: AppSection) -> ShellPage? {
        switch section {
        case .plan: .plan
        case .mail: .mail
        case .workouts, .nutrition: .body
        case .notes: .notes
        case .library: .library
        case .review, .sleep, .trends: .review
        case .settings: .settings
        default: nil
        }
    }

    /// What the page needs switched on to be listed. Plan and Settings are always there.
    struct Modules: Equatable, Sendable {
        var mail = false
        var workouts = false
        var food = false
        var notes = false
        var library = false
        /// Review has something to look back on (any module it covers is on).
        var review = false
    }

    /// The pages, in the order the switcher stacks them upwards from its button and the rail lists
    /// them downwards: the pages for doing, then looking back, then Settings (always last).
    static func listed(_ on: Modules) -> [ShellPage] {
        var pages: [ShellPage] = [.plan]
        if on.mail { pages.append(.mail) }
        if on.workouts || on.food { pages.append(.body) }
        if on.notes { pages.append(.notes) }
        if on.library { pages.append(.library) }
        if on.review { pages.append(.review) }
        pages.append(.settings)
        return pages
    }

    /// Review and Settings open over the page (a sheet on a phone); the rest are pages.
    var opensOver: Bool { self == .review || self == .settings }
}

/// Which navigation layer the shell has, by its width alone: the bar at the bottom wherever the
/// room is portrait-like (a phone either way, an iPad upright, any split or Slide Over), the rail
/// and one toolbar only where a landscape iPad's room is (the Mac's window always has the rail).
/// The approved images: an iPad upright is the phone's layout with wider pages.
enum ShellLayout: Equatable, Sendable {
    case bottomBar, rail

    /// Narrower than any iPad on its side (an iPad mini's is 1133 pt), wider than any upright
    /// iPad (a 13-inch is 1032 pt) and any phone on its side.
    static let railWidth: Double = 1_100

    static func of(width: Double) -> Self { width >= railWidth ? .rail : .bottomBar }

    /// The rail's own width on an iPad on its side: its round buttons with room either side.
    static let railColumn: Double = 80
    /// The Mac's rail is as wide as the window's three buttons with the same margin after the
    /// green one as before the red one (owner, 9 Nov 2026: 80 pt ended right at the green dot), so
    /// the rail's circles centre under the three buttons. Fixed width; it hides, not resizes.
    static let macRailColumn: Double = macWindowButtonsEnd + macWindowButtonsStart
    /// A rail button's circle.
    static let railButton: Double = 48
    /// The height of an iPad toolbar's controls (the paging group, Today, "…"), which start at
    /// the top of the safe area.
    static let barControl: Double = 44
    /// From the top of the safe area to the first rail button, on an iPad: its centre on the top
    /// bar's centre line. It was 16, which put the first circle 18 points below the bar's line.
    /// (The Mac's rail starts under the window's title bar, where the traffic lights are.)
    static let railTopInset: Double = (barControl - railButton) / 2
    /// Where the Mac window's close, minimise and zoom buttons start and end, from the window's
    /// left edge (measured on macOS 26/27: the red button's edge at 19 pt, the green's at 78 pt).
    static let macWindowButtonsStart: Double = 19
    static let macWindowButtonsEnd: Double = 78
}

/// What needs attention, as chips in today's row beside the reminders (`PlanAttentionChips`).
enum PlanAttentionLine {
    /// The chips a row shows: all of them, or where the row folds what doesn't fit (`limit`), one
    /// fewer and a "+N more" chip that opens the rest.
    static func shown(_ count: Int, limit: Int?) -> (chips: Int, more: Int) {
        guard let limit, count > limit else { return (count, 0) }
        let chips = max(0, limit - 1)
        return (chips, count - chips)
    }
}

/// The rail on an iPad on its side and on the Mac hides and shows like a system sidebar, and
/// stays as it was left (owner, 9 Nov 2026). One stored value for both.
enum ShellRailVisibility {
    static let key = "shellRailShown"
}

/// What the "Search or ask" field has under it.
enum ShellFieldMode: Equatable, Sendable {
    /// Nothing: the page.
    case idle
    /// Focused with nothing typed: what can be added, this page's kinds first.
    case add
    /// Words typed: "Ask Banana" (when there is an assistant), then what was found.
    case results

    static func of(text: String, focused: Bool) -> Self {
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .results }
        return focused ? .add : .idle
    }

    /// The switcher and the AI button step aside while the field is in use, so it is as wide as
    /// the bar.
    var hidesSideButtons: Bool { self != .idle }
}

/// Grouped results for the field. Each group is one existing search path's answer.
struct ShellSearchGroups<Item: Identifiable> {
    enum Group: String, CaseIterable, Sendable { case plan, mail, notes }

    var plan: [Item] = []
    var mail: [Item] = []
    var notes: [Item] = []

    /// How many of each group are listed. A group that has more says how many it has.
    static var shownPerGroup: Int { 5 }

    func items(_ group: Group) -> [Item] {
        switch group {
        case .plan: plan
        case .mail: mail
        case .notes: notes
        }
    }

    /// The groups with anything in them, in the field's order.
    var nonEmpty: [Group] { Group.allCases.filter { !items($0).isEmpty } }
    var isEmpty: Bool { nonEmpty.isEmpty }
}

enum ShellSearchRules {
    /// The words a search runs on: trimmed, and nothing for fewer than two characters (one letter
    /// matches most of a mailbox and tells nothing).
    static func query(_ text: String) -> String? {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return words.count >= 2 ? words : nil
    }

    /// How long typing waits before the searches run: under one frame of a fast typist's gap, so
    /// a burst of keys runs one search and not one per key.
    static let settle: Duration = .milliseconds(120)

    /// A plan item's title matches when every word of the query starts a word of the title.
    static func titleMatches(_ title: String, query: String) -> Bool {
        let wanted = words(query)
        guard !wanted.isEmpty else { return false }
        let have = words(title)
        return wanted.allSatisfy { word in have.contains { $0.hasPrefix(word) } }
    }

    private static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}

/// Where the podcast player is: a capsule above the bar, a small round artwork at the left end of
/// the field when hidden, or nowhere with nothing loaded.
enum ShellPlayerPlacement: Equatable, Sendable {
    case none, capsule, chip

    static func of(loaded: Bool, hidden: Bool, fieldInUse: Bool) -> Self {
        guard loaded else { return .none }
        // Typing needs the whole field and the room above the keyboard.
        if fieldInUse { return .none }
        return hidden ? .chip : .capsule
    }

    /// A newly loaded episode shows the capsule again, whatever was chosen for the last one. The
    /// first one seen (at launch) keeps what is set.
    static func hiddenAfterLoad(previous: String?, current: String?, hidden: Bool) -> Bool {
        guard let previous else { return hidden }
        return previous == current ? hidden : false
    }
}

/// What Plan's "‹" and "›" are called (`PlanStepButton`).
enum PlanTopRow {
    /// What "‹" and "›" say to VoiceOver: the period they step.
    static func stepLabels(days: Int) -> (previous: String, next: String) {
        switch days {
        case 1: ("Previous day", "Next day")
        case 7: ("Previous week", "Next week")
        default: ("Previous \(days) days", "Next \(days) days")
        }
    }
}

/// Where Plan's paging is, by shell: one place each for "‹ ›", the period and Today. Both shells
/// have the same group, the Mac's (8 Nov 2026): "‹", the period picker, "›", then Today, always
/// there and idle on the current period. The wide toolbar (an iPad on its side, the Mac) holds it
/// (`PlanPagingToolbar`); the bottom-bar shell (a phone, an iPad upright) draws it as its top row
/// (`PlanPagingRow`); where the row is narrow the forecast takes Today's place while Plan is on
/// the current period (Today does nothing there), and otherwise gives way; then the dates move
/// under the period's name, and only then go (`topRowLayouts`). Only outside both shells is there a date line under the bar: an iPad on its side
/// had it under the toolbar's group, a second "‹ ›", a second Today and the period named twice.
enum PlanPaging {
    enum Shell: Equatable, Sendable { case classic, bottomBar, wide }
    enum Control: Equatable, Sendable { case previous, period, next, today, dateLine }

    static func shell(bottomBar: Bool, wide: Bool) -> Shell {
        wide ? .wide : bottomBar ? .bottomBar : .classic
    }

    /// What a shell's Plan pages with, left to right. Today only away from the current period.
    static func controls(_ shell: Shell, isCurrent: Bool) -> [Control] {
        switch shell {
        case .wide, .bottomBar: [.previous, .period, .next] + (showsToday(isCurrent: isCurrent) ? [.today] : [])
        case .classic: [.period, .dateLine]
        }
    }

    /// The date line under the bar: only where the bar does not page.
    static func drawsDateLine(_ shell: Shell) -> Bool {
        controls(shell, isCurrent: true).contains(.dateLine)
    }

    /// Today is shown only away from the current period, on every device (owner, 9 Nov 2026):
    /// on the current period it does nothing, and an idle Today read as broken.
    static func showsToday(isCurrent: Bool) -> Bool { !isCurrent }

    /// One way the bottom-bar shell's top row can be laid out.
    struct TopRow: Equatable, Sendable {
        enum Dates: Equatable, Sendable { case beside, under, hidden }
        var dates: Dates
        var today: Bool
        var forecast: Bool
    }

    /// The top row's layouts, widest first; the row takes the first that fits (owner, 9 Nov 2026).
    /// Today follows `showsToday`. On the current period, where Today isn't shown, the forecast
    /// takes its place and stays at every width: the dates move under the period's name and then
    /// go before it does. Paged away, where Today and the forecast don't both fit, the forecast
    /// gives way first, then the dates move under the name, and on the narrowest go.
    static func topRowLayouts(isCurrent: Bool, hasForecast: Bool) -> [TopRow] {
        let today = showsToday(isCurrent: isCurrent)
        let widths: [TopRow.Dates] = [.beside, .under, .hidden]
        if isCurrent {
            let withForecast = hasForecast ? widths.map { TopRow(dates: $0, today: today, forecast: true) } : []
            return withForecast + widths.map { TopRow(dates: $0, today: today, forecast: false) }
        }
        var layouts: [TopRow] = []
        for dates in widths {
            if hasForecast, dates != .hidden { layouts.append(TopRow(dates: dates, today: today, forecast: true)) }
            layouts.append(TopRow(dates: dates, today: today, forecast: false))
        }
        return layouts
    }

    /// A pointer's tooltip; on the Mac with the key that does the same.
    static func help(_ text: String, key: String) -> String {
        #if os(macOS)
        "\(text) (\(key))"
        #else
        text
        #endif
    }

    /// The dates beside the period's name: "Wed, Nov 4" for a day; "Nov 2–8", "Oct 30–Nov 5" or
    /// "Dec 29, 2026–Jan 4, 2027" for more.
    static func dates(start: Date, days: Int, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        guard days > 1, let last = calendar.date(byAdding: .day, value: days - 1, to: start) else {
            return start.formatted(style.weekday(.abbreviated).month(.abbreviated).day())
        }
        let sameYear = calendar.component(.year, from: start) == calendar.component(.year, from: last)
        let sameMonth = sameYear && calendar.component(.month, from: start) == calendar.component(.month, from: last)
        if sameMonth {
            return "\(start.formatted(style.month(.abbreviated).day()))\u{2013}\(last.formatted(style.day()))"
        }
        if sameYear {
            return "\(start.formatted(style.month(.abbreviated).day()))\u{2013}\(last.formatted(style.month(.abbreviated).day()))"
        }
        let full = style.year().month(.abbreviated).day()
        return "\(start.formatted(full))\u{2013}\(last.formatted(full))"
    }
}

/// The pages' badges: what the old tab bar badged, page by page, from the same counts
/// (`ActionItems.Counts`); their sum on the closed switcher circle. Plan: overdue reminders.
/// Body: meals to log or check and doses due (the old Body tab's count). Mail: the unified
/// Inbox's unread conversations (the owner's ruling of 7 Nov 2026). No other page has one.
enum ShellBadge {
    /// `mail`: the unified Inbox's unread conversations (`ActionBadges.mailInbox`).
    static func count(_ page: ShellPage, _ counts: ActionItems.Counts, mail: Int = 0) -> Int {
        switch page {
        case .plan: counts.plan
        case .body: counts.nutrition
        case .mail: mail
        case .notes, .library, .review, .settings: 0
        }
    }

    /// The closed switcher's badge: the pages that are on, added up.
    static func total(_ pages: [ShellPage], _ counts: ActionItems.Counts, mail: Int = 0) -> Int {
        pages.reduce(0) { $0 + count($1, counts, mail: mail) }
    }

    /// What the red capsule says: nothing at zero, "99+" past 99.
    static func text(_ count: Int) -> String? {
        count <= 0 ? nil : count > 99 ? "99+" : "\(count)"
    }

    /// What VoiceOver adds: "3 need attention".
    static func spoken(_ count: Int) -> String? {
        count <= 0 ? nil : count == 1 ? "1 needs attention" : "\(count) need attention"
    }
}

/// How far a toast stands off the bottom of a page: above the bottom bar (and the player on it)
/// while the bar is there, on the pages it lies over; in a sheet, on the iPad on its side and on
/// the Mac there is no bar under it, and it keeps its own place.
enum ShellToastInset {
    static func bottom(barHeight: Double, barShown: Bool, onPage: Bool) -> Double {
        barShown && onPage ? barHeight : 0
    }
}
