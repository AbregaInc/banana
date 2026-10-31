import Combine
import XCTest

/// Your foods, kept and synced (`MyFoodsStore`).
@MainActor
final class MyFoodsStoreTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        super.setUp()
        url = FileManager.default.temporaryDirectory.appendingPathComponent("my-foods-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
        super.tearDown()
    }

    private func food(_ name: String, barcode: String? = nil, kcal: Double = 150) -> MyFood {
        MyFood(name: name, barcode: barcode, per100g: NutritionMacros(calories: kcal), servingLabel: "1 cup",
               servingGrams: 140, source: barcode == nil ? .label : .barcode)
    }

    func testScanningInGroceriesIsAPurchaseEachShop() {
        let store = MyFoodsStore(fileURL: url)
        let monday = Date(timeIntervalSince1970: 1_791_000_000)
        let first = store.bought(food("Greek Yogurt", barcode: "00772914"), at: monday)
        store.bought(food("Greek Yogurt", barcode: "00772914"), at: monday.addingTimeInterval(60))
        let again = store.bought(food("Greek Yogurt", barcode: "00772914"), at: monday.addingTimeInterval(7 * 86_400))
        XCTAssertEqual(again.id, first.id)
        XCTAssertEqual(store.foods.count, 1)
        XCTAssertEqual(again.bought, [monday, monday.addingTimeInterval(7 * 86_400)])
        // A scan to correct a meal keeps them.
        XCTAssertEqual(store.save(food("Greek Yogurt", barcode: "00772914")).bought.count, 2)
    }

    func testScanningTheSameBarcodeAgainUpdatesTheFoodItIs() {
        let store = MyFoodsStore(fileURL: url)
        let first = store.save(food("Pumpkin Gnocchi", barcode: "0051"))
        store.note(first.id, standsFor: "Gnocchi")
        let again = store.save(food("Trader Joe's Pumpkin Gnocchi", barcode: "0051", kcal: 160))
        XCTAssertEqual(again.id, first.id)
        XCTAssertEqual(store.foods.count, 1)
        XCTAssertEqual(again.per100g.calories, 160)
        XCTAssertEqual(again.standsFor, ["gnocchi"], "what it stood in for survives a rescan")
        XCTAssertEqual(MyFoodsStore(fileURL: url).foods.map(\.id), [first.id], "kept on disk")
    }

    func testUsesFollowTheMealLog() {
        let store = MyFoodsStore(fileURL: url)
        let gnocchi = store.save(food("Pumpkin Gnocchi"))
        let meals = CurrentValueSubject<[MealEntry], Never>([])
        store.follow(meals)
        XCTAssertNil(store.food(gnocchi.id)?.lastUsed)
        meals.send([MealEntry(date: Date(), items: [ScanCorrection.item(food: gnocchi, grams: 210)])])
        XCTAssertEqual(store.food(gnocchi.id)?.uses.map(\.grams), [210])
        XCTAssertEqual(store.food(gnocchi.id).flatMap { MyFoods.typicalGrams($0) }, 210)
    }

    func testAnotherDevicesFoodArrivesAndSoDoesItsDeletion() throws {
        let store = MyFoodsStore(fileURL: url)
        let remote = food("Kale chips")
        XCTAssertTrue(store.applyCloud(.myFood, id: remote.id.uuidString, item: try JSONEncoder().encode(remote)))
        XCTAssertEqual(store.food(remote.id)?.name, "Kale chips")
        XCTAssertNotNil(store.cloudItems(.myFood)[remote.id.uuidString])
        XCTAssertTrue(store.cloudItems(.routine).isEmpty)
        store.applyCloud(.myFood, id: remote.id.uuidString, item: nil)
        XCTAssertNil(store.food(remote.id))
    }

    func testOneUnreadableFoodCostsOnlyItself() throws {
        let good = food("Pumpkin Gnocchi")
        let json = "[\(String(decoding: try JSONEncoder().encode(good), as: UTF8.self)), {\"name\": 3}]"
        try Data(json.utf8).write(to: url)
        XCTAssertEqual(MyFoodsStore(fileURL: url).foods.map(\.id), [good.id])
    }

    func testADeletedFoodComesBackOnUndo() {
        let store = MyFoodsStore(fileURL: url)
        let gnocchi = store.save(food("Pumpkin Gnocchi"))
        store.delete(gnocchi.id)
        XCTAssertTrue(store.foods.isEmpty)
        store.restore(gnocchi)
        XCTAssertEqual(store.food(gnocchi.id)?.name, "Pumpkin Gnocchi")
    }
}
