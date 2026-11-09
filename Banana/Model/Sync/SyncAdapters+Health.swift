#if BANANA_MODULE_WORKOUTS
import Foundation

extension SyncAdapters {
    /// Health and food (T2, Stage C): `health.*` and `food.*` in `Shared/DataCatalog.json`. They
    /// sync only with the Health consent (§7); the engine holds it, and `MoveOver` moves this tier
    /// only once it's given.
    ///
    /// | Type | Store |
    /// |---|---|
    /// | `food.meal`, `food.supplement`, `food.dose` | `WellnessStore` (`WellnessAdapter`) |
    /// | `health.workoutPlan`, `health.workoutCompletion`, `food.correction` | `WellnessStore` as a `CloudControlSource` |
    /// | `food.myFood` | `MyFoodsStore` |
    /// | `food.mealInbox` | `MealInboxStore` |
    /// | `food.mealPhoto` | `MealPhotoStore` (`MealPhotoAdapter`, the JPEG as blob `v`) |
    /// | `food.mealPhotoFound` | `MealPhotoLedger` |
    /// | `food.searchPick` | `FoodSearchPicks` (one record per query) |
    /// | `food.estimatorStatus`, `food.photoScanReport` | `MealEstimators`, `MealPhotoScanReports` (one record per install) |
    /// | `health.snapshot` | `HealthKitStore` (`HealthSnapshotAdapter`, hub only, paced) |
    /// | `health.workout` | `FitnessStore` (`WorkoutAdapter`, recordings as blob `samples`) |
    /// | `health.removalRequest`, `health.workoutRevert` | `HealthRemovalInbox`, `WorkoutRevertInbox` |
    static func healthAndFood(_ stores: SyncStores) -> [any RecordAdapter] {
        let isHub = DeviceRole.current.isHub
        let hooks = HealthFood.EngineHooks(
            ensureBlob: { type, id, field in
                guard let engine = await MainActor.run(body: { SpaceSyncLaunch.engine }) else { return false }
                return await engine.ensureBlob(type: type, id: id, field: field)
            },
            replay: { types in
                guard let engine = await MainActor.run(body: { SpaceSyncLaunch.engine }) else { return }
                await engine.replay(types: types)
            })
        let controlsEditedAt: (ControlKind, String) -> Date? = { kind, id in
            CloudControlsSync.editedAt(kind, id: id)   // an offer's 1970 counts as none (`HealthFood.ownTime`)
        }
        let directory = AppSupport.directory.appendingPathComponent("SpaceSync", isDirectory: true)

        let snapshot = HealthSnapshotAdapter(port: stores.health, isHub: isHub, directory: directory)
        stores.health.onSnapshotChange = { [weak snapshot] urgent in snapshot?.snapshotChanged(urgent: urgent) }
        let workouts = WorkoutAdapter(port: stores.fitness, isHub: isHub, hooks: hooks, directory: directory)
        stores.fitness.fetchSpaceSamples = { id in
            await hooks.ensureBlob(WorkoutAdapter.type, id.uuidString, WorkoutAdapter.samples)
        }
        if !reportingHealth {
            reportingHealth = true
            ControlChangeReporter.alsoReportHealthToSpace()
        }
        SpaceSyncQuestions.shared.hasHealthData = { [weak wellness = stores.wellness, weak fitness = stores.fitness,
                                                     weak health = stores.health] in
            !(wellness?.meals.isEmpty ?? true) || !(wellness?.supplements.isEmpty ?? true)
                || !(fitness?.summaries.isEmpty ?? true) || (isHub && health?.hasData == true)
        }

        SpaceSyncQuestions.shared.consentChanged = { [weak health = stores.health] consent in
            // Without the Health consent an iPad or a Mac shows no Health at all (§7).
            health?.setShowsNoHealth(!isHub && !consent)
        }

        let adapters: [any RecordAdapter] = [
            WellnessAdapter(port: stores.wellness),
            HealthFood.ControlSourceAdapter(source: stores.wellness, kinds: FoodKinds.wellnessControls, editedAt: controlsEditedAt),
            HealthFood.ControlSourceAdapter(source: stores.myFoods, kinds: [FoodKinds.myFood], editedAt: controlsEditedAt),
            HealthFood.ControlSourceAdapter(source: stores.mealInbox, kinds: [FoodKinds.mealInbox], editedAt: controlsEditedAt),
            MealPhotoAdapter(photos: stores.mealPhotos, editedAt: controlsEditedAt),
            HealthFood.ControlSourceAdapter(source: stores.mealPhotoLedger, kinds: [FoodKinds.mealPhotoFound], editedAt: controlsEditedAt),
            HealthFood.KeyedValuesAdapter(type: FoodSearchPicks.spaceType, port: FoodSearchPicksPort(), whole: false),
            HealthFood.KeyedValuesAdapter(type: MealEstimators.spaceType, port: MealEstimatorsPort(stores.mealEstimators),
                                          whole: true) { $0.at },
            HealthFood.KeyedValuesAdapter(type: MealPhotoScanReports.spaceType, port: MealPhotoScanReportsPort(stores.mealPhotoScanReports),
                                          whole: true) { $0.checkedAt ?? $0.completedAt },
            snapshot,
            workouts,
            HealthRequestsAdapter(type: HealthRemovalInbox.spaceType, port: stores.removalInbox),
            HealthRequestsAdapter(type: WorkoutRevertInbox.spaceType, port: stores.revertInbox),
        ]
        assert(adapters.flatMap(\.types).sorted() == HealthFood.types.sorted(), "one adapter for each of HealthFood.types")
        return adapters
    }

    /// The controls' health kinds report to the data platform from the first time adapters join.
    private static var reportingHealth = false

}
#endif
