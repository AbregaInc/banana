import XCTest

/// Banana's own usage counts (`Telemetry`, docs/design/TELEMETRY.md).
@MainActor
final class TelemetryTests: XCTestCase {
    func testUsageAndDiagnosticsNeedAnAffirmativeChoice() {
        let name = "telemetry-consent-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertFalse(Telemetry.hasUsageConsent(in: defaults))
        defaults.set(true, forKey: Telemetry.shareUsageKey)
        XCTAssertTrue(Telemetry.hasUsageConsent(in: defaults))
        defaults.set(false, forKey: Telemetry.shareUsageKey)
        XCTAssertFalse(Telemetry.hasUsageConsent(in: defaults))
        defaults.removeObject(forKey: Telemetry.shareUsageKey)
        XCTAssertFalse(Telemetry.hasUsageConsent(in: defaults))
    }

    private let utc = TelemetryBatch.utc
    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        utc.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    func testABatchSaysOnlyWhenTheCopyWasFirstOpenedAndWhatWasCounted() throws {
        let batch = TelemetryBatch(platform: "iphone", channel: "testflight", version: "1.0 (56)",
                                   firstOpened: date(2026, 10, 12), now: date(2026, 10, 15, 23), calendar: true,
                                   pending: ["feature|mealLogged|scan": 2, "active||": 1, "feature|labelRead|model": 0])
        XCTAssertEqual(batch.cohort, "2026-W42")
        XCTAssertEqual(batch.since, 3)
        XCTAssertEqual(batch.events, [.init(event: "active", name: "", detail: "", count: 1),
                                      .init(event: "feature", name: "mealLogged", detail: "scan", count: 2)])
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(batch), encoding: .utf8))
        XCTAssertFalse(json.contains("2026-10-12"), "not the day it was first opened, only its week")
    }

    func testHealthInventoryIsRemovedFromLegacyPendingBatches() {
        let batch = TelemetryBatch(platform: "iphone", channel: "testflight", version: "1.0 (74)",
                                   firstOpened: date(2026, 10, 23), now: date(2026, 10, 23), calendar: true,
                                   pending: ["setup|meals7d|3-5": 1, "setup|supplements|2": 1,
                                             "setup|myFoods|6-10": 1, "setup|workouts7d|1": 1,
                                             "active||": 1])
        XCTAssertEqual(batch.events, [.init(event: "active", name: "", detail: "", count: 1)])
    }

    func testTheFirstWeekOfAYearBelongsToItsISOYear() {
        let batch = TelemetryBatch(platform: "mac", channel: "dev", version: "1.0 (56)", firstOpened: date(2026, 12, 31),
                                   now: date(2027, 1, 2), calendar: false, pending: [:])
        XCTAssertEqual(batch.cohort, "2026-W53")
        XCTAssertEqual(batch.since, 2)
    }

    func testCountsAreCapped() {
        let batch = TelemetryBatch(platform: "ipad", channel: "appstore", version: "1.0 (56)", firstOpened: date(2026, 10, 1),
                                   now: date(2026, 10, 1), calendar: false, pending: ["feature|podcastPlayed|": 9_999])
        XCTAssertEqual(batch.events.first?.count, 500)
    }

    func testASignalSurvivesBeingKept() {
        let signal = Telemetry.Signal.feature(.mealLogged, .groceries)
        XCTAssertEqual(Telemetry.Signal(key: signal.key), signal)
        XCTAssertEqual(Telemetry.Signal(key: Telemetry.Signal.active.key), .active)
    }

    /// Every word the app can send is one the service takes (Service/src/usage.js), so nothing
    /// counted on a phone is dropped on arrival.
    func testEveryWordTheAppSendsIsOnTheCollectorsList() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Service/src/usage.js")
        let list = try String(contentsOf: source, encoding: .utf8)
        func listed(_ word: String) -> Bool { word.isEmpty || list.contains("\"\(word)\"") || list.contains("\(word):") }
        let words = Telemetry.Signal.Step.allCasesRaw + Telemetry.Signal.StepAction.allCasesRaw
            + Telemetry.Signal.Feature.allCasesRaw + Telemetry.Signal.Detail.allCasesRaw + Telemetry.Signal.Failure.allCasesRaw
            + Telemetry.Signal.Setup.allCasesRaw + Telemetry.Signal.Answer.allCasesRaw
            + ["active", "onboarding", "feature", "failure", "setup", "iphone", "ipad", "mac", "appstore", "testflight", "dev"]
        for word in words { XCTAssertTrue(listed(word), "\(word) isn't on the collector's list") }
    }

    func testNumbersGoAsRanges() {
        XCTAssertEqual([0, 1, 2, 3, 5, 6, 10, 11, 20, 21, 400].map { Telemetry.bucket($0).rawValue },
                       ["0", "1", "2", "3-5", "3-5", "6-10", "6-10", "11-20", "11-20", "21+", "21+"])
        XCTAssertEqual(Telemetry.Signal.setup(.calendars, count: 4), Telemetry.Signal(event: "setup", name: "calendars", detail: "3-5"))
    }

    func testOnlyACodeGoesWhereACodeBelongs() {
        XCTAssertNotNil(Telemetry.Signal.setup(.os, code: "27"))
        XCTAssertNotNil(Telemetry.Signal.setup(.region, code: "US"))
        XCTAssertNotNil(Telemetry.Signal.setup(.language, code: "en"))
        XCTAssertNil(Telemetry.Signal.setup(.region, code: "Brooklyn"))
        XCTAssertNil(Telemetry.Signal.setup(.language, code: "en-US"))
        XCTAssertNil(Telemetry.Signal.setup(.calendars, code: "4"), "a count goes as a range")
    }
}
