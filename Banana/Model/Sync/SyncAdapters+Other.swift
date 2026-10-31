import Foundation

extension SyncAdapters {
    /// Everything else (T1, Stage D): the `core.*`, `plan.*`, `podcast.*` and `notes.*` types in
    /// `Shared/DataCatalog.json`, every one of them, so the personal tier's legacy channels can
    /// move (`MoveOver`: a tier moves only once every type it carries has an adapter).
    ///
    /// | Type | Store |
    /// |---|---|
    /// | `plan.routine`, `plan.alarm`, `plan.wake` | `RoutineStore`, `AlarmStore`, `WakeStore` (`ControlsAdapter`) |
    /// | `plan.override`, `plan.extra` | `ExceptionStore` (`ControlsAdapter`) |
    /// | `podcast.show`, `podcast.settings` | `PodcastLibrary` (`ControlsAdapter`) |
    /// | `podcast.progress` | `PodcastLibrary` (`PodcastProgressAdapter`) |
    /// | `podcast.listen` | `ListenHistoryStore` (`ListenAdapter`, the route a blob) |
    /// | `podcast.skipPlan`, `.adSlots`, `.skipCorrection` | `SkipPlanStore` (`ControlsAdapter`) |
    /// | `podcast.narratorReading`, `.narratorGender`, `.narratorOverride` | `NarratorVoiceStore` (`ControlsAdapter`) |
    /// | `podcast.transcript` | `TranscriptStore` (`TranscriptAdapter`, the body a lazy blob) |
    /// | `notes.voiceNote` | `VoiceNoteStore` (`VoiceNoteAdapter`, the audio an eager blob) |
    /// | `core.appSettings`, `.modules`, `.smartSettings`, `.wakePlan`, `.hubStatus`, `.hubRequest` | `AppSettings`, `ModuleStore`, `SmartScheduleStore`, `HubStatusStore` (`SettingsAdapters`) |
    /// | `plan.bookingType` | `BookingTypeStore` (`BookingTypeAdapter`) |
    /// | `plan.taskDuration`, `.reminderAnchor`, `.reminderAnchorUsual`, `.missedRepeat`, `.declinedSuggestion`, `.notNow`, `core.guestPick` | `TaskDurationStore`, `ReminderAnchors`, `MissedRepeats`, `AnchorSuggestionStore`, `GuestPicks` (`KeyValueAdapters`) |
    static func everythingElse(_ stores: SyncStores) -> [any RecordAdapter] {
        let edited: @MainActor (ControlKind, String) -> Date? = { CloudControlsSync.editedAt($0, id: $1) }
        func control<T: Codable>(_ kind: ControlKind, _ source: CloudControlSource, _ model: T.Type,
                                 _ shape: SyncShape = .fields) -> SyncBinding {
            ControlsAdapter.binding(LegacyInventory.controlKinds[kind.rawValue]!, kind: kind, source: source,
                                    codec: .model(model, shape: shape), editedAt: edited)
        }
        let adapters: [any RecordAdapter] = [
            BoundAdapter("routines, alarms and wake sounds", [
                control(.routine, stores.routines, Routine.self),
                control(.alarm, stores.alarms, OneOffAlarm.self),
                control(.wake, stores.wake, WakeSource.self, .wrapped),
            ]),
            BoundAdapter("timeline", [
                control(.timelineOverride, stores.exceptions, ExceptionStore.Kind.self, .wrapped),
                control(.timelineExtra, stores.exceptions, ExceptionStore.Extra.self),
            ]),
            BoundAdapter("podcast library", [
                control(.show, stores.library, PodcastSubscription.self),
                control(.podcast, stores.library, PodcastSettings.self),
                PodcastProgressAdapter.binding(stores.library),
            ]),
            ListenAdapter.adapter(stores.listenHistory),
            BoundAdapter("skip plans", [
                control(.skipPlan, stores.skipPlans, StoredSkipPlan.self),
                control(.adSlots, stores.skipPlans, DeclaredAdSlots.self),
                control(.skipCorrection, stores.skipPlans, Int.self, .wrapped),
            ]),
            BoundAdapter("narrator voices", [
                control(.narratorReading, stores.narratorVoices, NarratorVoiceStore.Reading.self),
                control(.narratorGender, stores.narratorVoices, NarratorVoiceStore.Reading.self),
                control(.narratorOverride, stores.narratorVoices, VoiceGender.self, .wrapped),
            ]),
            TranscriptAdapter.adapter(TranscriptStore.shared),
            VoiceNoteAdapter.adapter(stores.voiceNotes),
            SettingsAdapters.adapter(stores),
            KeyValueAdapters.adapter(stores),
            BookingTypeAdapter.adapter(stores.bookingTypes),
        ]
        assert(Set(adapters.flatMap(\.types)) == Set(EverythingElseTypes.all), "EverythingElseTypes is out of date")
        return adapters
    }

    /// As these adapters join: the transcript index is read (or built once) off the main actor,
    /// without holding them up. Transcripts it lists after a seed has begun enter as late
    /// arrivals, with their seed clocks (`TranscriptStore.prepareSyncIndex`).
    static func prepareEverythingElse() async {
        Task { await TranscriptStore.shared.prepareSyncIndex() }
    }
}
