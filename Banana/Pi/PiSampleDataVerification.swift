#if DEBUG && PI_DEVELOPMENT
import Foundation

@MainActor enum PiSampleDataVerification {
    static func run(_ assistant: AssistantStore) async {
        var report: [String: Any] = ["passed": false, "run": AssistantVerification.runIdentifier]
        let store = WellnessStore.shared
        var owned: [UUID] = []
        do {
            await store.whenLoaded()
            try await PiSampleData.setLoaded(false)
            let baseline = store.meals
            let real = MealEntry(items: [MealItem(name: "Sample test personal food", serving: "1", macros: .init(proteinGrams: 10))], name: "Personal test meal")
            owned.append(real.id); try store.addAssistantMeal(real)
            try await PiSampleData.setLoaded(true)
            let count = store.meals.filter(PiSampleMeals.contains).count
            guard count == 249 else { throw AssistantFailure(message: "Expected 249 sample meals; found \(count)") }
            try await PiSampleData.setLoaded(true)
            guard store.meals.filter(PiSampleMeals.contains).count == count else { throw AssistantFailure(message: "Reload duplicated samples") }
            let source = store.meals.first(where: PiSampleMeals.contains)!
            let copy = MealEntry(items: source.items, name: source.name)
            owned.append(copy.id); try store.addAssistantMeal(copy)
            try await PiSampleData.setLoaded(false)
            guard !store.meals.contains(where: PiSampleMeals.contains),
                  (baseline + [real, copy]).allSatisfy({ store.meals.contains($0) }) else {
                throw AssistantFailure(message: "Removing samples changed a personal meal or saved copy")
            }
            let file = AppSupport.directory.appendingPathComponent("wellness.json")
            let persisted = try JSONDecoder().decode(WellnessSnapshot.self, from: Data(contentsOf: file))
            guard !persisted.meals.contains(where: PiSampleMeals.contains), persisted.meals.contains(real), persisted.meals.contains(copy) else {
                throw AssistantFailure(message: "Sample removal was not persisted correctly")
            }
            report["sampleMealCount"] = count
            report["reloadDeduplicated"] = true
            report["personalMealsAndSavedCopiesPreserved"] = true
            report["removalPersisted"] = true
            report["passed"] = true
        } catch { report["error"] = error.localizedDescription }
        for id in owned { store.deleteMeal(id) }
        do {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: AssistantVerification.reportURL("pi-app-integration.json"), options: .atomic)
        } catch { print("Cannot write sample-data result: \(error)") }
        AssistantVerification.finishHeadless(passed: report["passed"] as? Bool == true)
    }
}
#endif
