#if BANANA_AI
import Foundation

extension AssistantNutrition {
    @MainActor static func validateRequest(_ args: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: args)
        let decoded = try JSONDecoder().decode(AssistantNutritionSurface.self, from: data)
        var surface = try resolve(decoded, period: args["period"] as? String)
        if let relative = args["draftRelativeDay"] as? String {
            switch relative {
            case "today": surface.draftDate = key(Date())
            case "tomorrow": surface.draftDate = key(calendar().date(byAdding: .day, value: 1, to: Date())!)
            case "date": break // The explicit date is checked below.
            default: throw AssistantFailure(message: "Choose today, tomorrow, or an explicit date for the meal draft.")
            }
        }
        try validate(surface)
        if let raw = surface.draftMealID {
            guard let id = UUID(uuidString: raw), let rawDraft = surface.draftID, let draft = UUID(uuidString: rawDraft),
                  WellnessStore.shared.meals.contains(where: { $0.id == id }) else {
                throw AssistantFailure(message: "The meal for this draft no longer exists.")
            }
            surface.draftMealID = id.uuidString
            surface.draftID = draft.uuidString
        }
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(surface))
        let points = days(surface, meals: WellnessStore.shared.meals)
        let selectedMeals = points.filter { surface.selectedDay == nil || $0.id == surface.selectedDay }.flatMap(\.meals)
        let prior = points.compactMap(\.previous)
        let priorTotal: Any = prior.isEmpty ? NSNull() : prior.reduce(0, +) as Any
        let saved = surface.draftID.map { id in WellnessStore.shared.meals.contains(where: { $0.id.uuidString == id }) } ?? false
        let previews: [[String: String]] = selectedMeals.prefix(12).map { meal in
            let name = meal.name.isEmpty ? meal.items.map(\.name).joined(separator: ", ") : meal.name
            return ["id": meal.id.uuidString, "name": String(name.prefix(160)), "date": key(meal.date)]
        }
        let summary: [String: Any] = [
            "loggedDays": points.filter { $0.value != nil }.count, "visibleDays": points.count,
            "loggedTotal": points.compactMap(\.value).reduce(0, +), "unit": surface.metric.unit,
            "missingDaysAreNotZero": true,
            "fictionalSampleMealsInResults": selectedMeals.filter(PiSampleMeals.contains).count,
            "aggregation": surface.search.isEmpty ? "All logged meal totals" : "Whole meal totals, including other foods in meals matching the food-name search",
            "priorLoggedDays": prior.count,
            "priorLoggedTotal": priorTotal,
            "comparisonStatus": prior.isEmpty ? "No matching prior meals logged. Cannot establish equal or zero intake." : "Compare logged meals only; unlogged days are unknown.",
            "draftAlreadySaved": saved,
            "meals": previews, "hasMoreMeals": selectedMeals.count > 12,
        ]
        let result: [String: Any] = ["surface": object, "summary": summary]
        return String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self)
    }
}

#endif
