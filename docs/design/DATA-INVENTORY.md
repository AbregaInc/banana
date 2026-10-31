# What Banana keeps in iCloud today (19 Oct 2026)

This is the source list for the move in DATA-PLATFORM.md. Paths are from the repo root. Line numbers are as of commit eb86171e.

## How it fits together

- **Container:** `AppCloud.containerID` (`Banana/Model/AppSupport.swift:11`) in the private database. Stable and Beta use different containers.
- **Who uses it:** the iOS app (iPhone and iPad) and the Mac app. The Watch has no iCloud and gets everything from the iPhone over WatchConnectivity.
- **Record types:** `SettingsSnapshot` (`payload: Data`, plus `samplesAsset: CKAsset` in Fitness) is used everywhere except Progress, which uses `EpisodeProgress` (`position`, `completed`, `updatedAt`).
- **Local files** live in `AppSupport.directory` (Application Support, or `Banana Beta/`).
- **Polling:** `CloudSyncPoll` checks once a minute while the app is open. It uses `CloudChangeCheck` (UserDefaults `dbChanges.private.token`) and then `CloudZonePoller` for each zone (`zonePoll.<zone>`).
- **Push:** the only CloudKit push is the `meals-zone-changes` zone subscription (`MealBacklogWake.swift:68`).
- **Hub:** `DeviceRole.current` (`DeviceRole.swift:18`), where `isHub` means the iPhone. Only the hub:
  - reads and publishes Health, the wake plan and the hub status;
  - carries out removal requests;
  - seeds the routine, alarm and wake lists;
  - makes the backup and arms alarms.
- **Where it starts:**
  - `BananaApp.swift:113-116`: `ControlChangeReporter.connectToCloud()` and `MealBacklogWake.startSync()`.
  - `wireUp()` (`:676/715`, and `:703` without a window). It starts, in order:
    - `:772-780` settings fan-out (LAN peer, `CloudSettingsSync`)
    - `:784` `CloudBackup.bind`
    - `:786` `HubStatusStore.onRequest`
    - `:798` `HealthRemovalInbox.attach`
    - `:802` `WorkoutRevertInbox.attach`
    - `:908` `CloudProgressSync.start`
    - `:911-957` `controls.register` for each kind, then `controls.start()`
    - `:962` `CloudFitnessSync.start`
    - `:966` `CloudWellnessSync.start`
    - then `CloudSyncPoll`

## CloudKit

### Zones Controls and Meals (`CloudControlsSync`)

- **Record:** `SettingsSnapshot` named `<kind>-<id>`. Long ids are stored as `~<sha256>`, with the real id in `envelope.key` (`ControlsCloudRecords.swift:76-85`).
- **Payload:** JSON `ControlEnvelope {editedAt, deleted, item, key, packed}` (`:117`). Items over 16 KB are LZFSE-compressed; items over 900 KB are not sent.
- **Code:** built at `CloudControlsSync.swift:407-439`, parsed at `:444`.
- **Merge:** `ControlMerge.remoteWins` (`ControlsCloudRecords.swift:156`): the later `editedAt` wins. Deletes are tombstones.
- **Phone-set kinds** (routine, alarm, wake): on an iPad or Mac's first sync, local items the phone doesn't have are dropped (`ControlMerge.localOnly`).

| Kind | Swift type | Store, local file | Notes | Health |
|---|---|---|---|---|
| routine | `Routine` (`RoutineModels.swift:152`) | `RoutineStore`, `routines.json` | phone-set | |
| alarm | `OneOffAlarm` (`OneOffAlarm.swift:5`) | `AlarmStore`, UserDefaults `oneOffAlarms` | phone-set; only the phone arms | |
| wake | `WakeSource` (`WakeStore.swift:35`) | `WakeStore`, UserDefaults `audioSources` | phone-set | |
| show | `PodcastSubscription` (`Podcast.swift:373`) | `PodcastLibrary`, `podcasts.json` | the same feed URL is de-duplicated | |
| podcast | `PodcastSettings` (`Podcast.swift:331`) | `PodcastLibrary` | never deleted; held back until the show exists | |
| timelineOverride / timelineExtra | `ExceptionStore.Kind/.Extra` (`ExceptionStore.swift:13/19`) | `ExceptionStore`, `timeline-exceptions.json` | | |
| listen | `ListenEvent` without its route (`ListenEvent.swift:22`) | `ListenHistoryStore`, `listen_history.json` | thousands of records | |
| listenRoute | route file bytes | `ListenRoutes/<uuid>.route` | GPS | location |
| skipPlan / adSlots / skipCorrection | `StoredSkipPlan`, `DeclaredAdSlots` (`SkipPlanStore.swift:11/48`), Int | `SkipPlanStore`, `AdSkip/*.json` | | |
| narratorReading / Gender / Override | `NarratorVoiceStore.Reading`, `VoiceGender` | `NarratorVoiceStore`, `narrator-voices.json` | | |
| workoutPlan / workoutCompletion | `WorkoutPlan`, `WorkoutCompletion` (`Shared/WellnessModels.swift:720/760`) | `WellnessStore`, `wellness.json` | completions capped at 100 | **yes** |
| foodCorrection | `FoodCorrection` (`WellnessModels.swift:369`) | `WellnessStore` | | **yes** |
| myFood | `MyFood` (`MyFoods.swift:8`) | `MyFoodsStore`, `my-foods.json` | | **yes** |
| mealInbox (zone Meals) | `MealInboxItem` (`MealBacklog.swift:9`) | `MealInboxStore`, `meal-inbox.json` | "offered" at time 0 | **yes** |
| mealPhoto (zone Meals) | JPEG bytes (`MealPhotoStore.swift:91-103`) | `MealPhotos/<uuid>.jpg` | up to 900 KB, inline | **yes** |
| mealPhotoFound (zone Meals) | `Date` per photo key (`MealPhotoLedger.swift:55/62`) | `meal-photo-found.json` | offered only, never deleted | **yes** |

Seams:
- **Protocol** `CloudControlSource` (`ControlsCloudRecords.swift:176`): `cloudItems`, `cloudItemIDs`, `cloudItem(_:id:)` and `applyCloud(_:id:item:) -> Bool`.
- **Outbound:** `ControlChangeReporter.changed/.deleted/.offered` (`:203-210`), wired in `connectToCloud()` (`CloudControlsSync.swift:640`).
- **Registering:** `CloudControlsSync.register(_:for:)` (`:124`).

### Zone Wellness (`CloudWellnessSync`)

- **Record:** `SettingsSnapshot`. `payload` is `WellnessCloudEnvelope {editedAt, item}` (`WellnessCloudRecords.swift:70`).
- **Code:** built at `CloudWellnessSync.swift:352`, parsed at `:378` and `:420`.
- **Merge:** `WellnessCloudConflict.resolve` (`:104`): a pending local delete wins, otherwise the later `editedAt`. `WellnessCloudMerge.apply` (`:136`) caps meals at 1,500 and logs at 2,000, and deleting a supplement deletes its doses.
- **Deletes are real CloudKit deletes.** Store: `WellnessStore`, `wellness.json`.

| Data | Record name | Type | Health |
|---|---|---|---|
| meal | `meal-<uuid>` | `MealEntry` (`Shared/WellnessModels.swift:141`) | **yes** |
| supplement / medication | `supplement-<uuid>` | `SupplementSchedule` (`:486`) | **yes** |
| dose | `dose-<uuid>-<yyyyMMdd>` | `SupplementLog` (`:610`) | **yes** |

Seams:
- **Outbound:** `CloudWellnessSync.shared.saved(_:)` (`:216`) and `.deleted(_:)` (`:228`), called from `WellnessStore.swift:211, 233, 239, 261, 271, 288, 300`.
- **Inbound:** `WellnessStore.applyCloudChanges(_:)` (`:317`).
- **Also:** `resyncAfterRestore()` (`:430`).

### Zone Progress (`CloudProgressSync`)

- **Record:** `EpisodeProgress`, named by the episode GUID. Built at `CloudProgressSync.swift:359`, parsed at `:378` and `:468`.
- **Merge:** the later `updatedAt` wins, with ties going to `library.localWinsTie`. Progress for an episode that hasn't arrived yet is parked in UserDefaults `cloudProgressParked`. Nothing is ever deleted.
- **Sending:** manual. Progress goes up on pause, stop, switch, background, foreground and poll.
- **Store:** `PodcastLibrary`, `progress.json` and `live-progress.json`.

Seams:
- `CloudProgressSync.shared.enqueue([episodeID])` (`PodcastLibrary.swift:832`) and `flushNow(reason:)`.
- `library.progressValue(episodeID:)` (`:751`) and `allProgressEpisodeIDs()` (`:788`).
- `library.applyCloudProgress(...)` (`:820`) and `applyingRemoteBatch` (`:472`).

### Zone Fitness (`CloudFitnessSync`, `CloudProgressSync.swift:651+`)

- **Code:** built at `:1153`, parsed at `:1207`, deletes at `:1292`. Names are routed in `Shared/FitnessModels.swift:787/810/890`.
- **Merge:** the local revision `Date` against the record's server `modificationDate`, which mixes clocks.
- **Deletes are real**, and pending deletes made before the engine starts are lost.

| Data | Record | Store | Writers | Health |
|---|---|---|---|---|
| workout | `workout-<uuid>`: `payload` = `FitnessSessionSummary` (`Shared/FitnessModels.swift:174`), `samplesAsset` = `Fitness/<uuid>.samples` | `FitnessStore`, `Fitness/summaries.json`, `*.samples`, `*.orig` | recorded on the Watch, then the phone; any device edits or deletes | **yes** (heart rate, GPS, motion), large |
| health snapshot | `health-cache`: `payload` is `"IN-ASSET"` or LZFSE JSON, `samplesAsset` is the packed `HealthKitStore.Payload` (workouts, trends, nights, hidden ids) | `HealthKitStore`, `health.json`; `cloudSnapshot` `:1125`, `adoptCloudSnapshot` `:1137` | **phone only** | **yes**, over 1 MB |
| voice note | `note-<uuid>`: JSON `VoiceNote` (`VoiceNote.swift:13`) | `VoiceNoteStore`, `VoiceNotes/notes.json`; the later `syncDate` wins (`:824`) | any | |

Seams:
- `CloudFitnessSync.shared.upsert(summary)`, `.upsert(note)`, `.delete(id)`, `.deleteNote(id)` and `.pushHealthSnapshot()`.
- Seeding: `.seedLocalSummaries` and `.seedLocalHealthIfPresent`.
- Inbound: `FitnessStore.adoptCloudWorkout(_:samplesAssetURL:)` (`:323`), `removeCloudSummary` (`:596`), `applyingCloudBatch` (`:439`) and `samplesFileForCloudSync` (`:312`).
- Voice notes: `VoiceNoteStore.cloudNotesSnapshot`, `adoptCloudNote` and `removeCloudNote` (`:822-840`).

### Zone Settings (`CloudSettingsSync`)

- **Record:** one, `smart-settings`, holding the Smart Schedule `CloudSettingsSnapshot` (`SmartScheduleStore.swift:507`).
- **Merge:** the later `updatedAt` wins (`SmartScheduleStore.adopt`, `:1842`).
- **The same payload also goes** to the key-value store and the LAN peer.

Seams: `smart.onSettingsBroadcast` → `CloudSettingsSync.push(Data)`, and `onSnapshot` → `adoptSettingsSnapshot(Data)` (`:1835`).

## iCloud key-value store

| Key | Data | Code | Writers | Merge today | Health |
|---|---|---|---|---|---|
| `appSettings` | app preferences | `AppSettings.swift:105/228/237` | any | no timestamp; any non-nil field that differs is adopted | borderline |
| `modules` | `ModuleChoice` | `ModuleStore.swift:19/72/94` | any | last writer | |
| `smartScheduleSettings.v1` | `CloudSettingsSnapshot` | `SmartScheduleStore.swift:488/1824/1883` | any | later `updatedAt` | |
| `smartWakePlan.v1` | `WakePlan` | `:489/1997/1890` | phone | replaced; used only if the time zone matches | from sleep |
| `hubStatus.v1` | `HubStatus` | `HubStatus.swift:104/170/175` | phone | later `updatedAt` | status |
| `hubRequests.v1` | Watch resync, back up now | `HubStatus.swift:105/136` (handled: `hubRequestsHandled.v1`) | iPad, Mac → phone | time per kind | |
| `healthRemovalRequests.v1` | `[HealthRemovalRequest]` (`HealthRemovalRequests.swift:11`) | `HealthRemovalInbox.swift:12/49/85` (handled: `healthRemovalRequestsHandled.v1`) | iPad, Mac → phone | appended; 7 days; at most 50 | **yes** |
| `workoutRevertRequests.v1` | `[WorkoutRevertRequest]` (`WorkoutEdits.swift:6`) | `WorkoutRevertInbox.swift:14/41` | any → whoever holds the original | appended | **yes** |
| `taskDurations.v1` | id → {minutes, updatedAt} | `TaskDurationStore.swift:22/94/107` (`task-durations.json`) | any | later time per entry | |
| `reminderAnchors.v1`, `.usual.v1` | key → `TimingAnchor` / Int | `ReminderAnchors.swift:12-13` | any | the whole dictionary, last writer | borderline |
| `missedRepeats.v1` | missed counts | `MissedRepeats.swift:15` | any | last writer; 40 days | |
| `anchorSuggestions.declined.v1`, `reminderToTaken.notNow.v1` | `[String]`, at most 300 | `AnchorSuggestionStore.swift:46-47/398/408` | any | last writer | |
| `guestPicks.v1` | name → email → count | `GuestSources.swift:112` | any | last writer | contacts |
| `foodSearchPicks.v1` | query → food → count | `FoodSearchSources.swift:76` | any | last writer | nutrition |
| `mealEstimators.v1` | install id → `MealEstimatorStatus` | `MealEstimators.swift:9/39` | each device its own | per device | |
| `mealPhotoScan.reports` | install id → `MealPhotoScanReport` | `MealPhotoLedger.swift:79/101` | each device its own | per device | |
| `podcastPeerGroupToken.v1` | the LAN peer secret | `DownloadManager.swift:1113/1384` | first device | written once | **stays** |
| `googleCalendar.accountHint.v1` | an email | `GoogleCalendarService.swift:158/1912` | any | last writer | **stays** |

## iCloud Drive (`Documents/` in the ubiquity container)

| Path | Data | Code | Health |
|---|---|---|---|
| `backup.plist`, `previous-backup.plist` | the full backup: podcasts, progress, routines, listens, exceptions, **wellness.json**, **Fitness/summaries.json**, routes, portable UserDefaults (`BackupRules.portable`) | `CloudBackup.swift:126-137/185-190`, phone only (`:213`) | **yes** |
| `Transcripts/<sha256(episode)>.lzfse` | `Transcript` (`TranscriptModels.swift:12`) | `Transcript.swift:140-178`; the higher `source.qualityRank` wins | |
| `VoiceNotes/<uuid>.m4a`, `.json`, `.deleted` | note audio, older metadata, tombstones | `VoiceNoteStore.swift:899-960`, `apply` `:713` | |

## Keychain (synced, stays)

`SyncedKeychain` (`GoogleAccountStore.swift:71`) holds two items:
- `credentials`: the Google tokens.
- `banana-session`: the Banana session.

## Known faults the move fixes

- Fitness deletes made before the engine starts are kept only in memory.
- Fitness compares a device clock with server time.
- `appSettings` has no timestamp.
- Key-value dictionaries lose entries when two devices write at once.
- Bad records already sit in the Fitness zone (`CloudFitnessZonePurgeTool`).
- A legacy container is still read once for restores (`AppCloud.legacyContainerID`).
