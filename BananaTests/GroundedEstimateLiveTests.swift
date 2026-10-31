import XCTest

/// The grounded estimate end to end — Apple's cloud model, the searchFoods tool, the bundled USDA
/// database — on a real iPhone or iPad with iOS 27. Skipped wherever that model isn't reachable
/// (the Simulator, a Mac on macOS 26), so the unit suite stays offline.
///
/// Run on a device: xcodebuild test … -destination 'id=<device>'
///   -only-testing:BananaTests/GroundedEstimateLiveTests
final class GroundedEstimateLiveTests: XCTestCase {
    @MainActor
    func testATypedMealIsGroundedInUSDAFoods() async throws {
        guard Intelligence.route(.knowledge, given: Intelligence.current) == .cloud else {
            throw XCTSkip("Needs Apple's Private Cloud Compute model (iOS 27 device).")
        }
        let outcome = await GroundedFoodEstimate.meal(
            images: [], note: "chicken curry with a cup of white rice and a mango lassi", eatenAt: Date())
        guard case .proposal(let proposal) = outcome else {
            return XCTFail("No proposal: \(outcome)")
        }
        for item in proposal.items {
            print("🍽 \(item.name) · \(item.serving) · \(Int(item.macros.calories)) kcal · \(item.reference?.id ?? "model's own") \(item.reference?.name ?? "")")
        }
        XCTAssertGreaterThanOrEqual(proposal.items.count, 2)
        XCTAssertTrue(proposal.items.contains { $0.reference != nil }, "at least one item from the database")
        XCTAssertTrue((400...2_000).contains(proposal.totals.calories), "total \(proposal.totals.calories) kcal")
    }

    @MainActor
    func testOneTypedItemFindsItsFood() async throws {
        guard Intelligence.route(.knowledge, given: Intelligence.current) == .cloud else {
            throw XCTSkip("Needs Apple's Private Cloud Compute model (iOS 27 device).")
        }
        let found = await GroundedFoodEstimate.item(name: "banana", quantity: "1 medium")
        let item = try XCTUnwrap(found)
        print("🍌 \(item.serving) · \(Int(item.macros.calories)) kcal · \(item.reference?.name ?? "model's own")")
        XCTAssertNotNil(item.reference)
        XCTAssertTrue((80...140).contains(item.macros.calories), "\(item.macros.calories) kcal")
    }
}
