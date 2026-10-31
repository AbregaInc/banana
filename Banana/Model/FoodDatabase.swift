import Foundation
import OSLog
import SQLite3

/// A household measure of a food and what it weighs, e.g. "1 cup" = 158 g.
struct FoodPortion: Codable, Hashable, Sendable {
    var label: String
    var grams: Double
}

/// One food from `FoodDatabase`: its numbers per 100 g, its category and its usual portions.
struct FoodMatch: Hashable, Sendable {
    /// id, name, per100g.
    var reference: FoodReference
    var category: String
    /// Most common first, in the source's own order.
    var portions: [FoodPortion]
}

/// The bundled USDA food database (Banana/Resources/Foods.sqlite, built by
/// tools/build_food_database.py), searched by name so a meal estimate can take its numbers from
/// measured data instead of the model's memory. The model names and portions the food; this
/// supplies calories and macros per 100 g.
///
/// Generic foods come from FNDDS (foods as eaten, including mixed dishes), SR Legacy and
/// Foundation Foods. Branded products are the rows of BarcodeProducts.sqlite: Foods.sqlite only
/// holds a name index over them (to stay small), so a branded hit is read back from the products
/// table by barcode.
///
/// Every call opens its own read-only connections and closes them before returning, so it's safe
/// from any thread or actor; there's no shared state beyond immutable constants.
enum FoodDatabase {
    private static let log = Logger(subsystem: "com.boris.banana", category: "food-database")

    /// Branded matches shown after the generic ones, at most.
    static let maxBrandedResults = 3
    /// Portions per line in `toolText` — enough for the model to pick a measure, few enough to
    /// keep a result list short.
    static let maxToolPortions = 6

    // MARK: - Public API

    static func search(_ query: String, limit: Int = 8) -> [FoodMatch] {
        guard let databaseURL = bundledDatabaseURL else {
            log.error("Foods.sqlite missing from bundle")
            return []
        }
        return search(query, limit: limit, databaseURL: databaseURL, productsURL: bundledProductsURL)
    }

    static func food(id: String) -> FoodMatch? {
        guard let databaseURL = bundledDatabaseURL else { return nil }
        return food(id: id, databaseURL: databaseURL, productsURL: bundledProductsURL)
    }

    /// Generic foods first, best first; then, when the query plausibly names a product, up to
    /// three branded products. `productsURL` nil leaves branded products out.
    static func search(_ query: String, limit: Int = 8, databaseURL: URL, productsURL: URL?) -> [FoodMatch] {
        let words = queryWords(query)
        guard !words.isEmpty, limit > 0, let database = FoodSQLite(url: databaseURL) else { return [] }

        let ranked = rankedGenericFoods(words, in: database)
        // A query plausibly names a product when one of its words does (see `productWords`) or
        // no generic food has every word ("chicken tikka masala").
        var branded: [FoodMatch] = []
        let productWords = productWords(words, in: database)
        let genericHasEveryWord = ranked.contains { $0.nameHits == words.count }
        if let productsURL, !productWords.isEmpty || !genericHasEveryWord, let products = FoodSQLite(url: productsURL) {
            branded = brandedFoods(words, keeping: productWords, in: database, products: products)
        }

        // Generic first. Branded products get up to three of the slots — more of them only when
        // there aren't enough generic foods to fill the list.
        let brandedSlots = min(maxBrandedResults, branded.count, max(limit / 2, limit - ranked.count))
        let generic = ranked.prefix(limit - brandedSlots).map { candidate in
            FoodMatch(reference: candidate.reference, category: candidate.category,
                      portions: portions(of: candidate.reference.id, in: database))
        }
        return generic + branded.prefix(brandedSlots)
    }

    static func food(id: String, databaseURL: URL, productsURL: URL?) -> FoodMatch? {
        if id.hasPrefix(brandedPrefix) {
            guard let productsURL, let products = FoodSQLite(url: productsURL) else { return nil }
            return brandedFood(barcode: String(id.dropFirst(brandedPrefix.count)), in: products)
        }
        guard let database = FoodSQLite(url: databaseURL) else { return nil }
        let rows = database.rows("SELECT id, name, category, kcal, protein, carbs, fat FROM foods WHERE id = ?",
                                 [.text(id)]) { row in
            FoodMatch(reference: FoodReference(id: row.text(0), name: row.text(1),
                                               per100g: row.macros(from: 3)),
                      category: row.text(2), portions: [])
        }
        guard var match = rows.first else { return nil }
        match.portions = portions(of: id, in: database)
        return match
    }

    /// What `searchFoods` hands back to the model: one line per match,
    /// "<id> | <name> | per 100 g: 130 kcal, P 2.7 g, C 28 g, F 0.3 g | 1 cup = 158 g; 1 oz = 28 g".
    /// A food with no portions ends after the macros. No matches reads as a sentence rather than
    /// an empty string, so the model knows the search ran and found nothing.
    static func toolText(_ matches: [FoodMatch]) -> String {
        guard !matches.isEmpty else { return "No matching foods." }
        return matches.map { match in
            let per100g = match.reference.per100g
            var fields = [
                match.reference.id,
                pipeFree(match.reference.name),
                "per 100 g: \(Int(per100g.calories.rounded())) kcal, P \(amount(per100g.proteinGrams)) g, "
                    + "C \(amount(per100g.carbohydrateGrams)) g, F \(amount(per100g.fatGrams)) g",
            ]
            let portions = match.portions.prefix(maxToolPortions).map { "\(pipeFree($0.label)) = \(amount($0.grams)) g" }
            if !portions.isEmpty { fields.append(portions.joined(separator: "; ")) }
            return fields.joined(separator: " | ")
        }.joined(separator: "\n")
    }

    /// The brands of the bundled products, with how many products each has — what a search's
    /// words are checked against for a brand (`FoodSearch.BrandIndex`). One pass over the
    /// products table, ~0.15 s on a Mac: read once, off the main thread.
    static func brands(minimumProducts: Int = 3, productsURL: URL? = bundledProductsURL) -> [(name: String, products: Int)] {
        guard let productsURL, let products = FoodSQLite(url: productsURL) else { return [] }
        return products.rows("SELECT brand, count(*) FROM products GROUP BY brand HAVING count(*) >= \(minimumProducts)", []) {
            (name: $0.text(0), products: Int($0.int(1)))
        }
    }

    /// Words the generic names only use as brands ("chobani", "cheerios").
    static func brandWords(databaseURL: URL? = bundledDatabaseURL) -> Set<String> {
        guard let databaseURL, let database = FoodSQLite(url: databaseURL) else { return [] }
        return Set(database.rows("SELECT word FROM brand_words", []) { $0.text(0) })
    }

    static var bundledDatabaseURL: URL? { Bundle.main.url(forResource: "Foods", withExtension: "sqlite") }
    static var bundledProductsURL: URL? { Bundle.main.url(forResource: "BarcodeProducts", withExtension: "sqlite") }

    // MARK: - Query words

    /// Words a query is searched by: lowercased, diacritics folded, split on anything that isn't
    /// a letter or digit — which also strips every FTS operator character, so a quote or a `*` in
    /// the query can't change the search's meaning. Filler words go; so do stray letters (the
    /// "s" of "joe's"). Capped at eight words.
    static func queryWords(_ query: String) -> [String] {
        var result: [String] = []
        for word in words(query) where !stopWords.contains(word) && (word.count > 1 || word.allSatisfy(\.isNumber)) {
            if !result.contains(word) { result.append(word) }
            if result.count == 8 { break }
        }
        return result
    }

    /// The same split tools/build_food_database.py makes of names (`folded_pieces`).
    static func words(_ text: String) -> [String] {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
            .split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
            .map(String.init)
    }

    /// Plural folding, so "fries" meets "fry" and "eggs" meets "egg" when comparing a name's words
    /// with the query's. The FTS index does its own (porter) stemming; this is only for the
    /// ranking's word counts, and must match `crude_stem` in the build script.
    static func stem(_ word: String) -> String {
        if word.count > 4, word.hasSuffix("ies") { return String(word.dropLast(3)) + "y" }
        if word.count > 4, word.hasSuffix("oes") || word.hasSuffix("ches") || word.hasSuffix("shes") {
            return String(word.dropLast(2))
        }
        if word.count > 3, word.hasSuffix("s"), !word.hasSuffix("ss") { return String(word.dropLast()) }
        return word
    }

    private static let stopWords: Set<String> = ["a", "an", "the", "of", "with", "and", "or", "in", "on", "for",
                                                 "to", "some", "my", "from", "at", "as", "by", "w", "without"]
    /// Words that say nothing about which food it is: "Bananas, raw" is as plain as "Bananas".
    private static let fillerWords: Set<String> = stopWords.union(["nfs", "ns", "raw", "plain", "regular", "fresh", "whole"])
    /// Words that end a name's head noun phrase: "Pad Thai with chicken" is still pad thai.
    private static let connectorWords: Set<String> = ["with", "and", "or", "in", "on", "from", "without", "for", "w", "as"]

    // MARK: - Generic foods

    /// A food the full-text search returned, with what the ranking needs to know about it.
    struct GenericCandidate {
        var reference: FoodReference
        var category: String
        /// bm25 over name, head and category (lower is better) — only a tie-breaker.
        var bm25: Double
        /// Query words found in the name.
        var nameHits: Int
        /// Query words found only in the category ("Yogurt, Greek" for a query naming yogurt).
        var categoryHits: Int
        /// Query words found in the name's first comma segment ("Bananas" of "Bananas, raw").
        var headHits: Int
    }

    /// Ranking, in order of weight:
    /// 1. every query word present (a word only in the category counts half);
    /// 2. no words the query didn't ask for — "Bananas, raw" over "Bananas, dehydrated";
    /// 3. the query isn't just modifying some other food — "Salmon salad" is a salad, "Banana
    ///    pudding" a pudding;
    /// 4. FNDDS's own "not further specified" entry, the everyday default of a food;
    /// 5. the words in the name's head, FNDDS over SR/Foundation (it's food as eaten, with
    ///    richer portions), and not an FNDDS recipe-ingredient row.
    static func score(_ candidate: GenericCandidate, queryStems: Set<String>) -> Double {
        let shape = nameShape(candidate.reference.name, queryStems: queryStems)
        var score = 10 * (Double(candidate.nameHits) + 0.5 * Double(candidate.categoryHits))
        score += 1.5 * Double(candidate.headHits)
        score -= 2 * Double(shape.extraWords)
        if shape.modifiesAnotherNoun { score -= 3 }
        // "Chicken, canned, no broth" names broth only to rule it out.
        score -= 10 * Double(shape.negatedQueryWords)
        if shape.hasDefaultSegment { score += 2 }
        if candidate.reference.id.hasPrefix("fndds:") { score += 1 }
        if candidate.category.hasPrefix("Not included") { score -= 1 }
        return score
    }

    struct NameShape: Equatable {
        /// Words in the name the query didn't ask for, ignoring filler and FNDDS's "NFS"/"NS as
        /// to …"/"no added fat" segments.
        var extraWords: Int
        /// A query word in the head is followed by another noun: "Salmon salad" for "salmon".
        var modifiesAnotherNoun: Bool
        /// Has an "NFS" / "NS as to …" / "no added fat" segment after the first.
        var hasDefaultSegment: Bool
        /// Query words the name has only after a "no" or "without".
        var negatedQueryWords = 0
    }

    /// How a food was kept or sold, not what it is: "Tomato sauce, canned, no salt added" is plain
    /// tomato sauce, and ranked below "Tomato chili sauce" while these counted as extra words.
    private static let storageWords: Set<String> = [
        "canned", "products", "product", "ready", "serve", "prepared", "commercial", "commercially",
        "bottled", "jarred", "drained", "solids", "packaged",
    ]
    private static let saltPhrases = #"\b(no salt added|with salt added|without salt added|without salt|with salt|salt added)\b"#

    static func nameShape(_ name: String, queryStems: Set<String>) -> NameShape {
        let withoutAsides = name.replacingOccurrences(of: #"\([^)]*\)"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: saltPhrases, with: " ", options: [.regularExpression, .caseInsensitive])
        let segments = withoutAsides.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        func isDefault(_ segment: String) -> Bool {
            let text = words(segment).joined(separator: " ")
            return text == "nfs" || text == "no added fat" || text == "not further specified" || text.hasPrefix("ns as to ")
        }
        func isExtra(_ word: String) -> Bool {
            word.count > 1 && !fillerWords.contains(word) && !storageWords.contains(word)
                && !word.allSatisfy(\.isNumber) && !queryStems.contains(stem(word))
        }
        var negatedQueryWords = 0
        for segment in segments {
            let segmentWords = words(segment)
            guard let at = segmentWords.firstIndex(where: { $0 == "no" || $0 == "without" }) else { continue }
            negatedQueryWords += segmentWords[(at + 1)...].filter { queryStems.contains(stem($0)) }.count
        }
        let extraWords = segments.filter { !$0.isEmpty && !isDefault($0) }.flatMap(words).filter(isExtra).count

        let head = segments.first.map(words) ?? []
        var modifiesAnotherNoun = false
        if let last = head.lastIndex(where: { queryStems.contains(stem($0)) }) {
            for word in head[(last + 1)...] {
                if connectorWords.contains(word) { break }
                if isExtra(word) { modifiesAnotherNoun = true; break }
            }
        }
        return NameShape(extraWords: extraWords, modifiesAnotherNoun: modifiesAnotherNoun,
                         hasDefaultSegment: segments.dropFirst().contains(where: isDefault),
                         negatedQueryWords: negatedQueryWords)
    }

    /// Candidates are the best 300 by bm25 among foods with every word, plus the best 300 with
    /// any word — so a food missing one word can still show when nothing has them all.
    private static func rankedGenericFoods(_ words: [String], in database: FoodSQLite) -> [GenericCandidate] {
        let quoted = words.map { "\"\($0)\"" }
        var candidates: [Int64: GenericCandidate] = [:]
        let sql = """
            SELECT f.num, f.id, f.name, f.category, f.kcal, f.protein, f.carbs, f.fat, m.score
            FROM (SELECT rowid AS num, bm25(foods_fts, 1.0, 2.0, 0.3) AS score FROM foods_fts
                  WHERE foods_fts MATCH ? ORDER BY score LIMIT 300) AS m
            JOIN foods AS f ON f.num = m.num
            """
        for match in [quoted.joined(separator: " AND "), quoted.joined(separator: " OR ")] {
            for (num, candidate) in database.rows(sql, [.text(match)], { row in
                (row.int(0), GenericCandidate(
                    reference: FoodReference(id: row.text(1), name: row.text(2), per100g: row.macros(from: 4)),
                    category: row.text(3), bm25: row.double(8), nameHits: 0, categoryHits: 0, headHits: 0))
            }) where candidates[num] == nil {
                candidates[num] = candidate
            }
        }
        guard !candidates.isEmpty else { return [] }

        for word in words {
            let inName = database.rowids("SELECT rowid FROM foods_fts WHERE foods_fts MATCH ?", "name : \"\(word)\"")
            let inHead = database.rowids("SELECT rowid FROM foods_fts WHERE foods_fts MATCH ?", "head : \"\(word)\"")
            let inCategory = database.rowids("SELECT rowid FROM foods_fts WHERE foods_fts MATCH ?", "category : \"\(word)\"")
            for num in candidates.keys {
                if inName.contains(num) {
                    candidates[num]?.nameHits += 1
                } else if inCategory.contains(num) {
                    candidates[num]?.categoryHits += 1
                }
                if inHead.contains(num) { candidates[num]?.headHits += 1 }
            }
        }

        let queryStems = Set(words.map(stem))
        return candidates.values
            .map { ($0, score($0, queryStems: queryStems)) }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                if lhs.0.bm25 != rhs.0.bm25 { return lhs.0.bm25 < rhs.0.bm25 }
                if lhs.0.reference.name.count != rhs.0.reference.name.count {
                    return lhs.0.reference.name.count < rhs.0.reference.name.count
                }
                return lhs.0.reference.id < rhs.0.reference.id
            }
            .map(\.0)
    }

    private static func portions(of foodID: String, in database: FoodSQLite) -> [FoodPortion] {
        database.rows("SELECT label, grams FROM portions WHERE food_id = ? ORDER BY seq", [.text(foodID)]) { row in
            FoodPortion(label: row.text(0), grams: row.double(1))
        }
    }

    // MARK: - Branded products

    private static let brandedPrefix = "branded:"

    /// The query's words that name a product rather than a food: a brand ("chobani", "cheerios" —
    /// the build lists words the generic names only ever use as brands) or a word barely seen
    /// among generic foods at all ("rxbar", "fairlife").
    private static func productWords(_ words: [String], in database: FoodSQLite) -> Set<String> {
        Set(words.filter { word in
            let appearances = database.rows(
                "SELECT count(*) FROM (SELECT 1 FROM foods_fts WHERE foods_fts MATCH ? LIMIT 4)",
                [.text("\"\(word)\"")]) { $0.int(0) }.first ?? 0
            return appearances <= 3
                || !database.rows("SELECT 1 FROM brand_words WHERE word = ?", [.text(stem(word))]) { $0.int(0) }.isEmpty
        })
    }

    /// Products with every query word, plainest (shortest name) first — the index's rowid order.
    /// With three or more words and no product having them all, one ordinary word at a time may
    /// be dropped, but never one of `productWords` ("chocolate sea salt" from any maker isn't an
    /// RXBAR), and a two-word query is never loosened, since "diet coke" without "diet" is a
    /// different drink.
    private static func brandedFoods(_ words: [String], keeping productWords: Set<String>, in database: FoodSQLite,
                                     products: FoodSQLite) -> [FoodMatch] {
        let sql = "SELECT rowid FROM branded_fts WHERE branded_fts MATCH ? ORDER BY rowid LIMIT 40"
        func matching(_ words: [String]) -> [Int64] {
            database.rows(sql, [.text(words.map { "\"\($0)\"" }.joined(separator: " AND "))]) { $0.int(0) }
        }
        var rowids = matching(words)
        if rowids.isEmpty, words.count >= 3 {
            var loosened = Set<Int64>()
            for dropped in words where !productWords.contains(dropped) {
                loosened.formUnion(matching(words.filter { $0 != dropped }))
            }
            rowids = Array(loosened.sorted().prefix(60))
        }

        let queryStems = Set(words.map(stem))
        var candidates: [(match: FoodMatch, wordsInName: Int, order: Int)] = []
        for (order, rowid) in rowids.enumerated() {
            guard let product = product(barcode: barcode(fromRowid: rowid), in: products),
                  let match = brandedMatch(product) else { continue }
            let nameStems = Set(Self.words(product.name).map(stem))
            candidates.append((match, queryStems.intersection(nameStems).count, order))
        }
        // Query words in the product's own name beat words only in the brand owner's name.
        candidates.sort { ($0.wordsInName, -$0.order) > ($1.wordsInName, -$1.order) }

        var seen = Set<String>()
        var result: [FoodMatch] = []
        for candidate in candidates where seen.insert(Self.words(candidate.match.reference.name).joined(separator: " ")).inserted {
            result.append(candidate.match)
            if result.count == maxBrandedResults { break }
        }
        return result
    }

    /// The branded index's rowid packs the barcode as `Int(barcode) * 16 + length` (so leading
    /// zeros survive) under an ordering prior in the bits above 51 — see `branded_rowid` in the
    /// build script.
    static func barcode(fromRowid rowid: Int64) -> String {
        let packed = rowid & ((1 << 51) - 1)
        let digits = String(packed / 16)
        let length = Int(packed % 16)
        return String(repeating: "0", count: max(0, length - digits.count)) + digits
    }

    struct Product: Equatable {
        var barcode: String
        var name: String
        var brand: String
        var serving: String
        var perServing: NutritionMacros
    }

    private static func product(barcode: String, in products: FoodSQLite) -> Product? {
        products.rows("SELECT barcode, name, brand, serving, calories, protein, carbs, fat FROM products WHERE barcode = ?",
                      [.text(barcode)]) { row in
            Product(barcode: row.text(0), name: row.text(1), brand: row.text(2), serving: row.text(3),
                    perServing: row.macros(from: 4))
        }.first
    }

    private static func brandedFood(barcode: String, in products: FoodSQLite) -> FoodMatch? {
        product(barcode: barcode, in: products).flatMap(brandedMatch)
    }

    /// A product as a food: per-100 g numbers derived from its labelled serving's weight, and that
    /// serving as its one portion. Nil for the rows the build leaves out of the index — no
    /// weight in the serving text, all zeros that aren't a zero-calorie drink (the catalog stores
    /// a missing value as 0), calories missing beside real macros, or impossible density.
    static func brandedMatch(_ product: Product) -> FoodMatch? {
        guard let grams = servingGrams(product.serving), grams > 0 else { return nil }
        let serving = product.perServing
        let macroEnergy = 4 * serving.proteinGrams + 4 * serving.carbohydrateGrams + 9 * serving.fatGrams
        let allZero = serving.calories <= 0 && serving.proteinGrams <= 0 && serving.carbohydrateGrams <= 0 && serving.fatGrams <= 0
        if allZero && product.name.range(of: zeroCaloriePattern, options: [.regularExpression, .caseInsensitive]) == nil {
            return nil
        }
        if serving.calories <= 0 && macroEnergy > 5 { return nil }
        let factor = 100 / grams
        let per100g = NutritionMacros(calories: serving.calories * factor, proteinGrams: serving.proteinGrams * factor,
                                      carbohydrateGrams: serving.carbohydrateGrams * factor, fatGrams: serving.fatGrams * factor)
        guard per100g.calories <= 950,
              per100g.proteinGrams + per100g.carbohydrateGrams + per100g.fatGrams <= 105 else { return nil }
        return FoodMatch(
            reference: FoodReference(id: brandedPrefix + product.barcode,
                                     name: BarcodeProductLookup.combinedName(brand: product.brand, product: product.name),
                                     per100g: per100g),
            category: "Branded product",
            portions: [FoodPortion(label: servingLabel(product.serving), grams: grams)])
    }

    /// Same list as `ZERO_CALORIE_NAME` in the build script.
    private static let zeroCaloriePattern =
        #"\b(diet|zero|sugar[- ]free|calorie[- ]free|0 ?cal\w*|water|seltzer|club soda|unsweetened|black coffee|tea)\b"#

    /// Grams in one labelled serving: the last metric amount in the text ("1 bar (52 g)",
    /// "2 cups (28g) (28 GRM)"; mL counts as grams, since the per-100 g figure comes from the same
    /// serving), else ounces ("1 ONZ" = 28.35 g). Fluid ounces aren't a weight and give nil unless
    /// a metric amount is there too. Must match `serving_grams` in the build script.
    static func servingGrams(_ serving: String) -> Double? {
        if let metric = lastNumber(matching: metricServing, in: serving) { return metric }
        return lastNumber(matching: ounceServing, in: serving).map { $0 * 28.35 }
    }

    private static let metricServing = try! NSRegularExpression(
        pattern: #"(\d+(?:\.\d+)?)\s*(g|grm|gram|grams|ml|mlt)\b"#, options: .caseInsensitive)
    private static let ounceServing = try! NSRegularExpression(
        pattern: #"\b(\d+(?:\.\d+)?)\s*(oz|onz)\b"#, options: .caseInsensitive)

    private static func lastNumber(matching regex: NSRegularExpression, in text: String) -> Double? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.matches(in: text, range: range).last,
              let number = Range(match.range(at: 1), in: text) else { return nil }
        return Double(text[number])
    }

    /// The serving as a person says it: "1 Container (128g) (128 GRM)" → "1 container",
    /// "1 ONZ (28 g)" → "1 oz". A serving that is only a weight ("150 g") becomes "1 serving",
    /// since "150 g = 150 g" tells the model nothing.
    static func servingLabel(_ serving: String) -> String {
        var label = serving.replacingOccurrences(
            of: #"\s*\([^)]*\d[^)]*\)"#, with: "", options: .regularExpression)
        label = label.replacingOccurrences(of: #"\bONZ\b"#, with: "oz", options: [.regularExpression, .caseInsensitive])
        label = label.replacingOccurrences(of: #"\bOZA\b"#, with: "fl oz", options: [.regularExpression, .caseInsensitive])
        label = label.replacingOccurrences(of: #"\bGRM\b"#, with: "g", options: [.regularExpression, .caseInsensitive])
        label = label.replacingOccurrences(of: #"\bMLT\b"#, with: "mL", options: [.regularExpression, .caseInsensitive])
        label = label.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
        let onlyWeight = label.range(of: #"^\d+(\.\d+)?\s*(g|gram|grams|ml)?$"#, options: .regularExpression) != nil
        if label.isEmpty || label == "none" || onlyWeight { return "1 serving" }
        return label
    }

    // MARK: - Formatting

    /// Below 10 to one decimal ("2.7", "0.3"), otherwise whole ("28", "158").
    static func amount(_ value: Double) -> String {
        if abs(value) < 9.95 {
            let text = String(format: "%.1f", value)
            return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
        }
        return String(Int(value.rounded()))
    }

    private static func pipeFree(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "/")
    }
}

// MARK: - SQLite

/// One read-only connection for the length of a call. Connections are opened NOMUTEX, so none is
/// ever shared between threads: each search opens its own, which costs little next to the
/// queries it runs.
private final class FoodSQLite {
    enum Argument { case text(String) }

    struct Row {
        let statement: OpaquePointer
        func text(_ column: Int32) -> String {
            sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
        }
        func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
        func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
        /// kcal, protein, carbs, fat in four columns starting at `column`.
        func macros(from column: Int32) -> NutritionMacros {
            NutritionMacros(calories: double(column), proteinGrams: double(column + 1),
                            carbohydrateGrams: double(column + 2), fatGrams: double(column + 3))
        }
    }

    private let handle: OpaquePointer

    init?(url: URL) {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let handle else {
            sqlite3_close(handle)
            return nil
        }
        self.handle = handle
    }

    deinit { sqlite3_close(handle) }

    func rows<T>(_ sql: String, _ arguments: [Argument], _ read: (Row) -> T) -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            return []
        }
        defer { sqlite3_finalize(statement) }
        for (index, argument) in arguments.enumerated() {
            switch argument {
            case .text(let value): sqlite3_bind_text(statement, Int32(index + 1), value, -1, SQLITE_TRANSIENT)
            }
        }
        var result: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(read(Row(statement: statement)))
        }
        return result
    }

    func rowids(_ sql: String, _ match: String) -> Set<Int64> {
        Set(rows(sql, [.text(match)]) { $0.int(0) })
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
