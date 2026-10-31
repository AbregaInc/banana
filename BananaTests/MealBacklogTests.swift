import ImageIO
import UniformTypeIdentifiers
import XCTest

final class MealPhotoGroupingTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    func testPhotosCloseTogetherAreOneMealAndUndatedStandAlone() {
        let photos: [(String, Date?)] = [
            ("dessert", base.addingTimeInterval(40 * 60)),
            ("plate", base),
            ("dinner", base.addingTimeInterval(6 * 3_600)),
            ("screenshot", nil),
            ("drink", base.addingTimeInterval(80 * 60)),
        ]
        let groups = MealPhotoGrouping.group(photos, takenAt: { $0.1 }).map { $0.map(\.0) }
        XCTAssertEqual(groups, [["plate", "dessert", "drink"], ["dinner"], ["screenshot"]])
    }

    func testAGapLongerThanAMealStartsANewOne() {
        let photos = [base, base.addingTimeInterval(46 * 60)]
        XCTAssertEqual(MealPhotoGrouping.group(photos, takenAt: { $0 }).count, 2)
    }
}

final class MealLogTimeTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    func testAPastDayGoesAtTheMealsUsualTimeOrNoon() {
        let now = at(30, 9)
        XCTAssertEqual(MealLogTime.date(on: at(28, 0), part: .dinner, now: now, calendar: calendar), at(28, 19))
        XCTAssertEqual(MealLogTime.date(on: at(28, 0), part: nil, now: now, calendar: calendar), at(28, 12))
    }

    func testTodayIsNeverLaterThanNow() {
        let now = at(30, 11)
        XCTAssertEqual(MealLogTime.date(on: now, part: .lunch, now: now, calendar: calendar), now)
        XCTAssertEqual(MealLogTime.date(on: now, part: .breakfast, now: now, calendar: calendar), at(30, 8))
        XCTAssertEqual(MealLogTime.date(on: now, part: nil, now: now, calendar: calendar), now)
    }
}

final class MealTextSplitterTests: XCTestCase {
    private func split(_ text: String) -> [String] {
        MealTextSplitter.split(text).map { "\($0.part?.rawValue ?? "-"): \($0.text)" }
    }

    func testMealsNamedAfterTheFood() {
        XCTAssertEqual(split("oatmeal and coffee for breakfast, chicken caesar at lunch and two beers with dinner"),
                       ["breakfast: oatmeal, coffee", "lunch: chicken caesar", "dinner: two beers"])
    }

    func testMealsNamedFirstTakeWhatFollows() {
        XCTAssertEqual(split("Breakfast: eggs, toast\nLunch - salad with salmon\nDinner was pasta"),
                       ["breakfast: eggs, toast", "lunch: salad with salmon", "dinner: pasta"])
    }

    func testLinesWithoutMealsAreAMealEach() {
        XCTAssertEqual(split("protein shake\nturkey sandwich"), ["-: protein shake", "-: turkey sandwich"])
    }

    func testOnePlainPhraseIsOneMeal() {
        XCTAssertEqual(split("two eggs and toast"), ["-: two eggs and toast"])
    }

    func testLateNightBeatsNight() {
        XCTAssertEqual(split("late night: cereal"), ["lateNight: cereal"])
    }

    func testNoWordsNoMeals() {
        XCTAssertTrue(MealTextSplitter.split("  \n ; ").isEmpty)
    }
}

final class MealBacklogRoutingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(photos: Bool, by: String?, secondsAgo: TimeInterval, state: MealInboxItem.State = .ready) -> MealInboxItem {
        MealInboxItem(eatenAt: now, photos: photos ? [MealPhotoRef()] : [], state: state, origin: .picked,
                      readiedBy: by, readiedAt: by == nil ? nil : now.addingTimeInterval(-secondsAgo))
    }

    private let phone = MealBacklogRouting.Here(installID: "phone", isHub: true, canReadPhotos: true, canReadText: true)
    private let mac = MealBacklogRouting.Here(installID: "mac", isHub: false, canReadPhotos: false, canReadText: true)
    private let pad = MealBacklogRouting.Here(installID: "pad", isHub: false, canReadPhotos: true, canReadText: true)

    func testTheDeviceThatReadiedItEstimatesIt() {
        XCTAssertTrue(MealBacklogRouting.shouldEstimate(item(photos: true, by: "pad", secondsAgo: 0), here: pad, now: now))
        XCTAssertFalse(MealBacklogRouting.shouldEstimate(item(photos: true, by: "pad", secondsAgo: 0), here: phone, now: now))
    }

    func testAPhotoAnsweredOnTheMacGoesToThePhone() {
        let answered = item(photos: true, by: "mac", secondsAgo: 5)
        XCTAssertFalse(MealBacklogRouting.shouldEstimate(answered, here: mac, now: now), "the Mac can't read photos")
        XCTAssertFalse(MealBacklogRouting.shouldEstimate(answered, here: phone, now: now), "not before the handoff")
        let later = item(photos: true, by: "mac", secondsAgo: 120)
        XCTAssertTrue(MealBacklogRouting.shouldEstimate(later, here: phone, now: now))
        XCTAssertFalse(MealBacklogRouting.shouldEstimate(later, here: pad, now: now))
        XCTAssertTrue(MealBacklogRouting.shouldEstimate(item(photos: true, by: "mac", secondsAgo: 700), here: pad, now: now))
    }

    func testWordsOnTheMacAreEstimatedThere() {
        XCTAssertTrue(MealBacklogRouting.shouldEstimate(item(photos: false, by: "mac", secondsAgo: 0), here: mac, now: now))
    }

    func testOnlyReadyMealsAreEstimated() {
        XCTAssertFalse(MealBacklogRouting.shouldEstimate(item(photos: true, by: "phone", secondsAgo: 0, state: .awaitingNote),
                                                         here: phone, now: now))
    }
}

final class RepeatMealTests: XCTestCase {
    func testTheSameWordsFindTheLatestMealDescribedThatWay() {
        let old = MealEntry(date: Date(timeIntervalSince1970: 100), items: [MealItem(name: "Oats", serving: "", macros: .init(calories: 300))],
                            note: "Usual breakfast!")
        let new = MealEntry(date: Date(timeIntervalSince1970: 200), items: [MealItem(name: "Oats", serving: "", macros: .init(calories: 350))],
                            note: "usual breakfast")
        XCTAssertEqual(RepeatMeal.match("usual  breakfast", in: [old, new])?.id, new.id)
        XCTAssertNil(RepeatMeal.match("breakfast", in: [old, new]))
        XCTAssertNil(RepeatMeal.match("ok", in: [old, new]), "too short to mean anything")
    }

    func testAMealsNameCounts() {
        let shake = MealEntry(items: [MealItem(name: "Whey", serving: "", macros: .init(calories: 120))], name: "Protein shake")
        XCTAssertEqual(RepeatMeal.match("protein shake", in: [shake])?.id, shake.id)
    }
}

final class NutritionSanityTests: XCTestCase {
    func testCaloriesThatDontMatchTheMacrosAreFlagged() {
        let off = MealItem(name: "Bowl", serving: "", macros: .init(calories: 900, proteinGrams: 20, carbohydrateGrams: 40, fatGrams: 10))
        XCTAssertEqual(NutritionSanity.warnings(for: off).count, 1)
        let fine = MealItem(name: "Bowl", serving: "", macros: .init(calories: 330, proteinGrams: 20, carbohydrateGrams: 40, fatGrams: 10))
        XCTAssertTrue(NutritionSanity.warnings(for: fine).isEmpty)
    }

    func testAlcoholIsntExpectedToMatch() {
        let beer = MealItem(name: "IPA beer", serving: "", macros: .init(calories: 200, proteinGrams: 2, carbohydrateGrams: 15))
        XCTAssertTrue(NutritionSanity.warnings(for: beer).isEmpty)
    }

    func testImpossibleDensityAndHugePortions() {
        let dense = MealItem(name: "Nuts", serving: "", macros: .init(calories: 1_000, proteinGrams: 20, carbohydrateGrams: 20, fatGrams: 100),
                             grams: 50)
        XCTAssertTrue(NutritionSanity.warnings(for: dense).contains { $0.contains("more calories than") })
        let huge = MealItem(name: "Soup", serving: "", macros: .init(calories: 800, proteinGrams: 40, carbohydrateGrams: 100, fatGrams: 25),
                            grams: 2_000)
        XCTAssertTrue(NutritionSanity.warnings(for: huge).contains { $0.contains("a lot for one item") })
    }
}

final class MealItemGramsTests: XCTestCase {
    private let rice = FoodReference(id: "fndds:1", name: "Rice, white, cooked",
                                     per100g: .init(calories: 130, proteinGrams: 2.7, carbohydrateGrams: 28, fatGrams: 0.3))

    func testADatabaseItemFollowsItsReference() {
        let item = MealItem(name: "Rice", serving: "1 cup", macros: rice.macros(grams: 150), grams: 150, reference: rice)
        let bigger = item.withGrams(300)
        XCTAssertEqual(bigger.macros.calories, 390, accuracy: 0.001)
        XCTAssertEqual(bigger.grams, 300)
    }

    func testAnyOtherItemScalesInProportion() {
        let item = MealItem(name: "Stew", serving: "", macros: .init(calories: 400, proteinGrams: 30), grams: 200)
        XCTAssertEqual(item.withGrams(100).macros.calories, 200, accuracy: 0.001)
        XCTAssertEqual(item.withGrams(100).macros.proteinGrams, 15, accuracy: 0.001)
    }

    func testOldItemsAndMealsStillDecode() throws {
        let item = try JSONDecoder().decode(MealItem.self, from: Data(#"{"name":"Egg","macros":{"calories":72}}"#.utf8))
        XCTAssertNil(item.grams)
        XCTAssertNil(item.reference)
        let meal = try JSONDecoder().decode(MealEntry.self, from: Data(#"{"items":[{"name":"Egg"}]}"#.utf8))
        XCTAssertTrue(meal.photoIDs.isEmpty)
    }

    func testGramsAndReferenceRoundTrip() throws {
        let item = MealItem(name: "Rice", serving: "1 cup", macros: rice.macros(grams: 158), grams: 158, reference: rice)
        let decoded = try JSONDecoder().decode(MealItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(decoded, item)
    }
}

final class MealInboxItemTests: XCTestCase {
    func testAStateFromANewerBuildAsksAgainRatherThanDroppingTheMeal() throws {
        let json = #"{"id":"\#(UUID().uuidString)","eatenAt":0,"state":"somethingNew","origin":"scanned"}"#
        let item = try JSONDecoder().decode(MealInboxItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.state, .awaitingNote)
        XCTAssertEqual(item.origin, .scanned)
    }

    func testALoggedMealKeepsItsTimeWordsAndPhotos() {
        let photo = MealPhotoRef()
        let item = MealInboxItem(eatenAt: Date(timeIntervalSince1970: 5_000), photos: [photo], note: "curry",
                                 state: .proposed, origin: .scanned)
        let entry = MealBacklogDays.entry(for: item, items: [MealItem(name: "Curry", serving: "", macros: .init())], name: "Curry")
        XCTAssertEqual(entry.date, item.eatenAt)
        XCTAssertEqual(entry.note, "curry")
        XCTAssertEqual(entry.photoIDs, [photo.id])
        XCTAssertEqual(entry.source, .photo)
    }
}

final class MealPhotoImageTests: XCTestCase {
    /// A small JPEG carrying the EXIF a phone camera writes.
    private func jpeg(original: String?, offset: String?) -> Data {
        let context = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0.8, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        var exif: [CFString: Any] = [:]
        if let original { exif[kCGImagePropertyExifDateTimeOriginal] = original }
        if let offset { exif[kCGImagePropertyExifOffsetTimeOriginal] = offset }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyExifDictionary: exif] as CFDictionary)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    func testTheCameraTimeWithItsOffset() {
        let date = MealPhotoImage.captureDate(from: jpeg(original: "2026:09:28 12:41:07", offset: "+02:00"))
        XCTAssertEqual(date, ISO8601DateFormatter().date(from: "2026-09-28T10:41:07Z"))
    }

    func testTheCameraTimeWithoutAnOffsetIsLocal() {
        let zone = TimeZone(identifier: "America/Los_Angeles")!
        let date = MealPhotoImage.captureDate(from: jpeg(original: "2026:09:28 12:41:07", offset: nil), timeZone: zone)
        XCTAssertEqual(date, ISO8601DateFormatter().date(from: "2026-09-28T19:41:07Z"))
    }

    func testAPhotoThatDoesntSayHasNoDate() {
        XCTAssertNil(MealPhotoImage.captureDate(from: jpeg(original: nil, offset: nil)))
    }

    func testThePreparedCopyIsSmallerAndKeepsTheDate() throws {
        let prepared = try XCTUnwrap(MealPhotoImage.prepare(jpeg(original: "2026:09:28 12:41:07", offset: "+00:00"), maxPixels: 32))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(prepared.jpeg as CFData, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 32)
        XCTAssertEqual(prepared.takenAt, ISO8601DateFormatter().date(from: "2026-09-28T12:41:07Z"))
    }
}

final class GroundedFoodEstimateTests: XCTestCase {
    private let curry = FoodMatch(reference: FoodReference(id: "fndds:1", name: "Chicken curry",
                                                           per100g: .init(calories: 150, proteinGrams: 12, carbohydrateGrams: 6, fatGrams: 9)),
                                  category: "Mixed dishes", portions: [FoodPortion(label: "1 cup", grams: 235)])

    private func part(_ name: String, id: String, grams: Double, own: NutritionMacros = .init(), confidence: Double = 0.9) -> GroundedFoodEstimate.ModelPart {
        .init(name: name, foodID: id, grams: grams, portion: "1 cup", ownEstimate: own, confidence: confidence)
    }

    /// "1 cup" of it is USDA's cup of that food (235 g), not the model's guess of 300 g.
    func testTheChosenDatabaseFoodGivesTheNumbersForTheStatedAmount() {
        let items = GroundedFoodEstimate.resolve([part("chicken curry", id: "fndds:1", grams: 300)],
                                                 lookup: { $0 == "fndds:1" ? self.curry : nil })
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].name, "Chicken curry")
        XCTAssertEqual(items[0].macros.calories, 352.5, accuracy: 0.001)
        XCTAssertEqual(items[0].grams, 235)
        XCTAssertEqual(items[0].reference?.id, "fndds:1")
        XCTAssertEqual(items[0].serving, "1 cup \u{00B7} 235 g")
        XCTAssertEqual(items[0].confidence, GroundedFoodEstimate.groundedConfidence)
    }

    func testAnAmountItCantConvertKeepsTheModelsWeight() {
        var plate = part("chicken curry", id: "fndds:1", grams: 300)
        plate.portion = "1 plate"
        let items = GroundedFoodEstimate.resolve([plate], lookup: { $0 == "fndds:1" ? self.curry : nil })
        XCTAssertEqual(items[0].grams, 300)
        XCTAssertEqual(items[0].macros.calories, 450, accuracy: 0.001)
    }

    func testAnUnknownIdFallsBackToTheModelsOwnNumbersFlagged() {
        let own = NutritionMacros(calories: 220, proteinGrams: 4, carbohydrateGrams: 30, fatGrams: 9)
        let items = GroundedFoodEstimate.resolve([part("mystery cake", id: "fndds:404", grams: 90, own: own)],
                                                 lookup: { _ in nil })
        XCTAssertEqual(items[0].macros, own)
        XCTAssertNil(items[0].reference)
        XCTAssertLessThanOrEqual(items[0].confidence ?? 1, GroundedFoodEstimate.guessConfidence)
    }

    func testAPastCorrectionOutranksTheDatabase() {
        let fix = FoodCorrection(macros: .init(calories: 610), serving: "my bowl", observedCount: 2)
        let items = GroundedFoodEstimate.resolve([part("chicken curry", id: "fndds:1", grams: 300)],
                                                 lookup: { _ in self.curry },
                                                 learned: { $0 == "Chicken curry" ? fix : nil })
        XCTAssertEqual(items[0].macros.calories, 610)
        XCTAssertEqual(items[0].serving, "my bowl")
        XCTAssertEqual(items[0].confidence, 1.0)
    }

    func testNamelessPartsAreDropped() {
        XCTAssertTrue(GroundedFoodEstimate.resolve([part("  ", id: "", grams: 10)], lookup: { _ in nil }).isEmpty)
    }

    func testServingText() {
        XCTAssertEqual(GroundedFoodEstimate.serving("", grams: 158.4), "158 g")
        XCTAssertEqual(GroundedFoodEstimate.serving("200 g", grams: 200), "200 g")
        XCTAssertEqual(GroundedFoodEstimate.serving("2 slices", grams: nil), "2 slices")
        XCTAssertEqual(GroundedFoodEstimate.serving("", grams: nil), "1 serving")
    }

    func testThePromptSaysWhatItHas() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(GroundedFoodEstimate.mealPrompt(note: "", eatenAt: at, photoCount: 2).contains("there's no description"))
        XCTAssertTrue(GroundedFoodEstimate.mealPrompt(note: "pho", eatenAt: at, photoCount: 1).contains("The person wrote: pho"))
        XCTAssertFalse(GroundedFoodEstimate.mealPrompt(note: "pho", eatenAt: at, photoCount: 0).contains("photo"))
    }
}

final class DeviceSketchTests: XCTestCase {
    private let rice = FoodMatch(reference: FoodReference(id: "fndds:2", name: "Rice, white, cooked",
                                                          per100g: .init(calories: 130, proteinGrams: 2.7, carbohydrateGrams: 28, fatGrams: 0.3)),
                                 category: "Rice", portions: [])

    func testTheAppLooksUpWhatTheSmallModelNamed() {
        let sketches = [
            GroundedFoodEstimate.Sketch(name: "white rice cooked", grams: 150, portion: "1 cup",
                                        ownEstimate: .init(calories: 999)),
            GroundedFoodEstimate.Sketch(name: "grandma's special stew", grams: 300, portion: "1 bowl",
                                        ownEstimate: .init(calories: 420, proteinGrams: 30, carbohydrateGrams: 30, fatGrams: 18)),
        ]
        let parts = GroundedFoodEstimate.parts(fromSketches: sketches, search: { $0.contains("rice") ? [self.rice] : [] })
        let items = GroundedFoodEstimate.resolve(parts, lookup: { $0 == "fndds:2" ? self.rice : nil })
        XCTAssertEqual(items[0].reference?.id, "fndds:2")
        XCTAssertEqual(items[0].macros.calories, 195, accuracy: 0.001, "USDA's numbers, not the model's 999")
        XCTAssertNil(items[1].reference)
        XCTAssertEqual(items[1].macros.calories, 420, "nothing matched: the model's own, flagged")
        XCTAssertLessThan(items[1].confidence ?? 1, 0.9)
    }

    func testPicturesShrinkForTheSmallModel() {
        let context = CGContext(data: nil, width: 1280, height: 960, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = context.makeImage()!
        let small = GroundedFoodEstimate.scaled(image, maxPixels: 768)
        XCTAssertEqual(small.width, 768)
        XCTAssertEqual(small.height, 576)
        XCTAssertEqual(GroundedFoodEstimate.scaled(small, maxPixels: 1000).width, 768, "never enlarged")
    }
}

final class FoodMatchCoverageTests: XCTestCase {
    func testAMatchHasToNameMostOfIt() {
        XCTAssertTrue(GroundedFoodEstimate.covers(query: "white rice cooked", name: "Rice, white, cooked, no added fat"))
        XCTAssertTrue(GroundedFoodEstimate.covers(query: "chicken curry", name: "Chicken curry"))
        XCTAssertTrue(GroundedFoodEstimate.covers(query: "Pasta", name: "Pasta with sauce, NFS"))
        XCTAssertTrue(GroundedFoodEstimate.covers(query: "scrambled eggs", name: "Egg, scrambled"), "plurals")
        XCTAssertFalse(GroundedFoodEstimate.covers(query: "mango lassi", name: "Mango, raw"))
        XCTAssertFalse(GroundedFoodEstimate.covers(query: "chicken tikka masala", name: "Chicken, NFS"))
        XCTAssertTrue(GroundedFoodEstimate.covers(query: "a slice of cheese pizza", name: "Pizza, cheese, from restaurant"))
    }

    func testAPartialMatchFallsBackToTheModelsOwnFigures() {
        let mango = FoodMatch(reference: FoodReference(id: "fndds:9", name: "Mango, raw",
                                                       per100g: .init(calories: 60)), category: "Fruit", portions: [])
        let parts = GroundedFoodEstimate.parts(
            fromSketches: [.init(name: "mango lassi", grams: 250, portion: "1 glass",
                                 ownEstimate: .init(calories: 260, proteinGrams: 8, carbohydrateGrams: 45, fatGrams: 6))],
            search: { _ in [mango] })
        XCTAssertEqual(parts[0].foodID, "")
    }
}

/// Changing what a meal was said to be, after it's been estimated.
final class MealWordsTests: XCTestCase {
    private let proposal = MealProposal(name: "Curry", items: [MealItem(name: "Curry", serving: "", macros: .init(calories: 400))])

    func testNewWordsEstimateItAgain() {
        let item = MealInboxItem(eatenAt: Date(), photos: [MealPhotoRef()], note: "curry", state: .proposed,
                                 origin: .scanned, proposal: proposal)
        let changed = item.withNote("  lamb curry and rice ")
        XCTAssertEqual(changed?.note, "lamb curry and rice")
        XCTAssertEqual(changed?.state, .ready)
        XCTAssertNil(changed?.proposal, "the old estimate goes; the new words make a new one")
        XCTAssertEqual(changed?.id, item.id)
    }

    func testTheSameWordsChangeNothing() {
        let item = MealInboxItem(eatenAt: Date(), note: "curry", state: .proposed, origin: .typed, proposal: proposal)
        XCTAssertNil(item.withNote(" curry "))
    }

    func testEmptyWordsMeanThePhotoAloneButAWordsOnlyMealNeedsWords() {
        let photo = MealInboxItem(eatenAt: Date(), photos: [MealPhotoRef()], note: "curry", state: .failed, origin: .scanned,
                                  failure: "busy")
        XCTAssertEqual(photo.withNote("")?.note, "")
        XCTAssertNil(photo.withNote("")?.failure)
        let typed = MealInboxItem(eatenAt: Date(), note: "curry", state: .proposed, origin: .typed, proposal: proposal)
        XCTAssertNil(typed.withNote(""))
    }
}
