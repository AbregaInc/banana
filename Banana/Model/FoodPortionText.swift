import Foundation

/// How much of a food someone said: "1/2 can", "2 medium", "a bowl", "200g".
struct FoodQuantity: Equatable, Sendable {
    enum Unit: Equatable, Sendable {
        case mass(grams: Double)                 // per one of it: g, kg, oz, lb, a palm
        case volume(Volume)
        /// small / medium / large ("1 medium onion").
        case size(String)
        /// A named measure the food's own portions may list: slice, piece, fillet, clove, can, stick…
        case measure(String)
        /// Just a number: "2 eggs".
        case count
    }

    enum Volume: String, Sendable {
        case teaspoon, tablespoon, cup, fluidOunce, milliliter, liter, glass, mug, bowl

        var milliliters: Double {
            switch self {
            case .teaspoon: return 4.93
            case .tablespoon: return 14.79
            case .cup: return 236.6
            case .fluidOunce: return 29.57
            case .milliliter: return 1
            case .liter: return 1_000
            case .glass: return 240
            case .mug: return 300
            case .bowl: return 355     // about a cup and a half
            }
        }
    }

    var amount: Double
    var unit: Unit
    /// The words it came from, for the serving line: "1/2 can".
    var text: String
}

/// Splitting a person's food line into the amount and the food, and reading portion phrases.
///
/// The estimates went wrong here: the model copied lines like "1/2 can of tomato sauce" into the
/// food's name, so the lookup searched for "1/2 can of…" — and matched a frozen meal named
/// "… 9 1/2 Oz" on its numbers — while the grams were the small model's guess, 2–20× off for a
/// teaspoon, a cup or a bowl. With the amount read here, the grams come from USDA's own measures
/// for that exact food (`PortionGrams`).
enum FoodPhrase {
    /// "1/2 can of tomato sauce" → (½ can, "tomato sauce"); "beef bone broth" → (nil, itself).
    static func split(_ text: String) -> (quantity: FoodQuantity?, food: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let (quantity, rest) = leading(trimmed, named: true) else { return (nil, trimmed) }
        guard rest.isEmpty else { return (quantity, rest) }
        // "2 eggs", "3 wings": the measure is the food itself — a count of it.
        guard case .measure = quantity.unit,
              let number = trimmed.split(whereSeparator: \.isWhitespace).first, number != Substring(trimmed)
        else { return (nil, trimmed) }
        let food = trimmed.dropFirst(number.count).trimmingCharacters(in: .whitespaces)
        return (FoodQuantity(amount: quantity.amount, unit: .count, text: String(number)), food)
    }

    /// A portion phrase on its own: "1/2 cup", "2 medium", "a bowl", "1 fillet". Nil when it
    /// doesn't start with an amount or a measure ("some", "a plate of it" still reads as 1 plate).
    static func quantity(_ text: String) -> FoodQuantity? {
        leading(text.trimmingCharacters(in: .whitespacesAndNewlines))?.quantity
    }

    // MARK: - Reading

    private static let fractions: [Character: String] = ["½": " 1/2", "¼": " 1/4", "¾": " 3/4", "⅓": " 1/3",
                                                          "⅔": " 2/3", "⅛": " 1/8"]
    private static let numberWords: [String: Double] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
        "eight": 8, "nine": 9, "ten": 10, "half": 0.5, "quarter": 0.25, "couple": 2, "few": 3,
        "single": 1, "dozen": 12,
    ]
    /// Words read as a unit, longest phrases first where they share a start.
    private static let units: [(words: [String], unit: FoodQuantity.Unit)] = {
        var list: [(words: [String], unit: FoodQuantity.Unit)] = [
            (["fl", "oz"], .volume(.fluidOunce)), (["fluid", "ounce"], .volume(.fluidOunce)),
            (["fluid", "ounces"], .volume(.fluidOunce)),
        ]
        let single: [(String, FoodQuantity.Unit)] = [
            ("tsp", .volume(.teaspoon)), ("teaspoon", .volume(.teaspoon)), ("teaspoons", .volume(.teaspoon)),
            ("tbsp", .volume(.tablespoon)), ("tbs", .volume(.tablespoon)), ("tablespoon", .volume(.tablespoon)),
            ("tablespoons", .volume(.tablespoon)), ("spoon", .volume(.tablespoon)), ("spoons", .volume(.tablespoon)),
            ("spoonful", .volume(.tablespoon)), ("spoonfuls", .volume(.tablespoon)),
            ("cup", .volume(.cup)), ("cups", .volume(.cup)),
            ("ml", .volume(.milliliter)), ("milliliter", .volume(.milliliter)), ("milliliters", .volume(.milliliter)),
            ("millilitre", .volume(.milliliter)), ("millilitres", .volume(.milliliter)),
            ("l", .volume(.liter)), ("liter", .volume(.liter)), ("liters", .volume(.liter)),
            ("litre", .volume(.liter)), ("litres", .volume(.liter)),
            ("glass", .volume(.glass)), ("glasses", .volume(.glass)), ("mug", .volume(.mug)), ("mugs", .volume(.mug)),
            ("bowl", .volume(.bowl)), ("bowls", .volume(.bowl)),
            ("g", .mass(grams: 1)), ("gram", .mass(grams: 1)), ("grams", .mass(grams: 1)), ("gr", .mass(grams: 1)),
            ("kg", .mass(grams: 1_000)), ("kilo", .mass(grams: 1_000)), ("kilos", .mass(grams: 1_000)),
            ("oz", .mass(grams: 28.35)), ("ounce", .mass(grams: 28.35)), ("ounces", .mass(grams: 28.35)),
            ("lb", .mass(grams: 453.6)), ("lbs", .mass(grams: 453.6)), ("pound", .mass(grams: 453.6)),
            ("pounds", .mass(grams: 453.6)),
            // A palm-sized portion of meat or fish: the usual 3–4 oz.
            ("palm", .mass(grams: 100)), ("palms", .mass(grams: 100)),
            ("small", .size("small")), ("medium", .size("medium")), ("large", .size("large")), ("big", .size("large")),
        ]
        list += single.map { ([$0.0], $0.1) }
        for measure in ["can", "tin", "slice", "piece", "fillet", "filet", "clove", "stick", "pat", "scoop",
                        "serving", "portion", "handful", "pinch", "dash", "splash", "bar", "packet", "bottle",
                        "egg", "link", "patty", "strip", "wedge", "leaf", "sprig", "head", "ear", "breast",
                        "thigh", "drumstick", "wing", "plate", "container", "pouch", "sheet", "square"] {
            list.append(([measure], .measure(measure)))
            let plural = measure.hasSuffix("ch") || measure.hasSuffix("sh") ? measure + "es" : measure + "s"
            list.append(([plural], .measure(measure)))
        }
        list.append((["leaves"], .measure("leaf")))
        list.append((["patties"], .measure("patty")))
        return list.sorted { $0.words.count > $1.words.count }
    }()

    /// The leading amount and unit of `text`, and what follows them (after "of").
    /// `named`: reading a food's name, where a measure word with no number before it is only an
    /// amount when "of" follows — "bowl of soup" is, "egg drop soup" isn't.
    private static func leading(_ text: String, named: Bool = false) -> (quantity: FoodQuantity, rest: String)? {
        var normalized = ""
        for character in text { normalized += fractions[character] ?? String(character) }
        // "200g" → "200 g", "1-2" → "1 - 2"
        normalized = normalized.replacingOccurrences(of: #"(\d)([a-zA-Z])"#, with: "$1 $2", options: .regularExpression)
        normalized = normalized.replacingOccurrences(of: #"(\d)\s*[-–]\s*(\d)"#, with: "$1 - $2", options: .regularExpression)
        let tokens = normalized.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return nil }
        let lower = tokens.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,")) }

        var index = 0
        var amount: Double?
        // "half a", "half an"
        if lower[0] == "half", lower.count > 1, ["a", "an"].contains(lower[1]) {
            amount = 0.5
            index = 2
        } else if let first = number(lower[0]) {
            amount = first
            index = 1
            // "1 1/2", "1 - 2"
            if index < lower.count, let fraction = fraction(lower[index]), first == first.rounded(), fraction < 1 {
                amount = first + fraction
                index += 1
            } else if index + 1 < lower.count, ["-", "to"].contains(lower[index]), let upper = number(lower[index + 1]) {
                amount = (first + upper) / 2
                index += 2
            }
        } else if lower[0] == "a", lower.count > 1, let word = ["few": 3.0, "couple": 2.0][lower[1]] {
            amount = word
            index = 2
            if index < lower.count, lower[index] == "of" { index += 1 }
        } else if let word = numberWords[lower[0]] {
            amount = word
            index = 1
            if lower[0] == "couple" || lower[0] == "few", index < lower.count, lower[index] == "of" { index += 1 }
        }

        var unit: FoodQuantity.Unit?
        var unitWords = 0
        for candidate in units where index + candidate.words.count <= lower.count {
            if Array(lower[index..<(index + candidate.words.count)]) == candidate.words {
                unit = candidate.unit
                unitWords = candidate.words.count
                break
            }
        }
        // "small/medium/large" are only a unit with a food after them, and only after a number:
        // "a medium" alone, or "large fries", keeps its words.
        if case .size = unit, amount == nil { unit = nil; unitWords = 0 }
        guard amount != nil || unit != nil else { return nil }
        let quantityEnd = index + unitWords
        let ofFollows = quantityEnd < lower.count && lower[quantityEnd] == "of"
        if named, amount == nil, !ofFollows { return nil }
        var restStart = quantityEnd
        if ofFollows { restStart += 1 }
        let rest = tokens[restStart...].joined(separator: " ").trimmingCharacters(in: .whitespaces)
        let quantityText = tokens[..<quantityEnd].joined(separator: " ")
        return (FoodQuantity(amount: amount ?? 1, unit: unit ?? .count, text: quantityText), rest)
    }

    private static func number(_ token: String) -> Double? {
        if let fraction = fraction(token) { return fraction }
        return Double(token)
    }

    private static func fraction(_ token: String) -> Double? {
        let parts = token.split(separator: "/")
        guard parts.count == 2, let top = Double(parts[0]), let bottom = Double(parts[1]), bottom > 0 else { return nil }
        return top / bottom
    }
}

/// Grams for an amount of one food, from the food's own household measures where it has them —
/// USDA's "1 cup" of rice noodles is 175 g, its "1 tablespoon" of butter 14 g — then plain
/// conversions. Nil when it can't be worked out; the model's estimate stands then.
enum PortionGrams {
    /// A can of something, when the food doesn't list one: a 14–15 oz can.
    static let defaultCanGrams = 400.0

    static func grams(_ quantity: FoodQuantity?, portions: [FoodPortion], food: String = "") -> Double? {
        guard let quantity, quantity.amount > 0, quantity.amount.isFinite else { return nil }
        let amount = quantity.amount
        let measures = portions.compactMap { portion -> (FoodQuantity, Double, String)? in
            guard portion.grams > 0, let parsed = FoodPhrase.quantity(portion.label) else { return nil }
            return (parsed, portion.grams / parsed.amount, portion.label.lowercased())
        }

        switch quantity.unit {
        case .mass(let grams):
            return amount * grams

        case .volume(let volume):
            // The food's own measure of this size ("1 cup, cooked" = 175 g)…
            if let same = measures.first(where: { $0.0.unit == .volume(volume) }) { return amount * same.1 }
            // …or its density from any measure by volume ("1 tablespoon" = 14 g → a teaspoon is 4.7 g)…
            if let any = measures.first(where: { if case .volume = $0.0.unit { return true } else { return false } }),
               case .volume(let measured) = any.0.unit {
                return amount * volume.milliliters * any.1 / measured.milliliters
            }
            // …or, for a drink, about water's. A cup of something solid with no measure of its own
            // is left to the model: cooked rice is 158 g a cup, not 237.
            switch volume {
            case .milliliter, .liter, .fluidOunce, .glass, .mug: return amount * volume.milliliters
            case .teaspoon, .tablespoon, .cup, .bowl: return nil
            }

        case .size(let size):
            if let exact = measures.first(where: { $0.2.range(of: "\\b\(size)\\b", options: .regularExpression) != nil
                                                    && isCountLike($0.0.unit) }) {
                return amount * exact.1
            }
            guard let medium = mediumMeasure(measures) else { return nil }
            return amount * medium * (size == "small" ? 0.7 : size == "large" ? 1.3 : 1)

        case .measure(let name):
            if let named = measures.first(where: { $0.2.range(of: "\\b\(name)", options: .regularExpression) != nil }) {
                return amount * named.1
            }
            switch name {
            case "can", "tin": return amount * defaultCanGrams
            // "1 piece of salmon": a regular one.
            case "piece": return mediumMeasure(measures).map { amount * $0 }
            case "handful": return amount * 30
            case "pinch", "dash": return amount * 0.4
            case "serving", "portion":
                return portions.first { $0.label.lowercased() == "typical portion" }.map { amount * $0.grams }
            default: return nil
            }

        case .count:
            // "2 eggs": the food's own "1 egg", else its medium one.
            let head = food.lowercased().split(whereSeparator: { !$0.isLetter }).last.map(String.init) ?? ""
            let stem = head.count > 3 && head.hasSuffix("s") ? String(head.dropLast()) : head
            if !stem.isEmpty, let own = measures.first(where: {
                isCountLike($0.0.unit) && $0.2.range(of: "\\b\(stem)", options: .regularExpression) != nil
            }) {
                return amount * own.1
            }
            return mediumMeasure(measures).map { amount * $0 }
        }
    }

    private static func isCountLike(_ unit: FoodQuantity.Unit) -> Bool {
        switch unit {
        case .count, .size, .measure: return true
        case .mass, .volume: return false
        }
    }

    /// One middling piece: "1 medium", else "1 regular …".
    private static func mediumMeasure(_ measures: [(FoodQuantity, Double, String)]) -> Double? {
        for word in ["medium", "regular"] {
            if let found = measures.first(where: {
                isCountLike($0.0.unit) && $0.2.range(of: "\\b\(word)\\b", options: .regularExpression) != nil
            }) {
                return found.1
            }
        }
        return nil
    }
}
