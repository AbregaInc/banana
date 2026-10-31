#if DEBUG && os(macOS)
import Foundation

/// Operator-run driver for the Fitness-zone phantom-record purge (deletion mechanics in
/// `CloudProgressSync.swift`'s `#if DEBUG` `CloudFitnessSync` extension; delete-list loading and
/// overlap validation in `Shared/FitnessModels.swift`'s `FitnessZonePurgePlan`). Launch arguments
/// read from `ProcessInfo.processInfo.arguments`, in the same family as this app's other
/// `--verify-*`/`--snapshot-*`/`--*-dump` developer harnesses (`FitnessBatchVerification`,
/// `CommuteDump`, `MacAppStoreSnapshotHarness`): DEBUG-only, never reached by a normal launch.
///
/// This tool does NOT query the CloudKit zone to discover what to delete — an earlier version
/// did (`CKDatabase.records(matching:)`, filtering by `recordName`), and it failed against the
/// real account with a genuine CloudKit error:
///
///     CKError "Invalid Arguments" (12/2015); server message = "Field 'recordName' is not marked
///     queryable"
///
/// `recordName` is a system field, and this container's schema never marked it Queryable for the
/// `SettingsSnapshot` record type — every query against it fails this way, including a
/// match-everything `NSPredicate(value: true)`, because CloudKit still needs an index on the
/// field to enumerate records of a type at all. That is a property of the owner's account schema,
/// not something client code can route around — see `Shared/FitnessModels.swift`'s "Fitness-zone
/// purge delete list" section for the fuller explanation, kept there so the next person hits the
/// comment before reaching for `records(matching:)` again.
///
/// Deletion by record ID needs no queryable index at all, so this tool instead deletes a KNOWN
/// list of record names supplied on disk — generated ahead of time, out-of-band, from evidence
/// gathered entirely outside CloudKit (the pre-dedup backup of the local index, hash-verified
/// before the dedup that made these records phantom).
///
///   `--purge-fitness-zone-delete-list <path>` — REQUIRED with either mode below. Path to the
///     JSON `FitnessZonePurgeDeleteList`: the record names to delete, and, separately, the record
///     names known real (never deleted; carried only so the file's own consistency can be
///     asserted before anything else happens).
///
///   `--purge-fitness-zone-dry-run` — load the delete list, validate it against the live local
///     index (`FitnessZonePurgePlan.validate`), print and write exactly what WOULD be deleted.
///     Deletes nothing, ever. Safe to run any number of times.
///
///   `--purge-fitness-zone-apply` — re-run that same validation, then actually delete the listed
///     records through the sync engine's own deletion path, in batches. Writes the report to the
///     SAME path before deleting anything and again after every batch, so the deletion is
///     auditable afterwards regardless of how far it got.
///
/// Deliberately two separate, explicit, differently-worded launch arguments rather than one
/// "clean up" command behind a flag: `-dry-run` and `-apply` share a long common prefix and then
/// diverge on one unambiguous trailing word, so neither a truncated paste nor a skim-read of one
/// can be mistaken for the other, and every report written to disk also carries its own `dryRun`
/// field for the same reason. An operator should always be able to see what would be deleted
/// before anything is. Wired into `BananaApp.wireUp()` right after `CloudFitnessSync.shared
/// .start(...)` — the sync engine and the local index (needed for the live real-workout safety
/// check) must both already be live.
enum CloudFitnessZonePurgeTool {
    /// Fixed, not caller-supplied — matches `CommuteDump.outPath`'s precedent (`/tmp`, not a
    /// launch-argument value) for this app's other one-off developer dumps.
    static let reportURL = URL(fileURLWithPath: "/tmp/banana-fitness-zone-purge-report.json")

    private static let dryRunFlag = "--purge-fitness-zone-dry-run"
    private static let applyFlag = "--purge-fitness-zone-apply"
    private static let deleteListFlag = "--purge-fitness-zone-delete-list"

    static func runIfRequested() async {
        let arguments = ProcessInfo.processInfo.arguments
        let dryRun = arguments.contains(dryRunFlag)
        let apply = arguments.contains(applyFlag)
        guard dryRun || apply else { return }
        guard !(dryRun && apply) else {
            print("[fitness-zone-purge] FAILED: pass exactly one of \(dryRunFlag) / \(applyFlag), not both")
            return
        }
        guard let flagIndex = arguments.firstIndex(of: deleteListFlag), flagIndex + 1 < arguments.count else {
            print("[fitness-zone-purge] FAILED: \(deleteListFlag) <path> is required")
            return
        }
        await run(deleteListPath: arguments[flagIndex + 1], dryRun: dryRun)
    }

    private static func run(deleteListPath: String, dryRun: Bool) async {
        let modeText = dryRun ? "DRY RUN (deletes nothing)" : "APPLY — this will delete records"
        print("[fitness-zone-purge] mode: \(modeText)")

        let listURL = URL(fileURLWithPath: deleteListPath)
        let deleteList: FitnessZonePurgeDeleteList
        do {
            let data = try Data(contentsOf: listURL)
            deleteList = try JSONDecoder().decode(FitnessZonePurgeDeleteList.self, from: data)
        } catch {
            print("[fitness-zone-purge] FAILED to load delete list at \(listURL.path): \(error)")
            return
        }
        print("[fitness-zone-purge] loaded \(deleteList.phantomRecordNames.count) phantom id(s) and \(deleteList.realRecordNames.count) real id(s) from \(listURL.path)")

        do {
            let runLog = try await CloudFitnessSync.shared.purgeCorruptWorkouts(
                deleteList: deleteList, deleteListPath: listURL.path, dryRun: dryRun, reportURL: reportURL)
            if dryRun {
                print("[fitness-zone-purge] would delete \(runLog.wouldDeleteRecordNames.count) record(s):")
                for name in runLog.wouldDeleteRecordNames {
                    print("[fitness-zone-purge]   \(name)")
                }
                print("[fitness-zone-purge] nothing was deleted. Re-run with \(applyFlag) to delete the records above.")
            } else {
                print("[fitness-zone-purge] deleted: \(runLog.deletedRecordNames.count)")
            }
            print("[fitness-zone-purge] report written to \(reportURL.path)")
        } catch {
            // Validation (self-contradicting file, or overlap with the live local index) throws
            // before any write happens — nothing was deleted and no report was produced.
            print("[fitness-zone-purge] ABORTED — nothing was deleted, no report written: \(error)")
        }
    }
}
#endif
