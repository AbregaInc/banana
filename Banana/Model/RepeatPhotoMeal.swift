import Foundation

/// A meal you've had before, from its photo (docs/design/MEAL-LEARNING.md §4): a new photo close
/// enough to a logged meal's photos proposes that meal's checked numbers instead of a fresh guess
/// — "Looks like your Tuesday breakfast" — with Not the same to estimate it fresh. Pure, for
/// tests: the prints come from `MealPhotoPrints`, the matching runs in `MealBacklogProcessor`.
enum RepeatPhotoMeal {
    /// Two meals this close (`mealDistance`, Vision feature print revision 2) can be the same meal.
    ///
    /// Set by a replay over real meal photos (3 Oct 2026; 7 photos: 5 meals logged
    /// or waiting, one of them three photos of different foods taken together). Of the 21 photo
    /// pairs, the one real repeat — the same bean and seafood stew at lunch and again at dinner,
    /// another bowl, angle and light — was 0.574. The 20 pairs of different foods were 0.696–1.035,
    /// median 0.880; the closest two were two broccoli plates on the same table (0.696), then
    /// orange chicken and the stew (0.753). Each photo against copies of itself cropped, turned
    /// 10°, darker and warmer, or from further away: 0.17–0.75, median 0.35. So it starts strict:
    /// the real repeat is in, the nearest different meal 0.1 out. As meals, nothing in the replay
    /// would have been proposed: the stew's twin was logged with two other foods (`mealDistance`).
    /// Move it only on more photos — `--photo-repeat-probe` logs the numbers from a phone's log.
    static let threshold: Float = 0.60

    /// …and clearly closer than the nearest meal that isn't the same one: two meals that look
    /// alike (two broccoli plates) mustn't be confused. In the replay the real repeat's photos
    /// were 0.76 of the way to the nearest different food's.
    ///
    /// 0.80 since the phone's own photos were looked at (`--photo-repeat-probe`, 5 Oct 2026: 19
    /// logged meals, 26 photos, none of them a repeat). Their nearest neighbours — all different
    /// meals — were 0.579–0.893 apart, median 0.721, so distance alone doesn't tell: the closest,
    /// chicken with broccolini and potatoes at lunch and chicken with broccoli and gnocchi that
    /// evening, were 0.579, a hair from the one real repeat's 0.574. This does: that pair was
    /// 0.84 of the way to its next different meal (0.690) and was proposed at 0.85; the real
    /// repeat was 0.76. Between the two, on one of each — move it again on more.
    static let ratio: Float = 0.80

    /// The same test for the words offered under "What was this?" (`suggestion`), where meals said
    /// alike are one meal (`sameKind`). Set by a replay over the Mac's 31 photographed meals
    /// (14 Oct 2026): his yogurt-and-granola breakfast, four times under four names, was 0.53–0.60
    /// from itself and 0.71–0.91 from anything else. 0.80 caught two of its three repeats (0.593
    /// against 0.733 is 0.81), 0.82 all three and nothing else, 0.85 also put a salad's words on
    /// tacos (0.585 to 0.699).
    static let suggestionRatio: Float = 0.82

    /// Meals logged this long ago or less are compared.
    static let lookback: TimeInterval = 120 * 86_400

    /// Meals this close to the nearest are as near as it: the most recent of them wins, with the
    /// numbers checked last.
    static let tie: Float = 0.01

    /// Straight-line distance between two prints: what `VNFeaturePrintObservation.computeDistance`
    /// gives for revision 2 (it agreed to within 5e-7 in the replay). Prints of different lengths
    /// (another revision) are never close.
    static func distance(_ a: [Float], _ b: [Float]) -> Float {
        guard !a.isEmpty, a.count == b.count else { return .infinity }
        var sum: Float = 0
        for i in a.indices {
            let d = a[i] - b[i]
            sum += d * d
        }
        return sum.squareRoot()
    }

    /// How far apart two meals' photos are: every photo of each must have a close counterpart in
    /// the other — the farthest any is from its nearest. The closest pair alone isn't enough: in
    /// the replay a tomato salad was logged with a photo of the stew eaten alongside it, and the
    /// stew's own meal came out 0.574 from it — its two items would have been proposed for a bowl
    /// of stew. A meal photographed with a dessert last time isn't this plate on its own, either.
    static func mealDistance(_ a: [[Float]], _ b: [[Float]]) -> Float {
        guard !a.isEmpty, !b.isEmpty else { return .infinity }
        func farthest(_ from: [[Float]], _ to: [[Float]]) -> Float {
            from.map { print in to.map { distance(print, $0) }.min() ?? .infinity }.max() ?? .infinity
        }
        return max(farthest(a, b), farthest(b, a))
    }

    /// A logged meal a photo can be matched with: something in it, photos, and recent.
    static func isCandidate(_ meal: MealEntry, now: Date) -> Bool {
        !meal.items.isEmpty && !meal.photoIDs.isEmpty && now.timeIntervalSince(meal.date) <= lookback
    }

    /// Two logged meals that are one meal eaten twice: the same name or words, or the same foods.
    /// Their photos being close is no confusion.
    static func sameMeal(_ a: MealEntry, _ b: MealEntry) -> Bool {
        if a.id == b.id { return true }
        func key(_ text: String) -> String? {
            let key = RepeatMeal.normalized(text)
            return key.count >= 3 ? key : nil
        }
        if let name = key(a.name), name == key(b.name) { return true }
        if let note = key(a.note), note == key(b.note) { return true }
        let foods = { (meal: MealEntry) in Set(meal.items.map { RepeatMeal.normalized($0.name) }) }
        return !a.items.isEmpty && foods(a) == foods(b)
    }

    /// Two meals said alike: one meal by `sameMeal`, or half the words of the shorter in common —
    /// "Breakfast: yogurt, granola and berries" and "Breakfast bowl: Greek yogurt, granola, banana,
    /// blueberries". Only for the words offered (`suggestion`), which are seen before they're sent:
    /// by name alone his four yogurt breakfasts were each other's rivals and none was offered. Not
    /// for copying numbers — chicken, broccoli and gnocchi is said like chicken, broccoli and rice.
    static func sameKind(_ a: MealEntry, _ b: MealEntry) -> Bool {
        if sameMeal(a, b) { return true }
        let (x, y) = (saidWords(a), saidWords(b))
        guard !x.isEmpty, !y.isEmpty else { return false }
        return 2 * x.intersection(y).count >= min(x.count, y.count)
    }

    /// What was said for a meal and its name, without amounts or the words any meal has. Not its
    /// foods' names: those carry brands ("Trader Joe's") that would make any two meals alike.
    static func saidWords(_ meal: MealEntry) -> Set<String> {
        GroundedFoodEstimate.words(meal.name + " " + meal.note)
            .filter { $0.count > 2 }
            .subtracting(mealWords)
    }

    private static let mealWords: Set<String> = ["breakfast", "brunch", "lunch", "dinner", "supper", "snack", "meal",
                                                 "bowl", "dish", "plate", "cup", "cups", "tsp", "tbsp", "slice",
                                                 "slices", "piece", "pieces", "half", "fat", "non", "also", "each", "some"]

    struct Nearest {
        var meal: MealEntry
        var distance: Float
        /// The nearest meal that isn't the same one, if any.
        var nextDifferent: Float?
    }

    /// The logged meal these prints look most like, and how near the nearest different meal is.
    /// Ties (within `tie`) go to the most recent.
    static func nearest(_ prints: [[Float]], among candidates: [(meal: MealEntry, prints: [[Float]])],
                        alike: (MealEntry, MealEntry) -> Bool = sameMeal) -> Nearest? {
        let scored = candidates
            .map { (meal: $0.meal, distance: mealDistance(prints, $0.prints)) }
            .filter { $0.distance.isFinite }
        guard let closest = scored.map(\.distance).min(),
              let best = scored.filter({ $0.distance <= closest + tie }).max(by: { $0.meal.date < $1.meal.date })
        else { return nil }
        let different = scored.filter { !alike($0.meal, best.meal) }.map(\.distance).min()
        return Nearest(meal: best.meal, distance: best.distance, nextDifferent: different)
    }

    /// The logged meal a new meal's photos show again: of the meals logged in the last 120 days
    /// with items and photos, the nearest — under `threshold`, and clearly nearer than any
    /// different meal (`ratio`). Nil when nothing is that close, or two different meals are.
    /// A meal with a photo that has no print (not on this device) isn't compared: the missing one
    /// may be what the new photos don't show.
    static func match(_ prints: [[Float]], candidates: [(meal: MealEntry, prints: [[Float]])],
                      now: Date = Date()) -> (meal: MealEntry, distance: Float)? {
        match(prints, candidates: candidates, now: now, alike: sameMeal, ratio: ratio)
    }

    /// The words to fill "What was this?" with: the meal these photos look like, by the same test
    /// with meals said alike as one (`sameKind`, `suggestionRatio`), and what was said for it
    /// (`suggestedWords`).
    static func suggestion(_ prints: [[Float]], candidates: [(meal: MealEntry, prints: [[Float]])],
                           now: Date = Date()) -> String? {
        match(prints, candidates: candidates, now: now, alike: sameKind, ratio: suggestionRatio)
            .flatMap { suggestedWords($0.meal) }
    }

    private static func match(_ prints: [[Float]], candidates: [(meal: MealEntry, prints: [[Float]])], now: Date,
                              alike: (MealEntry, MealEntry) -> Bool, ratio: Float) -> (meal: MealEntry, distance: Float)? {
        let eligible = candidates.filter { isCandidate($0.meal, now: now) && $0.prints.count == $0.meal.photoIDs.count }
        guard let near = nearest(prints, among: eligible, alike: alike), near.distance < threshold else { return nil }
        if let next = near.nextDifferent, near.distance >= ratio * next { return nil }
        return (near.meal, near.distance)
    }

    /// What "What was this?" is filled with for a photo that looks like a logged meal: the words
    /// said for that meal, or its name — ready to Add, or to change first. Nil when it has neither.
    static func suggestedWords(_ past: MealEntry) -> String? {
        [past.note, past.name]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    // MARK: - The proposal

    /// The meal proposed again: its items (new ids, so each is its own row in the estimate's
    /// record), its name, and where it came from.
    /// Whether what they wrote fits the meal a photo looks like: no words, or a word in common
    /// with its name, words or foods. Their words win over a look-alike photo, as everywhere else —
    /// "chicken salad" under a photo like last week's pasta is chicken salad.
    static func wordsAgree(_ note: String, with past: MealEntry) -> Bool {
        let said = GroundedFoodEstimate.words(note).filter { $0.count > 2 }
        guard !said.isEmpty else { return true }
        let theirs = GroundedFoodEstimate.words(([past.name, past.note] + past.items.map(\.name)).joined(separator: " "))
        return !said.isDisjoint(with: theirs)
    }

    static func proposal(copying past: MealEntry, calendar: Calendar = .current) -> MealProposal {
        let items = past.items.map { old -> MealItem in
            var copy = old
            copy.id = UUID()
            return copy
        }
        let name = past.name.isEmpty ? GroundedFoodEstimate.mealName("", items: items) : past.name
        let estimate = MealEstimate(estimator: GroundedFoodEstimate.version, from: .repeatedPhoto,
                                    foods: items.map { EstimatedFood($0, amount: .repeated) })
        return MealProposal(name: name, items: items, warnings: [warning(for: past, calendar: calendar)],
                            estimator: GroundedFoodEstimate.version, estimate: estimate, repeatOf: past.id)
    }

    /// "Looks like your Tuesday, September 30 breakfast" — dated like "Same as your … meal".
    static func warning(for past: MealEntry, calendar: Calendar = .current) -> String {
        "Looks like your \(past.date.formatted(.dateTime.weekday(.wide).month().day())) \(mealWord(at: past.date, calendar: calendar))"
    }

    /// What a meal at that time of day is called; "meal" between them.
    static func mealWord(at date: Date, calendar: Calendar = .current) -> String {
        switch calendar.component(.hour, from: date) {
        case 5..<11: "breakfast"
        case 11..<15: "lunch"
        case 17..<22: "dinner"
        default: "meal"
        }
    }

    /// Told "Not the same": estimated afresh from its photos and words, and never matched by its
    /// photos again. The store stamps who readied it.
    static func notTheSame(_ item: MealInboxItem) -> MealInboxItem {
        var item = item
        item.notTheSame = true
        item.state = .ready
        item.proposal = nil
        item.failure = nil
        return item
    }
}
