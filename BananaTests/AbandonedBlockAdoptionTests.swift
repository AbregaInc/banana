import XCTest

/// Deleting a busy block that the other variant wrote.
///
/// Prod and beta each refuse to delete the other's blocks, which is what stops two installs on one
/// machine fighting over a calendar. The hole: when the owning variant stops running — or has
/// write-back switched off — its stale blocks sit there with nobody permitted to remove them.
/// Deleting the meeting looks like it worked and the block stays; deleting the block by hand
/// achieves nothing because it is simply rewritten.
final class AbandonedBlockAdoptionTests: XCTestCase {

    /// Both markers count as app-written. No real event of the user's carries one, which is what
    /// makes adopting an abandoned block safe rather than a licence to delete anything.
    func testEveryVariantMarkerIsRecognisedAsAppWritten() {
        XCTAssertTrue(CalendarWriteBackVariant.isAppMarker("banana"))
        XCTAssertTrue(CalendarWriteBackVariant.isAppMarker("banana-beta"))
        XCTAssertTrue(CalendarWriteBackVariant.isAppMarker("quarters"))
    }

    /// The guard that matters: anything without a Banana marker is someone's real event.
    func testAForeignEventIsNeverAppWritten() {
        XCTAssertFalse(CalendarWriteBackVariant.isAppMarker(nil))
        XCTAssertFalse(CalendarWriteBackVariant.isAppMarker("http"))
        XCTAssertFalse(CalendarWriteBackVariant.isAppMarker("webcal"))
        XCTAssertFalse(CalendarWriteBackVariant.isAppMarker("bananas"))
    }

    /// Ownership stays narrow for normal operation: production only claims its own marker, so a
    /// beta block is never *rewritten* by prod — it is only ever cleaned up once stale.
    func testProductionDoesNotClaimBetaBlocksForWriting() {
        XCTAssertFalse(CalendarWriteBackVariant.production.owns(markerScheme: "banana-beta"))
        XCTAssertTrue(CalendarWriteBackVariant.production.owns(markerScheme: "banana"))
    }

    /// Beta keeps its own non-mirror entries, and leaves the ambiguous shared mirrors to prod.
    func testBetaOwnsItsOwnMarkerAndLegacyNonMirrors() {
        XCTAssertTrue(CalendarWriteBackVariant.beta.owns(markerScheme: "banana-beta"))
        XCTAssertTrue(CalendarWriteBackVariant.beta.owns(markerScheme: "banana", appItemID: "travel-abc"))
        XCTAssertFalse(CalendarWriteBackVariant.beta.owns(markerScheme: "banana", appItemID: "mirror-abc"))
    }
}
