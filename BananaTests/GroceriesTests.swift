import XCTest

/// Scanning in what you bought (`GroceryScanView`): each scan is a purchase, and what you've
/// bought lately and not had since is offered before you've ever logged it (`MyFoods.justBought`).
final class GroceriesTests: XCTestCase {
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/New_York")!; return c }
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 8))! }
    private func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    private func yogurt(bought: [Date] = [], uses: [MyFood.Use] = [], addedAt: Date? = nil) -> MyFood {
        MyFood(name: "Greek Yogurt", barcode: "00772914", per100g: .init(calories: 132), servingLabel: "1 container",
               servingGrams: 227, source: .barcode, addedAt: addedAt ?? bought.first ?? daysAgo(30), uses: uses, bought: bought)
    }

    func testEachShopIsOnePurchaseHoweverOftenItsScanned() {
        var food = yogurt()
        food = MyFoods.purchased(food, at: daysAgo(7), calendar: calendar)
        food = MyFoods.purchased(food, at: now, calendar: calendar)
        food = MyFoods.purchased(food, at: now.addingTimeInterval(600), calendar: calendar)
        XCTAssertEqual(food.bought, [daysAgo(7), now])
        XCTAssertEqual(food.lastBought, now)
    }

    func testAFoodScannedBeforePurchasesWereKeptWasBoughtWhenAdded() throws {
        let json = #"{"id":"8C3A7B6E-0D3B-4C1E-9E0A-2F1B8E6A9D10","name":"Gnocchi","per100g":{"calories":160,"proteinGrams":0,"carbohydrateGrams":0,"fatGrams":0},"servingLabel":"1 cup","servingGrams":140,"source":"label","addedAt":0}"#
        let food = try JSONDecoder().decode(MyFood.self, from: Data(json.utf8))
        XCTAssertEqual(food.bought, [])
        XCTAssertEqual(food.lastBought, food.addedAt)
        let encoded = try JSONDecoder().decode(MyFood.self, from: JSONEncoder().encode(MyFoods.purchased(food, at: now)))
        XCTAssertEqual(encoded.bought, [now], "purchases are kept and synced")
    }

    func testWhatYouBoughtAndHaventHadIsOffered() {
        let fresh = yogurt(bought: [daysAgo(2)])
        let eatenSince = MyFood(name: "Granola", per100g: .init(calories: 450), servingLabel: "1/2 cup", servingGrams: 50,
                                source: .barcode, addedAt: daysAgo(5), uses: [.init(at: daysAgo(1), grams: 50)], bought: [daysAgo(5)])
        let longAgo = MyFood(name: "Crackers", per100g: .init(calories: 440), servingLabel: "1 oz", servingGrams: 28,
                             source: .barcode, addedAt: daysAgo(40), bought: [daysAgo(40)])
        XCTAssertEqual(MyFoods.justBought([longAgo, eatenSince, fresh], now: now).map(\.name), ["Greek Yogurt"])
    }

    func testHavingItRanksAboveOnlyBuyingIt() {
        let had = MyFood(name: "Granola", per100g: .init(calories: 450), servingLabel: "1/2 cup", servingGrams: 50,
                         source: .barcode, addedAt: daysAgo(60), uses: [.init(at: now, grams: 50)], bought: [daysAgo(60)])
        let boughtToday = yogurt(bought: [now])
        let boughtLastMonth = MyFood(name: "Crackers", per100g: .init(calories: 440), servingLabel: "1 oz", servingGrams: 28,
                                     source: .barcode, addedAt: daysAgo(30), bought: [daysAgo(30)])
        XCTAssertEqual(MyFoods.ranked([boughtLastMonth, boughtToday, had], now: now).map(\.name),
                       ["Granola", "Greek Yogurt", "Crackers"])
    }

    func testABoughtFoodIsOfferedAtItsServingWhenLoggingAMeal() throws {
        let mine = yogurt(bought: [daysAgo(1)])
        let offered = UsualFoods.foods(at: now, meals: [], myFoods: [mine], now: now, calendar: calendar)
        let food = try XCTUnwrap(offered.first)
        XCTAssertEqual(food.name, "Greek Yogurt")
        XCTAssertEqual(food.item.grams, 227, "a whole container: you haven't had it yet, so no usual amount")
        XCTAssertEqual(food.item.reference?.id, mine.reference.id, "it's your food, with its label's numbers")
        XCTAssertEqual(UsualFoods.names(at: now, meals: [], myFoods: [mine], now: now, calendar: calendar),
                       ["Greek Yogurt"], "and the model is told its name")
    }

    func testAHabitAlreadyOfferedIsntOfferedTwice() {
        let meals = (1...2).map { day in
            MealEntry(date: daysAgo(Double(day)), items: [MealItem(name: "Greek yogurt", serving: "", macros: .init(calories: 300), grams: 227)])
        }
        let offered = UsualFoods.foods(at: now, meals: meals, myFoods: [yogurt(bought: [now])], now: now, calendar: calendar)
        XCTAssertEqual(offered.count, 1)
    }
}
