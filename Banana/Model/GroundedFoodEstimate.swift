import CoreGraphics
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Estimates grounded in USDA data: the model says what each food is and how much of it there
/// was, and the numbers come from the food it picked in Banana's bundled database
/// (`FoodDatabase`), scaled to the grams — not from the model's memory of calories. The model
/// finds those foods itself, through the `searchFoods` tool.
///
/// Used for backlog meals (photos and/or words, `MealBacklogProcessor`) and for the items the
/// typed "Describe what you ate" flow can't answer from the catalog or past corrections.
enum GroundedFoodEstimate {

    /// One food as the model described it, before its numbers are resolved.
    struct ModelPart: Hashable, Sendable {
        var name: String
        /// The `searchFoods` result it chose; empty when nothing fit.
        var foodID: String
        var grams: Double
        var portion: String
        /// The model's own numbers, used only when no database food fits.
        var ownEstimate: NutritionMacros
        var confidence: Double
        /// Where the amount came from, once something other than the model decided it: the
        /// person's words, or their usual (`preferringMine`). Nil is the model's guess.
        var amount: EstimatedFood.Amount?
    }

    /// What's known about a meal besides its photos and words (docs/design/MEAL-LEARNING.md).
    struct Context: Sendable {
        /// The foods they often have around this time (`UsualFoods`), for the model to call things by.
        var usualNames: [String] = []
        /// What the photos' depth measured (`MealPhotoDepth`), a line each.
        var measurements: [String] = []
        /// How much more or less than the model guesses they usually have of a food
        /// (`LearnedPortions`), by its name and database food. Applied only to a guessed amount.
        var portionFactor: @Sendable (_ name: String, _ referenceID: String?) -> Double? = { _, _ in nil }

        init(usualNames: [String] = [], measurements: [String] = [],
             portionFactor: @escaping @Sendable (_ name: String, _ referenceID: String?) -> Double? = { _, _ in nil }) {
            self.usualNames = usualNames
            self.measurements = measurements
            self.portionFactor = portionFactor
        }

        /// The lines the model reads after the meal itself.
        var promptLines: String { usualLine(usualNames) + measurementLine(measurements) }
    }

    /// One resolved item and where its amount came from, for the estimate kept with the meal.
    struct Resolved: Sendable {
        var item: MealItem
        var amount: EstimatedFood.Amount
        var factor: Double?
    }

    enum Outcome: Sendable {
        case proposal(MealProposal)
        /// Nothing here can read it (no model with vision for a photo, no Apple Intelligence).
        case unavailable(String)
        /// What to tell the person, and the underlying error for the diagnostics log.
        case failed(String, detail: String = "")
    }

    /// Bumped when estimates get meaningfully better, so meals still waiting for review can be
    /// estimated again (`MealBacklogProcessor.redoOutdatedEstimates`). 2: amounts read from the
    /// person's words in USDA's own measures, stricter matching (1 Oct 2026). 3: "egg drop soup"
    /// stays whole, the calorie check only rejects a richer food, cans look for canned foods.
    static let version = 3

    /// A database food with the portion estimated: the numbers are USDA's, the grams a guess.
    static let groundedConfidence = 0.8
    /// The model's own numbers.
    static let guessConfidence = 0.35

    // MARK: - Resolution (pure)

    /// Each part's numbers, in order of trust: a correction the person has made to this food
    /// before, the database food the model chose at the grams it estimated, the model's own guess.
    static func resolve(_ parts: [ModelPart],
                        lookup: (String) -> FoodMatch? = FoodDatabase.food(id:),
                        learned: (String) -> FoodCorrection? = { _ in nil }) -> [MealItem] {
        resolved(parts, lookup: lookup, learned: learned).map(\.item)
    }

    /// `resolve`, keeping where each amount came from. `portionFactor`: what the person usually
    /// has of a food compared with the model's guess (`LearnedPortions`) — applied to a guessed
    /// amount only, never to one they said or their usual.
    static func resolved(_ parts: [ModelPart],
                         lookup: (String) -> FoodMatch? = FoodDatabase.food(id:),
                         learned: (String) -> FoodCorrection? = { _ in nil },
                         portionFactor: (String, String?) -> Double? = { _, _ in nil }) -> [Resolved] {
        parts.compactMap { part in
            let name = displayName(part.name)
            guard !name.isEmpty else { return nil }
            let grams = part.grams.isFinite && part.grams > 0 ? part.grams : nil
            let portion = part.portion.trimmingCharacters(in: .whitespacesAndNewlines)
            let id = part.foodID.trimmingCharacters(in: .whitespacesAndNewlines)
            if let fix = learned(name) {
                return corrected(fix, name: name, part: part, portion: portion, grams: grams,
                                 match: id.isEmpty ? nil : lookup(id))
            }
            // The amount as said ("1 tsp", "2 cups") in this food's own measures, over the model's
            // gram guess — which was 2–20× off for a teaspoon, a cup or a bowl.
            if !id.isEmpty, let match = lookup(id),
               var grams = PortionGrams.grams(FoodPhrase.quantity(portion), portions: match.portions, food: name) ?? grams {
                var amount = part.amount ?? .guess
                var factor: Double?
                if amount == .guess, let learned = portionFactor(name, match.reference.id) {
                    grams *= learned
                    factor = learned
                    amount = .learned
                }
                let item = MealItem(name: name, serving: serving(factor == nil ? portion : "", grams: grams),
                                    macros: match.reference.macros(grams: grams),
                                    confidence: groundedConfidence, grams: grams, reference: match.reference)
                return Resolved(item: item, amount: amount, factor: factor)
            }
            let item = MealItem(name: name, serving: serving(portion, grams: grams),
                                macros: part.ownEstimate.sanitized,
                                confidence: min(guessConfidence, max(0, part.confidence)), grams: grams)
            return Resolved(item: item, amount: part.amount ?? .guess)
        }
    }

    /// A food the person has corrected works like one of theirs: its numbers per gram are theirs,
    /// and how much is their usual — the weight they corrected it at — unless their words say
    /// otherwise, or the model saw something quite different (`MyFoods.grams`). A correction from
    /// before weights were kept stays the fixed number it always was.
    static func corrected(_ fix: FoodCorrection, name: String, part: ModelPart, portion: String, grams: Double?,
                          match: FoodMatch?) -> Resolved {
        guard let usual = fix.grams, usual > 0 else {
            return Resolved(item: MealItem(name: name, serving: fix.serving.isEmpty ? portion : fix.serving,
                                           macros: fix.macros, confidence: 1.0, grams: grams),
                            amount: .usual)
        }
        let said = part.amount == .words
            ? (match.flatMap { PortionGrams.grams(FoodPhrase.quantity(portion), portions: $0.portions, food: name) } ?? grams)
            : nil
        let weight = said ?? MyFoods.grams(estimated: grams, usual: usual) ?? usual
        let factor = weight / usual
        let macros = NutritionMacros(calories: fix.macros.calories * factor, proteinGrams: fix.macros.proteinGrams * factor,
                                     carbohydrateGrams: fix.macros.carbohydrateGrams * factor,
                                     fatGrams: fix.macros.fatGrams * factor)
        let amount: EstimatedFood.Amount = said != nil ? .words : (weight == usual ? .usual : .guess)
        let shown = said != nil ? portion : (amount == .usual ? "your usual" : "")
        return Resolved(item: MealItem(name: name, serving: serving(shown, grams: weight), macros: macros.sanitized,
                                       confidence: 1.0, grams: weight),
                        amount: amount)
    }

    /// The estimate kept with a meal: each item as first proposed, and where its amount came from.
    static func estimate(_ resolved: [Resolved], from: MealEstimate.From, measured: Bool = false) -> MealEstimate {
        MealEstimate(estimator: version, from: from, measured: measured,
                     foods: resolved.map { EstimatedFood($0.item, amount: $0.amount, factor: $0.factor) })
    }

    /// Parts whose amount is the person's own words: the portion appears in what they wrote
    /// ("1/2 cup" of "1/2 cup rice and dal"). A portion the model made up for a food they didn't
    /// quantify ("1 bowl") stays its guess.
    static func markingSaidAmounts(_ parts: [ModelPart], note: String) -> [ModelPart] {
        let said = " " + RepeatMeal.normalized(note) + " "
        guard said.count > 2 else { return parts }
        return parts.map { part in
            guard part.amount == nil else { return part }
            let portion = RepeatMeal.normalized(part.portion)
            guard !portion.isEmpty, FoodPhrase.quantity(part.portion) != nil,
                  said.contains(" " + portion + " ") else { return part }
            var part = part
            part.amount = .words
            return part
        }
    }

    /// The on-device model's sketch of one food, before the app looks it up itself.
    struct Sketch: Hashable, Sendable {
        var name: String
        var grams: Double
        var portion: String
        var ownEstimate: NutritionMacros
    }

    /// For the on-device model, which has too little room to read search results (a meal's worth
    /// overflowed its 4,096 tokens): it names each food and its grams, and the app looks the food up
    /// itself — the best USDA match for the words it gave.
    static func parts(fromSketches sketches: [Sketch],
                      search: (String) -> [FoodMatch] = { FoodDatabase.search($0, limit: 8) }) -> [ModelPart] {
        sketches.map { sketch in
            // "1/2 can of tomato sauce": the amount is the portion, the rest is what to look up.
            let (quantity, food) = FoodPhrase.split(sketch.name)
            let portion = quantity?.text ?? sketch.portion
            let ownPer100g = sketch.grams > 0 && sketch.ownEstimate.calories > 0
                ? sketch.ownEstimate.calories / sketch.grams * 100 : nil
            // "Half a can of beans" is canned beans, not beans cooked from dry.
            var canned = false
            if case .measure(let measure)? = quantity?.unit, measure == "can" || measure == "tin" { canned = true }
            let match = (canned ? bestMatch(for: food, among: search("canned \(food)"), ownCaloriesPer100g: ownPer100g) : nil)
                ?? bestMatch(for: food, among: search(food), ownCaloriesPer100g: ownPer100g)
            return ModelPart(name: food, foodID: match?.reference.id ?? "", grams: sketch.grams,
                             portion: portion, ownEstimate: sketch.ownEstimate, confidence: 1)
        }
    }

    /// The first search result (they come best first) that is really this food — or none, and
    /// the model's own estimate is used, flagged: a confident wrong match is worse than a guess.
    /// Each rule here is a match that happened: "beef bone broth" → a T-bone steak, "chicken broth"
    /// → "Chicken, canned, no broth", "seafood blend" → a creamy seafood salad, "orzo" → dry orzo
    /// weighed as if cooked.
    static func bestMatch(for food: String, among candidates: [FoodMatch], ownCaloriesPer100g: Double?) -> FoodMatch? {
        candidates.first { candidate in
            guard covers(query: food, name: candidate.reference.name) else { return false }
            // A branded product's name says a lot more than the food (brand aside): "Shrimp &
            // Seafood Blend In A Creamy Salad Dressing With Chopped Celery" isn't a seafood blend.
            if candidate.reference.id.hasPrefix("branded:"),
               extraWords(query: food, name: candidate.reference.name) > maxBrandedExtraWords {
                return false
            }
            // Far more calories per gram than the model thought this food has: some other food, or
            // the same one dry when it was eaten cooked (orzo). Only that way round — the model
            // guesses condiments and sauces high (its grams are off), so a plainer food than it
            // expected is kept: rejecting plain mustard picked mustard oil instead.
            if let own = ownCaloriesPer100g {
                let theirs = candidate.reference.per100g.calories
                if theirs >= 40, theirs > max(own, 1) * maxCalorieDensityRatio { return false }
            }
            return true
        }
    }

    static let maxBrandedExtraWords = 5
    static let maxCalorieDensityRatio = 2.5

    private static let fillerWords: Set<String> = ["a", "an", "and", "the", "of", "with", "in", "on", "some", "plain"]
    /// Words that say how it was made or kept, not what it is: never required for a match.
    private static let descriptorWords: Set<String> = [
        "cooked", "raw", "fresh", "grilled", "baked", "broiled", "fried", "boiled", "steamed", "roasted",
        "sauteed", "poached", "scrambled", "homemade", "canned", "frozen", "chopped", "sliced", "diced",
        "shredded", "organic", "leftover", "hot", "cold", "warm", "iced", "small", "medium", "large", "big",
        "whole", "half", "extra", "store", "bought",
    ]
    private static let connectorWords: Set<String> = ["with", "and", "in", "on", "over", "plus", "from", "w"]
    private static let negationWords: Set<String> = ["no", "without", "not", "non"]

    private static func stemmed(_ word: String) -> String {
        word.count > 3 && word.hasSuffix("s") && !word.hasSuffix("ss") ? String(word.dropLast()) : word
    }

    /// The words of a name in order, lowercased and singular.
    private static func orderedWords(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .map(stemmed)
    }

    /// The plain words of a food's name: lowercase, plurals, fillers and numbers dropped.
    static func words(_ text: String) -> Set<String> {
        Set(orderedWords(text).filter { !fillerWords.contains($0) && !$0.allSatisfy(\.isNumber) })
    }

    /// The words that say which food it is, in order: no amounts ("1/2 can of"), fillers or
    /// descriptors ("cooked", "grilled").
    private static func foodWords(_ text: String) -> [String] {
        let (_, food) = FoodPhrase.split(text)
        var seen = Set<String>()
        return orderedWords(food).filter {
            !fillerWords.contains($0) && !descriptorWords.contains($0) && !$0.allSatisfy(\.isNumber)
                && seen.insert($0).inserted
        }
    }

    /// What the food is: the last word before "with", "and"… — "broth" of "beef bone broth",
    /// "curry" of "chicken curry with rice".
    static func headNoun(_ text: String) -> String? {
        let (_, food) = FoodPhrase.split(text)
        let ordered = orderedWords(food)
        let head = ordered.prefix { !connectorWords.contains($0) }
        let wanted = Set(foodWords(text))
        return head.last { wanted.contains($0) } ?? ordered.last { wanted.contains($0) }
    }

    /// Words a name puts after "no" or "without": "broth" in "Chicken, canned, no broth".
    private static func negatedWords(_ name: String) -> Set<String> {
        var negated = Set<String>()
        for segment in name.lowercased().split(separator: ",") {
            let segmentWords = orderedWords(String(segment))
            if let at = segmentWords.firstIndex(where: negationWords.contains) {
                negated.formUnion(segmentWords[(at + 1)...])
            }
        }
        return negated
    }

    /// Whether a database food is the food named: every word of a one- or two-word name, else
    /// two thirds of them including what the food is (`headNoun`) — and none of them only after a
    /// "no". Amounts, fillers and descriptors don't count.
    static func covers(query: String, name: String) -> Bool {
        let wanted = foodWords(query)
        guard !wanted.isEmpty else { return false }
        let present = words(name).subtracting(negatedWords(name))
        let found = wanted.filter(present.contains)
        if wanted.count <= 2 { return found.count == wanted.count }
        guard let head = headNoun(query), found.contains(head) else { return false }
        return Double(found.count) / Double(wanted.count) >= 2.0 / 3.0
    }

    /// Whether a name says what a product is, not just something in it: one of the last two
    /// food words of the product's name — "chicken" or "tenders" of "Sundried Tomato And Basil
    /// Chicken Tenders", never "tomato". A tomato was once logged as those tenders.
    static func namesTheKind(query: String, product: String) -> Bool {
        let kind = Set(foodWords(product).suffix(2))
        return foodWords(query).contains(where: kind.contains)
    }

    /// Words in a database name that the food's own name didn't use, descriptors aside.
    static func extraWords(query: String, name: String) -> Int {
        let wanted = Set(foodWords(query))
        return words(name).filter { !wanted.contains($0) && !descriptorWords.contains($0) && $0.count > 1 }.count
    }

    /// "1 cup · 158 g", "158 g", or the portion alone.
    static func serving(_ portion: String, grams: Double?) -> String {
        let weight = grams.map { "\(Int($0.rounded())) g" }
        switch (portion.isEmpty, weight) {
        case (false, let weight?) where !portion.lowercased().hasSuffix(" g"): return "\(portion) · \(weight)"
        case (true, let weight?): return weight
        default: return portion.isEmpty ? "1 serving" : portion
        }
    }

    /// "white rice" → "White rice"; USDA's "not specified" clauses dropped: "Yogurt, Greek, NS as
    /// to type of milk, plain" → "Yogurt, Greek, plain", "Rice, NFS" → "Rice".
    static func displayName(_ name: String) -> String {
        let trimmed = name
            .replacingOccurrences(of: #",\s*NS as to [^,]*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #",\s*NFS\b"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "" }
        return first.uppercased() + trimmed.dropFirst()
    }

    /// The meal's name: the model's, else its items' names.
    static func mealName(_ proposed: String, items: [MealItem]) -> String {
        let trimmed = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return String(trimmed.prefix(80)) }
        return items.prefix(3).map(\.name).joined(separator: ", ")
    }

    // MARK: - Asking the model

    /// A whole meal from its photos and/or words.
    ///
    /// `myFoods`: what you've scanned (`MyFoodsStore`) — a food of yours that an item names is
    /// used before any database food, at your usual amount when nothing says how much.
    @MainActor
    static func meal(images: [CGImage], note: String, eatenAt: Date,
                     learned: @escaping (String) -> FoodCorrection? = { _ in nil },
                     myFoods: [MyFood] = [], context: Context = Context()) async -> Outcome {
        #if canImport(FoundationModels)
        guard #available(iOS 26, macOS 26, *) else { return .unavailable(unavailableText(photos: !images.isEmpty)) }
        let need: Intelligence.Need = images.isEmpty ? .knowledge : .vision
        let availability = Intelligence.current
        let route = Intelligence.route(need, given: availability)
        guard route != .none else { return .unavailable(unavailableText(photos: !images.isEmpty)) }
        if !images.isEmpty {
            guard #available(iOS 27, macOS 27, visionOS 27, watchOS 27, *) else {
                return .unavailable(unavailableText(photos: true))
            }
        }
        if route == .device {
            return await deviceMeal(images: images, note: note, eatenAt: eatenAt, learned: learned,
                                    myFoods: myFoods, context: context, need: need, availability: availability)
        }
        let tool = FoodSearchTool(compact: false)
        guard let (session, chosen) = Intelligence.session(for: need, instructions: mealInstructions,
                                                           tools: [tool], availability: availability) else {
            return .unavailable(unavailableText(photos: !images.isEmpty))
        }
        let prompt = mealPrompt(note: note, eatenAt: eatenAt, photoCount: images.count) + context.promptLines
        do {
            let generated: GeneratedMealEstimate = try await Intelligence.withTimeout(seconds: chosen == .cloud ? 90 : 30, route: chosen) {
                if !images.isEmpty, #available(iOS 27, macOS 27, visionOS 27, watchOS 27, *) {
                    let attachments = images.map { Attachment($0).label("photo of the meal") }
                    return try await session.respond(generating: GeneratedMealEstimate.self,
                                                     options: .init(temperature: 0.2)) {
                        prompt
                        for attachment in attachments { attachment }
                    }.content
                }
                return try await session.respond(to: prompt, generating: GeneratedMealEstimate.self,
                                                 options: .init(temperature: 0.2)).content
            }
            let parts = preferringMine(markingSaidAmounts(generated.items.map(\.part), note: note),
                                       myFoods: myFoods, amountsFromWords: !note.isEmpty)
            let resolved = resolved(parts, lookup: lookup(myFoods), learned: learned, portionFactor: context.portionFactor)
            return proposal(resolved, mealName: generated.mealName, images: images, note: note, context: context)
        } catch is Intelligence.TimedOut {
            return .failed("Took too long to answer. Try again.", detail: "timed out")
        } catch {
            return .failed(failureText(error), detail: String(describing: error))
        }
        #else
        return .unavailable(unavailableText(photos: !images.isEmpty))
        #endif
    }

    /// The on-device model's meal: a sketch of foods and grams (no tools — its context is too
    /// small for search results), each food then looked up by the app (`parts(fromSketches:)`).
    @MainActor
    private static func deviceMeal(images: [CGImage], note: String, eatenAt: Date,
                                   learned: @escaping (String) -> FoodCorrection?, myFoods: [MyFood],
                                   context: Context, need: Intelligence.Need,
                                   availability: Intelligence.Availability) async -> Outcome {
        #if canImport(FoundationModels)
        guard #available(iOS 26, macOS 26, *),
              let (session, chosen) = Intelligence.session(for: need, instructions: sketchInstructions,
                                                           availability: availability) else {
            return .unavailable(unavailableText(photos: !images.isEmpty))
        }
        // Smaller pictures for the small model: quicker, and room left for the answer.
        let small = images.prefix(2).map { scaled($0, maxPixels: 768) }
        let prompt = sketchPrompt(note: note, eatenAt: eatenAt, photoCount: small.count) + context.promptLines
        do {
            let generated: GeneratedMealSketch = try await Intelligence.withTimeout(seconds: small.isEmpty ? 30 : 75,
                                                                                    route: chosen) {
                if !small.isEmpty, #available(iOS 27, macOS 27, visionOS 27, watchOS 27, *) {
                    let attachments = small.map { Attachment($0).label("photo of the meal") }
                    return try await session.respond(generating: GeneratedMealSketch.self,
                                                     options: .init(temperature: 0.2)) {
                        prompt
                        for attachment in attachments { attachment }
                    }.content
                }
                return try await session.respond(to: prompt, generating: GeneratedMealSketch.self,
                                                 options: .init(temperature: 0.2)).content
            }
            let sketched = markingSaidAmounts(parts(fromSketches: generated.items.map(\.sketch)), note: note)
            let mine = preferringMine(sketched, myFoods: myFoods, amountsFromWords: !note.isEmpty)
            let resolved = resolved(mine, lookup: lookup(myFoods), learned: learned, portionFactor: context.portionFactor)
            return proposal(resolved, mealName: generated.mealName, images: images, note: note, context: context)
        } catch is Intelligence.TimedOut {
            return .failed("Took too long to answer. Try again.", detail: "timed out (on device)")
        } catch {
            return .failed(failureText(error), detail: String(describing: error))
        }
        #else
        return .unavailable(unavailableText(photos: !images.isEmpty))
        #endif
    }

    /// The proposal for review, with the estimate as first made kept beside it.
    static func proposal(_ resolved: [Resolved], mealName proposed: String, images: [CGImage], note: String,
                         context: Context) -> Outcome {
        let items = resolved.map(\.item)
        guard !items.isEmpty else { return .failed("Couldn\u{2019}t make out any food in that.") }
        let words = !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let from: MealEstimate.From = images.isEmpty ? .words : (words ? .photoAndWords : .photo)
        return .proposal(MealProposal(name: mealName(proposed, items: items), items: items,
                                      warnings: NutritionSanity.warnings(for: items), estimator: version,
                                      estimate: estimate(resolved, from: from, measured: !context.measurements.isEmpty)))
    }

    /// The image no larger than `maxPixels` on its longest side.
    static func scaled(_ image: CGImage, maxPixels: Int) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > maxPixels else { return image }
        let factor = Double(maxPixels) / Double(longest)
        let width = Int(Double(image.width) * factor), height = Int(Double(image.height) * factor)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    /// One typed item ("1 cup dal"), for the typed flow. Nil when no model can answer, so the
    /// caller falls back to its own estimate.
    static func item(name: String, quantity: String,
                     availability: Intelligence.Availability = Intelligence.current) async -> MealItem? {
        #if canImport(FoundationModels)
        guard #available(iOS 26, macOS 26, *) else { return nil }
        let route = Intelligence.route(.knowledge, given: availability)
        if route == .device {
            // The small model sketches it; the app looks it up.
            guard let (session, chosen) = Intelligence.session(for: .knowledge, instructions: sketchInstructions,
                                                               availability: availability) else { return nil }
            do {
                let generated: GeneratedFoodSketch = try await Intelligence.withTimeout(seconds: 20, route: chosen) {
                    try await session.respond(to: "\(quantity) \(name)", generating: GeneratedFoodSketch.self,
                                              options: .init(temperature: 0.2)).content
                }
                var sketch = generated.sketch
                // Their words for the food and the amount, not the model's retelling of them.
                sketch.name = name
                if !quantity.trimmingCharacters(in: .whitespaces).isEmpty { sketch.portion = quantity }
                var part = parts(fromSketches: [sketch]).first
                part?.name = name
                return part.flatMap { resolve([$0]).first }
            } catch {
                return nil
            }
        }
        guard route != .none,
              let (session, chosen) = Intelligence.session(for: .knowledge, instructions: itemInstructions,
                                                           tools: [FoodSearchTool(compact: false)],
                                                           availability: availability) else { return nil }
        do {
            let part: GeneratedMealPart = try await Intelligence.withTimeout(seconds: chosen == .cloud ? 30 : 12, route: chosen) {
                try await session.respond(to: "\(quantity) \(name)", generating: GeneratedMealPart.self,
                                          options: .init(temperature: 0.2)).content
            }
            var resolved = part.part
            resolved.name = name
            return resolve([resolved]).first
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    static func unavailableText(photos: Bool) -> String {
        photos
            ? "Reading photos needs Apple Intelligence on an iPhone or iPad with iOS 27."
            : "Estimating needs Apple Intelligence, which isn\u{2019}t available here right now."
    }

    static func mealPrompt(note: String, eatenAt: Date, photoCount: Int) -> String {
        let time = eatenAt.formatted(date: .omitted, time: .shortened)
        let words = note.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines: [String] = []
        switch (photoCount, words.isEmpty) {
        case (0, _): lines.append("Eaten at \(time). The person wrote: \(words)")
        case (_, true): lines.append("Eaten at \(time). \(photoCount == 1 ? "The photo shows" : "The \(photoCount) photos show") the meal; there's no description.")
        case (_, false): lines.append("Eaten at \(time). \(photoCount == 1 ? "The photo shows" : "The \(photoCount) photos show") the meal. The person wrote: \(words)")
        }
        lines.append("List every food and drink, look each one up with searchFoods, and estimate the grams eaten.")
        return lines.joined(separator: "\n")
    }

    #if canImport(FoundationModels)
    @available(iOS 26, macOS 26, *)
    static func failureText(_ error: Error) -> String {
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation, .refusal: return "The model wouldn\u{2019}t read this one. Enter it by hand."
            case .exceededContextWindowSize: return "Too much to read at once. Try fewer photos."
            case .rateLimited: return "Apple Intelligence is busy. Try again in a bit."
            default: break
            }
        }
        return "Couldn\u{2019}t estimate it this time. Try again, or enter it by hand."
    }
    #endif

    static let mealInstructions = """
    You work out what someone ate so it can be logged. You're given photos of a meal, the person's \
    own description, or both. When their words and the photo disagree, their words win: they know \
    what it was. List each separate food and drink once. For each, call searchFoods with a short \
    plain query ("chicken curry", "white rice cooked", "naan") and pick the result whose \
    description fits best, copying its id exactly. Then estimate the grams actually eaten, using the \
    portion weights the results list and what you can see (plate size, pieces, how full the glass \
    is). Prefer a matching mixed dish ("pad thai with chicken") over its separate ingredients. \
    If nothing listed fits, leave the id empty and give your own calories and macros for the \
    portion. Never invent foods that aren't there.
    """

    static func sketchPrompt(note: String, eatenAt: Date, photoCount: Int, usual: [String] = []) -> String {
        let time = eatenAt.formatted(date: .omitted, time: .shortened)
        let words = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let said: String
        switch (photoCount, words.isEmpty) {
        case (0, _): said = "Eaten at \(time): \(words)"
        case (_, true): said = "Eaten at \(time). List what the photo shows."
        case (_, false): said = "Eaten at \(time). The person says: \(words)"
        }
        return said + usualLine(usual)
    }

    /// "Foods they often have: …" — so a photo of the gnocchi they always buy is called that, and
    /// their own food is found for it. Short: the small model's context is 4,096 tokens.
    static func usualLine(_ usual: [String]) -> String {
        guard !usual.isEmpty else { return "" }
        return "\nFoods they often have (use these names when one is what you see): "
            + usual.prefix(12).joined(separator: "; ") + "."
    }

    /// "Measured from the photo's depth: …" — sizes the model can't see in a flat picture.
    static func measurementLine(_ measurements: [String]) -> String {
        guard !measurements.isEmpty else { return "" }
        return "\nMeasured from the photo's depth (trust these sizes over how it looks): "
            + measurements.prefix(4).joined(separator: "; ") + "."
    }

    /// Database foods, with yours first (`MyFoods.food(id:in:)`).
    static func lookup(_ myFoods: [MyFood]) -> (String) -> FoodMatch? {
        { id in MyFoods.food(id: id, in: myFoods) ?? FoodDatabase.food(id: id) }
    }

    /// Each part that names a food of yours becomes it (`MyFoods.match`). How much: what the
    /// person's words said, when they said it in a measure of that food; otherwise your usual,
    /// unless the model saw something quite different (`MyFoods.grams`).
    static func preferringMine(_ parts: [ModelPart], myFoods: [MyFood], amountsFromWords: Bool,
                               now: Date = Date()) -> [ModelPart] {
        guard !myFoods.isEmpty else { return parts }
        return parts.map { part in
            guard let mine = MyFoods.match(part.name, in: myFoods, now: now) else { return part }
            var part = part
            part.foodID = mine.reference.id
            let measures = MyFoods.foodMatch(mine).portions
            // Said in their words (`markingSaidAmounts`), in a measure this food has: that stands.
            // A portion the model made up doesn't outrank their usual.
            let stated = amountsFromWords && part.amount != .guess
                && (part.amount == .words || part.amount == nil)
                && PortionGrams.grams(FoodPhrase.quantity(part.portion), portions: measures, food: part.name) != nil
            guard !stated else { return part }
            let estimated = part.grams.isFinite && part.grams > 0 ? part.grams : nil
            let usual = MyFoods.typicalGrams(mine, now: now)
            if let grams = MyFoods.grams(estimated: estimated, usual: usual) {
                // "your usual" reads as no measure, so the weight chosen here stands.
                if let usual, grams == usual {
                    part.portion = "your usual"
                    part.amount = .usual
                }
                part.grams = grams
            }
            return part
        }
    }

    static let sketchInstructions = """
    You list what someone ate so a nutrition database can look it up. For each separate food or \
    drink give its name in the person's own words without the amount ("white rice", "beef bone \
    broth", "orzo") — fix an obvious typo, but never swap a food for a different one. Give the \
    amount as they said it ("1/2 cup", "1 tsp", "2 medium", "half a can"); when they didn't say, \
    estimate it the same way ("1 bowl", "1 fillet", "2 slices"). Then the grams eaten, and your own \
    estimate of its calories and macros for that amount. When the person's words and a photo \
    disagree, their words win. Never invent foods that aren't there.
    """

    static let itemInstructions = """
    You find one food in a nutrition database and estimate how many grams the stated quantity is. \
    Call searchFoods, pick the result that fits best and copy its id exactly, and convert the \
    quantity to grams using the portions it lists. If nothing fits, leave the id empty and give \
    your own calories and macros for that quantity.
    """
}

#if canImport(FoundationModels)
/// The model's way into `FoodDatabase`.
@available(iOS 26, macOS 26, *)
struct FoodSearchTool: Tool {
    let name = "searchFoods"
    let description = "Search the USDA food database. Returns matching foods, each with its id, calories and macros per 100 g, and common portion weights in grams."
    /// For the small on-device model: fewer, shorter results so its context doesn't fill up.
    var compact = false

    @Generable
    struct Arguments {
        @Guide(description: "A food or drink in a few plain words, e.g. 'chicken curry', 'white rice cooked', 'oat milk latte'")
        var query: String
    }

    func call(arguments: Arguments) async throws -> String {
        let matches = FoodDatabase.search(arguments.query, limit: compact ? 4 : 8)
        guard !matches.isEmpty else { return "No foods found for \"\(arguments.query)\". Try simpler words." }
        let trimmed = compact ? matches.map { match in
            var match = match
            match.portions = Array(match.portions.prefix(3))
            return match
        } : matches
        return FoodDatabase.toolText(trimmed)
    }
}

@available(iOS 26, macOS 26, *)
@Generable
struct GeneratedMealEstimate {
    @Guide(description: "A short name for the whole meal, e.g. 'Chicken curry with rice'")
    var mealName: String
    @Guide(description: "Every separate food and drink, once each")
    var items: [GeneratedMealPart]
}

@available(iOS 26, macOS 26, *)
@Generable
struct GeneratedMealSketch {
    @Guide(description: "A short name for the whole meal, e.g. 'Chicken curry with rice'")
    var mealName: String
    @Guide(description: "Every separate food and drink, once each")
    var items: [GeneratedFoodSketch]
}

@available(iOS 26, macOS 26, *)
@Generable
struct GeneratedFoodSketch {
    @Guide(description: "The food in the person's own words, without the amount, e.g. 'white rice', 'beef bone broth'")
    var name: String
    @Guide(description: "Estimated weight eaten, in grams")
    var grams: Double
    @Guide(description: "The amount as the person said it, e.g. '1/2 cup', '1 tsp', '2 medium', 'half a can'; if they didn't say, your estimate in the same form, e.g. '1 bowl'")
    var portion: String
    @Guide(description: "Your estimate of the calories in this portion")
    var calories: Double
    @Guide(description: "Protein in grams for this portion")
    var proteinGrams: Double
    @Guide(description: "Carbohydrate in grams for this portion")
    var carbGrams: Double
    @Guide(description: "Fat in grams for this portion")
    var fatGrams: Double

    var sketch: GroundedFoodEstimate.Sketch {
        .init(name: name, grams: grams, portion: portion,
              ownEstimate: NutritionMacros(calories: calories, proteinGrams: proteinGrams,
                                           carbohydrateGrams: carbGrams, fatGrams: fatGrams))
    }
}

@available(iOS 26, macOS 26, *)
@Generable
struct GeneratedMealPart {
    @Guide(description: "What it is, in a few plain words, e.g. 'white rice'")
    var name: String
    @Guide(description: "The id of the searchFoods result that fits best, copied exactly, e.g. 'fndds:2341234'; empty if none fits")
    var foodID: String
    @Guide(description: "Estimated weight eaten, in grams")
    var grams: Double
    @Guide(description: "The portion in everyday terms, e.g. '1 cup', '2 slices', '1 pint'")
    var portion: String
    @Guide(description: "Only if foodID is empty: your own estimate of the calories in this portion; otherwise 0")
    var calories: Double
    @Guide(description: "Only if foodID is empty: protein in grams for this portion; otherwise 0")
    var proteinGrams: Double
    @Guide(description: "Only if foodID is empty: carbohydrate in grams for this portion; otherwise 0")
    var carbGrams: Double
    @Guide(description: "Only if foodID is empty: fat in grams for this portion; otherwise 0")
    var fatGrams: Double
    @Guide(description: "How sure you are what this food is, from 0 to 1")
    var confidence: Double

    var part: GroundedFoodEstimate.ModelPart {
        .init(name: name, foodID: foodID, grams: grams, portion: portion,
              ownEstimate: NutritionMacros(calories: calories, proteinGrams: proteinGrams,
                                           carbohydrateGrams: carbGrams, fatGrams: fatGrams),
              confidence: confidence)
    }
}
#endif
