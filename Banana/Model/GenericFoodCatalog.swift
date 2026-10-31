import Foundation

/// A hand-curated macro entry for one generic food, matched by name against free-text
/// descriptions. See `Banana/Resources/GenericFoods.json`'s own `source` field for where these
/// numbers came from.
struct GenericFood: Codable, Hashable, Sendable {
    /// Every alternative name/spelling someone might type or dictate for this food, lowercase.
    var names: [String]
    /// Human-readable label for one unit of `unitMacros`, e.g. "large egg", "slice (25 g)".
    var unitLabel: String
    var unitMacros: NutritionMacros
}

/// The decoded shape of `GenericFoods.json`: a source note (for later audit) plus the rows.
struct GenericFoodTable: Codable, Sendable {
    var source: String
    var foods: [GenericFood]
}

/// Loads Banana's bundled generic-food macro table and matches free-text food names against it.
/// This is the "honesty" layer behind natural-language food entry (`FoodTextExtractor`): a known
/// food gets these real, hand-curated numbers; an unknown one falls through to the model's own
/// flagged estimate instead of silently trusting a guess.
enum GenericFoodCatalog {
    static var source: String { defaultTable?.source ?? "unavailable" }

    /// Loaded once from the main bundle — the table never changes at runtime, and `match(name:)`
    /// can run on every keystroke of an edited row.
    private static let defaultTable: GenericFoodTable? = loadTable(from: .main)

    static func match(name: String) -> GenericFood? {
        match(name: name, in: defaultTable)
    }

    /// Reads and decodes `GenericFoods.json` from the given bundle. Exposed (rather than baked
    /// into a `.main`-only private loader) so tests can load the copy embedded in the BananaTests
    /// bundle instead — the same seam `BarcodeProductLookup.lookup(_:databaseURL:)` uses for its
    /// bundled catalog, and for the same reason.
    static func loadTable(from bundle: Bundle) -> GenericFoodTable? {
        guard let url = bundle.url(forResource: "GenericFoods", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(GenericFoodTable.self, from: data)
    }

    /// Whole-word match against every alternative name: a name matches when its words appear, in
    /// order and together, among the words of what was typed, a plural counting as its singular
    /// ("2 eggs" is "egg"). When more than one food's name matches (e.g. "milk" in a generic dairy
    /// row and "almond milk" in its own row), the *longest* matching name wins — the more specific
    /// entry is always preferred over a shorter generic one it happens to contain.
    ///
    /// It was a substring test, so "eggplant" was an egg, "buttermilk" a tablespoon of butter and
    /// "cornbread" a cup of corn, each at full confidence.
    static func match(name: String, in table: GenericFoodTable?) -> GenericFood? {
        let needle = words(name)
        guard !needle.isEmpty, let table else { return nil }
        var best: (food: GenericFood, words: Int, letters: Int)?
        for food in table.foods {
            for candidate in food.names {
                let wanted = words(candidate)
                guard !wanted.isEmpty, contains(needle, wanted) else { continue }
                let letters = wanted.reduce(0) { $0 + $1.count }
                if best == nil || (wanted.count, letters) > (best!.words, best!.letters) {
                    best = (food, wanted.count, letters)
                }
            }
        }
        return best?.food
    }

    /// Lowercase words, a plural as its singular. The same reading for what was typed and for
    /// the catalog's names, so it only has to be consistent, not grammatical.
    static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter }.map { singular(String($0)) }
    }

    private static func singular(_ word: String) -> String {
        guard word.count > 3 else { return word }
        if word.hasSuffix("ies") { return String(word.dropLast(3)) + "y" }
        if word.hasSuffix("oes") { return String(word.dropLast(2)) }
        for ending in ["ches", "shes", "sses", "xes", "zes"] where word.hasSuffix(ending) {
            return String(word.dropLast(2))
        }
        if word.hasSuffix("s"), !word.hasSuffix("ss") { return String(word.dropLast()) }
        return word
    }

    private static func contains(_ words: [String], _ run: [String]) -> Bool {
        guard run.count <= words.count else { return false }
        return (0...(words.count - run.count)).contains { Array(words[$0..<($0 + run.count)]) == run }
    }
}

extension GenericFood {
    /// What one unit weighs, when its label says: "slice (25 g)" is 25.
    var unitGrams: Double? {
        guard let match = unitLabel.range(of: #"\((\d+(?:\.\d+)?)\s*g\)"#, options: .regularExpression) else { return nil }
        return Double(unitLabel[match].filter { $0.isNumber || $0 == "." })
    }

    /// The unit the label is in, read the way a person's amount is (`FoodPhrase`): "1 cup cooked
    /// (158 g)" is one cup, "12 almonds (14 g)" is twelve, "large egg" is one.
    var unitQuantity: FoodQuantity? {
        let bare = unitLabel.replacingOccurrences(of: #"\s*\(.*\)"#, with: "", options: .regularExpression)
        return FoodPhrase.quantity(bare) ?? FoodPhrase.split(bare).quantity
    }

    /// How many of this food's unit an amount is. Nil when the two can't be compared — a weight
    /// against a unit with no weight, a slice against a cup — so the caller can fall back to an
    /// estimate it marks as one, instead of multiplying anyway.
    ///
    /// The amount used to be the leading whole number times the unit, whatever either was:
    /// "200 g rice" was 200 cups and "1/2 cup" was one, both at full confidence.
    func units(in quantity: FoodQuantity?) -> Double? {
        guard let quantity else { return 1 }
        let label = unitQuantity
        let labelAmount = max(label?.amount ?? 1, 0.000_1)
        switch quantity.unit {
        case .mass(let grams):
            guard let unitGrams, unitGrams > 0 else { return nil }
            return quantity.amount * grams / unitGrams
        case .volume(let volume):
            guard case .volume(let labelVolume)? = label?.unit else { return nil }
            return quantity.amount * volume.milliliters / (labelAmount * labelVolume.milliliters)
        case .count:
            // A bare number is that many of whatever the label counts in.
            if let label, Self.countsLike(label.unit) { return quantity.amount / labelAmount }
            return quantity.amount
        case .measure(let name) where name == "serving" || name == "portion":
            return quantity.amount
        case .measure, .size:
            guard let label else { return quantity.amount }
            guard Self.countsLike(label.unit) else { return nil }
            // "2 slices" against a label in slices; a different measure can't be compared.
            if case .measure(let said) = quantity.unit, case .measure(let labelled) = label.unit, said != labelled {
                return nil
            }
            return quantity.amount / labelAmount
        }
    }

    private static func countsLike(_ unit: FoodQuantity.Unit) -> Bool {
        switch unit {
        case .count, .size, .measure: return true
        case .mass, .volume: return false
        }
    }
}
