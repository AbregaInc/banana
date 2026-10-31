import Foundation

/// Changing how much of something you had — "I had two of those" — without retyping four
/// numbers. The editor's ½× · 1× · 1½× · 2× buttons scale an item from its original estimate.
enum PortionScaling {
    static let factors: [Double] = [0.5, 1, 1.5, 2]

    static func label(_ factor: Double) -> String {
        switch factor {
        case 0.5: "\u{00BD}\u{00D7}"
        case 1.5: "1\u{00BD}\u{00D7}"
        default: "\(Int(factor))\u{00D7}"
        }
    }

    static func scaled(_ macros: NutritionMacros, by factor: Double) -> NutritionMacros {
        NutritionMacros(calories: macros.calories * factor,
                        proteinGrams: macros.proteinGrams * factor,
                        carbohydrateGrams: macros.carbohydrateGrams * factor,
                        fatGrams: macros.fatGrams * factor)
    }

    /// "1 cup" at 2× → "2 × 1 cup". 1× gives the serving back unchanged.
    static func serving(_ base: String, factor: Double) -> String {
        let base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard factor != 1 else { return base }
        let amount = factor == 0.5 ? "\u{00BD}" : factor == 1.5 ? "1\u{00BD}" : "\(Int(factor))"
        return base.isEmpty ? "\(amount) serving" : "\(amount) \u{00D7} \(base)"
    }

    /// More than this in one item is more likely a typo or a misread portion than a meal:
    /// 100 slices of toast, a whole cake logged as a slice. Worth a second look, not a block.
    static let implausibleCalories: Double = 2_000

    static func isImplausible(_ macros: NutritionMacros) -> Bool {
        macros.calories > implausibleCalories
    }
}

/// Every nutrition number as text, one way everywhere: calories whole, with their unit; the
/// macros protein, carbs, fat, in that order; a measure without a stray "1 " before its number.
/// Figures that stand alone are `StatValue`s and `MacroTile`s; these are for the lines between.
enum NutritionText {
    /// "P 12 g · C 50 g · F 8 g", each macro kept on one line when the line wraps.
    static func macroLine(_ m: NutritionMacros) -> String {
        "P\u{00A0}\(grams(m.proteinGrams)) \u{00B7} C\u{00A0}\(grams(m.carbohydrateGrams)) \u{00B7} F\u{00A0}\(grams(m.fatGrams))"
    }

    /// "210 kcal".
    static func kcal(_ m: NutritionMacros) -> String { kcal(m.calories) }

    static func kcal(_ calories: Double) -> String {
        "\(Int(calories.rounded()).formatted())\u{00A0}kcal"
    }

    /// "12 g", never split across lines.
    static func grams(_ grams: Double) -> String { "\(Int(grams.rounded()))\u{00A0}g" }

    /// A measure as said aloud: USDA's "1 5.3 oz container" → "5.3 oz container"; "1 cup" stays.
    static func measure(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("1 "), trimmed.dropFirst(2).first?.isNumber == true else { return trimmed }
        return String(trimmed.dropFirst(2))
    }

    /// A serving with its weight: "2/3 cup · 80 g"; "80 g" when the measure is the weight.
    static func serving(_ label: String, grams: Double?) -> String {
        GroundedFoodEstimate.serving(measure(label), grams: grams)
    }

    /// The named meal if it has a name; otherwise its items, capped so a five-plus-item meal
    /// reads "Eggs, Toast +3 more" rather than truncating mid-word into the fourth item.
    static func mealTitle(_ meal: MealEntry) -> String {
        let trimmedName = meal.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty { return trimmedName }
        let names = meal.items.map(\.name)
        guard names.count > 3 else { return names.joined(separator: ", ") }
        return "\(names.prefix(2).joined(separator: ", ")) +\(names.count - 2) more"
    }
}
