import Foundation

/// A meal's part of the day. The Plan's own: reminders and Taken items can be due after one
/// (`TimingAnchor.Moment.meal`), with or without the Food module. The meals people name, and when
/// each usually happens.
enum MealTextPart: String, CaseIterable, Codable, Sendable {
    case breakfast, brunch, lunch, snack, dinner, dessert, lateNight

    var title: String {
        switch self {
        case .breakfast: "Breakfast"
        case .brunch: "Brunch"
        case .lunch: "Lunch"
        case .snack: "Snack"
        case .dinner: "Dinner"
        case .dessert: "Dessert"
        case .lateNight: "Late night"
        }
    }

    /// The time a meal of this kind is filed at when nothing says otherwise.
    var clock: (hour: Int, minute: Int) {
        switch self {
        case .breakfast: (8, 0)
        case .brunch: (10, 30)
        case .lunch: (12, 30)
        case .snack: (15, 30)
        case .dinner: (19, 0)
        case .dessert: (20, 30)
        case .lateNight: (22, 30)
        }
    }

    /// The words that name it, longest first so "late night" wins over "night".
    var words: [String] {
        switch self {
        case .breakfast: ["breakfast", "brekkie"]
        case .brunch: ["brunch"]
        case .lunch: ["lunch", "lunchtime"]
        case .snack: ["afternoon snack", "snacks", "snack"]
        case .dinner: ["dinner", "supper", "tea time"]
        case .dessert: ["dessert", "pudding"]
        case .lateNight: ["late night", "late-night", "midnight snack"]
        }
    }
}
