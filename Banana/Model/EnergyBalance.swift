import Foundation

/// Your logs against your weight (MEAL-LEARNING.md §6): what four weeks of weigh-ins and the
/// Watch's energy say you ate, next to what you logged on the days you logged fully.
///
/// The idea is MacroFactor's, turned round. MacroFactor trusts the logs and works out from the
/// weight trend what you burn; here the Watch already says what you burn, so the weight trend
/// says how complete the logs are. Weight that holds steady while the Watch counts 2,400 a day
/// means about 2,400 a day was eaten, whatever the log says.
///
/// A report only: nothing here changes a meal or an estimate, and nothing it says is a nudge to
/// eat more or less — only how much of what you eat the logs catch. Pure, fed from
/// `HealthTrends` (which the phone syncs to the Mac and iPad) and the meal log, so every device
/// says the same thing.
struct EnergyBalance: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        /// Not enough yet; `headline` says what's missing ("Needs 3 weeks of weigh-ins — 9 days so far").
        case gathering
        /// Enough, and the numbers are plausible together: `coverage` is the answer.
        case measured
        /// Enough, but the numbers can't all be right — most often the Watch missed some of what
        /// was burned. No percentage then: it would be a precise-looking wrong number.
        case doesNotAddUp
    }

    var status: Status
    var headline: String
    /// How the answer was reached ("Over 4 weeks: about 2,450 kcal a day burned…"); nil while gathering.
    var detail: String?

    /// Days in the window with a weigh-in, and how many days they stretch over, first to last.
    var weighIns: Int
    var weighInSpanDays: Int
    var fullyLoggedDays: Int
    /// Days with both active and resting energy.
    var energyDays: Int

    /// Active plus resting energy, per day. Nil while gathering, as are the rest.
    var burnedPerDay: Double?
    /// The weight trend, kg a day; negative is losing.
    var weightChangePerDay: Double?
    /// What the weight says was eaten: burned + change × 7,700 kcal/kg.
    var impliedIntakePerDay: Double?
    /// Mean calories logged on fully logged days.
    var loggedPerDay: Double?
    /// `loggedPerDay` ÷ `impliedIntakePerDay`.
    var coverage: Double?
}

extension EnergyBalance {
    /// Four weeks ending yesterday: today isn't finished, so its meals and energy are partial.
    static let windowDays = 28
    /// A trend needs weigh-ins three weeks apart, and enough of them that a few water-weight
    /// days are a minority.
    static let minWeighInSpanDays = 21
    static let minWeighIns = 8
    static let minFullyLoggedDays = 10
    /// "Most days": three in four.
    static let minEnergyDays = 21
    /// Energy in a kilogram of body weight — the usual figure for mixed fat and lean tissue.
    static let kcalPerKg = 7_700.0
    /// A logged day is fully logged at this share of the median logged day (`fullyLogged`).
    static let fullyLoggedShare = 0.7
    /// Nobody eats less than this a day for four weeks; a weight trend that says so is wrong.
    static let minPlausibleIntake = 1_000.0
    /// Coverage outside this is more likely a measuring problem than a logging one.
    static let plausibleCoverage = 0.4...1.6

    /// Nil when there's nothing to say at all — no weigh-ins, no logged meals, or no Watch energy
    /// in the last four weeks. Someone who doesn't weigh themselves, or doesn't log, isn't told
    /// what they'd need to start.
    static func compute(meals: [MealEntry], weightKg: [MetricPoint], activeKcal: [MetricPoint],
                        restingKcal: [MetricPoint], now: Date = Date(), calendar: Calendar = .current,
                        imperial: Bool = MetricKind.imperial, locale: Locale = .current) -> EnergyBalance? {
        let today = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: -windowDays, to: today) else { return nil }
        /// The day of the window a date falls on, 0 being four weeks ago; nil outside it.
        func day(_ date: Date) -> Int? {
            guard let d = calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: date)).day,
                  (0..<windowDays).contains(d) else { return nil }
            return d
        }
        /// Health's series are one value a day; a second for the same day is added in, as the
        /// day's total would be.
        func daily(_ points: [MetricPoint]) -> [Int: Double] {
            var totals: [Int: Double] = [:]
            for point in points { if let d = day(point.date) { totals[d, default: 0] += point.value } }
            return totals
        }

        // A day's weight is the mean of its readings.
        var readings: [Int: [Double]] = [:]
        for point in weightKg where point.value > 0 {
            if let d = day(point.date) { readings[d, default: []].append(point.value) }
        }
        let weights = readings.mapValues { $0.reduce(0, +) / Double($0.count) }

        // Burned only where both halves are there: a day with active energy but no resting is
        // usually one the Watch spent off the wrist (the phone counts steps, not rest), and
        // counting it would say next to nothing was burned. In day order throughout, so the same
        // month always sums to the same last digit.
        let active = daily(activeKcal), resting = daily(restingKcal)
        let burned = active.keys.sorted().compactMap { d in resting[d].map { active[d]! + $0 } }

        var logged: [Int: Double] = [:]
        for meal in meals { if let d = day(meal.date) { logged[d, default: 0] += meal.totals.calories } }
        let loggedDays = logged.keys.sorted().compactMap { logged[$0] }.filter { $0 > 0 }
        let full = fullyLogged(loggedDays)

        guard let first = weights.keys.min(), let last = weights.keys.max(),
              !loggedDays.isEmpty, !burned.isEmpty else { return nil }

        var balance = EnergyBalance(status: .gathering, headline: "", weighIns: weights.count,
                                    weighInSpanDays: last - first + 1, fullyLoggedDays: full.count,
                                    energyDays: burned.count)
        if let line = progressLine(balance) {
            balance.headline = line
            return balance
        }

        let slope = theilSenSlope(weights.keys.sorted().map { (x: Double($0), y: weights[$0]!) })
        let burnedPerDay = mean(burned)
        let implied = burnedPerDay + slope * kcalPerKg
        let loggedPerDay = mean(full)
        let coverage = implied > 0 ? loggedPerDay / implied : nil
        balance.burnedPerDay = burnedPerDay
        balance.weightChangePerDay = slope
        balance.impliedIntakePerDay = implied
        balance.loggedPerDay = loggedPerDay
        balance.coverage = coverage

        if implied >= minPlausibleIntake, let coverage, plausibleCoverage.contains(coverage) {
            balance.status = .measured
            balance.headline = headline(coverage: coverage)
            balance.detail = detail(burned: burnedPerDay, weightChangePerDay: slope, implied: implied,
                                    logged: loggedPerDay, imperial: imperial, locale: locale)
        } else {
            balance.status = .doesNotAddUp
            balance.headline = "Your logs and your weight don\u{2019}t add up"
            // Too little implied means energy went uncounted — the Watch off the wrist, or a
            // device that doesn't write resting energy. Too much means the logs are far short,
            // or a run of water weight is steering the trend; neither is the Watch's fault.
            let logsFarShort = implied >= minPlausibleIntake && (coverage ?? 0) < plausibleCoverage.lowerBound
            balance.detail = logsFarShort
                ? "Your logs come to far less than your weight says you eat \u{2014} days only partly logged, or a swing in water weight, can do this."
                : "Your weight says you eat less than seems likely \u{2014} most often because the Watch missed some of what you burned."
        }
        return balance
    }

    // MARK: - Pieces

    /// The days logged fully, by calories: at least 70% of the median day with anything logged.
    ///
    /// MacroFactor leaves partly logged days out, and so does this: a day where only breakfast
    /// went in would drag the average down and say the logs miss more than they do on the days
    /// you meant to log everything. The rule is calories rather than a count of meals because a
    /// count measures habits, not completeness — two meals is a whole day for some people and
    /// would never count, while breakfast, lunch and a snack with dinner forgotten would. Measured
    /// against your own median, a day well short of your usual is the forgotten dinner it looks
    /// like, however you eat. If most days are partial the median is too and every day passes;
    /// the coverage then comes out low, which is the true answer. The cost: a genuinely light
    /// day (ill, fasting) is left out with the forgotten ones, nudging coverage up a little.
    static func fullyLogged(_ days: [Double]) -> [Double] {
        guard let median = median(days) else { return [] }
        return days.filter { $0 >= median * fullyLoggedShare }
    }

    /// The median of the slopes between every pair of weigh-ins (Theil–Sen). A few days of water
    /// weight — a salty dinner, a long run, a flight — tilt a least-squares line, but they're a
    /// minority of the pairs, so they barely move the median. Units of y per unit of x.
    static func theilSenSlope(_ points: [(x: Double, y: Double)]) -> Double {
        var slopes: [Double] = []
        for i in points.indices {
            for j in points.indices where j > i && points[j].x != points[i].x {
                slopes.append((points[j].y - points[i].y) / (points[j].x - points[i].x))
            }
        }
        return median(slopes) ?? 0
    }

    /// What's still missing, the slowest first: weigh-ins take calendar time whatever you do.
    static func progressLine(_ balance: EnergyBalance) -> String? {
        if balance.weighInSpanDays < minWeighInSpanDays {
            let days = balance.weighInSpanDays == 1 ? "1 day" : "\(balance.weighInSpanDays) days"
            return "Needs \(minWeighInSpanDays / 7) weeks of weigh-ins \u{2014} \(days) so far"
        }
        if balance.weighIns < minWeighIns {
            return "Needs \(minWeighIns) weigh-ins in \(windowDays / 7) weeks \u{2014} \(balance.weighIns) so far"
        }
        if balance.fullyLoggedDays < minFullyLoggedDays {
            return "Needs \(minFullyLoggedDays) fully logged days \u{2014} \(balance.fullyLoggedDays) so far"
        }
        if balance.energyDays < minEnergyDays {
            return "Needs the Watch\u{2019}s energy on most days \u{2014} \(balance.energyDays) of the last \(windowDays) so far"
        }
        return nil
    }

    /// "Your logs cover about 85% of what your weight says you eat", to the nearest 5% — a finer
    /// number would claim more than four weeks of weigh-ins can tell. Over 100% the logs either
    /// run high or the Watch counts less than was burned; from here the two look the same.
    static func headline(coverage: Double) -> String {
        let percent = Int((coverage * 20).rounded()) * 5
        if percent == 100 { return "Your logs match what your weight says you eat" }
        if percent > 100 {
            return "Your logs come to about \(percent)% of what your weight says you eat \u{2014} they run high, or the Watch undercounts"
        }
        return "Your logs cover about \(percent)% of what your weight says you eat"
    }

    /// "Over 4 weeks: about 2,450 kcal a day burned, weight down 0.3 kg a week — so about 2,120
    /// eaten; you logged 1,800 on fully logged days." Calories to the nearest 10, weight to a
    /// tenth a week in the units Settings shows.
    static func detail(burned: Double, weightChangePerDay: Double, implied: Double, logged: Double,
                       imperial: Bool, locale: Locale) -> String {
        func kcal(_ value: Double) -> String {
            (Int((value / 10).rounded()) * 10).formatted(.number.locale(locale))
        }
        let perWeek = weightChangePerDay * 7 * (imperial ? 2.204_622_6 : 1)
        let tenths = (perWeek * 10).rounded() / 10
        let weight: String
        if tenths == 0 {
            weight = "weight steady"
        } else {
            let amount = abs(tenths).formatted(.number.precision(.fractionLength(1)).locale(locale))
            weight = "weight \(tenths < 0 ? "down" : "up") \(amount) \(imperial ? "lb" : "kg") a week"
        }
        return "Over \(windowDays / 7) weeks: about \(kcal(burned)) kcal a day burned, \(weight) \u{2014} "
            + "so about \(kcal(implied)) eaten; you logged \(kcal(logged)) on fully logged days."
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted(), mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    private static func mean(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }
}

#if DEBUG
extension EnergyBalance {
    /// `--energy-balance [measured|over|off|gathering]`: four weeks of meals, weigh-ins and Watch
    /// energy, so the card can be looked at in each state on the Nutrition pages. The weight
    /// wobbles by water as a real scale's does, a few days are only partly logged and a few not
    /// at all, so the fixture exercises the same rules a real month does.
    enum Preview: String, CaseIterable, Sendable {
        /// About 85%: down 0.3 kg a week on about 2,450 burned.
        case measured
        /// Logs above what the weight says.
        case over
        /// The Watch off the wrist most of each day: too little burned to add up.
        case off
        /// Nine days of weigh-ins.
        case gathering

        static func requested(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> Preview? {
            guard let i = arguments.firstIndex(of: "--energy-balance") else { return nil }
            if i + 1 < arguments.count, let named = Preview(rawValue: arguments[i + 1]) { return named }
            return .measured
        }

        struct Sample {
            var meals: [MealEntry]
            var weightKg: [MetricPoint]
            var activeKcal: [MetricPoint]
            var restingKcal: [MetricPoint]
        }

        func sample(now: Date = Date(), calendar: Calendar = .current) -> Sample {
            let today = calendar.startOfDay(for: now)
            func date(_ daysAgo: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
                let day = calendar.date(byAdding: .day, value: -daysAgo, to: today) ?? today
                return calendar.date(byAdding: .minute, value: hour * 60 + minute, to: day) ?? day
            }
            func noise(_ d: Double) -> Double { sin(d * 12.9898) * 0.5 + sin(d * 4.1414) * 0.5 }
            func item(_ name: String, _ serving: String, _ kcal: Double) -> MealItem {
                // A plain 25 / 45 / 30 split, so the macro tiles have something to show.
                MealItem(name: name, serving: serving,
                         macros: .init(calories: kcal, proteinGrams: kcal * 0.25 / 4,
                                       carbohydrateGrams: kcal * 0.45 / 4, fatGrams: kcal * 0.30 / 9),
                         confidence: 0.9)
            }
            let scale = self == .over ? 1.36 : 1
            let breakfasts = [("Oatmeal with banana", "1 bowl", 390.0), ("Eggs and toast", "2 eggs", 430.0),
                              ("Greek yogurt and granola", "1 cup", 370.0)]
            let lunches = [("Chicken grain bowl", "1 bowl", 640.0), ("Turkey sandwich", "1", 580.0),
                           ("Salmon salad", "1 plate", 610.0)]
            let dinners = [("Pasta with pesto", "1 plate", 810.0), ("Steak and potatoes", "1 plate", 850.0),
                           ("Tofu stir-fry", "1 bowl", 745.0)]

            var meals: [MealEntry] = []
            var weight: [MetricPoint] = [], active: [MetricPoint] = [], resting: [MetricPoint] = []
            for daysAgo in 1...EnergyBalance.windowDays {
                let d = Double(daysAgo)
                // Losing 0.3 kg a week, so further back is heavier, with up to ±0.35 kg of water.
                // No weigh-in on about one day in five; while gathering, only the last nine.
                let weighs = self == .gathering ? daysAgo <= 9 : daysAgo % 5 != 2
                if weighs {
                    weight.append(MetricPoint(date: date(daysAgo), value: 80.6 + d * 0.3 / 7 + 0.35 * noise(d)))
                }
                if self == .off {
                    // Worn for a few hours a day: a fraction of what was burned.
                    active.append(MetricPoint(date: date(daysAgo), value: 180 + 40 * noise(d + 3)))
                    resting.append(MetricPoint(date: date(daysAgo), value: 760 + 60 * noise(d + 7)))
                } else {
                    active.append(MetricPoint(date: date(daysAgo), value: 640 + 110 * noise(d + 3)))
                    resting.append(MetricPoint(date: date(daysAgo), value: 1_810 + 20 * noise(d + 7)))
                }
                // Three days with nothing logged, three with only breakfast.
                if [8, 16, 23].contains(daysAgo) { continue }
                let partial = [4, 11, 19].contains(daysAgo)
                let menu = daysAgo % 3
                let slot = daysAgo * 10
                func meal(_ offset: Int, _ hour: Int, _ minute: Int, _ food: (String, String, Double)) -> MealEntry {
                    MealEntry(id: Self.id(slot + offset), date: date(daysAgo, hour, minute),
                              items: [item(food.0, food.1, (food.2 * scale).rounded())], source: .text)
                }
                meals.append(meal(1, 8, 0, breakfasts[menu]))
                if partial { continue }
                meals.append(meal(2, 12, 45, lunches[(menu + 1) % 3]))
                meals.append(meal(3, 19, 15, dinners[(menu + 2) % 3]))
            }
            return Sample(meals: meals, weightKg: weight, activeKcal: active, restingKcal: resting)
        }

        /// Stable, so a relaunch's fixture replaces the last one's instead of adding to it.
        private static func id(_ slot: Int) -> UUID {
            UUID(uuidString: String(format: "EB000000-0000-4000-8000-%012d", slot))!
        }
    }
}
#endif
