import XCTest

/// Busy blocks written through Google's API rather than through Apple Calendar's CalDAV mirror.
///
/// The ownership marker is the point. A block written to a Google calendar through CalDAV comes
/// back with its `url` stripped, so Banana stops recognising a block it wrote, ingests it as a real
/// meeting, and writes another on top — the "I deleted it and it came back, twice as long" report.
/// `extendedProperties.private` is not rewritten by any sync layer.
final class GoogleBusyBlockTests: XCTestCase {
    private typealias B = GoogleBusyBlocks

    private let start = ISO8601DateFormatter().date(from: "2026-09-22T11:30:00Z")!
    private let end = ISO8601DateFormatter().date(from: "2026-09-22T12:30:00Z")!

    private func body(variant: String = "banana", item: String = "mirror-abc") -> [String: Any] {
        B.body(title: "Busy", start: start, end: end, timeZoneID: "America/New_York",
               appItemID: item, variant: variant)
    }

    /// A block that doesn't mark you busy protects nothing.
    func testABlockIsOpaqueAndPrivate() {
        let body = self.body()
        XCTAssertEqual(body["transparency"] as? String, "opaque")
        XCTAssertEqual(body["visibility"] as? String, "private")
    }

    /// Eight calendars all alerting for the same hold is what makes people switch the feature off.
    func testABlockCarriesNoReminders() {
        let reminders = body()["reminders"] as? [String: Any]
        XCTAssertEqual(reminders?["useDefault"] as? Bool, false)
        XCTAssertTrue((reminders?["overrides"] as? [Any])?.isEmpty ?? false)
    }

    func testOwnershipTravelsInPrivateExtendedProperties() {
        let properties = (body()["extendedProperties"] as? [String: Any])?["private"] as? [String: String]
        XCTAssertEqual(properties?[B.itemIDKey], "mirror-abc")
        XCTAssertEqual(properties?[B.variantKey], "banana")
    }

    func testOwnershipIsReadBackOnlyForTheSameBuild() {
        let mine = [B.itemIDKey: "mirror-abc", B.variantKey: "banana"]
        XCTAssertEqual(B.appItemID(fromPrivateProperties: mine, variant: "banana"), "mirror-abc")
        // The beta must not be able to delete the production app's blocks, or the reverse.
        XCTAssertNil(B.appItemID(fromPrivateProperties: mine, variant: "banana-beta"))
    }

    func testAForeignOrEmptyEventIsNeverClaimed() {
        XCTAssertNil(B.appItemID(fromPrivateProperties: nil, variant: "banana"))
        XCTAssertNil(B.appItemID(fromPrivateProperties: [:], variant: "banana"))
        XCTAssertNil(B.appItemID(fromPrivateProperties: [B.variantKey: "banana"], variant: "banana"))
        XCTAssertNil(B.appItemID(
            fromPrivateProperties: [B.itemIDKey: "", B.variantKey: "banana"], variant: "banana"))
    }

    /// Google matches these as `key=value`. Filtering server-side is what makes recovery one
    /// request instead of listing a calendar and sifting it locally.
    func testTheServerSideFiltersAreKeyEqualsValue() {
        XCTAssertEqual(B.ownershipFilter(variant: "banana"), "bananaVariant=banana")
        XCTAssertEqual(B.itemFilter(appItemID: "mirror-abc"), "bananaItemID=mirror-abc")
    }

    func testTheTimeZoneTravelsWithTheTimes() {
        let body = self.body()
        let startValue = body["start"] as? [String: String]
        XCTAssertEqual(startValue?["timeZone"], "America/New_York")
        XCTAssertEqual(startValue?["dateTime"], "2026-09-22T11:30:00Z")
    }
}

/// Shared calendars you have turned on for busy blocks.
///
/// Someone else's calendar is opt-in, and the opt-in syncs between devices as plain Google calendar
/// ids — so it has to survive the synced encoding, and settings from before it existed must still
/// decode.
final class SharedCalendarOptInSettingTests: XCTestCase {

    func testNothingSharedIsOnByDefault() {
        XCTAssertTrue(SmartScheduleSettings().writeBackSharedCalendarIDs.isEmpty,
                      "writing to someone else's calendar must be chosen, calendar by calendar")
    }

    func testTheChoiceSurvivesTheSyncedEncoding() throws {
        var settings = SmartScheduleSettings()
        settings.writeBackSharedCalendarIDs = ["google-calendar:dGVhbQ=="]
        let decoded = try JSONDecoder().decode(
            SmartScheduleSettings.self, from: try JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.writeBackSharedCalendarIDs, ["google-calendar:dGVhbQ=="])
    }

    /// An older build wrote `writeBackThroughGoogleAPI`, since removed. Its settings must decode
    /// with everything else intact rather than failing and resetting Smart Schedule.
    func testSettingsFromAnOlderBuildStillDecode() throws {
        let legacy = Data(#"{"enabled":true,"reserveTaskTime":false,"writeBackThroughGoogleAPI":true}"#.utf8)
        let decoded = try JSONDecoder().decode(SmartScheduleSettings.self, from: legacy)
        XCTAssertTrue(decoded.enabled)
        XCTAssertFalse(decoded.reserveTaskTime)
        XCTAssertTrue(decoded.writeBackSharedCalendarIDs.isEmpty)
    }
}
