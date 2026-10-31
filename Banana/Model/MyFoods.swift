import Foundation

/// A food you have: scanned once — its barcode, or the Nutrition Facts on the package — and
/// remembered, with how much of it you usually have. You buy the same things from the same
/// shops, so after the first scan "gnocchi" in a photo or a note is your Trader Joe's Pumpkin
/// Gnocchi, at your usual amount (`MyFoods.match`, `GroundedFoodEstimate`). Synced
/// (`ControlKind.myFood`, `MyFoodsStore`).
struct MyFood: Codable, Hashable, Identifiable, Sendable {
    enum Source: String, Codable, Sendable { case barcode, label }

    struct Use: Codable, Hashable, Sendable {
        var at: Date
        var grams: Double
    }

    var id = UUID()
    var name: String
    var barcode: String?
    var per100g: NutritionMacros
    /// "1 cup", with what it weighs.
    var servingLabel: String
    var servingGrams: Double
    var packageGrams: Double?
    /// False when the product gives its numbers per 100 g and no serving: `servingLabel` is then
    /// "100 g", and nothing is ever counted in servings of it — a pack of seaweed has no "one
    /// serving", and 100 g of it is nobody's portion.
    var servingStated = true
    /// Informational (`MyFoods.numbersRevision`): nothing decides on it, because a build that
    /// doesn't know the field saves a food back without it.
    var numbers = MyFoods.numbersRevision
    var source: Source
    var addedAt = Date()
    /// The times you had it, oldest first — what "your usual" is worked out from. Not stored: read
    /// off the meal log (`MyFoods.uses(in:)`), every meal item that came from this food, so a use
    /// is counted once whichever device logged it.
    var uses: [Use] = []
    /// Names it has stood in for ("gnocchi", "pumpkin gnocchi"), as `MyFoods.key` writes them.
    var standsFor: [String] = []
    /// The days you bought it, oldest first: each time it's scanned in after shopping
    /// (`MyFoods.purchased`). Stored and synced, unlike `uses`. Empty on a food scanned before
    /// this was kept: its `addedAt` is then its one purchase.
    var bought: [Date] = []

    private enum CodingKeys: String, CodingKey {
        case id, name, barcode, per100g, servingLabel, servingGrams, packageGrams, source, addedAt, standsFor
        case servingStated, numbers, bought
    }

    var reference: FoodReference {
        FoodReference(id: MyFoods.referencePrefix + id.uuidString, name: name, per100g: per100g)
    }

    var lastUsed: Date? { uses.last?.at }
    /// When you last bought it: its last purchase, else when it was first scanned.
    var lastBought: Date { bought.last ?? addedAt }

    init(id: UUID = UUID(), name: String, barcode: String? = nil, per100g: NutritionMacros, servingLabel: String,
         servingGrams: Double, packageGrams: Double? = nil, servingStated: Bool = true, source: Source,
         addedAt: Date = Date(), uses: [Use] = [], standsFor: [String] = [], bought: [Date] = []) {
        self.id = id
        self.name = name
        self.barcode = barcode
        self.per100g = per100g
        self.servingLabel = servingLabel
        self.servingGrams = servingGrams
        self.packageGrams = packageGrams
        self.servingStated = servingStated
        self.source = source
        self.addedAt = addedAt
        self.uses = uses
        self.standsFor = standsFor
        self.bought = bought
    }

    /// Tolerant: a field a later build adds can't cost the food.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        barcode = try c.decodeIfPresent(String.self, forKey: .barcode)
        per100g = try c.decode(NutritionMacros.self, forKey: .per100g)
        servingLabel = try c.decodeIfPresent(String.self, forKey: .servingLabel) ?? "1 serving"
        servingGrams = try c.decodeIfPresent(Double.self, forKey: .servingGrams) ?? 100
        packageGrams = try c.decodeIfPresent(Double.self, forKey: .packageGrams)
        source = (try? c.decodeIfPresent(Source.self, forKey: .source)) ?? .label
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
        standsFor = try c.decodeIfPresent([String].self, forKey: .standsFor) ?? []
        bought = try c.decodeIfPresent([Date].self, forKey: .bought) ?? []
        servingStated = try c.decodeIfPresent(Bool.self, forKey: .servingStated) ?? true
        // Stored before the field existed: before the numbers were right.
        numbers = try c.decodeIfPresent(Int.self, forKey: .numbers) ?? 1
    }
}

enum MyFoods {
    static let referencePrefix = "myfood:"
    /// Uses counted per food, newest: plenty for "usual" and for ranking.
    static let keptUses = 20
    /// A use this many days old counts half: what you have now matters more than last spring.
    static let halfLife: Double = 45
    /// A purchase this many days old counts half: groceries are eaten within a week or two.
    static let purchaseHalfLife: Double = 10
    /// Bought within this many days and not had since: offered as something you have in.
    static let justBoughtDays: Double = 21
    /// Purchases kept per food, newest.
    static let keptPurchases = 20

    /// The same words in any order and form: "Pumpkin Gnocchi" and "gnocchi, pumpkin" alike.
    static func key(_ name: String) -> String {
        GroundedFoodEstimate.words(name).sorted().joined(separator: " ")
    }

    // MARK: - From a scan

    /// From a product a barcode found: its nutrition is per serving, so it needs the serving's weight.
    static func food(name: String, barcode: String?, servingLabel: String, servingGrams: Double,
                     perServing: NutritionMacros, packageGrams: Double? = nil, source: MyFood.Source) -> MyFood? {
        guard servingGrams > 0, perServing.calories >= 0 else { return nil }
        let factor = 100 / servingGrams
        return MyFood(name: name, barcode: barcode,
                      per100g: NutritionMacros(calories: perServing.calories * factor,
                                               proteinGrams: perServing.proteinGrams * factor,
                                               carbohydrateGrams: perServing.carbohydrateGrams * factor,
                                               fatGrams: perServing.fatGrams * factor),
                      servingLabel: servingLabel, servingGrams: servingGrams, packageGrams: packageGrams, source: source)
    }

    /// A product a barcode found, when it has nutrition and says what its serving weighs — or
    /// gives its numbers per 100 g and no serving, which is kept as that. Nil sends the scan on
    /// to a photo of the label.
    static func food(product: BarcodeProduct) -> MyFood? {
        guard let macros = product.macros, macros.calories > 0,
              let (label, grams) = serving(product.serving) else { return nil }
        guard var food = food(name: product.name, barcode: product.barcode, servingLabel: label, servingGrams: grams,
                              perServing: macros, packageGrams: product.packageGrams, source: .barcode) else { return nil }
        // Its numbers as the source gave them, not worked back from the serving.
        if let per100g = product.per100g { food.per100g = per100g }
        food.servingStated = product.servingStated ?? true
        return food
    }

    // MARK: - Putting right what was scanned mis-scaled

    /// Informational only — nothing decides on it. A food's numbers were once put right by
    /// arithmetic wherever this read 1, and a device still on an older build saved the corrected
    /// food back without the field, so the next build to open there would have corrected it
    /// again. The check is now against the source (`reconciled`), which can't be applied twice.
    static let numbersRevision = 3

    /// One of yours brought into line with what scanning its barcode gives now (`fresh`, from
    /// `food(product:)`): the source's numbers per 100 g, its serving, whether it states one, and
    /// its package — keeping which food it is, since when, and what it has stood for. Nil when
    /// it already is. Until 5 Oct 2026 Open Food Facts' per-100 g numbers were stored as one
    /// serving's, so a food scanned before was off by 100 ÷ its serving's grams (a 50 g egg at
    /// 140 kcal); this is how those are put right, and it is the same answer every time.
    static func reconciled(_ food: MyFood, with fresh: MyFood) -> MyFood? {
        var fixed = fresh
        fixed.id = food.id
        fixed.name = food.name
        fixed.barcode = food.barcode ?? fresh.barcode
        fixed.addedAt = food.addedAt
        fixed.standsFor = food.standsFor
        fixed.uses = food.uses
        fixed.source = food.source
        fixed.packageGrams = fresh.packageGrams ?? food.packageGrams
        fixed.numbers = numbersRevision
        let same = close(food.per100g, fixed.per100g) && abs(food.servingGrams - fixed.servingGrams) < 0.01
            && food.servingStated == fixed.servingStated && food.packageGrams == fixed.packageGrams
        return same ? nil : fixed
    }

    /// What a check against the source was made of: a food whose numbers or serving change
    /// afterwards — a stale copy arriving from another device — is checked again.
    static func fingerprint(_ food: MyFood) -> String {
        "\(food.id.uuidString)|\(Int((food.per100g.calories * 10).rounded()))|\(Int((food.servingGrams * 10).rounded()))|\(food.servingStated)"
    }

    /// A meal's item that came from a food just put right: the food's numbers, and — unless its
    /// numbers were changed by hand — what they come to at its weight. Nil when it isn't one.
    static func repaired(_ item: MealItem, from old: MyFood, to new: MyFood) -> MealItem? {
        guard let reference = item.reference, reference.id == old.reference.id,
              close(reference.per100g, old.per100g), !close(old.per100g, new.per100g) else { return nil }
        var fixed = item
        fixed.reference = new.reference
        if let grams = item.grams, close(item.macros, old.reference.macros(grams: grams)) {
            fixed.macros = new.reference.macros(grams: grams)
        }
        return fixed
    }

    private static func close(_ a: NutritionMacros, _ b: NutritionMacros) -> Bool {
        abs(a.calories - b.calories) < 0.5 && abs(a.proteinGrams - b.proteinGrams) < 0.1
            && abs(a.carbohydrateGrams - b.carbohydrateGrams) < 0.1 && abs(a.fatGrams - b.fatGrams) < 0.1
    }

    /// "1 cup (140 g)" → ("1 cup", 140); "28g" → ("28 g", 28). Nil without a weight in grams.
    static func serving(_ text: String) -> (label: String, grams: Double)? {
        let lower = text.lowercased()
        guard let range = lower.range(of: #"(\d+(?:\.\d+)?)\s*(?:g|grams?)\b"#, options: .regularExpression) else { return nil }
        let digits = lower[range].prefix { $0.isNumber || $0 == "." }
        guard let grams = Double(digits), grams > 0 else { return nil }
        let before = lower.components(separatedBy: "(").first?
            .replacingOccurrences(of: #"(\d+(?:\.\d+)?)\s*(?:g|grams?)\b"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces) ?? ""
        return (before.isEmpty ? "\(Int(grams.rounded())) g" : before, grams)
    }

    static func food(label: ParsedNutritionLabel, name: String, barcode: String?) -> MyFood {
        MyFood(name: name, barcode: barcode, per100g: label.per100g, servingLabel: label.servingLabel,
               servingGrams: label.servingGrams, packageGrams: label.packageGrams, source: .label)
    }

    // MARK: - Learning

    /// Every use of each of your foods, from the meal log: a logged item whose numbers came from
    /// it, at its weight, newest `keptUses` per food.
    static func uses(in meals: [MealEntry]) -> [UUID: [MyFood.Use]] {
        var out: [UUID: [MyFood.Use]] = [:]
        for meal in meals {
            for item in meal.items {
                guard let id = item.reference?.id, id.hasPrefix(referencePrefix),
                      let uuid = UUID(uuidString: String(id.dropFirst(referencePrefix.count))),
                      let grams = item.grams, grams > 0 else { continue }
                out[uuid, default: []].append(MyFood.Use(at: meal.date, grams: grams))
            }
        }
        return out.mapValues { Array($0.sorted { $0.at < $1.at }.suffix(keptUses)) }
    }

    /// The name it was called by when it replaced an item ("pumpkin gnocchi with sage"), so that
    /// name finds it next time without the scan — only when the two names share a word. A scan
    /// that replaced "Pasta" mustn't make every pasta, a restaurant's included, your gnocchi.
    static func noting(_ food: MyFood, standsFor name: String) -> MyFood {
        var food = food
        let key = key(name)
        let shared = GroundedFoodEstimate.words(name).intersection(GroundedFoodEstimate.words(food.name))
        if !key.isEmpty, !shared.isEmpty, key != Self.key(food.name), !food.standsFor.contains(key) {
            food.standsFor.append(key)
        }
        return food
    }

    /// How much you usually have: the middle of what you've had, recent times counting more — so
    /// one big bowl doesn't move it, and a habit that changed does. Nil before the first use.
    static func typicalGrams(_ food: MyFood, now: Date = Date()) -> Double? {
        let weighted = food.uses.filter { $0.grams > 0 }
            .map { (grams: $0.grams, weight: recency($0.at, now: now)) }
            .sorted { $0.grams < $1.grams }
        let total = weighted.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return nil }
        var running = 0.0
        for item in weighted {
            running += item.weight
            if running >= total / 2 { return item.grams }
        }
        return weighted.last?.grams
    }

    private static func recency(_ date: Date, now: Date) -> Double {
        let days = max(0, now.timeIntervalSince(date)) / 86_400
        return pow(0.5, days / halfLife)
    }

    /// How much it's yours now: every use, and every time you bought it, fading with age — a
    /// purchase faster than a use, and counting half as much. A food you haven't had or bought in
    /// months sinks but is never dropped: its barcode still finds it instantly.
    static func rank(_ food: MyFood, now: Date = Date()) -> Double {
        let used = food.uses.reduce(0) { $0 + recency($1.at, now: now) }
        let purchases = food.bought.isEmpty ? [food.addedAt] : food.bought
        let bought = purchases.reduce(0) { $0 + pow(0.5, max(0, now.timeIntervalSince($1)) / 86_400 / purchaseHalfLife) }
        return used + 0.5 * bought
    }

    /// Bought again on `date`: once a day however many times it's scanned.
    static func purchased(_ food: MyFood, at date: Date = Date(), calendar: Calendar = .current) -> MyFood {
        var food = food
        guard !food.bought.contains(where: { calendar.isDate($0, inSameDayAs: date) }) else { return food }
        food.bought = Array((food.bought + [date]).sorted().suffix(keptPurchases))
        return food
    }

    /// What you've bought lately and not had since: newest purchase first. The shop is where the
    /// next meals come from, so these are offered before they've ever been logged.
    static func justBought(_ foods: [MyFood], now: Date = Date()) -> [MyFood] {
        foods.filter { food in
            let since = now.timeIntervalSince(food.lastBought) / 86_400
            guard since >= 0, since <= justBoughtDays else { return false }
            return (food.lastUsed ?? .distantPast) < food.lastBought
        }
        .sorted { $0.lastBought > $1.lastBought }
    }

    static func ranked(_ foods: [MyFood], now: Date = Date()) -> [MyFood] {
        foods.sorted { rank($0, now: now) > rank($1, now: now) }
    }

    /// Your usual foods' names, for the model to call things by (`GroundedFoodEstimate.sketchPrompt`).
    static func usualNames(_ foods: [MyFood], limit: Int = 12, now: Date = Date()) -> [String] {
        let fresh = Set(justBought(foods, now: now).map(\.id))
        return Array(ranked(foods.filter { !$0.uses.isEmpty || fresh.contains($0.id) }, now: now).prefix(limit).map(\.name))
    }

    // MARK: - Matching

    /// Your food that a name means, if any: one it has stood in for before, else one whose name
    /// covers it (`GroundedFoodEstimate.covers`) — "gnocchi" is your Trader Joe's Pumpkin
    /// Gnocchi; "pumpkin soup" isn't. Of several, the one you have most.
    static func match(_ name: String, in foods: [MyFood], now: Date = Date()) -> MyFood? {
        let key = key(name)
        guard !key.isEmpty else { return nil }
        let candidates = foods.filter { food in
            // You've said so, it's its name — or the name covers it and says what it is. Sharing
            // a word isn't enough: "tomato" is not your sundried-tomato chicken tenders.
            food.standsFor.contains(key) || Self.key(food.name) == key
                || (GroundedFoodEstimate.covers(query: name, name: food.name)
                    && GroundedFoodEstimate.namesTheKind(query: name, product: food.name))
        }
        return candidates.max { a, b in
            let aExact = a.standsFor.contains(key) || Self.key(a.name) == key
            let bExact = b.standsFor.contains(key) || Self.key(b.name) == key
            if aExact != bExact { return !aExact }
            return rank(a, now: now) < rank(b, now: now)
        }
    }

    /// One of yours as a database food, so the estimate and the editor treat it like any other:
    /// its serving and its package as measures (`PortionGrams`).
    static func foodMatch(_ food: MyFood) -> FoodMatch {
        FoodMatch(reference: food.reference, category: "My foods", portions: measures(food))
    }

    /// What one of yours is counted in: its serving, when the package says one, and the package.
    /// Grams and ounces go without saying (`FoodSearch.units`).
    static func measures(_ food: MyFood) -> [FoodPortion] {
        var portions: [FoodPortion] = []
        if food.servingStated, food.servingGrams > 0 {
            portions.append(FoodPortion(label: servingMeasure(food.servingLabel), grams: food.servingGrams))
        }
        if let package = food.packageGrams, package > 0, package != food.servingGrams || !food.servingStated {
            portions.append(FoodPortion(label: "1 package", grams: package))
        }
        return portions
    }

    /// A serving's label as a measure to count: "1 cup", "1 egg", "1 serving" — and "1 serving"
    /// for one that is only a weight ("30 g"), which isn't a thing to have two of.
    static func servingMeasure(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, BarcodeProductLookup.grams(in: trimmed) == nil else { return "1 serving" }
        return trimmed.first?.isNumber == true ? trimmed : "1 \(trimmed)"
    }

    static func food(id: String, in foods: [MyFood]) -> FoodMatch? {
        guard id.hasPrefix(referencePrefix), let uuid = UUID(uuidString: String(id.dropFirst(referencePrefix.count))),
              let food = foods.first(where: { $0.id == uuid }) else { return nil }
        return foodMatch(food)
    }

    /// A typed item ("1 cup pumpkin gnocchi") as one of your foods: the amount as written, in its
    /// measures; else your usual; else one serving. Nil when no food of yours is meant.
    static func item(name: String, quantity: String, in foods: [MyFood], now: Date = Date()) -> MealItem? {
        guard let food = match(name, in: foods, now: now) else { return nil }
        let measures = foodMatch(food).portions
        let stated = PortionGrams.grams(FoodPhrase.quantity(quantity), portions: measures, food: name)
        // A food with no serving on its package, never had before, and no amount said: nothing
        // says how much, and 100 g of seaweed is nobody's portion. Left to the estimate.
        if stated == nil, !food.servingStated, typicalGrams(food, now: now) == nil { return nil }
        let grams = stated ?? typicalGrams(food, now: now) ?? food.servingGrams
        let serving = stated != nil ? quantity : (typicalGrams(food, now: now) != nil ? "your usual" : food.servingLabel)
        return MealItem(name: GroundedFoodEstimate.displayName(name),
                        serving: GroundedFoodEstimate.serving(serving, grams: grams),
                        macros: food.reference.macros(grams: grams), confidence: 1.0, grams: grams,
                        reference: food.reference)
    }

    /// The amount to use when nothing says how much: your usual, while the model's guess is in
    /// its neighbourhood — it's noisy, your habit isn't. A guess far off (two portions on the
    /// plate) is something else, and stands.
    static func grams(estimated: Double?, usual: Double?) -> Double? {
        guard let usual else { return estimated }
        guard let estimated, estimated > 0 else { return usual }
        return (0.5...2).contains(estimated / usual) ? usual : estimated
    }
}

// MARK: - Which item a scan corrects, and how much of it

/// Applying a scanned food to a meal (`ScanCorrectionSheet`): which item it is — without asking,
/// when the names say — and how much of it there was. Pure, for tests.
enum ScanCorrection {
    enum Target: Equatable {
        case item(UUID)
        /// No clear item: one tap to choose, or add it as a new one.
        case ask
    }

    /// The item the food is. By what each item IS — its head noun ("pasta" of "pasta with pesto")
    /// being one of the food's words or the same kind of food (gnocchi is pasta) — not by any shared
    /// word: scanning pumpkin gnocchi into "Pasta" and "Pumpkin cream sauce" corrects the pasta.
    /// A name it has stood in for before wins outright; a meal of one item is that item. Otherwise,
    /// unless exactly one item is that kind of food (or several are and one shares the most words),
    /// it asks.
    static func target(foodName: String, standsFor: [String] = [], items: [(id: UUID, name: String)]) -> Target {
        guard !items.isEmpty else { return .ask }
        if items.count == 1 { return .item(items[0].id) }
        let remembered = items.filter { standsFor.contains(MyFoods.key($0.name)) }
        if remembered.count == 1 { return .item(remembered[0].id) }
        let scored = score(foodName: foodName, standsFor: standsFor, items: items).filter(\.isKind)
        guard let best = scored.first else { return .ask }
        if scored.count == 1 || scored[1].overlap < best.overlap { return .item(best.id) }
        return .ask
    }

    /// The items, likeliest first — the order to offer them in when asking.
    static func ranked(foodName: String, standsFor: [String] = [], items: [(id: UUID, name: String)]) -> [UUID] {
        score(foodName: foodName, standsFor: standsFor, items: items).map(\.id)
    }

    private struct Score {
        var id: UUID
        var isKind: Bool
        var overlap: Int
    }

    private static func score(foodName: String, standsFor: [String], items: [(id: UUID, name: String)]) -> [Score] {
        let foodWords = significant(GroundedFoodEstimate.words(foodName))
            .union(standsFor.flatMap { $0.split(separator: " ").map(String.init) })
        let foodKinds = Set(foodWords.compactMap(kind))
        let scored = items.map { item -> Score in
            let words = significant(GroundedFoodEstimate.words(item.name))
            let head = GroundedFoodEstimate.headNoun(item.name)
            let isKind = head.map { foodWords.contains($0) || kind($0).map(foodKinds.contains) == true } ?? false
            return Score(id: item.id, isKind: isKind, overlap: words.intersection(foodWords).count)
        }
        // Stable: equal scores keep the meal's order.
        return scored.enumerated().sorted { a, b in
            if a.element.isKind != b.element.isKind { return a.element.isKind }
            if a.element.overlap != b.element.overlap { return a.element.overlap > b.element.overlap }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// "s" of "Joe's" and the like say nothing.
    private static func significant(_ words: Set<String>) -> Set<String> { words.filter { $0.count > 1 } }

    /// Foods that are the same kind of thing on a plate, as `GroundedFoodEstimate.words` writes them.
    private static let kinds: [String: Set<String>] = [
        "pasta": ["pasta", "gnocchi", "noodle", "spaghetti", "penne", "ravioli", "tortellini", "macaroni", "mac",
                  "fettuccine", "linguine", "rigatoni", "fusilli", "orzo", "lasagna", "lasagne", "ramen", "udon"],
        "bread": ["bread", "toast", "bagel", "bun", "roll", "tortilla", "wrap", "pita", "naan", "baguette", "sourdough"],
        "cereal": ["cereal", "granola", "oat", "oatmeal", "muesli", "porridge"],
        "yogurt": ["yogurt", "yoghurt", "skyr"],
        "snack": ["chip", "crisp", "cracker", "pretzel"],
        "rice": ["rice", "risotto", "pilaf"],
        "dumpling": ["dumpling", "gyoza", "potsticker", "wonton", "bao"],
        "soup": ["soup", "stew", "chili", "broth"],
    ]

    private static func kind(_ word: String) -> String? {
        kinds.first { $0.value.contains(word) }?.key
    }

    /// Servings, in quarters — what a photo's count of them is rounded to (`ServingsFromPhoto`).
    static let step = 0.25

    /// The meal item a scanned food becomes, at `grams`. `id`: the item it replaces keeps its place.
    static func item(food: MyFood, grams: Double, id: UUID = UUID()) -> MealItem {
        MealItem(id: id, name: food.name, serving: FoodSearch.serving(amount(grams: grams, of: food)),
                 macros: food.reference.macros(grams: grams), confidence: 1.0, grams: grams, reference: food.reference)
    }

    /// A weight of one of yours as an amount: so many of its serving when that's a quarter of
    /// one or a round number of them ("1¾ cups"), else the grams.
    static func amount(grams: Double, of food: MyFood) -> FoodSearch.Amount {
        if food.servingStated, food.servingGrams > 0, grams > 0 {
            let count = grams / food.servingGrams
            let quarters = (count * 4).rounded() / 4
            if quarters >= 0.25, abs(quarters - count) <= count * 0.02 {
                let serving = FoodPortion(label: MyFoods.servingMeasure(food.servingLabel), grams: food.servingGrams)
                return FoodSearch.Amount(count: quarters, unit: .portion(serving))
            }
        }
        return FoodSearch.Amount(count: grams.rounded(), unit: .grams)
    }

    /// How much to start from, best first: what the photo showed (servings the model counted), your
    /// usual, the estimate's own weight, one serving. A food whose package states no serving has
    /// none to count or fall back on: after your usual and the estimate there is nothing, and
    /// it starts at 0 — to be said, not guessed (`needsAmount`).
    static func startingGrams(photoServings: Double?, food: MyFood, estimatedGrams: Double?, now: Date = Date()) -> Double {
        if food.servingStated, let photoServings, photoServings > 0 { return photoServings * food.servingGrams }
        if let usual = MyFoods.typicalGrams(food, now: now) { return usual }
        if let estimatedGrams, estimatedGrams > 0 { return estimatedGrams }
        return food.servingStated ? food.servingGrams : 0
    }
}
