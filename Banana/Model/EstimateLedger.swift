import Foundation

/// How each estimate turned out: every food Banana first proposed, paired with what was logged
/// (docs/design/MEAL-LEARNING.md §1). Read off the meal log whenever it's needed, like My foods'
/// uses: nothing to store or sync, so it can't drift from the meals. Pure.
enum EstimateLedger {
    enum Outcome: String, Sendable {
        /// Logged as proposed.
        case accepted
        /// Its amount, numbers or name were changed.
        case edited
        /// Replaced by a package that was scanned (`MyFood`).
        case scanned
        /// Its amount given when asked (`PortionQuestion`), whether or not it moved.
        case answered
        /// Taken out: the estimate named a food that wasn't there.
        case removed
        /// Put in by the person: the estimate missed it.
        case added
    }

    struct Row: Hashable, Sendable {
        var mealID: UUID
        var date: Date
        var from: MealEstimate.From
        var estimator: Int?
        var measured: Bool
        /// Nil when the person added the food.
        var estimated: EstimatedFood?
        /// Nil when the food was taken out.
        var logged: MealItem?
        var outcome: Outcome

        /// The person changed it — the only rows that teach. An estimate left alone may be right,
        /// or may just not have been looked at.
        var teaches: Bool { outcome == .edited || outcome == .scanned || outcome == .answered }

        /// The model's own gram guess, before any learned factor.
        var guessedGrams: Double? {
            guard let estimated, let grams = estimated.grams, grams > 0 else { return nil }
            if estimated.amount == .learned, let factor = estimated.factor, factor > 0 { return grams / factor }
            return estimated.amount == .guess ? grams : nil
        }

        /// Logged grams ÷ the model's guess: how much more or less was really eaten.
        var guessRatio: Double? {
            guard let guess = guessedGrams, let grams = logged?.grams, grams > 0 else { return nil }
            return grams / guess
        }
    }

    /// Changes smaller than this are rounding, not a correction.
    static let tolerance = 0.03

    static func rows(_ meals: [MealEntry]) -> [Row] {
        meals.flatMap { meal -> [Row] in
            guard let estimate = meal.estimate, !estimate.foods.isEmpty else { return [] }
            func row(_ estimated: EstimatedFood?, _ logged: MealItem?, _ outcome: Outcome) -> Row {
                Row(mealID: meal.id, date: meal.date, from: estimate.from, estimator: estimate.estimator,
                    measured: estimate.measured, estimated: estimated, logged: logged, outcome: outcome)
            }
            let logged = Dictionary(meal.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let estimatedIDs = Set(estimate.foods.map(\.itemID))
            var rows = estimate.foods.map { food in
                logged[food.itemID].map { item in
                    let outcome = outcome(estimated: food, logged: item)
                    return row(food, item, outcome == .accepted && estimate.confirmed.contains(food.itemID) ? .answered : outcome)
                } ?? row(food, nil, .removed)
            }
            rows += meal.items.filter { !estimatedIDs.contains($0.id) }.map { row(nil, $0, .added) }
            return rows
        }
    }

    static func outcome(estimated: EstimatedFood, logged: MealItem) -> Outcome {
        let reference = logged.reference?.id
        if let reference, reference.hasPrefix(MyFoods.referencePrefix), reference != estimated.referenceID {
            return .scanned
        }
        func moved(_ a: Double?, _ b: Double?) -> Bool {
            guard let a, let b else { return (a == nil) != (b == nil) }
            return abs(a - b) > max(abs(a), abs(b), 1) * tolerance
        }
        let renamed = MyFoods.key(logged.name) != MyFoods.key(estimated.name)
        if renamed || moved(estimated.grams, logged.grams)
            || moved(estimated.calories, logged.macros.sanitized.calories) {
            return .edited
        }
        return .accepted
    }

    // MARK: - How it's going

    struct Summary: Equatable, Sendable {
        var meals = 0
        /// Meals whose calories the person changed.
        var changedMeals = 0
        /// The middle of how far each meal's calories moved, as a fraction of what was logged.
        var medianChange: Double?
        /// The middle of the signed change: below zero, estimates ran low.
        var medianBias: Double?
        /// Foods the estimate missed, and named that weren't there, per food logged.
        var missedRate = 0.0
        var removedRate = 0.0
    }

    /// The last `meals` estimated meals: how much they were changed, and which way.
    static func summary(_ rows: [Row], meals limit: Int = 30) -> Summary {
        let byMeal = Dictionary(grouping: rows, by: \.mealID)
        let recent = byMeal.values.sorted { ($0.first?.date ?? .distantPast) > ($1.first?.date ?? .distantPast) }
            .prefix(limit)
        guard !recent.isEmpty else { return Summary() }
        var changes: [Double] = []
        var signed: [Double] = []
        var foods = 0, missed = 0, removed = 0, changed = 0
        for meal in recent {
            let estimated = meal.compactMap(\.estimated).reduce(0) { $0 + $1.calories }
            let logged = meal.compactMap(\.logged).reduce(0) { $0 + $1.macros.sanitized.calories }
            if logged > 0 {
                let change = (logged - estimated) / logged
                changes.append(abs(change))
                signed.append(-change)
                if abs(change) > tolerance { changed += 1 }
            }
            foods += meal.filter { $0.logged != nil }.count
            missed += meal.filter { $0.outcome == .added }.count
            removed += meal.filter { $0.outcome == .removed }.count
        }
        return Summary(meals: recent.count, changedMeals: changed, medianChange: median(changes),
                       medianBias: median(signed),
                       missedRate: foods > 0 ? Double(missed) / Double(foods) : 0,
                       removedRate: foods > 0 ? Double(removed) / Double(foods) : 0)
    }

    /// "Last 30 meals: you changed 9, by 18% in the middle; estimates ran 12% low. 1 in 8 foods
    /// missed." Nil before there's anything to say.
    static func line(_ summary: Summary) -> String? {
        guard summary.meals > 0, let change = summary.medianChange else { return nil }
        var parts = ["Last \(summary.meals) meal\(summary.meals == 1 ? "" : "s"): you changed \(summary.changedMeals)"]
        if summary.changedMeals > 0 { parts[0] += ", by \(percent(change)) in the middle" }
        if let bias = summary.medianBias, abs(bias) >= 0.05 {
            parts.append("estimates ran \(percent(abs(bias))) \(bias < 0 ? "low" : "high")")
        }
        var line = parts.joined(separator: "; ") + "."
        if summary.missedRate >= 0.05 {
            line += " About 1 in \(max(2, Int((1 / summary.missedRate).rounded()))) foods was missed."
        }
        return line
    }

    static func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }

    static func median(_ values: [Double]) -> Double? {
        let sorted = values.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else { return nil }
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }
}
