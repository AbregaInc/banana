import XCTest

/// Your logs against your weight: four weeks of weigh-ins and Watch energy say what was eaten,
/// and the logs on fully logged days are compared with it. A report only — these pin what it
/// says, and when it says nothing.
final class EnergyBalanceTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()
    private let locale = Locale(identifier: "en_US")

    /// Tuesday 29 September 2026, 3 pm.
    private var september29: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 29, hour: 15))!
    }

    private func date(_ daysAgo: Int, hour: Int = 0, now: Date) -> Date {
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now))!
        return calendar.date(byAdding: .hour, value: hour, to: day)!
    }

    private struct Month {
        var meals: [MealEntry] = []
        var weight: [MetricPoint] = []
        var active: [MetricPoint] = []
        var resting: [MetricPoint] = []
    }

    /// Four weeks ending yesterday, by days ago (1 = yesterday): a weigh-in on each of
    /// `weighDays`, energy on each of `energyDays`, and `logged(day)` kcal on each of
    /// `loggedDays` — in three meals unless `mealsPerDay` says otherwise.
    private func month(now: Date? = nil,
                       weighDays: [Int] = Array(1...28), weight: (Int) -> Double = { _ in 80 },
                       energyDays: [Int] = Array(1...28), active: Double = 600, resting: Double = 1_800,
                       loggedDays: [Int] = Array(1...28), mealsPerDay: (Int) -> Int = { _ in 3 },
                       logged: (Int) -> Double = { _ in 2_000 }) -> Month {
        let now = now ?? september29
        var m = Month()
        for d in weighDays { m.weight.append(MetricPoint(date: date(d, now: now), value: weight(d))) }
        for d in energyDays {
            m.active.append(MetricPoint(date: date(d, now: now), value: active))
            m.resting.append(MetricPoint(date: date(d, now: now), value: resting))
        }
        for d in loggedDays {
            let count = mealsPerDay(d)
            for i in 0..<count {
                m.meals.append(MealEntry(date: date(d, hour: 8 + i * 5, now: now),
                                         items: [MealItem(name: "Food", serving: "1",
                                                          macros: .init(calories: logged(d) / Double(count)))]))
            }
        }
        return m
    }

    private func balance(_ m: Month, now: Date? = nil, imperial: Bool = false) -> EnergyBalance? {
        EnergyBalance.compute(meals: m.meals, weightKg: m.weight, activeKcal: m.active, restingKcal: m.resting,
                              now: now ?? september29, calendar: calendar, imperial: imperial, locale: locale)
    }

    // MARK: - What the weight says

    /// Weight that holds still means what was eaten is what was burned.
    func testSteadyWeightMeansYouAteWhatYouBurned() throws {
        let b = try XCTUnwrap(balance(month(active: 600, resting: 1_800, logged: { _ in 2_040 })))
        XCTAssertEqual(b.status, .measured)
        XCTAssertEqual(b.burnedPerDay ?? 0, 2_400, accuracy: 0.01)
        XCTAssertEqual(b.weightChangePerDay ?? 1, 0, accuracy: 1e-9)
        XCTAssertEqual(b.impliedIntakePerDay ?? 0, 2_400, accuracy: 0.01)
        XCTAssertEqual(b.loggedPerDay ?? 0, 2_040, accuracy: 0.01)
        XCTAssertEqual(b.coverage ?? 0, 0.85, accuracy: 0.0001)
        XCTAssertEqual(b.headline, "Your logs cover about 85% of what your weight says you eat")
        XCTAssertEqual(b.detail, "Over 4 weeks: about 2,400 kcal a day burned, weight steady \u{2014} so about 2,400 eaten; you logged 2,040 on fully logged days.")
    }

    /// Down 0.3 kg a week is 330 kcal a day eaten under what was burned.
    func testLosingWeightMeansYouAteLessThanYouBurned() throws {
        let m = month(weight: { 80 + Double($0) * 0.3 / 7 }, active: 650, resting: 1_800, logged: { _ in 1_800 })
        let b = try XCTUnwrap(balance(m))
        XCTAssertEqual(b.status, .measured)
        XCTAssertEqual((b.weightChangePerDay ?? 0) * 7, -0.3, accuracy: 1e-9)
        XCTAssertEqual(b.impliedIntakePerDay ?? 0, 2_120, accuracy: 0.01)
        XCTAssertEqual(b.headline, "Your logs cover about 85% of what your weight says you eat")
        XCTAssertEqual(b.detail, "Over 4 weeks: about 2,450 kcal a day burned, weight down 0.3 kg a week \u{2014} so about 2,120 eaten; you logged 1,800 on fully logged days.")
    }

    /// Up 0.2 kg a week is 220 kcal a day over; in pounds when Settings says imperial.
    func testGainingWeightMeansYouAteMoreThanYouBurned() throws {
        let m = month(weight: { 80 - Double($0) * 0.2 / 7 }, active: 700, resting: 1_800, logged: { _ in 2_600 })
        let b = try XCTUnwrap(balance(m))
        XCTAssertEqual(b.status, .measured)
        XCTAssertEqual(b.impliedIntakePerDay ?? 0, 2_720, accuracy: 0.01)
        XCTAssertEqual(b.headline, "Your logs cover about 95% of what your weight says you eat")
        XCTAssertEqual(b.detail, "Over 4 weeks: about 2,500 kcal a day burned, weight up 0.2 kg a week \u{2014} so about 2,720 eaten; you logged 2,600 on fully logged days.")
        let imperial = try XCTUnwrap(balance(m, imperial: true))
        XCTAssertTrue(imperial.detail?.contains("weight up 0.4 lb a week") == true, imperial.detail ?? "")
    }

    /// A week without the scale leaves a gap, not a different trend.
    func testAMissingWeekOfWeighInsKeepsTheTrend() throws {
        let water: [Int: Double] = [2: 0.3, 5: -0.25, 21: 0.2, 25: -0.3]
        let m = month(weighDays: Array(1...28).filter { !(10...16).contains($0) },
                      weight: { 80 + Double($0) * 0.3 / 7 + (water[$0] ?? 0) },
                      active: 650, resting: 1_800, logged: { _ in 1_800 })
        let b = try XCTUnwrap(balance(m))
        XCTAssertEqual(b.weighIns, 21)
        XCTAssertEqual(b.weighInSpanDays, 28)
        XCTAssertEqual(b.status, .measured)
        XCTAssertEqual((b.weightChangePerDay ?? 0) * 7, -0.3, accuracy: 0.03)
        XCTAssertEqual(b.headline, "Your logs cover about 85% of what your weight says you eat")
    }

    /// Two salty-dinner mornings at the end of the month, 1.5 kg up, barely move the trend; a
    /// least-squares line would read them as weeks of gain.
    func testWaterWeightBarelyMovesTheTrend() {
        var points: [(x: Double, y: Double)] = (1...28).map { daysAgo -> (x: Double, y: Double) in
            let kg: Double = 80 + Double(daysAgo) * 0.3 / 7
            return (x: Double(28 - daysAgo), y: kg)
        }
        points[0].y += 1.5   // yesterday
        points[1].y += 1.5   // the day before
        let slope = EnergyBalance.theilSenSlope(points)
        XCTAssertEqual(slope * 7, -0.3, accuracy: 0.02)
    }

    // MARK: - Which days count

    /// Breakfast-only days would say the logs miss most of what's eaten; they're left out.
    func testPartlyLoggedDaysAreLeftOut() throws {
        let partial: Set = [3, 6, 9, 12, 15, 18]
        let m = month(loggedDays: Array(1...28).filter { $0 != 20 && $0 != 21 },
                      mealsPerDay: { partial.contains($0) ? 1 : 3 },
                      logged: { partial.contains($0) ? 450 : 2_000 })
        let b = try XCTUnwrap(balance(m))
        XCTAssertEqual(b.fullyLoggedDays, 20)
        XCTAssertEqual(b.loggedPerDay ?? 0, 2_000, accuracy: 0.01)
        XCTAssertEqual(b.status, .measured)
    }

    /// The rule is your own median, not a count of meals: two meals is a whole day for some.
    func testFullyLoggedFollowsYourOwnDayNotAMealCount() throws {
        XCTAssertEqual(EnergyBalance.fullyLogged([2_000, 1_900, 450, 2_100, 1_500]), [2_000, 1_900, 2_100, 1_500])
        let twoMeals = month(mealsPerDay: { _ in 2 }, logged: { _ in 2_100 })
        XCTAssertEqual(try XCTUnwrap(balance(twoMeals)).fullyLoggedDays, 28)
    }

    /// Today isn't finished: a big lunch, a weigh-in and the Watch's count so far change nothing.
    func testTodayIsLeftOut() throws {
        var m = month(weight: { 80 + Double($0) * 0.3 / 7 }, active: 650, resting: 1_800, logged: { _ in 1_800 })
        let before = try XCTUnwrap(balance(m))
        m.meals.append(MealEntry(date: date(0, hour: 12, now: september29),
                                 items: [MealItem(name: "Feast", serving: "1", macros: .init(calories: 5_000))]))
        m.weight.append(MetricPoint(date: date(0, now: september29), value: 90))
        m.active.append(MetricPoint(date: date(0, now: september29), value: 120))
        m.resting.append(MetricPoint(date: date(0, now: september29), value: 600))
        XCTAssertEqual(try XCTUnwrap(balance(m)), before)
    }

    /// Days are counted on the calendar, so the window holds 28 of them across a clock change.
    func testTheWindowIsFourWeeksAcrossAClockChange() throws {
        let november10 = calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 9))!
        let b = try XCTUnwrap(balance(month(now: november10, logged: { _ in 2_040 }), now: november10))
        XCTAssertEqual(b.weighIns, 28)
        XCTAssertEqual(b.weighInSpanDays, 28)
        XCTAssertEqual(b.energyDays, 28)
        XCTAssertEqual(b.fullyLoggedDays, 28)
    }

    // MARK: - Not enough yet

    func testNotEnoughYetSaysWhatsMissing() throws {
        let nineDays = try XCTUnwrap(balance(month(weighDays: Array(1...9))))
        XCTAssertEqual(nineDays.status, .gathering)
        XCTAssertEqual(nineDays.headline, "Needs 3 weeks of weigh-ins \u{2014} 9 days so far")
        XCTAssertNil(nineDays.detail)
        XCTAssertNil(nineDays.coverage)

        XCTAssertEqual(try XCTUnwrap(balance(month(weighDays: [3]))).headline,
                       "Needs 3 weeks of weigh-ins \u{2014} 1 day so far")
        XCTAssertEqual(try XCTUnwrap(balance(month(weighDays: [1, 7, 14, 20, 25]))).headline,
                       "Needs 8 weigh-ins in 4 weeks \u{2014} 5 so far")
        XCTAssertEqual(try XCTUnwrap(balance(month(loggedDays: Array(1...6)))).headline,
                       "Needs 10 fully logged days \u{2014} 6 so far")
        XCTAssertEqual(try XCTUnwrap(balance(month(energyDays: Array(1...15)))).headline,
                       "Needs the Watch\u{2019}s energy on most days \u{2014} 15 of the last 28 so far")
    }

    /// No scale, no logs or no Watch: nothing to say, not a line about what to start doing.
    func testNothingAtAllSaysNothing() {
        XCTAssertNil(balance(month(weighDays: [])))
        XCTAssertNil(balance(month(loggedDays: [])))
        XCTAssertNil(balance(month(energyDays: [])))
        XCTAssertNil(balance(month(weighDays: [40, 50, 60])), "weigh-ins from before the four weeks don't count")
    }

    // MARK: - Doesn't add up

    /// The Watch off the wrist: too little burned for anyone to live on. No percentage.
    func testTooLittleBurnedDoesNotAddUp() throws {
        let b = try XCTUnwrap(balance(month(active: 150, resting: 700, logged: { _ in 1_900 })))
        XCTAssertEqual(b.status, .doesNotAddUp)
        XCTAssertEqual(b.headline, "Your logs and your weight don\u{2019}t add up")
        XCTAssertFalse(b.headline.contains("%"))
        XCTAssertTrue(b.detail?.contains("Watch missed") == true, b.detail ?? "")
    }

    /// Logged far above a plausible intake: the Watch, again, rather than a 175% number.
    func testLogsFarAboveDoNotAddUp() throws {
        let b = try XCTUnwrap(balance(month(active: 200, resting: 1_300, logged: { _ in 2_600 })))
        XCTAssertEqual(b.status, .doesNotAddUp)
        XCTAssertGreaterThan(b.coverage ?? 0, 1.6)
        XCTAssertTrue(b.detail?.contains("Watch missed") == true, b.detail ?? "")
    }

    /// Logged far below: not the Watch's fault, so it doesn't say so.
    func testLogsFarBelowDoNotAddUp() throws {
        let b = try XCTUnwrap(balance(month(logged: { _ in 800 })))
        XCTAssertEqual(b.status, .doesNotAddUp)
        XCTAssertLessThan(b.coverage ?? 1, 0.4)
        XCTAssertFalse(b.detail?.contains("Watch") ?? true, b.detail ?? "")
    }

    // MARK: - Words

    func testHeadlineRoundsToTheNearestFivePercent() {
        XCTAssertEqual(EnergyBalance.headline(coverage: 0.83), "Your logs cover about 85% of what your weight says you eat")
        XCTAssertEqual(EnergyBalance.headline(coverage: 0.82), "Your logs cover about 80% of what your weight says you eat")
        XCTAssertEqual(EnergyBalance.headline(coverage: 0.874), "Your logs cover about 85% of what your weight says you eat")
        XCTAssertEqual(EnergyBalance.headline(coverage: 0.876), "Your logs cover about 90% of what your weight says you eat")
        XCTAssertEqual(EnergyBalance.headline(coverage: 0.41), "Your logs cover about 40% of what your weight says you eat")
        XCTAssertEqual(EnergyBalance.headline(coverage: 0.976), "Your logs match what your weight says you eat")
        XCTAssertEqual(EnergyBalance.headline(coverage: 1.024), "Your logs match what your weight says you eat")
        XCTAssertEqual(EnergyBalance.headline(coverage: 1.03),
                       "Your logs come to about 105% of what your weight says you eat \u{2014} they run high, or the Watch undercounts")
        XCTAssertEqual(EnergyBalance.headline(coverage: 1.149),
                       "Your logs come to about 115% of what your weight says you eat \u{2014} they run high, or the Watch undercounts")
    }

    /// The `--energy-balance` fixtures show the states they're named for.
    func testPreviewFixturesShowTheirStates() throws {
        func preview(_ kind: EnergyBalance.Preview) -> EnergyBalance? {
            let s = kind.sample(now: september29, calendar: calendar)
            return EnergyBalance.compute(meals: s.meals, weightKg: s.weightKg, activeKcal: s.activeKcal,
                                         restingKcal: s.restingKcal, now: september29, calendar: calendar,
                                         imperial: false, locale: locale)
        }
        let measured = try XCTUnwrap(preview(.measured))
        XCTAssertEqual(measured.status, .measured)
        XCTAssertEqual(measured.headline, "Your logs cover about 85% of what your weight says you eat")
        XCTAssertEqual(measured.fullyLoggedDays, 22, "three breakfast-only days and three blank ones are left out")
        XCTAssertEqual((measured.weightChangePerDay ?? 0) * 7, -0.3, accuracy: 0.05)
        XCTAssertGreaterThan(try XCTUnwrap(preview(.over)).coverage ?? 0, 1.05)
        XCTAssertEqual(try XCTUnwrap(preview(.over)).status, .measured)
        XCTAssertEqual(try XCTUnwrap(preview(.off)).status, .doesNotAddUp)
        XCTAssertEqual(try XCTUnwrap(preview(.gathering)).headline, "Needs 3 weeks of weigh-ins \u{2014} 9 days so far")
        XCTAssertEqual(EnergyBalance.Preview.requested(["Banana", "--energy-balance"]), .measured)
        XCTAssertEqual(EnergyBalance.Preview.requested(["Banana", "--energy-balance", "off"]), .off)
        XCTAssertNil(EnergyBalance.Preview.requested(["Banana", "--wellness"]))
    }
}
