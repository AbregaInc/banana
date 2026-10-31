import XCTest

final class MealPhotoClassifierTests: XCTestCase {
    // Label sets as Vision gave them for real photos (see MealPhotoClassifier's doc comment).

    func testDishesCount() {
        XCTAssertTrue(MealPhotoClassifier.isMeal(labels: [("food", 0.93), ("pizza", 0.93), ("tableware", 0.15)]))
        // The lowest-scoring plate measured: a steak among mushrooms.
        XCTAssertTrue(MealPhotoClassifier.isMeal(labels: [("tableware", 0.88), ("plate", 0.88), ("food", 0.31)]))
        // A dish on its own counts even when its parent label comes out low.
        XCTAssertTrue(MealPhotoClassifier.isMeal(labels: [("sushi", 0.5), ("food", 0.1)]))
        XCTAssertTrue(MealPhotoClassifier.isMeal(labels: [("dessert", 0.66), ("cookie", 0.54)]))
    }

    func testDrinksCountOnTheirOwnLabels() {
        XCTAssertTrue(MealPhotoClassifier.isMeal(labels: [("drink", 0.96), ("wine", 0.96), ("food", 0)]))
        XCTAssertTrue(MealPhotoClassifier.isMeal(labels: [("drink", 0.53), ("beer", 0.52)]))
        XCTAssertTrue(MealPhotoClassifier.isMeal(labels: [("cocktail", 0.91), ("martini", 0.91)]))
        // An espresso cup from above: the lowest drink measured.
        XCTAssertTrue(MealPhotoClassifier.isMeal(labels: [("tableware", 0.99), ("drink", 0.28), ("coffee", 0.26)]))
    }

    func testWhereAMealHappensIsNotAMeal() {
        XCTAssertFalse(MealPhotoClassifier.isMeal(labels: [("interior_room", 0.64), ("restaurant", 0.64), ("table", 0.54)]))
        XCTAssertFalse(MealPhotoClassifier.isMeal(labels: [("tableware", 0.95), ("plate", 0.9), ("bowl", 0.6), ("dining_room", 0.5)]))
        XCTAssertFalse(MealPhotoClassifier.isMeal(labels: [("kitchen", 0.8), ("stove", 0.81), ("cookware", 0.5)]))
    }

    func testFoodNearbyButNotEatenIsNotAMeal() {
        // A fridge, and a farmers' market: the highest non-meals measured.
        XCTAssertFalse(MealPhotoClassifier.isMeal(labels: [("refrigerator", 0.89), ("food", 0.17), ("fruit", 0.17)]))
        XCTAssertFalse(MealPhotoClassifier.isMeal(labels: [("people", 0.94), ("outdoor", 0.91), ("food", 0.12)]))
        // A wheat field, a glass of water, herbs in a pot.
        XCTAssertFalse(MealPhotoClassifier.isMeal(labels: [("grain", 0.8), ("agriculture", 0.7)]))
        XCTAssertFalse(MealPhotoClassifier.isMeal(labels: [("drink", 0.9), ("liquid", 0.9), ("drinking_glass", 0.9)]))
        XCTAssertFalse(MealPhotoClassifier.isMeal(labels: [("herb", 0.7), ("plant", 0.8)]))
        XCTAssertFalse(MealPhotoClassifier.isMeal(labels: []))
    }
}

final class MealPhotoScanSelectionTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func asset(_ id: String, _ minutes: Double?, screenshot: Bool = false) -> MealPhotoAsset {
        MealPhotoAsset(id: id, createdAt: minutes.map { start.addingTimeInterval($0 * 60) }, isScreenshot: screenshot)
    }

    func testPicksNewPhotosSinceTheStartNewestFirst() {
        let assets = [
            asset("lunch", 60),
            asset("before", -5),
            asset("screenshot", 70, screenshot: true),
            asset("known", 80),
            asset("seen", 90),
            asset("undated", nil),
            asset("dinner", 400),
        ]
        let plan = MealPhotoScanSelection.select(assets, skipping: ["known", "seen"], from: start, cap: 10)
        XCTAssertEqual(plan, .init(ids: ["dinner", "lunch"], remaining: 0))
    }

    func testCapLeavesTheRestForTheNextPass() {
        let assets = (0..<5).map { asset("p\($0)", Double($0)) }
        let plan = MealPhotoScanSelection.select(assets, skipping: [], from: start, cap: 2)
        XCTAssertEqual(plan.ids, ["p4", "p3"])
        XCTAssertEqual(plan.remaining, 3)
    }
}

final class MealPhotoScanStateTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private let since = Date(timeIntervalSince1970: 1_800_000_000)

    func testWindowStartsAtTheStartUntilAPassGetsThrough() {
        var state = MealPhotoScanState()
        XCTAssertEqual(state.windowStart(since: since), since)

        let passAt = since.addingTimeInterval(10 * day)
        state.record(.init(startedAt: passAt, complete: true), since: since)
        XCTAssertEqual(state.windowStart(since: since), passAt.addingTimeInterval(-day), "a day before the last pass")

        // A start moved later than that wins; moved earlier than anything looked at, it starts over.
        let later = since.addingTimeInterval(9.5 * day)
        XCTAssertEqual(state.windowStart(since: later), later)
        let earlier = since.addingTimeInterval(-5 * day)
        XCTAssertEqual(state.windowStart(since: earlier), earlier)
    }

    func testAPassCutShortDoesNotMoveTheWindow() {
        var state = MealPhotoScanState()
        let passAt = since.addingTimeInterval(10 * day)
        state.record(.init(startedAt: passAt, classified: ["a": since.addingTimeInterval(day)],
                           remaining: 40, complete: false), since: since)
        XCTAssertNil(state.lastPass)
        XCTAssertEqual(state.lastCheck, passAt)
        XCTAssertEqual(state.remaining, 40)
        XCTAssertEqual(state.windowStart(since: since), since)
        XCTAssertEqual(state.seen.keys.sorted(), ["a"], "kept: the next pass still looks from the start")
    }

    func testForgetsWhatNoPassWillLookAtAgain() {
        var state = MealPhotoScanState()
        let passAt = since.addingTimeInterval(10 * day)
        state.record(.init(
            startedAt: passAt,
            classified: ["old": since.addingTimeInterval(2 * day), "recent": passAt.addingTimeInterval(-3_600)],
            food: ["oldMeal": since.addingTimeInterval(2 * day)],
            newMeals: 1, complete: true), since: since)
        // Seen photos from before the next window go; a photo that became a meal stays while the
        // start date covers it, so a meal logged or dismissed is never found again.
        XCTAssertEqual(state.seen.keys.sorted(), ["recent"])
        XCTAssertEqual(state.found.keys.sorted(), ["oldMeal"])
        XCTAssertTrue(state.skipping.isSuperset(of: ["recent", "oldMeal"]))

        let laterStart = since.addingTimeInterval(5 * day)
        state.record(.init(startedAt: passAt.addingTimeInterval(3_600), complete: true), since: laterStart)
        XCTAssertTrue(state.found.isEmpty)
    }

    func testPrunedDropsOnlyWhatIsBeforeTheCutoff() {
        let ids = ["a": since.addingTimeInterval(-1), "b": since, "c": since.addingTimeInterval(1)]
        XCTAssertEqual(MealPhotoScanState.pruned(ids, before: since).keys.sorted(), ["b", "c"])
    }

    func testMealsFoundCountFromTheStartDate() {
        var state = MealPhotoScanState()
        state.record(.init(startedAt: since.addingTimeInterval(day), newMeals: 2, complete: true), since: since)
        state.record(.init(startedAt: since.addingTimeInterval(2 * day), newMeals: 1, complete: true), since: since)
        XCTAssertEqual(state.meals(countingFrom: since), 3)

        let moved = since.addingTimeInterval(-3 * day)
        XCTAssertEqual(state.meals(countingFrom: moved), 0)
        state.record(.init(startedAt: since.addingTimeInterval(3 * day), newMeals: 4, complete: true), since: moved)
        XCTAssertEqual(state.meals(countingFrom: moved), 4)
    }

    func testStateSurvivesARoundTrip() throws {
        var state = MealPhotoScanState()
        state.record(.init(startedAt: since, classified: ["x": since], food: ["x": since], newMeals: 1,
                           remaining: 2, complete: false), since: since)
        let decoded = try JSONDecoder().decode(MealPhotoScanState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded, state)
    }

    func testTurningItOnStartsTwoWeeksBackAtTheStartOfTheDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 15, minute: 12))!
        let expected = calendar.date(from: DateComponents(year: 2026, month: 9, day: 16))!
        XCTAssertEqual(MealPhotoScanPrefs.defaultSince(now: now, calendar: calendar), expected)
        XCTAssertEqual(MealPhotoScanPrefs(enabled: true, since: nil).effectiveSince(now: now, calendar: calendar), expected)
    }
}

final class MealPhotoScanMergeTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func photo(_ minutes: Double) -> MealPhotoRef {
        MealPhotoRef(takenAt: base.addingTimeInterval(minutes * 60), assetID: "asset-\(minutes)")
    }

    private func item(_ minutes: [Double], state: MealInboxItem.State = .awaitingNote,
                      origin: MealInboxItem.Origin = .scanned) -> MealInboxItem {
        let photos = minutes.map(photo)
        return MealInboxItem(eatenAt: photos.compactMap(\.takenAt).min() ?? base, photos: photos,
                             state: state, origin: origin)
    }

    func testPhotosCloseToAWaitingScannedMealJoinIt() {
        let lunch = item([0, 10])
        let dessert = [photo(50)]
        XCTAssertEqual(MealPhotoScanMerge.plan(groups: [dessert], existing: [lunch]), [.join(lunch.id, dessert)])
        // Before it counts too: the drink ordered before the plate came.
        let drink = [photo(-40)]
        XCTAssertEqual(MealPhotoScanMerge.plan(groups: [drink], existing: [lunch]), [.join(lunch.id, drink)])
    }

    func testFarPhotosAreAMealOfTheirOwn() {
        let lunch = item([0])
        let dinner = [photo(6 * 60)]
        XCTAssertEqual(MealPhotoScanMerge.plan(groups: [dinner], existing: [lunch]), [.new(dinner)])
    }

    func testOnlyScannedMealsStillWaitingForWordsAreJoined() {
        let group = [photo(20)]
        for existing in [item([0], state: .ready), item([0], state: .proposed), item([0], origin: .picked)] {
            XCTAssertEqual(MealPhotoScanMerge.plan(groups: [group], existing: [existing]), [.new(group)])
        }
    }

    func testTheNearestWaitingMealWins() {
        let early = item([10])
        let late = item([80])
        let group = [photo(50)]   // 40 min after one, 30 before the other
        XCTAssertEqual(MealPhotoScanMerge.plan(groups: [group], existing: [early, late]), [.join(late.id, group)])
    }

    func testGroupsEitherSideJoinTheSameMeal() {
        let dinner = item([0, 10])
        let aperitif = [photo(-40)]
        let dessert = [photo(55)]
        XCTAssertEqual(MealPhotoScanMerge.plan(groups: [aperitif, dessert], existing: [dinner]),
                       [.join(dinner.id, aperitif), .join(dinner.id, dessert)])
    }

    func testAJoinedMealReachesFurtherForTheNextGroup() {
        let lunch = item([0])
        let second = [photo(40)]
        let third = [photo(84)]   // 84 min after the plate, 44 after the second group
        XCTAssertEqual(MealPhotoScanMerge.plan(groups: [second, third], existing: [lunch]),
                       [.join(lunch.id, second), .join(lunch.id, third)])
    }

    func testUndatedGroupsStandAlone() {
        let undated = [MealPhotoRef(takenAt: nil, assetID: "x")]
        XCTAssertEqual(MealPhotoScanMerge.plan(groups: [undated], existing: [item([0])]), [.new(undated)])
    }
}

final class MealPhotoScanTextTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/London")!
        return c
    }()
    private let locale = Locale(identifier: "en_GB")

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    private func title(_ eatenAt: Date, now: Date) -> String {
        MealPhotoNotificationText.title(eatenAt: eatenAt, now: now, calendar: calendar, locale: locale)
    }

    func testTheQuestionSaysWhenTheMealWas() {
        let now = at(30, 15)
        XCTAssertEqual(title(at(30, 12, 40), now: now), "What did you eat at 12:40?")
        XCTAssertEqual(title(at(29, 19, 5), now: now), "What did you eat yesterday at 19:05?")
        XCTAssertEqual(title(at(27, 8, 10), now: now), "What did you eat on Sunday at 08:10?")
        let older = title(at(20, 13), now: now)
        XCTAssertTrue(older.hasPrefix("What did you eat on 20 Sep"), older)
        XCTAssertTrue(older.hasSuffix(" at 13:00?"), older)
    }

    func testTheBodyCountsPhotos() {
        XCTAssertEqual(MealPhotoNotificationText.body(photoCount: 1), "1 photo")
        XCTAssertEqual(MealPhotoNotificationText.body(photoCount: 3), "3 photos")
    }

    func testOnlyRecentMealsAreAskedAboutNewestFirst() {
        let now = at(30, 15)
        let old = MealInboxItem(eatenAt: at(20, 13), state: .awaitingNote, origin: .scanned)
        let answered = MealInboxItem(eatenAt: at(30, 12), state: .ready, origin: .scanned)
        let recent = (0..<6).map { MealInboxItem(eatenAt: at(30, 8 + $0), state: .awaitingNote, origin: .scanned) }
        let asked = MealPhotoNotificationPolicy.worthAsking([old, answered] + recent, now: now)
        XCTAssertEqual(asked.map(\.eatenAt), [at(30, 13), at(30, 12), at(30, 11), at(30, 10)])
    }

    func testStatusLineForThisDevice() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let checked = MealPhotoScanReport(access: .full, checkedAt: now.addingTimeInterval(-5 * 60), found: 3, remaining: 0)
        XCTAssertEqual(MealPhotoScanStatusText.line(enabled: true, report: checked, isMac: false, now: now),
                       "Checked 5 min ago \u{00B7} 3 meals found")
        XCTAssertEqual(MealPhotoScanStatusText.line(enabled: true, report: checked, isMac: false, checking: true, now: now),
                       "Checking your photos\u{2026}")
        var backfilling = checked
        backfilling.found = 1
        backfilling.remaining = 120
        XCTAssertEqual(MealPhotoScanStatusText.line(enabled: true, report: backfilling, isMac: true, now: now),
                       "Checked 5 min ago \u{00B7} 1 meal found \u{00B7} 120 more photos to check")
        var recent = checked
        recent.recentOnly = true
        XCTAssertEqual(MealPhotoScanStatusText.line(enabled: true, report: recent, isMac: false, now: now),
                       "Checked 5 min ago \u{00B7} 3 meals found \u{00B7} recent photos only \u{2014} your Mac does the rest")
        for access in [MealPhotoAccess.limited, .denied] {
            XCTAssertEqual(MealPhotoScanStatusText.line(enabled: true, report: .init(access: access), isMac: false, now: now),
                           "Allow full Photos access in Settings")
        }
        XCTAssertEqual(MealPhotoScanStatusText.line(enabled: true, report: .init(access: .denied), isMac: true, now: now),
                       "Allow Banana in System Settings \u{203A} Privacy & Security \u{203A} Photos")
        XCTAssertEqual(MealPhotoScanStatusText.line(enabled: true, report: nil, isMac: true, now: now),
                       "Waiting for access to your photos")
        XCTAssertNil(MealPhotoScanStatusText.line(enabled: false, report: checked, isMac: false, now: now))
    }

    func testTheOtherDevicesLooking() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reports: [String: MealPhotoScanReport] = [
            "me": .init(access: .full, checkedAt: now, device: "iPhone"),
            "mac": .init(access: .full, checkedAt: now.addingTimeInterval(-2 * 60), device: "Mac"),
            "pad": .init(access: .full, checkedAt: now.addingTimeInterval(-3 * 3_600), device: "iPad"),
            "old": .init(access: .full, checkedAt: now.addingTimeInterval(-9 * 86_400), device: "iPad"),
            "denied": .init(access: .denied, checkedAt: now, device: "Mac"),
        ]
        XCTAssertEqual(MealPhotoScanStatusText.others(reports, except: "me", now: now),
                       "Also looking: Mac, 2 min ago \u{00B7} iPad, 3 h ago")
        XCTAssertNil(MealPhotoScanStatusText.others(["me": reports["me"]!], except: "me", now: now))
    }

    func testAReportFromANewerDeviceStillReads() throws {
        let json = #"{"access": "someday", "found": 1, "device": "Mac", "somethingNew": true}"#
        let report = try JSONDecoder().decode(MealPhotoScanReport.self, from: Data(json.utf8))
        XCTAssertEqual(report.access, .notAsked)
        XCTAssertEqual(report.found, 1)
        XCTAssertEqual(report.device, "Mac")
    }

    func testAgo() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(MealPhotoScanStatusText.ago(now.addingTimeInterval(-20), now: now), "just now")
        XCTAssertEqual(MealPhotoScanStatusText.ago(now.addingTimeInterval(-59 * 60), now: now), "59 min ago")
        XCTAssertEqual(MealPhotoScanStatusText.ago(now.addingTimeInterval(-25 * 3_600), now: now), "yesterday")
        XCTAssertEqual(MealPhotoScanStatusText.ago(now.addingTimeInterval(-3 * 86_400), now: now), "3 days ago")
    }

}

final class MealPhotoSharingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testTheSamePhotoIsTheSameMealOnEveryDevice() {
        let key = MealPhotoIdentity.key(cloudIdentifier: "5C1E0A7B-0000-4000-8000-000000000001:001:AbCdEf")
        XCTAssertEqual(key.count, 32)
        XCTAssertEqual(key, MealPhotoIdentity.key(cloudIdentifier: "5C1E0A7B-0000-4000-8000-000000000001:001:AbCdEf"))
        XCTAssertEqual(MealPhotoIdentity.photoID(key: key), MealPhotoIdentity.photoID(key: key))
        XCTAssertNotEqual(MealPhotoIdentity.photoID(key: key), MealPhotoIdentity.photoID(key: key + "x"))

        let plate = MealPhotoRef(takenAt: now, cloudKey: "aaa")
        let dessert = MealPhotoRef(takenAt: now.addingTimeInterval(600), cloudKey: "bbb")
        // Named by the earliest photo, whichever order a device found them in.
        XCTAssertEqual(MealPhotoIdentity.mealID(photos: [plate, dessert]), MealPhotoIdentity.mealID(photos: [dessert, plate]))
        XCTAssertNotEqual(MealPhotoIdentity.mealID(photos: [plate]), MealPhotoIdentity.photoID(key: "aaa"),
                          "a meal and its photo never share an id")
        XCTAssertNil(MealPhotoIdentity.mealID(photos: [MealPhotoRef(takenAt: now)]), "no cloud key: a random id instead")
    }

    func testTheIPhoneLooksAtRecentPhotosWhileAMacKeepsUp() {
        let mac = MealPhotoScanReport(access: .full, checkedAt: now.addingTimeInterval(-10 * 60), device: "Mac", onPower: true)
        XCTAssertTrue(MealPhotoScanShare.macKeepingUp(["mac": mac], except: "phone", now: now))
        let own = now.addingTimeInterval(-14 * 86_400)
        XCTAssertEqual(MealPhotoScanShare.windowStart(own: own, onBattery: true, macKeepingUp: true, now: now),
                       now.addingTimeInterval(-MealPhotoScanShare.recent))
        XCTAssertEqual(MealPhotoScanShare.windowStart(own: own, onBattery: false, macKeepingUp: true, now: now), own,
                       "the Mac itself looks at everything")
        let recentOwn = now.addingTimeInterval(-3_600)
        XCTAssertEqual(MealPhotoScanShare.windowStart(own: recentOwn, onBattery: true, macKeepingUp: true, now: now), recentOwn)
    }

    func testAMacAsleepUnpluggedOrShutOutIsNotReliedOn() {
        let asleep = MealPhotoScanReport(access: .full, checkedAt: now.addingTimeInterval(-50 * 60), device: "Mac", onPower: true)
        let unplugged = MealPhotoScanReport(access: .full, checkedAt: now, device: "Mac", onPower: false)
        let denied = MealPhotoScanReport(access: .denied, checkedAt: now, device: "Mac", onPower: true)
        let pad = MealPhotoScanReport(access: .full, checkedAt: now, device: "iPad")
        XCTAssertFalse(MealPhotoScanShare.macKeepingUp(["a": asleep, "b": unplugged, "c": denied, "d": pad],
                                                       except: "phone", now: now))
        let fresh = MealPhotoScanReport(access: .full, checkedAt: now, device: "Mac", onPower: true)
        XCTAssertFalse(MealPhotoScanShare.macKeepingUp(["me": fresh], except: "me", now: now), "not itself")
        // A report from before power was reported still counts while its heartbeat is fresh.
        XCTAssertTrue(MealPhotoScanShare.macKeepingUp(["mac": .init(access: .full, checkedAt: now, device: "Mac")],
                                                      except: "phone", now: now))
    }

    func testTheMacPacesItselfByPower() {
        XCTAssertTrue(MealPhotoScanPace.timerLooks(.mains))
        for power in [MealPhotoScanPace.Power.battery, .lowPower, .hot] {
            XCTAssertFalse(MealPhotoScanPace.timerLooks(power))
        }
        XCTAssertEqual(MealPhotoScanPace.afterChange(.mains), 20)
        XCTAssertEqual(MealPhotoScanPace.afterChange(.battery), 120)
        XCTAssertNil(MealPhotoScanPace.afterChange(.lowPower))
        XCTAssertNil(MealPhotoScanPace.afterChange(.hot))
    }

    func testTheIPhoneAsksOnceAboutMealsFoundAnywhere() {
        let fresh = MealInboxItem(eatenAt: now.addingTimeInterval(-600), state: .awaitingNote, origin: .scanned)
        let alreadyAsked = MealInboxItem(eatenAt: now.addingTimeInterval(-900), state: .awaitingNote, origin: .scanned)
        let answered = MealInboxItem(eatenAt: now.addingTimeInterval(-300), note: "pho", state: .ready, origin: .scanned)
        let asked = MealPhotoNotificationPolicy.toAsk([fresh, alreadyAsked, answered], asked: [alreadyAsked.id], now: now)
        XCTAssertEqual(asked.map(\.id), [fresh.id])
    }

    func testTheBacklogHasAZoneOfItsOwn() {
        XCTAssertEqual(Set(ControlChannel.meals.kinds), [.mealInbox, .mealPhoto, .mealPhotoFound])
        XCTAssertFalse(ControlChannel.controls.kinds.contains(.mealInbox))
        XCTAssertEqual(Set(ControlChannel.controls.kinds).union(ControlChannel.meals.kinds), Set(ControlKind.allCases))
        XCTAssertEqual(ControlChannel.meals.zoneName, "Meals")
        XCTAssertEqual(ControlChannel.controls.zoneName, "Controls", "the zone everything else already lives in")
    }
}
