import Foundation

/// Finding a food by name and adding it at an amount — "Trader Joe's cut and peeled carrots",
/// "mini scallops" — without a photo, a barcode or a model's guess. Three places, best first:
///
/// - **Yours:** what you've logged before, at your usual amount, and the packages you've scanned,
///   matched by name — and whatever you picked for these words last time (`FoodSearchPicks`).
///   The more you log, the more of what you search for is already here.
/// - **Foods:** Banana's bundled USDA foods, offline (`FoodDatabase`). A brand in the words is left
///   out of this search: Trader Joe's carrots are carrots.
/// - **Products:** packaged products — the bundled USDA branded ones and, online, Open Food Facts
///   — of the brand named, when one is (`brand(in:index:)`).
///
/// Every result has numbers per 100 g and real household measures, so the amount is chosen
/// ("1 cup", "10 baby carrots", grams) and everything follows it. Pure, for tests; where it looks
/// is `FoodSearchSources`.
enum FoodSearch {
    enum Section: Int, CaseIterable, Hashable, Sendable {
        case yours, foods, products

        var title: String {
            switch self {
            case .yours: "Yours"
            case .foods: "Foods"
            case .products: "Products"
            }
        }
    }

    struct Result: Identifiable, Hashable, Sendable {
        var id: String
        var section: Section
        var name: String
        /// "Had 6 times · usually 85 g", "USDA · 41 kcal per 100 g".
        var detail: String
        /// It at the amount it starts at — `start`.
        var item: MealItem
        /// Household measures to choose the amount in, most common first. Empty for something of
        /// yours logged without a weight: its amount is a number of what was logged.
        var portions: [FoodPortion]
        var start: Amount
    }

    /// How much: a count of a measure, of grams, of ounces, or of what was logged.
    struct Amount: Hashable, Sendable {
        enum Unit: Hashable, Sendable { case portion(FoodPortion), grams, ounces, servings }
        var count: Double
        var unit: Unit
    }

    static let ounce = 28.3495

    // MARK: - Words

    private static let filler: Set<String> = ["a", "an", "and", "the", "of", "with", "in", "on", "some", "my", "from", "at"]

    /// Lowercased, diacritics folded, apostrophes closed up ("Joe's" → "joes"), plurals singular
    /// ("carrots" → "carrot", "joes" → "joe"), filler and bare numbers dropped. `singular: false`
    /// keeps plurals, for a search sent as typed.
    static func words(_ text: String, singular: Bool = true) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
            .replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\u{2019}", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !filler.contains($0) && !$0.allSatisfy(\.isNumber) }
            .map { singular ? self.singular($0) : $0 }
    }

    static func singular(_ word: String) -> String {
        guard word.count > 3, word.hasSuffix("s"), !word.hasSuffix("ss") else { return word }
        if word.hasSuffix("ies"), word.count > 4 { return String(word.dropLast(3)) + "y" }
        return String(word.dropLast())
    }

    /// The same words in any order, for remembering what was picked for them.
    static func key(_ query: String) -> String { words(query).sorted().joined(separator: " ") }

    // MARK: - Brands

    struct Brand: Hashable, Sendable {
        /// As products are labelled: "Trader Joe's".
        var name: String
        /// The words of it a search used, folded: ["trader", "joe"].
        var words: [String]
    }

    /// Every way a search may name a brand — its first two or three words ("trader joe", "whole
    /// foods market"), or its one word when that word is only ever a brand ("chobani") — to the
    /// brand as labelled. Built once from the bundled products' brands.
    struct BrandIndex: Sendable {
        var phrases: [String: String] = [:]

        /// Short names people use.
        static let aliases = ["tj": "Trader Joe's", "tjs": "Trader Joe's"]

        init(phrases: [String: String] = [:]) { self.phrases = phrases }

        /// `brands` with how many products each has: the most-sold wins a phrase two share.
        init(brands: [(name: String, products: Int)], brandWords: Set<String>) {
            for (name, _) in brands.sorted(by: { $0.products > $1.products }) {
                let label = FoodSearch.label(brand: name)
                for (phrase, prefix) in FoodSearch.prefixes(of: label) {
                    let count = phrase.split(separator: " ").count
                    guard count >= 2 || brandWords.contains(phrase), phrases[phrase] == nil else { continue }
                    phrases[phrase] = prefix
                }
            }
            for (alias, brand) in Self.aliases where phrases[alias] == nil { phrases[alias] = brand }
        }
    }

    /// "TRADER JOE'S" → "Trader Joe's"; "Whole Foods Market, Inc." → "Whole Foods Market".
    static func label(brand: String) -> String {
        var name = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffixes = [", inc.", ", inc", " inc.", " inc", ", llc", " llc", " co.", " corp.", " corp", " company", ", ltd", " ltd"]
        var trimmed = true
        while trimmed {
            trimmed = false
            for suffix in suffixes where name.lowercased().hasSuffix(suffix) {
                name = String(name.dropLast(suffix.count)).trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
                trimmed = true
            }
        }
        if name.lowercased().hasPrefix("the ") { name = String(name.dropFirst(4)) }
        let letters = name.filter(\.isLetter)
        if !letters.isEmpty, letters == letters.uppercased() {
            // Capitalise each word, leaving what follows an apostrophe small ("Joe's", not "Joe'S").
            name = name.split(separator: " ").map { word in
                word.prefix(1).uppercased() + word.dropFirst().lowercased()
            }.joined(separator: " ")
        }
        return name
    }

    /// A brand's first one, two and three words, folded, each with the label up to there.
    static func prefixes(of label: String) -> [(phrase: String, prefix: String)] {
        var out: [(String, String)] = []
        var folded: [String] = []
        var tokens: [Substring] = []
        for token in label.split(separator: " ") {
            tokens.append(token)
            let added = words(String(token))
            guard !added.isEmpty else { continue }
            folded += added
            out.append((folded.joined(separator: " "), tokens.joined(separator: " ")))
            if folded.count >= 3 { break }
        }
        return out
    }

    /// The brand a search names, at its start ("trader joes carrots") or its end ("carrots from
    /// trader joes"), and the words left: the food. Never the whole search, and never words that
    /// name a food (`isFood`): "baby carrots raw" is carrots, whatever some company is called.
    static func brand(in query: String, index: BrandIndex,
                      isFood: (String) -> Bool = { _ in false }) -> (brand: Brand, food: [String])? {
        let all = words(query)
        guard all.count >= 2 else { return nil }
        for length in stride(from: min(3, all.count - 1), through: 1, by: -1) {
            for (phrase, rest) in [(Array(all.prefix(length)), Array(all.dropFirst(length))),
                                   (Array(all.suffix(length)), Array(all.dropLast(length)))] {
                let joined = phrase.joined(separator: " ")
                if let name = index.phrases[joined], BrandIndex.aliases[joined] != nil || !isFood(joined) {
                    return (Brand(name: name, words: phrase), rest)
                }
            }
        }
        return nil
    }

    /// Whether some of these foods are named by every one of the words: "baby carrot" is
    /// "Carrots, baby, raw"; "trader joe" names nothing.
    static func names(_ phrase: String, among matches: [FoodMatch]) -> Bool {
        let wanted = Set(words(phrase))
        return !wanted.isEmpty && matches.contains {
            !$0.reference.id.hasPrefix("branded:") && wanted.isSubset(of: Set(words($0.reference.name)))
        }
    }

    // MARK: - Amounts

    /// Grams of an amount; nil for a count of what was logged.
    static func grams(_ amount: Amount) -> Double? {
        switch amount.unit {
        case .portion(let portion): amount.count * portion.grams
        case .grams: amount.count
        case .ounces: amount.count * ounce
        case .servings: nil
        }
    }

    /// The result as an item at an amount, under the name given (its own when blank). Numbers
    /// from a database follow the weight; something of yours without one scales by the count.
    static func item(_ result: Result, amount: Amount, name: String) -> MealItem {
        var item = result.item
        item.id = UUID()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        item.name = trimmed.isEmpty ? result.item.name : trimmed
        item.confidence = 1
        if let grams = grams(amount), item.reference != nil || (item.grams ?? 0) > 0 {
            item = item.withGrams(grams)
        } else {
            item.macros = PortionScaling.scaled(result.item.macros, by: amount.count)
        }
        item.serving = serving(amount, base: result.item.serving)
        return item
    }

    /// "1½ cups · 180 g", "3 oz · 85 g", "120 g", "2 × 1 bowl".
    static func serving(_ amount: Amount, base: String = "") -> String {
        let count = number(amount.count)
        switch amount.unit {
        case .portion(let portion):
            let measure = amount.count == 1 ? NutritionText.measure(portion.label) : counted(portion.label, count: count)
            return GroundedFoodEstimate.serving(measure, grams: amount.count * portion.grams)
        case .grams:
            return "\(Int(amount.count.rounded())) g"
        case .ounces:
            return "\(count) oz \u{00B7} \(Int((amount.count * ounce).rounded())) g"
        case .servings:
            let base = base.trimmingCharacters(in: .whitespacesAndNewlines)
            if amount.count == 1 { return base.isEmpty ? "1 serving" : base }
            return base.isEmpty ? "\(count) servings" : "\(count) \u{00D7} \(base)"
        }
    }

    /// Measures whose first word is the thing counted: "1 cup chopped" → "2 cups chopped".
    private static let unitWords: Set<String> = [
        "cup", "tablespoon", "teaspoon", "slice", "piece", "serving", "stick", "container", "package",
        "can", "bottle", "bar", "link", "patty", "fillet", "bowl", "plate", "scoop", "handful", "pouch",
    ]
    private static let abbreviations: Set<String> = ["oz", "g", "tbsp", "tsp", "ml", "lb", "fl", "cups", "pieces"]

    /// "1 baby carrot" at 10 → "10 baby carrots"; "typical portion" at 2 → "2 × typical portion".
    static func counted(_ label: String, count: String) -> String {
        guard label.hasPrefix("1 ") else { return "\(count) \u{00D7} \(label)" }
        var rest = String(label.dropFirst(2))
        let head = rest.prefix { $0.isLetter }
        if unitWords.contains(String(head).lowercased()) {
            rest = plural(String(head)) + String(rest.dropFirst(head.count))
        } else {
            let cut = rest.firstIndex { $0 == "," || $0 == "(" } ?? rest.endIndex
            let phrase = rest[..<cut].trimmingCharacters(in: .whitespaces)
            let lastWord = phrase.split(separator: " ").last.map(String.init) ?? ""
            if !lastWord.isEmpty, !abbreviations.contains(lastWord.lowercased()), lastWord.allSatisfy(\.isLetter) {
                rest = String(phrase.dropLast(lastWord.count)) + plural(lastWord) + rest[cut...]
            }
        }
        return "\(count) \(rest)"
    }

    private static func plural(_ word: String) -> String {
        let lower = word.lowercased()
        if lower.hasSuffix("s") || abbreviations.contains(lower) { return word }
        if lower.hasSuffix("ch") || lower.hasSuffix("sh") || lower.hasSuffix("x") { return word + "es" }
        if lower.hasSuffix("y"), let before = lower.dropLast().last, !"aeiou".contains(before) {
            return String(word.dropLast()) + "ies"
        }
        return word + "s"
    }

    /// ¼, ½, 1¾, 2, 0.3.
    static func number(_ value: Double) -> String {
        let whole = Int(value)
        let fraction = value - Double(whole)
        let symbols: [(Double, String)] = [(0.25, "\u{00BC}"), (0.5, "\u{00BD}"), (0.75, "\u{00BE}")]
        if abs(fraction) < 0.001 { return "\(whole)" }
        if let symbol = symbols.first(where: { abs($0.0 - fraction) < 0.001 }) {
            return (whole == 0 ? "" : "\(whole)") + symbol.1
        }
        return value.formatted(.number.precision(.fractionLength(0...2)))
    }

    /// One step more or less: a quarter of a measure under one, a half above; 1 oz; grams by
    /// 1 under 20 g, 5 under 100 g and 10 above — a sheet of seaweed is 3 g, a bowl of rice 200.
    static func stepped(_ amount: Amount, by direction: Int) -> Amount {
        var amount = amount
        let step: Double
        let down = direction < 0
        switch amount.unit {
        case .grams: step = amount.count < 20 || (down && amount.count <= 20) ? 1
            : amount.count < 100 || (down && amount.count <= 100) ? 5 : 10
        case .ounces: step = 1
        case .portion, .servings: step = amount.count < 1 || (direction < 0 && amount.count <= 1) ? 0.25 : 0.5
        }
        let next = ((amount.count + Double(direction) * step) / step).rounded() * step
        amount.count = max(step, next)
        return amount
    }

    /// The same weight in another unit, rounded to what that unit counts in: whole grams, a
    /// quarter of a measure or an ounce. A count of what was logged can't be weighed: it stays.
    static func converted(_ amount: Amount, to unit: Amount.Unit) -> Amount {
        guard let grams = grams(amount) else { return Amount(count: amount.count, unit: unit) }
        switch unit {
        case .grams: return Amount(count: max(1, grams.rounded()), unit: .grams)
        case .ounces: return Amount(count: max(0.25, (grams / ounce * 4).rounded() / 4), unit: .ounces)
        case .portion(let portion):
            guard portion.grams > 0 else { return Amount(count: 1, unit: unit) }
            return Amount(count: max(0.25, (grams / portion.grams * 4).rounded() / 4), unit: unit)
        case .servings: return Amount(count: 1, unit: .servings)
        }
    }

    /// Where a result starts: your usual weight in the measure it was logged in, when that's one
    /// of its measures and the weight is close to a quarter of it (so the amount isn't changed by
    /// saying it), else in grams; for a database food its first measure, else 100 g.
    static func startAmount(portions: [FoodPortion], grams: Double?, serving: String = "") -> Amount {
        if let grams, grams > 0 {
            // The measure the serving names: "1½ cups · 180 g" is in cups.
            let logged = Set(words(serving))
            let named = portions.filter { $0.grams > 0 && !words($0.label).isEmpty && Set(words($0.label)).isSubset(of: logged) }
            if let portion = named.max(by: { words($0.label).count < words($1.label).count }) {
                let count = grams / portion.grams
                let quarters = max(0.25, (count * 4).rounded() / 4)
                if abs(quarters - count) <= count * 0.05 { return Amount(count: quarters, unit: .portion(portion)) }
            }
            return Amount(count: grams.rounded(), unit: .grams)
        }
        if let first = portions.first(where: { $0.grams > 0 }) { return Amount(count: 1, unit: .portion(first)) }
        return Amount(count: 100, unit: .grams)
    }

    // MARK: - The amount of something in a meal

    /// What an amount can be counted in: the food's own measures, then grams and ounces — or,
    /// for something with no weight, only servings of what was logged.
    static func units(portions: [FoodPortion], weighable: Bool) -> [Amount.Unit] {
        guard weighable else { return [.servings] }
        return portions.filter { $0.grams > 0 }.map { .portion($0) } + [.grams, .ounces]
    }

    /// A measure as named beside its count: "regular · 200 g", "cup, sliced · 104 g", "grams",
    /// "× 1 can". `serving`: one of what was logged, for something counted in servings.
    static func unitName(_ unit: Amount.Unit, serving: String = "") -> String {
        switch unit {
        case .portion(let portion):
            let label = portion.label.hasPrefix("1 ") ? String(portion.label.dropFirst(2)) : portion.label
            return "\(label) \u{00B7} \(Int(portion.grams.rounded())) g"
        case .grams: return "grams"
        case .ounces: return "ounces"
        case .servings:
            let base = serving.trimmingCharacters(in: .whitespacesAndNewlines)
            return base.isEmpty ? "servings" : "\u{00D7} \(base)"
        }
    }

    /// A measure as a chip to tap: "g", "oz", "cup", "regular", "package" — the count and what
    /// one weighs are beside it (`unitName`).
    static func unitChip(_ unit: Amount.Unit) -> String {
        switch unit {
        case .portion(let portion):
            let label = portion.label.hasPrefix("1 ") ? String(portion.label.dropFirst(2)) : portion.label
            return label.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? label
        case .grams: return "g"
        case .ounces: return "oz"
        case .servings: return "servings"
        }
    }

    /// Where something already in a meal starts: in the measure its serving names when saying so
    /// doesn't change its weight ("1/2 cup · 60 g" is ½ cup), else in grams. Something without a
    /// weight is one of what was logged.
    static func amount(of item: MealItem, portions: [FoodPortion]) -> Amount {
        guard let grams = item.grams, grams > 0 else {
            // A food whose numbers follow its weight, with no weight yet: grams, to be said.
            return item.reference != nil ? Amount(count: 0, unit: .grams) : Amount(count: 1, unit: .servings)
        }
        return startAmount(portions: portions, grams: grams, serving: item.serving)
    }

    /// Something in a meal at another amount. With a weight its numbers follow it (from its food
    /// when it has one); counted in servings, it's `base` — as first logged — times the count.
    static func item(_ item: MealItem, at amount: Amount, base: MealItem) -> MealItem {
        if let grams = grams(amount), item.reference != nil || (item.grams ?? 0) > 0 {
            var updated = item.withGrams(grams)
            updated.serving = serving(amount)
            return updated
        }
        var updated = item
        updated.macros = PortionScaling.scaled(base.macros, by: amount.count)
        updated.serving = serving(Amount(count: amount.count, unit: .servings), base: base.serving)
        updated.grams = base.grams.map { $0 * amount.count }
        return updated
    }

    // MARK: - Which foods

    /// The word a search is about: the last of its food's words, before any "with" — "carrot"
    /// of "trader joes cut and peeled carrots", "oatmeal" of "oatmeal with blueberries".
    static func head(of query: String, brand: Brand?) -> String? {
        let lowered = " " + query.lowercased() + " "
        let main = lowered.components(separatedBy: " with ").first ?? lowered
        var food = words(main.replacingOccurrences(of: " w/ ", with: " with "))
        if let brand { food = food.filter { !brand.words.contains($0) } }
        return food.last ?? words(query).last
    }

    /// The foods worth showing for a search: those with its head word as a whole word ("Carrots,
    /// raw", not "Lamb, NS as to cut"; "Scallops, fried", not "Potato, scalloped"), each name
    /// once, the ones named for it ("Carrots, …") before those that only have some ("Peas and
    /// carrots"). When none has it, the database's own order.
    static func focused(_ matches: [FoodMatch], head: String?, limit: Int) -> [FoodMatch] {
        var seen = Set<String>()
        let unique = matches.filter { seen.insert($0.reference.name.lowercased()).inserted }
        guard let head else { return Array(unique.prefix(limit)) }
        let having = unique.filter { words($0.reference.name).contains(head) }
        guard !having.isEmpty else { return Array(unique.prefix(limit)) }
        func namedFor(_ match: FoodMatch) -> Bool {
            let first = match.reference.name.split(separator: ",").first.map(String.init) ?? match.reference.name
            return words(first).contains(head)
        }
        let ordered = having.filter(namedFor) + having.filter { !namedFor($0) }
        return Array(ordered.prefix(limit))
    }

    // MARK: - From the database

    /// A bundled USDA food or product as a result, at its first measure.
    static func result(_ match: FoodMatch, section: Section) -> Result {
        let start = startAmount(portions: match.portions, grams: nil)
        let grams = grams(start) ?? 100
        let name = GroundedFoodEstimate.displayName(match.reference.name)
        let item = MealItem(name: name, serving: serving(start), macros: match.reference.macros(grams: grams),
                            confidence: 1, grams: grams, reference: match.reference)
        return Result(id: match.reference.id, section: section, name: name,
                      detail: section == .products ? "USDA branded" : "USDA", item: item, portions: match.portions, start: start)
    }

    /// Bundled matches split into foods and products, each `focused` on the head word; with a
    /// brand named, only that brand's products.
    static func split(_ matches: [FoodMatch], brand: Brand?, head: String?, limit: Int) -> (foods: [Result], products: [Result]) {
        let generic = matches.filter { !$0.reference.id.hasPrefix("branded:") }
        var branded = matches.filter { $0.reference.id.hasPrefix("branded:") }
        if let brand {
            branded = branded.filter { brand.words.allSatisfy(Set(words($0.reference.name)).contains) }
        }
        return (focused(generic, head: head, limit: limit).map { result($0, section: .foods) },
                focused(branded, head: head, limit: limit).filter { match in
                    head.map { words(match.reference.name).contains($0) } ?? true
                }.map { result($0, section: .products) })
    }

    // MARK: - Open Food Facts

    static let searchFields = "code,product_name,brands,nutriments,serving_quantity,serving_size,product_quantity"

    /// The search sent to Open Food Facts. With a brand: the food's last word — its head noun,
    /// in English — of that brand ("carrots AND brands:\"trader joe's\""): its search can't OR
    /// words together, and a brand's whole range is short enough to rank here. Without one: the
    /// words, kept below only when a product's name has every one.
    static func onlineURL(_ query: String, brand: Brand?) -> URL? {
        var typed = words(query, singular: false)
        if let brand { typed = typed.filter { !brand.words.contains(singular($0)) } }
        let q: String
        if let brand {
            let name = brand.name.lowercased().replacingOccurrences(of: "\"", with: "")
            q = typed.last.map { "\($0) AND brands:\"\(name)\"" } ?? "brands:\"\(name)\""
        } else {
            guard !typed.isEmpty else { return nil }
            q = typed.joined(separator: " ")
        }
        var components = URLComponents(string: "https://search.openfoodfacts.org/search")
        components?.queryItems = [
            URLQueryItem(name: "q", value: q),
            URLQueryItem(name: "page_size", value: "24"),
            URLQueryItem(name: "langs", value: "en"),
            URLQueryItem(name: "fields", value: searchFields),
        ]
        return components?.url
    }

    /// Open Food Facts' answer as results: products with calories per 100 g whose names have a
    /// word of the food (every word, without a brand), each once — those that are the food
    /// first, then the best covered, at most `limit`.
    static func products(fromSearch data: Data, food: [String], brand: Brand?, limit: Int = 8) -> [Result] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hits = object["hits"] as? [[String: Any]] else { return [] }
        struct Ranked { var result: Result; var about: Bool; var covered: Int; var extra: Int; var order: Int }
        // A product is about what its name ends in: "Organic Whole Carrots" are carrots, "Carrot
        // Ginger Soup" is soup.
        let head = food.last
        var ranked: [Ranked] = []
        var seen = Set<String>()
        for (order, hit) in hits.enumerated() {
            guard let code = hit["code"] as? String, !code.isEmpty,
                  let nutriments = hit["nutriments"] as? [String: Any],
                  let kcal = numeric(nutriments["energy-kcal_100g"]), kcal >= 0, kcal <= 900 else { continue }
            let hitBrand = brands(hit["brands"]).first.map(label(brand:)) ?? brand?.name
            guard let name = productName(hit["product_name"] as? String, brands: [hitBrand, brand?.name].compactMap { $0 }) else { continue }
            let nameWords = Set(words(name))
            let covered = food.filter(nameWords.contains).count
            if brand == nil {
                guard !food.isEmpty, covered == food.count else { continue }
            } else if !food.isEmpty, covered == 0 {
                continue
            }
            let shown = hitBrand.map { brandName in
                Set(words(brandName)).isSubset(of: nameWords) ? name : "\(brandName) \(name)"
            } ?? name
            guard seen.insert(key(shown)).inserted else { continue }
            let per100g = NutritionMacros(calories: kcal, proteinGrams: numeric(nutriments["proteins_100g"]) ?? 0,
                                          carbohydrateGrams: numeric(nutriments["carbohydrates_100g"]) ?? 0,
                                          fatGrams: numeric(nutriments["fat_100g"]) ?? 0)
            var portions: [FoodPortion] = []
            if let grams = numeric(hit["serving_quantity"]), grams > 0, grams <= 2_000 {
                let size = (hit["serving_size"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
                portions.append(FoodPortion(label: size.isEmpty ? "1 serving" : "1 serving (\(size))", grams: grams))
            }
            if let package = numeric(hit["product_quantity"]), package > (portions.first?.grams ?? 0), package <= 5_000 {
                portions.append(FoodPortion(label: "1 package", grams: package))
            }
            let reference = FoodReference(id: "off:\(code)", name: shown, per100g: per100g)
            let start = startAmount(portions: portions, grams: nil)
            let grams = grams(start) ?? 100
            let item = MealItem(name: shown, serving: serving(start), macros: reference.macros(grams: grams),
                                confidence: 1, grams: grams, reference: reference)
            let result = Result(id: reference.id, section: .products, name: shown,
                                detail: "Open Food Facts",
                                item: item, portions: portions, start: start)
            let brandWords = Set(hitBrand.map { words($0) } ?? [])
            let extra = nameWords.subtracting(food).subtracting(brandWords).count
            let about = head != nil && words(name).last == head
            ranked.append(Ranked(result: result, about: about, covered: covered, extra: extra, order: order))
        }
        return ranked.sorted {
            ($0.about ? 1 : 0, $0.covered, -$0.extra, -$0.order) > ($1.about ? 1 : 0, $1.covered, -$1.extra, -$1.order)
        }.prefix(limit).map(\.result)
    }

    /// "Spinach Dip - Trader Joe's - Trader Joe's" → "Spinach Dip": the parts that are only the
    /// brand go. Nil when nothing else is left.
    static func productName(_ raw: String?, brands: [String]) -> String? {
        guard let raw else { return nil }
        let brandKeys = Set(brands.map { key($0) })
        let parts = raw.components(separatedBy: " - ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !brandKeys.contains(key($0)) }
        guard let first = parts.first, !words(first).isEmpty else { return nil }
        return GroundedFoodEstimate.displayName(parts.joined(separator: " - "))
    }

    private static func brands(_ value: Any?) -> [String] {
        if let list = value as? [String] { return list.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        if let text = value as? String {
            return text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return []
    }

    /// A number Open Food Facts may send as a number or a string.
    private static func numeric(_ value: Any?) -> Double? {
        let number: Double?
        if let value = value as? Double { number = value }
        else if let value = value as? Int { number = Double(value) }
        else if let value = value as? String { number = Double(value.trimmingCharacters(in: .whitespaces)) }
        else { number = nil }
        return number.flatMap { $0.isFinite ? $0 : nil }
    }

    // MARK: - Yours

    /// What you've logged that the words name — by its name, or the food behind it — and your
    /// scanned packages, at your usual amount. Anything picked for these words before comes first,
    /// then the most had. A brand in the words needn't be in the name: "Trader Joe's carrots"
    /// finds the carrots you logged.
    static func yours(_ query: String, meals: [MealEntry], myFoods: [MyFood], picked: [String: Int],
                      brand: Brand?, portions: (String) -> [FoodPortion] = { _ in [] },
                      now: Date = Date(), limit: Int = 6) -> [Result] {
        var food = words(query)
        if let brand { food = food.filter { !brand.words.contains($0) } }
        guard !food.isEmpty || !picked.isEmpty else { return [] }
        func named(_ names: [String]) -> Bool {
            !food.isEmpty && Set(food).isSubset(of: Set(names.flatMap { words($0) }))
        }

        struct Tally { var times = 0; var last: (date: Date, item: MealItem); var grams: [Double] = [] }
        var tallies: [String: Tally] = [:]
        for meal in meals where meal.date <= now {
            for item in meal.items {
                let key = MyFoods.key(item.name)
                guard !key.isEmpty else { continue }
                var tally = tallies[key] ?? Tally(last: (meal.date, item))
                tally.times += 1
                if meal.date >= tally.last.date { tally.last = (meal.date, item) }
                if let grams = item.grams, grams > 0 { tally.grams.append(grams) }
                tallies[key] = tally
            }
        }

        struct Found { var result: Result; var picks: Int; var times: Int; var last: Date }
        var found: [String: Found] = [:]
        for (key, tally) in tallies {
            let item = tally.last.item
            let picks = item.reference.map { picked[$0.id] ?? 0 } ?? 0
            guard picks > 0 || named([item.name, item.reference?.name ?? ""]) else { continue }
            // Your usual amount: the middle of the last few weights.
            var usual = item
            let recent = tally.grams.suffix(5).sorted()
            if !recent.isEmpty, let grams = usual.grams, grams > 0 {
                let middle = recent[recent.count / 2]
                if abs(middle - grams) > 0.5 { usual = usual.withGrams(middle) }
            }
            let measures = usual.reference.map { portions($0.id) } ?? []
            let start = usual.grams.map { startAmount(portions: measures, grams: $0, serving: item.serving) }
                ?? Amount(count: 1, unit: .servings)
            usual.serving = start.unit == .servings ? item.serving : serving(start)
            usual.id = UUID()
            let detail = "Had \(tally.times == 1 ? "once" : "\(tally.times) times")"
                + (usual.grams.map { " \u{00B7} usually \(Int($0.rounded())) g" } ?? "")
            found[key] = Found(result: Result(id: "yours:\(key)", section: .yours, name: item.name, detail: detail,
                                              item: usual, portions: measures, start: start),
                               picks: picks, times: tally.times, last: tally.last.date)
        }
        for myFood in myFoods {
            let key = MyFoods.key(myFood.name)
            let picks = picked[myFood.reference.id] ?? 0
            guard found[key] == nil, picks > 0 || named([myFood.name] + myFood.standsFor) else { continue }
            let measures = MyFoods.measures(myFood)
            // One serving, when its package says one; else no amount yet — to be said.
            let start = myFood.servingStated && !measures.isEmpty
                ? Amount(count: 1, unit: .portion(measures[0])) : Amount(count: 0, unit: .grams)
            let startGrams = grams(start) ?? 0
            let item = MealItem(name: myFood.name, serving: serving(start),
                                macros: myFood.reference.macros(grams: startGrams),
                                confidence: 1, grams: startGrams, reference: myFood.reference)
            found[key] = Found(result: Result(id: "yours:\(key)", section: .yours, name: myFood.name,
                                              detail: "Your food",
                                              item: item, portions: measures, start: start),
                               picks: picks, times: 0, last: myFood.addedAt)
        }
        return found.values.sorted {
            ($0.picks, $0.times, $0.last) > ($1.picks, $1.times, $1.last)
        }.prefix(limit).map(\.result)
    }

    /// What you usually have around now, as results: for an empty search.
    static func usual(_ foods: [UsualFoods.Food], portions: (String) -> [FoodPortion] = { _ in [] },
                      limit: Int = 8) -> [Result] {
        foods.prefix(limit).map { food in
            var item = food.item
            let measures = item.reference.map { portions($0.id) } ?? []
            let start = item.grams.map { startAmount(portions: measures, grams: $0, serving: food.last.serving) }
                ?? Amount(count: 1, unit: .servings)
            if start.unit != .servings { item.serving = serving(start) }
            return Result(id: "yours:\(food.key)", section: .yours, name: food.name,
                          detail: "Had \(food.times) times around now", item: item, portions: measures, start: start)
        }
    }

    /// Picked results first, in how often; the rest as they were.
    static func pickedFirst(_ results: [Result], picked: [String: Int]) -> [Result] {
        guard !picked.isEmpty else { return results }
        return results.enumerated().sorted { a, b in
            let pa = a.element.item.reference.map { picked[$0.id] ?? 0 } ?? 0
            let pb = b.element.item.reference.map { picked[$0.id] ?? 0 } ?? 0
            return pa != pb ? pa > pb : a.offset < b.offset
        }.map(\.element)
    }
}
