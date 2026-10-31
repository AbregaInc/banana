import XCTest

/// Coverage for the pure sync-state derivation in `Shared/FitnessModels.swift`
/// (`FitnessSyncStateDerivation`/`WorkoutCloudUploadStateDerivation`) — the logic that turns the
/// sets `CloudFitnessSync` already maintains (`dirty`, `assetPending`) plus its own
/// availability/exchange bits into the states Settings and the workout detail badge show. Kept
/// pure and CloudKit-free, like `CloudFitnessRecordRouting`
/// (`CloudFitnessRecordRoutingTests.swift`), so it's testable here without constructing a
/// `CKSyncEngine`/`CKContainer`.
final class FitnessSyncStateTests: XCTestCase {

    // MARK: - Unavailable takes priority over everything else

    /// The core safety property: an account that has gone unavailable must never report success,
    /// even if a stale `lastSuccess` timestamp from before it went unavailable is still on hand
    /// and nothing is currently pending. Showing "up to date" here would be exactly the "stale
    /// success" the Settings section is required to never show.
    func testUnavailableAccountNeverReportsSuccessEvenWithPendingCountZeroAndAStaleTimestamp() {
        let staleSuccess = Date(timeIntervalSinceNow: -60)
        let state = FitnessSyncStateDerivation.derive(
            iCloudAvailable: false, exchanging: false, pendingCount: 0, lastSuccess: staleSuccess)
        XCTAssertEqual(state, .unavailable)
    }

    /// Same guarantee, but with a backlog outstanding too — unavailable still wins over waiting.
    func testUnavailableAccountNeverReportsSuccessWithPendingItemsEither() {
        let state = FitnessSyncStateDerivation.derive(
            iCloudAvailable: false, exchanging: false, pendingCount: 5, lastSuccess: Date())
        XCTAssertEqual(state, .unavailable)
    }

    /// Unavailable wins even over an in-flight exchange flag — that flag can only be true because
    /// of stale bookkeeping if iCloud has already gone unavailable.
    func testUnavailableAccountWinsOverExchangingFlag() {
        let state = FitnessSyncStateDerivation.derive(
            iCloudAvailable: false, exchanging: true, pendingCount: 0, lastSuccess: nil)
        XCTAssertEqual(state, .unavailable)
    }

    // MARK: - Never synced yet reads the same as unavailable

    /// iCloud is available, nothing is pending, but no exchange has ever completed — there is no
    /// success to report, so this reads as `.unavailable` rather than a bare "up to date" with no
    /// date to show.
    func testNeverSyncedWithNoBacklogAndNoLastSuccessIsUnavailable() {
        let state = FitnessSyncStateDerivation.derive(
            iCloudAvailable: true, exchanging: false, pendingCount: 0, lastSuccess: nil)
        XCTAssertEqual(state, .unavailable)
    }

    // MARK: - Up to date

    /// An empty backlog with a recent timestamp reads as up to date, carrying that exact date.
    func testEmptyDirtySetWithRecentTimestampReadsAsUpToDate() {
        let recent = Date(timeIntervalSinceNow: -5)
        let state = FitnessSyncStateDerivation.derive(
            iCloudAvailable: true, exchanging: false, pendingCount: 0, lastSuccess: recent)
        XCTAssertEqual(state, .upToDate(recent))
    }

    // MARK: - Waiting counts map to the right state

    func testOnePendingItemMapsToWaitingWithCountOne() {
        let state = FitnessSyncStateDerivation.derive(
            iCloudAvailable: true, exchanging: false, pendingCount: 1, lastSuccess: nil)
        XCTAssertEqual(state, .waiting(count: 1, lastSuccess: nil))
    }

    func testSeveralPendingItemsCarryTheirExactCount() {
        let state = FitnessSyncStateDerivation.derive(
            iCloudAvailable: true, exchanging: false, pendingCount: 7, lastSuccess: nil)
        XCTAssertEqual(state, .waiting(count: 7, lastSuccess: nil))
    }

    /// A stalled backlog still remembers when things last moved, so the UI can say "last synced
    /// ⟨date⟩" alongside "N waiting" instead of losing that fact the moment something is pending.
    func testWaitingCarriesForwardTheLastSuccessTimestamp() {
        let lastSuccess = Date(timeIntervalSinceNow: -3600)
        let state = FitnessSyncStateDerivation.derive(
            iCloudAvailable: true, exchanging: false, pendingCount: 2, lastSuccess: lastSuccess)
        XCTAssertEqual(state, .waiting(count: 2, lastSuccess: lastSuccess))
    }

    // MARK: - Syncing takes priority over a backlog, but not over unavailable

    func testExchangingWithBacklogReadsAsSyncingNotWaiting() {
        let state = FitnessSyncStateDerivation.derive(
            iCloudAvailable: true, exchanging: true, pendingCount: 3, lastSuccess: nil)
        XCTAssertEqual(state, .syncing)
    }

    func testExchangingWithNoBacklogStillReadsAsSyncing() {
        // e.g. mid-fetch of another device's changes, with nothing local to send.
        let state = FitnessSyncStateDerivation.derive(
            iCloudAvailable: true, exchanging: true, pendingCount: 0, lastSuccess: Date())
        XCTAssertEqual(state, .syncing)
    }
}

/// Coverage for `WorkoutCloudUploadStateDerivation` — the per-workout sibling shown on
/// `WorkoutHeroHeader`. Separate from the sync-state suite above because it answers a narrower
/// question ("has THIS workout's recording left this device") from different inputs.
final class WorkoutCloudUploadStateTests: XCTestCase {
    func testNoLocalSamplesMeansNothingToUploadRegardlessOfOtherFlags() {
        XCTAssertEqual(
            WorkoutCloudUploadStateDerivation.derive(
                hasLocalSamples: false, iCloudAvailable: true, isPending: true, exchanging: true),
            .noLocalRecording)
        XCTAssertEqual(
            WorkoutCloudUploadStateDerivation.derive(
                hasLocalSamples: false, iCloudAvailable: false, isPending: false, exchanging: false),
            .noLocalRecording)
    }

    /// The bug caught by running the harness with `--disable-icloud` against real data: with sync
    /// never started, `dirty`/`assetPending` stay at their empty initial value, which — without
    /// this check — is indistinguishable from "everything already uploaded." A workout with a
    /// local recording but no running sync engine must read as `.unavailable`, never `.uploaded`.
    func testLocalSamplesButICloudUnavailableNeverReadsAsUploadedEvenWithNothingPending() {
        XCTAssertEqual(
            WorkoutCloudUploadStateDerivation.derive(
                hasLocalSamples: true, iCloudAvailable: false, isPending: false, exchanging: false),
            .unavailable)
    }

    func testICloudUnavailableWinsOverPendingAndExchangingToo() {
        XCTAssertEqual(
            WorkoutCloudUploadStateDerivation.derive(
                hasLocalSamples: true, iCloudAvailable: false, isPending: true, exchanging: true),
            .unavailable)
    }

    func testLocalSamplesNotPendingMeansUploaded() {
        XCTAssertEqual(
            WorkoutCloudUploadStateDerivation.derive(
                hasLocalSamples: true, iCloudAvailable: true, isPending: false, exchanging: false),
            .uploaded)
    }

    func testLocalSamplesPendingWhileExchangingMeansUploading() {
        XCTAssertEqual(
            WorkoutCloudUploadStateDerivation.derive(
                hasLocalSamples: true, iCloudAvailable: true, isPending: true, exchanging: true),
            .uploading)
    }

    func testLocalSamplesPendingWhileIdleMeansWaiting() {
        XCTAssertEqual(
            WorkoutCloudUploadStateDerivation.derive(
                hasLocalSamples: true, iCloudAvailable: true, isPending: true, exchanging: false),
            .waiting)
    }
}
