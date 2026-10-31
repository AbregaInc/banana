import Foundation

struct NutritionMacros: Codable, Hashable, Sendable {
    var calories: Double = 0
    var proteinGrams: Double = 0
    var carbohydrateGrams: Double = 0
    var fatGrams: Double = 0

    private enum CodingKeys: String, CodingKey { case calories, proteinGrams, carbohydrateGrams, fatGrams }

    init(calories: Double = 0, proteinGrams: Double = 0, carbohydrateGrams: Double = 0, fatGrams: Double = 0) {
        self.calories = calories
        self.proteinGrams = proteinGrams
        self.carbohydrateGrams = carbohydrateGrams
        self.fatGrams = fatGrams
    }

    /// Hand-written so a future field added here can't throw `keyNotFound` and take the whole
    /// enclosing meal — and, upstream, the whole `wellness.json` snapshot — down with it (see
    /// `WellnessSnapshotLoader`). No field here is "the point of the record" the way
    /// `MealItem.name` is, so everything just defaults to 0 rather than staying required.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        calories = try container.decodeIfPresent(Double.self, forKey: .calories) ?? 0
        proteinGrams = try container.decodeIfPresent(Double.self, forKey: .proteinGrams) ?? 0
        carbohydrateGrams = try container.decodeIfPresent(Double.self, forKey: .carbohydrateGrams) ?? 0
        fatGrams = try container.decodeIfPresent(Double.self, forKey: .fatGrams) ?? 0
    }

    static func + (lhs: Self, rhs: Self) -> Self {
        .init(
            calories: lhs.calories + rhs.calories,
            proteinGrams: lhs.proteinGrams + rhs.proteinGrams,
            carbohydrateGrams: lhs.carbohydrateGrams + rhs.carbohydrateGrams,
            fatGrams: lhs.fatGrams + rhs.fatGrams)
    }

    var sanitized: Self {
        .init(
            calories: calories.isFinite ? max(0, calories) : 0,
            proteinGrams: proteinGrams.isFinite ? max(0, proteinGrams) : 0,
            carbohydrateGrams: carbohydrateGrams.isFinite ? max(0, carbohydrateGrams) : 0,
            fatGrams: fatGrams.isFinite ? max(0, fatGrams) : 0)
    }
}

/// The database food an item's numbers come from, per 100 g, so the portion can be changed and
/// everything scales with it. From Banana's bundled USDA data (`FoodDatabase`).
struct FoodReference: Codable, Hashable, Sendable {
    /// "fndds:<fdc id>", "sr:<fdc id>", "foundation:<fdc id>", "branded:<barcode>", "myfood:<uuid>"
    /// or "off:<barcode>" (an Open Food Facts product found by searching).
    var id: String
    /// The database's own name for it, e.g. "Chicken curry".
    var name: String
    var per100g: NutritionMacros

    /// Where the numbers come from, for a row's badge.
    var sourceName: String {
        switch id.split(separator: ":").first {
        case "fndds": "USDA survey foods"
        case "sr": "USDA SR Legacy"
        case "foundation": "USDA Foundation"
        case "branded": "USDA branded"
        case "myfood": "your foods"
        case "off": "Open Food Facts"
        default: "USDA"
        }
    }

    /// The nutrition in `grams` of it.
    func macros(grams: Double) -> NutritionMacros {
        let factor = max(0, grams) / 100
        return NutritionMacros(calories: per100g.calories * factor,
                               proteinGrams: per100g.proteinGrams * factor,
                               carbohydrateGrams: per100g.carbohydrateGrams * factor,
                               fatGrams: per100g.fatGrams * factor)
    }
}

struct MealItem: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var serving = ""
    var macros = NutritionMacros()
    /// 0…1 confidence in the food label, never in the serving size. The person confirms both.
    var confidence: Double?
    /// The portion's weight, when known — what a database-backed item scales by.
    var grams: Double?
    /// The database food behind the numbers; nil for a label, a barcode serving or a typed row.
    var reference: FoodReference?

    private enum CodingKeys: String, CodingKey { case id, name, serving, macros, confidence, grams, reference }

    init(id: UUID = UUID(), name: String, serving: String, macros: NutritionMacros, confidence: Double? = nil,
         grams: Double? = nil, reference: FoodReference? = nil) {
        self.id = id
        self.name = name
        self.serving = serving
        self.macros = macros
        self.confidence = confidence
        self.grams = grams
        self.reference = reference
    }

    /// The same food at a different weight: a database-backed item's numbers follow from its
    /// reference; any other item's scale in proportion to the weight it had.
    func withGrams(_ newGrams: Double) -> MealItem {
        var copy = self
        let newGrams = max(0, newGrams)
        if let reference {
            copy.macros = reference.macros(grams: newGrams)
        } else if let grams, grams > 0 {
            let factor = newGrams / grams
            copy.macros = NutritionMacros(calories: macros.calories * factor,
                                          proteinGrams: macros.proteinGrams * factor,
                                          carbohydrateGrams: macros.carbohydrateGrams * factor,
                                          fatGrams: macros.fatGrams * factor)
        }
        copy.grams = newGrams
        return copy
    }

    /// Hand-written for the same reason `MealEntry` carries one — a synthesized `Decodable`
    /// throws `keyNotFound` for an absent key even when the property has a default value, so a
    /// future field added here would silently discard the whole `wellness.json` snapshot on the
    /// very next save (see `WellnessSnapshotLoader`). `name` alone stays required: a food item
    /// with no name isn't a recoverable record, the same reasoning `MealEntry.items` uses for
    /// keeping itself required.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        serving = try container.decodeIfPresent(String.self, forKey: .serving) ?? ""
        macros = try container.decodeIfPresent(NutritionMacros.self, forKey: .macros) ?? NutritionMacros()
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence)
        grams = try? container.decodeIfPresent(Double.self, forKey: .grams)
        reference = try? container.decodeIfPresent(FoodReference.self, forKey: .reference)
    }
}

struct MealEntry: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var date = Date()
    var items: [MealItem]
    var note = ""
    var source: Source = .manual
    /// Optional label the person gives the whole meal ("Lunch", "Post-gym") — additive field,
    /// defaults empty so naming a meal costs zero taps unless he wants one. Deliberately separate
    /// from `note`: for `.text`-sourced entries `note` already archives the original typed
    /// phrase, which naming would otherwise silently overwrite. The Today list (`WellnessView`)
    /// prefers this over the comma-joined item names whenever it's non-empty.
    var name = ""
    /// Photos of the meal (`MealPhotoStore`), when it came from the backlog.
    var photoIDs: [UUID] = []
    /// What Banana first estimated, kept so it can see how far the logged meal moved from it
    /// (`EstimateLedger`). Nil for a meal entered by hand, or logged before this was kept.
    var estimate: MealEstimate?

    /// `.text` is natural-language entry — see `FoodTextExtractor`. `note` carries the original
    /// typed/dictated phrase for that source, which is otherwise a dead field.
    enum Source: String, Codable, Hashable, Sendable { case manual, photo, barcode, text }

    init(id: UUID = UUID(), date: Date = Date(), items: [MealItem], note: String = "",
        source: Source = .manual, name: String = "", photoIDs: [UUID] = [], estimate: MealEstimate? = nil) {
        self.id = id
        self.date = date
        self.items = items
        self.note = note
        self.source = source
        self.name = name
        self.photoIDs = photoIDs
        self.estimate = estimate
    }

    private enum CodingKeys: String, CodingKey { case id, date, items, note, source, name, photoIDs, estimate }

    /// A hand-written decoder — not the synthesized one a default-valued property normally gets
    /// — because a default value on a stored property does NOT make Swift's synthesized
    /// `Decodable` tolerate an absent key; it still throws `keyNotFound`. `name` is additive
    /// (absent from any wellness.json written before meal naming shipped), and `WellnessStore`
    /// decodes its whole snapshot — meals included — behind one blanket `try?`, so one meal
    /// missing this key would have silently discarded the person's entire saved history on next
    /// launch. `note`/`source` get the same defensive `decodeIfPresent` treatment for the same
    /// reason, even though they predate this fix. `items` alone stays a hard requirement — a
    /// "meal" with no food to default to isn't a recoverable case.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try container.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        items = try container.decode([MealItem].self, forKey: .items)
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        source = try container.decodeIfPresent(Source.self, forKey: .source) ?? .manual
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        photoIDs = (try? container.decodeIfPresent([UUID].self, forKey: .photoIDs)) ?? []
        estimate = try? container.decodeIfPresent(MealEstimate.self, forKey: .estimate)
    }

    var totals: NutritionMacros {
        items.reduce(.init()) { $0 + $1.macros.sanitized }
    }

    /// True once every item is at least as confident as the review sheet's own cutoff for a
    /// plain (non-amber) row — see `ResolvedFoodItem.isConfident` in `FoodTextExtractor.swift`,
    /// which uses the same 0.9 threshold. A total assembled from even one row below that bar is
    /// itself only an estimate, never a confident-looking sum built out of a guess. A `nil`
    /// per-item confidence (barcode/photo/manual entries never set one) counts as confident: it
    /// isn't a model guess, it's a value the person entered or a lookup returned directly. An
    /// empty item list also counts as confident — there is no guess in it to disclaim.
    static func isConfident(_ items: [MealItem]) -> Bool {
        items.allSatisfy { ($0.confidence ?? 1) >= 0.9 }
    }

    var isConfident: Bool { Self.isConfident(items) }

    /// Sanitizes one item exactly as `WellnessStore.addMeal`/`updateMeal` require: trimmed,
    /// length-capped name/serving with a sensible fallback when empty, macros clamped to
    /// finite/non-negative, confidence clamped to 0...1. Pulled out as a pure function — rather
    /// than left inline in `WellnessStore` — so it, and everything built on it below, is testable
    /// without that store's CloudBackup/CloudKit dependency chain (the same reasoning
    /// `FoodCorrectionBook` was split out for).
    static func sanitizedItem(_ item: MealItem) -> MealItem {
        var item = item
        item.name = String(item.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        if item.name.isEmpty { item.name = "Food" }
        item.serving = String(item.serving.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        if item.serving.isEmpty { item.serving = "1 serving" }
        item.macros = item.macros.sanitized
        item.confidence = item.confidence.map { $0.isFinite ? min(1, max(0, $0)) : 0 }
        item.grams = item.grams.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        return item
    }

    /// Edits the same meal, preserving its photos, estimate and source. Omitted dates keep the
    /// original timestamp; an explicit correction can move it to another day.
    func updating(items: [MealItem], name: String, date: Date? = nil) -> MealEntry {
        var updated = self
        updated.items = items.map(Self.sanitizedItem)
        updated.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        if let date, date.timeIntervalSinceReferenceDate.isFinite { updated.date = date }
        return updated
    }

    /// Finds the meal with `id` in `meals` and replaces it via `updating(items:name:)`; leaves
    /// `meals` byte-for-byte unchanged if no meal has that id. Pure array transform — rather than
    /// a `WellnessStore` method with a find-and-mutate body — so "editing a meal that was deleted
    /// elsewhere is a no-op, not a crash or a resurrected entry" is directly testable.
    /// `WellnessStore.updateMeal` is a thin wrapper around this.
    static func applyingUpdate(id: UUID, items: [MealItem], name: String, date: Date? = nil, to meals: [MealEntry]) -> [MealEntry] {
        guard let index = meals.firstIndex(where: { $0.id == id }) else { return meals }
        var updated = meals
        updated[index] = updated[index].updating(items: items, name: name, date: date)
        return updated
    }
}

/// What Banana first estimated for a meal, before anyone changed it — kept with the proposal and
/// then with the logged meal, never edited, so the estimate can be compared with what was really
/// eaten (`EstimateLedger`, docs/design/MEAL-LEARNING.md).
struct MealEstimate: Codable, Hashable, Sendable {
    enum From: String, Codable, Sendable {
        case photo, words, photoAndWords
        /// The same words as a meal logged before: its items, copied.
        case repeatedWords
        /// A photo like one of a meal logged before: its items, copied.
        case repeatedPhoto
        /// Typed in "Describe what you ate".
        case typed
    }

    /// `GroundedFoodEstimate.version` at the time.
    var estimator: Int?
    var from: From
    /// The photos' depth was measured and told to the model (`MealPhotoDepth`).
    var measured = false
    var foods: [EstimatedFood]
    var madeAt = Date()
    /// Foods whose amount the person gave when asked (`PortionQuestion`) — the one thing added
    /// after the estimate is made: an answer that agrees with the guess still says it was right.
    var confirmed: [UUID] = []

    init(estimator: Int?, from: From, measured: Bool = false, foods: [EstimatedFood], madeAt: Date = Date(),
         confirmed: [UUID] = []) {
        self.estimator = estimator
        self.from = from
        self.measured = measured
        self.foods = foods
        self.madeAt = madeAt
        self.confirmed = confirmed
    }

    private enum CodingKeys: String, CodingKey { case estimator, from, measured, foods, madeAt, confirmed }

    /// Tolerant, like every meal record: a value a newer build writes can't cost the meal.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        estimator = try? c.decodeIfPresent(Int.self, forKey: .estimator)
        from = (try? c.decodeIfPresent(From.self, forKey: .from)) ?? .words
        measured = (try? c.decodeIfPresent(Bool.self, forKey: .measured)) ?? false
        foods = (try? c.decodeIfPresent([EstimatedFood].self, forKey: .foods)) ?? []
        madeAt = (try? c.decodeIfPresent(Date.self, forKey: .madeAt)) ?? Date()
        confirmed = (try? c.decodeIfPresent([UUID].self, forKey: .confirmed)) ?? []
    }
}

/// One food as the estimate first had it.
struct EstimatedFood: Codable, Hashable, Sendable {
    /// Where its amount came from: what decides whether it can teach (`LearnedPortions`).
    enum Amount: String, Codable, Sendable {
        /// The person said how much ("1/2 cup").
        case words
        /// Their usual: a food of theirs, or a food they've corrected.
        case usual
        /// The model's guess, scaled by what Banana has learned about this food (`factor`).
        case learned
        /// The model's guess.
        case guess
        /// Copied from a meal logged before.
        case repeated
        /// Typed in "Describe what you ate".
        case typed
    }

    /// The meal item it was proposed as. Ids survive editing, and a scan that replaces an item.
    var itemID: UUID
    var name: String
    var grams: Double?
    var calories: Double
    /// The database food behind its numbers (`FoodReference.id`).
    var referenceID: String?
    var amount: Amount
    /// For `.learned`: the factor applied to the model's grams.
    var factor: Double?

    init(itemID: UUID, name: String, grams: Double?, calories: Double, referenceID: String?,
         amount: Amount, factor: Double? = nil) {
        self.itemID = itemID
        self.name = name
        self.grams = grams
        self.calories = calories
        self.referenceID = referenceID
        self.amount = amount
        self.factor = factor
    }

    init(_ item: MealItem, amount: Amount, factor: Double? = nil) {
        self.init(itemID: item.id, name: item.name, grams: item.grams, calories: item.macros.sanitized.calories,
                  referenceID: item.reference?.id, amount: amount, factor: factor)
    }

    private enum CodingKeys: String, CodingKey { case itemID, name, grams, calories, referenceID, amount, factor }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        itemID = try c.decode(UUID.self, forKey: .itemID)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        grams = try? c.decodeIfPresent(Double.self, forKey: .grams)
        calories = (try? c.decodeIfPresent(Double.self, forKey: .calories)) ?? 0
        referenceID = try? c.decodeIfPresent(String.self, forKey: .referenceID)
        amount = (try? c.decodeIfPresent(Amount.self, forKey: .amount)) ?? .guess
        factor = try? c.decodeIfPresent(Double.self, forKey: .factor)
    }
}

/// A confirmed correction to a food's macros/serving, learned only after the same food has been
/// corrected the same way at least twice (see `FoodCorrectionBook`). Outranks even the bundled
/// generic-food catalog in `FoodTextExtractor.resolve(_:)` — it is the person's own confirmed
/// number, not a generic USDA average or an AI guess.
struct FoodCorrection: Codable, Hashable, Sendable {
    var macros: NutritionMacros
    var serving = ""
    /// 1 after the first edit; promoted to "learned" (see `FoodCorrectionBook.lookup`) at 2+.
    var observedCount = 1
    /// The weight the numbers are for, when the item had one: what makes the correction a food's
    /// numbers per gram rather than one fixed amount (`GroundedFoodEstimate.resolved`).
    var grams: Double?

    private enum CodingKeys: String, CodingKey { case macros, serving, observedCount, grams }

    init(macros: NutritionMacros, serving: String = "", observedCount: Int = 1, grams: Double? = nil) {
        self.macros = macros
        self.serving = serving
        self.observedCount = observedCount
        self.grams = grams
    }

    /// `macros` stays required: the corrected numbers ARE the correction. Defaulting them on a
    /// future-field decode failure wouldn't just drop a record — via `LossyDictionary` — it would
    /// actively teach `FoodTextExtractor.resolve` a wrong (zero-calorie) number for that food,
    /// which is worse than dropping it. `serving` and `observedCount` are safe to default: an
    /// empty serving string is just missing descriptive text, and `observedCount` defaulting to 1
    /// (below `FoodCorrectionBook.promotionThreshold`) conservatively treats a possibly-corrupt
    /// record as "not yet learned" rather than risking a bad correction outranking the catalog.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        macros = try container.decode(NutritionMacros.self, forKey: .macros)
        serving = try container.decodeIfPresent(String.self, forKey: .serving) ?? ""
        observedCount = try container.decodeIfPresent(Int.self, forKey: .observedCount) ?? 1
        grams = (try? container.decodeIfPresent(Double.self, forKey: .grams)).flatMap { $0 }
    }
}

/// Pure decision logic behind "the app remembers, but only after the second matching
/// correction" (natural-language food entry, §5). Kept separate from `WellnessStore` — which
/// owns the actual `[String: FoodCorrection]` dictionary and its on-disk persistence — so this
/// logic is testable without `WellnessStore`'s CloudBackup/CloudKit dependency chain, the same
/// reasoning `DistanceUnit`/`HealthWorkout` were split out of their heavier owners for.
enum FoodCorrectionBook {
    /// A correction counts as "learned" — i.e. it outranks the catalog — only once the same food
    /// has been corrected to roughly the same numbers this many times.
    static let promotionThreshold = 2
    /// How far a new correction's calorie value may drift from the stored one and still count as
    /// "the same correction" rather than the start of a fresh series.
    static let toleranceFraction = 0.15

    static func normalize(_ name: String) -> String {
        name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Only returns a correction once it has been observed at least `promotionThreshold` times —
    /// a single edit is "just today," never generalized into a standing override.
    static func lookup(_ name: String, in corrections: [String: FoodCorrection]) -> FoodCorrection? {
        guard let correction = corrections[normalize(name)], correction.observedCount >= promotionThreshold else {
            return nil
        }
        return correction
    }

    /// Records one edit. No existing entry for this food → starts a series at count 1. An
    /// existing entry within `toleranceFraction` of the new calorie value → the same repeatable
    /// fact, so bump the count and keep the latest numbers. Outside tolerance → a real change in
    /// what he eats, so reset to a fresh series rather than getting stuck on stale numbers.
    /// With `grams`, "the same correction" means the same calories per gram — a bigger bowl of
    /// the same rice repeats it rather than starting over.
    static func recordEdit(name: String, macros: NutritionMacros, serving: String, grams: Double? = nil,
                            into corrections: inout [String: FoodCorrection]) {
        let key = normalize(name)
        guard !key.isEmpty else { return }
        let sanitizedMacros = macros.sanitized
        let trimmedServing = serving.trimmingCharacters(in: .whitespacesAndNewlines)
        let weight = grams.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let same: Bool
        if let existing = corrections[key] {
            if let weight, let before = existing.grams, before > 0 {
                same = caloriesWithinTolerance(existing.macros.calories / before, sanitizedMacros.calories / weight)
            } else {
                same = caloriesWithinTolerance(existing.macros.calories, sanitizedMacros.calories)
            }
        } else {
            same = false
        }
        let count = same ? (corrections[key]?.observedCount ?? 0) + 1 : 1
        corrections[key] = FoodCorrection(macros: sanitizedMacros, serving: trimmedServing, observedCount: count,
                                          grams: weight)
    }

    private static func caloriesWithinTolerance(_ a: Double, _ b: Double) -> Bool {
        guard a.isFinite, b.isFinite else { return false }
        if a == 0, b == 0 { return true }
        let reference = max(abs(a), abs(b), 1)
        return abs(a - b) / reference <= toleranceFraction
    }
}

extension SupplementSchedule {
    /// What a Taken reminder's notification id starts with ("banana.supplement.<id>[.<day>]").
    static let notificationPrefix = "banana.supplement."

    /// Whether a notification is a Taken reminder: those show over the app too — ticking
    /// "Workout" in Banana makes Creatine due right then, while the app is in front.
    static func isReminder(notificationID: String) -> Bool { notificationID.hasPrefix(notificationPrefix) }

    /// The id of an item's reminder on one day: each day's is its own notification.
    static func reminderID(_ id: UUID, on day: Date, calendar: Calendar = .current) -> String {
        notificationPrefix + "\(id.uuidString).\(Int(calendar.startOfDay(for: day).timeIntervalSince1970))"
    }

    /// Every id an item's reminders may be pending under: the days ahead, and the one that
    /// repeated daily before reminders were per day.
    static func reminderIDs(_ id: UUID, from day: Date, daysAhead: Int = 7, calendar: Calendar = .current) -> [String] {
        (0...daysAhead).compactMap { calendar.date(byAdding: .day, value: $0, to: day) }
            .map { reminderID(id, on: $0, calendar: calendar) } + [notificationPrefix + id.uuidString]
    }
}

struct SupplementSchedule: Codable, Hashable, Identifiable, Sendable {
    /// Supplement or prescription. Both are "a thing you take at a time each day", which is why
    /// they share one schedule, one log, one reminder and one editor rather than growing a
    /// parallel set — but the distinction is load-bearing everywhere the app has an opinion. A
    /// supplement's time is yours to move; a prescription's was chosen by someone with your blood
    /// results in front of them, so the app reports a timing clash against it and proposes moving
    /// the supplement, never the drug (see `SupplementInteractions.TimedIntake.isMovable`).
    enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        // Medications first everywhere `allCases` drives an ordering: higher stakes, and the
        // shorter list, so it does not push the prescriptions below a screenful of vitamins.
        case medication, supplement

        var label: String { self == .medication ? "Medication" : "Supplement" }
        var plural: String { self == .medication ? "Medications" : "Supplements" }
        var symbol: String { self == .medication ? "cross.case.fill" : "pills.fill" }
    }

    var id = UUID()
    var name: String
    var kind: Kind = .supplement
    var dose = ""
    var hour = 8
    var minute = 0
    var enabled = true
    var note = ""
    /// Active ingredients, as NIH's DSLD normalises them, when a barcode scan found this product
    /// there. Empty for anything typed or photographed.
    ///
    /// Exists so `SupplementInteractions` can see inside a bottle whose name hides its contents:
    /// "Men's Daily Multivitamin" contains iron and calcium and announces neither. Matching on
    /// the name alone would never flag it against a calcium tablet — a warning system that misses
    /// the commonest bottle in the cupboard is worse than none.
    var ingredients: [String] = []
    /// Due around something rather than at a time — "after your workout", "30 min before
    /// breakfast" (docs/design/ANCHORED-TIMING.md). `hour`/`minute` stay its time when that
    /// doesn't happen.
    var anchor: TimingAnchor?

    var safeHour: Int { min(23, max(0, hour)) }
    var safeMinute: Int { min(59, max(0, minute)) }

    private enum CodingKeys: String, CodingKey { case id, name, kind, dose, hour, minute, enabled, note, ingredients, anchor }

    init(id: UUID = UUID(), name: String, kind: Kind = .supplement, dose: String = "", hour: Int = 8,
         minute: Int = 0, enabled: Bool = true, note: String = "", ingredients: [String] = [],
         anchor: TimingAnchor? = nil) {
        self.anchor = anchor
        self.id = id
        self.name = name
        self.kind = kind
        self.dose = dose
        self.hour = hour
        self.minute = minute
        self.enabled = enabled
        self.note = note
        self.ingredients = ingredients
    }

    /// `name` stays required — a supplement schedule with no name is meaningless, the same
    /// reasoning `MealItem.name` uses. `hour`/`minute` default to 8:00am, matching the time
    /// `WellnessView` itself defaults a new supplement to; `safeHour`/`safeMinute` already clamp
    /// any nonsense value, so a defaulted time is no less trustworthy than a hand-typed one.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        // Everything already on disk predates the distinction and was, by definition, a
        // supplement — the app had nowhere to record a medication.
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .supplement
        dose = try container.decodeIfPresent(String.self, forKey: .dose) ?? ""
        hour = try container.decodeIfPresent(Int.self, forKey: .hour) ?? 8
        minute = try container.decodeIfPresent(Int.self, forKey: .minute) ?? 0
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        ingredients = try container.decodeIfPresent([String].self, forKey: .ingredients) ?? []
        // A moment a newer build knows and this one doesn't: its own time, as before.
        anchor = try? container.decodeIfPresent(TimingAnchor.self, forKey: .anchor)
    }
}

/// What something done each day is due around, instead of only a clock time
/// (docs/design/ANCHORED-TIMING.md): a moment, before or after it by some minutes, and what to do
/// when the moment doesn't come. The item's own time is the fallback.
struct TimingAnchor: Codable, Hashable, Sendable {
    enum Moment: Codable, Hashable, Sendable {
        /// A workout: Health's, or one recorded on the Watch.
        case workout
        /// Waking, from last night's sleep.
        case wake
        /// A meal logged — breakfast, lunch, dinner (a `MealTextPart` raw value), or nil for the
        /// first meal of the day.
        case meal(String?)
        /// Another reminder ticked. Its stable id, and its title (a completed copy of a repeating
        /// reminder can carry a different id).
        case reminder(id: String, title: String)
        /// Another Taken item marked taken.
        case dose(id: UUID, name: String)
        /// A calendar event whose title has one of these words.
        case event([String])
    }

    enum Relation: String, Codable, Hashable, Sendable { case before, after }

    enum Fallback: String, Codable, Hashable, Sendable {
        /// At the item's own time.
        case usualTime
        /// Not that day.
        case skip
    }

    var moment: Moment
    var relation: Relation = .after
    /// How long after (or before) it. 0 is right away.
    var minutes: Int = 0
    var fallback: Fallback = .usualTime

    init(moment: Moment, relation: Relation = .after, minutes: Int = 0, fallback: Fallback = .usualTime) {
        self.moment = moment
        self.relation = relation
        self.minutes = max(0, minutes)
        self.fallback = fallback
    }
}

struct SupplementLog: Codable, Hashable, Identifiable, Sendable {
    enum Status: String, Codable, Hashable, Sendable { case taken, skipped }

    var id = UUID()
    var supplementID: UUID
    var date = Date()
    var status: Status
    /// The day this dose counts for, "yyyyMMdd", fixed where it was logged. Sync files the dose
    /// under it, so a trip across time zones (or a Mac in another one) can't move a dose into the
    /// neighbouring day. nil for logs from before it existed; filled in when sync starts.
    var day: String?

    private enum CodingKeys: String, CodingKey { case id, supplementID, date, status, day }

    init(id: UUID = UUID(), supplementID: UUID, date: Date = Date(), status: Status, day: String? = nil) {
        self.id = id
        self.supplementID = supplementID
        self.date = date
        self.status = status
        self.day = day
    }

    /// `supplementID` stays required — a log with no supplement reference is orphaned, nothing to
    /// show it against. `status` stays required too: there's no neutral third value between
    /// "taken" and "skipped", so guessing one would misrepresent the owner's actual history,
    /// which is worse than dropping the entry.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        supplementID = try container.decode(UUID.self, forKey: .supplementID)
        date = try container.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        status = try container.decode(Status.self, forKey: .status)
        day = try? container.decodeIfPresent(String.self, forKey: .day)
    }
}

enum WorkoutFocus: String, Codable, CaseIterable, Hashable, Sendable {
    case strength, mobility, mixed

    var title: String {
        switch self {
        case .strength: return "Strength"
        case .mobility: return "Stretch"
        case .mixed: return "Strength + stretch"
        }
    }
}

enum WorkoutExperience: String, Codable, CaseIterable, Hashable, Sendable {
    case beginner, intermediate, advanced

    var title: String { rawValue.capitalized }
}

enum WorkoutEquipment: String, Codable, CaseIterable, Hashable, Sendable {
    case bodyweight, dumbbells, bench, resistanceBand

    var title: String {
        switch self {
        case .bodyweight: return "Bodyweight"
        case .dumbbells: return "Dumbbells"
        case .bench: return "Bench"
        case .resistanceBand: return "Resistance band"
        }
    }
}

struct WorkoutPreferences: Codable, Hashable, Sendable {
    var focus: WorkoutFocus = .mixed
    var experience: WorkoutExperience = .beginner
    var durationMinutes: Int = 30
    var equipment: Set<WorkoutEquipment> = [.bodyweight]
    var avoidExerciseIDs: Set<String> = []
    var notes = ""

    var sanitizedDuration: Int { min(90, max(10, durationMinutes)) }
}

enum ExerciseCategory: String, Codable, Hashable, Sendable { case strength, mobility }

enum ExerciseVisualKind: String, Codable, Hashable, Sendable {
    case squat, lunge, pushup, plank, bridge, deadBug, birdDog
    case row, overheadPress, curl
    case hipFlexorStretch, hamstringStretch, calfStretch, childPose, thoracicRotation, chestStretch
}

struct ExerciseDefinition: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var category: ExerciseCategory
    var equipment: Set<WorkoutEquipment>
    var visual: ExerciseVisualKind
    var primaryMuscles: [String]
    var instructions: [String]
    var formCues: [String]
    var defaultSets: Int
    var defaultReps: Int? = nil
    var defaultDurationSeconds: Int? = nil
    var defaultRestSeconds: Int
}

struct ExercisePrescription: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var exerciseID: String
    var sets: Int
    var reps: Int?
    var durationSeconds: Int?
    var restSeconds: Int
}

struct WorkoutPlan: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var title = ""
    var createdAt = Date()
    var focus: WorkoutFocus = .mixed
    var targetMinutes = 30
    var exercises: [ExercisePrescription]
    var rationale = ""

    private enum CodingKeys: String, CodingKey {
        case id, title, createdAt, focus, targetMinutes, exercises, rationale
    }

    init(id: UUID = UUID(), title: String, createdAt: Date = Date(), focus: WorkoutFocus,
         targetMinutes: Int, exercises: [ExercisePrescription], rationale: String = "") {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.focus = focus
        self.targetMinutes = targetMinutes
        self.exercises = exercises
        self.rationale = rationale
    }

    /// `exercises` is the one required field — a plan with no exercises isn't a workout, the same
    /// "the record's whole point" reasoning `MealEntry.items` and `MealItem.name` use. Everything
    /// else (including `focus`/`targetMinutes`, which are just descriptive metadata once
    /// `exercises` has loaded) defaults, so a future field can't take the plan down with it.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        focus = try container.decodeIfPresent(WorkoutFocus.self, forKey: .focus) ?? .mixed
        targetMinutes = try container.decodeIfPresent(Int.self, forKey: .targetMinutes) ?? 30
        exercises = try container.decode([ExercisePrescription].self, forKey: .exercises)
        rationale = try container.decodeIfPresent(String.self, forKey: .rationale) ?? ""
    }
}

struct WorkoutCompletion: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var planID: UUID
    var startedAt: Date
    var endedAt: Date
    var completedExerciseIDs: [String] = []

    private enum CodingKeys: String, CodingKey { case id, planID, startedAt, endedAt, completedExerciseIDs }

    init(id: UUID = UUID(), planID: UUID, startedAt: Date, endedAt: Date, completedExerciseIDs: [String] = []) {
        self.id = id
        self.planID = planID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.completedExerciseIDs = completedExerciseIDs
    }

    /// `planID`/`startedAt`/`endedAt` stay required: a completion with no plan reference is
    /// orphaned (nothing to show it against), and defaulting either timestamp would fabricate a
    /// workout duration that never happened — worse than dropping the record. Only the completed-
    /// exercise checklist, purely descriptive once the session itself is known, defaults to empty.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        planID = try container.decode(UUID.self, forKey: .planID)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        endedAt = try container.decode(Date.self, forKey: .endedAt)
        completedExerciseIDs = try container.decodeIfPresent([String].self, forKey: .completedExerciseIDs) ?? []
    }
}

enum ExerciseCatalog {
    static let all: [ExerciseDefinition] = [
        .init(id: "bodyweight-squat", name: "Bodyweight squat", category: .strength,
              equipment: [.bodyweight], visual: .squat,
              primaryMuscles: ["Quads", "Glutes"],
              instructions: ["Stand with feet about shoulder-width apart.", "Sit hips down and back while keeping the whole foot planted.", "Stand tall by driving through the floor."],
              formCues: ["Knees track in the same direction as toes.", "Keep ribs stacked over pelvis.", "Use only a depth you can control."],
              defaultSets: 3, defaultReps: 10, defaultRestSeconds: 60),
        .init(id: "reverse-lunge", name: "Reverse lunge", category: .strength,
              equipment: [.bodyweight], visual: .lunge,
              primaryMuscles: ["Quads", "Glutes"],
              instructions: ["Step one foot back and land softly on the ball of the foot.", "Lower both knees under control.", "Push through the front foot to return."],
              formCues: ["Keep the front heel down.", "Keep the front knee tracking over the foot.", "Stay tall rather than pitching forward."],
              defaultSets: 3, defaultReps: 8, defaultRestSeconds: 60),
        .init(id: "incline-pushup", name: "Incline push-up", category: .strength,
              equipment: [.bodyweight, .bench], visual: .pushup,
              primaryMuscles: ["Chest", "Triceps", "Shoulders"],
              instructions: ["Place hands on a stable raised surface.", "Lower the chest between the hands.", "Press the surface away until elbows are straight."],
              formCues: ["Keep head, ribs, hips, and heels in one line.", "Let elbows travel diagonally, not straight sideways.", "Use a higher surface if alignment breaks."],
              defaultSets: 3, defaultReps: 8, defaultRestSeconds: 60),
        .init(id: "pushup", name: "Push-up", category: .strength,
              equipment: [.bodyweight], visual: .pushup,
              primaryMuscles: ["Chest", "Triceps", "Shoulders"],
              instructions: ["Start in a strong plank with hands below shoulders.", "Lower the chest under control.", "Press back to the plank."],
              formCues: ["Keep the body moving as one unit.", "Do not let hips sag.", "Shorten the range or use an incline if needed."],
              defaultSets: 3, defaultReps: 8, defaultRestSeconds: 75),
        .init(id: "glute-bridge", name: "Glute bridge", category: .strength,
              equipment: [.bodyweight], visual: .bridge,
              primaryMuscles: ["Glutes", "Hamstrings"],
              instructions: ["Lie on your back with knees bent and feet planted.", "Drive through the feet and lift the hips.", "Pause, then lower under control."],
              formCues: ["Finish with ribs and pelvis stacked.", "Do not force the lower back into an arch.", "Keep knees tracking over feet."],
              defaultSets: 3, defaultReps: 12, defaultRestSeconds: 45),
        .init(id: "front-plank", name: "Front plank", category: .strength,
              equipment: [.bodyweight], visual: .plank,
              primaryMuscles: ["Core", "Shoulders"],
              instructions: ["Set elbows below shoulders.", "Lift knees and make a straight line from head to heels.", "Breathe while holding tension."],
              formCues: ["Keep hips level with shoulders.", "Press the floor away.", "Stop the set when alignment changes."],
              defaultSets: 3, defaultDurationSeconds: 25, defaultRestSeconds: 45),
        .init(id: "dead-bug", name: "Dead bug", category: .strength,
              equipment: [.bodyweight], visual: .deadBug,
              primaryMuscles: ["Core"],
              instructions: ["Lie on your back with hips and knees bent.", "Reach opposite arm and leg away slowly.", "Return and alternate sides."],
              formCues: ["Keep the lower ribs heavy.", "Move only as far as the trunk stays still.", "Exhale during the reach."],
              defaultSets: 3, defaultReps: 8, defaultRestSeconds: 45),
        .init(id: "bird-dog", name: "Bird dog", category: .strength,
              equipment: [.bodyweight], visual: .birdDog,
              primaryMuscles: ["Core", "Glutes", "Back"],
              instructions: ["Start on hands and knees.", "Reach opposite arm and leg long.", "Return without shifting and alternate."],
              formCues: ["Keep hips square to the floor.", "Reach long rather than high.", "Move slowly enough to stay balanced."],
              defaultSets: 3, defaultReps: 8, defaultRestSeconds: 45),
        .init(id: "one-arm-dumbbell-row", name: "One-arm dumbbell row", category: .strength,
              equipment: [.dumbbells, .bench], visual: .row,
              primaryMuscles: ["Upper back", "Biceps"],
              instructions: ["Support one hand on a stable bench and hinge at the hips.", "Pull the dumbbell toward the hip.", "Lower it until the arm is long."],
              formCues: ["Keep shoulders and hips square.", "Avoid twisting to lift the weight.", "Keep the neck in line with the spine."],
              defaultSets: 3, defaultReps: 10, defaultRestSeconds: 60),
        .init(id: "dumbbell-overhead-press", name: "Dumbbell overhead press", category: .strength,
              equipment: [.dumbbells], visual: .overheadPress,
              primaryMuscles: ["Shoulders", "Triceps"],
              instructions: ["Stand tall with dumbbells near shoulder height.", "Press overhead without leaning back.", "Lower under control."],
              formCues: ["Keep ribs stacked over pelvis.", "Finish with weights over the shoulders.", "Use a load you can control without arching."],
              defaultSets: 3, defaultReps: 8, defaultRestSeconds: 75),
        .init(id: "dumbbell-curl", name: "Dumbbell curl", category: .strength,
              equipment: [.dumbbells], visual: .curl,
              primaryMuscles: ["Biceps"],
              instructions: ["Stand tall with arms by your sides.", "Bend the elbows to raise the weights.", "Lower fully under control."],
              formCues: ["Keep elbows close to the ribs.", "Do not swing the torso.", "Use the same controlled speed both ways."],
              defaultSets: 2, defaultReps: 12, defaultRestSeconds: 45),
        .init(id: "hip-flexor-stretch", name: "Half-kneeling hip flexor stretch", category: .mobility,
              equipment: [.bodyweight], visual: .hipFlexorStretch,
              primaryMuscles: ["Hip flexors"],
              instructions: ["Kneel with one foot in front.", "Gently tuck the pelvis.", "Shift forward slightly until the front of the rear hip feels a mild stretch."],
              formCues: ["Keep the torso tall.", "Avoid arching the lower back.", "A stretch should feel mild, never sharp."],
              defaultSets: 2, defaultDurationSeconds: 30, defaultRestSeconds: 15),
        .init(id: "hamstring-stretch", name: "Supported hamstring stretch", category: .mobility,
              equipment: [.bodyweight], visual: .hamstringStretch,
              primaryMuscles: ["Hamstrings"],
              instructions: ["Extend one leg with heel down and knee softly bent.", "Hinge forward from the hips.", "Hold a mild stretch behind the thigh."],
              formCues: ["Keep the spine long.", "Do not force the knee straight.", "Back off if you feel tingling or sharp pain."],
              defaultSets: 2, defaultDurationSeconds: 30, defaultRestSeconds: 15),
        .init(id: "calf-stretch", name: "Wall calf stretch", category: .mobility,
              equipment: [.bodyweight], visual: .calfStretch,
              primaryMuscles: ["Calves"],
              instructions: ["Place hands on a wall and step one foot back.", "Keep the rear heel planted.", "Lean forward until the rear calf feels a mild stretch."],
              formCues: ["Point both feet forward.", "Keep the rear knee straight but not locked.", "Do not bounce."],
              defaultSets: 2, defaultDurationSeconds: 30, defaultRestSeconds: 15),
        .init(id: "child-pose", name: "Child's pose", category: .mobility,
              equipment: [.bodyweight], visual: .childPose,
              primaryMuscles: ["Back", "Shoulders", "Hips"],
              instructions: ["Start on hands and knees.", "Sit hips toward heels while reaching arms forward.", "Breathe into a comfortable position."],
              formCues: ["Use a smaller range if knees or hips feel pinched.", "Keep the neck relaxed.", "The position should be comfortable enough to breathe."],
              defaultSets: 2, defaultDurationSeconds: 40, defaultRestSeconds: 15),
        .init(id: "thoracic-rotation", name: "Open-book rotation", category: .mobility,
              equipment: [.bodyweight], visual: .thoracicRotation,
              primaryMuscles: ["Upper back", "Chest"],
              instructions: ["Lie on your side with knees bent and arms together.", "Rotate the top arm and chest open.", "Return slowly and repeat."],
              formCues: ["Keep knees stacked.", "Follow the moving hand with your eyes.", "Use a range that stays smooth and pain-free."],
              defaultSets: 2, defaultReps: 6, defaultRestSeconds: 15),
        .init(id: "doorway-chest-stretch", name: "Doorway chest stretch", category: .mobility,
              equipment: [.bodyweight], visual: .chestStretch,
              primaryMuscles: ["Chest", "Front shoulders"],
              instructions: ["Place a forearm on a stable doorway below shoulder height.", "Step forward gently.", "Hold a mild stretch across the chest."],
              formCues: ["Keep the shoulder down away from the ear.", "Do not force the arm behind you.", "Stop for pinching or sharp discomfort."],
              defaultSets: 2, defaultDurationSeconds: 25, defaultRestSeconds: 15),
    ]

    private static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    static func exercise(_ id: String) -> ExerciseDefinition? { byID[id] }
}

enum WorkoutPlanValidator {
    static func validate(_ plan: WorkoutPlan, preferences: WorkoutPreferences) -> WorkoutPlan? {
        let allowedEquipment = preferences.equipment.union([.bodyweight])
        var seen = Set<String>()
        let validated = plan.exercises.compactMap { item -> ExercisePrescription? in
            guard seen.insert(item.exerciseID).inserted,
                  let exercise = ExerciseCatalog.exercise(item.exerciseID),
                  !preferences.avoidExerciseIDs.contains(item.exerciseID),
                  exercise.equipment.isSubset(of: allowedEquipment) else { return nil }

            var copy = item
            copy.sets = min(6, max(1, copy.sets))
            copy.restSeconds = min(180, max(10, copy.restSeconds))
            if exercise.defaultReps != nil {
                copy.reps = min(30, max(1, copy.reps ?? exercise.defaultReps ?? 8))
                copy.durationSeconds = nil
            } else {
                copy.durationSeconds = min(180, max(10, copy.durationSeconds ?? exercise.defaultDurationSeconds ?? 30))
                copy.reps = nil
            }
            return copy
        }
        guard !validated.isEmpty else { return nil }

        var result = plan
        result.targetMinutes = preferences.sanitizedDuration
        result.exercises = Array(validated.prefix(12))
        result.title = String(result.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        if result.title.isEmpty { result.title = preferences.focus.title }
        result.rationale = String(result.rationale.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        return result
    }
}

enum DeterministicWorkoutBuilder {
    static func build(preferences: WorkoutPreferences, date: Date = Date()) -> WorkoutPlan {
        let allowedEquipment = preferences.equipment.union([.bodyweight])
        let categories: Set<ExerciseCategory>
        switch preferences.focus {
        case .strength: categories = [.strength]
        case .mobility: categories = [.mobility]
        case .mixed: categories = [.strength, .mobility]
        }
        let eligible = ExerciseCatalog.all.filter {
            categories.contains($0.category)
                && $0.equipment.isSubset(of: allowedEquipment)
                && !preferences.avoidExerciseIDs.contains($0.id)
        }

        let targetCount = min(10, max(3, preferences.sanitizedDuration / 6))
        var selected: [ExerciseDefinition] = []
        if preferences.focus == .mixed {
            let strength = eligible.filter { $0.category == .strength }
            let mobility = eligible.filter { $0.category == .mobility }
            selected = Array(strength.prefix(max(2, targetCount - 2))) + Array(mobility.prefix(2))
        } else {
            selected = Array(eligible.prefix(targetCount))
        }

        let prescriptions = selected.map { exercise in
            ExercisePrescription(
                exerciseID: exercise.id,
                sets: preferences.experience == .beginner ? min(2, exercise.defaultSets) : exercise.defaultSets,
                reps: exercise.defaultReps,
                durationSeconds: exercise.defaultDurationSeconds,
                restSeconds: exercise.defaultRestSeconds)
        }
        return WorkoutPlan(
            title: preferences.focus.title,
            createdAt: date,
            focus: preferences.focus,
            targetMinutes: preferences.sanitizedDuration,
            exercises: prescriptions,
            rationale: "Built from your available equipment, experience, time, and excluded movements.")
    }
}

// MARK: - Wellness snapshot persistence (decode-and-quarantine)
//
// `WellnessStore.decodeAndSort(from:)` used to do `try? JSONDecoder().decode(Snapshot.self,
// from: data)` and treat any failure — including one corrupt meal buried in 1,500 otherwise-good
// ones — as "nothing here." The store would then start empty, and the next mutation (adding a
// meal, logging a supplement, anything) would `save()` that empty state right over
// `wellness.json`, permanently. This was the first store this was found and fixed in; the fix
// itself — `LossyArray`/`LossyDictionary` so one bad record doesn't sink the whole file, and
// quarantining a file that fails to parse at all before anything can overwrite it — now lives in
// `Shared/SnapshotPersistence.swift`, generic over any store's snapshot type, so the sweep to
// `ListenHistoryStore`/`PodcastLibrary`/`VoiceNoteStore`/`RoutineStore`/`CalendarWriteBack`/
// `ExceptionStore` didn't have to duplicate it six more times. `WellnessSnapshotLoader` below is
// now a thin, type-specific wrapper around `SnapshotLoader`, kept so `WellnessStore` (and its
// tests) don't need to change. Still free of `WellnessStore`'s `AppSupport`/`CloudBackup`/
// CloudKit dependency chain — same reasoning `FoodCorrectionBook` and `MealEntry.applyingUpdate`
// were split out for — so it can be exercised in tests against a throwaway temp file.

/// The full on-disk shape of `wellness.json`.
struct WellnessSnapshot: Sendable {
    var version = 1
    var meals: [MealEntry] = []
    var supplements: [SupplementSchedule] = []
    var supplementLogs: [SupplementLog] = []
    var workoutPlans: [WorkoutPlan] = []
    var workoutCompletions: [WorkoutCompletion] = []
    var foodCorrections: [String: FoodCorrection] = [:]
    /// How many individual records — across every collection above — failed to decode and were
    /// dropped while everything else loaded fine. A derived signal, not part of the file format:
    /// deliberately excluded from `CodingKeys` below so it is never written to `wellness.json`.
    var droppedRecordCount = 0

    init() {}
}

extension WellnessSnapshot: Codable {
    private enum CodingKeys: String, CodingKey {
        case version, meals, supplements, supplementLogs, workoutPlans, workoutCompletions, foodCorrections
    }

    /// Decodes each collection element-by-element via `LossyArray`/`LossyDictionary` — one
    /// unparseable meal, supplement, log, plan, completion, or food correction is dropped and
    /// tallied into `droppedRecordCount`, rather than sinking the entire snapshot the way
    /// synthesized `Decodable` on `[MealEntry]` etc. would (one throwing element fails the whole
    /// array). `version` keeps the plain `decodeIfPresent` default it always had.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1

        var dropped = 0
        func array<T: Decodable & Sendable>(_ key: CodingKeys) throws -> [T] {
            let lossy = try container.decodeIfPresent(LossyArray<T>.self, forKey: key)
            dropped += lossy?.droppedCount ?? 0
            return lossy?.elements ?? []
        }

        meals = try array(.meals)
        supplements = try array(.supplements)
        supplementLogs = try array(.supplementLogs)
        workoutPlans = try array(.workoutPlans)
        workoutCompletions = try array(.workoutCompletions)

        let corrections = try container.decodeIfPresent(LossyDictionary<FoodCorrection>.self, forKey: .foodCorrections)
        foodCorrections = corrections?.elements ?? [:]
        dropped += corrections?.droppedCount ?? 0

        droppedRecordCount = dropped
    }

    /// Written explicitly (rather than relying on synthesis alongside the hand-written
    /// `init(from:)` above) so there is no ambiguity about `droppedRecordCount` — a derived,
    /// in-memory-only signal — ever being written to disk.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(meals, forKey: .meals)
        try container.encode(supplements, forKey: .supplements)
        try container.encode(supplementLogs, forKey: .supplementLogs)
        try container.encode(workoutPlans, forKey: .workoutPlans)
        try container.encode(workoutCompletions, forKey: .workoutCompletions)
        try container.encode(foodCorrections, forKey: .foodCorrections)
    }
}

/// Outcome of attempting to load a `wellness.json`-shaped file. A type-specific alias over the
/// generic `SnapshotLoadResult` (`Shared/SnapshotPersistence.swift`) so `WellnessStore` and its
/// tests keep referring to `WellnessSnapshotLoadResult`/`.empty`/`.loaded`/`.corrupt` unchanged.
typealias WellnessSnapshotLoadResult = SnapshotLoadResult<WellnessSnapshot>

/// Reads and decodes a `wellness.json`-shaped file without ever risking the original — see
/// `SnapshotLoader` for the mechanics (decode-or-quarantine, never mutating `url` itself). A
/// thin, type-specific wrapper: all the actual logic is generic and shared with the rest of the
/// sweep this fixed (`ListenHistoryStore`, `PodcastLibrary`, `VoiceNoteStore`, `RoutineStore`,
/// `CalendarWriteBack`, `ExceptionStore`).
enum WellnessSnapshotLoader {
    static func load(from url: URL, now: Date = Date()) -> WellnessSnapshotLoadResult {
        SnapshotLoader.load(from: url, as: WellnessSnapshot.self, now: now)
    }
}
