import Combine
import Foundation

/// The meal backlog (`MealInboxItem`): what's waiting to be said, estimated or reviewed. Kept in
/// Application Support/meal-inbox.json and synced item by item (`ControlKind.mealInbox`), so a
/// photo the iPhone found can be answered on the Mac and reviewed on the iPad.
@MainActor
final class MealInboxStore: ObservableObject {
    static let shared = MealInboxStore()

    @Published private(set) var items: [MealInboxItem] = []

    /// Something changed that may leave a meal to estimate (`MealBacklogProcessor`).
    var onChange: (() -> Void)?

    private let fileURL: URL
    private let photos: MealPhotoStore

    init(fileURL: URL = AppSupport.directory.appendingPathComponent("meal-inbox.json"),
         photos: MealPhotoStore = .shared) {
        self.fileURL = fileURL
        self.photos = photos
        load()
    }

    /// This install, for who estimates what (`MealBacklogRouting`). Made once, kept.
    static let installID: String = {
        let key = "mealBacklog.installID"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }()

    func item(_ id: UUID) -> MealInboxItem? { items.first { $0.id == id } }

    /// Meals waiting for words, oldest first.
    var awaitingNote: [MealInboxItem] {
        items.filter { $0.state == .awaitingNote }.sorted { $0.eatenAt < $1.eatenAt }
    }

    /// Every photo the scanner has already turned into a backlog meal, by library id.
    var knownAssetIDs: Set<String> { Set(items.flatMap { $0.photos.compactMap(\.assetID) }) }

    /// The same, by cloud key — found on any device.
    var knownCloudKeys: Set<String> { Set(items.flatMap { $0.photos.compactMap(\.cloudKey) }) }

    // MARK: - Changes

    /// `offer`: meals this device found in the library that another may have found first, under
    /// the same id (`MealPhotoIdentity`). One already here is left as it is, and each goes up as an
    /// offer, so an answer, a dismissal or a meal logged elsewhere always beats it.
    func add(_ new: [MealInboxItem], offer: Bool = false) {
        guard !new.isEmpty else { return }
        var added = false
        for var item in new {
            if offer, items.contains(where: { $0.id == item.id }) { continue }
            if item.state == .ready { stampReady(&item) }
            items.removeAll { $0.id == item.id }
            items.append(item)
            if offer {
                ControlChangeReporter.offered(.mealInbox, item.id.uuidString)
            } else {
                report(item)
            }
            added = true
        }
        if added { commit() }
    }

    /// Photos found close to a meal already waiting for words join it rather than asking twice.
    func addPhotos(_ refs: [MealPhotoRef], to id: UUID) {
        mutate(id) { item in
            let known = Set(item.photos.map(\.id))
            item.photos += refs.filter { !known.contains($0.id) }
            if let first = item.photos.compactMap(\.takenAt).min() { item.eatenAt = first }
        }
    }

    /// Words for a meal: it's estimated with them. Also re-estimates one already estimated.
    func answer(_ id: UUID, note: String) {
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { return }
        mutate(id) { item in
            item.note = note
            item.state = .ready
            item.failure = nil
            item.proposal = nil
            stampReady(&item)
        }
    }

    /// New words for a meal already described or estimated: it's estimated again with them. Empty
    /// words on a photo meal estimate it from the photo alone. Returns the meal as it was, for Undo;
    /// nil when nothing changed.
    @discardableResult
    func changeNote(_ id: UUID, to note: String) -> MealInboxItem? {
        guard let before = item(id), var changed = before.withNote(note) else { return nil }
        stampReady(&changed)
        mutate(id) { $0 = changed }
        return before
    }

    /// Undo for `changeNote`: the meal back as it was, words and estimate. An estimate still
    /// running for the new words finds the meal changed and is dropped (`propose`).
    func restore(_ previous: MealInboxItem) {
        mutate(previous.id) { $0 = previous }
    }

    /// Estimate from the photos alone.
    func usePhotoOnly(_ id: UUID) {
        mutate(id) { item in
            guard item.hasPhotos else { return }
            item.state = .ready
            item.failure = nil
            stampReady(&item)
        }
    }

    func retry(_ id: UUID) {
        mutate(id) { item in
            guard item.state == .failed || item.state == .proposed else { return }
            if item.hasPhotos || !item.trimmedNote.isEmpty {
                item.state = .ready
                item.failure = nil
                item.proposal = nil
                stampReady(&item)
            } else {
                item.state = .awaitingNote
            }
        }
    }

    /// "Not the same": the photo looked like a meal from before and wasn't. Estimated afresh, and
    /// never matched by its photos again (`RepeatPhotoMeal`).
    func notTheSame(_ id: UUID) {
        mutate(id) { item in
            item = RepeatPhotoMeal.notTheSame(item)
            stampReady(&item)
        }
    }

    /// Moves a meal to another time (and so, perhaps, another day).
    func setEatenAt(_ id: UUID, _ date: Date) {
        mutate(id) { $0.eatenAt = date }
    }

    /// The estimate, for review. Ignored when the meal changed meanwhile (new words, dismissed).
    func propose(_ id: UUID, _ proposal: MealProposal, forNote note: String) {
        mutate(id) { item in
            guard item.state == .ready, item.note == note else { return }
            item.proposal = proposal
            item.state = .proposed
            item.failure = nil
        }
    }

    func fail(_ id: UUID, _ reason: String, forNote note: String) {
        mutate(id) { item in
            guard item.state == .ready, item.note == note else { return }
            item.state = .failed
            item.failure = reason
        }
    }

    /// An edit made in review, kept until the day is logged.
    func editProposal(_ id: UUID, items newItems: [MealItem], name: String) {
        mutate(id) { item in
            // No proposal yet (entered by hand after estimating failed): this becomes it.
            var proposal = item.proposal ?? MealProposal(name: "", items: [])
            proposal.items = newItems
            proposal.name = name
            proposal.warnings = NutritionSanity.warnings(for: newItems)
            item.proposal = proposal
            item.state = .proposed
        }
    }

    /// How much of a food there was, given when asked (`PortionQuestion`): its weight, and a note
    /// on the estimate that this amount was confirmed — so it teaches even when it agrees.
    func answerPortion(_ id: UUID, itemID: UUID, grams: Double, serving: String) {
        mutate(id) { item in
            guard var proposal = item.proposal,
                  let index = proposal.items.firstIndex(where: { $0.id == itemID }) else { return }
            var food = proposal.items[index].withGrams(grams)
            food.serving = GroundedFoodEstimate.serving(serving, grams: grams)
            proposal.items[index] = food
            proposal.warnings = NutritionSanity.warnings(for: proposal.items)
            if var estimate = proposal.estimate, !estimate.confirmed.contains(itemID) {
                estimate.confirmed.append(itemID)
                proposal.estimate = estimate
            }
            item.proposal = proposal
        }
    }

    /// Not a meal: gone, photos and all.
    func dismiss(_ id: UUID) {
        guard let item = takeOut(id) else { return }
        discardPhotos(of: item)
    }

    /// Not a meal, with a way back (`DeleteUndo.notAMeal`): out of the backlog now, its photos
    /// kept until `discardPhotos`, so `putBack` finds them.
    @discardableResult
    func takeOut(_ id: UUID) -> MealInboxItem? {
        guard let item = item(id) else { return nil }
        items.removeAll { $0.id == id }
        ControlChangeReporter.deleted(.mealInbox, id.uuidString)
        commit()
        return item
    }

    /// Undo for `takeOut`: the meal back as it was (the backlog is kept in time order, so in its
    /// place too). A newer edit than the removal, so it comes back on every device.
    func putBack(_ item: MealInboxItem) {
        items.removeAll { $0.id == item.id }
        items.append(item)
        ControlChangeReporter.changed(.mealInbox, item.id.uuidString)
        commit()
    }

    func discardPhotos(of item: MealInboxItem) {
        for photo in item.photos { photos.delete(photo.id) }
    }

    /// Logs reviewed meals: each becomes a meal on its own day and time, keeping its photos, and
    /// leaves the backlog. Returns the meals logged.
    @discardableResult
    func log(_ ids: [UUID], into wellness: WellnessStore) -> [MealEntry] {
        var logged: [MealEntry] = []
        for id in ids {
            guard let item = item(id), let proposal = item.proposal, !proposal.items.isEmpty else { continue }
            let entry = MealBacklogDays.entry(for: item, items: proposal.items, name: proposal.name)
            wellness.addMeal(entry)
            logged.append(entry)
            items.removeAll { $0.id == id }
            ControlChangeReporter.deleted(.mealInbox, id.uuidString)
        }
        if !logged.isEmpty { commit() }
        return logged
    }

    // MARK: - Internals

    private func stampReady(_ item: inout MealInboxItem) {
        item.readiedBy = Self.installID
        item.readiedAt = Date()
    }

    private func mutate(_ id: UUID, _ change: (inout MealInboxItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items[index]
        change(&item)
        guard item != items[index] else { return }
        items[index] = item
        report(item)
        commit()
    }

    private func report(_ item: MealInboxItem) {
        ControlChangeReporter.changed(.mealInbox, item.id.uuidString)
    }

    private func commit() {
        items.sort { $0.eatenAt > $1.eatenAt }
        save()
        onChange?()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return }
        // One item that won't decode costs that item, not the backlog.
        items = raw.compactMap { element in
            guard let json = try? JSONSerialization.data(withJSONObject: element) else { return nil }
            return try? JSONDecoder().decode(MealInboxItem.self, from: json)
        }
        items.sort { $0.eatenAt > $1.eatenAt }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? HealthFileProtection.write(data, to: fileURL)
    }
}

extension MealInboxStore: CloudControlSource {
    func cloudItems(_ kind: ControlKind) -> [String: Data] {
        guard kind == .mealInbox else { return [:] }
        let encoder = JSONEncoder()
        var out: [String: Data] = [:]
        for item in items { out[item.id.uuidString] = try? encoder.encode(item) }
        return out
    }

    func cloudItem(_ kind: ControlKind, id: String) -> Data? {
        guard kind == .mealInbox else { return nil }
        return items.first { $0.id.uuidString == id }.flatMap { try? JSONEncoder().encode($0) }
    }

    func applyCloud(_ kind: ControlKind, id: String, item: Data?) -> Bool {
        applyCloudBatch(kind, [(id, item)])[id] ?? true
    }
}

// Another device's backlog in one save and one `onChange`.
extension MealInboxStore: HealthFood.BatchSource {
    func applyCloudBatch(_ kind: ControlKind, _ batch: [(id: String, item: Data?)]) -> [String: Bool] {
        var changed = false
        for (id, item) in batch where kind == .mealInbox {
            guard let uuid = UUID(uuidString: id) else { continue }
            if let item {
                guard let decoded = try? JSONDecoder().decode(MealInboxItem.self, from: item) else { continue }
                items.removeAll { $0.id == uuid }
                items.append(decoded)
            } else {
                items.removeAll { $0.id == uuid }
            }
            changed = true
        }
        if changed { commit() }
        return Dictionary(batch.map { ($0.id, true) }, uniquingKeysWith: { a, _ in a })
    }
}

#if DEBUG
import CoreGraphics

extension MealInboxStore {
    /// `--meal-backlog` (with `--wellness`): one meal in each state, with drawn "photos", for
    /// looking at the backlog without a library or a model.
    func injectPreview(now: Date = Date(), calendar: Calendar = .current) {
        // Fixed ids, so launching with it again replaces rather than piles up.
        var slot = 0
        func previewID() -> UUID {
            slot += 1
            return UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", 900 + slot))!
        }
        func photo(_ hue: (Double, Double, Double)) -> MealPhotoRef {
            let ref = MealPhotoRef(id: previewID(), takenAt: now)
            let context = CGContext(data: nil, width: 480, height: 480, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: 0.55, green: 0.4, blue: 0.3, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 480, height: 480))
            context.setFillColor(CGColor(red: 0.97, green: 0.97, blue: 0.95, alpha: 1))
            context.fillEllipse(in: CGRect(x: 40, y: 40, width: 400, height: 400))
            context.setFillColor(CGColor(red: hue.0, green: hue.1, blue: hue.2, alpha: 1))
            context.fillEllipse(in: CGRect(x: 120, y: 150, width: 220, height: 160))
            context.setFillColor(CGColor(red: 0.95, green: 0.93, blue: 0.85, alpha: 1))
            context.fillEllipse(in: CGRect(x: 170, y: 250, width: 150, height: 110))
            if let image = context.makeImage(), let jpeg = MealPhotoImage.jpeg(image) {
                photos.save(jpeg, id: ref.id)
            }
            return ref
        }
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        let lunch = calendar.date(bySettingHour: 12, minute: 40, second: 0, of: yesterday) ?? yesterday
        let dinner = calendar.date(bySettingHour: 19, minute: 15, second: 0, of: yesterday) ?? yesterday
        let rice = FoodReference(id: "fndds:2708403", name: "Rice, white, cooked",
                                 per100g: .init(calories: 130, proteinGrams: 2.7, carbohydrateGrams: 28.2, fatGrams: 0.3))
        let curry = FoodReference(id: "fndds:27146360", name: "Chicken curry",
                                  per100g: .init(calories: 146, proteinGrams: 12.6, carbohydrateGrams: 5.4, fatGrams: 8.4))
        let items = [
            MealItem(name: "Chicken curry", serving: "1 cup \u{00B7} 240 g", macros: curry.macros(grams: 240),
                     confidence: 0.8, grams: 240, reference: curry),
            MealItem(name: "White rice", serving: "240 g", macros: rice.macros(grams: 240),
                     confidence: 0.8, grams: 240, reference: rice),
            MealItem(name: "Mango lassi", serving: "1 glass", macros: .init(calories: 260, proteinGrams: 7, carbohydrateGrams: 45, fatGrams: 6),
                     confidence: 0.35, grams: 300),
        ]
        // The logged preview meal gets photos too, so a logged row's photo can be opened.
        let logged = [photo((0.75, 0.35, 0.2)), photo((0.95, 0.85, 0.6))].map(\.id)
        WellnessStore.shared.attachPreviewPhotos(logged)
        add([
            MealInboxItem(id: previewID(), eatenAt: now.addingTimeInterval(-50 * 60), photos: [photo((0.85, 0.55, 0.2))],
                          state: .awaitingNote, origin: .scanned),
            MealInboxItem(id: previewID(), eatenAt: now.addingTimeInterval(-4 * 3_600), photos: [photo((0.3, 0.6, 0.25))],
                          note: "caesar salad, extra chicken", state: .failed, origin: .picked,
                          failure: "Apple Intelligence is busy. Try again in a bit."),
            MealInboxItem(id: previewID(), eatenAt: dinner, note: "two beers and a burger", state: .ready, origin: .typed),
            MealInboxItem(id: previewID(), eatenAt: lunch, photos: [photo((0.8, 0.5, 0.15)), photo((0.9, 0.8, 0.5))], note: "curry and rice from the indian place",
                          state: .proposed, origin: .scanned,
                          proposal: MealProposal(name: "Chicken curry with rice", items: items,
                                                 warnings: NutritionSanity.warnings(for: items),
                                                 // The curry's amount learned, the rice's a guess
                                                 // worth asking about.
                                                 estimate: MealEstimate(estimator: GroundedFoodEstimate.version, from: .photo, foods: [
                                                    EstimatedFood(items[0], amount: .learned, factor: 1.2),
                                                    EstimatedFood(items[1], amount: .guess),
                                                    EstimatedFood(items[2], amount: .guess),
                                                 ]))),
        ])
        // `--meal-amount-preview`: the cucumber a photo guessed at half a cup, waiting for review.
        if ProcessInfo.processInfo.arguments.contains("--meal-amount-preview") {
            let cucumber = Self.previewCucumber
            let snack = calendar.date(bySettingHour: 15, minute: 30, second: 0, of: yesterday) ?? yesterday
            add([MealInboxItem(id: previewID(), eatenAt: snack, photos: [photo((0.35, 0.65, 0.3))], state: .proposed,
                               origin: .scanned,
                               proposal: MealProposal(name: "Cucumber wrapped seaweed", items: [cucumber],
                                                      estimate: MealEstimate(estimator: GroundedFoodEstimate.version,
                                                                             from: .photo,
                                                                             foods: [EstimatedFood(cucumber, amount: .guess)])))])
        }
    }

    /// A cucumber as a photo guessed it: "1/2 cup · 60 g" of the USDA food.
    static var previewCucumber: MealItem {
        let reference = FoodReference(id: "fndds:2709784", name: "Cucumber, raw",
                                      per100g: .init(calories: 16, proteinGrams: 0.62, carbohydrateGrams: 2.95, fatGrams: 0.18))
        return MealItem(name: "Cucumber", serving: "1/2 cup \u{00B7} 60 g", macros: reference.macros(grams: 60),
                        confidence: 0.8, grams: 60, reference: reference)
    }
}
#endif
