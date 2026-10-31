# Scale stress gate

The [UI performance contract](ui-performance-contract.md) defines the required 120 Hz frame and
interaction budgets. This harness provides component checks; a passing run does not establish
compliance with the full UI contract.

This workload uses the real app models and screens, with synthetic data in an isolated Simulator
Application Support directory. It never starts the normal `wireUp()` service graph. The stress
entry point is compiled only for Debug-enabled Simulator builds, requires an existing audit route
and `--disable-icloud`, and accepts 1–365 days. Normal shipping launches are unchanged.

## Workload

All four datasets are available together, even when only one tab is visible. Notes and podcast
episodes now live in SQLite; the screens retain pages of 100 records. The mail fixture and injected
calendar events still reside in memory:

| Days | Emails (2,000/day) | Events (100/day) | Notes | Shows × episodes |
| --- | ---: | ---: | ---: | ---: |
| 1 | 2,000 | 100 | 1,000 | 10 × 1,000 |
| 7 | 14,000 | 700 | 7,000 | 70 × 1,000 |
| 30 | 60,000 | 3,000 | 30,000 | 300 × 1,000 |
| 90 | 180,000 | 9,000 | 90,000 | 900 × 1,000 |
| 365 | 730,000 | 36,500 | 365,000 | 3,650 × 1,000 |

Events overlap, with overnight events mixed in. Podcast dates are deliberately unsorted. Notes
include archived entries and repeatable search matches. Mail includes unread and starred messages.
Text payloads are short, podcast progress starts empty, and no attachments are loaded. Large bodies,
attachments, dense listening-progress histories, and active provider sync need separate scenarios.

**Mail limitation:** the current app runs `MailFixtureSource`, not a wired persistent Gmail engine.
These numbers exercise its real UI contract, paging and mutations. They do not validate SQLite
query plans, Gmail sync/backfill, remote search, attachment downloads or disk-cache eviction.

## Build and run

Use one Xcode build at a time. Do not measure while compiling or under competing workloads.
The optimizer is Release; DEBUG enables the isolated fixture routes (as in `tools/perf-gate.sh`).
Do not force `-sdk iphonesimulator`: the scheme also builds a Watch target with its own SDK.

```sh
xcodegen generate
xcodebuild -project Banana.xcodeproj -scheme Banana -configuration Release \
  -destination 'platform=iOS Simulator,id=E5232BE0-8F82-4E85-A03B-5CA7160571E2,arch=arm64' \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG' CODE_SIGNING_ALLOWED=NO \
  -derivedDataPath .build/stress-dd build-for-testing

python3 tools/scale-stress.py --days 1 7 30 --out .build/scale-results --label candidate
```

The script validates that the destination is a Simulator and installs only there. It terminates
the test app between tiers, waits for a fresh JSON report and fails on a missing report or exceeded
budget. It retains all result files and test workspaces. `--app` selects a saved A/B binary;
`--device` selects the iPad Simulator. `--allow-failures` is only for recording a known-failing
baseline. `--baseline DIR` compares against `baseline-<days>d.json` in that directory and also
fails on median regressions larger than both 5 ms and 25%, or RSS growth larger than both 64 MB
and 20%. Use alternating repeated A/B runs before attributing a small change to code.

The report summarizes seven samples per operation as median and nearest-rank p95 (the maximum of seven),
checksums, record counts, source commit/dirty status, Simulator ID, peak process RSS and fixture
readiness time. The first sample is retained: caches are not explicitly prewarmed by the probe,
although the real screen/session may have already queried a store.

Budgets: mail first page 50 ms; read mutation 100 ms; calendar week query 16 ms and day query 8 ms;
notes search 100 ms and browse 16 ms; podcast next/download selection across the catalog 100 ms.
Peak Simulator RSS defaults to a 900 MB ceiling (`--max-memory-mb`). This ceiling includes fixture
construction and framework overhead; it is not an acceptable physical-phone memory target.

## Correctness and UI checks

```sh
xcodebuild -project Banana.xcodeproj -scheme Banana -configuration Release \
  -destination 'platform=iOS Simulator,id=E5232BE0-8F82-4E85-A03B-5CA7160571E2,arch=arm64' \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG' CODE_SIGNING_ALLOWED=NO \
  -derivedDataPath .build/stress-dd \
  -only-testing:BananaTests/PodcastCatalogTests \
  -only-testing:BananaTests/NoteRepositoryTests \
  -only-testing:BananaTests/JSONRecordStreamTests \
  -only-testing:BananaTests/ScaleQueryTests \
  -only-testing:BananaTests/DownloadRetentionTests \
  -only-testing:BananaTests/NarratorVoiceFilterTests \
  -only-testing:BananaTests/NarratorVoiceOverrideTests \
  -only-testing:BananaTests/NarratorFilterPlaybackTests \
  -only-testing:BananaTests/MailFixtureSourceTests \
  -only-testing:BananaUITests/ScaleStressUITests \
  -only-testing:BananaUITests/CueTimeUITest \
  -only-testing:BananaUITests/DayColumnWidthUITest \
  -resultBundlePath .build/scale-checks.xcresult test
```

Repeat the UI class on iPad (`7CE990BF-066D-4E79-BA7F-B5F285E6A66C`). UI tests require the
`stress.ready` marker before interacting: an empty screen cannot pass. They open notes and
podcasts, scroll mail/calendar and open a mail conversation. Scroll tests record clock time,
process memory and Apple's [scrolling and deceleration metric](https://developer.apple.com/documentation/xctest/xctossignpostmetric/scrollinganddecelerationmetric).
Screenshots and raw metrics are retained in the result bundle. These UI measurements are recorded
for comparison; XCTest does not enforce an animation baseline until one is configured.

The model gate is not a frame-rate claim. Real device hitches, thermal behavior, background work,
network I/O, persistent-store writes and long-running sync still require separate measurements.
The larger tiers expose capacity limits without truncating retained history. These measurements
do not establish unlimited capacity: exact substring-search counts, per-catalog background work,
and the fixture mail store still grow with history.

## Initial in-memory results — October 7, 2026

The 1-, 7- and 30-day tiers passed every model latency, memory and baseline-regression gate
on the iPhone 17 Pro Simulator (iOS 26.5). At 30 days all four stores held 60,000 emails,
3,000 events, 30,000 notes and 300,000 episodes together. Peak process RSS was 635 MB;
the baseline was 650 MB. These are Simulator measurements on a busy shared Mac, not device limits.

| Operation at 30 days | Baseline median | Updated median | Updated p95, including first sample |
| --- | ---: | ---: | ---: |
| Mail first page | 68.59 ms | <0.01 ms cached | 14.06 ms |
| Mail read mutation + first page | 169.69 ms | 28.02 ms | 28.57 ms |
| Calendar visible week | 0.28 ms | 0.27 ms | 4.88 ms |
| Notes search | 35.01 ms | <0.01 ms cached | 32.85 ms |
| Podcast next across catalog | 1,137.80 ms | 5.97 ms | 8.34 ms |
| Podcast download candidates | 1,196.12 ms | 11.02 ms | 11.55 ms |

The calendar index has a cold construction cost; this small event tier was already below its
query budget before the change. Notes avoid repeating an unchanged query, but a new search still
scans the notes. Mail selects a page with a bounded heap and counts without sorting; podcast
selection keeps only the needed episode indices instead of copying and sorting every episode.

Raw [baseline](scale-results/baseline-30d.json) and [updated](scale-results/final-30d.json) reports
are retained alongside the 1- and 7-day reports. Updated reports identify the exact binary hash;
the source commit is the pre-change commit with `dirty: true` because measurement preceded commit.

The [90-day capacity probe](scale-results/capacity-90d.json) retained 180,000 emails, 9,000 events,
90,000 notes and 900,000 episodes. Every latency budget still passed (mail mutation p95 77.18 ms,
notes search p95 97.28 ms), but peak RSS reached **1,228 MB**, failing the unchanged 900 MB gate.
This pre-paging run was captured with `--allow-failures`; it is not a passing capacity claim.
It motivated the disk-backed catalogs described below. Real mail sync and full-size message bodies
still need their own production-engine workload.

Validation: 49 model correctness tests, all four stress UI tests on both iPhone and iPad,
and the existing iPhone cue-tap and calendar-width/rotation regressions passed. Calendar day
containers now have explicit chronological accessibility ordering: the same dense-calendar
XCUITest gesture pair fell from a median 23.86 seconds to 5.37 seconds. Sampling localized the
stall to SwiftUI's accessibility geometry sorting. The scroll signpost duration itself stayed
around 2.47 seconds; this is an accessibility/main-thread stall fix, not evidence of improved FPS.
Raw [initial](scale-results/first-ui-metrics.json), [updated iPhone](scale-results/final-ui-metrics.json)
and [iPad](scale-results/ipad-ui-metrics.json) UI metrics are retained. Those A/B calendar metrics
used the standalone `--week` route; the final test enters `--plan` with Week explicitly selected
so that the real mode-switching container is exercised and the picker cannot inherit a stale mode.
The [final Plan-container rerun](scale-results/plan-route-ui-metrics.json) passed on both devices.
The Release-optimized Simulator build and the Mac Beta Debug build both succeeded. The Mac build
was compiled for compatibility; no desktop stress measurement or physical-device run is claimed.


## Disk paging and redraw checks

`PodcastCatalog` stores immutable episode snapshots and keeps only feed metadata in the library.
Feed refresh stages one feed at a time. Episode lists fetch 100 rows, direct lookups use an indexed
ID query and a cache capped at 128 entries/4 MB estimated payload cost. Playback order retains
IDs rather than full episode bodies. Superseded snapshots are reclaimed after their model handles
are released. Portable cloud backups export the existing JSON format one feed at a time; the final
backup Data buffer is still proportional to the backup size.

`NoteRepository` stores each note separately, with indexed browse order, episode and pending-work
queries. Notes screens load 100 active/archived rows per page. Search runs off the main actor with
32 ms typing debounce, preserves Foundation localized substring matching, and counts all matches.
An ASCII prefilter avoids unnecessary Foundation bridging. Search is still a scan, not a full-text
index. CloudKit upload payloads are assembled in batches of at most 200 queued changes; startup
seeding reads note IDs only. The legacy file-based cloud import remains a bulk operation.

Both stores migrate legacy JSON in a transaction, streaming one top-level record at a time and
leaving the original JSON untouched. Malformed input rolls back the entire import. Podcast backup
export fails on a read error rather than backing up stale legacy JSON. Notes writes report failures
and retain the compose draft. Notes' first migration is synchronous and still needs launch-time
measurement with a large pre-existing history.

Unchanged note merges do not publish a new revision. Podcast settings saves avoid republishing an
identical catalog. Row counts run in keyed tasks rather than scanning every episode in view bodies.
The calendar no longer sends an explicit object-change notification immediately before changing a
published revision. Existing playback-clock and download-progress publisher separation is retained.

For an isolated redraw probe, run each route with `--idle-seconds 10`:

```sh
python3 tools/scale-stress.py --days 30 --route notes --idle-seconds 10 \
  --out .build/paging-results --label redraw-notes
```

Repeat with `library`, `plan`, and `mail`. After a five-second settling period, the probe injects
100 playhead updates at 10 Hz without playing audio. It requires the selected screen to have rendered
and fails if a watched large screen root exceeds two renders/second. This checks publisher isolation;
it does not exercise live audio, network sync, transcription, or physical-device frame timing.
`readySeconds` includes the settling/probe interval when this option is enabled.

The 900 MB RSS gate was a harness choice, not an iOS memory limit or a product target. It includes
Simulator/framework overhead and fixture construction. Device-specific resident-memory and hitch
budgets need physical-device profiling; changing this ceiling does not fix scaling behavior.


## Disk-paging results — October 7, 2026

The optimized disk-paging measurement build passed the existing model and 900 MB RSS gates at 1, 7, 30,
and 90 days. Reports: [1 day](scale-results/paged-1d.json), [7 days](scale-results/paged-7d.json),
[30 days](scale-results/paged-30d.json), [90 days](scale-results/paged-90d.json). At 30 days peak RSS
was 460 MB; at 90 days it was **670 MB**, compared with the earlier in-memory 90-day run's 1,228 MB.
These are single retained runs on a busy shared Mac, not device memory limits or a 120 Hz claim.

| Operation | 30-day p95 | 90-day p95 |
| --- | ---: | ---: |
| Mail first page, including cold query | 14.59 ms | 38.50 ms |
| Mail read mutation and page | 30.50 ms | 83.25 ms |
| Calendar visible week, including cold index | 4.99 ms | 10.66 ms |
| Notes search and first 100 results | 18.93 ms | 54.07 ms |
| Notes browse page | 1.59 ms | 3.54 ms |
| Next episode across all shows | 19.34 ms | 65.38 ms |
| Download candidates across all shows | 23.17 ms | 80.57 ms |

The first disk-backed search implementation took 159 ms at 90 days. The ASCII prefilter reduced
that to 54 ms while retaining localized matching, including Unicode and embedded-null regression
cases. The notes operation now returns a page rather than every matching body; its checksum is
the page size, so old whole-result checksums are not directly comparable. Counts and paging
correctness are checked separately.

**These component passes do not meet the full UI acceptance contract.** In particular, 54–83 ms
of model work at 90 days leaves little room for a 100 ms visible response and misses the 32–50 ms
goals before rendering. End-to-end device interaction and frame measurements remain unmeasured.

All [57 model correctness tests](scale-results/paging-unit-summary.json) passed, including
transactional migration/rollback, stable paging order, portable podcast backups, no-op/stale note
merges, localized search parity, narrator filtering, download retention, and the mail fixture.
Five Python tests also verify the UI acceptance evaluator's strict thresholds and missing-evidence
handling. These correctness tests do not constitute UI timing evidence.

The 30-day playback-clock isolation probes passed on all four routes. Each injected 100 updates
at 10 Hz after settling; the selected screen was confirmed rendered. RootView and the watched
NotesView, PodcastsView, PlannerTab/WeekView, and MailSection roots each recorded **zero redraws**
during their respective probe. Reports: [Notes](scale-results/redraw-notes-30d.json),
[Library](scale-results/redraw-library-30d.json), [Plan](scale-results/redraw-plan-30d.json),
[Mail](scale-results/redraw-mail-30d.json). This rules out that specific publisher-induced redraw
storm in the isolated routes; it does not test all live-service feedback loops.

For ongoing changes, use the [persistent regression suite](regression-testing.md), which compares
all four scale tiers and redraw routes with a reviewed reference and retains failed measurements.

Functional UI checks passed on iPhone 17 Pro and iPad Pro 13-inch (iOS 26.5): dense calendar,
mail scrolling/opening, notes opening/paging, podcasts opening/scrolling and podcast page-next/back.
The first five checks passed on both devices in `.build/paging-ui5.xcresult`. Podcast paging passed
on iPhone in the [mixed rerun](scale-results/paging-ui-mixed-summary.json), then on iPad in the
[isolated rerun](scale-results/paging-ui-ipad-summary.json). The mixed rerun's iPad failure is retained;
these are passes across separate runs, not one fully green suite. The tests caught shared SwiftUI
accessibility identifiers on the pager and a footer assertion that needed scrolling after page load.
Screenshots verify actual episode rows on both pages. Release Simulator and Debug Mac Beta builds
also succeeded; no production Mac app was launched.
