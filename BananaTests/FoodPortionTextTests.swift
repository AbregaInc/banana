import XCTest

/// The estimates the review of 1 Oct 2026 found wrong, one case each: amounts left in food names,
/// grams 2–20× off for a teaspoon, a cup or a bowl, and look-ups that matched another food.
final class FoodPhraseTests: XCTestCase {
    private func split(_ text: String) -> (Double?, FoodQuantity.Unit?, String) {
        let (quantity, food) = FoodPhrase.split(text)
        return (quantity?.amount, quantity?.unit, food)
    }

    func testTheAmountComesOffTheFood() {
        XCTAssertEqual(split("1/2 can of tomato sauce").0, 0.5)
        XCTAssertEqual(split("1/2 can of tomato sauce").1, .measure("can"))
        XCTAssertEqual(split("1/2 can of tomato sauce").2, "tomato sauce")
        XCTAssertEqual(split("half a can of beans").0, 0.5)
        XCTAssertEqual(split("half a can of beans").2, "beans")
        XCTAssertEqual(split("1/2 spoon of olive oil").1, .volume(.tablespoon))
        XCTAssertEqual(split("1-2 palms of chicken").0, 1.5)
        XCTAssertEqual(split("½ tsp sour cream").0, 0.5)
        XCTAssertEqual(split("½ tsp sour cream").2, "sour cream")
        XCTAssertEqual(split("1 1/2 cups rice").0, 1.5)
        XCTAssertEqual(split("200g chicken").1, .mass(grams: 1))
        XCTAssertEqual(split("200g chicken").0, 200)
        XCTAssertEqual(split("1 medium onion").1, .size("medium"))
        XCTAssertEqual(split("1 medium onion").2, "onion")
        XCTAssertEqual(split("a bowl of egg drop soup").1, .volume(.bowl))
        XCTAssertEqual(split("2 eggs").1, .count)
        XCTAssertEqual(split("2 eggs").2, "eggs")
        XCTAssertEqual(FoodPhrase.quantity("1 can")?.unit, .measure("can"), "a portion phrase keeps its measure")
        XCTAssertEqual(split("a few almonds").0, 3)
    }

    func testANameWithNoAmountStaysWhole() {
        XCTAssertNil(split("egg drop soup").0, "a measure word with no number or 'of' is part of the name")
        XCTAssertEqual(split("egg drop soup").2, "egg drop soup")
        XCTAssertEqual(split("bowl of egg drop soup").1, .volume(.bowl))
        XCTAssertEqual(split("bowl of egg drop soup").2, "egg drop soup")
        XCTAssertEqual(FoodPhrase.quantity("bowl")?.unit, .volume(.bowl), "a portion phrase needs neither")
        XCTAssertNil(split("beef bone broth").0)
        XCTAssertEqual(split("beef bone broth").2, "beef bone broth")
        XCTAssertEqual(split("large fries").2, "large fries", "a size word alone isn't an amount")
        XCTAssertNil(FoodPhrase.quantity("typical portion"))
        XCTAssertNil(FoodPhrase.quantity("Guideline amount per slice of bread/roll"))
    }
}

final class PortionGramsTests: XCTestCase {
    private func grams(_ text: String, _ portions: [(String, Double)], food: String = "") -> Double? {
        PortionGrams.grams(FoodPhrase.quantity(text), portions: portions.map { FoodPortion(label: $0.0, grams: $0.1) },
                           food: food)
    }

    private let butter = [("1 cup", 224.0), ("1 tablespoon", 14.0), ("1 pat", 7.0)]

    func testSpoonsAndCupsUseTheFoodsOwnMeasures() throws {
        XCTAssertEqual(try XCTUnwrap(grams("1 tsp", butter)), 4.7, accuracy: 0.1, "was 1 g")
        XCTAssertEqual(try XCTUnwrap(grams("1/2 tsp", [("1 tablespoon", 15)])), 2.5, accuracy: 0.1, "sour cream: was 20 g")
        XCTAssertEqual(try XCTUnwrap(grams("1/2 cup", [("1 cup", 249)])), 124.5, accuracy: 0.1, "broth: was 50 g")
        XCTAssertEqual(try XCTUnwrap(grams("2 cups", [("1 cup, cooked", 175), ("1 cup", 176)])), 350, accuracy: 0.1,
                       "rice noodles: was 200 g")
        XCTAssertEqual(try XCTUnwrap(grams("1/2 spoon", [("1 cup", 224), ("1 tablespoon", 14)])), 7, accuracy: 0.1)
    }

    func testABowlIsACupAndAHalf() throws {
        XCTAssertEqual(try XCTUnwrap(grams("1 bowl", [("1 cup", 245)])), 367, accuracy: 2, "egg drop soup: was 150 g")
    }

    func testSizesAndPieces() throws {
        let carrot = [("1 cup", 120.0), ("1 regular carrot", 60), ("1 large (7-1/4\" to 8-/1/2\" long)", 72),
                      ("1 medium", 61), ("1 small (5-1/2\" long)", 50)]
        XCTAssertEqual(try XCTUnwrap(grams("1 medium", carrot)), 61, "was 15 g")
        XCTAssertEqual(try XCTUnwrap(grams("1 large", carrot)), 72)
        let pepper = [("1 cup", 149.0), ("1 regular", 119)]
        XCTAssertEqual(try XCTUnwrap(grams("1 medium", pepper)), 119, "a medium is a regular one: was 50 g")
        let salmon = [("1 small/regular fillet", 140.0), ("1 large fillet", 210)]
        XCTAssertEqual(try XCTUnwrap(grams("1 fillet", salmon)), 140)
        XCTAssertEqual(try XCTUnwrap(grams("1 piece", salmon)), 140, "a piece is a regular one")
        XCTAssertEqual(try XCTUnwrap(grams("2", [("1 egg", 50.0), ("1 cup", 135)], food: "eggs")), 100)
    }

    func testWeightsAndCans() throws {
        XCTAssertEqual(try XCTUnwrap(grams("3 oz", [])), 85, accuracy: 0.1)
        XCTAssertEqual(try XCTUnwrap(grams("1/2 can", [("1 cup", 185)])), PortionGrams.defaultCanGrams / 2)
        XCTAssertEqual(try XCTUnwrap(grams("1 can", [("1 can (10.75 oz)", 305)])), 305)
    }

    func testWhatItCantWorkOutIsLeftToTheModel() {
        XCTAssertNil(grams("1 plate", [("1 cup", 235)]))
        XCTAssertNil(grams("some", [("1 cup", 235)]))
        XCTAssertNil(grams("2", [("1 cup", 235)], food: "curry"))
    }
}

final class FoodMatchRuleTests: XCTestCase {
    private func food(_ id: String, _ name: String, kcal: Double) -> FoodMatch {
        FoodMatch(reference: FoodReference(id: id, name: name, per100g: .init(calories: kcal)), category: "", portions: [])
    }

    func testTheFoodItselfHasToBeThere() {
        XCTAssertFalse(GroundedFoodEstimate.covers(query: "beef bone broth", name: "Beef, steak, T-bone, NS as to fat eaten"))
        XCTAssertFalse(GroundedFoodEstimate.covers(query: "apple cider vinegar", name: "Apple cider"))
        XCTAssertTrue(GroundedFoodEstimate.covers(query: "apple cider vinegar", name: "Vinegar, cider"))
        XCTAssertFalse(GroundedFoodEstimate.covers(query: "chicken broth", name: "Chicken, canned, no broth"), "a 'no'")
        XCTAssertTrue(GroundedFoodEstimate.covers(query: "chicken broth", name: "Soup, chicken broth, ready-to-serve"))
        XCTAssertFalse(GroundedFoodEstimate.covers(query: "1/2 can of tomato sauce",
                                                   name: "Lean Cuisine Spaghetti With Meatballs 9 1/2 Oz"),
                       "the amount's numbers aren't words of the food")
        XCTAssertTrue(GroundedFoodEstimate.covers(query: "grilled salmon", name: "Fish, salmon, NFS"),
                      "how it was cooked isn't required")
    }

    func testAMatchFarFromTheModelsCaloriesIsSomeOtherFood() {
        let dryOrzo = food("branded:1", "Pastene Orzo", kcal: 375)
        XCTAssertNil(GroundedFoodEstimate.bestMatch(for: "orzo", among: [dryOrzo], ownCaloriesPer100g: 133),
                     "dry orzo, eaten cooked")
        let steak = food("fndds:1", "Beef, bone broth style steak", kcal: 252)
        let broth = food("branded:2", "Sun Fed Ranch Beef Bone Broth", kcal: 20)
        XCTAssertEqual(GroundedFoodEstimate.bestMatch(for: "beef bone broth", among: [steak, broth],
                                                      ownCaloriesPer100g: 8)?.reference.id, "branded:2")
        let butter = food("fndds:3", "Butter, NFS", kcal: 717)
        XCTAssertNotNil(GroundedFoodEstimate.bestMatch(for: "butter", among: [butter], ownCaloriesPer100g: 3_500),
                        "the model put 35 kcal in 1 g: a leaner food than it thought is kept")
    }

    /// The model guesses condiments high; rejecting the plain food picked a richer one after it.
    func testAPlainerFoodThanTheModelThoughtIsKept() {
        let mustard = food("fndds:4", "Mustard", kcal: 69)
        let oil = food("sr:5", "Oil, mustard", kcal: 884)
        XCTAssertEqual(GroundedFoodEstimate.bestMatch(for: "mustard", among: [mustard, oil],
                                                      ownCaloriesPer100g: 500)?.reference.id, "fndds:4")
        let sauce = food("sr:6", "Tomato sauce, canned, no salt added", kcal: 24)
        let chili = food("fndds:7", "Tomato chili sauce", kcal: 92)
        XCTAssertEqual(GroundedFoodEstimate.bestMatch(for: "tomato sauce", among: [sauce, chili],
                                                      ownCaloriesPer100g: 90)?.reference.id, "sr:6")
    }

    func testACanLooksForTheCannedFood() {
        let cooked = food("fndds:8", "Beans, NFS", kcal: 189)
        let canned = food("fndds:9", "Beans, from canned, NS as to type, no added fat", kcal: 136)
        let parts = GroundedFoodEstimate.parts(
            fromSketches: [.init(name: "1/2 can of beans", grams: 200, portion: "", ownEstimate: .init(calories: 250))],
            search: { $0.contains("canned") ? [canned] : [cooked] })
        XCTAssertEqual(parts[0].foodID, "fndds:9")
    }

    func testABrandedNameThatSaysMuchMoreIsntTheFood() {
        let salad = food("branded:3", "Target Stores Seafood Shrimp & Seafood Blend In A Creamy Salad Dressing With Chopped Celery, Seafood",
                         kcal: 300)
        XCTAssertNil(GroundedFoodEstimate.bestMatch(for: "seafood blend", among: [salad], ownCaloriesPer100g: 150))
        let burrata = food("branded:4", "Belgioioso Cheese, Inc. Burrata", kcal: 250)
        XCTAssertNotNil(GroundedFoodEstimate.bestMatch(for: "burrata", among: [burrata], ownCaloriesPer100g: 280))
    }

    func testTheSketchsAmountBecomesThePortionAndTheGramsComeFromIt() {
        let sauce = FoodMatch(reference: FoodReference(id: "sr:169074", name: "Tomato sauce, canned, no salt added",
                                                       per100g: .init(calories: 24)),
                              category: "", portions: [FoodPortion(label: "1 cup", grams: 245)])
        let parts = GroundedFoodEstimate.parts(
            fromSketches: [.init(name: "1/2 cup of tomato sauce", grams: 60, portion: "",
                                 ownEstimate: .init(calories: 20))],
            search: { $0 == "tomato sauce" ? [sauce] : [] })
        XCTAssertEqual(parts[0].name, "tomato sauce")
        XCTAssertEqual(parts[0].portion, "1/2 cup")
        let items = GroundedFoodEstimate.resolve(parts, lookup: { $0 == "sr:169074" ? sauce : nil })
        XCTAssertEqual(items[0].grams ?? 0, 122.5, accuracy: 0.1, "half USDA's cup, not the model's 60 g")
        XCTAssertEqual(items[0].macros.calories, 29.4, accuracy: 0.1)
    }
}

final class OutdatedEstimateTests: XCTestCase {
    func testOnlyWaitingMealsFromAnOlderEstimatorAreRedone() {
        let old = MealInboxItem(eatenAt: Date(), note: "orzo and salmon", state: .proposed, origin: .typed,
                                proposal: MealProposal(name: "Orzo", items: []))
        let current = MealInboxItem(eatenAt: Date(), note: "rice", state: .proposed, origin: .typed,
                                    proposal: MealProposal(name: "Rice", items: [], estimator: GroundedFoodEstimate.version))
        let waiting = MealInboxItem(eatenAt: Date(), note: "soup", state: .ready, origin: .typed)
        let empty = MealInboxItem(eatenAt: Date(), state: .proposed, origin: .typed,
                                  proposal: MealProposal(name: "?", items: []))
        XCTAssertEqual(MealBacklogRouting.outdatedProposals([old, current, waiting, empty],
                                                            version: GroundedFoodEstimate.version), [old.id])
    }
}

/// Who estimates a meal: a Mac on power first, then the device it was readied on, then the iPhone.
final class MealRoutingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func item(photos: Bool, readiedBy: String = "phone", secondsAgo: TimeInterval) -> MealInboxItem {
        MealInboxItem(eatenAt: now, photos: photos ? [MealPhotoRef()] : [], note: photos ? "" : "toast",
                      state: .ready, origin: .typed, readiedBy: readiedBy, readiedAt: now.addingTimeInterval(-secondsAgo))
    }
    private let phone = MealBacklogRouting.Here(installID: "phone", isHub: true, canReadPhotos: true, canReadText: true)
    private func mac(photos: Bool, onPower: Bool = true) -> MealBacklogRouting.Here {
        .init(installID: "mac", isHub: false, canReadPhotos: photos, canReadText: true, isMac: true, onPower: onPower)
    }
    private func status(photos: Bool, onPower: Bool = true, minutesAgo: Double = 5) -> [String: MealEstimatorStatus] {
        ["mac": .init(device: "Mac", canReadPhotos: photos, canReadText: true, onPower: onPower,
                      at: now.addingTimeInterval(-minutesAgo * 60))]
    }

    // A meal waiting on another device has a way out: enter it by hand, or say it wasn't one.

    func testAPhotoMealOnADeviceThatCannotReadPhotosWaitsElsewhere() {
        let photo = item(photos: true, secondsAgo: 5)
        XCTAssertTrue(MealBacklogRouting.waitsElsewhere(photo, here: mac(photos: false), working: false))
        let noModel = MealBacklogRouting.Here(installID: "phone", isHub: true, canReadPhotos: false, canReadText: false)
        XCTAssertTrue(MealBacklogRouting.waitsElsewhere(item(photos: false, secondsAgo: 5), here: noModel, working: false),
                      "a phone with no model can't read words either: nothing will ever estimate it here")
    }

    func testOneThisDeviceCanEstimateOrIsWorkingOnIsNotWaitingElsewhere() {
        let photo = item(photos: true, secondsAgo: 5)
        XCTAssertFalse(MealBacklogRouting.waitsElsewhere(photo, here: phone, working: false))
        XCTAssertFalse(MealBacklogRouting.waitsElsewhere(item(photos: false, secondsAgo: 5), here: mac(photos: false), working: false),
                       "the Mac reads words")
        XCTAssertFalse(MealBacklogRouting.waitsElsewhere(photo, here: mac(photos: false), working: true))
    }

    func testAMacOnPowerTakesWhatItCanReadAtOnce() {
        let typed = item(photos: false, secondsAgo: 5)
        XCTAssertTrue(MealBacklogRouting.shouldEstimate(typed, here: mac(photos: false), now: now))
        XCTAssertFalse(MealBacklogRouting.shouldEstimate(item(photos: true, secondsAgo: 5), here: mac(photos: false), now: now),
                       "macOS 26 can't read photos")
        XCTAssertFalse(MealBacklogRouting.shouldEstimate(typed, here: mac(photos: false, onPower: false), now: now),
                       "on battery it waits its turn like anyone")
    }

    func testThePhoneLeavesItToTheMacForTwoMinutes() {
        let typed = item(photos: false, secondsAgo: 30)
        let macTakes = MealBacklogRouting.macTakes(typed, estimators: status(photos: false), except: "phone", now: now)
        XCTAssertTrue(macTakes)
        XCTAssertFalse(MealBacklogRouting.shouldEstimate(typed, here: phone, macTakes: macTakes, now: now))
        let later = item(photos: false, secondsAgo: MealBacklogRouting.macHandoff + 1)
        XCTAssertTrue(MealBacklogRouting.shouldEstimate(later, here: phone, macTakes: true, now: now),
                      "the Mac didn't: the phone does")
    }

    func testAMacThatCantTakeItOrIsAsleepIsntWaitedFor() {
        let photo = item(photos: true, secondsAgo: 10)
        XCTAssertFalse(MealBacklogRouting.macTakes(photo, estimators: status(photos: false), except: "phone", now: now),
                       "no vision model on it")
        XCTAssertFalse(MealBacklogRouting.macTakes(photo, estimators: status(photos: true, minutesAgo: 60), except: "phone", now: now),
                       "not heard from in an hour")
        XCTAssertFalse(MealBacklogRouting.macTakes(photo, estimators: status(photos: true, onPower: false), except: "phone", now: now))
        XCTAssertTrue(MealBacklogRouting.macTakes(photo, estimators: status(photos: true), except: "phone", now: now),
                      "on macOS 27, plugged in")
    }

    /// What makes it safe for only the Mac to keep repeating its status: nothing reads another
    /// device's. If routing ever starts to, this fails and `repeatsStatus` has to follow.
    func testOnlyAMacsStatusIsEverRead() {
        let photo = item(photos: true, secondsAgo: 10)
        for device in ["iPhone", "iPad"] {
            let heard = ["other": MealEstimatorStatus(device: device, canReadPhotos: true, canReadText: true,
                                                      onPower: true, at: now.addingTimeInterval(-60))]
            XCTAssertFalse(MealBacklogRouting.macTakes(photo, estimators: heard, except: "phone", now: now),
                           "a fresh, able \(device) is not a Mac to leave the meal to")
        }
    }

    func testOnlyAMacRepeatsItsStatus() {
        XCTAssertTrue(MealBacklogRouting.repeatsStatus(on: .mac))
        XCTAssertFalse(MealBacklogRouting.repeatsStatus(on: .phone), "a pocketed phone's timer wakes the process for nothing")
        XCTAssertFalse(MealBacklogRouting.repeatsStatus(on: .pad))
    }

    func testTheProgressBarAlwaysMovesAndEndsFull() {
        let start = MealEstimateProgress.completed(done: 0, total: 3, secondsIntoCurrent: 0)
        let later = MealEstimateProgress.completed(done: 0, total: 3, secondsIntoCurrent: 10)
        XCTAssertGreaterThan(start, 0)
        XCTAssertGreaterThan(later, start)
        XCTAssertLessThan(MealEstimateProgress.completed(done: 0, total: 3, secondsIntoCurrent: 600), 100,
                          "never past the meal under way")
        XCTAssertEqual(MealEstimateProgress.completed(done: 3, total: 3, secondsIntoCurrent: 5), 300)
        XCTAssertEqual(MealEstimateProgress.subtitle(done: 1, total: 5), "2 of 5")
    }
}
