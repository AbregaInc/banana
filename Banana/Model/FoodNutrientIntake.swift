#if BANANA_MODULE_FOOD
import Foundation

/// Estimates from the logged food reference and portion, never invented nutrient values.
enum FoodNutrientIntake {
    struct Reference: Codable, Equatable, Sendable {
        var source: String
        var url: String
        var kind: String
        var adults19Plus: [String: Double]?
        var note: String
    }
    struct Definition: Codable, Equatable, Sendable {
        var id: String
        var key: String
        var name: String
        var unit: String
        var aliases: [String]
        var reference: Reference?
    }
    struct Catalog: Sendable { var definition: Definition; var values: [String: Double] }
    struct Day: Codable, Equatable, Sendable {
        var date: String
        /// Nil means no quantified food, not zero intake.
        var amount: Double?
        var quantifiedItems = 0
        var unknownItems = 0
    }
    struct Contributor: Codable, Equatable, Sendable {
        var food: String
        var referenceID: String
        var amount: Double
        var grams: Double
        var sourceURL: String
    }
    struct Missing: Codable, Equatable, Sendable { var food: String; var reason: String }
    struct Report: Codable, Equatable, Sendable {
        var nutrient: Definition
        var start: String
        var end: String
        var timeZone: String
        var estimateFromLoggedFoods: Double?
        var averagePerDayWithData: Double?
        var days: [Day]
        var loggedDays: Int
        var quantifiedItems: Int
        var unknownItems: Int
        var contributors: [Contributor]
        var missingExamples: [Missing]
        var moreContributors: Bool
        var basis = "USDA values per 100 g scaled by logged portion weights; estimates, not measured personal intake. Missing foods, weights and days are unknown, not zero. The average excludes days with no quantified food. Supplements and unlogged foods are not included."
        var source = "USDA FoodData Central"
        var sourceURL = "https://fdc.nal.usda.gov/download-datasets/"
        var fullDietCoverageKnown = false
        var sampleData = false
    }
    enum Failure: Error { case invalidRange, unavailableNutrient }

    static func normalized(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Called off the main actor. The supplied lookup batches IDs on one read-only connection.
    static func report(nutrient: String, start: Date, end: Date, meals: [MealEntry], calendar: Calendar = .current,
                       lookup: (String, Set<String>) -> Catalog? = { FoodDatabase.nutrientCatalog($0, foodIDs: $1) }) throws -> Report {
        let start = calendar.startOfDay(for: start), end = calendar.startOfDay(for: end)
        let count = calendar.dateComponents([.day], from: start, to: end).day ?? -1
        guard (0..<93).contains(count), let afterEnd = calendar.date(byAdding: .day, value: 1, to: end), nutrient.count <= 80 else { throw Failure.invalidRange }
        let selected = meals.filter { $0.date >= start && $0.date < afterEnd }
        let ids = Set(selected.flatMap(\.items).compactMap { $0.reference?.id })
        guard let catalog = lookup(nutrient, ids) else { throw Failure.unavailableNutrient }
        func key(_ date: Date) -> String {
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
        }
        var days = (0...count).map { Day(date: key(calendar.date(byAdding: .day, value: $0, to: start)!)) }
        var contributors: [String: Contributor] = [:], missing: [Missing] = []
        var logged = Set<Int>(), quantified = 0, unknown = 0
        for meal in selected {
            let day = calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: meal.date)).day!
            logged.insert(day)
            for item in meal.items {
                let id = item.reference?.id
                var grams = item.grams
                // An explicit mass can be recovered from older records without assuming a serving.
                if grams == nil, let quantity = FoodPhrase.quantity(item.serving), case .mass(let mass) = quantity.unit {
                    grams = quantity.amount * mass
                }
                let reason: String?
                if id == nil { reason = "No linked USDA food" }
                else if grams == nil || !grams!.isFinite || grams! < 0 { reason = "Portion weight missing" }
                else if catalog.values[id!] == nil { reason = "Nutrient measurement unavailable" }
                else { reason = nil }
                if let reason {
                    unknown += 1; days[day].unknownItems += 1
                    if missing.count < 12 { missing.append(Missing(food: String(item.name.prefix(160)), reason: reason)) }
                    continue
                }
                let amount = catalog.values[id!]! * grams! / 100
                guard amount.isFinite else { throw Failure.invalidRange }
                quantified += 1; days[day].quantifiedItems += 1
                days[day].amount = (days[day].amount ?? 0) + amount
                if var existing = contributors[id!] {
                    existing.amount += amount; existing.grams += grams!; contributors[id!] = existing
                } else {
                    let fdcID = id!.split(separator: ":").last.map(String.init) ?? ""
                    contributors[id!] = Contributor(food: String((item.reference?.name ?? item.name).prefix(160)), referenceID: id!, amount: amount, grams: grams!,
                        sourceURL: "https://fdc.nal.usda.gov/food-details/\(fdcID)/nutrients")
                }
            }
        }
        let measuredDays = days.compactMap(\.amount)
        let total = measuredDays.isEmpty ? nil : measuredDays.reduce(0, +)
        guard days.allSatisfy({ $0.amount?.isFinite != false }), total?.isFinite != false,
              contributors.values.allSatisfy({ $0.amount.isFinite && $0.grams.isFinite }) else { throw Failure.invalidRange }
        let ranked = contributors.values.sorted { $0.amount == $1.amount ? $0.referenceID < $1.referenceID : $0.amount > $1.amount }
        return Report(nutrient: catalog.definition, start: key(start), end: key(end), timeZone: calendar.timeZone.identifier, estimateFromLoggedFoods: total,
                      averagePerDayWithData: total.map { $0 / Double(measuredDays.count) }, days: days, loggedDays: logged.count,
                      quantifiedItems: quantified, unknownItems: unknown, contributors: Array(ranked.prefix(12)), missingExamples: missing,
                      moreContributors: ranked.count > 12)
    }
}
#endif
