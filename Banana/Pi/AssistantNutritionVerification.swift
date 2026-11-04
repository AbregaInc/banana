#if BANANA_AI
#if DEBUG
import Foundation

@MainActor enum AssistantNutritionVerification {
    static func run(_ assistant: AssistantStore) async {
        var report: [String: Any] = ["passed": false, "model": "apple-foundation/on-device", "bundle": Bundle.main.bundleIdentifier ?? "", "run": AssistantVerification.runIdentifier]
        var fixture: UUID?
        var copiedMeal: UUID?
        do {
            try AssistantVerification.requireIsolatedBuild()
            await WellnessStore.shared.whenLoaded()
            try await wait { assistant.available && assistant.selected != nil }
            report["model"] = assistant.modelIdentity
            let calendar = AssistantNutrition.calendar()
            var date = calendar.startOfDay(for: Date())
            while calendar.isDateInWeekend(date) { date = calendar.date(byAdding: .day, value: -1, to: date)! }
            let meal = MealEntry(date: date, items: [MealItem(name: "Pi verification yogurt", serving: "1 cup",
                macros: .init(calories: 150, proteinGrams: 20))], name: "Pi verification breakfast")
            fixture = meal.id
            WellnessStore.shared.addMeal(meal)
            await assistant.newConversation()
            let firstTiming = try await send("Show my protein this month", assistant)
            guard let first = assistant.surface, first.metric == .protein, first.search.isEmpty,
                  first.start == AssistantNutrition.key(calendar.date(from: calendar.dateComponents([.year, .month], from: Date()))!) else {
                throw AssistantFailure(message: "The model did not open the requested monthly protein chart")
            }
            report["naturalChartQuery"] = true
            report["firstQueryTiming"] = firstTiming
            try await send("Only weekdays", assistant)
            guard assistant.surface?.weekdaysOnly == true else { throw AssistantFailure(message: "The weekday follow-up did not update the view") }
            report["languageFilter"] = true
            try await send("Compare with the previous period", assistant)
            guard assistant.surface?.compare == true else { throw AssistantFailure(message: "The comparison follow-up did not update the view") }
            report["languageComparison"] = true
            let touchStarted = Date()
            await assistant.updateSurface(["selectedDay": AssistantNutrition.key(date)])
            report["nativeSelectionMilliseconds"] = Int(Date().timeIntervalSince(touchStarted) * 1000)
            guard assistant.surface?.selectedDay == AssistantNutrition.key(date) else { throw AssistantFailure(message: assistant.error ?? "Native day selection failed") }
            report["nativeSelection"] = true
            try await send("Prepare a copy of the Pi verification breakfast on the selected day for tomorrow. Do not save it yet.", assistant)
            let tomorrow = AssistantNutrition.key(calendar.date(byAdding: .day, value: 1, to: Date())!)
            guard assistant.surface?.draftMealID == meal.id.uuidString, assistant.surface?.draftDate == tomorrow,
                  WellnessStore.shared.meals.filter({ $0.id == meal.id }).count == 1 else {
                throw AssistantFailure(message: "The model did not prepare the selected meal draft without saving")
            }
            report["contextualMealDraft"] = true
            let state = assistant.surface
            try await assistant.verifyColdReopen()
            guard assistant.surface == state else { throw AssistantFailure(message: "Cold reopen lost the native surface") }
            report["surfaceRestored"] = true
            let points = AssistantNutrition.days(state!, meals: WellnessStore.shared.meals)
            guard points.contains(where: { $0.meals.contains(where: { $0.id == meal.id }) && ($0.value ?? 0) >= 20 }) else {
                throw AssistantFailure(message: "The chart did not use the actual logged meal")
            }
            report["nativeDataGrounding"] = true
            report["surface"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state))
            guard let draftID = state?.draftID, let operation = UUID(uuidString: draftID) else {
                throw AssistantFailure(message: "The meal draft has no durable save identity")
            }
            copiedMeal = operation
            let copy = MealEntry(id: operation, date: try AssistantNutrition.date(tomorrow), items: meal.items, source: .manual, name: meal.name)
            try WellnessStore.shared.addAssistantMeal(copy)
            try WellnessStore.shared.addAssistantMeal(copy)
            let stored = try JSONDecoder().decode(WellnessSnapshot.self, from: Data(contentsOf: AppSupport.directory.appendingPathComponent("wellness.json")))
            guard stored.meals.filter({ $0.id == operation }).count == 1,
                  WellnessStore.shared.meals.filter({ $0.id == operation }).count == 1 else {
                throw AssistantFailure(message: "The meal save was not persisted exactly once for its draft ID")
            }
            var different = copy; different.items[0].macros.proteinGrams += 1
            var conflictRejected = false
            do { try WellnessStore.shared.addAssistantMeal(different) } catch { conflictRejected = true }
            guard conflictRejected else { throw AssistantFailure(message: "A reused draft ID accepted different meal contents") }
            report["nativeMealSavePersisted"] = true
            report["nativeMealSaveDeduplicated"] = true
            report["conflictingMealRetryRejected"] = true
            try await send("Find my logged meals containing Pi verification yogurt.", assistant)
            guard let searched = assistant.surface, searched.search.localizedCaseInsensitiveContains("yogurt"),
                  AssistantNutrition.days(searched, meals: WellnessStore.shared.meals).flatMap(\.meals).contains(where: { $0.id == meal.id }) else {
                throw AssistantFailure(message: "The natural-language food search did not find the logged meal")
            }
            report["naturalMealSearch"] = true
            await assistant.newConversation()
            guard assistant.surface == nil else { throw AssistantFailure(message: "New conversation inherited a prior view") }
            report["conversationIsolation"] = true
            report["passed"] = true
        } catch {
            report["error"] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            report["messages"] = assistant.messages.map { ["role": $0.role, "text": $0.text] }
            if let surface = assistant.surface {
                report["failedSurface"] = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(surface))
            }
        }
        await assistant.stop()
        if let fixture { WellnessStore.shared.deleteMeal(fixture) }
        if let copiedMeal { WellnessStore.shared.deleteMeal(copiedMeal) }
        do {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: AssistantVerification.reportURL("pi-app-integration.json"), options: .atomic)
        } catch { print("Could not write nutrition verification: \(error)") }
        print("PI_NUTRITION_VERIFICATION \(report["passed"] ?? false)"); fflush(stdout)
        AssistantVerification.finishHeadless(passed: report["passed"] as? Bool == true)
    }

    @discardableResult private static func send(_ text: String, _ assistant: AssistantStore) async throws -> [String: Int] {
        let started = Date()
        let revision = assistant.surface?.revision
        let workspaceRevision = assistant.workspace?.revision
        var visible: Date?
        let count = assistant.messages.filter { $0.role == "assistant" }.count
        let errors = assistant.messages.filter { $0.role == "error" }.count
        guard await assistant.send(text) else { throw AssistantFailure(message: assistant.error ?? "Input was not accepted") }
        try await wait {
            if visible == nil, let surface = assistant.surface, surface.revision != revision { visible = Date() }
            return !assistant.busy && (assistant.workspace?.revision != workspaceRevision || assistant.surface?.revision != revision || assistant.messages.filter { $0.role == "assistant" }.count > count || assistant.messages.filter { $0.role == "error" }.count > errors)
        }
        if assistant.messages.filter({ $0.role == "error" }).count > errors, let error = assistant.messages.last(where: { $0.role == "error" }) {
            throw AssistantFailure(message: error.text)
        }
        if let error = assistant.error { throw AssistantFailure(message: error) }
        if assistant.workspace?.action != nil, assistant.workspace?.revision != workspaceRevision {
            throw AssistantFailure(message: "Expected a nutrition update; received \(assistant.workspace?.action?.kind.rawValue ?? "another") workspace")
        }
        var timing = ["fullTurnMilliseconds": Int(Date().timeIntervalSince(started) * 1000)]
        if let visible { timing["viewMilliseconds"] = Int(visible.timeIntervalSince(started) * 1000) }
        return timing
    }
    private static func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(75)
        while !condition() {
            guard Date() < deadline else { throw AssistantFailure(message: "Timed out waiting for the nutrition view") }
            try await Task.sleep(for: .milliseconds(75))
        }
    }
}
#endif

#endif
