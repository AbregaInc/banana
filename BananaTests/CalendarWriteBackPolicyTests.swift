import XCTest

final class CalendarWriteBackPolicyTests: XCTestCase {
    func testVariantsUseDistinctMarkersAndMigrateLegacyClaimsSafely() {
        XCTAssertEqual(CalendarWriteBackVariant.production.markerScheme, "banana")
        XCTAssertEqual(CalendarWriteBackVariant.beta.markerScheme, "banana-beta")
        XCTAssertTrue(CalendarWriteBackVariant.production.owns(markerScheme: "banana"))
        XCTAssertTrue(CalendarWriteBackVariant.production.owns(markerScheme: "quarters"))
        XCTAssertFalse(CalendarWriteBackVariant.beta.owns(markerScheme: "banana"))
        XCTAssertTrue(CalendarWriteBackVariant.beta.owns(markerScheme: "banana-beta"))
        XCTAssertFalse(CalendarWriteBackVariant.beta.owns(
            markerScheme: "banana",
            appItemID: "mirror-old-source-event"
        ))
        XCTAssertTrue(CalendarWriteBackVariant.beta.owns(
            markerScheme: "banana",
            appItemID: "task:beta-only"
        ))
    }

    func testProductionCoverageWinsWhenBothVariantsAreInstalled() {
        XCTAssertTrue(CalendarWriteBackVariant.beta.reusesCoverage(markerScheme: "banana"))
        XCTAssertFalse(CalendarWriteBackVariant.beta.reusesCoverage(
            markerScheme: "banana",
            appItemID: "task:beta-only"
        ))
        XCTAssertFalse(CalendarWriteBackVariant.production.reusesCoverage(markerScheme: "banana-beta"))
        XCTAssertFalse(CalendarWriteBackVariant.production.reusesCoverage(markerScheme: "banana"))
        XCTAssertFalse(CalendarWriteBackVariant.beta.reusesCoverage(markerScheme: "banana-beta"))
        XCTAssertTrue(CalendarWriteBackVariant.production.reusesCoverage(markerScheme: nil))
        XCTAssertTrue(CalendarWriteBackVariant.beta.reusesCoverage(markerScheme: nil))
        XCTAssertTrue(CalendarWriteBackVariant.production.reusesCoverage(markerScheme: "https"))
        XCTAssertTrue(CalendarWriteBackVariant.beta.reusesCoverage(markerScheme: "https"))
    }

    func testBetaReusesExactProductionCoverageOfTheSameScheduledItem() {
        let item = "travel-item"
        XCTAssertTrue(CalendarWriteBackVariant.beta.reusesExactProductionCoverage(
            markerScheme: "banana", existingItemID: item, wantedItemID: item))
        XCTAssertFalse(CalendarWriteBackVariant.beta.reusesExactProductionCoverage(
            markerScheme: "banana", existingItemID: "another-item", wantedItemID: item))
        XCTAssertFalse(CalendarWriteBackVariant.production.reusesExactProductionCoverage(
            markerScheme: "banana-beta", existingItemID: item, wantedItemID: item))
    }

    func testBetaShadowRequiresExactBlockingCopyAndSameKnownCreator() {
        let content = ["Busy", "time", "1000", "2000"].joined(separator: "\u{1F}")
        let original = BusyVariantShadows.Copy(content: content, creator: "noor@plan.example", blocksTime: true)
        XCTAssertNotNil(original)
        XCTAssertEqual(original, .init(content: content, creator: " NOOR@plan.example ", blocksTime: true))
        XCTAssertNotEqual(original, .init(content: content, creator: "team@plan.example", blocksTime: true))
        XCTAssertNotEqual(original, .init(content: content + "1", creator: "noor@plan.example", blocksTime: true))
        XCTAssertNil(BusyVariantShadows.Copy(content: content, creator: nil, blocksTime: true))
        XCTAssertNil(BusyVariantShadows.Copy(content: content, creator: "noor@plan.example", blocksTime: false))
    }

    func testSelfCommitEchoIsDeferredInsteadOfDiscarded() {
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        let delay = CalendarChangeEchoPolicy.debounceDelay(
            lastSelfCommit: now.addingTimeInterval(-2),
            now: now
        )

        XCTAssertEqual(delay, 8.25, accuracy: 0.001)
    }

    func testOrdinaryCalendarChangeKeepsFiveSecondDebounce() {
        let now = Date(timeIntervalSinceReferenceDate: 10_000)

        XCTAssertEqual(
            CalendarChangeEchoPolicy.debounceDelay(lastSelfCommit: nil, now: now),
            5,
            accuracy: 0.001
        )
        XCTAssertEqual(
            CalendarChangeEchoPolicy.debounceDelay(
                lastSelfCommit: now.addingTimeInterval(-11),
                now: now
            ),
            5,
            accuracy: 0.001
        )
    }
}

/// Every device reconciles the same busy blocks, so duplicates must resolve the same way on each.
final class BusyBlockDuplicatesTests: XCTestCase {
    func testEveryDeviceKeepsTheSameCopy() {
        // The phone and the iPad list the copies in different orders (and each ledger knows a
        // different one); both must keep the same.
        let phone = BusyBlockDuplicates.copyToKeep(["evt-b", "evt-a", "evt-c"])
        let iPad = BusyBlockDuplicates.copyToKeep(["evt-c", "evt-b", "evt-a"])
        XCTAssertEqual(phone, iPad)
        XCTAssertEqual(phone, "evt-a")
        XCTAssertNil(BusyBlockDuplicates.copyToKeep([]))
    }
}
