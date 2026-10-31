#if DEBUG
import Foundation
import Combine

/// `--verify-fitness-batch` — feed 50 synthetic remote workout summaries through ONE
/// `FitnessStore.applyingCloudBatch` scope (the same scope `CloudFitnessSync` now wraps its
/// `.fetchedRecordZoneChanges` loop in) and count how many times `FitnessStore.objectWillChange`
/// actually fires, so the fix for the reported storm —
///
///   🌀 STORM: fitness↻ at 13/s  cpu=205% over 15s — fitness↻×205 WeekView×103
///
/// (CKSyncEngine delivering a backlog of workout records, one `adoptCloudWorkout` /
/// `adoptCloudSummary` per record, each publishing `summaries` on its own) — is proven, not just
/// argued. Without the batch scope this would print 50 (or more: `adoptCloudSummary` itself
/// mutates `summaries` twice per call — assign/append, then sort); with it, exactly 1.
enum FitnessBatchVerification {
    static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--verify-fitness-batch") else { return }
        Task { @MainActor in
            await run()
        }
    }

    @MainActor
    private static func run() async {
        let fitness = FitnessStore.shared
        await fitness.whenLoaded()
        let before = fitness.summaries.count

        var publishCount = 0
        let cancellable = fitness.objectWillChange.sink { _ in publishCount += 1 }

        // 50 distinct synthetic ids, staggered `start` dates — exercises the real dedup-by-id and
        // sort-by-start-descending path inside `adoptCloudSummary`, not just an append.
        let synthetic: [FitnessSessionSummary] = (0..<50).map { i in
            let session = FitnessSession(
                id: UUID(), start: Date(timeIntervalSinceNow: TimeInterval(-i * 60)), end: nil,
                activity: "verify-fitness-batch", avgHeartRate: nil, totalEnergy: nil,
                totalDistance: nil, samples: [])
            return FitnessSessionSummary(session: session)
        }

        await fitness.applyingCloudBatch {
            for summary in synthetic {
                fitness.adoptCloudSummary(summary)
            }
        }
        cancellable.cancel()

        let after = fitness.summaries.count
        print("[fitness-batch] adopted \(synthetic.count) synthetic summaries inside one applyingCloudBatch scope")
        print("[fitness-batch] objectWillChange fired \(publishCount) time(s) (expect 1)")
        print("[fitness-batch] summaries.count \(before) -> \(after) (expect +\(synthetic.count))")

        // Clean up: these are test fixtures, not real workouts — never let them survive into a
        // profile a person actually looks at (see FitnessStore.previewSessionID for the equivalent
        // guard on the screenshot fixture).
        for summary in synthetic { fitness.delete(summary.id) }
    }
}
#endif
