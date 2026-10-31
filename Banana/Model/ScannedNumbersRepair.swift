import Foundation

/// Keeps what you've scanned true to its source: **a scanned food's numbers are what scanning
/// its barcode gives now.**
///
/// Until 5 Oct 2026 a product Open Food Facts found had its per-100 g nutrition stored as one
/// serving's, so each of those foods was off by 100 ÷ its serving's grams (a 50 g egg at
/// 140 kcal, 100 g of potatoes at 368), every meal logged from one with it — and a package's
/// size could be taken for a serving (a 72 g pack of seaweed).
///
/// Each barcode food is looked up again and brought into line (`MyFoods.reconciled`), and the
/// meals and waiting estimates logged from it follow at the weight they were logged at, unless
/// their numbers were changed by hand. Because it compares with the source instead of
/// multiplying, it gives the same answer however often it runs and whatever state a food
/// arrives in — the first version multiplied wherever a synced revision field read "not yet",
/// and a device on an older build saved corrected foods back without that field. What has been
/// checked is remembered on this device only (`checkedKey`), by the numbers it was checked at: a
/// copy that arrives different is checked again.
@MainActor
enum ScannedNumbersRepair {
    private static let checkedKey = "scannedFoodsChecked.3"
    private static var running = false
    private static var again = false

    static func run(foods: MyFoodsStore, wellness: WellnessStore, inbox: MealInboxStore) {
        foods.afterCloudApply = { [weak foods, weak wellness, weak inbox] in
            guard let foods, let wellness, let inbox else { return }
            start(foods: foods, wellness: wellness, inbox: inbox)
        }
        start(foods: foods, wellness: wellness, inbox: inbox)
    }

    private static func start(foods: MyFoodsStore, wellness: WellnessStore, inbox: MealInboxStore) {
        guard !running else { again = true; return }
        running = true
        Task {
            repeat {
                again = false
                await check(foods: foods, wellness: wellness, inbox: inbox)
            } while again
            running = false
        }
    }

    private static func check(foods: MyFoodsStore, wellness: WellnessStore, inbox: MealInboxStore) async {
        var checked = Set(UserDefaults.standard.stringArray(forKey: checkedKey) ?? [])
        var changed: [(old: MyFood, new: MyFood)] = []
        let scanned = foods.foods.filter { $0.source == .barcode }
        for food in scanned {
            guard let barcode = food.barcode, !checked.contains(MyFoods.fingerprint(food)) else { continue }
            guard let outcome = try? await BarcodeProductLookup.lookup(barcode) else { continue }
            switch outcome {
            case .foundOnline(let product), .foundLocally(let product):
                if let fresh = MyFoods.food(product: product), let fixed = foods.reconcile(food.id, with: fresh) {
                    changed.append((food, fixed))
                    checked.insert(MyFoods.fingerprint(fixed))
                } else {
                    checked.insert(MyFoods.fingerprint(food))
                }
            case .notFound:
                checked.insert(MyFoods.fingerprint(food))   // nothing to check it against
            case .networkError, .rateLimited:
                break   // another time
            }
        }
        UserDefaults.standard.set(Array(checked).sorted(), forKey: checkedKey)
        guard !changed.isEmpty else { return }

        var meals = 0
        for meal in wellness.meals {
            guard let items = repaired(meal.items, with: changed) else { continue }
            wellness.updateMeal(id: meal.id, items: items, name: meal.name)
            meals += 1
        }
        var estimates = 0
        // Only what's waiting for review: editing a proposal puts it back there.
        for item in inbox.items where item.state == .proposed {
            guard let proposal = item.proposal, let items = repaired(proposal.items, with: changed) else { continue }
            inbox.editProposal(item.id, items: items, name: proposal.name)
            estimates += 1
        }
        let names = changed.map { "\($0.new.name) \(Int($0.old.per100g.calories.rounded()))\u{2192}\(Int($0.new.per100g.calories.rounded()))" }
        PlaybackDiagnostics.shared.log(
            "\u{1F9EE} scanned numbers",
            "brought into line with their source: \(names.joined(separator: "; ")) \u{2014} \(meals) meal(s), \(estimates) waiting")
    }

    /// A meal's items with any that came from a changed food put right; nil when none did.
    static func repaired(_ items: [MealItem], with pairs: [(old: MyFood, new: MyFood)]) -> [MealItem]? {
        var any = false
        let fixed = items.map { item -> MealItem in
            for pair in pairs {
                if let repaired = MyFoods.repaired(item, from: pair.old, to: pair.new) {
                    any = true
                    return repaired
                }
            }
            return item
        }
        return any ? fixed : nil
    }
}
