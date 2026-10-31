import Foundation

// The meal backlog: photos and words waiting to become logged meals. A photo found in the library
// (or picked) first asks what it was; once it has words — or is told to go on the photo alone —
// it's estimated, and the estimate waits for its day's review. Pure, for tests; the store is
// `MealInboxStore`, the estimating `MealBacklogProcessor`. See docs/design/MEAL-BACKLOG.md.

/// A meal waiting to be logged.
struct MealInboxItem: Codable, Hashable, Identifiable, Sendable {
    enum State: String, Codable, Sendable {
        /// Photos with no words yet: it asks "What was this?" before anything is estimated.
        case awaitingNote
        /// Has words, or was told to go on the photo alone: waiting to be estimated.
        case ready
        /// Estimated; waiting for its day's review.
        case proposed
        /// Estimating didn't work. Retry, or enter it by hand.
        case failed
    }

    enum Origin: String, Codable, Sendable {
        /// Chosen in "Add photos & notes".
        case picked
        /// Found in the photo library by the phone (`MealPhotoScanner`).
        case scanned
        /// Words only.
        case typed
    }

    var id = UUID()
    /// When it was eaten: the first photo's time, or the time its words or day gave it.
    var eatenAt: Date
    var photos: [MealPhotoRef] = []
    /// What the person said it was. Empty for a photo told to go on its own.
    var note = ""
    var state: State
    var origin: Origin
    var proposal: MealProposal?
    /// Why estimating failed, in words for the row.
    var failure: String?
    var createdAt = Date()
    /// The install that made it `ready`, and when: that device estimates it (`MealBacklogRouting`).
    var readiedBy: String?
    var readiedAt: Date?
    /// Told "Not the same" when a photo looked like a meal from before: estimated fresh from now on
    /// (`RepeatPhotoMeal`).
    var notTheSame = false

    init(id: UUID = UUID(), eatenAt: Date, photos: [MealPhotoRef] = [], note: String = "", state: State,
         origin: Origin, proposal: MealProposal? = nil, failure: String? = nil, createdAt: Date = Date(),
         readiedBy: String? = nil, readiedAt: Date? = nil, notTheSame: Bool = false) {
        self.id = id
        self.eatenAt = eatenAt
        self.photos = photos
        self.note = note
        self.state = state
        self.origin = origin
        self.proposal = proposal
        self.failure = failure
        self.createdAt = createdAt
        self.readiedBy = readiedBy
        self.readiedAt = readiedAt
        self.notTheSame = notTheSame
    }

    private enum CodingKeys: String, CodingKey {
        case id, eatenAt, photos, note, state, origin, proposal, failure, createdAt, readiedBy, readiedAt, notTheSame
    }

    /// Everything but the id, the time and the state defaults, so a field added later — or a state
    /// a newer build writes — can't make an older build drop the whole backlog. An unknown state
    /// reads as `awaitingNote`: asked again rather than lost.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        eatenAt = try c.decode(Date.self, forKey: .eatenAt)
        photos = (try? c.decodeIfPresent([MealPhotoRef].self, forKey: .photos)) ?? []
        note = (try? c.decodeIfPresent(String.self, forKey: .note)) ?? ""
        state = (try? c.decodeIfPresent(State.self, forKey: .state)) ?? .awaitingNote
        origin = (try? c.decodeIfPresent(Origin.self, forKey: .origin)) ?? .picked
        proposal = try? c.decodeIfPresent(MealProposal.self, forKey: .proposal)
        failure = try? c.decodeIfPresent(String.self, forKey: .failure)
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? eatenAt
        readiedBy = try? c.decodeIfPresent(String.self, forKey: .readiedBy)
        readiedAt = try? c.decodeIfPresent(Date.self, forKey: .readiedAt)
        notTheSame = (try? c.decodeIfPresent(Bool.self, forKey: .notTheSame)) ?? false
    }

    var hasPhotos: Bool { !photos.isEmpty }
    var trimmedNote: String { note.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The meal with new words, waiting to be estimated again with them — its old estimate gone.
    /// Empty words on a photo meal mean the photo alone. Nil when the words didn't change, or
    /// there'd be nothing left to estimate from.
    func withNote(_ note: String) -> MealInboxItem? {
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard note != trimmedNote, !note.isEmpty || hasPhotos else { return nil }
        var changed = self
        changed.note = note
        changed.state = .ready
        changed.failure = nil
        changed.proposal = nil
        return changed
    }
}

/// One photo of a meal. The image itself is in `MealPhotoStore`, under `id`.
struct MealPhotoRef: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    /// When it was taken, from the photo itself; nil when it doesn't say.
    var takenAt: Date?
    /// The photo library's id for it on the device that found it — what keeps the scanner from
    /// adding it twice. Meaningless anywhere else.
    var assetID: String?
    /// The same photo on every device (`MealPhotoIdentity.key`, from its iCloud Photos cloud
    /// identifier): what keeps two devices scanning one library from making two meals of it.
    var cloudKey: String?
    /// What its depth measured when it came in (a Portrait photo, Banana's camera): the plate's
    /// size, the food's volume. Read once from the original — the copy kept has no depth.
    var depth: PhotoDepth?
}

/// What estimating a backlog meal came up with, for review.
struct MealProposal: Codable, Hashable, Sendable {
    var name: String
    var items: [MealItem]
    /// Things worth a second look ("Calories don't add up to the macros"), for the review.
    var warnings: [String] = []
    var madeAt = Date()
    /// Which estimator made it (`GroundedFoodEstimate.version`); nil for those before 2.
    var estimator: Int?
    /// The estimate as first made, never edited (docs/design/MEAL-LEARNING.md §1). Logged with
    /// the meal, so how far it was moved can be learned from.
    var estimate: MealEstimate?
    /// The logged meal a photo looked like (`RepeatPhotoMeal`), whose items these are.
    var repeatOf: UUID?

    var totals: NutritionMacros { items.reduce(.init()) { $0 + $1.macros.sanitized } }
}

// MARK: - Photos into meals

enum MealPhotoGrouping {
    /// Photos this close together are one meal: the plate, then the dessert.
    static let gap: TimeInterval = 45 * 60

    /// Groups photos into meals, oldest first. A photo within `gap` of the previous one joins its
    /// meal; a photo that doesn't say when it was taken is a meal of its own.
    static func group<T>(_ photos: [T], takenAt: (T) -> Date?, gap: TimeInterval = gap) -> [[T]] {
        let dated = photos.compactMap { photo in takenAt(photo).map { (photo, $0) } }.sorted { $0.1 < $1.1 }
        var groups: [[T]] = []
        var last: Date?
        for (photo, date) in dated {
            if let last, date.timeIntervalSince(last) <= gap, !groups.isEmpty {
                groups[groups.count - 1].append(photo)
            } else {
                groups.append([photo])
            }
            last = date
        }
        for photo in photos where takenAt(photo) == nil { groups.append([photo]) }
        return groups
    }
}

// MARK: - When a meal logged on a day happened

/// The meals people name, and when each usually happens.
enum MealTextPart: String, CaseIterable, Codable, Sendable {
    case breakfast, brunch, lunch, snack, dinner, dessert, lateNight

    var title: String {
        switch self {
        case .breakfast: "Breakfast"
        case .brunch: "Brunch"
        case .lunch: "Lunch"
        case .snack: "Snack"
        case .dinner: "Dinner"
        case .dessert: "Dessert"
        case .lateNight: "Late night"
        }
    }

    /// The time a meal of this kind is filed at when nothing says otherwise.
    var clock: (hour: Int, minute: Int) {
        switch self {
        case .breakfast: (8, 0)
        case .brunch: (10, 30)
        case .lunch: (12, 30)
        case .snack: (15, 30)
        case .dinner: (19, 0)
        case .dessert: (20, 30)
        case .lateNight: (22, 30)
        }
    }

    /// The words that name it, longest first so "late night" wins over "night".
    var words: [String] {
        switch self {
        case .breakfast: ["breakfast", "brekkie"]
        case .brunch: ["brunch"]
        case .lunch: ["lunch", "lunchtime"]
        case .snack: ["afternoon snack", "snacks", "snack"]
        case .dinner: ["dinner", "supper", "tea time"]
        case .dessert: ["dessert", "pudding"]
        case .lateNight: ["late night", "late-night", "midnight snack"]
        }
    }
}

enum MealLogTime {
    /// When a meal logged on `day` happened, when it has no time of its own: its part of the day's
    /// usual time, or noon for a day already past. On today, never later than now — a lunch logged
    /// at 11 is filed at 11, not in the future.
    static func date(on day: Date, part: MealTextPart?, now: Date = Date(),
                     calendar: Calendar = .current) -> Date {
        let isToday = calendar.isDate(day, inSameDayAs: now)
        guard let part else {
            return isToday ? now : calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
        }
        let at = calendar.date(bySettingHour: part.clock.hour, minute: part.clock.minute, second: 0, of: day) ?? day
        return isToday ? min(at, now) : at
    }
}

// MARK: - A day's worth of words into meals

enum MealTextSplitter {
    struct Piece: Equatable, Sendable {
        var part: MealTextPart?
        var text: String
    }

    /// "Oatmeal for breakfast, chicken caesar at lunch and two beers with dinner" → three meals.
    /// A meal named first ("Lunch: salad, bread") takes what follows; one named after ("salad for
    /// lunch") takes what came before. Lines with no meal named are a meal each; text that names
    /// none at all is one meal.
    static func split(_ text: String) -> [Piece] {
        let clauses = text
            .components(separatedBy: CharacterSet(charactersIn: "\n;."))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var pieces: [Piece] = []
        /// A piece named up front keeps taking clauses until the next name.
        var open: Int?
        var pending: [String] = []

        func flushPending() {
            guard !pending.isEmpty else { return }
            if let open { pieces[open].text = join(pieces[open].text, pending) }
            else { pieces.append(Piece(part: nil, text: join("", pending))) }
            pending = []
        }

        for clause in clauses {
            let subs = mentions(in: clause).count > 1 ? subClauses(clause) : [clause]
            for sub in subs {
                guard let found = mentions(in: sub).first else {
                    if let open { pieces[open].text = join(pieces[open].text, [sub]) }
                    else { pending.append(sub) }
                    continue
                }
                let rest = strip(found, from: sub)
                if found.leading {
                    flushPending()
                    pieces.append(Piece(part: found.part, text: rest))
                    open = pieces.count - 1
                } else {
                    // Named after: it takes what was waiting, and closes.
                    let text = join("", pending + (rest.isEmpty ? [] : [rest]))
                    pending = []
                    pieces.append(Piece(part: found.part, text: text))
                    open = nil
                }
            }
            // A line of its own ends what it started, unless a meal was named up front.
            if open == nil { flushPending() }
        }
        flushPending()
        return pieces
            .map { Piece(part: $0.part, text: tidy($0.text)) }
            .filter { !$0.text.isEmpty }
    }

    private struct Mention {
        var part: MealTextPart
        var range: Range<String.Index>
        /// The clause starts with it ("Lunch: …", "For dinner …").
        var leading: Bool
    }

    private static func mentions(in text: String) -> [Mention] {
        let lower = text.lowercased()
        var found: [Mention] = []
        for part in MealTextPart.allCases {
            for word in part.words {
                var search = lower.startIndex..<lower.endIndex
                while let range = lower.range(of: word, range: search) {
                    search = range.upperBound..<lower.endIndex
                    guard isWordBoundary(lower, range) else { continue }
                    guard !found.contains(where: { $0.range.overlaps(range) }) else { continue }
                    let before = lower[lower.startIndex..<range.lowerBound]
                        .trimmingCharacters(in: .whitespaces).lowercased()
                    let leading = before.isEmpty || ["for", "at", "and for", "then for", "then"].contains(before)
                    found.append(Mention(part: part, range: range, leading: leading))
                }
            }
        }
        return found.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    private static func isWordBoundary(_ text: String, _ range: Range<String.Index>) -> Bool {
        let beforeOK = range.lowerBound == text.startIndex || !text[text.index(before: range.lowerBound)].isLetter
        let afterOK = range.upperBound == text.endIndex || !text[range.upperBound].isLetter
        return beforeOK && afterOK
    }

    /// A clause naming several meals, cut at commas and "and"s.
    private static func subClauses(_ clause: String) -> [String] {
        clause
            .replacingOccurrences(of: " and then ", with: ",")
            .replacingOccurrences(of: " then ", with: ",")
            .replacingOccurrences(of: " and ", with: ",")
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The clause without the words that named the meal: "for lunch", "Lunch:", "at dinner".
    private static func strip(_ mention: Mention, from text: String) -> String {
        let lower = text.lowercased()
        var result = text
        let range = mention.range
        // Take the preposition before it along with it.
        var start = range.lowerBound
        for prep in ["for ", "at ", "with ", "during ", "after ", "before "] {
            let head = lower[lower.startIndex..<range.lowerBound]
            if head.hasSuffix(prep) {
                start = lower.index(range.lowerBound, offsetBy: -prep.count)
                break
            }
        }
        result.removeSubrange(start..<range.upperBound)
        return result
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ":-–—,")))
            .replacingOccurrences(of: "  ", with: " ")
            .replacingOccurrences(of: #"^(was|were|is|had)\s*:?\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
    }

    private static func join(_ head: String, _ tail: [String]) -> String {
        ([head] + tail).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private static func tidy(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",:-–—")))
    }
}

// MARK: - Which device estimates

enum MealBacklogRouting {
    /// Meals waiting for review whose estimate an older estimator made, and that have something
    /// to estimate from again.
    static func outdatedProposals(_ items: [MealInboxItem], version: Int) -> [UUID] {
        items.filter { item in
            item.state == .proposed && (item.proposal?.estimator ?? 1) < version
                && (item.hasPhotos || !item.trimmedNote.isEmpty)
        }.map(\.id)
    }

    /// How long the device that readied a meal has to estimate it before the iPhone does. The
    /// Mac can't read photos (no model with vision on it), so a note typed there is picked up by
    /// the iPhone once this passes.
    static let handoff: TimeInterval = 90
    /// After this, any device that can estimate it does: the one that readied it is gone.
    static let lastResort: TimeInterval = 10 * 60
    /// How long the other devices leave a meal to a Mac that can take it, before doing it themselves.
    static let macHandoff: TimeInterval = 2 * 60
    /// A Mac that hasn't said what it can do in this long is asleep, unplugged or closed.
    static let macHeartbeat: TimeInterval = 45 * 60

    /// Whether this device keeps saying what it can estimate, every `MealEstimators.refresh`.
    /// Only a Mac's status is ever read (`macTakes` ignores every other device), so only a Mac has
    /// to keep proving it is there; the iPhone and iPad say it once, at launch. The repeat is a
    /// timer, and on the phone it woke a process that audio keeps alive for hours for nothing.
    static func repeatsStatus(on role: DeviceRole) -> Bool { role == .mac }

    struct Here: Equatable, Sendable {
        var installID: String
        var isHub: Bool
        var canReadPhotos: Bool
        var canReadText: Bool
        var isMac = false
        /// On mains power, not in Low Power Mode, not hot.
        var onPower = false
    }

    static func canEstimate(_ item: MealInboxItem, here: Here) -> Bool {
        item.hasPhotos ? here.canReadPhotos : here.canReadText
    }

    /// Whether a meal ready to be estimated is waiting on another device: this one isn't working
    /// on it and can't. Its row then offers the ways out the failed one has — enter it by hand,
    /// or say it wasn't a meal — because no other device may ever come. It used to say "Your
    /// iPhone or iPad will estimate this" and offer nothing.
    static func waitsElsewhere(_ item: MealInboxItem, here: Here, working: Bool) -> Bool {
        item.state == .ready && !working && !canEstimate(item, here: here)
    }

    /// Whether a Mac other than this device — on power, and heard from lately — can estimate this
    /// kind of meal: then it's the Mac's to do.
    static func macTakes(_ item: MealInboxItem, estimators: [String: MealEstimatorStatus],
                         except installID: String, now: Date = Date()) -> Bool {
        estimators.contains { id, status in
            id != installID && status.device == "Mac" && status.onPower
                && now.timeIntervalSince(status.at) <= macHeartbeat
                && (item.hasPhotos ? status.canReadPhotos : status.canReadText)
        }
    }

    /// Whether this device should estimate `item` now. One device at a time, as far as the sync
    /// allows: a Mac on power first — it has the compute, and no battery to spend — then the one
    /// it was readied on, then the iPhone, then anyone.
    static func shouldEstimate(_ item: MealInboxItem, here: Here, macTakes: Bool = false,
                               now: Date = Date()) -> Bool {
        guard item.state == .ready, canEstimate(item, here: here) else { return false }
        if here.isMac, here.onPower { return true }
        let waited = item.readiedAt.map { now.timeIntervalSince($0) }
        if macTakes, let waited, waited < macHandoff { return false }
        guard let by = item.readiedBy, let waited else { return here.isHub }
        if by == here.installID { return true }
        if here.isHub, waited >= handoff { return true }
        return waited >= lastResort
    }
}

/// What a device can estimate, shared through iCloud key-value storage (`MealEstimators`) so the
/// others know when a Mac is there to take the work.
struct MealEstimatorStatus: Codable, Equatable, Sendable {
    /// "iPhone", "iPad" or "Mac".
    var device: String
    var canReadPhotos: Bool
    var canReadText: Bool
    var onPower: Bool
    var at: Date
}

/// The bar the system shows while meals are estimated with the app closed
/// (`ContinuedMealEstimates`). It has to keep moving — a bar that stands still gets the task
/// stopped as stalled — so the meal under way creeps toward nine tenths until it's done.
enum MealEstimateProgress {
    static let unitsPerMeal: Int64 = 100

    static func completed(done: Int, total: Int, secondsIntoCurrent: Double) -> Int64 {
        let finished = Int64(max(0, min(done, total))) * unitsPerMeal
        guard done < total else { return finished }
        // About 15 s a meal on the phone: a third of the way at 5 s, nine tenths by ~45 s.
        let creep = Int64(90 * (1 - exp(-max(0, secondsIntoCurrent) / 20)))
        return finished + max(1, creep)
    }

    static func subtitle(done: Int, total: Int) -> String {
        total <= 1 ? "1 meal" : "\(min(done + 1, total)) of \(total)"
    }
}

// MARK: - The same meal again

enum RepeatMeal {
    static func normalized(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// The most recent logged meal described in exactly these words, or named them — "usual
    /// breakfast", "protein shake" — so a meal eaten again gets the numbers already checked
    /// rather than a fresh guess.
    static func match(_ note: String, in meals: [MealEntry]) -> MealEntry? {
        let key = normalized(note)
        guard key.count >= 3 else { return nil }
        return meals
            .filter { !$0.items.isEmpty && (normalized($0.note) == key || normalized($0.name) == key) }
            .max { $0.date < $1.date }
    }
}

// MARK: - Numbers worth a second look

enum NutritionSanity {
    /// kcal per gram of pure fat — no food can be denser.
    static let maxDensity = 9.1
    static let maxItemGrams: Double = 1_500

    private static let alcoholWords = ["beer", "wine", "cocktail", "vodka", "whisky", "whiskey", "gin",
                                       "rum", "tequila", "sake", "cider", "spritz", "margarita", "negroni",
                                       "martini", "prosecco", "champagne", "ipa", "lager", "stout", "liqueur"]

    /// Calories from the macros: 4 per gram of protein and carbohydrate, 9 per gram of fat.
    static func caloriesFromMacros(_ macros: NutritionMacros) -> Double {
        macros.proteinGrams * 4 + macros.carbohydrateGrams * 4 + macros.fatGrams * 9
    }

    /// Why this item's numbers might be wrong, in words; empty when nothing stands out.
    static func warnings(for item: MealItem) -> [String] {
        var found: [String] = []
        let m = item.macros.sanitized
        let name = item.name.lowercased()
        let expected = caloriesFromMacros(m)
        let isAlcohol = alcoholWords.contains { name.contains($0) }
        if !isAlcohol, max(m.calories, expected) > 60,
           abs(m.calories - expected) > 60,
           abs(m.calories - expected) / max(m.calories, expected) > 0.3 {
            found.append("\(item.name): calories don\u{2019}t match the macros (they add up to about \(Int(expected.rounded())) kcal)")
        }
        if let grams = item.grams, grams > 0 {
            if grams > maxItemGrams {
                found.append("\(item.name): \(Int(grams)) g is a lot for one item \u{2014} check the portion")
            }
            if m.calories / grams > maxDensity {
                found.append("\(item.name): more calories than \(Int(grams)) g of anything can hold")
            }
        }
        if m.calories > PortionScaling.implausibleCalories {
            found.append("\(item.name): over \(Int(PortionScaling.implausibleCalories)) kcal in one item")
        }
        return found
    }

    static func warnings(for items: [MealItem]) -> [String] { items.flatMap(warnings(for:)) }
}

// MARK: - Days

enum MealBacklogDays {
    /// Backlog meals eaten on `day`, in the order they were eaten.
    static func items(_ items: [MealInboxItem], on day: Date, calendar: Calendar = .current) -> [MealInboxItem] {
        items.filter { calendar.isDate($0.eatenAt, inSameDayAs: day) }.sorted { $0.eatenAt < $1.eatenAt }
    }

    /// The days with backlog meals, most recent first.
    static func days(_ items: [MealInboxItem], calendar: Calendar = .current) -> [Date] {
        Array(Set(items.map { calendar.startOfDay(for: $0.eatenAt) })).sorted(by: >)
    }

    /// The logged meal a reviewed backlog meal becomes: its own time, words and photos, and the
    /// estimate as first made.
    static func entry(for item: MealInboxItem, items: [MealItem], name: String) -> MealEntry {
        MealEntry(date: item.eatenAt, items: items, note: item.note,
                  source: item.hasPhotos ? .photo : .text, name: name,
                  photoIDs: item.photos.map(\.id), estimate: item.proposal?.estimate)
    }
}
