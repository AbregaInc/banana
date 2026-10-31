import Foundation

/// Every top-level surface in the app, shared between the iOS tab bar and the Mac sidebar so
/// the two never drift into naming the same place differently (that's how "Rhythm" on Mac and
/// "Workouts" on iOS happened). Each platform picks its own subset and order via `iOSTabs` /
/// `macSidebar` rather than hand-listing cases at the call site.
enum AppSection: String, Codable, CaseIterable, Identifiable {
    case plan, mail, workouts, sleep, trends, nutrition, notes, routines, library, review, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .plan: "Plan"
        case .mail: "Email"
        case .workouts: "Workouts"
        case .sleep: "Sleep"
        case .trends: "Trends"
        case .nutrition: "Food"
        case .notes: "Notes"
        case .routines: "Routines"
        case .library: "Library"
        case .review: "Review"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .plan: "sun.max.fill"
        case .mail: "envelope.fill"
        case .workouts: "figure.run"
        case .sleep: "bed.double.fill"
        case .trends: "chart.line.uptrend.xyaxis"
        case .nutrition: "fork.knife"
        case .notes: "quote.bubble.fill"
        case .routines: "repeat"
        case .library: "square.stack.fill"
        case .review: "chart.bar.fill"
        case .settings: "gearshape.fill"
        }
    }

    /// Mail is reachable in the normal phone UI. The system provides overflow when
    /// the compact tab bar cannot display every primary section at once.
    static let iOSTabs: [AppSection] = [.plan, .mail, .workouts, .nutrition, .notes, .library]

    /// The tab a sidebar-only section lives under when there's only a tab bar: Review opens
    /// from the chart button, Routines and Settings from "…", on every tab, so they fall back
    /// to Plan. Sleep and Trends are parts of Review now (`sidebarHome`).
    var tabBarHome: AppSection {
        switch self {
        case .sleep, .trends, .review: .workouts
        case .routines, .settings: .plan
        default: self
        }
    }

    /// Where a stored section shows when there is a sidebar: Sleep and Trends had rows of their
    /// own and are inside Review now, so a place kept from before opens Review.
    var sidebarHome: AppSection {
        switch self {
        case .sleep, .trends: .review
        default: self
        }
    }

    /// The sidebar on the Mac and the iPad, in list order: the pages for doing, then Review for
    /// looking back, then Settings.
    static let sidebar: [AppSection] = [.plan, .mail, .workouts, .nutrition, .notes, .routines, .library, .review, .settings]
    static var macSidebar: [AppSection] { sidebar.filter { $0 != .settings } }

    /// The section a sidebar row stands for, from the id its List selected it by (rows are
    /// selected by their own ids, never a tag a later modifier can hide — see MacRootView). No
    /// row, or an id that names none, keeps the section there is.
    static func chosen(_ id: ID?, current: AppSection) -> AppSection {
        id.flatMap(AppSection.init(rawValue:)) ?? current
    }

    /// Sidebar rows that get a ⌘-number shortcut. Settings is reached from the sidebar or ⌘,
    /// like every other Mac app, not a number key. Nine at most: a tenth has no number key.
    static var macShortcuts: [AppSection] { Array(macSidebar.filter { $0 != .settings }.prefix(9)) }

    /// `--mac-section rhythm` predates the Workouts rename; keep the old argument working for one
    /// release instead of breaking anyone's saved debug invocation.
    init?(legacyRawValue: String) {
        switch legacyRawValue {
        case "rhythm": self = .workouts
        default: return nil
        }
    }
}
