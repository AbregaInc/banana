import XCTest

/// The iCloud backup's rules (`BackupRules`): what of the settings it carries, what a restore
/// leaves alone, and what the Settings row says.
final class BackupRulesTests: XCTestCase {
    func testEverySyncEnginesStateStaysOutOfABackup() {
        // Only the podcast-progress engine's was kept out.
        for key in ["ckSyncEngine.progress.state", "ckSyncEngine.settings.state", "ckSyncEngine.settings.systemFields",
                    "ckSyncEngine.wellness.state", "ckSyncEngine.fitness.state", "ckSyncEngine.fitness.dirty",
                    "ckSyncEngine.controls.state", "mealsPush.subscribed.v1", "fitnessCloud.samplesAssetBlockedUntil",
                    "smartAlarmIDs", "wakeAlarmTimes", "cloudBackupDate"] {
            XCTAssertTrue(BackupRules.isOperational(key), key)
        }
        XCTAssertFalse(BackupRules.isOperational("planMode"))
        XCTAssertFalse(BackupRules.isOperational("onboardingCompleted"))
        XCTAssertFalse(BackupRules.isOperational("cloudBackupEnabled"), "the switch itself is a setting")
    }

    func testABackupCarriesSettingsOnly() {
        let portable = BackupRules.portable(["planMode": "week", "ckSyncEngine.wellness.state": Data([1]), "smartAlarmIDs": Data()])
        XCTAssertEqual(Array(portable.keys), ["planMode"])
    }

    func testARestoreKeepsThisDevicesOwnSyncStateAndAlarms() {
        let backup: [String: Any] = ["planMode": "week", "ckSyncEngine.fitness.state": "the phone's",
                                     "onboardingCompleted": false]
        let current: [String: Any] = ["planMode": "day", "ckSyncEngine.fitness.state": "this Mac's",
                                      "wakeAlarmTimes": [Date(timeIntervalSince1970: 1)], "onboardingCompleted": true,
                                      "somethingLocalOnly": 3]
        let restored = BackupRules.restored(from: backup, over: current)
        XCTAssertEqual(restored["planMode"] as? String, "week", "settings come from the backup")
        XCTAssertEqual(restored["ckSyncEngine.fitness.state"] as? String, "this Mac's")
        XCTAssertNotNil(restored["wakeAlarmTimes"])
        XCTAssertEqual(restored["onboardingCompleted"] as? Bool, true, "never asked to onboard again")
        XCTAssertNil(restored["somethingLocalOnly"], "a setting the backup doesn't have is gone, as before")
    }

    func testTheStatusSaysWhenItWasLastBackedUp() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        func at(_ day: Int, _ hour: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))! }
        let now = at(8, 15)
        XCTAssertEqual(BackupRules.restingStatus(lastBackup: nil, now: now, calendar: calendar), "Not backed up yet")
        XCTAssertTrue(BackupRules.restingStatus(lastBackup: at(8, 9), now: now, calendar: calendar).hasPrefix("Backed up today at "))
        XCTAssertTrue(BackupRules.restingStatus(lastBackup: at(7, 22), now: now, calendar: calendar).hasPrefix("Backed up yesterday at "))
        let older = BackupRules.restingStatus(lastBackup: at(2, 9), now: now, calendar: calendar)
        XCTAssertTrue(older.hasPrefix("Backed up Oct 2 at "), older)
    }

    func testAnOlderBackupIsNotCalledByTheAppsOldName() {
        XCTAssertEqual(BackupRules.sourceName("Quarters migration"), "earlier Banana")
        XCTAssertEqual(BackupRules.sourceName("previous Quarters migration"), "previous earlier Banana")
        XCTAssertEqual(BackupRules.sourceName("Banana"), "Banana")
        XCTAssertEqual(BackupRules.sourceName(nil), "iCloud")
    }
}
