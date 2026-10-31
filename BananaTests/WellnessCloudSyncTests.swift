import XCTest

final class WellnessCloudSyncTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    private func meal(_ id: UUID = UUID(), at date: Date, _ name: String = "Eggs") -> MealEntry {
        MealEntry(id: id, date: date, items: [MealItem(name: name, serving: "2", macros: .init(calories: 150))])
    }

    // MARK: - Record names

    func testRecordNamesRoundTrip() {
        let id = UUID()
        for record in [WellnessCloudRecord.meal(id), .supplement(id), .dose(supplementID: id, day: "20260927")] {
            XCTAssertEqual(WellnessCloudRecord(name: record.name), record)
        }
    }

    func testUnknownOrMalformedNamesAreNotGuessed() {
        XCTAssertNil(WellnessCloudRecord(name: "workout-\(UUID().uuidString)"))
        XCTAssertNil(WellnessCloudRecord(name: "meal-not-a-uuid"))
        XCTAssertNil(WellnessCloudRecord(name: "dose-\(UUID().uuidString)-2026"))
        XCTAssertNil(WellnessCloudRecord(name: "dose-\(UUID().uuidString)-2026092x"))
        XCTAssertNil(WellnessCloudRecord(name: "health-cache"))
    }

    func testADoseIsNamedByItsSupplementAndDay() {
        let supplement = UUID()
        let morning = SupplementLog(supplementID: supplement, date: date(27, 8), status: .taken)
        let evening = SupplementLog(supplementID: supplement, date: date(27, 21), status: .skipped)
        let tomorrow = SupplementLog(supplementID: supplement, date: date(28, 8), status: .taken)
        // A change of mind the same day overwrites the same record on every device.
        XCTAssertEqual(WellnessCloudRecord.dose(morning, calendar: calendar).name,
                       WellnessCloudRecord.dose(evening, calendar: calendar).name)
        XCTAssertNotEqual(WellnessCloudRecord.dose(morning, calendar: calendar).name,
                          WellnessCloudRecord.dose(tomorrow, calendar: calendar).name)
        XCTAssertEqual(WellnessCloudRecord.dayKey(date(7, 23, 59), calendar: calendar), "20260907")
    }

    func testAStoredDayWinsOverTheTimeZoneNow() {
        let supplement = UUID()
        // Taken at 23:30 in New York on the 27th; in London that instant is already the 28th.
        let log = SupplementLog(supplementID: supplement, date: date(27, 23, 30), status: .taken, day: "20260927")
        var london = calendar
        london.timeZone = TimeZone(identifier: "Europe/London")!
        XCTAssertEqual(WellnessCloudRecord.dayKey(log.date, calendar: london), "20260928")
        XCTAssertEqual(WellnessCloudRecord.dose(log, calendar: london).name,
                       WellnessCloudRecord.dose(supplementID: supplement, day: "20260927").name)
    }

    func testTravelDoesNotMergeTwoDaysIntoOne() {
        var london = calendar
        london.timeZone = TimeZone(identifier: "Europe/London")!
        let supplement = UUID()
        let lateInNewYork = SupplementLog(supplementID: supplement, date: date(27, 23, 30), status: .taken, day: "20260927")
        var logs = [lateInNewYork]
        var meals: [MealEntry] = []
        var supplements: [SupplementSchedule] = []
        // The next morning's dose, logged in London, arrives from the other device.
        let nextMorning = SupplementLog(supplementID: supplement, date: date(28, 4), status: .taken, day: "20260928")
        WellnessCloudMerge.apply(.init(doses: [nextMorning]), meals: &meals, supplements: &supplements,
                                 logs: &logs, calendar: london)
        XCTAssertEqual(Set(logs), [lateInNewYork, nextMorning])
    }

    func testDoseDayRoundTripsAndOldLogsStillDecode() throws {
        let log = SupplementLog(supplementID: UUID(), date: date(27, 8), status: .skipped, day: "20260927")
        XCTAssertEqual(try JSONDecoder().decode(SupplementLog.self, from: JSONEncoder().encode(log)), log)
        let old = #"{"id":"\#(UUID().uuidString)","supplementID":"\#(UUID().uuidString)","date":0,"status":"taken"}"#
        XCTAssertNil(try JSONDecoder().decode(SupplementLog.self, from: Data(old.utf8)).day)
    }

    // MARK: - Payload and conflicts

    func testPayloadCarriesTheEditTime() throws {
        let meal = meal(at: date(27, 8))
        let edited = date(27, 9, 30)
        let data = try XCTUnwrap(WellnessCloudPayload.encode(meal, editedAt: edited))
        XCTAssertEqual(WellnessCloudPayload.editedAt(data), edited)
        let envelope = try XCTUnwrap(WellnessCloudPayload.decode(MealEntry.self, from: data))
        XCTAssertEqual(envelope.item, meal)
        XCTAssertEqual(envelope.editedAt, edited)
    }

    func testTheNewerEditWinsWhicheverUploadedFirst() {
        // Phone edited at 09:00, Mac at 09:30; the phone's copy reached the server later.
        XCTAssertEqual(WellnessCloudConflict.resolve(localEditedAt: date(27, 9, 30), remoteEditedAt: date(27, 9),
                                                     deletedHere: false), .keepLocal)
        XCTAssertEqual(WellnessCloudConflict.resolve(localEditedAt: date(27, 9), remoteEditedAt: date(27, 9, 30),
                                                     deletedHere: false), .adopt)
        XCTAssertEqual(WellnessCloudConflict.resolve(localEditedAt: date(27, 9), remoteEditedAt: date(27, 9),
                                                     deletedHere: false), .adopt, "the same edit: nothing to keep")
        XCTAssertEqual(WellnessCloudConflict.resolve(localEditedAt: nil, remoteEditedAt: WellnessCloudPayload.unedited,
                                                     deletedHere: false), .adopt)
    }

    func testADeleteOnItsWayIsNotUndoneByAnIncomingCopy() {
        XCTAssertEqual(WellnessCloudConflict.resolve(localEditedAt: nil, remoteEditedAt: date(27, 10),
                                                     deletedHere: true), .ignore)
    }

    // MARK: - Merge

    func testRemoteMealIsAddedOrReplacesTheSameIDAndNothingElseMoves() {
        let kept = meal(at: date(27, 8), "Toast")
        let edited = meal(at: date(27, 12), "Salad")
        var meals = [edited, kept]
        var supplements: [SupplementSchedule] = []
        var logs: [SupplementLog] = []
        var renamed = edited
        renamed.name = "Big salad"
        let added = meal(at: date(27, 19), "Pasta")
        WellnessCloudMerge.apply(.init(meals: [renamed, added]), meals: &meals,
                                 supplements: &supplements, logs: &logs, calendar: calendar)
        XCTAssertEqual(meals.map(\.id), [added.id, edited.id, kept.id], "newest first")
        XCTAssertEqual(meals[1].name, "Big salad")
        XCTAssertEqual(meals[2], kept)
    }

    func testOnlyAnExplicitDeletionRemovesAMeal() {
        let a = meal(at: date(27, 8)), b = meal(at: date(27, 9))
        var meals = [b, a]
        var supplements: [SupplementSchedule] = []
        var logs: [SupplementLog] = []
        // A batch that simply doesn't mention a meal leaves it alone.
        WellnessCloudMerge.apply(.init(meals: [meal(at: date(26, 8))]), meals: &meals,
                                 supplements: &supplements, logs: &logs, calendar: calendar)
        XCTAssertEqual(Set(meals.map(\.id)).isSuperset(of: [a.id, b.id]), true)
        WellnessCloudMerge.apply(.init(deletedMeals: [a.id]), meals: &meals,
                                 supplements: &supplements, logs: &logs, calendar: calendar)
        XCTAssertFalse(meals.contains { $0.id == a.id })
        XCTAssertTrue(meals.contains { $0.id == b.id })
    }

    func testMealMergeRetainsHistoryBeyondTheFormerCap() {
        var meals = (0..<2_000).map { meal(at: date(1, 0).addingTimeInterval(Double($0) * 60)) }
        let retainedIDs = Set(meals.map(\.id))
        var supplements: [SupplementSchedule] = []
        var logs: [SupplementLog] = []
        let newest = meal(at: date(28, 8))
        WellnessCloudMerge.apply(.init(meals: [newest]), meals: &meals,
                                 supplements: &supplements, logs: &logs, calendar: calendar)
        XCTAssertEqual(meals.count, 2_001)
        XCTAssertEqual(meals.first?.id, newest.id)
        XCTAssertEqual(Set(meals.map(\.id)), retainedIDs.union([newest.id]))
    }

    func testRemoteDoseReplacesThatDaysLogForThatSupplementOnly() {
        let vitaminD = UUID(), magnesium = UUID()
        let localTaken = SupplementLog(supplementID: vitaminD, date: date(27, 8), status: .taken)
        let yesterday = SupplementLog(supplementID: vitaminD, date: date(26, 8), status: .taken)
        let other = SupplementLog(supplementID: magnesium, date: date(27, 21), status: .taken)
        var logs = [other, localTaken, yesterday]
        var meals: [MealEntry] = []
        var supplements: [SupplementSchedule] = []
        // Another device marked today's dose skipped; its log has its own id.
        let remote = SupplementLog(supplementID: vitaminD, date: date(27, 9), status: .skipped)
        WellnessCloudMerge.apply(.init(doses: [remote]), meals: &meals,
                                 supplements: &supplements, logs: &logs, calendar: calendar)
        XCTAssertEqual(Set(logs), Set([other, remote, yesterday]))
    }

    func testDeletingASupplementTakesItsDosesWithIt() {
        let gone = SupplementSchedule(name: "Iron", hour: 9, minute: 0)
        let stays = SupplementSchedule(name: "Zinc", hour: 10, minute: 0)
        var supplements = [gone, stays]
        var logs = [SupplementLog(supplementID: gone.id, date: date(27, 9), status: .taken),
                    SupplementLog(supplementID: stays.id, date: date(27, 10), status: .taken)]
        var meals: [MealEntry] = []
        WellnessCloudMerge.apply(.init(deletedSupplements: [gone.id]), meals: &meals,
                                 supplements: &supplements, logs: &logs, calendar: calendar)
        XCTAssertEqual(supplements.map(\.id), [stays.id])
        XCTAssertEqual(logs.map(\.supplementID), [stays.id])
    }

    func testRemoteSupplementEditKeepsScheduleOrder() {
        let morning = SupplementSchedule(name: "Vitamin D", hour: 8, minute: 0)
        let night = SupplementSchedule(name: "Magnesium", hour: 21, minute: 30)
        var supplements = [morning, night]
        var moved = night
        moved.hour = 7
        var meals: [MealEntry] = []
        var logs: [SupplementLog] = []
        WellnessCloudMerge.apply(.init(supplements: [moved]), meals: &meals,
                                 supplements: &supplements, logs: &logs, calendar: calendar)
        XCTAssertEqual(supplements.map(\.name), ["Magnesium", "Vitamin D"])
    }

    func testDoseDeletionRemovesJustThatDay() {
        let id = UUID()
        var logs = [SupplementLog(supplementID: id, date: date(27, 8), status: .taken),
                    SupplementLog(supplementID: id, date: date(26, 8), status: .taken)]
        var meals: [MealEntry] = []
        var supplements: [SupplementSchedule] = []
        WellnessCloudMerge.apply(.init(deletedDoses: [.init(supplementID: id, day: "20260927")]),
                                 meals: &meals, supplements: &supplements, logs: &logs, calendar: calendar)
        XCTAssertEqual(logs.map { WellnessCloudRecord.dayKey($0.date, calendar: calendar) }, ["20260926"])
    }

    func testEmptyChangesTouchNothing() {
        XCTAssertTrue(WellnessCloudChanges().isEmpty)
        var meals = [meal(at: date(27, 8))]
        let before = meals
        var supplements: [SupplementSchedule] = []
        var logs: [SupplementLog] = []
        WellnessCloudMerge.apply(.init(), meals: &meals, supplements: &supplements, logs: &logs, calendar: calendar)
        XCTAssertEqual(meals, before)
    }

    // MARK: - Mac Nutrition days

    func testWindowIsTheLastSevenDaysWhileTheDayIsInIt() {
        let days = { (window: [Date]) in window.map { self.calendar.component(.day, from: $0) } }
        let today = date(27, 15)
        XCTAssertEqual(days(NutritionDays.window(for: today, today: today, calendar: calendar)), Array(21...27))
        XCTAssertEqual(days(NutritionDays.window(for: date(23, 9), today: today, calendar: calendar)), Array(21...27),
                       "moving back within the week keeps the strip still")
        XCTAssertEqual(days(NutritionDays.window(for: date(18, 9), today: today, calendar: calendar)), Array(12...18),
                       "further back, the week ends on the chosen day")
        XCTAssertEqual(days(NutritionDays.window(for: date(29, 9), today: today, calendar: calendar)), Array(21...27),
                       "never a day still to come")
    }

    func testDayMealsAndTotal() {
        let meals = [meal(at: date(27, 19)), meal(at: date(26, 8)), meal(at: date(27, 8))]
        let today = NutritionDays.meals(meals, on: date(27, 0), calendar: calendar)
        XCTAssertEqual(today.map(\.date), [date(27, 8), date(27, 19)], "in eating order")
        XCTAssertEqual(NutritionDays.total(today).calories, 300)
    }

    func testDoseDateIsNowTodayAndTheScheduledTimeForAPastDay() {
        let supplement = SupplementSchedule(name: "Vitamin D", hour: 8, minute: 30)
        let now = date(27, 22)
        XCTAssertEqual(NutritionDays.doseDate(for: supplement, on: date(27, 0), now: now, calendar: calendar), now)
        XCTAssertEqual(NutritionDays.doseDate(for: supplement, on: date(25, 0), now: now, calendar: calendar), date(25, 8, 30))
    }

    func testDayTitles() {
        let now = date(27, 15)
        XCTAssertEqual(NutritionDays.title(for: date(27, 1), now: now, calendar: calendar), "Today")
        XCTAssertEqual(NutritionDays.title(for: date(26, 23), now: now, calendar: calendar), "Yesterday")
        XCTAssertNotEqual(NutritionDays.title(for: date(24, 9), now: now, calendar: calendar), "Yesterday")
    }

    func testSteppingNeverPassesToday() {
        let now = date(27, 15)
        XCTAssertEqual(NutritionDays.step(date(27, 0), by: -1, now: now, calendar: calendar), date(26, 0))
        XCTAssertEqual(NutritionDays.step(date(26, 10), by: 1, now: now, calendar: calendar), date(27, 0))
        XCTAssertEqual(NutritionDays.step(date(27, 0), by: 1, now: now, calendar: calendar), date(27, 0))
    }

    func testMealTitleFallsBackToItems() {
        var m = MealEntry(date: date(27, 8), items: ["Eggs", "Toast", "Juice", "Coffee"].map {
            MealItem(name: $0, serving: "1", macros: .init())
        })
        XCTAssertEqual(NutritionText.mealTitle(m), "Eggs, Toast +2 more")
        m.name = "  Breakfast "
        XCTAssertEqual(NutritionText.mealTitle(m), "Breakfast")
    }
}
