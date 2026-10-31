import Foundation
import SwiftUI
import os
#if canImport(UserNotifications)
import UserNotifications
#endif

@MainActor
final class WellnessStore: ObservableObject {
    static let shared = WellnessStore()

    // `nonisolated` — `Logger` is inherently thread-safe, and this needs to be usable from both
    // MainActor call sites (e.g. `save()`) and `decodeAndSort`, which runs off the main actor by
    // design (see its doc comment).
    private nonisolated static let log = Logger(subsystem: "com.boris.banana", category: "wellness")

    @Published private(set) var meals: [MealEntry] = []
    @Published private(set) var supplements: [SupplementSchedule] = []
    @Published private(set) var supplementLogs: [SupplementLog] = []
    @Published private(set) var workoutPlans: [WorkoutPlan] = []
    @Published private(set) var workoutCompletions: [WorkoutCompletion] = []
    /// Corrections learned from repeated edits to natural-language food entry rows — see
    /// `FoodCorrectionBook`. Keyed by normalized food name.
    @Published private(set) var foodCorrections: [String: FoodCorrection] = [:]

    var onWorkoutPlansChanged: (() -> Void)?

    /// Decoded + sorted/capped contents of `wellness.json`. Kept as a plain value so the exact
    /// same decode rules can run either inside the background initial-load task or synchronously
    /// from `load()` (used by `reloadFromDisk()`) without duplicating the sort/cap logic.
    private struct DecodedSnapshot: Sendable {
        var meals: [MealEntry] = []
        var supplements: [SupplementSchedule] = []
        var supplementLogs: [SupplementLog] = []
        var workoutPlans: [WorkoutPlan] = []
        var workoutCompletions: [WorkoutCompletion] = []
        var foodCorrections: [String: FoodCorrection] = [:]
    }

    private let fileURL: URL = {
        try? FileManager.default.createDirectory(at: AppSupport.directory, withIntermediateDirectories: true)
        return AppSupport.directory.appendingPathComponent("wellness.json")
    }()

    /// True once the on-disk snapshot has been installed — either by the background initial
    /// decode's merge, or by that decode detecting it was superseded by a synchronous `load()`
    /// (a CloudBackup restore). Callers that must not see an empty history (e.g. Watch plan sync)
    /// await `whenLoaded()` first instead of racing the decode.
    private var isLoaded = false
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []
    /// Bumped by every `load()` call, including the synchronous one `reloadFromDisk()` uses, so
    /// the in-flight background decode can tell a restore already replaced its data and must not
    /// re-merge the now-stale read on top of it.
    private var loadGeneration = 0
    /// A mutation applied in memory before the initial decode has merged has its `save()` call
    /// deferred (see `save()`) so the merge can't clobber it; this flags that a flush is owed once
    /// the merge (or its supersession) resolves.
    private var needsFlushAfterLoad = false
    /// Set when `wellness.json` failed to decode AND could not even be quarantined (copied aside
    /// for safekeeping) — see `decodeAndSort`. In that situation there is no backup anywhere, so
    /// `save()` refuses to run rather than risk being the thing that actually destroys the
    /// owner's only copy. Stays true for the rest of this launch; a relaunch (after the
    /// underlying problem — e.g. a full disk — is resolved by hand) gets a fresh attempt.
    private var saveIsUnsafe = false
    private var saveRevision: UInt64 = 0

    /// Cloud/Watch sync must not read `meals`/`supplements`/etc. while the on-disk snapshot is
    /// still decoding — an empty initial state looks valid but silently omits real history.
    func whenLoaded() async {
        if isLoaded { return }
        await withCheckedContinuation { loadWaiters.append($0) }
    }

    private init() {
        // Decode off the main thread (was a synchronous Data(contentsOf:) + JSONDecoder + 5 sorts
        // of up to 1,500 meals and 2,000 supplement logs before first paint). A mutation that
        // arrives while this is in flight (e.g. a Watch workout completion via
        // PhoneConnectivity.recordWorkoutCompletion) or a CloudBackup restore is handled by the
        // merge/generation guards below instead of being lost or clobbered.
        let url = fileURL
        let capturedGeneration = loadGeneration
        let openedAt = Date()
        Task.detached(priority: .userInitiated) { [weak self] in
            MealRepeatPersistence.cleanAbandonedStages(beside: url, before: openedAt)
            let outcome = Self.decodeAndSort(from: url)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if outcome.mustRefuseSaves { self.saveIsUnsafe = true }
                guard self.loadGeneration == capturedGeneration else {
                    // A synchronous load() (CloudBackup restore) already ran while this decode was
                    // in flight; it is authoritative, and merging this now-stale read on top of it
                    // would reintroduce rows the restore intentionally dropped.
                    self.isLoaded = true
                    self.resolveLoadWaiters()
                    return
                }
                if let decoded = outcome.decoded { self.merge(decoded) }
                self.isLoaded = true
                self.refreshSupplementNotificationsOnce()
                if self.needsFlushAfterLoad {
                    self.needsFlushAfterLoad = false
                    self.save()
                }
                self.resolveLoadWaiters()
            }
        }
    }

    private func resolveLoadWaiters() {
        for waiter in loadWaiters { waiter.resume() }
        loadWaiters.removeAll()
    }

    /// Installs a background decode's result. If nothing mutated the store first (the common
    /// case), the decode is simply assigned. Otherwise only rows not already present (by id) are
    /// appended, then the same sort/cap rule the decode itself uses is reapplied — an early
    /// mutation is preserved exactly rather than being overwritten.
    private func merge(_ decoded: DecodedSnapshot) {
        meals = Self.merged(meals, decoded.meals, sortedBy: { $0.date > $1.date })
        supplements = Self.merged(supplements, decoded.supplements, sortedBy: {
            ($0.safeHour, $0.safeMinute, $0.name) < ($1.safeHour, $1.safeMinute, $1.name)
        })
        supplementLogs = Self.merged(supplementLogs, decoded.supplementLogs, sortedBy: { $0.date > $1.date }, cap: 2_000)
        workoutPlans = Self.merged(workoutPlans, decoded.workoutPlans, sortedBy: { $0.createdAt > $1.createdAt })
        workoutCompletions = Self.merged(workoutCompletions, decoded.workoutCompletions, sortedBy: { $0.startedAt > $1.startedAt })
        // Not Identifiable/array-shaped, so this doesn't go through Self.merged: start from the
        // decoded (disk) dictionary, then let any in-memory entry (a correction recorded before
        // this initial load finished) win — same "early mutation survives" intent as above.
        foodCorrections = decoded.foodCorrections.merging(foodCorrections) { _, inMemory in inMemory }
    }

    private static func merged<T: Identifiable>(
        _ existing: [T], _ decoded: [T], sortedBy areInIncreasingOrder: (T, T) -> Bool, cap: Int? = nil
    ) -> [T] {
        guard !existing.isEmpty else {
            return cap.map { Array(decoded.prefix($0)) } ?? decoded
        }
        guard !decoded.isEmpty else { return existing }
        let existingIDs = Set(existing.map(\.id))
        var merged = existing
        merged.append(contentsOf: decoded.filter { !existingIDs.contains($0.id) })
        merged.sort(by: areInIncreasingOrder)
        return cap.map { Array(merged.prefix($0)) } ?? merged
    }

    /// Result of one `decodeAndSort` attempt: the sorted/capped content ready to `merge()` (nil
    /// when there's nothing to merge — a fresh install, or a corrupt file that was safely
    /// quarantined), plus whether `save()` must refuse to run because even the quarantine copy
    /// could not be made. Kept internal to `WellnessStore` — `WellnessSnapshotLoadResult` (in
    /// `Shared/WellnessModels.swift`) is the reusable/testable part; this just adds the
    /// store-specific sort/cap step and the save-safety verdict on top of it.
    private struct LoadOutcome: Sendable {
        var decoded: DecodedSnapshot?
        var mustRefuseSaves = false
    }

    /// Same decode + sort + cap rules `load()` always used, factored out so the background task
    /// and the synchronous restore path can never drift apart. Runs off the main actor.
    ///
    /// Delegates the actual decode to `WellnessSnapshotLoader`, which tolerates one corrupt
    /// record inside an otherwise-valid file (dropped and counted, not fatal — see
    /// `WellnessSnapshot`) and, on a whole-file decode failure, copies the original bytes aside
    /// before returning. That quarantine copy is what makes it safe for this store to start empty
    /// and let normal saves resume: the *original* `wellness.json` will get overwritten by the
    /// next mutation same as always, but the owner's actual history survives under the quarantine
    /// name, which `save()` never touches. Only if the quarantine copy itself couldn't be made —
    /// no independent backup exists anywhere — does this ask the caller to stop saving instead.
    private nonisolated static func decodeAndSort(from url: URL) -> LoadOutcome {
        switch WellnessSnapshotLoader.load(from: url) {
        case .empty:
            return LoadOutcome()

        case let .loaded(snapshot):
            if snapshot.droppedRecordCount > 0 {
                log.error("wellness.json: dropped \(snapshot.droppedRecordCount, privacy: .public) corrupt record(s) on load; everything else loaded normally")
            }
            let decoded = DecodedSnapshot(
                meals: snapshot.meals.sorted { $0.date > $1.date },
                supplements: snapshot.supplements.sorted {
                    ($0.safeHour, $0.safeMinute, $0.name) < ($1.safeHour, $1.safeMinute, $1.name)
                },
                supplementLogs: Array(snapshot.supplementLogs.sorted { $0.date > $1.date }.prefix(2_000)),
                workoutPlans: snapshot.workoutPlans.sorted { $0.createdAt > $1.createdAt },
                workoutCompletions: snapshot.workoutCompletions.sorted { $0.startedAt > $1.startedAt },
                foodCorrections: snapshot.foodCorrections
            )
            return LoadOutcome(decoded: decoded)

        case let .corrupt(error, quarantinedTo):
            if let quarantinedTo {
                log.error("wellness.json failed to decode (\(String(describing: error), privacy: .public)); original preserved at \(quarantinedTo.lastPathComponent, privacy: .public). Starting empty — history is recoverable from the quarantine copy, and normal saves will only ever touch wellness.json from here on.")
                return LoadOutcome()
            } else {
                log.fault("wellness.json failed to decode (\(String(describing: error), privacy: .public)) AND could not be quarantined — no backup exists. Refusing to save until this is resolved by hand; the original is still at wellness.json, untouched.")
                return LoadOutcome(mustRefuseSaves: true)
            }
        }
    }

    var latestWorkoutPlan: WorkoutPlan? { workoutPlans.first }

    func nutritionTotals(on date: Date, calendar: Calendar = .current) -> NutritionMacros {
        meals.filter { calendar.isDate($0.date, inSameDayAs: date) }
            .reduce(.init()) { $0 + $1.totals }
    }

    func addMeal(_ meal: MealEntry) {
        var sanitized = meal
        sanitized.name = String(sanitized.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        sanitized.items = sanitized.items.map(MealEntry.sanitizedItem)
        meals.insert(sanitized, at: 0)
        save()
        saved(.meal(sanitized.id))
        Telemetry.shared.record(.feature(.mealLogged, Self.telemetryDetail(sanitized.source)))
    }

    /// Encode and stage off the UI thread, then atomically publish only a current snapshot.
    /// A concurrent edit invalidates staging; retry uses the same id and the newer full state.
    func addMealDurably(_ meal: MealEntry) async throws {
        var sanitized = meal
        sanitized.name = String(meal.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        sanitized.items = meal.items.map(MealEntry.sanitizedItem)
        try await commitMealEdit(.add(sanitized))
    }

    func deleteMealDurably(_ id: UUID) async throws {
        try await commitMealEdit(.remove(id))
    }

    private enum MealEdit { case add(MealEntry), remove(UUID) }

    private func commitMealEdit(_ edit: MealEdit) async throws {
        await whenLoaded()
        while true {
            try Task.checkCancellation()
            guard !saveIsUnsafe else { throw CocoaError(.fileWriteNoPermission) }
            let revision = saveRevision
            let generation = loadGeneration
            var current = currentSnapshot()
            switch edit {
            case .add(let meal):
                guard !current.meals.contains(where: { $0.id == meal.id }) else { return }
                current.meals.insert(meal, at: 0)
            case .remove(let id):
                guard current.meals.contains(where: { $0.id == id }) else { return }
                current.meals.removeAll { $0.id == id }
            }
            let snapshot = current
            let url = fileURL
            let staged = try await Task.detached(priority: .userInitiated) {
                try MealRepeatPersistence.stage(snapshot, beside: url)
            }.value
            defer { try? FileManager.default.removeItem(at: staged) }
            try Task.checkCancellation()
            guard revision == saveRevision, generation == loadGeneration else { continue }
            try MealRepeatPersistence.commit(staged, replacing: url)
            saveRevision &+= 1
            meals = snapshot.meals
            CloudBackup.shared.schedule()
            switch edit {
            case .add(let meal):
                saved(.meal(meal.id))
                Telemetry.shared.record(.feature(.mealLogged, Self.telemetryDetail(meal.source)))
            case .remove(let id): deleted([.meal(id)])
            }
            return
        }
    }

    private static func telemetryDetail(_ source: MealEntry.Source) -> Telemetry.Signal.Detail {
        switch source {
        case .manual: .byHand
        case .photo: .photo
        case .barcode: .scan
        case .text: .describe
        }
    }

    /// Corrects a saved meal in place and publishes the same record ID to sync.
    func updateMeal(id: UUID, items: [MealItem], name: String, date: Date? = nil) {
        let updated = MealEntry.applyingUpdate(id: id, items: items, name: name, date: date, to: meals)
        guard updated != meals else { return }
        meals = updated.sorted { $0.date > $1.date }
        save()
        saved(.meal(id))
    }

    func deleteMeal(_ id: UUID) {
        meals.removeAll { $0.id == id }
        save()
        deleted([.meal(id)])
    }

    func upsertSupplement(_ supplement: SupplementSchedule) {
        var sanitized = supplement
        sanitized.name = String(sanitized.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        if sanitized.name.isEmpty { sanitized.name = sanitized.kind.label }
        sanitized.dose = String(sanitized.dose.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        sanitized.note = String(sanitized.note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        sanitized.ingredients = Array(sanitized.ingredients
            .map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)) }
            .filter { !$0.isEmpty }.prefix(60))
        sanitized.hour = sanitized.safeHour
        sanitized.minute = sanitized.safeMinute
        if let index = supplements.firstIndex(where: { $0.id == sanitized.id }) {
            supplements[index] = sanitized
        } else {
            supplements.append(sanitized)
        }
        supplements.sort { ($0.safeHour, $0.safeMinute, $0.name) < ($1.safeHour, $1.safeMinute, $1.name) }
        updateNotification(for: sanitized)
        save()
        saved(.supplement(sanitized.id))
    }

    func deleteSupplement(_ id: UUID) {
        let doses = Set(supplementLogs.filter { $0.supplementID == id }.map { WellnessCloudRecord.dose($0).name })
            .compactMap(WellnessCloudRecord.init(name:))
        supplements.removeAll { $0.id == id }
        supplementLogs.removeAll { $0.supplementID == id }
        removeNotification(id)
        save()
        // Its doses go with it, and this device sends their deletes (DATA-PLATFORM.md §3).
        deleted([.supplement(id)] + doses)
    }

    /// A dose belongs to the day stored on it when it was logged (see `SupplementLog.day`), so
    /// the status, the replace-on-relog below and sync all agree on which day it is.
    func supplementStatus(_ id: UUID, on date: Date = Date(), calendar: Calendar = .current) -> SupplementLog.Status? {
        let key = WellnessCloudChanges.DoseKey(supplementID: id, day: WellnessCloudRecord.dayKey(date, calendar: calendar))
        return supplementLogs.first { WellnessCloudRecord.doseKey($0, calendar: calendar) == key }?.status
    }

    func logSupplement(_ id: UUID, status: SupplementLog.Status, at date: Date = Date(), calendar: Calendar = .current) {
        let day = WellnessCloudRecord.dayKey(date, calendar: calendar)
        let key = WellnessCloudChanges.DoseKey(supplementID: id, day: day)
        supplementLogs.removeAll { WellnessCloudRecord.doseKey($0, calendar: calendar) == key }
        supplementLogs.insert(.init(supplementID: id, date: date, status: status, day: day), at: 0)
        supplementLogs = Array(supplementLogs.prefix(2_000))
        save()
        saved(.dose(supplementID: id, day: day))
    }

    /// Doses brought in all at once — a reminder's ticks, when it moves to Taken
    /// (`ReminderToTaken`). One save for the lot; each day's record syncs as a dose logged by hand
    /// would. A day that already has a dose keeps it: what was logged here wins over an import.
    func importSupplementLogs(_ logs: [SupplementLog], calendar: Calendar = .current) {
        var taken = Set(supplementLogs.map { WellnessCloudRecord.doseKey($0, calendar: calendar) })
        let fresh = logs.filter { taken.insert(WellnessCloudRecord.doseKey($0, calendar: calendar)).inserted }
        guard !fresh.isEmpty else { return }
        supplementLogs = Array((supplementLogs + fresh).sorted { $0.date > $1.date }.prefix(2_000))
        save()
        for log in fresh { saved(WellnessCloudRecord.dose(log, calendar: calendar)) }
    }

    /// Gives each dose logged before days were stored the day it was taken, in this calendar,
    /// once — so sync files it under that day from now on, wherever the device is later.
    func backfillDoseDays(calendar: Calendar = .current) {
        guard supplementLogs.contains(where: { $0.day == nil }) else { return }
        supplementLogs = supplementLogs.map { log in
            var log = log
            if log.day == nil { log.day = WellnessCloudRecord.dayKey(log.date, calendar: calendar) }
            return log
        }
        save()
    }

    /// Meals, supplements and doses changed on another device (`CloudWellnessSync`). One save for
    /// the whole batch, and never echoed back to the cloud. What it brought is told to the data
    /// platform too: while the legacy sync applies it, that's a late arrival (`MoveOver`).
    func applyCloudChanges(_ changes: WellnessCloudChanges) {
        guard !changes.isEmpty else { return }
        var changes = changes
        // Once health and food have moved off iCloud here, a supplement's delete from an old build
        // doesn't take its doses: on the data platform only a dose's own delete does (§3).
        if !LegacyCloud.mayWrite(.health) { changes.cascadesDoses = false }
        applySpaceChanges(changes)
        let changed = changes.meals.map { WellnessCloudRecord.meal($0.id) }
            + changes.supplements.map { WellnessCloudRecord.supplement($0.id) }
            + changes.doses.map { WellnessCloudRecord.dose($0) }
        for (type, ids) in Self.byType(changed) { MoveOver.changed(type: type, ids: ids) }
        let gone = changes.deletedMeals.map { WellnessCloudRecord.meal($0) }
            + changes.deletedSupplements.map { WellnessCloudRecord.supplement($0) }
            + changes.deletedDoses.map { WellnessCloudRecord.dose(supplementID: $0.supplementID, day: $0.day) }
        for (type, ids) in Self.byType(gone) { MoveOver.deleted(type: type, ids: ids) }
    }

    /// Another device's changes in one save: iCloud's (`applyCloudChanges`) or the data platform's
    /// (`WellnessAdapter`, which never cascades a supplement's delete to its doses).
    func applySpaceChanges(_ changes: WellnessCloudChanges) {
        guard !changes.isEmpty else { return }
        WellnessCloudMerge.apply(changes, meals: &meals, supplements: &supplements, logs: &supplementLogs)
        for supplement in changes.supplements {
            if let current = supplements.first(where: { $0.id == supplement.id }) { updateNotification(for: current) }
        }
        for id in changes.deletedSupplements { removeNotification(id) }
        save()
    }

    // MARK: - Telling the syncs

    /// An item edited here: iCloud's sync as before (its mode decides whether it writes), and the
    /// data platform (`MoveOver`).
    private func saved(_ record: WellnessCloudRecord) {
        CloudWellnessSync.shared.saved(record)
        if SpaceSyncFlag.isOn, case .supplement(let id) = record { noteSupplementEdited(id) }
        let (type, id) = record.catalogRecord
        MoveOver.changed(type: type, ids: [id])
    }

    private func deleted(_ records: [WellnessCloudRecord]) {
        CloudWellnessSync.shared.deleted(records)
        for (type, ids) in Self.byType(records) { MoveOver.deleted(type: type, ids: ids) }
    }

    private static func byType(_ records: [WellnessCloudRecord]) -> [(String, [String])] {
        Dictionary(grouping: records.map { $0.catalogRecord }, by: { $0.type })
            .map { ($0.key, $0.value.map { $0.id }) }.sorted { $0.0 < $1.0 }
    }

    // MARK: - Interaction timing

    /// Today as `SupplementInteractions` sees it: everything scheduled, plus everything already
    /// eaten, each with the substances its name gives away.
    ///
    /// Disabled schedules are left out — a supplement you have switched off is not taken, so
    /// warning about it is warning about a day that isn't happening. Meals and medications go in
    /// with an origin that makes them immovable, so the only thing the app ever proposes
    /// rescheduling is a supplement.
    func todaysIntakes(on date: Date = Date(), calendar: Calendar = .current) -> [SupplementInteractions.TimedIntake] {
        let scheduled = supplements.filter(\.enabled).map { supplement in
            SupplementInteractions.TimedIntake(
                name: supplement.name,
                minuteOfDay: supplement.safeHour * 60 + supplement.safeMinute,
                // Name, dose line and ingredient panel all get a look. The dose carries the
                // substance as often as the name does — "Thyroid, 100mcg levothyroxine" names it
                // only in the dose — and the ingredient panel is the only place a multivitamin
                // ever admits what is in it.
                substances: SupplementInteractions.substances(
                    in: ([supplement.name, supplement.dose] + supplement.ingredients).joined(separator: " ")),
                origin: supplement.kind == .medication ? .medication : .supplement)
        }
        let eaten = meals.filter { calendar.isDate($0.date, inSameDayAs: date) }.map { meal in
            let components = calendar.dateComponents([.hour, .minute], from: meal.date)
            let names = meal.items.map(\.name).joined(separator: " ")
            return SupplementInteractions.TimedIntake(
                name: meal.name.isEmpty ? meal.items.first?.name ?? "Meal" : meal.name,
                minuteOfDay: (components.hour ?? 0) * 60 + (components.minute ?? 0),
                substances: SupplementInteractions.substances(in: "\(meal.name) \(names)"),
                origin: .food)
        }
        return scheduled + eaten
    }

    func saveWorkoutPlan(_ plan: WorkoutPlan) {
        workoutPlans.removeAll { $0.id == plan.id }
        workoutPlans.insert(plan, at: 0)
        workoutPlans = Array(workoutPlans.prefix(30))
        save()
        onWorkoutPlansChanged?()
        ControlChangeReporter.changed(.workoutPlan, plan.id.uuidString)
    }

    /// - Returns: what was taken out and where from, for `restoreWorkoutPlan` (Undo).
    @discardableResult
    func deleteWorkoutPlan(_ id: UUID) -> Removed<WorkoutPlan>? {
        let removed = workoutPlans.take { $0.id == id }
        save()
        onWorkoutPlansChanged?()
        ControlChangeReporter.deleted(.workoutPlan, id.uuidString)
        return removed
    }

    /// Brings back a deleted plan where it was (Undo), on every device and the Watch.
    func restoreWorkoutPlan(_ removed: Removed<WorkoutPlan>) {
        workoutPlans.putBack(removed)
        save()
        onWorkoutPlansChanged?()
        ControlChangeReporter.changed(.workoutPlan, removed.item.id.uuidString)
    }

    func recordWorkoutCompletion(_ completion: WorkoutCompletion) {
        workoutCompletions.insert(completion, at: 0)
        workoutCompletions = Array(workoutCompletions.prefix(100))
        save()
        ControlChangeReporter.changed(.workoutCompletion, completion.id.uuidString)
    }

    /// Only returns a correction once the same food has been corrected the same way twice —
    /// see `FoodCorrectionBook`. First-priority source in `FoodTextExtractor.resolve(_:)`,
    /// ahead of even the bundled catalog.
    func lookupLearned(_ name: String) -> FoodCorrection? {
        FoodCorrectionBook.lookup(name, in: foodCorrections)
    }

    /// The same lookup, frozen, for handing to code that runs off the main actor.
    ///
    /// `lookupLearned` is main-actor isolated because the book it reads is `@Published` state on
    /// this store; `FoodTextExtractor.extract` is not, and suspends repeatedly while the on-device
    /// model works. Passing the method itself across that boundary is the data race Swift 6 turns
    /// into an error. Capturing a value copy removes the boundary instead of papering over it —
    /// and makes the extraction self-consistent as a side effect: every row of one meal now
    /// resolves against the same book, rather than against whatever it happens to hold when that
    /// particular row comes back.
    func learnedLookup() -> @Sendable (String) -> FoodCorrection? {
        let corrections = foodCorrections
        return { FoodCorrectionBook.lookup($0, in: corrections) }
    }

    /// Records one edit to a natural-language food entry row — call for any row whose final
    /// macros differ from what was proposed (catalog match or AI estimate). See
    /// `FoodCorrectionBook.recordEdit` for the promote-after-two / reset-on-drift rule.
    func recordEdit(name: String, macros: NutritionMacros, serving: String, grams: Double? = nil) {
        FoodCorrectionBook.recordEdit(name: name, macros: macros, serving: serving, grams: grams, into: &foodCorrections)
        save()
        let key = FoodCorrectionBook.normalize(name)
        if !key.isEmpty { ControlChangeReporter.changed(.foodCorrection, key) }
    }

    func reloadFromDisk() {
        load()
        // A restore replaces the file wholesale. Fetch everything again so what was logged on
        // the other device since the backup comes back too.
        CloudWellnessSync.shared.resyncAfterRestore()
    }

    /// Synchronous decode, used only by `reloadFromDisk()` (a CloudBackup restore, which must be
    /// authoritative and complete before the restore's other side effects run). Bumps
    /// `loadGeneration` so an in-flight background initial decode knows to defer to this result
    /// instead of re-merging its now-stale read on top of it.
    private func load() {
        loadGeneration += 1
        let outcome = Self.decodeAndSort(from: fileURL)
        if outcome.mustRefuseSaves { saveIsUnsafe = true }
        guard let decoded = outcome.decoded else { return }
        // A mutation from before this store finished its very first load (e.g. a Watch workout
        // completion arriving while the background initial decode is still in flight) sets
        // `needsFlushAfterLoad` instead of writing to disk — see `save()`. A plain overwrite here
        // would discard that in-memory-only mutation the instant the restore's decode replaces
        // these arrays. Merge instead, so the restored snapshot and the pending mutation both
        // survive, then flush the merged result so it's not lost again if this races the initial
        // decode's own (now-superseded) merge.
        let hadPendingMutation = needsFlushAfterLoad
        isLoaded = true
        if hadPendingMutation {
            needsFlushAfterLoad = false
            merge(decoded)
            save()
        } else {
            meals = decoded.meals
            supplements = decoded.supplements
            supplementLogs = decoded.supplementLogs
            workoutPlans = decoded.workoutPlans
            workoutCompletions = decoded.workoutCompletions
            foodCorrections = decoded.foodCorrections
        }
        resolveLoadWaiters()
    }

    private func save() {
        saveRevision &+= 1
        // A mutation can land while the initial decode is still in flight (isLoaded == false).
        // Deferring its write instead of saving now keeps the merge in init() from clobbering it
        // with the on-disk snapshot; init() flushes this once the merge has safely applied it.
        guard isLoaded else { needsFlushAfterLoad = true; return }
        // See `decodeAndSort`/`saveIsUnsafe`: only set when wellness.json failed to decode AND
        // couldn't be quarantined, i.e. there is no backup of the original anywhere. Writing here
        // would risk being the actual data-loss event rather than just reflecting an earlier one.
        guard !saveIsUnsafe else {
            Self.log.fault("save() refused: no backup of a previously-corrupt wellness.json exists yet, so writing now would risk destroying the only copy. Resolve by hand and relaunch.")
            return
        }
        let snapshot = currentSnapshot()
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? HealthFileProtection.write(data, to: fileURL)
        CloudBackup.shared.schedule()
    }


    private func currentSnapshot() -> WellnessSnapshot {
        var snapshot = WellnessSnapshot()
        snapshot.meals = meals
        snapshot.supplements = supplements
        snapshot.supplementLogs = supplementLogs
        snapshot.workoutPlans = workoutPlans
        snapshot.workoutCompletions = workoutCompletions
        snapshot.foodCorrections = foodCorrections
        return snapshot
    }


    /// Re-schedule every supplement reminder once per format change. They are otherwise only
    /// rescheduled when edited, so reminders scheduled before they became Time Sensitive would
    /// have stayed ordinary for good.
    private func refreshSupplementNotificationsOnce() {
        let key = "supplementNotifications.timeSensitive.v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        for supplement in supplements { updateNotification(for: supplement) }
        UserDefaults.standard.set(true, forKey: key)
    }

    private func updateNotification(for supplement: SupplementSchedule) {
        // Every device rings its reminders, like bedtime, leave-by and event reminders — a day
        // at a time, by `AnchoredTimingHub`, so today's can be left out once the dose is marked.
        // (A fixed time was one notification repeating daily, which rang whether or not it was.)
        AnchoredTimingHub.shared.refreshSoon()
    }

    private func removeNotification(_ id: UUID) {
        #if canImport(UserNotifications)
        // Every day's: a deleted item's reminders were pending for days after it was gone.
        NotificationWrites.removePending(SupplementSchedule.reminderIDs(id, from: Date()))
        #endif
    }

    #if DEBUG
    /// Stable ids for the preview fixtures.
    ///
    /// These used to be fresh `UUID()`s on every launch, which quietly corrupted every
    /// preview-argument route over repeated runs. `merge()` appends any decoded row whose id is
    /// not already in memory, so last run's persisted fixtures came back alongside this run's
    /// freshly-minted ones and the list grew a duplicate set each time — two "Calcium Citrate"
    /// rows, one at the seeded time and one at wherever a previous run had moved it. With stable
    /// ids the merge recognises them and the seed wins, so every launch starts from the same
    /// state whatever the last one did.
    private static func previewID(_ slot: Int) -> UUID {
        UUID(uuidString: String(format: "BA9A9A00-0000-4000-8000-%012d", slot))!
    }

    #if DEBUG
    /// `--meal-backlog`: photos on the first preview meal, so a logged row's photo can be opened.
    func attachPreviewPhotos(_ ids: [UUID]) {
        guard !meals.isEmpty else { return }
        meals[0].photoIDs = ids
    }
    #endif

    /// The preview's one meal ("Chicken grain bowl"), for a route that opens it.
    static var previewMealID: UUID { previewID(1) }

    func injectPreviewData() {
        meals = [
            MealEntry(id: Self.previewID(1), date: Date(), items: [
                MealItem(name: "Chicken grain bowl", serving: "1 bowl",
                         macros: .init(calories: 640, proteinGrams: 43, carbohydrateGrams: 68, fatGrams: 21),
                         confidence: 0.82),
                MealItem(name: "Greek yogurt", serving: "1 cup",
                         macros: .init(calories: 160, proteinGrams: 18, carbohydrateGrams: 9, fatGrams: 4),
                         confidence: 0.91),
            ], source: .photo),
        ]
        supplements = [
            SupplementSchedule(id: Self.previewID(10), name: "Vitamin D", dose: "1 capsule", hour: 8, minute: 0),
            SupplementSchedule(id: Self.previewID(11), name: "Magnesium", dose: "200 mg", hour: 21, minute: 30),
        ]
        // The timing-clash fixture is deliberately NOT part of the default preview set, which is
        // also what the App Store screenshot pipeline renders (`--wellness`, see
        // tools/app-store/manifest.json). A staged prescription in a store screenshot would
        // advertise a medical feature the app does not claim to be.
        if ProcessInfo.processInfo.arguments.contains("--wellness-taken") {
            // Levothyroxine at 7 with calcium at 7:30 is the textbook clash the timing section
            // exists to catch, and the case where the fix must be to move the calcium.
            supplements.insert(
                SupplementSchedule(id: Self.previewID(12), name: "Levothyroxine", kind: .medication,
                                   dose: "100 mcg", hour: 7, minute: 0),
                at: 0)
            supplements.insert(
                SupplementSchedule(id: Self.previewID(13), name: "Calcium Citrate",
                                   dose: "500 mg", hour: 7, minute: 30),
                at: 1)
        }
        supplementLogs = [.init(id: Self.previewID(20), supplementID: supplements[0].id, status: .taken)]
        workoutPlans = [DeterministicWorkoutBuilder.build(
            preferences: .init(focus: .mixed, experience: .beginner, durationMinutes: 30,
                               equipment: [.bodyweight], notes: ""))]
    }

    /// A week of meals across the parts of the day, for the Mac Nutrition page's visual checks
    /// (its week strip and day-part groups need more than one meal to show anything).
    func injectWeekPreview(now: Date = Date(), calendar: Calendar = .current) {
        func item(_ name: String, _ serving: String, _ kcal: Double, _ p: Double, _ c: Double, _ f: Double) -> MealItem {
            MealItem(name: name, serving: serving,
                     macros: .init(calories: kcal, proteinGrams: p, carbohydrateGrams: c, fatGrams: f), confidence: 0.9)
        }
        let day = calendar.startOfDay(for: now)
        func at(_ offset: Int, _ hour: Int, _ minute: Int) -> Date {
            calendar.date(byAdding: .minute, value: hour * 60 + minute,
                          to: calendar.date(byAdding: .day, value: -offset, to: day) ?? day) ?? day
        }
        var slot = 100
        func meal(_ date: Date, _ name: String, _ items: [MealItem]) -> MealEntry {
            slot += 1
            return MealEntry(id: Self.previewID(slot), date: date, items: items, source: .text, name: name)
        }
        var week: [MealEntry] = [
            meal(at(0, 7, 45), "", [item("Eggs", "2 large", 156, 13, 1, 11), item("Sourdough toast", "1 slice", 120, 4, 23, 1),
                                    item("Flat white", "1 cup", 110, 6, 9, 6)]),
            meal(at(0, 12, 30), "Lunch", [item("Chicken grain bowl", "1 bowl", 640, 43, 68, 21)]),
            meal(at(0, 16, 10), "", [item("Greek yogurt", "1 cup", 160, 18, 9, 4), item("Blueberries", "\u{00BD} cup", 42, 1, 11, 0)]),
        ]
        for offset in 1...5 {
            week.append(meal(at(offset, 8, 0), "", [item("Oatmeal", "1 bowl", 310, 11, 54, 6)]))
            week.append(meal(at(offset, 13, 0), "", [item("Turkey sandwich", "1", 480 + Double(offset * 20), 32, 46, 16)]))
            if offset != 3 {
                week.append(meal(at(offset, 19, 30), "Dinner", [item("Salmon", "150 g", 310, 34, 0, 19),
                                                                item("Rice", "1 cup", 205, 4, 45, 0)]))
            }
        }
        // The fixture above leaves today's evening open, as a day in progress would.
        meals = (week + meals.filter { !week.map(\.id).contains($0.id) }).sorted { $0.date > $1.date }
    }

    /// `--energy-balance`: four weeks of meals for the logs-against-weight card
    /// (`EnergyBalance.Preview`), beside the preview's own. Their ids are stable too, so a
    /// relaunch replaces last run's instead of adding to them.
    func injectPreviewMeals(_ extra: [MealEntry]) {
        let ids = Set(extra.map(\.id))
        meals = (extra + meals.filter { !ids.contains($0.id) }).sorted { $0.date > $1.date }
    }
    #endif
}

// Guided workouts planned and done, and the foods you've corrected, on every device
// (CloudControlsSync) — meals, supplements and doses have their own sync (`CloudWellnessSync`).
extension WellnessStore: CloudControlSource {
    /// One item, encoded (the data platform asks for the few that changed).
    func cloudItem(_ kind: ControlKind, id: String) -> Data? {
        let encoder = JSONEncoder()
        switch kind {
        case .workoutPlan: return workoutPlans.first { $0.id.uuidString == id }.flatMap { try? encoder.encode($0) }
        case .workoutCompletion: return workoutCompletions.first { $0.id.uuidString == id }.flatMap { try? encoder.encode($0) }
        case .foodCorrection: return foodCorrections[id].flatMap { try? encoder.encode($0) }
        default: return nil
        }
    }

    func cloudItems(_ kind: ControlKind) -> [String: Data] {
        let encoder = JSONEncoder()
        var items: [String: Data] = [:]
        switch kind {
        case .workoutPlan: for plan in workoutPlans { items[plan.id.uuidString] = try? encoder.encode(plan) }
        case .workoutCompletion: for done in workoutCompletions { items[done.id.uuidString] = try? encoder.encode(done) }
        case .foodCorrection: for (key, fix) in foodCorrections { items[key] = try? encoder.encode(fix) }
        default: break
        }
        return items
    }

    func applyCloud(_ kind: ControlKind, id: String, item: Data?) -> Bool {
        let decoder = JSONDecoder()
        switch kind {
        case .workoutPlan:
            let plan = item.flatMap { try? decoder.decode(WorkoutPlan.self, from: $0) }
            if item != nil, plan == nil { return true }
            workoutPlans.removeAll { $0.id.uuidString == id }
            if let plan {
                workoutPlans.append(plan)
                workoutPlans.sort { $0.createdAt > $1.createdAt }
            }
            save()
            onWorkoutPlansChanged?()
        case .workoutCompletion:
            let done = item.flatMap { try? decoder.decode(WorkoutCompletion.self, from: $0) }
            if item != nil, done == nil { return true }
            workoutCompletions.removeAll { $0.id.uuidString == id }
            if let done {
                workoutCompletions.append(done)
                workoutCompletions.sort { $0.startedAt > $1.startedAt }
                workoutCompletions = Array(workoutCompletions.prefix(100))
            }
            save()
        case .foodCorrection:
            let fix = item.flatMap { try? decoder.decode(FoodCorrection.self, from: $0) }
            if item != nil, fix == nil { return true }
            foodCorrections[id] = fix
            save()
        default:
            break
        }
        return true
    }
}

// The data platform's first pull can bring a hundred completions: one save for the lot.
extension WellnessStore: HealthFood.BatchSource {
    func applyCloudBatch(_ kind: ControlKind, _ items: [(id: String, item: Data?)]) -> [String: Bool] {
        let decoder = JSONDecoder()
        var changed = false
        for (id, item) in items {
            switch kind {
            case .workoutPlan:
                let plan = item.flatMap { try? decoder.decode(WorkoutPlan.self, from: $0) }
                if item != nil, plan == nil { continue }
                workoutPlans.removeAll { $0.id.uuidString == id }
                if let plan { workoutPlans.append(plan) }
                changed = true
            case .workoutCompletion:
                let done = item.flatMap { try? decoder.decode(WorkoutCompletion.self, from: $0) }
                if item != nil, done == nil { continue }
                workoutCompletions.removeAll { $0.id.uuidString == id }
                if let done { workoutCompletions.append(done) }
                changed = true
            case .foodCorrection:
                let fix = item.flatMap { try? decoder.decode(FoodCorrection.self, from: $0) }
                if item != nil, fix == nil { continue }
                foodCorrections[id] = fix
                changed = true
            default:
                break
            }
        }
        if changed {
            switch kind {
            case .workoutPlan:
                workoutPlans.sort { $0.createdAt > $1.createdAt }
            case .workoutCompletion:
                // Kept to 100 here; pruning here deletes nothing anywhere else (DATA-PLATFORM.md §3).
                workoutCompletions.sort { $0.startedAt > $1.startedAt }
                workoutCompletions = Array(workoutCompletions.prefix(100))
            default:
                break
            }
            save()
            if kind == .workoutPlan { onWorkoutPlansChanged?() }
        }
        return Dictionary(items.map { ($0.id, true) }, uniquingKeysWith: { first, _ in first })
    }
}

// What the data platform's meals, supplements and doses adapter needs of the store.
extension WellnessStore: WellnessSyncPort {
    /// iCloud's edit time where it runs; for a supplement, also the one kept here (a supplement
    /// has no time of its own to seed from).
    func editedAt(_ record: WellnessCloudRecord) -> Date? {
        if let edited = CloudWellnessSync.shared.editedAt(record) { return edited }
        if case .supplement(let id) = record { return Self.supplementEdits[id.uuidString] }
        return nil
    }

    private static let supplementEditsKey = "spaceSync.supplementEditedAt"
    private static var supplementEdits: [String: Date] {
        (UserDefaults.standard.dictionary(forKey: supplementEditsKey) as? [String: Date]) ?? [:]
    }

    fileprivate func noteSupplementEdited(_ id: UUID) {
        var edits = Self.supplementEdits
        edits[id.uuidString] = Date()
        let live = Set(supplements.map(\.id.uuidString))
        UserDefaults.standard.set(edits.filter { live.contains($0.key) }, forKey: Self.supplementEditsKey)
    }
}

