import Combine
import Foundation

/// Your foods (`MyFood`): what you've scanned, kept in Application Support/my-foods.json and
/// synced food by food (`ControlKind.myFood`), so the gnocchi scanned on the phone is known on the
/// Mac. How often and how much you have each is read off the meal log (`MyFoods.uses(in:)`).
@MainActor
final class MyFoodsStore: ObservableObject {
    static let shared = MyFoodsStore()

    /// Every food, with its uses, most yours first (`MyFoods.ranked`).
    @Published private(set) var foods: [MyFood] = []

    private var stored: [MyFood] = []
    private var uses: [UUID: [MyFood.Use]] = [:]
    private let fileURL: URL
    private var mealsWatch: AnyCancellable?

    init(fileURL: URL = AppSupport.directory.appendingPathComponent("my-foods.json")) {
        self.fileURL = fileURL
        load()
        publish()
    }

    /// Follows the meal log (`WellnessStore.$meals`), so a meal logged with one of these counts as
    /// having it.
    func follow<Meals: Publisher<[MealEntry], Never>>(_ meals: Meals) {
        mealsWatch = meals.sink { [weak self] meals in
            guard let self else { return }
            self.uses = MyFoods.uses(in: meals)
            self.publish()
        }
    }

    func food(_ id: UUID) -> MyFood? { foods.first { $0.id == id } }

    func food(barcode: String) -> MyFood? {
        foods.first { $0.barcode == barcode }
    }

    // MARK: - Checked against the source

    /// Called after foods arrive from another device, so a stale copy is checked like any other
    /// (`ScannedNumbersRepair`).
    var afterCloudApply: (() -> Void)?

    /// One of yours brought into line with what its barcode's source says now
    /// (`MyFoods.reconciled`). Returns it as it is afterwards, or nil when nothing changed.
    @discardableResult
    func reconcile(_ id: UUID, with fresh: MyFood) -> MyFood? {
        guard let food = stored.first(where: { $0.id == id }),
              let fixed = MyFoods.reconciled(food, with: fresh) else { return nil }
        replace(fixed)
        return fixed
    }

    // MARK: - Changes

    /// A scanned food: new, or — the same barcode or name scanned again — the existing one with
    /// the label's numbers, keeping what it has stood in for. Returns it as kept.
    @discardableResult
    func save(_ scanned: MyFood) -> MyFood {
        var food = scanned
        if let existing = stored.first(where: { ($0.barcode != nil && $0.barcode == scanned.barcode)
            || MyFoods.key($0.name) == MyFoods.key(scanned.name) }) {
            food.id = existing.id
            food.addedAt = existing.addedAt
            food.standsFor = Array(Set(existing.standsFor + scanned.standsFor)).sorted()
            food.barcode = scanned.barcode ?? existing.barcode
            food.packageGrams = scanned.packageGrams ?? existing.packageGrams
            food.bought = Array(Set(existing.bought + scanned.bought)).sorted()
        }
        food.numbers = MyFoods.numbersRevision
        food.uses = []
        replace(food)
        return self.food(food.id) ?? food
    }

    /// Scanned in after shopping: kept as `save` keeps it, and bought today.
    @discardableResult
    func bought(_ scanned: MyFood, at date: Date = Date()) -> MyFood {
        let kept = save(scanned)
        guard let stored = stored.first(where: { $0.id == kept.id }) else { return kept }
        let purchased = MyFoods.purchased(stored, at: date)
        if purchased != stored { replace(purchased) }
        return food(kept.id) ?? purchased
    }

    /// The name an item was called by when this food replaced it.
    func note(_ id: UUID, standsFor name: String) {
        guard let food = stored.first(where: { $0.id == id }) else { return }
        let noted = MyFoods.noting(food, standsFor: name)
        guard noted != food else { return }
        replace(noted)
    }

    func rename(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, var food = stored.first(where: { $0.id == id }) else { return }
        food.name = name
        replace(food)
    }

    func delete(_ id: UUID) {
        guard stored.contains(where: { $0.id == id }) else { return }
        stored.removeAll { $0.id == id }
        ControlChangeReporter.deleted(.myFood, id.uuidString)
        commit()
    }

    /// Brings back a deleted food (Undo).
    func restore(_ food: MyFood) {
        var food = food
        food.uses = []
        replace(food)
    }

    private func replace(_ food: MyFood) {
        stored.removeAll { $0.id == food.id }
        stored.append(food)
        ControlChangeReporter.changed(.myFood, food.id.uuidString)
        commit()
    }

    private func commit() {
        save()
        publish()
    }

    private func publish() {
        foods = MyFoods.ranked(stored.map { food in
            var food = food
            food.uses = uses[food.id] ?? []
            return food
        })
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return }
        // One food that won't decode costs that food, not the list.
        stored = raw.compactMap { element in
            guard let json = try? JSONSerialization.data(withJSONObject: element) else { return nil }
            return try? JSONDecoder().decode(MyFood.self, from: json)
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? HealthFileProtection.write(data, to: fileURL)
    }
}

extension MyFoodsStore: CloudControlSource {
    func cloudItems(_ kind: ControlKind) -> [String: Data] {
        guard kind == .myFood else { return [:] }
        let encoder = JSONEncoder()
        var out: [String: Data] = [:]
        for food in stored { out[food.id.uuidString] = try? encoder.encode(food) }
        return out
    }

    func cloudItem(_ kind: ControlKind, id: String) -> Data? {
        guard kind == .myFood else { return nil }
        return stored.first { $0.id.uuidString == id }.flatMap { try? JSONEncoder().encode($0) }
    }

    func applyCloud(_ kind: ControlKind, id: String, item: Data?) -> Bool {
        applyCloudBatch(kind, [(id, item)])[id] ?? true
    }
}

// Another device's foods in one save (the data platform's first pull brings them all at once).
extension MyFoodsStore: HealthFood.BatchSource {
    func applyCloudBatch(_ kind: ControlKind, _ items: [(id: String, item: Data?)]) -> [String: Bool] {
        guard kind == .myFood else { return Dictionary(items.map { ($0.id, true) }, uniquingKeysWith: { a, _ in a }) }
        var changed = false
        for (id, item) in items {
            guard let uuid = UUID(uuidString: id) else { continue }
            stored.removeAll { $0.id == uuid }
            if let item, let decoded = try? JSONDecoder().decode(MyFood.self, from: item) {
                stored.append(decoded)
            }
            changed = true
        }
        if changed {
            commit()
            afterCloudApply?()
        }
        return Dictionary(items.map { ($0.id, true) }, uniquingKeysWith: { a, _ in a })
    }
}
