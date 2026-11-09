#if BANANA_MODULE_FOOD
import Foundation

/// Versioned native catalog entry. Pi persists the query, never model-invented chart values.
struct AssistantNutritionSurface: Codable, Equatable {
    var revision: Int
    var metric: Metric
    var start: String
    var end: String
    var weekdaysOnly: Bool
    var compare: Bool
    var search: String
    var selectedDay: String?
    var draftMealID: String?
    var draftDate: String?
    var draftID: String? = nil

    enum Metric: String, Codable, CaseIterable {
        case protein, calories, carbs, fat
        var title: String {
            switch self { case .protein: "Protein"; case .calories: "Calories"; case .carbs: "Carbohydrates"; case .fat: "Fat" }
        }
        var unit: String { self == .calories ? "kcal" : "g" }
        func value(_ macros: NutritionMacros) -> Double {
            switch self { case .protein: macros.proteinGrams; case .calories: macros.calories; case .carbs: macros.carbohydrateGrams; case .fat: macros.fatGrams }
        }
    }
}

enum AssistantNutrition {
    struct Day: Identifiable {
        var id: String
        var date: Date
        var value: Double?
        var previous: Double?
        var meals: [MealEntry]
    }

    static func calendar(_ zone: TimeZone = .current) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }
    static func key(_ date: Date, calendar: Calendar = calendar()) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
    static func date(_ text: String, calendar: Calendar = calendar()) throws -> Date {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, text.count == 10,
              let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              key(date, calendar: calendar) == text else {
            throw AssistantFailure(message: "Use a valid date in YYYY-MM-DD format.")
        }
        return date
    }

    static func resolve(_ value: AssistantNutritionSurface, period: String?, now: Date = Date(), calendar: Calendar = calendar()) throws -> AssistantNutritionSurface {
        guard let period else { return value }
        var value = value
        let today = calendar.startOfDay(for: now)
        let month = calendar.date(from: calendar.dateComponents([.year, .month], from: today))!
        let start: Date, end: Date
        switch period {
        case "this_month": start = month; end = today
        case "last_month":
            start = calendar.date(byAdding: .month, value: -1, to: month)!
            end = calendar.date(byAdding: .day, value: -1, to: month)!
        case "last_7_days": start = calendar.date(byAdding: .day, value: -6, to: today)!; end = today
        case "last_30_days": start = calendar.date(byAdding: .day, value: -29, to: today)!; end = today
        default: throw AssistantFailure(message: "That nutrition period is not supported.")
        }
        value.start = key(start, calendar: calendar); value.end = key(end, calendar: calendar)
        return value
    }

    /// Native validation is also applied to direct UI edits before Pi commits a descriptor.
    static func validate(_ value: AssistantNutritionSurface, calendar: Calendar = calendar()) throws {
        let start = try date(value.start, calendar: calendar)
        let end = try date(value.end, calendar: calendar)
        let days = calendar.dateComponents([.day], from: start, to: end).day ?? -1
        guard (0..<93).contains(days), value.search.count <= 120 else {
            throw AssistantFailure(message: "Choose a nutrition range of one to 93 days and a shorter search.")
        }
        if let selected = value.selectedDay {
            let day = try date(selected, calendar: calendar)
            guard day >= start, day <= end,
                  !value.weekdaysOnly || !calendar.isDateInWeekend(day) else {
                throw AssistantFailure(message: "Select a day in the visible chart.")
            }
        }
        if let id = value.draftMealID {
            guard UUID(uuidString: id) != nil, let day = value.draftDate else {
                throw AssistantFailure(message: "Choose a meal and date for the draft.")
            }
            _ = try date(day, calendar: calendar)
        }
    }

    static func days(_ surface: AssistantNutritionSurface, meals: [MealEntry], calendar: Calendar = calendar()) -> [Day] {
        guard let start = try? date(surface.start, calendar: calendar),
              let end = try? date(surface.end, calendar: calendar), start <= end else { return [] }
        let count = (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1
        guard (1...93).contains(count) else { return [] }
        let filtered = meals.filter { meal in
            surface.search.isEmpty || ([meal.name] + meal.items.map(\.name)).joined(separator: " ")
                .localizedStandardContains(surface.search)
        }
        let groups = Dictionary(grouping: filtered) { calendar.startOfDay(for: $0.date) }
        return (0..<count).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: start),
                  !surface.weekdaysOnly || !calendar.isDateInWeekend(day) else { return nil }
            let entries = (groups[day] ?? []).sorted { $0.date < $1.date }
            let earlier = calendar.date(byAdding: .day, value: -count, to: day)!
            let previous = surface.weekdaysOnly && calendar.isDateInWeekend(earlier) ? [] : groups[earlier] ?? []
            // An unlogged day is missing, not a measured zero intake.
            return Day(id: key(day, calendar: calendar), date: day,
                       value: entries.isEmpty ? nil : entries.reduce(0) { $0 + surface.metric.value($1.totals) },
                       previous: previous.isEmpty ? nil : previous.reduce(0) { $0 + surface.metric.value($1.totals) }, meals: entries)
        }
    }

}
#endif
