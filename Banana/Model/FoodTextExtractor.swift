import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// One item as extracted by the model, before resolution — name/quantity/estimate only. Kept
/// independent of `@Generable`'s `GeneratedItem` (which requires iOS 26 + `FoundationModels`)
/// so `FoodTextExtractor.resolve(_:)` is callable — and testable — without the on-device model
/// ever running.
struct ExtractedFoodItem: Hashable, Sendable {
    var name: String
    var quantityPhrase: String
    var estimatedCalories: Double
    var estimatedProteinGrams: Double
    var estimatedCarbGrams: Double
    var estimatedFatGrams: Double
}

/// One food item after resolution: the model's extraction, reconciled against a learned
/// correction, the bundled catalog, or — last resort — the model's own honest estimate. See
/// `FoodTextExtractor.resolve(_:)` for the priority order. This is the "honesty mechanism" the
/// whole natural-language food entry feature rests on: a known food gets real numbers, an unknown
/// one is visibly flagged as a guess, never presented as fact.
struct ResolvedFoodItem: Hashable, Identifiable, Sendable {
    enum Source: Hashable, Sendable {
        /// A correction the person has made to this same food at least twice before.
        case learned
        /// A match in `Banana/Resources/GenericFoods.json`.
        case catalog
        /// A USDA food the model chose from `FoodDatabase`, at the grams it estimated: the
        /// numbers are real, the portion is a guess (`GroundedFoodEstimate`).
        case database
        /// The on-device model's own estimate — no catalog or learned match.
        case aiEstimate
        /// The model was unavailable, refused, or errored. A blank row, filled in by hand.
        case manual
        /// Carried over from an already-saved meal being edited, rather than a value just
        /// proposed for review. `EditableFoodRow.init(saved:)` only assigns this when the saved
        /// item's confidence already cleared the `aiEstimate` bar (an item that was never
        /// confirmed keeps reading as `.aiEstimate` even after a trip through Save, since nothing
        /// about it has actually changed). Still counts toward `wasEditedFromProposal`: changing
        /// a number already logged is exactly the correction signal `WellnessStore.recordEdit`
        /// exists to catch.
        case saved
    }

    var id = UUID()
    var name: String
    var serving: String
    var macros: NutritionMacros
    /// 0…1, mirrors `MealItem.confidence` exactly — never about the serving/quantity phrase.
    var confidence: Double
    var source: Source
    /// The portion's weight, for a database-backed row — what changing the portion scales by.
    var grams: Double? = nil
    var reference: FoodReference? = nil

    /// `>= 0.9` is the UI's two-tier cutoff: catalog/learned rows render plainly, everything else
    /// gets the amber "check this" treatment.
    var isConfident: Bool { confidence >= 0.9 }

    var badgeText: String {
        switch source {
        case .learned: return "From your past entries"
        case .catalog: return "From catalog"
        case .database: return "\(reference?.sourceName ?? "USDA") \u{00B7} check the portion"
        case .aiEstimate: return "AI estimate — check this"
        case .manual: return "Enter manually"
        case .saved: return "Already saved"
        }
    }

    /// Keeps the row's id: an item edited in review stays the item it was proposed as, which is
    /// how its estimate finds it (`EstimateLedger`).
    func asMealItem() -> MealItem {
        MealItem(id: id, name: name, serving: serving, macros: macros, confidence: confidence,
                 grams: grams, reference: reference)
    }

}

extension ResolvedFoodItem {
    /// A grounded estimate (`GroundedFoodEstimate.item`) as a row to review. In an extension so
    /// the memberwise initializer stays.
    init(grounded item: MealItem, serving fallback: String) {
        self.init(name: item.name, serving: item.serving.isEmpty ? fallback : item.serving, macros: item.macros,
                  confidence: item.confidence ?? GroundedFoodEstimate.guessConfidence,
                  source: item.reference == nil ? .aiEstimate : .database,
                  grams: item.grams, reference: item.reference)
    }
}

/// Extracts a multi-item food log from one free-text phrase using Apple's on-device
/// `FoundationModels` (iOS 26), then resolves each item's macros against, in priority order: a
/// learned correction, the bundled generic-food catalog, and only then the model's own estimate.
/// Every failure path — model unavailable, refusal, malformed response, an on-device hang — lands
/// on one manually-editable row instead of an error; there is no dead end.
///
/// All `FoundationModels` code for this feature lives in this file.
enum FoodTextExtractor {
    static var available: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) {
            return SystemLanguageModel.default.availability == .available
        }
        #endif
        return false
    }

    /// Extracts and resolves every item in `phrase`. `learned` supplies a per-name correction
    /// lookup — passed in rather than reached for via `WellnessStore.shared` so this stays
    /// callable (and testable) without that store's on-disk/CloudKit dependency chain.
    static func extract(_ phrase: String,
                        learned: @Sendable (String) -> FoodCorrection? = { _ in nil },
                        myFoods: [MyFood] = []) async -> [ResolvedFoodItem] {
        await extract(phrase, catalogMatch: GenericFoodCatalog.match(name:), learned: learned,
                      mine: { MyFoods.item(name: $0, quantity: $1, in: myFoods) })
    }

    /// Two passes, not one.
    ///
    /// The single call this replaced asked the model to do two unrelated jobs at once: split the
    /// phrase into items, AND estimate six nutrition fields for each. Three things were wrong with
    /// that. It spent the context window on estimates that were then thrown away — `resolve` prefers
    /// a learned correction or the bundled catalog over the model, so for anything recognised the
    /// numbers were computed and discarded. It failed as a unit: one refusal, one truncation past
    /// the 800-token response cap, and the whole meal collapsed to a single empty row, losing
    /// everything typed. And it split attention across a long combined output, which is where a
    /// 4096-token window shared between instructions, prompt and output runs out first.
    ///
    /// Splitting is now its own small call — two fields an item — and nutrition is asked for ONE
    /// item at a time, and only for items nothing else can answer. A typical meal asks the model
    /// for nutrition zero or one times instead of once per item. A failure now costs that item,
    /// not the meal.
    static func extract(_ phrase: String,
                        catalogMatch: (String) -> GenericFood?,
                        learned: @Sendable (String) -> FoodCorrection? = { _ in nil },
                        mine: @Sendable (String, String) -> MealItem? = { _, _ in nil },
                        groundedItem: @escaping @Sendable (String, String, Intelligence.Availability) async -> MealItem? = {
                            await GroundedFoodEstimate.item(name: $0, quantity: $1, availability: $2)
                        }) async -> [ResolvedFoodItem] {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard available else { return [manualFallback(trimmed)] }

        // Probed once for the whole meal. Routing every item against its own probe would let one
        // meal split across two models halfway through as the quota tipped over, which is exactly
        // the kind of inconsistency the review screen would surface as unexplained noise.
        let availability = Intelligence.current
        let parts = await splitIntoItems(trimmed, availability: availability)
        guard !parts.isEmpty else { return [manualFallback(trimmed)] }

        // Anything the catalog or a past correction already knows needs no model call at all —
        // `resolve` would discard the model's numbers for those anyway. Keyed by index, not name,
        // so "1 egg" and "2 eggs" (both normalising to "egg") stay two rows.
        // Your own foods (`MyFoods`) too: the gnocchi you scanned is that gnocchi.
        let needsEstimate = parts.indices.filter {
            learned(parts[$0].name) == nil && mine(parts[$0].name, parts[$0].quantity) == nil
                && catalogUnits(parts[$0].name, parts[$0].quantity, catalogMatch) == nil
        }
        var estimates: [Int: ExtractedFoodItem] = [:]
        var grounded: [Int: MealItem] = [:]
        if !needsEstimate.isEmpty {
            (estimates, grounded) = await withTaskGroup(of: (Int, ExtractedFoodItem?, MealItem?).self) { group in
                var found: [Int: ExtractedFoodItem] = [:]
                var foundGrounded: [Int: MealItem] = [:]
                var pending = needsEstimate[...]
                // Two at a time, not all at once. These share one on-device model, so a meal with
                // six unknown items would open six sessions against it for no speed-up — and the
                // failure mode if that is too many is every item falling back to zeroes at once,
                // which is the whole-meal collapse this two-pass design exists to prevent.
                func submit() {
                    guard let index = pending.popFirst() else { return }
                    let part = parts[index]
                    group.addTask {
                        // A USDA food at estimated grams first; the model's own figures only when
                        // that finds nothing (`GroundedFoodEstimate`).
                        if let item = await groundedItem(part.name, part.quantity, availability) {
                            return (index, nil, item)
                        }
                        return (index, await estimateNutrition(name: part.name, quantity: part.quantity,
                                                                availability: availability), nil)
                    }
                }
                submit(); submit()
                while let (index, item, groundedItem) = await group.next() {
                    found[index] = item
                    foundGrounded[index] = groundedItem
                    submit()
                }
                return (found.compactMapValues { $0 }, foundGrounded)
            }
        }

        return parts.indices.map { index in
            let part = parts[index]
            if learned(part.name) == nil, let item = mine(part.name, part.quantity) {
                return ResolvedFoodItem(grounded: item, serving: part.quantity)
            }
            if let item = grounded[index], learned(part.name) == nil {
                return ResolvedFoodItem(grounded: item, serving: part.quantity)
            }
            // A row whose nutrition call failed still arrives named and countable, with zeroes to
            // fill in — `resolve` hands it back as a low-confidence estimate the review screen
            // already knows how to flag. Losing one item's numbers costs one item.
            let extracted = estimates[index]
                ?? ExtractedFoodItem(name: part.name, quantityPhrase: part.quantity,
                                     estimatedCalories: 0, estimatedProteinGrams: 0,
                                     estimatedCarbGrams: 0, estimatedFatGrams: 0)
            return resolve(extracted, catalogMatch: catalogMatch, learned: learned)
        }
    }

    /// What one item looked like in the phrase, before anything is known about its nutrition.
    struct SplitItem: Hashable, Sendable {
        var name: String
        var quantity: String
    }

    /// Pass one: the phrase into named items. Two short fields each, so this is the call least
    /// likely to run out of room — which matters, because everything downstream depends on it.
    static func splitIntoItems(_ phrase: String,
                               availability: Intelligence.Availability = Intelligence.current) async -> [SplitItem] {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) {
            // `.structuring`: the small model does this well, and quota spent here is quota
            // missing from the nutrition estimates below, which are the part that needs help.
            guard let (session, route) = Intelligence.session(for: .structuring,
                                                          instructions: splitInstructions,
                                                          availability: availability) else { return [] }
            do {
                return try await Intelligence.withTimeout(seconds: 8, route: route) {
                    let response = try await session.respond(
                        to: phrase, generating: GeneratedItemList.self,
                        options: .init(temperature: 0.2, maximumResponseTokens: 400))
                    return response.content.items.compactMap { item in
                        let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty else { return nil }
                        let quantity = item.quantity.trimmingCharacters(in: .whitespacesAndNewlines)
                        return SplitItem(name: name, quantity: quantity.isEmpty ? "1 serving" : quantity)
                    }
                }
            } catch {
                return []
            }
        }
        #endif
        return []
    }

    /// Pass two: nutrition for ONE item. Small prompt, small output, and a failure costs only this
    /// row — it still reaches the review screen with its name and quantity intact, for editing.
    static func estimateNutrition(name: String, quantity: String,
                                  availability: Intelligence.Availability = Intelligence.current) async -> ExtractedFoodItem? {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) {
            // `.knowledge`: this is the request the accuracy complaint is actually about. The
            // calories in an arbitrary described food are real-world knowledge a ~3B on-device
            // model does not reliably hold, so on iOS 27 this is where the cloud model earns its
            // quota. On iOS 26, or once the quota is gone, it lands back on-device unchanged.
            guard let (session, route) = Intelligence.session(for: .knowledge,
                                                              instructions: nutritionInstructions,
                                                              availability: availability) else { return nil }
            // A cloud round-trip is not an on-device inference; give it room to answer.
            let timeout: UInt64 = route == .cloud ? 20 : 8
            do {
                return try await Intelligence.withTimeout(seconds: timeout, route: route) {
                    let response = try await session.respond(
                        to: "\(quantity) \(name)", generating: GeneratedNutrition.self,
                        options: .init(temperature: 0.3, maximumResponseTokens: 200))
                    let n = response.content
                    return ExtractedFoodItem(
                        name: name, quantityPhrase: quantity,
                        estimatedCalories: n.estimatedCalories,
                        estimatedProteinGrams: n.estimatedProteinGrams,
                        estimatedCarbGrams: n.estimatedCarbGrams,
                        estimatedFatGrams: n.estimatedFatGrams)
                }
            } catch {
                return nil
            }
        }
        #endif
        return nil
    }

    /// Resolution rule, run per extracted item: a learned correction (§5) outranks the bundled
    /// catalog, which outranks the model's own estimate. Pure and FoundationModels-free — this is
    /// the part covered by unit tests.
    ///
    /// `catalogMatch` defaults to the production catalog (`GenericFoodCatalog.match(name:)`,
    /// which reads `GenericFoods.json` from `Bundle.main`); tests inject a lookup against the
    /// copy of that JSON loaded from the *test* bundle instead, since `Bundle.main` inside the
    /// test host doesn't carry it.
    static func resolve(_ item: ExtractedFoodItem,
                        catalogMatch: (String) -> GenericFood? = GenericFoodCatalog.match(name:),
                        learned: (String) -> FoodCorrection? = { _ in nil }) -> ResolvedFoodItem {
        let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let quantity = item.quantityPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        let serving = quantity.isEmpty ? "1 serving" : quantity

        if let correction = learned(name) {
            return .init(name: name, serving: correction.serving.isEmpty ? serving : correction.serving,
                        macros: correction.macros, confidence: 1.0, source: .learned)
        }
        if let food = catalogMatch(name), let count = food.units(in: FoodPhrase.quantity(quantity)) {
            let scaled = NutritionMacros(
                calories: food.unitMacros.calories * count,
                proteinGrams: food.unitMacros.proteinGrams * count,
                carbohydrateGrams: food.unitMacros.carbohydrateGrams * count,
                fatGrams: food.unitMacros.fatGrams * count)
            return .init(name: name, serving: serving, macros: scaled, confidence: 1.0, source: .catalog)
        }
        let estimate = NutritionMacros(
            calories: item.estimatedCalories, proteinGrams: item.estimatedProteinGrams,
            carbohydrateGrams: item.estimatedCarbGrams, fatGrams: item.estimatedFatGrams
        ).sanitized
        return .init(name: name, serving: serving, macros: estimate, confidence: 0.35, source: .aiEstimate)
    }

    /// How many catalog units an item is, when the catalog has the food and its unit can be
    /// compared with the amount said (`GenericFood.units`). Nil sends the item to an estimate.
    static func catalogUnits(_ name: String, _ quantity: String, _ catalogMatch: (String) -> GenericFood?) -> Double? {
        catalogMatch(name)?.units(in: FoodPhrase.quantity(quantity.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    /// One empty, fully-editable row seeded with the raw phrase — the landing state for every
    /// failure this feature can hit (model unavailable, refusal, timeout, decoding failure).
    private static func manualFallback(_ phrase: String) -> ResolvedFoodItem {
        .init(name: phrase, serving: "1 serving", macros: .init(), confidence: 0, source: .manual)
    }


    private static let splitInstructions = """
    You break a short, casual description of food or drink into the distinct items someone is
    logging. Only list what the person actually named or clearly implied — never invent an extra
    item, and never drop one they named. Give each item a specific generic name and the quantity
    they implied. Do not estimate nutrition; that is asked separately.
    """

    private static let nutritionInstructions = """
    You give real-world nutrition figures for one specific quantity of one food or drink. Answer
    for exactly the quantity given, not a standard serving. Do not refuse or leave fields at zero
    because you are unsure — give your best estimate; the app shows it to the person as an estimate
    to check and never logs it silently.
    """

}

#if canImport(FoundationModels)
@available(iOS 26, macOS 26, *)
@Generable
private struct GeneratedItemList {
    @Guide(description: "One entry per distinct food or drink, split on 'and' or a comma. Keep a food together with a preparation or minor addition in the same phrase — 'toast with butter' is one item, not two.")
    var items: [GeneratedItem]
}

@available(iOS 26, macOS 26, *)
@Generable
private struct GeneratedItem {
    @Guide(description: "A specific, generic food or drink name, singular, lowercase. No brand names unless one was stated. E.g. 'egg', 'wheat toast', 'black coffee'.")
    var name: String
    @Guide(description: "The quantity exactly as implied, as a short phrase: '2 large', '1 slice', '1 cup'. Default to '1 serving' if no amount was stated.")
    var quantity: String
}

@available(iOS 26, macOS 26, *)
@Generable
private struct GeneratedNutrition {
    @Guide(description: "Your best honest estimate of calories for this exact quantity, in kcal. Estimate rather than refuse; this will be shown to the person as an estimate to check, not a fact.")
    var estimatedCalories: Double
    @Guide(description: "Estimated protein in grams for this exact quantity.")
    var estimatedProteinGrams: Double
    @Guide(description: "Estimated carbohydrates in grams for this exact quantity.")
    var estimatedCarbGrams: Double
    @Guide(description: "Estimated fat in grams for this exact quantity.")
    var estimatedFatGrams: Double
}

#endif

extension FoodTextExtractor {
    /// A typed meal's estimate as first parsed (`MealEstimate`). None when a row had to be filled
    /// in by hand: there was no estimate to learn from.
    static func estimate(_ parsed: [ResolvedFoodItem]) -> MealEstimate? {
        guard !parsed.isEmpty, !parsed.contains(where: { $0.source == .manual }) else { return nil }
        return MealEstimate(estimator: GroundedFoodEstimate.version, from: .typed,
                            foods: parsed.map { EstimatedFood($0.asMealItem(), amount: .typed) })
    }
}
