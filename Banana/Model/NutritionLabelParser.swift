import Foundation

/// A US Nutrition Facts panel, as read from a photo of it (`NutritionLabelReader`): the serving,
/// how many are in the package, and what one serving holds. For a product no database knows —
/// Trader Joe's barely appears in any — the label on the package is the source.
struct ParsedNutritionLabel: Equatable, Sendable {
    /// "1 cup", "2/3 cup", "6 pieces".
    var servingLabel: String
    var servingGrams: Double
    var servingsPerContainer: Double?
    var perServing: NutritionMacros

    var per100g: NutritionMacros {
        let factor = 100 / max(servingGrams, 1)
        return NutritionMacros(calories: perServing.calories * factor,
                               proteinGrams: perServing.proteinGrams * factor,
                               carbohydrateGrams: perServing.carbohydrateGrams * factor,
                               fatGrams: perServing.fatGrams * factor)
    }

    var packageGrams: Double? { servingsPerContainer.map { $0 * servingGrams } }
}

/// Reads the panel from the text a camera recognized on it, line by line. Tolerant of what text
/// recognition does to a label: "Calories" and its number on separate lines, "Total Fat Og" for
/// 0 g, words run together ("TotalFat8g", "Servingsize"), the % Daily Value on the same line.
/// Pure, for tests. Nil when the serving's weight or the calories can't be found — without the
/// weight nothing can be scaled to what was actually eaten.
enum NutritionLabelParser {
    static func parse(_ lines: [String]) -> ParsedNutritionLabel? {
        let cleaned = lines.map(clean).filter { !$0.isEmpty }
        guard let (servingLabel, servingGrams) = serving(in: cleaned),
              let calories = calories(in: cleaned) else { return nil }
        let macros = NutritionMacros(
            calories: calories,
            proteinGrams: grams(after: #"protein"#, in: cleaned) ?? 0,
            carbohydrateGrams: grams(after: #"total\s*carb(?:ohydrates?|s|\.)?"#, in: cleaned) ?? 0,
            fatGrams: grams(after: #"total\s*fat"#, in: cleaned) ?? 0)
        return ParsedNutritionLabel(servingLabel: servingLabel, servingGrams: servingGrams,
                                    servingsPerContainer: servingsPerContainer(in: cleaned),
                                    perServing: macros)
    }

    /// Lowercased, spaced out, with the letter O read for a zero put right ("Og" → "0g").
    private static func clean(_ line: String) -> String {
        var text = line.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: #"(?<=[\s:])o(?=\s?g\b)"#, with: "0", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?<=\d)\s*o(?=\s?g\b)"#, with: "0", options: .regularExpression)
        return text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private static func number(_ text: Substring) -> Double? {
        let parts = text.split(separator: "/")
        if parts.count == 2, let a = Double(parts[0]), let b = Double(parts[1]), b > 0 { return a / b }
        return Double(text)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> [Substring]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { text[$0] } ?? ""
        }
    }

    /// "Serving size 1 cup (140g)" — or "Serving size" with "1 cup (140g)" on the line after or before.
    private static func serving(in lines: [String]) -> (String, Double)? {
        // "Serv. size" on a small package's one-paragraph label.
        for (index, line) in lines.enumerated() where line.range(of: #"serv(?:ing|\.)?\s*size"#, options: .regularExpression) != nil {
            var text = line.replacingOccurrences(of: #".*serv(?:ing|\.)?\s*size:?"#, with: "", options: .regularExpression)
            // On a one-paragraph label the serving's weight is followed by the rest of the panel.
            if let bracket = text.range(of: #"\)"#, options: .regularExpression), text.range(of: "(") != nil {
                text = String(text[..<bracket.upperBound])
            }
            // Its value can be read as a line of its own, just after it or, printed larger, before.
            if firstMatch(#"(\d+(?:\.\d+)?)\s*g\b"#, in: text) == nil,
               let neighbour = [index + 1, index - 1].first(where: {
                   lines.indices.contains($0) && firstMatch(#"(\d+(?:\.\d+)?)\s*g\b"#, in: lines[$0]) != nil
               }) {
                text += " " + lines[neighbour]
            }
            guard let grams = firstMatch(#"\(?\s*(\d+(?:\.\d+)?)\s*g\s*\)?"#, in: text), let value = Double(grams[1]),
                  value > 0 else { continue }
            let label = text.components(separatedBy: "(").first?
                .replacingOccurrences(of: #"\d+(?:\.\d+)?\s*g\b"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces) ?? ""
            return (label.isEmpty ? "1 serving" : label, value)
        }
        return nil
    }

    /// "About 3 servings per container", "Servings Per Container 3", "8 servings per container".
    private static func servingsPerContainer(in lines: [String]) -> Double? {
        for line in lines {
            if let m = firstMatch(#"(\d+(?:\.\d+)?)\s*servings?\s*per\s*(?:container|package)"#, in: line), let n = number(m[1]) {
                return n
            }
            if let m = firstMatch(#"servings?\s*per\s*(?:container|package)\s*(?:about\s*)?(\d+(?:\.\d+)?)"#, in: line),
               let n = number(m[1]) {
                return n
            }
        }
        return nil
    }

    /// "Calories 210", or "Calories" with "210" on its own line after it (it's printed large). Not
    /// "Calories from fat", nor the footnote's "2,000 calories a day".
    private static func calories(in lines: [String]) -> Double? {
        for (index, line) in lines.enumerated() {
            // At the start of its row, or mid-sentence on a one-paragraph label ("…per serving: Calories 190,").
            guard line.range(of: #"(?:^|[:,]\s*)(?:amount per serving\s*)?calories\b"#, options: .regularExpression) != nil,
                  !line.hasPrefix("calories from fat"), !line.contains("per gram") else { continue }
            if let m = firstMatch(#"calories\s*:?\s*(\d{1,4})\b"#, in: line), let value = Double(m[1]) { return value }
            // Printed large on the right, its number can come just before or just after it.
            for neighbour in [index + 1, index - 1] where lines.indices.contains(neighbour) {
                if let m = firstMatch(#"^(\d{1,4})$"#, in: lines[neighbour]), let value = Double(m[1]) { return value }
            }
        }
        return nil
    }

    /// The grams on the line a nutrient is named on: "Total Fat 8g 10%" → 8.
    private static func grams(after name: String, in lines: [String]) -> Double? {
        for line in lines {
            guard let m = firstMatch(name + #"\s*:?\s*(?:less than\s*|<\s*)?(\d+(?:\.\d+)?)\s*g\b"#, in: line),
                  let value = Double(m[1]) else { continue }
            return value
        }
        return nil
    }
}
