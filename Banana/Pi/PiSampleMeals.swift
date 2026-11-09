#if BANANA_MODULE_FOOD
import Foundation

/// Fictional, deterministic meals. Reserved IDs and a marker make removal precise.
enum PiSampleMeals {
    static let marker = "Banana Pi sample meals v1 — fictional test data"
    private static let prefix = "BA5A4E11-0000-4000-8000-"

    static func contains(_ meal: MealEntry) -> Bool {
        meal.id.uuidString.hasPrefix(prefix) && meal.note == marker
    }

    static func make(now: Date = Date(), calendar: Calendar = AssistantNutrition.calendar()) -> [MealEntry] {
        let today = calendar.startOfDay(for: now)
        return (0..<90).flatMap { offset -> [MealEntry] in
            // Deliberately incomplete logs, including a recent gap.
            guard offset % 13 != 4, let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return [] }
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            let day = parts.year! * 10_000 + parts.month! * 100 + parts.day!
            let variation = Double(day % 7) * 0.025
            let menus: [(String, String, Double, Double, Double, Double)] = [
                ("Greek yogurt breakfast", "Greek yogurt, berries and oats", 390, 28, 46, 10),
                ("Chicken grain bowl", "Chicken, brown rice and vegetables", 650, 46, 72, 20),
                ("Salmon dinner", "Salmon, potatoes and green beans", 710, 43, 58, 30),
                ("Eggs and toast breakfast", "Eggs and wholegrain toast", 430, 25, 34, 21),
                ("Chickpea lunch", "Chickpeas, quinoa and vegetables", 590, 23, 80, 19),
                ("Tofu stir-fry dinner", "Tofu, noodles and vegetables", 620, 32, 71, 23),
            ]
            return (0..<3).map { slot in
                let menu = menus[(day % 2) * 3 + slot]
                let factor = 1 + variation
                let id = UUID(uuidString: prefix + String(format: "%012d", day * 10 + slot))!
                let time = calendar.date(bySettingHour: [8, 13, 19][slot], minute: 0, second: 0, of: date)!
                let itemID = UUID(uuidString: "BA5A4E12-0000-4000-8000-" + String(format: "%012d", day * 10 + slot))!
                let item = MealItem(id: itemID, name: menu.1, serving: "1 sample serving",
                    macros: .init(calories: menu.2 * factor, proteinGrams: menu.3 * factor,
                                  carbohydrateGrams: menu.4 * factor, fatGrams: menu.5 * factor))
                return MealEntry(id: id, date: time, items: [item], note: marker, source: .manual, name: "Sample · " + menu.0)
            }
        }
    }

    static func adding(to meals: [MealEntry], now: Date = Date(), calendar: Calendar = AssistantNutrition.calendar()) -> [MealEntry] {
        let ids = Set(meals.map(\.id))
        return (meals + make(now: now, calendar: calendar).filter { !ids.contains($0.id) }).sorted { $0.date > $1.date }
    }

    static func removing(from meals: [MealEntry]) -> [MealEntry] { meals.filter { !contains($0) } }
}

#if PI_DEVELOPMENT
@MainActor enum PiSampleData {
    /// Absolute instants plus source zones: never reinterpret arrival as device-local time.
    static func flights(now: Date = Date()) -> [MeetingInfo] {
        var origin = Calendar(identifier: .gregorian)
        origin.timeZone = TimeZone(identifier: "America/New_York")!
        let day = origin.date(byAdding: .day, value: 3, to: now)!
        let outbound = origin.date(bySettingHour: 20, minute: 0, second: 0, of: day)!
        var destination = origin
        destination.timeZone = TimeZone(identifier: "Europe/London")!
        let returnDay = destination.date(byAdding: .day, value: 3, to: outbound)!
        let inbound = destination.date(bySettingHour: 10, minute: 0, second: 0, of: returnDay)!
        return [
            MeetingInfo(start: outbound, end: outbound.addingTimeInterval(7 * 3600), isVirtual: false,
                title: "Sample flight · JFK → LHR", eventID: "sample-flight-outbound",
                startTimeZone: origin.timeZone.identifier, endTimeZone: destination.timeZone.identifier),
            MeetingInfo(start: inbound, end: inbound.addingTimeInterval(8 * 3600), isVirtual: false,
                title: "Sample flight · LHR → JFK", eventID: "sample-flight-return",
                startTimeZone: destination.timeZone.identifier, endTimeZone: origin.timeZone.identifier)
        ]
    }

    private static var initialized: String {
        if AppSupport.isPiVerification { return "assistant.verification.sampleData.initialized.v1" }
        if AppSupport.isPiUITest { return "assistant.test.sampleData.initialized.v1" }
        return "assistant.sampleData.initialized.v1"
    }

    static func setLoaded(_ loaded: Bool) async throws {
        await WellnessStore.shared.whenLoaded()
        try WellnessStore.shared.setPiSampleMeals(loaded: loaded)
        UserDefaults.standard.set(true, forKey: initialized)
    }
}
#endif
#endif
