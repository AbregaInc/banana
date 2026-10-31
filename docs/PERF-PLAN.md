# Performance Plan — status after the 15 Jul fix pass

## 19 Jul re-audit and hardening pass

The full source tree was re-read after the earlier plan became stale. This pass fixed the remaining
recurring work that was still visible in the current code:

### Watch playback and workout

- `BananaWatch/WatchAudioPlayer.swift`: moved the one-second playhead into
  `WatchPlaybackClock`, a narrow leaf observable. Titles, current item, and playing state publish
  only on meaningful transitions.
- `BananaWatch/WatchRootView.swift`: removed root/workout observation of the whole audio player.
  Dedicated 28 pt progress-ring, workout-media-progress, and DEBUG clock leaves are the only
  one-second observers. Podcast ordering and the episode list no longer rebuild every second.
- `BananaWatch/WatchEpisodeStore.swift`: added a tiny, independently persisted
  `WatchPlayheadCheckpoint`. It restores on launch and is cleared only after an equal-or-newer
  normal progress commit. This preserves at-most-60-second crash recovery without publishing or
  serializing every episode's progress each minute.
- `BananaWatch/WorkoutRecorder.swift`: the real and simulated one-second workout callbacks now
  enter the already-required main actor directly instead of allocating a new unstructured `Task`
  every second.

### Watch downloads

- `BananaWatch/WatchDownloadManager.swift`: each background URL task now carries a Codable,
  Sendable metadata envelope in `taskDescription`.
- Existing daemon tasks are adopted after launch and before pending requests are started, avoiding
  duplicate transfers after process death.
- Completion can recover podcast/episode metadata without the original in-memory dictionary.
- Progress publishes in five-percent buckets instead of per network callback/one-percent tick.
- Orphaned staged temporary files are removed on an unrecoverable completion. A failed final
  install requests the phone-transfer fallback rather than acknowledging a file that is not
  playable, and replacement installs remove the old audio file instead of leaking it.

### Phone playback and diagnostics

- `Banana/Model/PlaybackDiagnostics.swift`: the 30-second crash breadcrumb is one compact Codable
  value under one defaults key instead of five independent defaults mutations. Legacy values are
  read and migrated. Exact episode/position recovery remains intact.
- `Banana/Views/PlaybackLogView.swift`: opening the log creates one bounded, monospaced text node
  for the newest 250 lines. “Copy” still copies the full journal.
- `Banana/Model/PlayerController.swift` and `Banana/Model/PerfWatchdog.swift`: recurring timer
  callbacks no longer allocate unstructured tasks merely to return to the main actor.
- `Banana/Views/PodcastDetailView.swift`: removed an `Array(enumerated())` copy of the complete
  ordered feed on each render and removed unused menu inputs.
- `Banana/Model/DownloadManager.swift`: unrecoverable background-download completions clean their
  staged file rather than leaking it.
- `Banana/Model/VoiceMemoRecorder.swift`: updated the Bluetooth session option to the current HFP
  API.
- `Banana/Model/AudioTranscoder.swift`: AVFoundation reader/writer objects are explicitly confined
  to their serial transfer lane, satisfying Swift concurrency without moving media work to the
  main actor.

### Measured result

- Current iOS Debug and Release simulator builds pass without warnings or errors; the Release build
  also compiles and embeds the Watch app and both widgets.
- `VerifyTimelineUITest.testReturningUserDoesNotReplayOnboarding` passes on the iPhone 17 Pro
  simulator after the launch/hot-path changes.
- Current macOS Debug and Release builds pass. Xcode's expected “no AppIntents dependency” metadata
  probe is the sole warning and does not run in the app.
- Fresh simulator trace: first-paint weather/layout work used 31% process CPU over the first
  five-second bucket, then every sampled bucket was 0% with no view-body evaluations. The bounded
  startup burst is not a runaway loop.
- Available crash reports were inspected. Both are old simulator CloudKit initialization traps
  addressed by lazy/simulator-gated container construction; neither indicates current CPU, memory,
  or thermal pressure.

### Residual work that must not be guessed at

The daily phone was not available to CoreDevice during this audit. A Release-device, screen-off
local-file playback soak is still required to prove power and thermal behavior. Do not infer that
from simulator CPU. Keep podcast/listen/workout history uncapped until a non-destructive archive and
pagination design exists.

---

> **This document now records what was DONE, what was verified, and what remains.** The original
> full-codebase review (15 Jul morning) found the issues; the fix pass (15 Jul afternoon)
> implemented them; three independent adversarial review agents then re-audited every changed
> file against HEAD, and their findings were folded back in. All three targets (iOS, watchOS,
> macOS) build clean. History: `PERF-AUDIT.md` (14 Jul) → this plan's findings → this status.
>
> **What code review cannot prove: the field behavior.** The device-verification protocol in §4
> is the remaining work — it needs the phone, a real ride, and a night on the charger.

---

## 1. Fixed and re-audited (code-level verification complete)

Every item below was implemented, compiled on all targets, and independently re-verified by an
adversarial reviewer reading the diff against HEAD. IDs refer to the original findings register
(git history of this file has the full descriptions).

### The loop class (crash-tier)
- **F1 — WeekView render loop**: now-anchor minute-quantized, ALL published geometry rounded to
  whole points (`dayAnchor`, dayGrid anchors, `DayOffsetKey`), both `onPreferenceChange` writes
  equality-guarded. Reviewer confirmed the guards are meaningful (`TimeAnchor: Equatable`) and
  that no un-quantized `Date()`/raw-float enters any preference in the file.
- **F1b — geometry jitter**: TodayView's `timeAnchor` y rounded too (the equality guard alone was
  defeated by sub-point layout jitter — the residual 22–43 % foreground storm). The one dead
  `Date()` fallback in `doneRun` now routes through `nowAnchor`.
- **Standing rule** (enforce in review): preference values must be quantized and stable; every
  `onPreferenceChange` write compares first. This shape has produced two CPU-kill loops.

### Background drain
- **F2 — visibility gate scope**: `.inactive` no longer blanks the UI or triggers commits/backups
  — Control Center, permission alerts, and call banners keep the tree alive. Only `.background`
  gates. (The black-screen gate itself is retained until the §4 soak clears it.)
- **F3 — calendar cascade debounce**: `EKEventStoreChanged` → 5 s trailing debounce. Self-authored
  commits are *not* hard-dropped (a drop also swallowed real external changes in the window);
  loop-termination rests on write-back's hash-diff, which the reviewer traced end-to-end.
- **F4 — EventKit fan-out**: ONE windowed 14-day predicate fetch, executed off the main actor,
  bucketed per-day with identical dedupe scope. The 140–700 ms main-thread block per recompute is
  gone. Known semantic change (reviewer judged it a fix): a cross-midnight event now appears only
  on its start day — the old per-day loop produced duplicate occurrence IDs for it.
- **F5 — alarm re-arm diff**: `scheduleWakeOccurrences` early-returns when the wanted set matches
  `wakeAlarmTimes` (count-guarded against leftover weekly repeats; `cancelSmartWakes` now clears
  the mirror). Reviewer walked every arm/cancel/relaunch sequence — no case skips needed work.
- **F6 — launch decode**: the multi-MB catalogue decodes off-main; `whenLoaded()` gates every
  launch-time consumer (wake intent, Watch ingest/fallback, backfill, manifest push, CloudKit
  seeding). Reviewer-found hardening applied: `startWake`/`play` are properly `async` so the
  **AlarmKit stop intent awaits playback start** (a fire-and-forget there could let iOS suspend
  the process before wake audio began); catalogue mutators are load-gated (`addPodcast` awaits,
  `remove` guards, `finishLoad` merges instead of clobbering if something mutated first).
- **F7 — backup dirty bit**: `schedule()` is a persisted dirty flag; the on-background snapshot
  pass skips entirely when clean and clears the bit on success *or* verified-unchanged. Reviewer
  found the coverage gaps; closed: FitnessStore summaries, AppSettings, and WakeStore now dirty
  the flag (they're all in the snapshot payload).
- **F9/F10 — transcription disk**: launch sweep of orphaned `seg-*.caf` decodes (up to ~500 MB
  each); 3-strike failure memo stops the nightly re-decode of permanently-failing episodes
  (success resets; parked episodes still retryable from the UI); checkpoint encode+write moved
  off the main actor onto a **serial IO lane** shared with `clearPartial` — the reviewer's two
  race findings (out-of-order checkpoint writes; a straggler write resurrecting a cleared
  partial) are closed by ordering.
- **F8 — watch audio session lifecycle**: episode-finish releases the session; interruption and
  route-loss observers stop the 1 Hz ticker, persist progress, and release the session (a
  system pause used to leave the ticker running forever).

### Playback path (publish + radio cadence)
- **F11 — quiet progress**: the 30 s commit writes a single `LiveProgress` value — **zero
  publishes during steady playback**; it folds into the published array (one publish) at
  pause/stop/switch/completion/remote-merge. Disk always merges the live value, so persistence
  never lags the fold. Reviewer swept every reader of positions/current/lastPlayedAt; the one
  wrong-decision path found (stale `currentEpisodeID` making "Play next" jump backwards
  mid-session) is closed by folding immediately after the new episode seeds. Loss-on-kill is
  byte-identical to old behavior (≤30 s).
- **F12 — ordered() memo**: play-order sort memoized per (feed, direction, episode set);
  `hasNext/hasPreviousEpisode` no longer sort per read (was 2 sorts/sec with the player open).
  Known narrow staleness: a refresh replacing episode *content* with identical count/first/last
  serves stale structs until any structural change — self-healing, LOW.
- **F15 — CloudKit cadence** (sync remains **default-off**, see §4): `automaticallySync = false`;
  `flushNow` at pause/stop/switch/finish/background/foreground/start only — playback costs zero
  radio between commit points. System-fields writes coalesced (was O(n²) on first sync).
  Reviewer-verified zone seeding converges in one flush; `serverRecordChanged` now re-stages the
  local save so a newer local value can't sit local-only forever.
- **F16 — LWW stamps**: out of UserDefaults (whole-dict rewrite per pause, unbounded) into
  progress.json, pruned to episodes that still carry progress; the legacy key is removed only
  *after* the stamps first persist (reviewer: deleting first risked losing the stale-remote
  guard on a crash). Watch side: three progress dicts split per-write, pruned on delete and aged
  (90 d) at init.
- **F23 — stream buffering (corrected 17 Jul)**: an earlier pass set
  `preferredForwardBufferDuration = 120`, incorrectly treating it as a cap. It is a requested
  read-ahead target, and Apple's SDK warns that high values increase system-resource demand.
  Streamed items now retain AVPlayer's power-aware default of `0` at both creation sites.
- **F28 — bar observation**: NowPlayingBar no longer observes the 1 Hz clock; the two labels that
  need it are child views.

### Foreground CPU
- **F13** episode menus build `before/after/byID` inside the lazily-evaluated menu content —
  list render is O(n), was O(n²). **F14** `OccurrenceStore.byDay` index (day queries are dict
  hits) + TodayView materializes the day once per body. **F24** formatter hygiene (OpenMeteo:
  ~185 → 1 per decode; WeatherDetail: cached per template|zone). **F31** observation granularity
  (Settings/Podcasts containers no longer re-render on download ticks; dead WakeStore
  observation removed). **F32** RhythmView single-pass `PeriodStats` (was 8–10 evaluations of
  O(n²) collections per render), FitnessView/ListenMap single bindings.
- **Watch**: **F17** download progress throttled to whole percents (the phone got this fix
  earlier; the watch never did); **F18** deleted a 5 Hz timer publishing a value nothing read
  (it re-rendered the workout screen for the length of every voice note); **F30** the "DEBUG"
  section no longer ships in release (it interpolated `currentTime`, forcing 1 Hz list renders).

### Storage, network, hygiene
- **F19 — WC dedup**: workout re-sends check `outstandingFileTransfers` (no more duplicate
  multi-MB uploads per launch); the watch re-acks already-present episodes so the phone stops
  re-instructing forever. **F20** transcripts die with unsubscribe, partials die with their
  download (a partial can't resume without its file; transcripts are kept — they serve streamed
  playback). **F21** transcript status reads are pure memory (was createDirectory+stat at 1 Hz
  and 5 Hz for hours). **F25** conditional feed GETs (ETag/Last-Modified; 304 = headers only, no
  parse, no catalogue rewrite). **F37** resume data preserved on failed downloads (and a user
  cancel no longer resurrects as `.failed`); abnormal watch workout end now *finalizes* (closes
  the writer, saves, sends) instead of just stopping sensors — double-finalize proven impossible
  by ordering. **F33** refcounted `KeepAwake` (StandBy can no longer un-assert a transcription's
  screen hold). **F34** interrupted voice memos finish through the flow owner and are SAVED
  (the first version of this fix would have deleted them — caught in re-audit). **F35** launch
  churn: RoutineStore re-saves only when the migrated shape differs (reviewer verified the model
  encodes deterministically); settings adopted from iCloud persist+notify once; the watch's
  shortcut-reindex/complication-reload runs once per binary (keyed by executable mtime — the
  project pins version numbers, so a version key would never fire again). **F36** TravelService
  memoizes geocoding. `NSSupportsLiveActivities` added (Live Activities could never present).

### Instruments (new, ship in release)
- **MetricKit** (`Metrics.swift`): daily CPU/battery rollups and — the one that matters —
  `cumulativeCPUResourceLimitExitCount` + CPU-exception/hang/crash diagnostics, written into
  `playback.log`. The kill class that was diagnosed by hand now self-reports.
- **Signposts** (`Signpost.swift`): intervals around `recompute` / `smartRecompute` /
  `saveProgress` / `backup` for Instruments correlation.
- **Playback power heartbeat** (17 Jul): the existing 30-second progress heartbeat now records
  process CPU, local-vs-stream source, speed, player state, physical footprint, thermal/Low Power
  state, callback cadence, and the busiest observed publisher/view. It adds no timer. Progress
  commits now use wall time rather than media ticks, so 3× playback no longer triples disk/log
  cadence.
- **App-wide power rollup** (17 Jul): the existing five-second watchdog aggregates one persistent
  `⚡ POWER` line per minute: average/max process CPU, physical footprint, kernel wakeups, syscalls,
  context switches, thermal/Low Power state, foreground/background state, audio state, download/
  transcription/Watch-transfer activity, active expensive operations, completed operation counts
  and durations, and the busiest publisher/view. Existing signposts feed the same attribution
  registry; transcription adds an explicit span. No additional sampling timer was introduced.
- PerfWatchdog remains the storm-namer of record and now also owns the bounded power rollup;
  RenderStats supplies its publisher/view attribution.

---

## 2. Known-accepted behavior notes (from the re-audit, deliberate)

- Cross-midnight calendar events appear on their start day only (fixes a duplicate-ID hazard).
- The playing episode's progress bar in feed lists updates at fold points (switch/pause), not
  every 30 s. The now-playing UI itself is clock-driven and live.
- A CloudKit record for a completed episode being *re-listened* reads `completed: false`
  mid-session until the next fold (LWW keeps this harmless).
- Force-quit from the app switcher relies on `.background` delivery (normal iOS behavior);
  worst-case loss is the same ≤30 s tick as a crash.
- WeatherDetail's cached formatters key on template+zone, not locale — a mid-session region
  change shows stale formats until relaunch (rare; cosmetic).
- `ensureTranscript` still allows a parked (3-strike) episode to be retried from the UI —
  parking protects the overnight batch only. Intentional escape hatch.
- Timezone changes can mis-bucket `byDay` lookups for ≤45 s until `recomputeIfStale` refreshes.

## 3. Second pass (15 Jul, later): the deferral list was worked off

Everything previously deferred-on-the-merits is now either **implemented** or **closed by a
recorded decision**:

**Implemented:**
- **NDJSON append-only checkpoints (H13, the real fix):** partials are now one-word-per-line
  appends — each word hits the flash exactly once (was: whole-array atomic rewrite per
  checkpoint, O(n²) bytes, largest writes last). Legacy `partial-*.json` files still resume
  (read once, converted); torn final lines from a kill are tolerated by the loader; all IO on
  the existing serial lane so appends can never race clears.
- **NotificationService reschedule-only-on-change:** each scheduler fingerprints its desired
  future set and skips the getPending → remove-all → re-add churn when nothing changed
  (~20 daemon round-trips per calendar event edit → 0 when the plan is stable). First call
  after relaunch always reschedules, which self-heals daemon drift.
- **Recompute coalescer:** `OccurrenceStore.requestRecompute()` (300 ms settle) now backs the
  callback-driven triggers — routine edits, one-off alarm changes, the smart-plan refresh — so
  a burst of edits (or the foreground plan-refresh racing Today's staleness refresh) collapses
  to one recompute. User-initiated paths still await `recompute()` directly for instant UI.
- **Download progress ticker split (the PlaybackClock pattern, applied):** per-percent updates
  moved off the manager's published `states` onto a `ProgressTicker`; `states` publishes only
  real transitions. The ring that displays the moving number is its own leaf view — a percent
  tick now invalidates a 20 pt circle, not the episode list.
- **LOW edges from the re-audit:** write-back commit failure now rolls back both the staged
  EKEvents (`store.reset()`) and the ledger snapshot; `orderedMemo` keys on the first episode's
  audio URL too (catches the CDN-migration case); `KeepAwake` asserts on unbalanced release
  (DEBUG); TravelService memoizes geocoding.

**Closed by decision (recorded in code comments at the site):**
- **WeekView stays an eager `VStack`.** The stripes are positioned by preference-published row
  anchors; a lazy container births/kills those GeometryReaders as sections scroll, turning every
  scroll position change into anchor-dictionary churn → guarded writes → body re-evals *while
  scrolling*. The eager tree re-evaluates once per data change and once a minute (now marker) —
  strictly cheaper for 7 sections. Revisit only with Instruments evidence.
- **@Observable migration is sequenced AFTER the §4 device soak, not skipped.** The migration
  removes `objectWillChange` — the exact signal PerfWatchdog's storm detector subscribes to.
  Migrating before the soak would blind the instrument the soak depends on, and any migration
  regression would be indistinguishable from a pre-existing storm. Do it once the field data
  says the loop class is dead; it also mechanically absorbs the remaining observation-granularity
  nits (PodcastRow).

**Still open (unchanged):**

| Item | Why |
|------|-----|
| Retire the black-screen `.background` gate | Needs the §4 storm-log soak first. |
| Flip `CloudProgressSync` default ON | Needs the §4.5 on-device round-trip check first. |
| ListenHistory cap / FitnessStore byte cap | Product decisions — they delete user data (Listen Map history, workout samples). Growth is slow. |

## 4. Device verification protocol (the remaining work)

Run on the real phone + watch, release build:

1. **Loop-class check (10 min):** open Week (weather on, upcoming items today) and Today; watch
   `playback.log` — **no `🌀 STORM` line**; with `--perf-trace`, body counts ∝ interactions.
   Pull down Control Center: UI stays rendered, no backup line.
2. **Background playback soak (2 h, screen off, watch workout running):** journal shows only
   30 s heartbeats; PerfWatchdog `perf` lines ≤ ~2 % CPU; **no storms**; next-day MetricKit line
   shows zero `CPU-LIMIT KILLS`.
3. **Calendar burst:** edit an event from another device — exactly one `recompute` signpost ≥5 s
   later; zero AlarmKit re-arm when wake times unchanged (Console: alarm daemon XPC).
4. **Launch:** cold launch with the real library — no main-thread hang >50 ms (Instruments);
   alarm-intent fire from Lock Screen starts wake audio reliably (the await chain is new — test
   this one specifically, three mornings).
5. **CloudKit enable gate:** with the Settings toggle ON (or `--cloudsync`): first sync seeds
   without churn (one system-fields write burst, not per-record); play 10 min → **zero** CK
   traffic (Console `cloudd`); pause → one send+fetch; second device converges; kill mid-listen
   → positions correct after relaunch on both. Only then flip the default.
6. **Storage:** delete a transcribed download → partial gone; unsubscribe → transcripts gone;
   interrupt a transcription twice → at most one bounded `seg-*.caf` after relaunch; interrupted
   voice memo (call during recording) → note SAVED with correct duration.
7. **Watch:** pause via Siri/route-loss → ticker dead (no 1 Hz republish in Console); finish an
   episode → session released; relaunch twice mid-workout-transfer → one outstanding WC transfer.
8. **Two-week soak:** storm log silent + MetricKit clean → remove the black-screen gate
   (Phase 5.1), keeping `AppVisibility` behind a debug flag as a circuit breaker.

## 4b. Launch & first paint (15 Jul, overnight device pass)

> Complaint: "first open is still super slow." Measured and fixed on a real device
> (iPhone 14 Pro test rig), A/B per change, Debug config throughout (relative deltas are what
> matter; Release is faster across the board).

**Methodology.** `LaunchClock` (ships in release) stamps milliseconds-from-*kernel-process-
creation* at every launch phase into both os_log (`category:launch`) and playback.log — so any
device, including the daily phone, self-reports its launch breakdown; pull the journal and read
it. Test rig runs: terminate → relaunch ×5–7, medians, post-install outlier run discarded.
Rig caveat: no permissions granted there (third-party device), so authorized-path costs
(AlarmKit with armed alarms, EventKit fetches, weather network) are UNDER-represented — those
fixes are structural and will show on the daily phone's own marks.

**What was found and fixed:**
- `@StateObject` autoclosures mean store construction runs during FIRST RENDER, not App.init —
  the launch trace decomposes per store. Every synchronous daemon round-trip in that path went:
  AlarmKit orphan-reconcile + alerting read (deferred one beat; `alarmUpdates` keeps it live),
  the AlarmKit authorization seed (cached — previously-authorized launches skip the XPC
  entirely), audio-session category + remote-command registration (deferred; every play path
  configures on demand), iCloud KVS synchronize (deferred), background-URLSession
  reconstruction in DownloadManager.init (deferred one beat).
- Remaining synchronous main-thread JSON decodes went async with merge guards (ListenHistory —
  unbounded by design, FitnessStore + its migration probe, HealthKit cache), same pattern as
  the catalogue.
- **Stale-while-revalidate snapshots** (the perceived-speed win): the occurrence timeline and
  the weather forecast now persist and load SYNCHRONOUSLY at store init (tens of KB, single-
  digit ms) — the first frame shows yesterday's-shape day + stripe instead of an empty card
  that pops and reflows 100+ ms later. `lastComputed` stays nil so the fresh recompute still
  runs and replaces; alarm arming and write-back consume ONLY fresh recomputes, never snapshots.
- EventKit off-main completed: `refreshAgenda`, `firstMeetings`, `todayMeetings` (commute) — the
  windowed occurrence fetch had it; these three still blocked the main actor.
- Foreground churn: `smart.recomputeIfStale(60s)` on `.active` (was: full plan recompute with
  travel ETAs per app switch); the plan refresh requests an occurrence recompute ONLY when wake
  times actually changed (was: two full recomputes per foreground); Today's three launch
  refreshes (agenda/occurrences/weather) run concurrently instead of serialized.
- Feel: Artwork checks the memory cache synchronously in init (cached art renders on frame one,
  no placeholder flash); PodcastDetailView's play-order sort is memoized (was O(n log n) per
  render on a 1,200-episode feed); launch screen background matches the app (no white flash);
  wake-alarm mirror persists so cold launches skip the ~40-XPC no-op re-arm.

**Test-rig numbers (medians; empty-permission environment):**

| milestone | baseline | final |
|-----------|---------:|------:|
| first frame (`root.appear`) | 268 ms | **203 ms (−24 %)** |
| Today content (`today.content`) | 490 ms | **239 ms (−51 %)** |
| snapshots loaded | — | 91 ms / 111 ms (both BEFORE first frame — content renders on frame one) |

On the daily phone the deltas are larger (authorized paths + real network); read them from
`playback.log` — the `⏱` lines are the breakdown, per launch, forever.

## 5. Budgets (the standing definition of "done")

| Scenario | Budget | Instrument |
|----------|--------|------------|
| Background playback, screen off, 1 h | ≤ ~2 % avg CPU; 0 UI body evals; 0 storms | PerfWatchdog, MetricKit |
| Backgrounded idle (no playback) | suspended in seconds; no timers alive | Energy gauge, journal silence |
| Calendar sync burst | exactly 1 recompute; 0 no-op alarm re-arms | signposts |
| Unlock → Today | no main-thread I/O > 50 ms; no fetch < 45 s stale | hang detector |
| 30 s of playback | ≤ 2 small file writes; 0 network; 0 CloudKit | fs_usage, CK console |
| Pause/stop/switch/background | one fold-publish; ≤ 1 CK send+fetch; one WC push | CK console |
| Foreground browsing | body evals ∝ interactions; no 2/s storms | PerfWatchdog |
| Overnight batch | bounded tmp; parked episodes skipped | tmp listing, journal |
| Steady-state disk | every store bounded or deferred-by-decision (§3) | du + delete tests |
| Watch workout + playback, 1 h | sensors/tickers stop in EVERY exit path | watch console |

## 6. Protected list (don't regress)

ImageIO-downsampled artwork cache (now with a 60-day disk sweep); one-shot reduced-accuracy
location; no HealthKit background delivery; static widget timelines; event-driven de-duped
WatchConnectivity (now with in-flight dedup + re-acks); background download sessions with
session-level policy (now with resume data); `requiresExternalPower` overnight batch (now with a
failure memo); journal + watchdog + MetricKit shipping in release; `recomputeIfStale`;
`PlaybackClock` and now `LiveProgress` as the pattern for hot state: **publish at the rate of
meaning, not the rate of I/O.**
