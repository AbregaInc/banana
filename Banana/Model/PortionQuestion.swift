import Foundation

/// The one question worth asking in a day's review: "Rice: 1 cup · 1½ · 2" — for the biggest
/// foods whose amount was only the model's guess (docs/design/MEAL-LEARNING.md §5). Portion is
/// where photo estimates go most wrong, and an answer is the best thing Banana can learn from
/// (`EstimateLedger.Outcome.answered`). Asked sparingly: at most two a day. Pure.
enum PortionQuestion {
    static let perDay = 2
    /// Only a food that's at least this much of its meal's calories is worth a question.
    static let share = 0.25

    struct Choice: Hashable, Sendable {
        var label: String
        var grams: Double
    }

    struct Question: Hashable, Sendable {
        var mealID: UUID
        var itemID: UUID
        var name: String
        var choices: [Choice]
    }

    /// The day's questions, biggest first. `portions`: a database food's measures (`FoodDatabase`).
    static func questions(_ meals: [MealInboxItem], portions: (String) -> [FoodPortion]) -> [Question] {
        var candidates: [(calories: Double, question: Question)] = []
        for meal in meals where meal.state == .proposed {
            guard let proposal = meal.proposal, let estimate = proposal.estimate else { continue }
            let total = proposal.totals.calories
            guard total > 0 else { continue }
            let current = Dictionary(proposal.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for food in estimate.foods where food.amount == .guess && !estimate.confirmed.contains(food.itemID) {
                guard let item = current[food.itemID], let reference = item.reference?.id,
                      let grams = item.grams, let estimated = food.grams, grams > 0,
                      abs(grams - estimated) <= estimated * EstimateLedger.tolerance else { continue }
                let calories = item.macros.sanitized.calories
                guard calories >= total * share,
                      let choices = choices(grams: grams, portions: portions(reference)) else { continue }
                candidates.append((calories, Question(mealID: meal.id, itemID: item.id, name: item.name, choices: choices)))
            }
        }
        return candidates.sorted { $0.calories > $1.calories }.prefix(perDay).map(\.question)
    }

    /// Three amounts around the guess, in the measure a person counts the food in: "1 cup ·
    /// 1½ cups · 2 cups" of rice, "¾ miniature · 1 miniature · 1½ miniature" of cucumber. Nil
    /// when it has no measure a person would answer in.
    static func choices(grams: Double, portions: [FoodPortion]) -> [Choice]? {
        let usable = portions.compactMap { portion -> (unit: String, grams: Double)? in
            guard portion.grams > 0, let unit = unit(portion.label) else { return nil }
            return (unit, portion.grams)
        }
        // A measure the guess is a sensible number of: a cup of rice, not 40 teaspoons of it.
        let fitting = usable.filter { (0.25...4).contains(grams / $0.grams) }
        func nearestOne(_ measures: [(unit: String, grams: Double)]) -> (unit: String, grams: Double)? {
            measures.min { abs(log(grams / $0.grams)) < abs(log(grams / $1.grams)) }
        }
        // Something that comes whole is counted whole — a cucumber, not cups of one — in the
        // size the guess is nearest one of. Otherwise cups, then whatever's nearest one.
        guard let measure = nearestOne(fitting.filter { sizes.contains($0.unit) })
                ?? fitting.first(where: { $0.unit == "cup" })
                ?? nearestOne(fitting) else { return nil }
        let amount = grams / measure.grams
        let steps: [Double] = [0.25, 0.5, 0.75, 1, 1.5, 2, 2.5, 3, 4]
        let nearest = steps.sorted { abs(log($0 / amount)) < abs(log($1 / amount)) }.prefix(3).sorted()
        return nearest.map { Choice(label: label($0, unit: measure.unit), grams: $0 * measure.grams) }
    }

    /// Measures that are the whole food, by size: "1 medium" apple, "1 regular" cucumber.
    static let sizes: Set<String> = ["small", "medium", "large", "extra large", "jumbo", "regular", "miniature",
                                     "mini", "whole"]

    /// The measure a USDA portion is in — "cup" of "1 cup, cooked", "medium" of "1 medium" — or nil
    /// for weights and odd ones ("1 oz", "1 cubic inch") nobody answers a question in.
    static func unit(_ label: String) -> String? {
        let head = label.lowercased().split(whereSeparator: { $0 == "," || $0 == "(" }).first?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard head.hasPrefix("1 ") else { return nil }
        let unit = String(head.dropFirst(2))
        let first = unit.split(separator: " ").first.map(String.init) ?? ""
        let refused: Set<String> = ["oz", "fl", "lb", "g", "gram", "grams", "kg", "ml", "tbsp", "tablespoon", "tsp",
                                    "teaspoon", "cubic", "surface", "quart", "pint", "gallon", "typical", "nlea",
                                    "package", "jar", "container", "recipe", "batch", "yield"]
        guard !unit.isEmpty, !refused.contains(first), unit.count <= 16 else { return nil }
        return unit
    }

    /// "1½ cups", "½ cup", "2 medium".
    static func label(_ amount: Double, unit: String) -> String {
        let whole = Int(amount)
        let fraction = amount - Double(whole)
        let glyph = [0.25: "¼", 0.5: "½", 0.75: "¾"][fraction] ?? ""
        let number = whole == 0 ? glyph : "\(whole)\(glyph)"
        return "\(number) \(amount > 1 ? plural(unit) : unit)"
    }

    private static func plural(_ unit: String) -> String {
        let countable: Set<String> = ["cup", "slice", "piece", "bowl", "fillet", "patty", "link", "can", "bottle", "bar",
                                      "serving", "roll", "bun", "wedge", "taco", "egg", "cookie", "tortilla", "breast",
                                      "thigh", "wing", "drumstick", "sandwich", "burrito", "steak", "plate", "scoop"]
        if unit == "glass" { return "glasses" }
        return countable.contains(unit) ? unit + "s" : unit
    }
}
