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

    /// The rail's own width, on an iPad on its side and on the Mac alike: its round buttons with
    /// room either side, and on the Mac the window's three buttons above it (they end about 76 pt
    /// from the edge), so the toolbar starts right after both. Fixed: the Mac's sidebar column is
    /// pinned to it and cannot be dragged wider or collapsed.
    static let railColumn: Double = 80
    /// A rail button's circle.
    static let railButton: Double = 48
    /// Where the Mac window's close, minimise and zoom buttons end, from the window's left edge.
    static let macWindowButtonsEnd: Double = 76
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

/// Plan's top row in the bottom-bar layout: the title (with today's date and the weather beside
/// it on the current period), then "‹ ›" with Today between them away from now, then "…". On a
/// narrow phone the weather gives way first, then Today's word for its icon, and only then the
/// title's size (WeekView's `mobileTopRow`).
enum PlanTopRow {
    /// Today sits between "‹" and "›" while the view is away from the current period.
    static func showsToday(isCurrent: Bool) -> Bool { !isCurrent }

    /// What "‹" and "›" say to VoiceOver: the period they step.
    static func stepLabels(days: Int) -> (previous: String, next: String) {
        switch days {
        case 1: ("Previous day", "Next day")
        case 7: ("Previous week", "Next week")
        default: ("Previous \(days) days", "Next \(days) days")
        }
    }
}

/// The pages' badges: what the old tab bar badged, page by page, from the same counts
/// (`ActionItems.Counts`); their sum on the closed switcher circle. Plan: overdue reminders.
/// Body: meals to log or check and doses due (the old Body tab's count). No other page had one.
enum ShellBadge {
    static func count(_ page: ShellPage, _ counts: ActionItems.Counts) -> Int {
        switch page {
        case .plan: counts.plan
        case .body: counts.nutrition
        case .mail, .notes, .library, .review, .settings: 0
        }
    }

    /// The closed switcher's badge: the pages that are on, added up.
    static func total(_ pages: [ShellPage], _ counts: ActionItems.Counts) -> Int {
        pages.reduce(0) { $0 + count($1, counts) }
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
