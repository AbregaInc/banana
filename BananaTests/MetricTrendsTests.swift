import XCTest

/// Trends compare like with like: finished days against the same number of finished days
/// before them, per day — never a week that's under way against a whole one.
final class MetricTrendsTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        c.firstWeekday = 2   // Monday
        return c
    }()

    /// Tuesday 29 September 2026, 3 pm.
    private var now: Date { day(29, hour: 15) }

    private func day(_ d: Int, month: Int = 9, hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: d, hour: hour))!
    }

    /// One value a day for `count` days ending the day before `end` (then `today` for today).
    private func daily(_ count: Int, endingBefore end: Date, today: Double? = nil, _ value: (Int) -> Double) -> [MetricPoint] {
        var points = (0..<count).map { i in
            MetricPoint(date: calendar.date(byAdding: .day, value: i - count, to: end)!, value: value(i))
        }
        if let today { points.append(MetricPoint(date: end.addingTimeInterval(9 * 3_600), value: today)) }
        return points
    }

    func testTheWindowIsTheLastFinishedDays() {
        let spans = MetricTrends.spans(window: .week, calendar: calendar, now: now)
        XCTAssertEqual(spans.current.start, day(22))
        XCTAssertEqual(spans.current.end, day(29), "today isn't finished, so it isn't in the window")
        XCTAssertEqual(spans.previous.start, day(15))
        XCTAssertEqual(spans.previous.end, day(22))
    }

    /// The bug this replaces: a week under way against finished days always read as a fall.
    /// 1,000 steps a day the week before, 1,200 a day last week, and 300 so far today.
    func testTotalsCompareFinishedDaysPerDayAndLeaveTodayOut() {
        let steps = daily(14, endingBefore: day(29), today: 300) { $0 < 7 ? 1_000 : 1_200 }
        let spans = MetricTrends.spans(window: .week, calendar: calendar, now: now)
        let trend = MetricTrends.trend(.steps, daily: steps, current: spans.current, previous: spans.previous,
                                       calendar: calendar, now: now)
        XCTAssertEqual(trend.currentValue ?? 0, 1_200, accuracy: 0.01)
        XCTAssertEqual(trend.previousValue ?? 0, 1_000, accuracy: 0.01)
        XCTAssertEqual(trend.change ?? 0, 0.2, accuracy: 0.0001)
        XCTAssertEqual(trend.direction, .up)
        XCTAssertEqual(trend.isBetter, true)
        XCTAssertEqual(trend.today, 300)
    }

    /// A rest day has no exercise recorded — it counts as none done. Before the series starts
    /// there's simply no data, which mustn't drag the average down.
    func testADayWithNothingCountsAsNothingButOnlyOnceDataStarts() {
        // Exercise on 4 of the last 7 days, 60 min each; data started 3 days into the window before.
        var exercise = daily(4, endingBefore: day(29)) { _ in 60 }
        exercise += daily(4, endingBefore: day(22)) { _ in 30 }
        let spans = MetricTrends.spans(window: .week, calendar: calendar, now: now)
        let trend = MetricTrends.trend(.exercise, daily: exercise, current: spans.current, previous: spans.previous,
                                       calendar: calendar, now: now)
        XCTAssertEqual(trend.currentValue ?? 0, 240.0 / 7, accuracy: 0.01)
        XCTAssertEqual(trend.previousValue ?? 0, 30, accuracy: 0.01, "4 days of data, averaged over those 4")
    }

    func testReadingsCompareAsTheirMean() {
        // Resting heart rate, read on only some days.
        let rhr = [MetricPoint(date: day(16), value: 60), MetricPoint(date: day(20), value: 62),
                   MetricPoint(date: day(24), value: 57), MetricPoint(date: day(27), value: 57)]
        let spans = MetricTrends.spans(window: .week, calendar: calendar, now: now)
        let trend = MetricTrends.trend(.restingHR, daily: rhr, current: spans.current, previous: spans.previous,
                                       calendar: calendar, now: now)
        XCTAssertEqual(trend.currentValue, 57)
        XCTAssertEqual(trend.previousValue, 61)
        XCTAssertEqual(trend.direction, .down)
        XCTAssertEqual(trend.isBetter, true, "a lower resting heart rate is good news")
        XCTAssertEqual(trend.currentReadings, 2)
        XCTAssertNil(trend.today, "a reading has no 'so far'")
    }

    func testSmallMovesAreFlat() {
        let steps = daily(14, endingBefore: day(29)) { $0 < 7 ? 10_000 : 10_100 }
        let spans = MetricTrends.spans(window: .week, calendar: calendar, now: now)
        let trend = MetricTrends.trend(.steps, daily: steps, current: spans.current, previous: spans.previous,
                                       calendar: calendar, now: now)
        XCTAssertEqual(trend.direction, .flat)
        XCTAssertNil(trend.isBetter)
    }

    /// A month you've paged back to is finished: August against July, per day.
    func testAPastPeriodComparesWithTheOneBefore() {
        let august = RhythmPeriod(granularity: .month, offset: -1)
        let spans = MetricTrends.spans(for: august, calendar: calendar, now: now)
        XCTAssertEqual(spans.current.start, day(1, month: 8))
        XCTAssertEqual(spans.current.end, day(1, month: 9))
        XCTAssertEqual(spans.previous.start, day(1, month: 7))
        XCTAssertEqual(MetricTrends.comparisonLabel(for: august, calendar: calendar, now: now), "Last month vs the month before")
        XCTAssertEqual(MetricTrends.comparisonLabel(for: RhythmPeriod(granularity: .quarter), calendar: calendar, now: now),
                       "Last 90 days vs the 90 before")
    }

    func testEveryWindowAtOnce() {
        let steps = daily(730, endingBefore: day(29)) { _ in 8_000 }
        let ladder = MetricTrends.ladder(.steps, daily: steps, calendar: calendar, now: now)
        XCTAssertEqual(Set(ladder.keys), Set(TrendWindow.allCases))
        XCTAssertEqual(ladder[.year]?.previousValue ?? 0, 8_000, accuracy: 0.01, "two years of history covers a year either side")
    }

    func testAQuarterChartsWeekByWeek() {
        let steps = daily(180, endingBefore: day(29)) { Double($0) }
        let spans = MetricTrends.spans(window: .quarter, calendar: calendar, now: now)
        let chart = MetricTrends.overlay(.steps, daily: steps, current: spans.current, previous: spans.previous,
                                         bucketDays: TrendWindow.quarter.chartBucketDays, calendar: calendar)
        XCTAssertEqual(chart.current.map(\.day), Array(stride(from: 0, to: 90, by: 7)))
        XCTAssertEqual(chart.previous.count, chart.current.count, "the two windows line up point for point")
        // Days 90…96 of the series (0-based) fall in the current window's first week.
        XCTAssertEqual(chart.current[0].value, 93, accuracy: 0.01)
    }

    // MARK: - Workouts: this period so far against the same stretch of the last

    func testAWeekUnderWayIsSetAgainstLastWeekUpToNow() {
        let span = PeriodPace.comparison(for: RhythmPeriod(granularity: .week), calendar: calendar, now: now)
        XCTAssertEqual(span.start, day(21))
        XCTAssertEqual(span.end, day(22, hour: 15), "last Monday to last Tuesday at 3 pm")
    }

    func testAFinishedWeekIsSetAgainstTheWholeWeekBefore() {
        let span = PeriodPace.comparison(for: RhythmPeriod(granularity: .week, offset: -1), calendar: calendar, now: now)
        XCTAssertEqual(span.start, day(14))
        XCTAssertEqual(span.end, day(21))
    }

    func testAMonthUnderWayStopsAtTheEndOfAShorterMonth() {
        // 31 March 3 pm against February (28 days): all of February, no further.
        let march31 = calendar.date(from: DateComponents(year: 2026, month: 3, day: 31, hour: 15))!
        let span = PeriodPace.comparison(for: RhythmPeriod(granularity: .month), calendar: calendar, now: march31)
        XCTAssertEqual(span.start, calendar.date(from: DateComponents(year: 2026, month: 2, day: 1)))
        XCTAssertEqual(span.end, calendar.date(from: DateComponents(year: 2026, month: 3, day: 1)))
    }

    // MARK: - The Health cache on its way to the Mac

    func testTheSnapshotCompressesAndStillReadsTheOldPlainForm() throws {
        var trends = HealthTrends()
        trends.steps = daily(730, endingBefore: day(29)) { Double(8_000 + $0 % 97) }
        let json = try JSONEncoder().encode(trends)
        let packed = try XCTUnwrap(HealthSnapshotCoding.pack(json))
        XCTAssertLessThan(packed.count, json.count / 3)
        XCTAssertEqual(HealthSnapshotCoding.unpack(packed), json)
        XCTAssertEqual(HealthSnapshotCoding.unpack(json), json, "an older build's plain JSON still reads")
    }

    /// The snapshot rides in the record's asset, outside the record's 1 MB; the payload only
    /// says so. A record from before that still carries it inline.
    func testTheSnapshotIsReadFromTheAssetWhenThePayloadSaysSo() {
        let packed = Data("packed snapshot".utf8)
        XCTAssertEqual(HealthSnapshotCoding.snapshot(payload: HealthSnapshotCoding.inAsset, asset: { packed }), packed)
        XCTAssertNil(HealthSnapshotCoding.snapshot(payload: HealthSnapshotCoding.inAsset, asset: { nil }),
                     "a missing asset keeps the cache rather than adopting nothing")
        var assetRead = false
        XCTAssertEqual(HealthSnapshotCoding.snapshot(payload: packed, asset: { assetRead = true; return nil }), packed)
        XCTAssertFalse(assetRead, "an inline snapshot never touches the asset")
    }
}

/// Sections that only have a sidebar row fall back to the tab they live under on a phone.
final class AppSectionTests: XCTestCase {
    func testSidebarOnlySectionsHaveATabBarHome() {
        XCTAssertEqual(AppSection.trends.tabBarHome, .workouts)
        XCTAssertEqual(AppSection.sleep.tabBarHome, .workouts)
        XCTAssertEqual(AppSection.settings.tabBarHome, .plan)
        XCTAssertEqual(AppSection.routines.tabBarHome, .plan)
        XCTAssertEqual(AppSection.mail.tabBarHome, .mail)
        for tab in AppSection.iOSTabs { XCTAssertEqual(tab.tabBarHome, tab) }
        for section in AppSection.allCases { XCTAssertTrue(AppSection.iOSTabs.contains(section.tabBarHome)) }
    }

    /// Mail is the second section everywhere there is a sidebar, and not one of the phone's five
    /// tabs: where it sits on a phone is undecided, so the phone's bar is exactly what it was.
    func testMailIsSecondInTheSidebarAndPhoneTabs() {
        XCTAssertEqual(AppSection.allCases.prefix(2).map(\.rawValue), ["plan", "mail"])
        XCTAssertEqual(AppSection.macSidebar, AppSection.allCases)
        XCTAssertEqual(AppSection.mail.title, "Mail")
        XCTAssertEqual(AppSection.mail.symbol, "envelope.fill")
        XCTAssertEqual(AppSection.iOSTabs, [.plan, .mail, .workouts, .nutrition, .notes, .library])
        XCTAssertTrue(AppSection.iOSTabs.contains(.mail))
    }

    /// The Mac numbers its sections ⌘1 to ⌘9 from their place. Mail is ⌘2, the sections after it
    /// each move down one, and no section after the ninth has a number to take (a tenth used to
    /// trap in `Character(String(index + 1))`).
    func testTheMacNumbersNineSectionsAndMailIsTheSecond() {
        XCTAssertEqual(AppSection.macShortcuts.map(\.rawValue),
                       ["plan", "mail", "workouts", "sleep", "trends", "nutrition", "notes", "routines", "library"])
        XCTAssertLessThanOrEqual(AppSection.macShortcuts.count, 9)
        XCTAssertFalse(AppSection.macShortcuts.contains(.settings), "Settings is ⌘, and has no number")
    }

    /// A shell state saved before Tab became AppSection still restores.
    func testAnOldSavedTabStillDecodes() throws {
        let state = try JSONDecoder().decode(ShellState.self, from: Data(#"{"tab":"library"}"#.utf8))
        XCTAssertEqual(state.tab, .library)
    }
}

/// The phone is the hub; an iPad works from what the phone syncs, like the Mac.
final class DeviceRoleTests: XCTestCase {
    func testOnlyThePhoneIsTheHub() {
        XCTAssertTrue(DeviceRole.phone.isHub)
        XCTAssertFalse(DeviceRole.pad.isHub)
        XCTAssertFalse(DeviceRole.mac.isHub)
    }

    /// Tests run on an iPhone Simulator, which must read as the phone.
    func testThisSimulatorIsThePhone() {
        XCTAssertEqual(DeviceRole.current, .phone)
    }
}

/// The phone's status under a control on every device.
final class HubStatusTests: XCTestCase {
    func testTripLearningCaptionsOnThePhoneAndElsewhere() {
        let running: HubStatus.TripLearning? = .running
        let blocked: HubStatus.TripLearning? = .needsAlwaysLocation
        let unknown: HubStatus.TripLearning? = nil
        XCTAssertNil(running.caption(wanted: true, onHub: true), "the phone's own toggle says nothing when all is well")
        XCTAssertEqual(running.caption(wanted: true, onHub: false), "Learning on your iPhone.")
        XCTAssertEqual(blocked.caption(wanted: true, onHub: false), "Needs \u{201C}Always\u{201D} location on your iPhone.")
        XCTAssertNotNil(blocked.caption(wanted: true, onHub: true))
        XCTAssertEqual(unknown.caption(wanted: true, onHub: false), "Starts on your iPhone next time it\u{2019}s open.")
        XCTAssertNil(blocked.caption(wanted: false, onHub: false), "off says nothing")
    }

    /// A newer phone's status must still read on an older iPad or Mac.
    func testAnUnknownStatusStillDecodes() throws {
        let data = Data(#"{"updatedAt":0,"tripLearning":"somethingNew","futureField":{"a":1}}"#.utf8)
        let status = try JSONDecoder().decode(HubStatus.self, from: data)
        XCTAssertEqual(status.tripLearning, .off)
        XCTAssertEqual(status.updatedAt, Date(timeIntervalSinceReferenceDate: 0))
    }
}

/// Busy blocks on/off and their calendar are synced settings; unset until a set-up device says.
final class SyncedWriteBackSettingsTests: XCTestCase {
    func testOlderSettingsLeaveTheChoiceUnset() throws {
        let settings = try JSONDecoder().decode(SmartScheduleSettings.self, from: Data("{}".utf8))
        XCTAssertNil(settings.writeBackEnabled, "a fresh device adopts, it doesn't seed off")
        XCTAssertNil(settings.writeBackCalendarID)
    }

    func testTheChoiceSurvivesTheRoundTrip() throws {
        var settings = SmartScheduleSettings()
        settings.writeBackEnabled = false
        settings.writeBackCalendarID = "cal-info-1"
        let back = try JSONDecoder().decode(SmartScheduleSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(back.writeBackEnabled, false)
        XCTAssertEqual(back.writeBackCalendarID, "cal-info-1")
    }
}

/// Today's "Up next" is the next thing with a real time — never an undated task that happens to
/// be stamped a minute ahead.
final class UpNextTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 812_416_620)   // 19:37 on 29 Sep 2026

    func testOnlyTimedPendingFutureItemsQualify() {
        XCTAssertTrue(UpNext.isCandidate(time: now.addingTimeInterval(60 * 59), pending: true, now: now))
        XCTAssertFalse(UpNext.isCandidate(time: nil, pending: true, now: now), "an undated task has no time to be next at")
        XCTAssertFalse(UpNext.isCandidate(time: now.addingTimeInterval(-60), pending: true, now: now), "already started")
        XCTAssertFalse(UpNext.isCandidate(time: now.addingTimeInterval(600), pending: false, now: now), "already done")
        XCTAssertFalse(UpNext.isCandidate(time: now, pending: true, now: now), "starting now is Now, not next")
    }
}

/// Requests from an iPad or the Mac for the phone to do one of its jobs: each done once.
final class HubRequestsTests: XCTestCase {
    func testOnlyNewRequestsArePending() {
        let t = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var asked = HubRequests()
        asked.watchResync = t
        XCTAssertEqual(asked.pending(after: HubRequests()), [.watchResync])
        var handled = HubRequests()
        handled.watchResync = t
        XCTAssertTrue(asked.pending(after: handled).isEmpty, "already done")
        asked.backUpNow = t.addingTimeInterval(60)
        asked.watchResync = t.addingTimeInterval(120)
        XCTAssertEqual(Set(asked.pending(after: handled)), [.watchResync, .backUpNow])
    }

    func testANewerPhoneStatusStillDecodesOnAnOlderDevice() throws {
        var status = HubStatus()
        status.alarmsAllowed = true
        status.nextAlarm = Date(timeIntervalSinceReferenceDate: 800_000_000)
        status.watchVersion = "1.0 (52)"
        let back = try JSONDecoder().decode(HubStatus.self, from: JSONEncoder().encode(status))
        XCTAssertEqual(back.alarmsAllowed, true)
        XCTAssertEqual(back.watchVersion, "1.0 (52)")
    }
}

/// The phone's status as the iPad and Mac show it.
final class PhoneStatusTextTests: XCTestCase {
    func testWordsForEachState() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var status = HubStatus()
        XCTAssertEqual(PhoneStatusText(status: status, now: now).alarmsLine, "Not reported yet")
        status.alarmsAllowed = true
        XCTAssertEqual(PhoneStatusText(status: status, now: now).alarmsLine, "Allowed \u{00B7} none armed")
        status.nextAlarm = now.addingTimeInterval(8 * 3_600)
        XCTAssertTrue(PhoneStatusText(status: status, now: now).alarmsLine.hasPrefix("Next "))
        status.alarmsAllowed = false
        XCTAssertEqual(PhoneStatusText(status: status, now: now).alarmsLine, "Not allowed")
        status.watchVersion = "1.0 (52)"
        status.watchEpisodesPending = 3
        XCTAssertEqual(PhoneStatusText(status: status, now: now).watchLine, "1.0 (52) \u{00B7} 3 to send")
        status.healthConnected = false
        XCTAssertEqual(PhoneStatusText(status: status, now: now).healthLine, "Not connected")
    }
}

/// Weight, height and speed follow the units in Settings on every device.
final class MetricUnitsTests: XCTestCase {
    func testImperialAndMetric() {
        XCTAssertEqual(MetricKind.bodyMass.format(77.1, imperial: true), "170.0 lb")
        XCTAssertEqual(MetricKind.bodyMass.format(77.1, imperial: false), "77.1 kg")
        XCTAssertEqual(MetricKind.height.format(1.8034, imperial: true), "5\u{2032} 11\u{2033}")
        XCTAssertEqual(MetricKind.height.format(1.8034, imperial: false), "180 cm")
        XCTAssertEqual(MetricKind.walkingSpeed.format(1.36, imperial: true), "3.0 mph")
        XCTAssertEqual(MetricKind.walkingSpeed.format(1.36, imperial: false), "4.9 km/h")
        XCTAssertEqual(MetricKind.steps.format(17_978, imperial: true), MetricKind.steps.format(17_978, imperial: false))
        XCTAssertEqual(MetricKind.bodyMass.displayValue(10, imperial: true), 22.046_226, accuracy: 0.001)
    }
}

/// Progress CloudKit hasn't confirmed is sent again — but never a value of unknown age.
final class ProgressReconcileTests: XCTestCase {
    func testWhatNeedsSendingAgain() {
        let t = Date(timeIntervalSinceReferenceDate: 800_000_000)
        XCTAssertTrue(ProgressReconcile.needsUpload(localStamp: t, confirmed: nil), "never confirmed")
        XCTAssertTrue(ProgressReconcile.needsUpload(localStamp: t, confirmed: t.addingTimeInterval(-60)), "changed since")
        XCTAssertFalse(ProgressReconcile.needsUpload(localStamp: t, confirmed: t), "already there")
        XCTAssertFalse(ProgressReconcile.needsUpload(localStamp: t, confirmed: t.addingTimeInterval(60)), "CloudKit has newer")
        XCTAssertFalse(ProgressReconcile.needsUpload(localStamp: nil, confirmed: nil),
                       "no timestamp: sending it as new could overwrite newer progress elsewhere")
    }
}

/// Two copies stamped at the same moment settle the same way on every device.
final class ProgressTieTests: XCTestCase {
    private let finished = ProgressTie.Copy(completed: true, position: nil)
    private let at41 = ProgressTie.Copy(completed: false, position: 2_497)
    private let at10 = ProgressTie.Copy(completed: false, position: 600)

    func testAFinishBeatsAPosition() {
        XCTAssertTrue(ProgressTie.beats(finished, at41))
        XCTAssertFalse(ProgressTie.beats(at41, finished))
    }

    func testTheFurtherPositionWins() {
        XCTAssertTrue(ProgressTie.beats(at41, at10))
        XCTAssertFalse(ProgressTie.beats(at10, at41))
    }

    func testEqualCopiesNeitherWin() {
        XCTAssertFalse(ProgressTie.beats(finished, finished))
        XCTAssertFalse(ProgressTie.beats(at41, at41))
    }

    func testAMillisecondIsTheSameMoment() {
        let t = Date(timeIntervalSinceReferenceDate: 812_139_644.201_331)
        XCTAssertTrue(ProgressTie.isTie(t, Date(timeIntervalSinceReferenceDate: 812_139_644.201)))
        XCTAssertFalse(ProgressTie.isTie(t, t.addingTimeInterval(0.01)))
    }
}


final class ParkedProgressTests: XCTestCase {
    private let early = Date(timeIntervalSince1970: 1_000)
    private let late = Date(timeIntervalSince1970: 2_000)

    func testKeepsTheLaterOfTwoForOneEpisode() {
        var parked = ParkedProgress()
        parked.park("ep", .init(position: 0, completed: true, at: late))
        parked.park("ep", .init(position: 300, completed: false, at: early))
        XCTAssertEqual(parked.entries["ep"], .init(position: 0, completed: true, at: late))
        parked.park("ep", .init(position: 60, completed: false, at: late.addingTimeInterval(5)))
        XCTAssertEqual(parked.entries["ep"]?.position, 60)
    }

    func testReleasesOnlyEpisodesThisDeviceNowHas() {
        var parked = ParkedProgress()
        parked.park("a", .init(position: 10, completed: false, at: early))
        parked.park("b", .init(position: 0, completed: true, at: early))
        let ready = parked.release { $0 == "b" }
        XCTAssertEqual(ready.map(\.episodeID), ["b"])
        XCTAssertEqual(Array(parked.entries.keys), ["a"], "still waiting for its episode")
        XCTAssertTrue(parked.release { _ in false }.isEmpty)
        XCTAssertEqual(parked.release { _ in true }.map(\.episodeID), ["a"])
        XCTAssertTrue(parked.isEmpty)
    }

    func testSurvivesARoundTripToDisk() throws {
        var parked = ParkedProgress()
        parked.park("ep", .init(position: 42, completed: false, at: late))
        let decoded = try JSONDecoder().decode(ParkedProgress.self, from: JSONEncoder().encode(parked))
        XCTAssertEqual(decoded, parked)
    }
}
