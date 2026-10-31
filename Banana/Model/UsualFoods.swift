import Foundation

/// The foods you usually have around a time of day, from every meal you've logged — not only the
/// packages you've scanned (docs/design/MEAL-LEARNING.md §3). It names things for the model
/// ("Foods they often have…"), and offers them as "Usually around now" when adding a meal.
/// MacroFactor's hourly go-tos, from your own log. Pure.
enum UsualFoods {
    /// Had within this long of the time of day, a meal counts fully; it fades to nothing by `reach`.
    static let around: TimeInterval = 90 * 60
    static let reach: TimeInterval = 3 * 3_600
    /// How far back to look. Recency weighs within it (`MyFoods.halfLife`).
    static let lookback = 120
    /// Had once is a meal; twice is a habit.
    static let minimumTimes = 2

    struct Food: Hashable, Sendable {
        /// As it was last called.
        var name: String
        var key: String
        var score: Double
        var times: Int
        /// The last time it was logged: its numbers, already checked.
        var last: MealItem
        /// How much, usually: the recency-weighted middle of the weights logged.
        var usualGrams: Double?

        /// It again, at the usual amount, as a new item.
        var item: MealItem {
            var item = last
            if let usualGrams, let grams = item.grams, grams > 0, abs(usualGrams - grams) > 0.5 {
                item = item.withGrams(usualGrams)
                item.serving = GroundedFoodEstimate.serving("", grams: usualGrams)
            }
            item.id = UUID()
            item.confidence = 1
            return item
        }
    }

    /// Foods had at least twice, most usual around `date`'s time of day first — and, among them by
    /// how recently, what you've bought lately and not had since (`MyFoods.justBought`): a
    /// purchase today counts as much as having it once at this time today.
    static func foods(at date: Date, meals: [MealEntry], myFoods: [MyFood] = [], now: Date = Date(),
                      calendar: Calendar = .current) -> [Food] {
        let had = logged(at: date, meals: meals, now: now, calendar: calendar)
        let keys = Set(had.map(\.key))
        let bought = MyFoods.justBought(myFoods, now: now).compactMap { food -> Food? in
            let key = MyFoods.key(food.name)
            guard !key.isEmpty, !keys.contains(key) else { return nil }
            let grams = MyFoods.typicalGrams(food, now: now) ?? food.servingGrams
            let age = max(0, now.timeIntervalSince(food.lastBought)) / 86_400
            return Food(name: food.name, key: key, score: pow(0.5, age / MyFoods.purchaseHalfLife), times: food.uses.count,
                        last: ScanCorrection.item(food: food, grams: grams), usualGrams: nil)
        }
        return (had + bought).sorted { $0.score != $1.score ? $0.score > $1.score : $0.name < $1.name }
    }

    private static func logged(at date: Date, meals: [MealEntry], now: Date, calendar: Calendar) -> [Food] {
        let earliest = calendar.date(byAdding: .day, value: -lookback, to: now) ?? now
        struct Tally {
            var score = 0.0
            var times = 0
            var last: (date: Date, item: MealItem)?
            var weights: [(grams: Double, weight: Double)] = []
        }
        var tallies: [String: Tally] = [:]
        let target = secondsIntoDay(date, calendar: calendar)
        for meal in meals where meal.date >= earliest && meal.date <= now {
            let closeness = timeWeight(abs(secondsIntoDay(meal.date, calendar: calendar) - target))
            let recency = pow(0.5, max(0, now.timeIntervalSince(meal.date)) / 86_400 / MyFoods.halfLife)
            for item in meal.items {
                let key = MyFoods.key(item.name)
                guard !key.isEmpty else { continue }
                var tally = tallies[key] ?? Tally()
                tally.times += 1
                tally.score += closeness * recency
                if tally.last.map({ $0.date < meal.date }) ?? true { tally.last = (meal.date, item) }
                if let grams = item.grams, grams > 0 { tally.weights.append((grams, recency)) }
                tallies[key] = tally
            }
        }
        return tallies.compactMap { key, tally -> Food? in
            guard tally.times >= minimumTimes, tally.score > 0, let last = tally.last else { return nil }
            return Food(name: last.item.name, key: key, score: tally.score, times: tally.times, last: last.item,
                        usualGrams: weightedMedian(tally.weights))
        }
        .sorted { $0.score != $1.score ? $0.score > $1.score : $0.name < $1.name }
    }

    /// The names the model is told to use, most usual around this time first, then your scanned
    /// foods (`MyFoods.usualNames`) — at most `limit`: the small model's context is 4,096 tokens.
    static func names(at date: Date, meals: [MealEntry], myFoods: [MyFood], limit: Int = 12,
                      now: Date = Date(), calendar: Calendar = .current) -> [String] {
        var names: [String] = []
        var seen = Set<String>()
        let candidates = foods(at: date, meals: meals, myFoods: myFoods, now: now, calendar: calendar).map(\.name)
            + MyFoods.usualNames(myFoods, now: now)
        for name in candidates where names.count < limit {
            if seen.insert(MyFoods.key(name)).inserted { names.append(name) }
        }
        return names
    }

    /// 1 within `around` of the time of day, falling to 0 at `reach`.
    static func timeWeight(_ apart: TimeInterval) -> Double {
        let day: TimeInterval = 86_400
        let distance = min(apart.truncatingRemainder(dividingBy: day), day - apart.truncatingRemainder(dividingBy: day))
        if distance <= around { return 1 }
        if distance >= reach { return 0 }
        return 1 - (distance - around) / (reach - around)
    }

    private static func secondsIntoDay(_ date: Date, calendar: Calendar) -> TimeInterval {
        date.timeIntervalSince(calendar.startOfDay(for: date))
    }

    private static func weightedMedian(_ values: [(grams: Double, weight: Double)]) -> Double? {
        let sorted = values.sorted { $0.grams < $1.grams }
        let total = sorted.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return nil }
        var running = 0.0
        for value in sorted {
            running += value.weight
            if running >= total / 2 { return value.grams }
        }
        return sorted.last?.grams
    }
}
