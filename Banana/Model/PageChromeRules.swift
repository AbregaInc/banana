import Foundation

/// The rules every page's controls follow, as far as they are decisions and not drawing
/// (10 Oct 2026; docs/design/DESIGN-SYSTEM.md, "One control for each job").
///
/// The author: the controls were "different … all over the place", and under that, "the problem is
/// that we [are] intermixing action and analysis". So the tabs are for doing (now and next), and
/// everything about the past is in one place, Review, opened by the chart button at the top left
/// of every tab: the corner hardest to reach, for the thing opened least.

/// A part of Review: one subject looked back on.
enum ReviewSubject: String, CaseIterable, Identifiable, Codable, Sendable {
    case fitness, sleep, food, listening
    var id: String { rawValue }

    var title: String {
        switch self {
        case .fitness: "Fitness"
        case .sleep: "Sleep"
        case .food: "Food"
        case .listening: "Listening"
        }
    }

    var symbol: String {
        switch self {
        case .fitness: "figure.run"
        case .sleep: "bed.double.fill"
        case .food: "fork.knife"
        case .listening: "headphones"
        }
    }

    /// Review's parts in the order a tab's chart button shows them: that tab's own subject
    /// first, the rest as they always are. Plan and Notes have nothing of their own to look
    /// back on, so they change nothing.
    static func ordered(for section: AppSection) -> [ReviewSubject] {
        guard let first = section.reviewSubject else { return allCases }
        return [first] + allCases.filter { $0 != first }
    }
}

extension AppSection {
    /// What this tab's chart button opens Review on.
    var reviewSubject: ReviewSubject? {
        switch self {
        case .workouts, .trends: .fitness
        case .sleep: .sleep
        case .nutrition: .food
        case .library: .listening
        case .plan, .mail, .notes, .routines, .settings, .review: nil
        }
    }
}

/// How far back Review looks: the app's one time-span switch.
enum ReviewSpan: String, CaseIterable, Identifiable, Codable, Sendable {
    case week, month, year
    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var granularity: RhythmGranularity {
        switch self {
        case .week: .week
        case .month: .month
        case .year: .year
        }
    }

    /// The rolling window the trend pages draw for this span.
    var trendWindow: TrendWindow { TrendWindow(granularity) }
}

/// What the date line under a page's top bar says. One wording for every page that has one.
enum DateLineWording {
    /// The name and, while on the current period, the dates beside it. Away from now the dates
    /// are the name: "Today · Sat, Oct 10" becomes "Fri, Oct 9".
    static func parts(current: String, dates: String, isCurrent: Bool) -> (name: String, dates: String?) {
        isCurrent ? (current, dates) : (dates, nil)
    }

    /// Which way a horizontal swipe on the line steps: left goes forward, on every page. (The
    /// plan went forward and Workouts went back.)
    static func step(forSwipe translation: CGFloat) -> Int {
        translation < 0 ? 1 : -1
    }
}

/// The sums Review's lines are made of.
enum ReviewMath {
    /// One total per calendar day from `start` up to `end`, in order, days with nothing included.
    static func perDay(_ items: [(date: Date, value: Double)], from start: Date, to end: Date,
                       calendar: Calendar = .current) -> [(day: Date, value: Double)] {
        var totals: [Date: Double] = [:]
        for item in items where item.date >= start && item.date < end {
            totals[calendar.startOfDay(for: item.date), default: 0] += item.value
        }
        var days: [(day: Date, value: Double)] = []
        var day = calendar.startOfDay(for: start)
        while day < end {
            days.append((day, totals[day] ?? 0))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return days
    }

    /// The average over the days that have anything: a day nothing was logged on is a day not
    /// logged, not a day of nothing eaten.
    static func averageOfLoggedDays(_ values: [Double]) -> Double? {
        let logged = values.filter { $0 > 0 }
        return logged.isEmpty ? nil : logged.reduce(0, +) / Double(logged.count)
    }

    /// One value per month: the average of that month's logged days, dated at its first day.
    static func monthlyAverages(_ days: [(day: Date, value: Double)],
                                calendar: Calendar = .current) -> [(day: Date, value: Double)] {
        let grouped = Dictionary(grouping: days) { calendar.dateInterval(of: .month, for: $0.day)?.start ?? $0.day }
        return grouped.map { (day: $0.key, value: averageOfLoggedDays($0.value.map(\.value)) ?? 0) }
            .sorted { $0.day < $1.day }
    }

    /// "7h 5m", "45m" (`DS.duration`).
    static func clock(minutes: Double) -> String { DS.duration(minutes: minutes) }
}

/// Everything the + can start. Where the tab bar is at the bottom the + sits on its row and is
/// on screen on every page, so it opens one list of all of these, the page's own first. (A +
/// that only knew its page did nothing on Workouts or on a page pushed over a tab.)
enum AddKind: String, CaseIterable, Identifiable, Sendable {
    case event, reminder, alarm
    case recentMeal, describeMeal, searchFood, scanFood, mealPhotos, mealByHand, groceries, supplement
    case recordNote, writeNote
    case podcast

    var id: String { rawValue }

    var title: String {
        switch self {
        case .event: "Event"
        case .reminder: "Reminder"
        case .alarm: "Alarm"
        case .recentMeal: "Recent meals"
        case .describeMeal: "Describe"
        case .searchFood: "Search"
        case .scanFood: "Scan"
        case .mealPhotos: "Photos"
        case .mealByHand: "By hand"
        case .groceries: "Groceries"
        case .supplement: "Something you take"
        case .recordNote: "Record"
        case .writeNote: "Write"
        case .podcast: "Podcast"
        }
    }

    var symbol: String {
        switch self {
        case .event: "calendar.badge.plus"
        case .reminder: "checklist"
        case .alarm: "alarm"
        case .recentMeal: "clock.arrow.circlepath"
        case .describeMeal: "text.bubble"
        case .searchFood: "magnifyingglass"
        case .scanFood: "barcode.viewfinder"
        case .mealPhotos: "photo.on.rectangle.angled"
        case .mealByHand: "list.bullet.rectangle"
        case .groceries: "cart"
        case .supplement: "pills"
        case .recordNote: "mic.fill"
        case .writeNote: "square.and.pencil"
        case .podcast: "antenna.radiowaves.left.and.right"
        }
    }

    /// The tab that owns it: picking it goes there, and that page opens what it always opened.
    var section: AppSection {
        switch self {
        case .event, .reminder, .alarm: .plan
        case .recentMeal, .describeMeal, .searchFood, .scanFood, .mealPhotos, .mealByHand, .groceries, .supplement: .nutrition
        case .recordNote, .writeNote: .notes
        case .podcast: .library
        }
    }

    /// Which half of Nutrition it belongs to, as `ShellState.nutritionSection` names them.
    var nutritionSection: String? {
        switch self {
        case .recentMeal, .describeMeal, .searchFood, .scanFood, .mealPhotos, .mealByHand, .groceries: "Food"
        case .supplement: "Taken"
        default: nil
        }
    }

    /// The names the pages' own menus gave these, kept.
    var identifier: String {
        switch self {
        case .event: "mobile.week.add.event"
        case .reminder: "mobile.week.newTask"
        case .alarm: "mobile.week.add.alarm"
        case .recentMeal: "wellness.recentMeals"
        case .describeMeal: "wellness.textMeal"
        case .searchFood: "wellness.searchFood"
        case .scanFood: "wellness.barcodeMeal"
        case .mealPhotos: "wellness.photoMeal"
        case .mealByHand: "wellness.manualMeal"
        case .groceries: "add.groceries"
        case .supplement: "add.supplement"
        case .recordNote: "notes.capture"
        case .writeNote: "notes.write"
        case .podcast: "add.podcast"
        }
    }

    /// The list, a group a tab, the tab being looked at first and the rest in the tab bar's order.
    static func groups(for current: AppSection) -> [(section: AppSection, kinds: [AddKind])] {
        let order: [AppSection] = [.plan, .nutrition, .notes, .library]
        let sections = order.contains(current) ? [current] + order.filter { $0 != current } : order
        return sections.map { section in (section, allCases.filter { $0.section == section }) }
    }
}

/// Body's views on a phone, where Workouts and Nutrition share a place in the tab bar: one
/// switch across both pages, where each page's title was, and not one switch inside another.
enum BodyPage: String, CaseIterable, Sendable {
    case workouts = "Workouts", food = "Food", taken = "Taken"

    /// A wide page shows Food and Taken together, so there are two to choose from.
    static func choices(wide: Bool) -> [BodyPage] { wide ? [.workouts, .food] : allCases }

    /// What is showing, from the section that is open and Nutrition's half
    /// (`ShellState.nutritionSection`).
    init(section: AppSection, nutritionSection: String?, wide: Bool = false) {
        if section.tabBarHome == .nutrition {
            self = !wide && nutritionSection == BodyPage.taken.rawValue ? .taken : .food
        } else {
            self = .workouts
        }
    }

    var section: AppSection { self == .workouts ? .workouts : .nutrition }

    /// The half of Nutrition to open, as `ShellState.nutritionSection` names them.
    var nutritionSection: String? { self == .workouts ? nil : rawValue }

    func title(wide: Bool) -> String { wide && self == .food ? AppSection.nutrition.title : rawValue }

    /// The tab's own name and symbol.
    static let title = "Body"
    static let symbol = "heart.fill"

    /// Whether `section` is shown under the Body tab.
    static func holds(_ section: AppSection) -> Bool { section == .workouts || section == .nutrition }
}
