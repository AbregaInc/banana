import Foundation

/// The stores the adapters wrap (docs/design/DATA-PLATFORM.md §6, DATA-INVENTORY.md "Seams"), as
/// `BananaApp.wireUp` holds them, handed over once every store has loaded. The ones with a
/// `shared` instance are here too, so an adapter never reaches for a singleton the app doesn't
/// use. `GuestPicks` and `FoodSearchPicks` are static and are reached directly.
@MainActor
///
/// A module's stores are there only in a build that carries the module (BANANA_MODULES): set after
/// the core ones (`SyncStores(routines:…)` then `stores.library = …`), so one call site serves every
/// build. Its adapters are left out with it; `MoveOver` moves a tier only once every type it
/// carries has an adapter, so a build without a module never moves that module's tier.
struct SyncStores {
    // plan
    let routines: RoutineStore
    let alarms: AlarmStore
    let wake: WakeStore
    let exceptions: ExceptionStore
    let taskDurations: TaskDurationStore
    let reminderAnchors: ReminderAnchors
    let missedRepeats: MissedRepeats
    let anchorSuggestions: AnchorSuggestionStore
    let bookingTypes: BookingTypeStore
    #if BANANA_MODULE_PODCASTS
    var library: PodcastLibrary! = nil
    var listenHistory: ListenHistoryStore! = nil
    var skipPlans: SkipPlanStore! = nil
    var narratorVoices: NarratorVoiceStore! = nil
    #endif
    #if BANANA_MODULE_NOTES
    var voiceNotes: VoiceNoteStore! = nil
    #endif
    #if BANANA_MODULE_WORKOUTS
    var fitness: FitnessStore! = nil
    var health: HealthKitStore! = nil
    var removalInbox: HealthRemovalInbox! = nil
    var revertInbox: WorkoutRevertInbox! = nil
    #endif
    #if BANANA_MODULE_FOOD
    var wellness: WellnessStore! = nil
    var myFoods: MyFoodsStore! = nil
    var mealInbox: MealInboxStore! = nil
    var mealPhotos: MealPhotoStore! = nil
    var mealPhotoLedger: MealPhotoLedger! = nil
    var mealPhotoScanReports: MealPhotoScanReports! = nil
    var mealEstimators: MealEstimators! = nil
    #endif
    // core
    let smart: SmartScheduleStore
    let settings: AppSettings
    let modules: ModuleStore
    let hubStatus: HubStatusStore
}

/// Where adapters join the engine (`SpaceSyncLaunch` registers what these return, once the engine
/// is up and the stores have loaded). Two halves, for the two stages that write them: health and
/// food (Stage C, `SyncAdapters+Health.swift`) and everything else (Stage D,
/// `SyncAdapters+Other.swift`).
///
/// The contract an adapter follows, beyond `RecordAdapter`:
/// - **Ids.** A record's id is the store's own id for the item, as `LegacyInventory` lists them,
///   so what the legacy drain reports (`DrainResult`) names the same records.
/// - **Reports.** The store's change reports go to `MoveOver.changed`, `.offered` and `.deleted`
///   (not to the engine directly): while a legacy channel applies what it fetched, those are late
///   arrivals and enter the mirror with their seed clocks (§3 seeding rule 6).
/// - **`remove`** takes items out of the store through its usual delete path, without a cascade
///   the deleting device didn't send (§3). `MoveOver` uses it for items deleted elsewhere before
///   the seed (`DrainResult.absent`) and for deletes the drain couldn't send; the legacy channels
///   are `readOnly` by then, so nothing reaches iCloud.
/// - **Coverage.** A tier of legacy channels moves only once every type it carries
///   (`LegacyInventory`) has an adapter: register a type only when its adapter is complete.
@MainActor
enum SyncAdapters {
    /// Every adapter, in registration order.
    static func all(_ stores: SyncStores) -> [any RecordAdapter] {
        #if BANANA_MODULE_WORKOUTS || BANANA_MODULE_FOOD
        healthAndFood(stores) + everythingElse(stores)
        #else
        everythingElse(stores)
        #endif
    }

    /// Another account signed in and the person said to clear this device first (§2): nothing of
    /// the account before may stay to seed into the new one. Only once no tier writes iCloud (the
    /// caller makes both read-only first; the device's floor keeps them there), so none of this
    /// reaches the other account's iCloud. Nil, and nothing cleared, while a tier still writes.
    ///
    /// - Every item every adapter covers (health and food, and the personal types) leaves its store
    ///   through the adapter's `remove`, the stores' adopt-from-cloud delete paths, which tell no
    ///   sync.
    /// - Podcast progress, transcripts, the settings that are one value (app settings, modules,
    ///   Smart Schedule and the wake plan, the hub status) go back to a new install's, through
    ///   their stores' account-change functions.
    /// - An iPad's or Mac's copy of the phone's Health goes; the removal and revert requests go.
    static func clearLocalData(_ stores: SyncStores) async -> Int? {
        guard LegacyTier.allCases.allSatisfy({ !LegacyCloud.mayWrite($0) }) else { return nil }
        await prepareEverythingElse()
        // What resets below rather than item by item (the health snapshot's type, `health.snapshot`).
        let reset: Set<String> = ["health.snapshot", "podcast.progress", "podcast.transcript"]
        var count = 0
        for adapter in all(stores) {
            for type in adapter.types where !reset.contains(type) {
                let ids = Array(adapter.snapshot(type).keys)
                guard !ids.isEmpty else { continue }
                adapter.remove(type, ids: ids.sorted())
                count += ids.count
            }
        }
        #if BANANA_MODULE_PODCASTS
        stores.library.clearProgressForAccountChange()
        TranscriptStore.shared.clearForAccountChange()
        #endif
        stores.settings.resetForAccountChange()
        stores.modules.resetForAccountChange()
        stores.smart.resetForAccountChange()
        stores.hubStatus.resetForAccountChange()
        #if BANANA_MODULE_WORKOUTS
        stores.health.clearForAccountChange()
        stores.removalInbox.clearForAccountChange()
        stores.revertInbox.clearForAccountChange()
        #endif
        return count
    }
}
