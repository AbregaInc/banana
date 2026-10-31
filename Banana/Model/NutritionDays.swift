import Foundation

/// Which days the Mac's Nutrition page shows and what each one adds up to. Pure, for tests.
enum NutritionDays {
    /// Seven days, oldest first, around `day`: the last week up to today while `day` is in it,
    /// else the week ending on `day`. Never a calendar week — on a Sunday that was today and six
    /// empty days still to come.
    static func window(for day: Date, today: Date = Date(), calendar: Calendar = .current) -> [Date] {
        let today = calendar.startOfDay(for: today)
        let day = min(calendar.startOfDay(for: day), today)
        let recent = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        let end = day >= recent ? today : day
        return (0..<7).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: end) }
    }

    /// "Today", "Yesterday", or "Thursday, September 25".
    static func title(for day: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(day, inSameDayAs: yesterday) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }

    /// The day `by` days from `day`, never past today.
    static func step(_ day: Date, by days: Int, now: Date = Date(), calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        guard let next = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: day)) else { return today }
        return min(next, today)
    }

    static func meals(_ meals: [MealEntry], on day: Date, calendar: Calendar = .current) -> [MealEntry] {
        meals.filter { calendar.isDate($0.date, inSameDayAs: day) }.sorted { $0.date < $1.date }
    }

    static func total(_ meals: [MealEntry]) -> NutritionMacros {
        meals.reduce(.init()) { $0 + $1.totals }
    }

    /// When a dose marked on `day` counts as taken: now, for today; the scheduled time, for a
    /// day already past (ticking off yesterday's vitamin D at 11 pm shouldn't file it at 11 pm).
    static func doseDate(for supplement: SupplementSchedule, on day: Date, now: Date = Date(),
                         calendar: Calendar = .current) -> Date {
        if calendar.isDate(day, inSameDayAs: now) { return now }
        return calendar.date(bySettingHour: supplement.safeHour, minute: supplement.safeMinute, second: 0, of: day)
            ?? calendar.startOfDay(for: day)
    }
}


/// Reuse checked portions without treating yesterday's photo or estimate as today's evidence.
enum RecentMeals {
    private static let blankID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    static func title(_ meal: MealEntry) -> String {
        let name = meal.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? meal.items.map(\.name).joined(separator: ", ") : name
    }

    static func choices(in meals: [MealEntry], query: String, hiddenIDs: Set<String> = []) -> [MealEntry] {
        let words = folded(query).split(whereSeparator: \.isWhitespace)
        var seen = Set<MealEntry>()
        var choices: [MealEntry] = []
        guard !Task.isCancelled else { return [] }
        for meal in meals.sorted(by: { $0.date != $1.date ? $0.date > $1.date : $0.id.uuidString < $1.id.uuidString }) {
            guard !Task.isCancelled else { return [] }
            guard !meal.items.isEmpty, !hiddenIDs.contains(meal.id.uuidString) else { continue }
            if !words.isEmpty {
                let text = folded(([meal.name] + meal.items.flatMap { [$0.name, $0.serving] }).joined(separator: " "))
                guard words.allSatisfy({ text.contains($0) }) else { continue }
            }
            var key = MealEntry(id: blankID, date: Date(timeIntervalSince1970: 0), items: meal.items, name: meal.name)
            key.items = key.items.map { var item = $0; item.id = blankID; return item }
            if seen.insert(key).inserted { choices.append(meal) }
        }
        return choices
    }

    static func entry(from meal: MealEntry, at date: Date) -> MealEntry {
        MealEntry(date: date, items: meal.items.map { item in
            var copy = item; copy.id = UUID(); return copy
        }, source: .manual, name: meal.name)
    }

    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
