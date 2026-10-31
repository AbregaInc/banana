import CoreGraphics
import Vision
import XCTest

/// A meal you've had before, from its photo (docs/design/MEAL-LEARNING.md §4). The prints here
/// are made up: short vectors whose straight-line distances are easy to read.
final class RepeatPhotoMealTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let day: TimeInterval = 86_400

    private func meal(_ name: String, daysAgo: Double, prints: [[Float]], items: Int = 2) -> (meal: MealEntry, prints: [[Float]]) {
        let foods = (0..<items).map { MealItem(name: "\(name) \($0)", serving: "1 bowl", macros: .init(calories: 200), grams: 150) }
        let entry = MealEntry(date: now.addingTimeInterval(-daysAgo * day), items: foods, source: .photo, name: name,
                              photoIDs: prints.map { _ in UUID() })
        return (entry, prints)
    }

    // MARK: Distance

    func testDistanceIsStraightLine() {
        XCTAssertEqual(RepeatPhotoMeal.distance([0, 0], [0.3, 0.4]), 0.5, accuracy: 1e-6)
        XCTAssertEqual(RepeatPhotoMeal.distance([1, 2, 3], [1, 2, 3]), 0)
        XCTAssertEqual(RepeatPhotoMeal.distance([0, 0], [0, 0, 0]), .infinity, "another revision's print never matches")
        XCTAssertEqual(RepeatPhotoMeal.distance([Float](), []), .infinity)
        XCTAssertEqual(RepeatPhotoMeal.mealDistance([], [[0, 0]]), .infinity, "no photos, nothing to compare")
    }

    func testEveryPhotoOfEachMealNeedsACounterpart() {
        let stew: [Float] = [0, 0], salad: [Float] = [1, 0]
        // The stew alone against a meal of the stew and a salad: the salad has nothing near it.
        XCTAssertEqual(RepeatPhotoMeal.mealDistance([stew], [stew, salad]), 1, accuracy: 1e-6)
        XCTAssertEqual(RepeatPhotoMeal.mealDistance([stew, salad], [salad, stew]), 0, accuracy: 1e-6)
        XCTAssertEqual(RepeatPhotoMeal.mealDistance([[0.1, 0]], [stew]), 0.1, accuracy: 1e-6)
    }

    // MARK: The words offered

    /// The same breakfast again: what was said for it last time fills "What was this?" in a tap.
    func testTheWordsOfferedAreWhatWasSaidThenItsName() {
        var oats = meal("Oats with berries", daysAgo: 1, prints: [[0, 0]]).meal
        oats.note = "  oatmeal, blueberries and a flat white\n"
        XCTAssertEqual(RepeatPhotoMeal.suggestedWords(oats), "oatmeal, blueberries and a flat white")
        oats.note = " "
        XCTAssertEqual(RepeatPhotoMeal.suggestedWords(oats), "Oats with berries", "photo only last time: its name")
        oats.name = ""
        XCTAssertNil(RepeatPhotoMeal.suggestedWords(oats), "nothing to offer")
    }

    /// The replay of 14 Oct 2026: his yogurt breakfast four times under four names, 0.53–0.60
    /// from itself and 0.73 from the nearest other meal. Copying numbers stays strict — the other
    /// breakfasts count as different meals — but the words are offered.
    func testTheSameBreakfastUnderOtherNamesIsOfferedItsWords() {
        func said(_ name: String, _ note: String, daysAgo: Double, _ print: [Float]) -> (meal: MealEntry, prints: [[Float]]) {
            var entry = meal(name, daysAgo: daysAgo, prints: [print])
            entry.meal.note = note
            return entry
        }
        let monday = said("Breakfast", "Yogurt, granola, and berries", daysAgo: 8, [0.528, 0])
        let wednesday = said("Breakfast", "0% Greek yogurt with granola and raspberries", daysAgo: 6, [0, 0.544])
        let bowl = said("Breakfast bowl", "Greek yogurt, granola, banana, blueberries, raspberries", daysAgo: 1, [-0.603, 0])
        let eggs = said("Eggs and vegetables", "Eggs, cucumber, tomatoes", daysAgo: 2, [0, -0.731])
        let candidates = [monday, wednesday, bowl, eggs]

        XCTAssertTrue(RepeatPhotoMeal.sameKind(monday.meal, bowl.meal))
        XCTAssertFalse(RepeatPhotoMeal.sameKind(monday.meal, eggs.meal))
        XCTAssertNil(RepeatPhotoMeal.match([[0, 0]], candidates: [monday, bowl, eggs], now: now),
                     "for its numbers the bowl is another meal, 0.603 against 0.528")
        XCTAssertEqual(RepeatPhotoMeal.suggestion([[0, 0]], candidates: candidates, now: now), "Yogurt, granola, and berries")
        // Nothing near enough, nothing offered.
        XCTAssertNil(RepeatPhotoMeal.suggestion([[5, 5]], candidates: candidates, now: now))
    }

    /// Said alike is about the foods, not the meal's word or a shared vegetable.
    func testMealsSaidAlike() {
        func said(_ name: String, _ note: String) -> MealEntry {
            var entry = meal(name, daysAgo: 1, prints: [[0, 0]]).meal
            entry.note = note
            return entry
        }
        XCTAssertTrue(RepeatPhotoMeal.sameKind(said("Breakfast", "Greek yogurt, granola, raspberries"),
                                               said("Breakfast bowl", "yogurt with granola and banana")))
        XCTAssertFalse(RepeatPhotoMeal.sameKind(said("Falafel and veggies", "couscous, broccoli, falafel"),
                                                said("Salmon and broccoli with rice", "rice, broccoli, baked salmon")))
        XCTAssertFalse(RepeatPhotoMeal.sameKind(said("Lunch", "tomato soup"), said("Dinner", "lentil curry")),
                       "a meal's word in common is nothing")
    }

    // MARK: Matching

    func testAPhotoCloseToALoggedMealProposesIt() {
        let oats = meal("Oats", daysAgo: 3, prints: [[0.2, 0]])
        let curry = meal("Curry", daysAgo: 2, prints: [[1.0, 0]])
        let found = RepeatPhotoMeal.match([[0, 0]], candidates: [oats, curry], now: now)
        XCTAssertEqual(found?.meal.id, oats.meal.id)
        XCTAssertEqual(found?.distance ?? 0, 0.2, accuracy: 1e-6)
    }

    func testNothingUnderTheThresholdIsNoMatch() {
        let oats = meal("Oats", daysAgo: 3, prints: [[RepeatPhotoMeal.threshold + 0.01, 0]])
        XCTAssertNil(RepeatPhotoMeal.match([[0, 0]], candidates: [oats], now: now))
    }

    func testTwoDifferentMealsAlikeAreNoMatch() {
        let broccoliChicken = meal("Orange chicken", daysAgo: 3, prints: [[0.30, 0]])
        let broccoliGnocchi = meal("Gnocchi", daysAgo: 4, prints: [[0, 0.32]])
        XCTAssertNil(RepeatPhotoMeal.match([[0, 0]], candidates: [broccoliChicken, broccoliGnocchi], now: now),
                     "0.30 isn't clearly closer than 0.32")
        // Clearly closer, it is.
        let farther = meal("Gnocchi", daysAgo: 4, prints: [[0, 0.5]])
        XCTAssertEqual(RepeatPhotoMeal.match([[0, 0]], candidates: [broccoliChicken, farther], now: now)?.meal.id,
                       broccoliChicken.meal.id)
    }

    /// The two measured cases the ratio sits between (see `RepeatPhotoMeal.ratio`).
    func testTheRealRepeatIsProposedAndTheLookAlikeDinnerIsNot() {
        // The stew again at dinner: 0.574 from its lunch, the next different food 0.753 away.
        let stew = meal("Bean and seafood stew", daysAgo: 0.25, prints: [[0.574, 0]])
        let orangeChicken = meal("Orange chicken", daysAgo: 2, prints: [[0, 0.753]])
        XCTAssertEqual(RepeatPhotoMeal.match([[0, 0]], candidates: [stew, orangeChicken], now: now)?.meal.id, stew.meal.id)
        // Chicken, broccolini and potatoes at lunch against chicken, broccoli and gnocchi that
        // evening: 0.579, with the next different meal at 0.690. Alike, and not the same meal.
        let gnocchiDinner = meal("Chicken with broccoli and gnocchi", daysAgo: 0.25, prints: [[0.579, 0]])
        let riceDinner = meal("Chicken with broccoli and rice", daysAgo: 1, prints: [[0, 0.690]])
        XCTAssertNil(RepeatPhotoMeal.match([[0, 0]], candidates: [gnocchiDinner, riceDinner], now: now),
                     "it was proposed while the ratio was 0.85")
    }

    func testTheSameMealLoggedTwiceIsNoConfusion() {
        let older = meal("Usual oats", daysAgo: 9, prints: [[0.20, 0]])
        let newer = meal("Usual oats", daysAgo: 2, prints: [[0, 0.25]])
        let found = RepeatPhotoMeal.match([[0, 0]], candidates: [older, newer], now: now)
        XCTAssertEqual(found?.meal.id, older.meal.id, "the closest wins; its twin isn't a different meal")
    }

    func testATieGoesToTheMostRecent() {
        let older = meal("Usual oats", daysAgo: 9, prints: [[0.2, 0]])
        let newer = meal("Usual oats", daysAgo: 2, prints: [[0, 0.2]])
        let newest = meal("Usual oats", daysAgo: 1, prints: [[0, 0.205]])
        XCTAssertEqual(RepeatPhotoMeal.match([[0, 0]], candidates: [older, newest, newer], now: now)?.meal.id, newest.meal.id)
    }

    func testMealsWithNothingInThemTooOldOrMissingAPhotoAreIgnored() {
        let empty = meal("Oats", daysAgo: 1, prints: [[0.05, 0]], items: 0)
        let old = meal("Oats", daysAgo: 121, prints: [[0.05, 0]])
        var missing = meal("Oats", daysAgo: 1, prints: [[0.05, 0]])
        missing.meal.photoIDs.append(UUID())   // a second photo not on this device
        let noPhotos = (meal: MealEntry(date: now, items: [MealItem(name: "Oats", serving: "", macros: .init(calories: 1))]),
                        prints: [[Float]]())
        XCTAssertNil(RepeatPhotoMeal.match([[0, 0]], candidates: [empty, old, missing, noPhotos], now: now))
        let recent = meal("Oats", daysAgo: 119, prints: [[0.3, 0]])
        XCTAssertEqual(RepeatPhotoMeal.match([[0, 0]], candidates: [empty, old, missing, recent], now: now)?.meal.id,
                       recent.meal.id)
    }

    func testSameMealByNameWordsOrFoods() {
        let a = MealEntry(items: [MealItem(name: "Oats", serving: "", macros: .init()), MealItem(name: "Berries", serving: "", macros: .init())],
                          note: "", name: "Breakfast bowl")
        var b = a
        b.id = UUID()
        b.items = [MealItem(name: "berries", serving: "", macros: .init()), MealItem(name: "OATS", serving: "", macros: .init())]
        b.name = ""
        XCTAssertTrue(RepeatPhotoMeal.sameMeal(a, b), "the same foods")
        b.items = [MealItem(name: "Granola", serving: "", macros: .init())]
        XCTAssertFalse(RepeatPhotoMeal.sameMeal(a, b))
        b.name = "breakfast  bowl"
        XCTAssertTrue(RepeatPhotoMeal.sameMeal(a, b), "the same name")
    }

    // MARK: The proposal

    func testTheProposalCopiesTheMealWithNewIDs() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let breakfastTime = calendar.date(bySettingHour: 8, minute: 15, second: 0, of: now)!
        let reference = FoodReference(id: "fndds:1", name: "Oats", per100g: .init(calories: 380))
        let past = MealEntry(date: breakfastTime,
                             items: [MealItem(name: "Oats", serving: "1 cup", macros: .init(calories: 300), grams: 80, reference: reference),
                                     MealItem(name: "Coffee", serving: "1 cup", macros: .init(calories: 5))],
                             source: .photo, name: "Usual oats", photoIDs: [UUID()])
        let proposal = RepeatPhotoMeal.proposal(copying: past, calendar: calendar)
        XCTAssertEqual(proposal.name, "Usual oats")
        XCTAssertEqual(proposal.repeatOf, past.id)
        XCTAssertEqual(proposal.items.map(\.name), ["Oats", "Coffee"])
        XCTAssertEqual(proposal.items.map(\.grams), [80, nil])
        XCTAssertEqual(proposal.items.first?.reference, reference)
        XCTAssertTrue(Set(proposal.items.map(\.id)).isDisjoint(with: past.items.map(\.id)), "copied items get new ids")
        XCTAssertEqual(proposal.estimator, GroundedFoodEstimate.version)
        XCTAssertEqual(proposal.estimate?.from, .repeatedPhoto)
        XCTAssertEqual(proposal.estimate?.estimator, GroundedFoodEstimate.version)
        XCTAssertEqual(proposal.estimate?.foods.map(\.itemID), proposal.items.map(\.id))
        XCTAssertEqual(proposal.estimate?.foods.map(\.amount), [.repeated, .repeated])
        XCTAssertEqual(proposal.warnings.count, 1)
        let warning = proposal.warnings[0]
        XCTAssertTrue(warning.hasPrefix("Looks like your \(breakfastTime.formatted(.dateTime.weekday(.wide)))"), warning)
        XCTAssertTrue(warning.hasSuffix(" breakfast"), warning)
    }

    func testAnUnnamedMealIsNamedForItsFoods() {
        let past = MealEntry(items: [MealItem(name: "Rice", serving: "", macros: .init(calories: 200))], photoIDs: [UUID()])
        XCTAssertEqual(RepeatPhotoMeal.proposal(copying: past).name, "Rice")
    }

    func testMealWordFromTheTimeOfDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func at(_ hour: Int) -> Date { calendar.date(bySettingHour: hour, minute: 30, second: 0, of: now)! }
        XCTAssertEqual(RepeatPhotoMeal.mealWord(at: at(7), calendar: calendar), "breakfast")
        XCTAssertEqual(RepeatPhotoMeal.mealWord(at: at(12), calendar: calendar), "lunch")
        XCTAssertEqual(RepeatPhotoMeal.mealWord(at: at(16), calendar: calendar), "meal")
        XCTAssertEqual(RepeatPhotoMeal.mealWord(at: at(19), calendar: calendar), "dinner")
        XCTAssertEqual(RepeatPhotoMeal.mealWord(at: at(23), calendar: calendar), "meal")
    }

    // MARK: Not the same

    func testNotTheSameEstimatesItFresh() {
        let past = MealEntry(items: [MealItem(name: "Oats", serving: "", macros: .init(calories: 300))], photoIDs: [UUID()])
        let item = MealInboxItem(eatenAt: now, photos: [MealPhotoRef()], state: .proposed, origin: .scanned,
                                 proposal: RepeatPhotoMeal.proposal(copying: past), failure: "old")
        let fresh = RepeatPhotoMeal.notTheSame(item)
        XCTAssertTrue(fresh.notTheSame)
        XCTAssertEqual(fresh.state, .ready)
        XCTAssertNil(fresh.proposal)
        XCTAssertNil(fresh.failure)
        XCTAssertEqual(fresh.photos, item.photos)
    }

    func testNotTheSameAndRepeatOfSurviveTheRoundTrip() throws {
        let past = MealEntry(items: [MealItem(name: "Oats", serving: "", macros: .init(calories: 300))], photoIDs: [UUID()])
        var item = MealInboxItem(eatenAt: now, photos: [MealPhotoRef()], state: .proposed, origin: .scanned,
                                 proposal: RepeatPhotoMeal.proposal(copying: past))
        item.notTheSame = true
        let decoded = try JSONDecoder().decode(MealInboxItem.self, from: JSONEncoder().encode(item))
        XCTAssertTrue(decoded.notTheSame)
        XCTAssertEqual(decoded.proposal?.repeatOf, past.id)
        XCTAssertEqual(decoded.proposal?.estimate?.from, .repeatedPhoto)
        XCTAssertEqual(decoded, item)
    }

    func testAnOlderRecordWithoutNotTheSameReadsAsFalse() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","eatenAt":0,"state":"proposed","origin":"scanned","#
            + #""proposal":{"name":"Oats","items":[],"warnings":[],"madeAt":0}}"#
        let item = try JSONDecoder().decode(MealInboxItem.self, from: Data(json.utf8))
        XCTAssertFalse(item.notTheSame)
        XCTAssertEqual(item.proposal?.name, "Oats")
        XCTAssertNil(item.proposal?.repeatOf)
        let marked = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","eatenAt":0,"state":"ready","origin":"scanned","notTheSame":true}"#
        XCTAssertTrue(try JSONDecoder().decode(MealInboxItem.self, from: Data(marked.utf8)).notTheSame)
    }
}

/// The prints' cache: one file per photo and revision, kept only on this device.
final class MealPhotoPrintsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("prints-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testAPrintIsKeptByPhotoAndRevision() async {
        let prints = MealPhotoPrints(directory: directory)
        let id = UUID()
        await prints.store([0.25, -0.5, 1], id)
        XCTAssertTrue(prints.url(id).lastPathComponent.hasSuffix(".r\(MealPhotoPrints.revision).print"))
        // A fresh cache reads it from disk, without the photo.
        let again = MealPhotoPrints(directory: directory)
        let read = await again.prints([id: directory.appendingPathComponent("no-such-photo.jpg")])
        XCTAssertEqual(read[id], [0.25, -0.5, 1])
    }

    func testAPhotoNotHereHasNoPrint() async {
        let prints = MealPhotoPrints(directory: directory)
        let read = await prints.prints([UUID(): directory.appendingPathComponent("missing.jpg")])
        XCTAssertTrue(read.isEmpty)
    }

    func testPruningDropsUnreferencedPhotosAndOtherRevisions() async throws {
        let prints = MealPhotoPrints(directory: directory)
        let kept = UUID(), gone = UUID()
        await prints.store([1, 2], kept)
        await prints.store([3, 4], gone)
        let oldRevision = directory.appendingPathComponent("\(kept.uuidString).r1.print")
        try Data([0, 0, 128, 63]).write(to: oldRevision)
        await prints.prune(keeping: [kept])
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(left, [prints.url(kept).lastPathComponent])
        let stillGone = await prints.stored(gone)
        XCTAssertNil(stillGone)
    }

    /// Vision's print of a drawn plate, if this machine makes one (the Simulator may not): its
    /// distance must be what Vision itself computes, since the threshold was measured with it.
    func testDistanceAgreesWithVision() throws {
        func plate(_ food: CGColor, _ shift: CGFloat) -> CGImage {
            let context = CGContext(data: nil, width: 400, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: 0.5, green: 0.35, blue: 0.25, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 400))
            context.setFillColor(CGColor(red: 0.97, green: 0.97, blue: 0.95, alpha: 1))
            context.fillEllipse(in: CGRect(x: 30, y: 30, width: 340, height: 340))
            context.setFillColor(food)
            context.fillEllipse(in: CGRect(x: 110 + shift, y: 120, width: 180, height: 140))
            return context.makeImage()!
        }
        let images = [plate(CGColor(red: 0.8, green: 0.3, blue: 0.1, alpha: 1), 0),
                      plate(CGColor(red: 0.2, green: 0.6, blue: 0.2, alpha: 1), 30)]
        var observations: [VNFeaturePrintObservation] = []
        for image in images {
            let request = VNGenerateImageFeaturePrintRequest()
            request.revision = MealPhotoPrints.revision
            try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            guard let observation = request.results?.first else { throw XCTSkip("no feature prints here") }
            observations.append(observation)
        }
        var vision: Float = 0
        try observations[0].computeDistance(&vision, to: observations[1])
        let a = MealPhotoPrints.floats(observations[0]), b = MealPhotoPrints.floats(observations[1])
        XCTAssertEqual(a.count, observations[0].elementCount)
        XCTAssertEqual(RepeatPhotoMeal.distance(a, b), vision, accuracy: 1e-4)
        XCTAssertEqual(MealPhotoPrints.make(images[0])?.count, a.count)
    }

    /// Their words win over a look-alike photo.
    func testWordsThatDisagreeKeepThePhotoFromBeingCopied() {
        let pasta = MealEntry(items: [MealItem(name: "Penne arrabbiata", serving: "", macros: .init(calories: 600))],
                              name: "Pasta night")
        XCTAssertTrue(RepeatPhotoMeal.wordsAgree("", with: pasta))
        XCTAssertTrue(RepeatPhotoMeal.wordsAgree("the arrabbiata again", with: pasta))
        XCTAssertFalse(RepeatPhotoMeal.wordsAgree("chicken salad", with: pasta))
    }
}
