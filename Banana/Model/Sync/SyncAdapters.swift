import Foundation

/// The stores the adapters wrap (docs/design/DATA-PLATFORM.md §6, DATA-INVENTORY.md "Seams"), as
/// `BananaApp.wireUp` holds them, handed over once every store has loaded. The ones with a
/// `shared` instance are here too, so an adapter never reaches for a singleton the app doesn't
/// use. `GuestPicks` and `FoodSearchPicks` are static and are reached directly.
@MainActor
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
    // podcast
    let library: PodcastLibrary
    let listenHistory: ListenHistoryStore
    let skipPlans: SkipPlanStore
    let narratorVoices: NarratorVoiceStore
    // notes
    let voiceNotes: VoiceNoteStore
    // health
    let fitness: FitnessStore
    let health: HealthKitStore
    let removalInbox: HealthRemovalInbox
    let revertInbox: WorkoutRevertInbox
    // food
    let wellness: WellnessStore
    let myFoods: MyFoodsStore
    let mealInbox: MealInboxStore
    let mealPhotos: MealPhotoStore
    let mealPhotoLedger: MealPhotoLedger
    let mealPhotoScanReports: MealPhotoScanReports
    let mealEstimators: MealEstimators
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
        healthAndFood(stores) + everythingElse(stores)
    }
}
