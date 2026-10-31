# Performance & Battery Audit — Banana

## Current status — 19 Jul 2026

The report below is the original 14 Jul audit and is retained as a traceable history. Its
“outstanding” labels are not the current source of truth. The current implementation status is:

- All crash-tier render, backup, progress-catalogue, audio-session, sensor, GPS, download, and
  persistence findings have been fixed without deleting podcast history, playback progress,
  transcripts, listen routes, or workout samples.
- Phone playback keeps its live 1 Hz position in a leaf `PlaybackClock`. Durable progress is a
  small checkpoint, not a rewrite or publish of the full podcast catalogue.
- Watch playback now follows the same design: a leaf `WatchPlaybackClock` updates the visible
  ring/time while the root, workout screen, and episode list remain stable. A small 60-second
  `WatchPlayheadCheckpoint` preserves crash recovery without serializing the full progress map.
- Phone and Watch downloads use daemon-backed background sessions. Automatic downloads obey the
  Wi-Fi policy, user overrides are explicit, resume state is retained, and the Watch can adopt
  in-flight tasks after process relaunch instead of duplicating them.
- HealthKit is anchored and cached; workout raw samples remain file-backed and are loaded only
  for a selected workout. Listen-route geometry is also a lazy sidecar rather than part of every
  launch decode.
- Weather, travel, geocoding, image, occurrence, and feed work is cached, bounded, coalesced, or
  single-flight as appropriate. CloudKit and iCloud backup work is dirty-gated and does not run
  on each playback tick.
- Playback Log renders one bounded text block (latest 250 lines) instead of hundreds of separate
  selectable SwiftUI nodes. The full file is still available through Copy.

### Current evidence

- iOS Debug and Release simulator builds succeed with no compiler diagnostics. The iOS Release
  build includes the Watch app and both widget extensions.
- The returning-user UI smoke test passes on the iPhone 17 Pro simulator, confirming the optimized
  launch reaches the main app without replaying onboarding or crashing.
- Watch Debug builds cleanly after the clock/checkpoint/download changes.
- macOS Debug and Release builds succeed. Xcode 26.6 emits one harmless build-tool warning because
  the Mac target intentionally has no `AppIntents.framework` dependency:
  `Metadata extraction skipped. No AppIntents.framework dependency found.`
- A fresh instrumented simulator launch showed one bounded first-paint burst (31% process CPU over
  the initial five-second weather/layout interval), followed by 0% CPU and no SwiftUI body
  evaluations in every subsequent five-second sample.
- The two available local `Banana-*.ips` reports are old simulator `SIGTRAP`s in eager
  `CKContainer.init`. CloudKit container construction is now lazy and simulator-gated; neither
  report is a CPU, memory, or power kill.
- No current physical-phone journal was available during this pass because both phones were
  unavailable to CoreDevice. Screen-off playback and thermal behavior therefore still require the
  non-destructive real-device soak in `PERF-PLAN.md` §4 and `TESTING-CHECKLIST.md` §12.

### Intentionally retained growth

Listen-history metadata, fitness summaries, podcast history, and raw workout files are not
destructively capped. Their high-volume geometry/sample payloads are already lazy. Archiving or
pagination can be added later, but silently deleting behavior history to “fix” theoretical growth
would violate the product requirement and is not part of this pass.

---

> **Validation status (14 Jul 2026).** Every finding below was re-checked before acting on it, in the
> Simulator, with measurements rather than reasoning. **One of the seven CRITICALs was wrong.** The
> ones marked ✅ FIXED were confirmed by measurement and fixed; ❌ WRONG was disproved; the rest are
> validated-but-outstanding.
>
> | # | Status |
> |---|--------|
> | C1 render loop | ❌ **WRONG** — 0.0% CPU, zero body evals. SwiftUI doesn't re-run the GeometryReader closure on a body pass, so the `Date()` is never re-captured. No loop. |
> | C2 iCloud dedup | ✅ **FIXED** — confirmed dead (two hashes of identical data differed), then found a *second* cause: `PropertyListSerialization` isn't byte-stable for a dictionary. Both fixed; verified MATCH. |
> | C3 progress in catalogue | ⚠️ **PARTLY** — the iCloud half is fixed (no upload on the playback tick). The 3.6 MB main-thread encode every 30s remains. |
> | C4 audio session | ✅ **FIXED** — category still set at launch; activation deferred to first play. |
> | C5 Watch sensors | ✅ **FIXED** — `stopSensors()` now runs on abnormal session end and failure. |
> | C6 indoor GPS | ✅ **FIXED** — GPS skipped when `indoor`; `distanceFilter` added. |
> | C7 download session | ⏳ outstanding (foreground session, no cellular policy). |
> | H8 unbuffered writes | ✅ **FIXED** — 8 KB buffer; ~180k syscalls/hour → ~800. |
> | H9 Watch ticker/session | ✅ **FIXED** — ticker invalidated on pause; session deactivated on stop. |
> | H10 download progress | ✅ **FIXED** — throttled to whole percents. |
> | H11 weather TTL | ✅ **FIXED** — 15-minute TTL; `refreshIfStale()`. |
>
> The lesson from C1: the reasoning was sound and the conclusion was false. Measure.

Read-only audit of the whole codebase (iPhone app, Watch app, widgets). **Nothing was changed.**
Six independent passes: view layer, timers/wakeups, persistence/IO, sensors/frameworks,
WatchConnectivity/Watch, networking/media.

Findings are deduplicated and ordered by cost. Where two passes found the same thing independently,
that's noted — those are the highest-confidence items.

⚠️ **Five of the seven CRITICAL findings were introduced on 13 Jul 2026**, in the weather-stripe and
iCloud-backup work. They are marked **[NEW TODAY]**. The pre-existing code is in better shape than
the code I added to it.

---

## The five that matter

| # | What | Cost | Mine? |
|---|------|------|-------|
| C1 | Unbounded SwiftUI render loop (Today + Week) | Pins a CPU core at 60–120 Hz with no user interaction | **[NEW TODAY]** |
| C2 | iCloud backup dedup can never fire | ~440 MB/hour uploaded while listening | **[NEW TODAY]** |
| C3 | Playback progress stored inside the episode catalogue | ~430 MB/hour of disk writes + ~100 ms main-thread stall every 30 s | pre-existing |
| C4 | Audio session activated at launch, never deactivated on pause | App never suspends → permanent background drain | pre-existing |
| C5 | Watch: sensors never stopped if a workout ends abnormally | 25 Hz IMU + best-accuracy GPS run until the app is killed | pre-existing |

---

## CRITICAL

### C1. Unbounded render loop in TodayView and WeekView **[NEW TODAY]**
`Banana/Views/TodayView.swift:377,382` · `Banana/Views/WeekView.swift:161` · `Banana/Views/WeatherStripe.swift:28`

The weather stripe learns where each row sits by publishing a `TimeAnchor` per row through a
`PreferenceKey`, and the view writes the result back into `@State`:

```swift
if index == nowIdx { nowMarker.background(timeAnchor(Date())) }   // TodayView:377
...
.onPreferenceChange(TimeAnchorKey.self) { timeAnchors = $0 }      // TodayView:167
```

`TimeAnchor` is `Equatable` on `(time: Date, y: CGFloat)`, and the now-marker's anchor is stamped
with a **fresh `Date()` on every body evaluation**. So:

> body → new `Date()` → preference value differs → `onPreferenceChange` → `@State` mutates → body → …

**This never converges.** It re-renders as fast as SwiftUI will turn passes, and each pass re-runs the
whole timeline body (≈1,600 `Calendar.isDate` calls + 2 sorts — see H4), plus seven `Canvas` weather
stripes in Week. Active whenever Today has weather, or Week is open.

*Fix:* quantize the now-anchor to the minute (or drive it from `TimeelineView(.everyMinute)`) so the
published value is stable between frames.

### C2. The iCloud backup dedup is structurally dead — every save uploads the whole library **[NEW TODAY]**
`Banana/Model/CloudBackup.swift:151-172` (`makeSnapshot`) and `:116-127` (the hash guard)

```swift
return Snapshot(savedAt: Date(),                    // ← unique on every call
                device: …, files: payload, defaults: …)
...
let payload = try PropertyListEncoder().encode(snapshot)
let hash = SHA256.hash(data: payload)…              // ← hashes savedAt too
if !userInitiated, hash == lastHash { return }      // ← therefore never matches
```

`savedAt` is *inside* the hashed payload, so the hash differs every time and the early-return can
**never** fire. Every `PodcastLibrary.save()`, `RoutineStore.save()`, `ListenHistory.save()` and
`ExceptionStore.save()` therefore performs a complete backup cycle: re-read four files + the entire
UserDefaults domain, plist-encode, SHA-256 (all on the **main actor**), then upload to iCloud.

Combined with C3 (a library save every 30 s of playback) that is roughly **440 MB/hour uploaded to
iCloud while you listen** — backgrounded, screen off, on cellular. The `audio` background mode keeps
the process alive to do it.

The comment above the guard explains carefully why SHA-256 was used instead of `hashValue`… while
hashing a timestamp.

*Fix:* hash only `files` + `defaults`; and don't schedule a backup from the playback-progress path.

### C3. Playback progress is stored inside the episode catalogue
`Banana/Model/PodcastLibrary.swift:221-225` ← `Banana/Model/PlayerController.swift:334-338`
*(found independently by the persistence, timers and networking passes)*

The 1 Hz time observer calls `saveProgressSnapshot()` every 30 ticks → `save()` → JSON-encodes
**every episode of every feed, including full HTML show notes**, and atomically rewrites the file.

For a realistic library (12 feeds × 250 episodes ≈ 3,000 episodes × ~1.2 KB) that's a **~3.6 MB
encode + write, on the main thread, every 30 seconds of listening**: ~430 MB/hour of flash writes and
a ~60–120 ms hitch every 30 s, forever. The existing comment ("persist occasionally — not every tick")
throttles the *frequency* but the payload is O(all episodes).

*Fix:* split progress into its own small `progress.json`; only rewrite the catalogue when a feed
actually changes; encode off the main actor.

### C4. AVAudioSession activated at launch and never deactivated on pause
`Banana/Model/PlayerController.swift:51-55, 282-293, 185-191`
*(found independently by the timers and sensors passes)*

`configureAudioSession()` runs in `PlayerController.init()`, and `PlayerController` is built eagerly by
`WakeCoordinator.shared`, which `BananaApp.init` touches. So **every** process launch — including
headless background launches for the overnight task, WatchConnectivity file receipt, and AlarmKit
intents — does `setCategory(.playback)` + `setActive(true)` with nothing playing.

Deactivation happens only in `stop()`. The common path — pause via `setPlaying(false)` — leaves the
session active permanently. With `UIBackgroundModes: [audio, processing]`, an active `.playback`
session tells iOS the app is producing audio, so **the app is never suspended**. This is the single
biggest silent drain on the phone.

*Fix:* activate lazily on first `play()`; deactivate with `.notifyOthersOnDeactivation` after pause.

### C5. Watch: sensors are never stopped if the workout ends abnormally
`BananaWatch/WorkoutRecorder.swift:221-237, 279-287`

`stopSensors()` is called from exactly one place: the user tapping stop. But
`workoutSession(_:didChangeTo:from:date:)` is **empty**, and `didFailWithError` only records the error.
If HealthKit or the system ends the session any other way, `CMMotionManager` keeps delivering device
motion at **25 Hz**, `CLLocationManager` keeps running at **`kCLLocationAccuracyBest`**, the 1 Hz timer
keeps ticking and `SampleWriter` keeps writing — indefinitely, until the app is killed.

*Fix:* call `stopSensors()` from `didChangeTo(.ended/.stopped)` and from `didFailWithError`.

### C6. Watch: continuous best-accuracy GPS for **indoor** workouts
`BananaWatch/WorkoutRecorder.swift:230-231`
*(found independently by the sensors and watch passes)*

`startSensors()` unconditionally sets `kCLLocationAccuracyBest` and `startUpdatingLocation()`, with no
`distanceFilter`. `start(activity:name:indoor:)` already accepts an `indoor` flag and threads it into
`HKWorkoutConfiguration.locationType` — but `startSensors()` never reads it. A yoga session runs a
full GNSS fix train for its duration. Continuous best-accuracy GPS is the most expensive thing a Watch
can do.

*Fix:* skip `startUpdatingLocation()` when `indoor`; set `distanceFilter ≈ 5–10 m` and
`activityType = .fitness` otherwise.

### C7. Episode downloads use a foreground URLSession, with no cellular policy
`Banana/Model/DownloadManager.swift:30-32, 318`

`URLSession(configuration: .default, …)` — so downloads die when the app suspends, and
`didCompleteWithError` **discards the resume data**, restarting a 50–150 MB MP3 from byte zero.
`allowsCellularAccess` is never set anywhere, and there's no Wi-Fi-only setting: "Download All Older"
on a large feed is gigabytes over LTE with no gate.

The **Watch already does this correctly** (`WatchDownloadManager.swift:24-29` uses a background
session with `sessionSendsLaunchEvents`), which makes the phone side look like an oversight.

*Fix:* background session + resume data + a Wi-Fi-only toggle + `isDiscretionary` for rule-driven
downloads.

---

## HIGH

### H1. The 1 Hz playback tick republishes the entire library and re-renders half the app
`Banana/Model/PlayerController.swift:317-341` → `Banana/Model/PodcastLibrary.swift:119-125`
*(found by three passes)*

`updateProgress` mutates the `@Published podcasts` array **every second**, firing `objectWillChange` on
`PodcastLibrary` for the whole session. Observers: `PodcastsView`, `PodcastDetailView`, `NowPlayingBar`,
`NowPlayingView`, `TodayView`, `RootView`, `RoutineEditorView`. Separately, `PlayerController.currentTime`
is itself `@Published` at 1 Hz and is observed by `TodayView`, `WeekView`, `TranscriptView`, `RootView`…

So during playback, roughly half the app re-renders once a second — **including with the screen off**.
It also multiplies C1.

*Fix:* keep the live position in `PlayerController` only; push into the library at commit points
(`commitProgress()` already exists for exactly this). Split the high-frequency position into a small
observable that only the scrubber watches.

### H2. `hasNextEpisode` / `hasPreviousEpisode` fully sort the feed — twice per render, once a second
`Banana/Model/PlayerController.swift:377-384` → `Banana/Model/Podcast.swift:138-143`

`ordered()` does a full `sorted()` + `reversed()` of every episode. `NowPlayingView` reads both
properties in its body, and its body re-runs every second (H1) → **two full sorts per second** while
the player is open. Under C1's loop, per frame.

*Fix:* cache `ordered()` on `Podcast`; precompute the current index when `play()` sets the episode.

### H3. `PodcastDetailView.episodeMenu` is O(n) per row → O(n²) per render
`Banana/Views/PodcastDetailView.swift:188-196`

`before`, `after` and a full `[String: Episode]` dictionary are built **eagerly per row**, not inside
the menu's lazy content closure. 500-episode feed × ~12 visible rows ≈ 18,000 element visits + 12
dictionary builds *per body pass* — and the body passes every second (H1).

*Fix:* hoist `byID` out of the row; move `before`/`after` inside the menu's content closure.

### H4. TodayView recomputes the day timeline ~4× per body evaluation
`Banana/Views/TodayView.swift:63-70, 94-104, 108-127, 626-630` → `Banana/Model/OccurrenceStore.swift:135-137`

`occurrences(on:)` filters the whole occurrence array with a `Calendar.isDate` per element. The body
calls it at least four times (`moments`, `nextItem`, `timelineCard`, `replannableCount`), and `dayItems`
adds a linear routine lookup per cue plus a sort. With a 14-day horizon (~200–400 occurrences) that's
~1,600 calendar comparisons + 2 sorts **per pass** — at 1 Hz, or per-frame under C1.

WeekView already solves this correctly (cached `[DayData]`, rebuilt only on `occurrences.$occurrences`).

*Fix:* do the same in TodayView; add a day-bucketed index to `OccurrenceStore`.

### H5. `OccurrenceStore.recompute()` does 14 synchronous EventKit queries on the main actor
`Banana/Model/OccurrenceStore.swift:26-78` (loop at `:52-55`)

Fourteen `store.events(matching:)` calls back-to-back on the main thread (10–50 ms each →
**140–700 ms of block**), plus an unbounded Reminders fetch, plus `CalendarWriteBack.sync()`, plus the
AlarmKit re-arm (H6). Called from **21 view-layer sites** — `.task` on Today/Week/Tomorrow, `.refreshable`,
and *every* context-menu action. `PlannerTab` swaps view identity on the Day↔Week toggle, so each
toggle re-runs the whole thing.

*Fix:* move the EventKit fan-out off the main actor; add a staleness guard and coalesce concurrent calls.

### H6. Every recompute cancels and re-arms up to 20 AlarmKit alarms
`Banana/Model/AlarmStore.swift:210-231` ← `Banana/Model/OccurrenceStore.swift:98`

`scheduleWakeOccurrences` calls `cancelSmartWakes()` then re-schedules each date, with **no diff**
against what's already armed. Runs on every recompute → every tab switch, every foreground, every
calendar sync: up to 20 XPC cancels + 20 XPC schedules to the system alarm daemon.

*Fix:* diff the desired dates against `wakeAlarmTimes` and return early when unchanged.

### H7. `EKEventStoreChanged` triggers the full cascade, and write-back can re-trigger itself
`Banana/Model/SmartScheduleStore.swift:286-295`

The observer runs `refreshAgenda()` + `recompute()` unconditionally on **every** EventKit sync from any
account (bursty — a CalDAV sync emits several). Each one costs H5 + H6 + an `MKDirections.calculateETA()`
**network call per meeting**.

Worse: `CalendarWriteBack.save()` commits **per event** (`CalendarWriteBack.swift:110`), and each commit
posts `.EKEventStoreChanged` → fires this observer again. Write-back is currently disabled by default,
so this loop is latent — but it's armed.

*Fix:* debounce 5–10 s; skip recompute when the change was self-authored; batch writes with
`commit: false` + a single `store.commit()`.

### H8. Watch: 25 Hz CoreMotion with one `write()` syscall **per sample**
`BananaWatch/WorkoutRecorder.swift:67,224-228` · `BananaWatch/SampleWriter.swift:30-37`
*(found by three passes)*

`deviceMotion` at 25 Hz appends **two** samples per callback → 50 appends/sec, each allocating a 33-byte
`Data` and issuing an **unbuffered `FileHandle.write`**. That's ~**180,000 syscalls + 180,000 allocations
per hour** of workout, on a watch, on battery — plus `deviceMotion` runs the full sensor-fusion pipeline
(accel + gyro + magnetometer), which is much costlier than raw accelerometer updates.

*Fix:* buffer to ~8–16 KB and flush; use raw accel/gyro if fused attitude isn't needed.

### H9. Watch: 1 Hz playback ticker never invalidated on pause; audio session never deactivated
`BananaWatch/WatchAudioPlayer.swift:64-75, 91-100, 113-117`
*(found by two passes)*

`togglePlayPause()`'s pause branch doesn't invalidate `ticker` — only `stop()` and the finish delegate
do. So a paused episode keeps a 1 Hz timer waking the watch CPU and republishing `@Published` state
forever. And `setActive(true)` is the only `setActive` call in the whole watch target — the session is
never deactivated, holding the audio route.

*Fix:* invalidate the ticker in the pause branch; `setActive(false, options: .notifyOthersOnDeactivation)`
in `stop()` and on finish.

### H10. Download progress publishes on every URLSession chunk callback
`Banana/Model/DownloadManager.swift:290-299` · `BananaWatch/WatchDownloadManager.swift:55-66`
*(found by three passes)*

`didWriteData` hops to `@MainActor` and mutates `@Published states` on **every received chunk** — tens
of times per second per task. "Download All Older" can run many concurrent tasks → a main-thread flood,
each mutation re-rendering the podcast list (which is already O(n²) per H3).

This is the identical pathology that transcription already fixed (per-word → per-mille). Same bug,
different file.

*Fix:* throttle to whole-percent changes.

### H11. Weather refetches on every appearance — no TTL
`Banana/Model/WeatherStore.swift:84-115` ← `TodayView.swift:236`, `WeekView.swift:106`
*(found by three passes)*

`refresh()` has no staleness check: every appearance of Today or Week does a location fix + a network
forecast fetch + a reverse-geocode. `PlannerTab` swaps view identity on the Day↔Week toggle, so **each
toggle of that segmented control is a fresh forecast fetch**.

*Fix:* skip if the last fetch is < ~15–30 min old and the coordinate hasn't meaningfully moved.

### H12. Resuming a transcription can write a ~500 MB temp file that survives a jetsam **[NEW TODAY]**
`Banana/Model/TranscriptionService.swift:102-176` ← `Banana/Model/TranscriptCoordinator.swift:195-197`

On resume (`startAt > 0`), `writeSegment` decodes **the entire remaining audio** into uncompressed
16 kHz PCM: 32 kB/s → **~518 MB for 4.5 h remaining**. The `defer` cleanup covers throw/cancel but
**not process termination** — which is exactly what causes a resume (an expired background task). iOS
only purges `tmp` under storage pressure, so an interrupted long transcription can orphan half a
gigabyte, and each resume writes another.

*Fix:* cap segment length instead of "rest of episode"; sweep the temp directory on launch.

### H13. The transcription checkpoint rewrites the entire word array every 20 s **[NEW TODAY]**
`Banana/Model/TranscriptCoordinator.swift:185-189` · `Banana/Model/TranscriptionService.swift:252-255`

`savePartial(id, Partial(words: base + words))` re-encodes **all words so far**, every checkpoint, on
the main actor. A 4.5 h episode ≈ 40,500 words ≈ 2.2 MB final → total written ≈ final × N/2:
~26 MB at 52× realtime, **~180 MB if throttled to 5×**. Genuinely O(n²) in episode length, and the
per-checkpoint main-thread encode (~2.2 MB, ~50–100 ms) competes with the transcription it's
checkpointing.

*Fix:* append-only NDJSON — write only the words added since the last checkpoint.

### H14. Nothing is ever pruned
- `TranscriptStore.delete` (`Banana/Model/Transcript.swift:75-78`) has **zero callers**. Deleting a
  download leaves the transcript behind. The overnight batch transcribes every download → ~200 MB
  after 300 episodes, in Application Support (not purgeable, counts against backup).
- `clearPartial` runs **only on success** — a failed or repeatedly-interrupted transcription leaves its
  partial (up to 2.2 MB) forever, with no sweep. **[NEW TODAY]**
- Workout samples: **~6 MB per workout-hour**, uncompressed, never pruned (`FitnessStore.swift:35,61`).
  100 one-hour workouts ≈ 600 MB.
- `ImageCache` disk cache never evicted (`ImageCache.swift:53`) — mitigated only by living in `Caches`.
- `ListenHistory` events never pruned, and the whole file is re-encoded per listen.

### H15. The Watch gets the full-bitrate original — the audio-quality setting is bypassed
`Banana/Model/DownloadManager.swift:241-248` vs `:262-279`

The primary path instructs the Watch to download `episode.audioURL` **directly**. The mono/32–48 kbps
transcode is applied **only** on the WatchConnectivity *fallback* path. So `watchAudioQuality` is
silently ignored whenever the fast path works — which is the normal case. A user who picked
"48 kbps mono" gets the 128 kbps stereo original: ~4–8× the bytes and the storage.

---

## MEDIUM (abridged)

- **`WeatherStripe` recomputes its `TimeMap`, gradient and callouts on every draw** — filter + sort +
  three full scans, ×7 in WeekView, per frame under C1. `WeatherStripe.swift:149-277`. **[NEW TODAY]**
- **WeekView renders all 7 days eagerly** (no `LazyVStack`) — 100–200 rows constructed per body pass.
  `WeekView.swift:131-175`.
- **`TranscriptStore.dir` calls `createDirectory` on every access**, and `status(for:)` does a `stat` —
  called from `TranscriptView`'s body (1 Hz) *and* at 5 Hz by the continued-task ticker.
  `Transcript.swift:51-61`. **[NEW TODAY, the 5 Hz part]**
- **`RemindersService.dueTasks()` fetches every incomplete reminder ever** (`withDueDateStarting: nil,
  ending: nil`) then filters in Swift. `RemindersService.swift:35`.
- **`progressSyncedAt` is an unbounded UserDefaults dictionary rewritten on every stamp**
  (`PodcastLibrary.swift:154-162`) — ~240 KB rewritten on every pause after a few years.
- **`FitnessView.entries` / `RhythmView.periodWorkouts` are O(n²)** and evaluated several times per body
  (`FitnessView.swift:120-148`, `RhythmView.swift:34-42`).
- **AVPlayer `preferredForwardBufferDuration` is never set** — progressive MP3s can buffer far ahead
  (~170 MB on a 3 h episode), costing memory and continuous radio. This is the real story behind the
  `debugSummary` "streaming buffer leak" note — not an object leak. `PlayerController.swift:101-104`.
- **`OpenMeteo` constructs a `DateFormatter` per timestamp** — ~180 per forecast, tens of ms wasted.
  `OpenMeteo.swift:71-77`. **[NEW TODAY]**
- **Feed refresh has no ETag/If-Modified-Since** — every manual refresh pulls and re-parses the whole
  RSS document, then replaces the episode array wholesale (→ full save → iCloud upload).
  `FeedParser.swift:29-41`.
- **`ImageCache` caches one 1000 px variant for every use site**, including 34–52 pt rows: a 4 MB decode
  where 0.1 MB would do, causing `NSCache` thrash against its 40 MB limit. `ImageCache.swift:16,26`.
- **`isIdleTimerDisabled` is a global non-refcounted flag with three owners** — no leak found today, but
  two concurrent owners will flip it off under each other. `TranscriptCoordinator.swift:97/102`,
  `StandByView.swift:19-20`.
- **Un-acked Watch workouts are re-queued on every launch** with no check against
  `outstandingFileTransfers` — repeated launches enqueue duplicate copies of the same multi-MB file.
  `WatchSyncManager.swift:29-42`.
- **`backfillWatch()` re-queues download instructions every cold launch** and the Watch never re-acks
  episodes it already has (`WatchDownloadManager.swift:33-34` returns early without acking) — so the
  phone can re-instruct forever once the sets desync.

---

## Verified clean — genuinely good

Worth recording, because these are the places where the obvious disaster **isn't** present:

- **`ImageCache` is well built.** ImageIO thumbnail downsampling with `kCGImageSourceShouldCache: false`
  — the 3000×3000 artwork is *never* fully decoded. `NSCache` with a real cost limit, disk backing,
  memory-warning purge, decoding off the main thread. The classic "36 MB per row" catastrophe is absent.
- **No HealthKit background delivery.** No `HKObserverQuery`, no `HKAnchoredObjectQuery`, no
  `enableBackgroundDelivery`. All reads are one-shot. This is the single best power decision in the app.
- **No background location.** No significant-location monitoring, no `allowsBackgroundLocationUpdates`,
  no region monitoring. Phone-side location is one-shot with `kCLLocationAccuracyReduced`.
- **No widget timeline reloads.** Zero `WidgetCenter.reload*` calls; the complication is `policy: .never`.
- **No feed polling.** `refresh()` has exactly one caller — a manual toolbar button. (The flip side: new
  episodes never appear on their own. That's a *functionality* gap, not a power one.)
- **No Combine leaks.** No `.sink` anywhere; the two `onReceive` uses are SwiftUI-lifetime-scoped.
- **WatchConnectivity is event-driven and de-duped.** `sendNowPlaying` de-dupes on `(title, playing)`;
  progress is sent on pause/stop/switch only, never per tick. The feared "2 Hz context storm" does not
  exist.
- **The overnight `BGProcessingTask` is correctly `requiresExternalPower = true`.**
- **`ForEach` ids are all stable.** `MemoryLog`'s timer is `#if DEBUG` only.

---

## Suggested order

1. **C1** — the render loop. Everything else is measured against a view that currently re-renders for
   free at 60–120 Hz. One-line fix.
2. **C2** — exclude `savedAt` from the hash. One-line fix, kills ~440 MB/hour of iCloud traffic.
3. **C3 + H1** — split progress out of the catalogue and stop republishing the library at 1 Hz. These
   are the same underlying design error and fixing them together deflates H2, H3 and H10.
4. **C4** — audio-session lifecycle. Turns an always-awake process into a suspendable one.
5. **C5 + C6 + H8 + H9** — the Watch cluster: sensors that never stop, GPS indoors, unbuffered writes,
   a ticker that never stops.
6. **C7** — background download session + Wi-Fi policy.
7. **H5 + H6 + H7** — debounce the recompute cascade.
