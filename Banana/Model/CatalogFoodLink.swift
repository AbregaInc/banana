import Foundation

/// A food the bundled catalog knows ("2 eggs") came with numbers but no weight and no database
/// food behind it, so its row could only be counted in "servings" of whatever was said: no egg,
/// no grams, no ounces. Linked to the database food it is, it can be counted in that food's own
/// measures. The catalog's numbers stay as they are until the amount is changed.
enum CatalogFoodLink {
    static func link(_ item: ResolvedFoodItem,
                     search: (String) -> [FoodMatch] = { FoodDatabase.search($0, limit: 5) }) -> ResolvedFoodItem {
        guard item.source == .catalog, item.reference == nil, item.macros.calories > 0,
              let head = headWord(item.name) else { return item }
        let count = leadingCount(item.serving) ?? 1
        for match in search(item.name) {
            // The database's name has to be about the same food: "Egg, whole" for "eggs", never
            // the first hit whatever it is ("Rice crackers" for "rice" would be worse than none).
            guard match.reference.name.lowercased().contains(head) else { continue }
            let kcalPerGram = match.reference.per100g.calories / 100
            guard kcalPerGram > 0 else { continue }
            let grams = item.macros.calories / kcalPerGram
            guard grams >= 1, grams <= 3000 else { continue }
            var linked = item
            linked.reference = match.reference
            linked.grams = grams
            // Counted in the measure one of them is ("2 large"), when one is within a fifth of it.
            let each = grams / count
            if let portion = match.portions.first(where: { $0.grams > 0 && abs($0.grams - each) / each <= 0.2 }) {
                linked.serving = FoodSearch.serving(FoodSearch.Amount(count: count, unit: .portion(portion)))
            } else {
                linked.serving = "\(Int(grams.rounded())) g"
            }
            return linked
        }
        return item
    }

    /// "egg" of "eggs", "banana" of "a ripe banana": the last word, without a plural s.
    static func headWord(_ name: String) -> String? {
        let words = name.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        guard var word = words.last, word.count >= 3 else { return nil }
        if word.hasSuffix("ies") { word = String(word.dropLast(3)) + "y" }
        else if word.hasSuffix("s"), !word.hasSuffix("ss") { word.removeLast() }
        return word
    }

    /// 2 of "2", "2 large", "2.5 cups"; nil when it doesn't start with a number.
    static func leadingCount(_ serving: String) -> Double? {
        let first = serving.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
        guard let value = Double(first), value > 0 else { return nil }
        return value
    }
}
