import Foundation

/// How much more or less of a food you really have than the model guesses — what trip learning
/// does with travel times (actual ÷ predicted, the median), for portions
/// (docs/design/MEAL-LEARNING.md §2). Learned only from amounts you changed or scanned, applied
/// only to an amount the model guessed. Pure.
enum LearnedPortions {
    /// The newest this many corrections of a food count: enough for a steady middle, recent
    /// enough to follow a habit that changed.
    static let window = 20
    /// Corrections needed before a food's own factor is used; a category needs more, being
    /// looser ("Rice" covers a lot of plates).
    static let minimumForFood = 3
    static let minimumForCategory = 5
    /// A correction beyond this is a different food or portion, not a habit, and is left out.
    static let plausible = 0.4...2.5
    /// A factor this close to 1 changes nothing worth saying.
    static let negligible = 0.9...1.1

    struct Factor: Hashable, Sendable {
        var ratio: Double
        var samples: Int
        /// What it was learned for: the food's name, or its category.
        var basis: String
        var isCategory: Bool
    }

    struct Book: Sendable {
        var byReference: [String: Factor] = [:]
        var byName: [String: Factor] = [:]
        var byCategory: [String: Factor] = [:]

        var isEmpty: Bool { byReference.isEmpty && byName.isEmpty && byCategory.isEmpty }

        /// The factor for a food, most specific first: the same database food, the same name,
        /// its category.
        func factor(name: String, referenceID: String?, category: String?) -> Factor? {
            if let referenceID, let factor = byReference[referenceID] { return factor }
            if let factor = byName[MyFoods.key(name)] { return factor }
            if let category, let factor = byCategory[category] { return factor }
            return nil
        }
    }

    /// What the rows teach. `category`: a database food's category (`FoodDatabase`), nil for one
    /// of yours.
    static func book(_ rows: [EstimateLedger.Row], category: (String) -> String?) -> Book {
        let teaching = rows.filter(\.teaches).compactMap { row -> (Date, String, String?, Double)? in
            guard let ratio = row.guessRatio, plausible.contains(ratio), let estimated = row.estimated else { return nil }
            return (row.date, estimated.name, estimated.referenceID, ratio)
        }.sorted { $0.0 > $1.0 }

        func factors(_ key: (String, String?) -> String?, minimum: Int, isCategory: Bool) -> [String: Factor] {
            var grouped: [String: (label: String, ratios: [Double])] = [:]
            for (_, name, reference, ratio) in teaching {
                guard let k = key(name, reference) else { continue }
                if grouped[k] == nil { grouped[k] = (isCategory ? k : name, []) }
                if grouped[k]!.ratios.count < window { grouped[k]!.ratios.append(ratio) }
            }
            var out: [String: Factor] = [:]
            for (k, value) in grouped where value.ratios.count >= minimum {
                guard let ratio = EstimateLedger.median(value.ratios), !negligible.contains(ratio) else { continue }
                out[k] = Factor(ratio: ratio, samples: value.ratios.count, basis: value.label, isCategory: isCategory)
            }
            return out
        }

        return Book(byReference: factors({ _, reference in reference }, minimum: minimumForFood, isCategory: false),
                    byName: factors({ name, _ in MyFoods.key(name) }, minimum: minimumForFood, isCategory: false),
                    byCategory: factors({ _, reference in reference.flatMap(category) }, minimum: minimumForCategory,
                                        isCategory: true))
    }

    // MARK: - Does it help?

    struct Backtest: Equatable, Sendable {
        /// Corrections it could be tried on: ones with learning from before them.
        var tried = 0
        /// The middle of how far the guess was from what was logged, as a fraction of it —
        /// without the factors, and with only the factors learned before each meal.
        var errorBefore: Double?
        var errorAfter: Double?

        /// Too few to tell, or closer with the factors: keep them on.
        var keepsFactors: Bool {
            guard tried >= 5, let before = errorBefore, let after = errorAfter else { return true }
            return after <= before
        }
    }

    /// Each correction, in order, estimated again with only what the ones before it taught —
    /// never with itself — to see whether the factors bring the guess closer.
    static func backtest(_ rows: [EstimateLedger.Row], category: (String) -> String?) -> Backtest {
        let ordered = rows.filter(\.teaches).sorted { $0.date < $1.date }
        var before: [Double] = []
        var after: [Double] = []
        for (index, row) in ordered.enumerated() {
            guard let guess = row.guessedGrams, let logged = row.logged?.grams, logged > 0,
                  let estimated = row.estimated else { continue }
            let book = Self.book(Array(ordered[..<index]), category: category)
            guard let factor = book.factor(name: estimated.name, referenceID: estimated.referenceID,
                                           category: estimated.referenceID.flatMap(category)) else { continue }
            before.append(abs(guess - logged) / logged)
            after.append(abs(guess * factor.ratio - logged) / logged)
        }
        return Backtest(tried: before.count, errorBefore: EstimateLedger.median(before),
                        errorAfter: EstimateLedger.median(after))
    }

    // MARK: - For the estimator

    /// What the estimator applies: the factors every logged meal teaches, or none while they'd
    /// make its guesses worse (`backtest`). `category`: a database food's category.
    static func lookup(_ meals: [MealEntry],
                       category: @escaping @Sendable (String) -> String?) -> @Sendable (String, String?) -> Double? {
        let rows = EstimateLedger.rows(meals)
        var categories: [String: String] = [:]
        for id in Set(rows.compactMap { $0.estimated?.referenceID }) { categories[id] = category(id) }
        let known = categories
        let book = book(rows, category: { known[$0] })
        guard !book.isEmpty, backtest(rows, category: { known[$0] }).keepsFactors else { return { _, _ in nil } }
        return { name, reference in
            book.factor(name: name, referenceID: reference,
                        category: reference.flatMap { known[$0] ?? category($0) })?.ratio
        }
    }
}
