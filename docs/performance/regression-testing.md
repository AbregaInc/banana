# Persistent performance regression checks

The [Mail disk-index checks](scale-results/mail-index-20261010/README.md) add
registered migrations, keyset correctness beyond 2,000 conversations and a retained
180,000-conversation OFFSET ablation. The measured host had a competing build;
the UI window and live Gmail source remain integration work.

The [physical iPad follow-up](scale-results/calendar-ipad-followup-20261010/README.md)
retains a test-only SpringBoard wait workaround, passing fixture smoke checks,
and failing Day/Week physical scrolling timings. It changes no app renderer or budget.

The [merged Beta Mac and phone regression](scale-results/merged-device-regression-20261010/README.md)
retains default-renderer and Mail functional checks, physical Calendar timing failures,
Mac paging commit stalls, primary-phone trace timeouts, and component-monitor failures.
The Mac tests now use the merged segmented picker. The physical fixture admits an
explicit guarded Mail route with 43 launch-policy checks; this does not enable live
Gmail or change the Calendar renderer. No baseline was changed.

The [prepared snapshot boundary regression](scale-results/calendar-snapshot-boundary-20261010/README.md)
checks the actual `DayData` initializer on whole- and half-hour DST transitions.
Calendar-core CI retains its failures/timings; the opt-in cached Day path also has
`ScaleStressUITests.testCachedVariedNativeDayScroll`. This correctness repair does
not enable layout reuse by default or establish a rendering speedup.

The [native XCTest startup investigation](scale-results/xctest-startup-20261009/README.md)
records runner/container diagnostics and the queued Simulator resource monitor.
Runner startup or functional success is separate from UI performance acceptance.

The [visible Metal calendar experiment](scale-results/calendar-live-metal-20261009/README.md)
adds repeatable physical-device scroll/paging/eviction checks, explicit missing-presentation
accounting, density reduction and independent queue/display-link ablations. It remains an
isolated prototype with failing latency and pixel evidence; it changes no shipping baseline.
Its reporter tests run in the existing calendar-harness CI discovery suite.
The physical runner also supports `--scenario pixels`: a fresh-process viewport
must change on paging and restore exactly after returning and cache eviction.
It validates the exact XCTest name/count and device, not just xcodebuild's exit.
Optional `hitches-framewait` exports add a render/wait intersection diagnostic;
the inclusive frame gate remains unchanged, and the derived interval does not
certify CPU execution or input-to-visible latency.

The [Skia Metal/Core Text feasibility check](scale-results/calendar-skia-feasibility-20261009/README.md)
retains the pinned native build, multilingual adapter failure and corrected smoke result.
It is backend feasibility only; calendar parity and performance remain unmeasured.
The subsequent [calendar raster comparison](scale-results/calendar-skia-raster-20261009/README.md)
adds repeatable matched raster jobs and pixel checks. Both retained matrices fail
pixel parity and have sampled host contention; neither is an adoption result.
The [color/path/command-reuse ablations](scale-results/calendar-skia-pictures-20261009/README.md)
retain all four policies, cold/warm/eviction work and an exact-image lifecycle
oracle with a zero-byte cache. Warm work drops, but native parity, two exact-image
comparisons and latency tails still fail; no baseline is replaced.

Performance is a continuing acceptance requirement. A change must meet the
[UI performance contract](ui-performance-contract.md) and must not make measured behavior slower
or use more memory beyond the declared measurement tolerance. Passing a component benchmark does
not certify end-to-end UI responsiveness.

## One command for the repeatable component suite

```sh
python3 tools/performance-regression.py run --device YOUR_SIMULATOR_UUID
```

This generates the Xcode project, builds Release with DEBUG audit fixtures enabled, then runs:

- 1, 7, 30 and 90 days at 2,000 emails, 100 events, 1,000 notes and 10,000 podcast episodes/day.
- Notes, Library, Plan and Mail redraw probes, each with 100 playback-clock ticks at 10 Hz.
- Absolute component latency limits, baseline median and tail latency, peak RSS, workload checksums,
  complete metric coverage and redraw comparisons.

The runner only installs on the selected Simulator. Use a dedicated fixture Simulator: installation
replaces its Banana binary. Fixture data is isolated; the normal service graph stays disabled.
Prerequisites: Xcode, xcodegen, Python 3 and the runtime specified in
[regression-baseline.json](regression-baseline.json). The initial reference targets this Mac model,
arm64, iPhone 17 Pro / iOS 26.5, Xcode 27.0. Other environments need their own reviewed reference.
Do not compare Debug and optimized builds or silently substitute another device/runtime.

Each invocation creates a new `.build/performance-regression/<timestamp>/` directory. An optional
`--out NEW_DIRECTORY` chooses its location. Existing directories are never overwritten.
`--derived-data .build/stress-dd` can reuse compilation products; a build still runs before measuring.
Logs, the exact baseline policy, copies of reference measurements and every completed raw report
remain available on failure.
`measurements.json` contains the collected suite and `gate.json` its verdict. A crash, absent metric,
wrong workload or incompatible environment exits **2 (unmeasured)**; a regression exits **1**;
only a complete passing component suite exits **0**. Build failures cannot become green results.

Re-evaluate retained measurements without launching anything:

```sh
python3 tools/performance-regression.py compare --results PATH/measurements.json
python3 -m unittest discover -s tools/tests -v
```

## References and noise policy

The versioned manifest points to retained raw measurements, not moving `latest` files. Initial
references were collected on a busy shared Mac; their binary SHA and dirty-tree provenance are
preserved. They are an initial guardrail, not a calibrated quiet-run distribution. Run on an idle,
dedicated host with no competing builds. Host load is retained; the gate never normalizes away a
slow sample. Investigate noisy failures using repeated complete runs, keeping every result. Do not
retry until one passes and discard failures.

The initial comparison margins are deliberately explicit:

| Measurement | Allowed measurement tolerance above reference |
| --- | --- |
| Component median | Larger of 1 ms or 10% |
| Component p95 | Larger of 2 ms or 15% |
| Peak process RSS | Larger of 16 MB or 5%, also below the 900 MB harness ceiling |
| Watched redraw rate | No increase from the reference (currently zero) |

These margins describe detectable regression, not permission to spend the margin on new work.
They are provisional until repeated quiet reference runs establish noise. Absolute budgets apply
independently. The current component collector takes seven samples, so its nearest-rank p95 is also
the maximum: an over-100 ms component sample cannot disappear in an average.
New reports retain all seven timings in collection order as `samplesMS`; the gate
verifies that they agree with the reported median and p95. Historical references
without raw samples remain supported. For diagnosis, `tools/scale-stress.py
--diagnostics` additionally records per-sample process CPU, fault and context-switch
counters. This optional instrumentation is not thread-specific and its overhead
must be checked separately. Host reports retain load samples, but `clean` still
means only no detected competing developer jobs or process-sampling errors—it is
not proof of an idle CPU, disk, memory subsystem or Simulator. A quiet host check
before booting a new Simulator does not establish quiet measurement conditions.
See the [query-tail investigation](scale-results/query-failure-diagnosis-20261009/README.md). This collector does
not measure every UI interaction or frame. The 900 MB Simulator ceiling is not a product/device
memory budget.

**Never automatically replace a baseline following a failure.** A baseline change must be a separate,
reviewable change containing old/new measurements, environment, reason, repeated-run evidence and
an explanation of every regression. Preserve previous artifacts. Ratchet references down after a
verified improvement so later changes cannot consume that improvement unnoticed. Raising a product
latency limit requires an explicit product decision; baseline maintenance cannot change the contract.
Adding/removing metrics or changing workload checksums requires review of coverage and correctness.

## CI and continuing use

`.github/workflows/performance-contract.yml` runs the gate's failure-behavior tests and checked-in
reference integrity on every push/PR. It does **not** run the app or certify performance.
`.github/workflows/performance-measurements.yml` provides manual and opt-in nightly component runs on a dedicated
trusted `banana-perf` macOS arm64 runner, with artifacts uploaded even on failure. No runner has been
provisioned and no remote workflow was triggered by this change. Do not run fork PR code on a
personal self-hosted Mac. When a dedicated runner exists, set repository variables `BANANA_PERF_ENABLED=true` and
`BANANA_PERF_SIMULATOR=<UUID>` to enable the nightly schedule (07:17 UTC). Make the measurement
status a required merge check through repository settings. Those variables/settings are not configured
by these files. Nightly app measurements stay disabled until explicitly enabled.
Until then, run the local command before merging changes to data stores, queries, scrolling, rendering,
observation, sync, caches or playback. Record the artifact path/verdict in the change description.

Retain the complementary suites:

- [`tools/perf-gate.sh`](../../tools/perf-gate.md): whole-app launch, idle CPU, memory and redraw storms
  across all routes on iPhone/iPad. Run it for broader UI/service changes and before releases; compare
  with its documented reference. It has a different workload and noise model.
- `BananaTests` and `BananaUITests/ScaleStressUITests`: migration, paging correctness and realistic
  scrolling/opening interactions. Their functional pass is not an input-to-visible latency pass.
- [`ui-performance-gate.py`](../../tools/ui-performance-gate.py): evaluate measured real-device frame
  and cold/warm interaction samples against 8.3 ms frames, direct input p95 <10 ms / max 20 ms,
  and UI max 100 ms (50 ms goal, about 32 ms preferred). Missing physical 120 Hz evidence remains
  unmeasured. Instrumentation/real-device collection is still outstanding; do not fill it with
  synthetic values or Simulator gesture durations.
- [`PerformanceInfrastructure`](../../PerformanceInfrastructure/README.md): dedicated-device power,
  background and endurance checks. Follow its preparation protocol separately.

The retained workload uses short fixture bodies and excludes real mail backfill, attachments, live
CloudKit/audio and large-history first migration. Extend coverage as those paths are instrumented;
never describe the current suite as proof of unlimited scale or all UI performance.

## First end-to-end runner validation — October 7, 2026

The full eight-case run completed and **failed the baseline comparison**, as it should:
[raw candidate](scale-results/regression-candidate-20261007.json),
[verdict](scale-results/regression-verdict-20261007.json).
All absolute component limits and RSS ceilings passed; the 90-day tier used about 670 MB.
All four redraw probes observed their selected root and recorded zero watched redraws.
Nevertheless, 7-/30-day podcast timings and 30-day notes-search tails exceeded the reference margins;
notes search reached 53–56 ms versus about 19 ms in the corresponding references.

This was an integration run on the heavily loaded shared host (recorded load averages roughly
300–970), with an iPad functional test overlapping the early scale cases. Attribution to app code
versus contention is unresolved. The final runner refuses to begin measurements while another
`xcodebuild` is running. **No baseline or threshold was relaxed, and this is not a green performance
acceptance result.** Reproduce on an idle dedicated host, retaining repeated runs and investigating
any persistent slowdown before approving a performance-sensitive merge. The runner itself was
checked with 15 Python tests and CLI success, injected-regression and missing-evidence cases.
Real-device frame and interaction acceptance remains unmeasured.

## Native Mac review preview

`python3 tools/mac-stress-preview.py --days 30` builds an optimized native Mac app with DEBUG
fixtures, a separate `com.boris.banana.mac.stressreview` identity and the display name
**Banana Stress Review**. It opens the full Mac sidebar with all four large stores loaded.
The debug-only `--ui-audit --stress-days N --disable-icloud` route skips normal service startup;
AppSupport uses a new temporary directory, and notes' legacy cloud-file access is disabled.
The original app and Beta data/defaults are not used. Preview copies, logs and fixture data remain
available after exit. Each launch makes a new isolated dataset; this is not a personal-data app.

The launcher also captures the same model-operation metrics to `scale-stress.json` in the isolated
AppSupport directory (identified in `app.log`). Mac reports identify macOS explicitly and must not
be compared against the Simulator reference. This preview and its component timings do not prove
native frame/input latency acceptance. The full macOS interaction/performance suite is still open.

Native review evidence (2026-10-08): Release arm64 build succeeded; native accessibility and
screenshot inspection confirmed `stress.ready`, Plan stress events and Mail's 60,000-message
inbox. SQLite counts confirmed 30,000 notes and 300,000 episodes across 300 shows. The initial
30-day model report is retained in `scale-results/native-mac-review-20261008/scale-stress.json`
(all eight component budgets passed, 350.8 MB reported RSS). These are component timings, not
input-to-visible or frame timings. Dense overlapping 24-hour fixtures make the native calendar
hard to read; that visual issue remains open.

The first native preview exposed a CloudKit startup crash: foreground polling ignored the
preview's disabled-cloud mode and attempted to create an unentitled container. Polling now
checks both the disable flag and entitlement, and the isolated Mac preview skips foreground
cloud polling. The rebuilt preview launched successfully. Shared-code component regression
artifacts are retained under `.build/mac-preview-change-regression`; consult its `gate.json`
for results: all scale scenarios (1/7/30/90 days) and four idle-redraw scenarios passed.
Full native Mac UI/performance acceptance remains outstanding.

## Native interaction profiling

Use the isolated Mac preview, not the daily-driver app. The email/calendar profile is:

```sh
python3 tools/mac-stress-preview.py --profile mail-calendar
```

It retains 90 days of mail (180,000 messages), 365 days of calendar events (36,500),
5,000 notes and 100 podcasts with 200 episodes each. Independent debug arguments are
`--stress-mail-days`, `--stress-event-days`, `--stress-notes`, `--stress-podcasts`, and
`--stress-episodes-per-show`. The legacy component suite and its baseline keep their
original workload; oversized podcast catalogs remain a separate capacity scenario.

Capture actual native UI work while exercising controls through XCUITest or computer use:

```sh
python3 tools/native-ui-trace.py --pid PREVIEW_PID --seconds 120 \
  --scenario '30-day legacy, warm Mail selection/scroll and Plan paging/scroll' \
  --out .build/native-ui-performance/UNIQUE_RUN
```

The recorder uses Instruments Logging + Core Animation Commits + Run Loops. It retains
all raw samples, trace logs, source revision, host load and recording completion status.
**Raw traces include the process environment: keep them local; share the summaries.**
A main-thread Core Animation commit over 8.3 ms is a frame-work failure. Fast commits are
not proof of full frame delivery or input-to-visible response. The collector therefore
never emits an overall acceptance pass; missing display/input evidence remains explicit.
Run-loop busy intervals are diagnostic, not substituted for response latency.

`tools/native-ui-test.sh` builds and runs `BananaNativePerformanceUITests` in Release.
It attaches only to an already-running stress-review bundle; it does not launch/terminate
Beta or production. Scenarios exercise Mail selection, scrolling and typing, and Plan
paging and scrolling, retaining screenshots in the xcresult. These are functional tests;
their wall-clock time includes automation overhead. Capture Instruments alongside them.
The script refuses to start if Automation Mode still requires authentication, and never
changes that policy. A user must authenticate to allow macOS automation without prompts.
Developer Mode must also be enabled (`DevToolsSecurity -status`); the script refuses a disabled
state and never changes it. A blocked runner is not a passing suite.

Actual native interaction evidence and remaining failures are recorded in
[the October 8 report](scale-results/native-interactions-20261008/report.md).

## Library-first calendar evaluation (2026-10-08)

The [October 9 source research](rendering-research-20261009.md) extends this audit with
Texture, DGCharts, Skia Metal and Apple's display-link/resource-synchronization samples.
It separates source findings from unmeasured hypotheses and defines staged renderer
comparisons; it does not adopt a dependency or replace the capacity search.

The [physical capacity results](scale-results/calendar-capacity-20261009/README.md) use
`report-capacity.py` to retain separate component gates and incomplete evidence. The
[offscreen Metal probe](scale-results/calendar-metal-tiles-20261009/README.md) is rerunnable
with `run-metal-tiles.py`; its GPU timings do not certify presentation or input latency.
`run-metal-tiles.py --comparison surfaces` retains three alternating process pairs per
seed/density for copied versus shared IOSurface textures. The [surface comparison](scale-results/calendar-metal-surfaces-20261009/README.md)
includes exact-pixel, eviction, memory and tail evidence; sharing is not shipping by default.

Before replacing the current grid, benchmark existing renderers through a small adapter using
our own occurrence/query models. Keep provider sync, durable edits and retries in the app.
The isolated component evaluation below measures pinned candidates. No library has been
integrated into the production app or accepted against the UI contract.

- [CalendarKit](https://github.com/richardtop/CalendarKit): MIT; iOS and Mac Catalyst,
  Apple Calendar-like day timeline. Latest inspected default-branch commit
  `99a4a05c641d70c3f735ef4256f60dc86580cf20` (2026-09-12). Has a reusable event-view pool,
  but `TimelineView.prepareEventViews` iterates every regular event layout attribute;
  reuse is not proof of vertical viewport culling. Benchmark as an iPhone/day candidate.
- [KVKCalendar](https://github.com/kvyatkovskys/KVKCalendar): MIT; day/week/month/year/list,
  iOS/iPadOS and Mac Catalyst. Inspected `0bcad2bd51e512a4088c0bcf65b85bc6e484d86f`
  (2026-09-03). Closest functional candidate for our multi-day timeline, but its timeline
  creation path filters/sorts events per date and constructs event views. Measure rather
  than assuming its scrolling work is bounded by the viewport.
- [HorizonCalendar](https://github.com/airbnb/HorizonCalendar): Apache-2.0, UIKit/SwiftUI iOS
  month/day-date grids; not an hourly event timeline. Inspected
  `257927434aecbc4a70163570b5ef40976f0428a2` (2026-09-03).
  [Its architecture](https://github.com/airbnb/HorizonCalendar/blob/master/Docs/TECHNICAL_DETAILS.md)
  explicitly resolves visible items incrementally and recycles views, with work tied to the
  viewport. Useful for date/month navigation and as architectural evidence, not a drop-in week
  scheduler. Its authors moved away from UICollectionView after their own measurements;
  using a collection view alone does not guarantee bounded work or memory.
- [JZCalendarWeekView](https://github.com/zjfjack/JZCalendarWeekView): MIT, iOS day/week
  collection-view implementation with reusable event cells. Default-branch commit inspected
  `6177be0ddb1257711186b8a282dfef5dcb274786` dates to 2020-08-03. Maintenance age is a
  material adoption concern; do not choose it solely because its architecture sounds right.
- [ScheduleKit](https://github.com/gservera/ScheduleKit): MIT, actual native macOS day/week
  control with async data loading and drag/drop. Default-branch commit inspected
  `b4f631e027d6cbaee799a5a4d8b97aea89df665c` dates to 2019-04-24. Investigate compatibility
  and ownership cost before treating it as a viable production dependency.

The default-branch dates above were checked through GitHub's API, not inferred from stars or
README claims. Native AppKit support is the largest gap in the current shortlist: Catalyst
support does not mean a UIKit calendar can be embedded directly in our AppKit target.

First evaluation: KVKCalendar for multi-day iPhone/iPad, CalendarKit for the day timeline;
assess ScheduleKit's AppKit viability separately. Use 100 events/day and 36,500 retained events,
including overlap, all-day/midnight/DST cases, travel bands, keyboard/VoiceOver, resizing, drag
updates, cold/warm paging and sustained scrolling. Record pinned revision, visible view count,
layout time, commit time, working-set growth, and available real-device input/display evidence.
Adopt a candidate only after the measurements and behavior checks justify it. If no AppKit
candidate qualifies, document that specific gap before implementing a minimal native adapter.


### Reproducible renderer probe

`tools/calendar-library-benchmark` is a separate Release UIKit app with pinned CalendarKit and
KVKCalendar revisions. It has no provider/account access or production-store integration.
Generate and build it, then run on an already-booted dedicated Simulator:

```sh
xcodegen generate --spec tools/calendar-library-benchmark/project.yml
xcodebuild -project tools/calendar-library-benchmark/CalendarLibraryBenchmark.xcodeproj \
  -scheme CalendarLibraryBenchmark -configuration Release -sdk iphonesimulator \
  -derivedDataPath .build/calendar-library-benchmark-dd build
python3 -m unittest discover -s tools/calendar-library-benchmark -p 'test_*.py' -v
python3 tools/calendar-library-benchmark/run.py --device SIMULATOR_UDID \
  --app .build/calendar-library-benchmark-dd/Build/Products/Release-iphonesimulator/CalendarLibraryBenchmark.app \
  --out .build/calendar-library-review/UNIQUE_RUN
```

The runner preserves every result and refuses an existing output directory. Exit 1 indicates
observed synchronous work above 8.3 ms, invalid evidence, or a failed case; exit 2 means UI
acceptance remains unmeasured. It never certifies acceptance. A synchronous main-thread block
above 8.3 ms is diagnostic evidence of work that cannot fit that frame budget; this is not a
measurement of compositor frame delivery. Every phase retains samples, p50/p95/p99, maximum,
and counts over 8.3 and 100 ms. Invalid/missing evidence cannot produce a pass. Five reporting
unit tests cover budget boundaries, retained outliers, invalid/incomplete samples, stale pages,
and percentiles; they are tests of the evaluator, not app performance evidence. The existing
performance-contract CI workflow now runs these checks alongside its reference-integrity suite.

All 11 cases are retained: each day renderer at 30/365/3,650 days × 100 events/day and 365 days
× 300/day, plus KVK five-day week at 365 days × 100/day with bounded/full feeds and 300/day
with a bounded feed. Each case mounts cold, alternates forward/backward 12 times, then applies
120 vertical offsets down/up. Fixture construction is timed separately. History is in-memory
for this isolated experiment; this does **not** test disk paging or concurrent mail/sync/playback.
The bounded KVK feed supplies ±7 days including midnight spillovers; CalendarKit requests each
date. Density is independent of retained history. Every tenth event lasts 24 hours, the rest
30 minutes, producing substantial overlap; these are timed events, not all-day events. This is
an adversarial overlap workload, not a claim about the typical distribution of business meetings.

Measurements wrap the public API call, pending layout, and `CATransaction.flush()`. The 250 ms
settling waits and asynchronous work between probes are outside these timings. Programmatic
offsets omit gesture tracking, deceleration and input-to-visible response. Counts distinguish
attached event views from rectangles intersecting ancestor clipping bounds; neither is a count
of readable labels or successful hit targets. KVK additionally checks that the requested date
has rendered events after paging. That check is not complete event identity/parity validation.
Do not compare these component numbers directly with the app's Instruments commit measurements.

### Architecture and ownership findings

| Candidate | Reuse available without a fork | Internal work needed for our proposed renderer | Platform/decision |
| --- | --- | --- | --- |
| CalendarKit | Date-based data source, selection/edit callbacks, event pool, day UI | Viewport-driven event lifecycle; cached overlap layout; injectable event view creation; a multi-day timeline | UIKit/Catalyst, no AppKit. Do not adopt as the shared rendering core. |
| KVKCalendar | Five-day week, custom event-view provider, custom rectangle-layout protocol, edit callbacks | Viewport lifecycle and bounded reuse; incremental page invalidation; adjacent-page preparation; dense-event presentation | Stronger mobile reference/prototype candidate, but a substantial rendering fork plus separate AppKit implementation would remain. |
| ScheduleKit | Native AppKit controls, async data source, drag/drop | Event viewport lifecycle, invalidation/layout modernization, compatibility and behavior validation | Source-screened only; not built or timed. No evidence justifying revival of this 2019 implementation. |
| HorizonCalendar | Incremental visible-item reuse for date/month grids | Hourly event scheduling would be a new component | Consider separately for date navigation; not a replacement for the hourly grid. |

Source evidence at the inspected revisions:

- CalendarKit's [timeline layout and event pool](https://github.com/richardtop/CalendarKit/blob/99a4a05c641d70c3f735ef4256f60dc86580cf20/Sources/Timeline/TimelineView.swift)
  recalculates overlap placement from `layoutSubviews`, repeatedly sorts an overlapping group,
  and prepares one view per regular event attribute. The private pool/layout methods mean an
  `EventView` subclass alone cannot replace that lifecycle.
- KVK's [timeline creation](https://github.com/kvyatkovskys/KVKCalendar/blob/0bcad2bd51e512a4088c0bcf65b85bc6e484d86f/Sources/KVKCalendar/TimelineView.swift)
  accepts custom rectangle layout and event views but constructs views across each displayed
  date. Those extension points do not make the lifecycle vertically virtualized.
  Its [public paging API](https://github.com/kvyatkovskys/KVKCalendar/blob/0bcad2bd51e512a4088c0bcf65b85bc6e484d86f/Sources/KVKCalendar/KVKCalendarView+Extension.swift)
  requires selecting the date before reloading the relevant events in this adapter.
- ScheduleKit's [event reconciliation](https://github.com/gservera/ScheduleKit/blob/b4f631e027d6cbaee799a5a4d8b97aea89df665c/ScheduleKit/SCKViewController.swift)
  creates an `SCKEventView` and four constraints for every inserted event, then invalidates all
  event views. Date/hour-label visibility handling does not establish event virtualization.

**Decision:** do not commit to wholesale adoption or a permanent fork yet. Bounded date queries
solve history growth; they do not solve dense-page view creation, repeated overlap layout, or
cross-platform rendering. If we replace those core mechanisms and separately build AppKit,
we own most of the performance-critical implementation regardless of the starting repository.
A library can still save useful behavior work, but this audit does not establish that either
candidate is the optimal long-term core. This conclusion is about architectural fit, not a
claim that a library's maintainers do not care about performance.

The next implementation comparison should put a minimal native viewport renderer and a narrowly
modified KVK prototype behind the same app-owned occurrence/layout snapshot interface. Start
with the Mac calendar, where the existing failure is measured and the UIKit candidates cannot
be embedded directly. Use native scroll containers; prepare indexed overlap geometry off the
input path, cache by data revision/date range/width/timezone, invalidate affected days only,
preload bounded adjacent pages, and recycle only visible event presentation. Keep durable edits,
retries and occurrence semantics in the app. Dense simultaneous events also require a readable,
accessible overflow/expansion policy: clipping offscreen views cannot bound a viewport containing
hundreds of overlapping visible events. Do not silently omit events to meet a budget.

A future adoption decision still requires real iPhone/iPad/Mac interaction traces, memory and
allocation measurements, cold/warm/cache-eviction behavior, actual gestures, keyboard/VoiceOver,
resizing, all-day/DST/recurrence/travel presentation, drag/edit parity and durable failure tests.
These were not validated by this bounded renderer probe. There is no new performance baseline
and no production-renderer change in this evaluation.


### Retained observations (2026-10-08)

Results and run provenance are retained in
[`scale-results/calendar-libraries-20261008`](scale-results/calendar-libraries-20261008/manifest.json).
The host was severely overloaded (one-minute load in the hundreds on a 10-logical-CPU Mac),
and Simulator launches sometimes stalled. These results are **diagnostic failures, not a clean
ranking of candidates**. The full per-sample data and timed-out cases remain in each run directory.
No normalization, baseline change, scenario removal, or passing-UI claim was made.

Corrected iPhone run 3 completed nine measured cases and two timeouts (KVK day/365 days/100 per
day and KVK week/365 days/300 per day). All nine measured cases contained synchronous work above
8.3 ms and above 100 ms. Selected results below are p95 **synchronous component work**, in ms,
not input latency or frame delivery:

| iPhone scenario | Page p95 | Offset/layout/flush p95 | Attached event views (page maximum) |
| --- | ---: | ---: | ---: |
| CalendarKit day, 3,000 events | 212.4 | 75.4 | 109 |
| CalendarKit day, 365,000 events | 214.8 | 80.9 | 109 |
| CalendarKit day, 300/day | 744.8 | 337.3 | 327 |
| KVK day, 3,000 events, bounded | 331.0 | 3.7 | 110 |
| KVK day, 365,000 events, bounded | 313.9 | 3.8 | 110 |
| KVK five-day week, 36,500 events, bounded | 2107.0 | 3.8 | 550 |
| KVK five-day week, 36,500 events, full feed | 2569.2 | 4.3 | 550 |

Both bounded day adapters retained the same attached-view count as total history grew 100×.
That supports the architectural separation between history size and active dates. Increasing
visible density from 100 to 300/day tripled attached event views (CalendarKit 109→327; KVK
110→330). KVK's five-day week attached 550 event views at 100/day. These counts are more useful
than a noisy speed ratio for identifying where bounded date loading stops helping. Page timings
include adapter event conversion/query work as well as the library; no CPU attribution profile
was collected for these isolated runs.

Earlier results are retained locally and explicitly marked invalid where appropriate: initial
harness forced parent layout on every offset and mixed timezones; the next KVK adapter reloaded
before selecting the date and its full-feed case rendered no events. Those KVK numbers are not
used in this comparison. A partial earlier iPad run was interrupted for that adapter correction.
The manifest records every earlier path. The corrected binary uses local-calendar dates, lays
out the parent only when needed, selects before reloading KVK, and validates requested-date
presence. These were benchmark fixes, not production fixes.


Corrected iPad run 2 was stopped after three consecutive launch/result timeouts. Its fourth
case was interrupted and seven remaining cases are explicitly marked unmeasured in the retained
summary; none were removed to obtain a pass. No corrected iPad case completed, so **cross-device
comparison remains blocked**. The earlier partial iPad run is retained but is not substituted
for this missing coverage. Benchmark processes were terminated; other apps/devices were left alone.

Validation: isolated Release build passed; 19 existing performance-gate/reference-integrity tests
and five new renderer-evidence tests passed (logs in the result directory). The production app's
component/UI suites were not rerun for this isolated harness/docs/CI change; production code is
unchanged. Repeated Simulator launch/result timeouts also prevent fresh UI acceptance evidence
on this host. The observed failures and missing coverage remain open; this report does not certify
the app or either library. A quiet-host rerun plus physical-device/native-Mac interaction evidence
is required before making a performance-based adoption decision.


## Native calendar prototype and optimization experiments (2026-10-08)

Results, source/binary identities, every completed/failed/deferred case, correctness logs and
remaining evidence gaps are retained in the [experiment report](scale-results/native-calendar-prototype-20261008/README.md)
and [manifest](scale-results/native-calendar-prototype-20261008/manifest.json). The latest complete
Simulator matrices have 30 valid iPhone and 54 valid iPad cases. Native matrix 4 has 42 completed
cases and six explicitly deferred when the user requested background-only testing. After the user
left, native matrix 5 completed all 52 current cases, all with recorded budget failures. The app-wide
eight-case component regression suite completed and failed; no baseline or budget was changed.

The user authorized a custom renderer prototype and requested a performance experiment for
every implementation optimization. It remains in `tools/calendar-library-benchmark`; production
calendar/data/persistence code is not replaced. Shared immutable geometry feeds native UIKit
and AppKit scroll containers. A batched drawing surface and a reusable-event-view alternative
render the same fixture IDs, interval positions, titles, clipping and background colors.
Selection and virtual accessibility activation are present; this is not full calendar feature
parity (drag/edit, recurrence expansion, all-day rows, travel bands, keyboard navigation and
polished dense-overlap presentation remain integration work). In particular, DST day clipping
is tested, but the prototype's elapsed-day axis is not complete local-wall-clock/DST presentation.

### Optimization ledger and tests

| Implementation item | Evidence/check | Acceptance boundary |
| --- | --- | --- |
| Batched surface instead of hundreds of event views/layers | Matched native `canvas` versus `cells` runs; same event-coverage oracle | Native API/layout/display/flush work, not compositor delivery |
| Prepared text reused across page/viewport changes | `no-text-cache` ablation; separate prepare/draw microbenchmarks | Cache bounded to 4,096 entries, fixed fixture text/style per surface |
| Background adjacent-page text preparation | `no-text-prefetch` ablation; main/preloaded glyph-build counters | Cancellation generations prevent stale completion after paging/eviction |
| Restrict speculative text to the destination viewport | `full-text-prefetch` ablation; independent geometry/prefetch-ID equality tests | Same 4,096-entry cap; avoids displacing useful titles with invisible ones |
| Geometry caching | `no-cache` ablation; cached versus rebuilt layout microbenchmarks; LRU/invalidation checks | 21 day snapshots per instance, fixed calendar/timezone; normalized widths |
| Adjacent geometry preparation | `no-prefetch` ablation; foreground/background geometry-build counters | Bounded two adjacent pages at utility priority, canceled on navigation |
| Interval lookup | Bucket index versus brute-force oracle and microbenchmarks, `force-index` ablation | Initial index was slower for broad viewports; default scan is intentional |
| Overlap lane assignment | Heap versus linear allocator, exact placement equality, randomized overlap tests | No dropped events or changed lanes to obtain a speedup |
| Overscan/reconciliation suppression | `no-overscan` ablation; reconciliation counters; independent visible-ID oracle | 160-point overscan; no update when viewport remains inside prepared area |
| Event-view reuse (alternative cell renderer) | `cells/none` versus `cells/no-reuse`; creation counters | At most 64 spare cells; not relevant to the canvas renderer |
| Width-independent geometry | Resize probes plus normalized geometry tests | Resizing must preserve IDs/intervals; text remains clipped to new bounds |
| Memory-pressure eviction | Cache/pool clear and immediate correct-page recovery probe; bounded-cache tests | Simulated eviction, not an OS jetsam/pressure endurance test |
| Prepared glyph drawing | Pixel-exact Core Text reference comparisons: Latin, CJK, Arabic, emoji | Immutable glyph/position arrays cross workers; CTLine/CTRun do not |
| Horizontal glyph culling | `no-glyph-culling` ablation and clipped bitmap equivalence at six widths | Retain a one-point antialias fringe; nonmonotonic glyph runs fall back to native clipping |
| Viewport-sized backing surface | `full-surface` ablation, scroll/resize coverage checks | Full scroll document remains 1,920 points high; surface covers viewport plus overscan |
| Prerendered page pixels (experimental alternative) | `--raster` comparisons with canvas/cells, `no-raster-cache` and `no-raster-prefetch` pairs | Cold, recovery, resize and image-retention costs remain in the gate |
| Publish prepared raster pages individually | `batch-raster-prefetch` pairs plus offscreen first/all-page availability trials | Integrated 250 ms settle can mask availability improvements; do not substitute this for input latency |
| Keep active pixels during memory-pressure eviction | Red/green offscreen retention test and 200 timed evictions; targeted iPhone/iPad recovery cases | Evict cached/speculative images while retaining the visible layer until replacement |

The [Core Text threading contract](https://developer.apple.com/documentation/CoreText) permits
sharing font objects but scopes layout objects to their operation/queue/thread. The final text
preparation path creates and consumes CTLine/CTRun in one operation, then transfers copied glyph
and position arrays plus immutable font/color objects. Main-thread drawing uses CTFontDrawGlyphs.
The 28 bitmap comparisons protect against losing shaping/fallback/emoji behavior in that path.
An initial culling implementation lost accent pixels at a narrow clipping boundary; the failed
test output is retained. The corrected version includes the antialias fringe and passes every
comparison. These fixtures do not establish equivalence for every font feature or script.

The lane allocator uses a linear scan below 4,000 placements and a heap at higher densities.
This crossover comes from retained 100/300/1,000/2,000/4,000/10,000-event microbenchmarks,
not an asymptotic argument alone. Both forced algorithms remain available for comparison.
The cell alternative now reassigns retired views in place, avoiding needless layer detachment
and reattachment; leftover spare views remain bounded to 64. Earlier reuse measurements did
not show a reliable win and are preserved alongside the revised implementation.

Do not add the percentage gains of separate ablations: cache/preparation dependencies interact.
For example, disabling geometry caching also makes geometry prefetch inapplicable, while text
preparation has its own switch. Repeated control cases beside variants expose host-load drift.
All measured maxima, invalid cases, earlier measurements, source/binary identities and failed
build/run logs are retained. Intermediate identity manifests are not complete source snapshots;
the committed source is the reproducible implementation going forward.
Changing the drawing strategy does not establish functional parity with the larger libraries.

### Prerendered-page experiment

`--renderer raster` prepares complete immutable Core Graphics images and installs them in a
native layer. Adjacent images are prepared at utility priority; generation checks reject obsolete
work. Native scrolling reuses the pixels while visible event hit targets/accessibility remain
available. Synchronous cache misses deliberately remain measured: the benchmark does not hide a
blank page behind an asynchronous task and call that a fast completed navigation.

The image cache retains at most **three pages and 128 MiB**, with LRU eviction and width/scale/date
keys. This is an explicit experimental cache limit, not a product memory budget. Active layer
contents, in-flight worker images, fixture history and framework allocations consume additional
memory. Process peak RSS is recorded; it does not capture every render-server/GPU allocation.
Fixture content, calendar/timezone and resolved appearance stay fixed for each run. Production
integration must include data revisions and appearance/font changes in invalidation; the date/
width/scale keys alone are not sufficient for an editable, live calendar.
The final raster suite has 232 checks, including known event/background pixels, asymmetric
interval orientation/clipping, 1x/2x/3x sizes, byte-for-byte worker equivalence, bounded count/bytes,
resize keys and 200 active-image eviction trials. Offscreen AppKit objects create no windows;
their timings are component evidence only. A separate five-trial probe measures first/all-page
cache availability with 1 ms polling for batched versus individual publication.

Append `--raster` to either runner for the six raster history/density cases and paired cache/
preparation experiments at both 100 and 300 events/day. On Simulator, `--cells` additionally
checks native event views across all six history/density cases. These append cases; existing
comparison cases remain present. A production choice must be made per platform: the initial
iPhone results favored reusable UIKit event views while AppKit favored the batched canvas.

Final review found and fixed active-image loss during cache eviction. The initial offscreen
retention test failed; the fixed test keeps the current pixels while discarding speculative
cache entries. Later publication experiments confirmed earlier first-page cache availability
(68.62 versus 150.25 ms median in the retained offscreen probe), while the eight paired Simulator
cases with 250 ms settling did not demonstrate a decisive navigation-latency benefit. Both the
two slow post-retention cases and all eight later paired cases are retained; none were discarded.
Native verification resumed after the user left the computer: matrix 5 completed all 52 cases
with valid coverage and budget failures. Fresh visible CUA interaction traces also failed the
8.3 ms commit limit (canvas max 9.45 ms; raster max 40.85 ms). See the experiment report for
retained samples, dense accessibility uncertainty and missing input/display evidence.

The full-page raster path is intentionally still an experiment. Its first dense Mac probe improved
scroll work but exceeded 100 ms during cold loading, cache recovery and resizing. Large synchronous
image preparation/installation is not an acceptable fallback. Smaller independently prepared
tiles and staged installation are candidates for a subsequent controlled experiment, with the
same correctness, cold-cache and memory-pressure requirements. Neither merely starting work on a
background thread nor showing stale/empty pixels counts as completing an interaction.

### Reproduction

```sh
mkdir -p .build/native-calendar-prototype
swiftc -O -parse-as-library tools/calendar-library-benchmark/Shared/*.swift \
  tools/calendar-library-benchmark/Native/MacBenchmark.swift \
  -o .build/native-calendar-prototype/MacCalendarBenchmark
python3 tools/calendar-library-benchmark/run-mac.py \
  --binary .build/native-calendar-prototype/MacCalendarBenchmark \
  --out .build/native-calendar-prototype/UNIQUE_MAC_MATRIX
```

The native runner preserves the six history/density cases, matched optimization controls and
variants. Its native displayIfNeeded step differs from UIKit's synchronous probe; compare
strategies within a platform, not AppKit numbers against UIKit library numbers. Every case
includes the original cold mount, 12 pages and 120 offsets, plus six explicitly uncached pages,
one simulated memory-pressure recovery, and three resizes. Per-phase action/layout/display/flush
breakdowns are diagnostic; the full synchronous duration remains the budgeted sample.

The native runner opens/focuses real Mac windows. **Do not run it while the user is working on
that desktop.** Run pure component checks and `simctl` probes in the background, without opening
Simulator or driving desktop input; keep expensive test jobs sequential. Defer foreground native
interaction/visual checks until an idle session or a dedicated test machine is available. Hidden
or occluded windows can be throttled and do not substitute for visible UI performance evidence.
When interrupted, retain completed cases and explicitly mark every remaining case unmeasured.

The Simulator runner defaults to all original 11 library cases plus six native cases. It
interleaves candidates within history/density tiers. `--candidates native` is an explicit subset
for a prototype-only run, recorded in environment.json; it is not a passing complete comparison.
It uses the same workload, page count, settle interval and offsets as the library probe.
Native samples additionally require an independent full-scan visible-ID match and confirmation
that those IDs reached the drawing path. Blank or stale pages cannot pass the evidence checks.

Pass `--ablations` to the Simulator runner to append matched controls and optimization variants.
The native runner includes these by default. `uncachedPage` clears the geometry cache before
each page but permits previously prepared text; `memoryPressurePage` additionally clears the
text cache and spare views. Neither should be described as a process-cold launch. The fixture
store is in memory and fixture generation is recorded separately from renderer timing. This
experiment does not measure disk paging, provider sync, migration, or full-app contention.

The existing performance-contract CI workflow also compiles/runs the pure Swift geometry tests,
pixel-equivalence tests and component microbenchmarks on macOS, retaining every raw sample.
Hosted-runner component timings have no reviewed baseline and do not certify UI performance.
Real-device input/display traces, platform behavior parity and workload-integrated measurements
are still required before this renderer can replace the app's calendar.


## Accessibility retention experiment (October 8, 2026)

The [retention experiment](scale-results/calendar-accessibility-20261008/README.md) isolates main-thread
accessibility object/hierarchy rebuilding in the native renderer. It preserves event IDs, ordering,
frames and activation while retaining surviving objects. The `rebuild-accessibility` ablation keeps
the comparison reproducible. `--accessibility-only` on either renderer runner explicitly selects
24 paired cases (three trials, two densities, two renderers), leaving normal matrices unchanged.

Offscreen checks, now included in CI, protect identity, retirement, scroll/resize, eviction and
empty-page behavior. The tests found and fixed stale content after empty installation. Native
Mac and both Simulator matrices completed with valid coverage, but performance budgets still fail.
See the report for per-platform tails, memory outliers, unchanged cold/miss costs, and missing
VoiceOver/physical-device evidence. This does not replace the full app component suite or baseline.

## Independent grid experiment (October 8, 2026)

The [grid experiment report](scale-results/calendar-grid-20261008/README.md) tests a separate
native backing for static lines/hour labels against the monolithic canvas. `--grid-only` selects
12 focused paired cases on either runner. The opt-in `--ablation split-grid` remains experimental;
the default renderer is unchanged. AppKit's retained-image variant reduces grid draws but worsens
cold loading, resize, recovery and RSS. UIKit tradeoffs are recorded separately. CI now checks
pixel equivalence through scroll/page/resize/eviction and retains the images. Failed versions and
all raw samples remain in the report directory; lower draw counts do not imply UI acceptance.

## Explicit tile experiments (October 9, 2026)

The [tile report](scale-results/calendar-tiles-20261009/README.md) retains the full canvas/raster/tile
comparison, separate scroll/page prefetch ablations, and fixed-budget cache experiments. These
are experimental renderers, not production UI acceptance. Focused subsets are explicit:
`--tiles-only`, `--tile-prefetch-only`, `--tile-cache-only`, and `--tile-text-only` on the existing
Simulator and Mac runners. The default matrices and all performance budgets remain unchanged.

`TileTests/main.swift` checks coverage, image bounds, bounded channel-rounding differences,
scroll/page/resize/eviction/empty lifecycle, and byte-exact equivalence for optional text culling.
`TileTests/prefetch.swift` checks cancellation, retired generations, cache limits, adversarial LRU
ordering and wide-page prefetch retention. CI retains their results. A one-channel-level bound
is explicit for translated tile versus full-page rendering; failed strict comparisons remain
in the report. This is not a change to a performance budget.

`run-device.py --device DEVICE --app SIGNED_BENCHMARK_APP --out NEW_DIRECTORY` runs the same
18 fixed-budget cache cases on physical hardware. It accepts only the isolated benchmark bundle,
retains install/launch/copy failures, and never certifies input-to-visible or display delivery.
Screen scale, maximum supported refresh rate, completion thermal state and low-power mode are
recorded by new builds; maximum supported refresh is not measured delivered refresh.

The [native overflow report](scale-results/calendar-overflow-20261009/README.md) retains the
staggered-overlap regression and native Mac traces. `tools/calendar-overflow-tests/main.swift`
checks omitted-event coverage and stable grouping. The native UI suite also exercises reaching
and opening the final hidden stress event through the overflow list; retain its actual result,
including failures, before claiming that wheel scrolling works.

### Host contention evidence

The component collector now samples `xcodebuild`, `swift-frontend`, `swiftc`, and `xctest`
once per second throughout each case, in addition to its existing preflight check. It never
stops those processes. Per-case `*-host.json` files survive a failed workload; completed cases
also embed the evidence in `measurements.json`. Observed competing work or incomplete sampling
fails the gate while preserving numerical budget failures and all samples. Historical references
remain comparable without retroactively inventing monitoring evidence. Sampling can miss short
jobs and does not establish an otherwise idle machine.

New Simulator and native renderer-runner invocations likewise retain per-case monitoring and
label observed contention explicitly. Earlier matrices lacking these files must not be described
as continuously monitored. A fresh clean run supplements a contended run; it never replaces it.

## Physical renderer and native functional follow-up (October 9, 2026)

The [physical renderer report](scale-results/calendar-physical-20261009/README.md) retains 18
completed iPhone 14 Pro cases, all with budget failures, plus the preceding iOS 27 lifecycle
launch failure. The isolated harness now uses scenes and an explicit verified Info.plist.
Maximum screen refresh capability is recorded separately from unmeasured display delivery.
Physical iPad coverage remains pending while the device requires a passcode.

The native Mac functional suite passed Mail selection/scroll/typing, Plan paging/scrolling,
overflow wheel reachability and palette invalidation/duplicate-publication checks. See the
[observation report](scale-results/calendar-observation-20261009/README.md) for the actual result
and prior attachment/selector failures. Keep exactly one isolated preview visibly open; XCTest
resolves its running app URL. Stricter event-rebinding assertions subsequently passed in the [pointer-state follow-up](scale-results/calendar-interaction-local-20261009/README.md).

The opt-in accessibility page-cache experiment uses `--tile-ax-cache-only` in the Simulator/Mac
renderer runners or `--matrix accessibility-cache` in the physical runner. It compares the same
budgeted tile policy with/without retaining same-event accessibility objects on at most three
retired pages and 4,096 objects. Off-page actions are disabled; objects never change event IDs.
Memory pressure clears retired pages. CI checks identity, activation, order, bounds and eviction.
This is an experiment; fewer allocations alone do not establish an interaction improvement.

The [lazy UIKit/container experiment](scale-results/calendar-ax-lazy-20261009/README.md)
adds explicit directional and rapid-navigation coverage through `--navigation-stress`. It appends
12 forward, 12 return, 12 rapid-forward and 12 rapid-return pages to the unchanged original phases.
Rapid phases settle 32 ms between requests; this is a workload parameter, not a claimed response
latency. Missing phase samples or incorrect visible/drawn IDs fail evidence validation.
`--tile-ax-lazy-only` (Simulator) and `--matrix accessibility-lazy` (physical device) compare eager
same-event page retention with native lazy UIKit accessibility containers. `--exercise-accessibility`
forces enumeration of every visible accessibility element inside each timed phase and independently
checks resulting IDs, frames and enabled state outside the timed region. Neither path establishes
VoiceOver focus behavior or input-to-visible acceptance. All cold/miss/eviction samples remain gated.

The [native Core Text tile experiment](scale-results/calendar-native-text-20261009/README.md)
uses `--tile-native-text-only` (Simulator/AppKit) or `--matrix native-text` (physical device).
It compares native per-worker line drawing with copied prepared glyph arrays, preserving exact
pixels in the tile oracle. Physical results show only modest drawing-cost reductions; all cases
still fail budgets. Cold work and directional misses remain in scope.

The [Mac hover observation report](scale-results/calendar-local-hover-20261009/README.md)
retains the original inline implementation and the initial extracted variants, including the
initial control-design limitation. `--calendar-local-hover` and `--calendar-local-drag` are
separate experimental preview flags; neither changes persistence or recurrence decisions.
Native tests retain hover/drag body counts and verify visible rejection/rollback for fixture moves.
Counts and XCTest gesture wall clock are not latency acceptance. The native test script accepts
optional `NativeInteractionTests/testName` filters; filtered runs are explicitly partial coverage.

The [matched Mac pointer-state follow-up](scale-results/calendar-interaction-local-20261009/README.md)
retains successful seven-test control/hover/drag suites, the earlier blocking-sheet selector failure,
manual context-menu date rebinding, and native paging traces. Body-count reductions do not establish
a latency win; all three first paging traces still exceed 8.3 ms.

The [pending-write durability fault tests](scale-results/calendar-write-durability-20261009/README.md)
exercise real temporary-file failure and immediate relaunch, and retain enqueue timings at 0, 10,
100 and 1,000 pending entries. Run model-only checks with `BananaModelTests` and
`-only-testing:BananaTests/PendingCalendarWriteStoreTests` plus
`-only-testing:BananaTests/PendingCalendarWriteTests`. Preserve expected failing before results.
The Mac preview's `--calendar-fail-local-write --calendar-observation-audit` flags support the
separate draft-retention UI check without sending a provider request. This flag requires an isolated
DEBUG stress fixture. Neither local durability nor an enqueue timing certifies provider idempotence.

The [native event-accessibility experiment](scale-results/calendar-event-accessibility-20261009/README.md)
compares the original child hierarchy with `--calendar-group-events`, using SwiftUI's native
accessibility element behavior. The nine-test native suite verifies representative element counts,
correct detail activation, drag rejection, page rebinding, overflow access and local-write draft
retention. This remains default-off pending timing and broader VoiceOver/travel-detail evidence.
The earlier grouped run's two coordinate failures remain retained with the corrected full run.

The [bounded tile-preparation experiment](scale-results/calendar-queue-preparation-20261009/README.md)
uses `--tile-queue-only` in the Simulator/Mac runners or `--matrix queue` on physical devices.
Native operation queues with one/two workers are compared with the existing task implementation.
Faster offscreen preparation did not improve the first physical rapid-navigation matrix; all cases
still fail budgets. The new availability probe retains pixels, cancellation, memory and timing
tradeoffs and does not replace the unchanged full renderer scenarios.

The [cooperative queue-cancellation follow-up](scale-results/calendar-queue-cancellation-20261009/README.md)
uses `--tile-queue-cancel-only` (Mac/Simulator) or `--matrix queue-cancel` (physical device).
The offscreen cancellation oracle and lifecycle suite are persistent CI checks. Faster obsolete
worker shutdown and selected physical paging improvements do not make the failing renderer pass;
all cold, eviction and rapid-navigation samples remain required.

The [visible-day layout-reuse experiment](scale-results/calendar-layout-reuse-20261009/README.md)
is selected with `mac-stress-preview.py --calendar-cache-layout`. Both native nine-test suites
passed, but matched commit traces still failed. It remains disabled; a separate query-free burst
is explicitly non-comparable because intermediate page updates may coalesce.
The [production-path integration follow-up](scale-results/calendar-integration-20261009/README.md)
extends opt-in prepared layouts to mobile day/week and agenda grids, with a persistent
allocator parity oracle and separate default/prepared dense-calendar UI tests. It does not
replace the app renderer or enable the inconclusive layout-reuse experiment by default.
The [artwork adapter](scale-results/calendar-artwork-integration-20261009/README.md) separates
real event painting from stores/actions and adds a 2,496-case exact offscreen pixel oracle to
calendar-core CI. It checks desktop/mobile layout branches on macOS, not iOS pixels or UI speed.
The frozen reference must not be regenerated to turn a renderer mismatch into a pass.
The [prepared app-path experiment](scale-results/calendar-prepared-app-20261009/README.md)
adds bounded preparation/consumer-lifetime checks to CI and an explicit prepared-artwork
UI test. Its cache/API measurements are separate from device interaction acceptance.
The comparison test now logs `CALENDAR_SCROLL_PROTOCOL=2`, sets a reproducible
zoom and reveals an actual event before scrolling. Both policies use opt-in,
offline actionable fixture IDs and must open the selected detail. The component
workload keeps its original IDs. Verify the executing protocol and exact test
counts; a retained run demonstrated stale runner execution after a rebuild.
Refreshing only the owned fixture Simulator's XCTest runner resolved that symptom.

The [asynchronous foreground preparation experiment](scale-results/calendar-async-preparation-20261009/README.md)
adds `TileTests/async.swift` to CI for exact pixels, cancellation, page coherence and bounded cache
checks. `--matrix foreground --foreground-navigation` (physical) or
`--foreground-only --foreground-navigation` (Simulator/AppKit) appends a separate 68-sample response
and main-section comparison while retaining every original phase. These section/API timings are
not input-to-visible or frame delivery. Supplemental `--memory-probe --workers 0|1|2` runs exclude
reference-image allocations and cannot replace pixel checks. Actual touch correctness can be run
with `test-device-interactive.py`; its UI automation timeouts are not performance budgets.

The [native surface experiment](scale-results/calendar-native-surfaces-20261009/README.md)
compares immutable IOSurface-backed CVPixelBuffer layer contents with CGImage using
unchanged geometry, pixels and workload. `--foreground-surface-only` (Mac/Simulator)
or `--matrix foreground-surface` (physical) selects three alternating paired trials.
The separate surface/accessibility matrix holds storage fixed while comparing
eager and lazy UIKit accessibility. Pixel and async lifecycle oracles are in CI.
Native surface results show lower measured publication cost and memory, but
cold/dense-page failures remain and no shipping renderer or baseline is replaced.

`run-mac-mount.py --binary RELEASE_BINARY --out NEW_DIRECTORY` adds fresh-process
controller-mount comparisons without replacing the original cold phases. It
records initial native setup separately and retains every failure.

`profile-touch.py --device UDID --instruments-device NAME --ablation POLICY --out NEW_DIRECTORY`
pairs the already-built physical XCTest swipe test with an eight-second Animation
Hitches capture, then exports selected tables. It records partial swipe overlap.
`report-hitches.py` requires app-attributed update rows and matching compositor
rows, reports variable display cadence, and flags measured work over 8.3 ms even
when Instruments reports no hitch. Neither script produces full UI acceptance.
Raw Instruments traces may include process environment data; retain them locally,
and archive only inspected, sanitized summaries in the repository.

### Cache recovery and foreground executor comparisons

The isolated native prototype has two explicitly opt-in controls:
`--async-cache-recovery` changes the interactive Clear cache action to complete in
bounded background workers; `--foreground-dispatch` compares two serial native
Dispatch queues against the existing Swift cooperative executor. Neither changes
shipping behavior or the original synchronous cold/warm/eviction benchmark phases.

```sh
swiftc -O -parse-as-library tools/calendar-library-benchmark/Shared/*.swift \
  tools/calendar-library-benchmark/Native/MacBenchmark.swift \
  -o .build/calendar-recovery
python3 tools/calendar-library-benchmark/run-mac-recovery.py \
  --binary .build/calendar-recovery --out .build/calendar-recovery-control
python3 tools/calendar-library-benchmark/run-mac-recovery.py \
  --binary .build/calendar-recovery --comparison executor \
  --out .build/calendar-recovery-executors
```

Each collector creates a new directory and runs three alternating paired trials
at 100 and 300 events/day across 365 days, with 21 evictions per process. It retains
all raw samples, source/binary identity, host-monitor status, peak RSS and sampled
physical footprint. First-use failures cannot be dropped. The analysis checks
coverage, completion, sample count and unexpected synchronous fallback before
reporting component timings. Exit 1 means an observed budget failure; exit 2 means
unmeasured full UI acceptance or invalid coverage. API flush is not display delivery.

For controller correctness, use `--check interactive-recovery` with the same
native binary, with/without each flag; `--check navigation` covers supersession.
`TileTests/async.swift --foreground-dispatch` additionally validates exact pixels,
cancellation, eviction and bounded retention. This oracle is part of persistent CI.
See [retained recovery/executor results](scale-results/calendar-native-surfaces-20261009/README.md).

Native trace summaries now report both inclusive Busy spans and spans excluding
explicit nested run-loop waits. A button's tracking loop can wait inside a Busy
parent. The additional metric preserves preemption and synchronous blocking; it
is neither CPU execution time nor input latency. Slow commits and slow non-waiting
spans both remain failures. The original raw tables and metrics must be retained.

`--time-profiler` on `native-ui-trace.py` is a diagnostic option, but this machine's
Instruments has failed combined recordings with a tagged-backtrace type error.
Use standalone Time Profiler for CPU diagnosis and the default trace configuration
for matched UI intervals; never accept the partial combined recording as complete.

When the desktop is available, the isolated surface preview can run the focused
native interaction scenarios with:

```sh
bash tools/native-ui-test.sh \
  CalendarPrototypeInteractionTests/testCacheRecoveryAndPaging \
  CalendarPrototypeInteractionTests/testRepeatedWheelScrolling
```

Exactly one `com.boris.banana.calendar-surface-review` preview must already be
running. The tests resolve its live URL and do not launch or terminate the user's
normal app. The default script still runs only the original production-preview
interaction class. Pair these functional tests with a trace for actual work
measurements; gesture durations and polling never count as input latency.

`run-mac-recovery.py --comparison native-text` holds asynchronous recovery and
surface storage fixed while comparing prepared glyph drawing to the existing
Core Text native line renderer (`--raster-native-text`). Results verify the actual
text policy so an older binary cannot silently ignore the option and appear to
provide a valid comparison. Its exact-pixel/cancellation oracle also runs in CI;
retained cold-tail and memory costs are described in the same result report.

`--comparison combined` compares cooperative/prepared text against Dispatch/native
text together, with surface storage and asynchronous recovery held fixed. Both
reported policy flags must match the selected case. This interaction experiment
does not replace either individual ablation; retain its cold tails and memory
alongside those comparisons before considering adoption.

## Varied calendar fixture correctness

The [varied-fixture report](scale-results/calendar-varied-fixtures-20261009/README.md)
retains the repeated single-calendar workload as `uniform-v1` and adds `varied-v1`.
The Simulator, Mac and physical-device calendar runners accept `--fixture`, `--seed`
and `--hidden-calendars`; reports must match the requested configuration. CI checks
fixture diversity/coverage, 12 actual bitmap colors and exact async pixels at both
densities and day/week widths. The uniform workload missed a concurrent colored-fill
failure; the first narrow-lock correction passes pixels but increases preparation
cost. Neither the corrected fixture nor those component checks establish UI capacity.

### Experimental text reuse and device lifecycle validity

`--memo-raster-text` is a default-off calendar benchmark ablation. It uses bounded,
job-local prepared-text reuse; compare it with the same binary and fixture without
the flag. Keep cold, warm, eviction, tail and memory results, even where they worsen.
CI includes memo capacity/style checks and exact-pixel async/cancellation coverage.
The physical `test-device-raster.py --memo-raster-text` command checks the same
implementation at device scale; it does not certify UI latency.

The iOS programmatic performance harness records `foregroundProtocol` version 1:
activation wait, idle-timer control scoped to the run, and lifecycle transitions.
`run-device.py` rejects absent protocol, inactive completion or interrupted runs.
A report collected after suspension/profiler attachment cannot replace an original
timeout or serve as clean matched performance evidence. Keep the 90-second collection
deadline separate from the unchanged 100 ms UI ceiling.

### Repository query probes

`tools/performance/statement-cache-probe.py` compares uncached/cached GRDB SQL
fetches on a copied stress catalog, including explicit cache release and warm reads.
It links the pinned GRDB build, checks payload ordering/bindings, and retains host
monitoring, memory, commands and binary identity. `tools/performance/notes-trigram-probe.py`
is an isolated FTS5 candidate-filter experiment with scan/index/selectivity ablations;
it does not change the Notes schema or replace localized-search correctness tests.
See [query investigation and reproduction](scale-results/query-performance-20261009/README.md).
Continue running the full persistent app suite for shipping query changes.

The [Day and independent-height integration](scale-results/calendar-day-integration-20261010/README.md)
adds real Day interaction checks and explicit cache-miss instrumentation for fresh
Day/Week launches. `tools/calendar-artwork-tests/profile-app.py` rejects missing or
truncated preparation evidence. Individual preparation API times are not frame,
queue-to-ready or input-to-visible measurements. The persistent raster oracle also
checks compact Agenda text inside independently sized canvases against the frozen
reference and retains its uncached/warm ablation.

**Mode-switching correction (protocol 3):** `-planMode week` is an argument-domain
preference and overrides later picker writes. Retained protocol-2 Day/Agenda tests
can show a selected picker label while still rendering Week; those passes do not
establish switched-view coverage. Interaction tests now seed a writable preference
through `STRESS_INITIAL_PLAN_MODE` on isolated stress Simulator launches, then assert
the actual content-surface identifier. Preserve protocol-2 runs as historical
results, not Day/Agenda acceptance. Direct-launch profiling with a fixed mode is
not affected by this switching issue. See the Day integration report's defaults
probe, screenshots, and retained selection failure.


The [Agenda integration checks](scale-results/calendar-agenda-accessibility-20261010/README.md)
retain the real mode-switching correction, early-event geometry regression, per-day
accessibility grouping, and same-binary preparation-admission controls. Persistent
pure geometry checks cover DST and clipping; artwork lifecycle checks cover cancelled
viewport replacement. The prepared backend is still audit-only, and these results
supply no physical 120 Hz or input-to-visible acceptance.


The [location-service startup fault collector](../../tools/onboarding-location-tests/README.md)
checks that calendar/fixture startup remains available when its own Simulator's
location daemon cannot reply. It records before/after builds and restores the
service on exit. Its verdict tests run in CI; device collection is an explicit
manual command. Launch-to-fixture-report timing is not a UI acceptance metric.

## Native Day viewport integration

The [real-app Day integration experiment](scale-results/calendar-native-day-20261010/README.md)
introduced `--calendar-native-day` in the optimized DEBUG audit build. The
[default-adoption follow-up](scale-results/calendar-day-default-20261010/README.md)
now enables native reusable Day cells in production and DEBUG iOS/iPad builds;
`--calendar-reference-day` explicitly selects the old DEBUG comparison host.
Week, Agenda and AppKit remain separate work.
The persistent `ScaleStressUITests` cases are:

- `testNativeDayCalendarScroll`: native viewport, dense scrolling, event identity/detail.
- `testNativePreparedDayCalendarScroll`: additionally requires installed prepared artwork.
- `testNativeDayPagingAndZoom`: adjacent dates/IDs, preserved time position, pinch spacing.
- `testNativeDayCreateGesture`: blank audit-slot press/drag opens the editor without saving.

Use the existing `testDenseDayCalendarScroll` as the same-binary reference, in
reference/native/native/reference order. Retain all result bundles and individual
samples; do not read XCTest gesture duration as an input latency measurement.
`tools/calendar-artwork-tests/profile-app.py --mode day --trials 1 --day-viewport POLICY`
collects the separate reference/native preparation comparison. Its default command
still runs the original Day/Week sequence. These checks do not replace the full
component suite or physical frame/input acceptance.


## Durable Calendar moves

The calendar-core CI job now runs the journal and injected-provider lifecycle checks
in `tools/calendar-move-tests/README.md`, retaining their JSON reports. These verify
persistence ordering, recovery, conflict handling and explicit discard. The real-app
`ScaleStressUITests.testNativeDayMoveRecovery` additionally exercises the native Day
move, recovery sheet, retry and two relaunches in an isolated fixture. See the
[recovery integration evidence](scale-results/calendar-move-recovery-20261010/README.md)
for exact coverage and remaining provider/device acceptance limits.


The [relative-move correction](scale-results/calendar-move-geometry-20261010/README.md)
adds `CalendarMoveGeometry` component checks to calendar-core CI. The targeted app
case `ScaleStressUITests.testNativeDayContinuationMove` verifies the persisted
failure destination after moving an overnight continuation; failure-alert existence
alone is insufficient. Frozen pre-fix component/UI failures remain retained.


The [full-app varied calendar workload](scale-results/calendar-varied-app-20261010/README.md)
reuses the standalone generator through `--stress-calendar-fixture varied-v1`.
`--stress-events-per-day N` is supplementary only; the legacy component fixture is
unchanged. `testVariedReferenceDayScroll` / `testVariedNativeDayScroll` retain actual
installed workload metadata before scroll/open/page checks. The preparation
collector supports `--fixture varied-v1 --density N` and validates installed counts
and checksum presence. Compare identical checksums and retain actual daily maxima;
a mean density is not a worst-day capacity result.


The [mobile event-label correction](scale-results/calendar-mobile-accessibility-20261010/README.md)
adds short/tall exact-label and detail-activation checks for native, reference and
prepared Day artwork. `testLegacyDayEventAccessibilityControl` reproduces the
triplicated tall label with a DEBUG-only ablation; its expected duplicate is not
production acceptance. `testLegacyNativeDayAccessibilityScroll` compares the same
native host without grouping. Preserve control/corrected scroll samples and full
component results; hierarchy correctness is not physical VoiceOver or frame timing.


The [mobile neighbor-preparation comparison](scale-results/calendar-neighbors-20261010/README.md)
adds `tools/calendar-neighbor-tests` to calendar-core CI. It retains exact parity
against frozen Day/Week scans, alternating component timings and optional fresh-
process first-use/memory measurements. The app's DEBUG
`--calendar-reference-neighbors` control supports matched native Day and Week UI
checks. Snapshot preparation has no cross-update cache; do not call its component
speedup a frame/input pass or discard the failing high-density timings.


The [Notes first-use investigation and crash correction](scale-results/notes-first-use-20261010/README.md)
retains the original repository crash, native-Boolean correction, fresh-process
phase diagnostics and full post-change component/UI results. `notes-search` CI runs
384 API/cache correctness checks and retains paired matching samples. The real
repository regression is `NoteRepositoryTests.testTrailingIgnoredSearchCharacterDoesNotCrash`.
The isolated localized-query/index matrix still records Japanese query times above
100 ms; the standard `needle` fixture does not cover that case. A green standard
suite must not be described as complete localized-search performance acceptance.


## Native Week candidate

The [native Week report](scale-results/calendar-native-week-20261010/README.md)
records the default-off `--calendar-native-week` collection viewport, retained
initial reachability failure and corrected reference/native comparison. Persistent
`testNativeWeekCalendarScroll` verifies dense scrolling and exact event detail;
`testNativeWeekNavigation` verifies the varied fixture, reuse, gutter, paging and
pinch. Protocol 4 uses a searchable day list to explicitly open event 61 before
scrolling with a common clock anchor; earlier protocols did not prove that event
was reachable. `tools/calendar-viewport-item-tests/run.py` runs descriptor identity,
clipping and deferred-content checks in calendar-core CI. Lower process memory is
measured; faster physical scrolling and full Week parity remain unproven.


The [native Week rotation regression](scale-results/calendar-week-resize-20261010/README.md)
adds `ScaleStressUITests.testNativeWeekRotation`: preserve a selected column through
portrait/landscape/portrait changes, verify the gutter and retain the original
pre-fix failure. Run it with the opt-in Week interaction cases and the shared Day
paging test. This functional resize check does not measure resize latency.


The [header publication experiment](scale-results/calendar-header-updates-20261010/README.md)
adds `tools/calendar-header-tests` to calendar-core CI for delivery ordering and
lifetime. Its `compare-app.py` runs the same-binary reference/native/native/reference
rotation comparison and checks xcresult warnings, exact counts and zero skips,
then shared Calendar interactions. Run the full component suite separately; these
checks do not establish frame or input-to-visible latency.


## Mail paging integration

`tools/mail-paging-tests/run.py --device SIMULATOR_UUID --out NEW_DIRECTORY` runs
Mail session/list-model tests and real-screen older-mail reachability/opening.
The dedicated nightly/manual workflow now runs it after the component suite,
including when the component gate fails, retaining both results. It requires
explicit coverage of growth, delayed handoff, cancellation and both UI cases;
skips, wrong devices, runtime warnings and missing cases fail. See the
[paging result report](scale-results/mail-paging-20261010/README.md). This is
functional Simulator evidence, not physical frame/input acceptance.

## Native Week default adoption — October 10

Week now selects the native collection viewport by default on iOS/iPadOS in both
production and DEBUG source. `--calendar-reference-week` is DEBUG-only and retains
the old host for matched comparisons. Historical opt-in reports above describe
those builds, not the current default. Mac native integration remains outstanding.

`testNativeWeekCalendarScroll`, navigation, rotation and creation-editor tests now
launch without a renderer flag. The scroll test explicitly requires a native
collection view. `testDenseCalendarScroll`, cached/prepared reference tests and the
reference-neighbor Week case explicitly retain the reference host, preserving the
meaning of their comparisons. Current default-adoption validation artifacts are
under `.build/calendar-week-default-20261010`; pending runs are not passes.


### Mac preview mode switching and idle-session checks

The Mac preview launcher now uses `STRESS_INITIAL_PLAN_MODE=week` to seed a writable
DEBUG stress preference. The former `-planMode week` argument overrode subsequent
picker writes, so it was unsuitable for Day/Week switching acceptance. The same
seed guard now covers the isolated Mac stress route; production launches do not
read it. `--calendar-reference-mac` explicitly selects the old DEBUG host for
controlled comparisons.

Queued visible checks may use `mac-stress-preview.py --require-idle-before-open 600`
and `BANANA_NATIVE_REQUIRE_IDLE_SECONDS=600 tools/native-ui-test.sh ...`. Both
recheck HID idle time after building, immediately before opening/driving the app;
recent activity defers visible work while retaining the build. These checks are
session coordination, not performance evidence or a substitute for authorization.

`mac-stress-preview.py --profile mail-calendar --calendar-fixture varied-v1`
selects the existing varied, multi-calendar generator for supplementary native
comparisons. The default remains `legacy` so prior workloads are not silently
replaced. Compare reference/native with the same profile, density, calendar
fixture, build, window size and interaction recipe; this option adds no acceptance
claim and does not change the persistent component baseline.

For supplementary real-app capacity searches, add `--calendar-events-per-day N`
(1–1000, requires `varied-v1`). Keep `--profile mail-calendar` to retain 365 days
and the same Mail/Notes/Podcast load while changing only calendar density. Verify
the installed `stress.ready` metadata, actual daily maxima and checksum for each
run. Repeat the same verified paging/scrolling recipe on the same binary; preserve
failures and record cache state. A capacity below 100 events/day does not replace
the unchanged stress target, and passing commit timings alone does not establish
input/display acceptance. The flag enables measurement; it establishes no capacity.


## Initial Mail and Calendar search checks

`tools/mail-index-tests/run.py` includes local FTS search across retained history,
account/keyset correctness, duplicate-hit folding and transactional edit/delete
invalidation. `search-benchmark.json` retains alternating original-summary versus
ID-first queries at 180,000 messages; the actual query's 100 ms guardrail stays fixed.
`tools/calendar-search-tests/run.py --out NEW_DIRECTORY` checks provider query/path
encoding, explicit recurrence bounds and bounded page size. These are components,
not live provider or 120 Hz acceptance. CI retains both sets of results.

`ScaleStressUITests.testMailSearchFindsRetainedConversationAndClears` and
`testCalendarSearchEntryAndDismissal` add UI coverage. The Mail case uses explicit
fixtures; the Calendar case exercises entry/dismissal without contacting an account.
Neither establishes live search correctness or device performance by itself.
The existing persistent Mail paging runner now requires both cases as well, so
nightly/manual measurements retain missing, failed or skipped search coverage.


## Reader body handoff

`tools/mail-reader-tests/run.py --out NEW_DIRECTORY` compiles the actual reader
and presentation dependencies, extracting the existing attachment opener and
subject cleaner without replacements. It requires four passing cases: placeholder
replacement, rejection of late obsolete reads, removal during a read, and ready-body
reuse/eviction. CI retains the original sources/hashes and test logs. The broader
Mail index suite also tests conversation projection and source notification through
real disk stores; neither proves live Gmail or frame/input performance.


## Durable Mail action projection

`tools/mail-index-tests/run.py` now retains `action-benchmark.json`: first and five
warm full-fsync-plus-index operations at 1, 20, 100 and 1,000 messages in a thread.
Every sample keeps the 100 ms component ceiling. It also checks retained intent
after an injected index failure, account isolation, refusal/retry transitions and
overlay recovery. The retained repeated-summary failure and correction are in
`.build/mail-download-20261011/action-index-{2,3}`. No component result establishes
physical frame/input acceptance, and these checks do not cover eviction or memory
pressure. The full suite remains failing while HTML preparation exceeds its budget.


The Mail engine runner also retains `import-benchmark.json`: alternating actual
20-message import transactions with arrival-boundary triggers enabled and disabled
in isolated temporary stores. Every batch keeps the 100 ms component guardrail.
The disabled-trigger control is an ablation only and is never a production mode.
Record its overhead; these first/warm samples do not cover migration, eviction,
or physical UI latency.


## Gmail read rate-limit regression — October 11

`MailReadBackoffTests` runs in the persistent Mail engine suite (minimum 234
cases). Injected label/page rate limits must appear on the account, preserve the
longest retry deadline across out-of-order responses, and block manual refresh,
paging, body/thread reads and hide/reopen bypasses. The sync worker rechecks its
deadline after sleeping in case another in-flight request extended it. Ordinary
page/label failures do not pause unrelated reader work. No real provider writes
or live account credentials are used in these tests.

Retained evidence under `.build/mail-download-20261011/`:

- `read-backoff-reference`: all four new cases fail against the preceding source.
- `read-backoff-fixed`: four cases pass, but the first correction regresses two
  reader lifecycle cases by pausing unrelated reads. This failed run is retained.
- `read-backoff-fixed-2`: all four backoff and both reader lifecycle cases pass.
  Overall 232 of 234 cases pass; HTML preparation and 500-message enumeration
  remain over their unchanged component limits.
- `read-backoff-components`: all eight unchanged component scenarios pass.
  This is Simulator component evidence; installed device review builds still
  predate this fix, and physical frame/input acceptance remains open.

This is retry correctness, not a measured rendering speedup. Project-wide quota
arbitration, persistent cooldown across process restarts and physical latency
acceptance remain separate work.


## Enumeration statement reuse — October 11

`MailReconcileIndex.apply` now uses GRDB's connection-owned prepared-statement
cache for seven fixed SQL strings inside the message loop. Bound arguments never
become cache keys. `reuseStatements: false` retains the original preparation
policy for controlled comparisons, without changing the workload or SQL semantics.
`MailReconcileIndexTests.testEnumerationStatementReuseMatchesUncachedAndSurvivesEviction`
alternates both policies on separate disk stores with identical 500-message pages,
checks all relevant durable/derived rows and continuation states, and covers first,
warm, explicit cache eviction and recovery. It runs in the persistent engine suite
(minimum 235 cases). SQLite statement memory is reported, not substituted for RSS.

`.build/mail-download-20261011/reconcile-statements/reconcile-statements.json`
retains uncached 200.79–213.25 ms versus cached 164.32–176.16 ms across those
phases. Statement storage rises from 7,952 to 54,784 bytes on the writer connection.
Parity passes. The original 500-message gate still fails at 168.78–176.46 ms;
100-message pages take 33.89–36.47 ms. Overall 233 of 235 engine cases pass, with
HTML preparation and enumeration still over budget. This is a component reduction,
not UI acceptance. Full component results are in `reconcile-statements-components`;
consult that gate before claiming a pass. No baseline was changed.


### Thread-summary statement reuse

The follow-up extends the same GRDB cache policy to eight fixed statements in
`MailIndexWriter.rebuildThread`. The persistent comparison now alternates three
policies: uncached, listing-only reuse, and listing-plus-projection reuse. Complete
database snapshots and decoded cursor state are compared after each phase. JSON
object member order is canonicalized for comparison; bootstrap timestamps are
fixed in the fixture. The first strict-string comparison's failure is retained in
`projection-statements`: its account difference was JSON key ordering, not decoded
content. No production serialization was changed to satisfy the test.

`projection-statements-2` records uncached 178.31–183.33 ms, listing-only
142.01–151.02 ms, and combined 93.46–102.14 ms. Combined statement storage is
92,672 bytes versus 54,784 listing-only and 7,952 uncached. Standard 500-message
samples are 95.60–95.80 ms, but the separate first-use sample of **102.14 ms fails**
the unchanged limit. `reconcile-statements-gate.json` preserves that failure; the
persistent comparison now explicitly asserts the budget for the current policy
after writing every sample. It does not gate the intentionally slow controls.

The engine's functional comparison passes after the oracle correction, while
HTML preparation still fails. Enumeration acceptance remains failed due to the
first-use outlier; none of these results proves UI response or frame performance.
`projection-statements-components` fails the one-day podcast traversal tail:
3.074 ms versus the unchanged 2.777 ms reference-plus-tolerance ceiling. The
other component and redraw scenarios pass. Three predeclared same-binary fresh
process repeats in `projection-podcast-repeats` record maxima of 2.396, 2.703 and
2.551 ms; they do not replace the failed full run or establish its cause. The
original first-use spike and all repeat samples remain retained. Host monitoring
found no competing developer jobs, which does not establish an idle host.
The preceding listing-only `reconcile-statements-components` passed all eight
scenarios. No baseline or budget was changed.

## Mail priority-warning investigation — October 11

The `history-windows-ui` legacy result identifies the warning in
`ScaleStressUITests.testMailRemovalReviewPagesKeepsAndPersists()`. Its activity
timestamps place it during launch, before `stress.ready` and before the review
button is tapped. `history-windows-ui/legacy-root.json` and
`removal-activities.json` retain that attribution. Earlier symbolized traces in
`removal-review-ui-3/priority-warning-symbols.txt` identify GRDB's reader-pool
semaphore; the latest run does not independently provide that full stack.

A controlled experiment gave explicit user-initiated priority to the four UI
read tasks (list, conversation, labels and removal status), leaving database QoS,
cancellation and sync/download tasks unchanged. `ui-read-priority` passes all
243 functional cases but still fails for the priority warning. The change was
reverted byte-for-byte; source variants and decision are in
`ui-read-priority-source`. No speedup or warning fix is claimed, and no baseline
was changed. The installed review apps never included this experiment.

The [upstream pool implementation](https://github.com/groue/GRDB.swift/blob/master/GRDB/Utils/Pool.swift)
still uses a semaphore for admission; a dependency upgrade alone is not an
established fix. Replacing async reads with callback wrappers must preserve
GRDB's per-operation cancellation and SQL interruption behavior. Lowering queue
priority or disabling the checker is not acceptance evidence.

The follow-up `startup-read-trace` focused UI run reproduces the warning at
08:21:28.577, the same timestamp as two overlapping initial removal-status reads.
Temporary operation-only logging identifies the background read launched by
action setup and the caller's explicit read. Logs, instrumented source and test
activities are retained; production source was restored afterward. Another build
overlapped this diagnostic run, so its durations are not performance evidence.

`testActionSetupPublishesInitialRemovalStatusBeforeReturning` then reproduces a
separate readiness defect: action setup returns with zero notices for a disk
containing one pending review. `initial-status-reference` retains that failure.
Setup now awaits its initial status read; subsequent refreshes remain asynchronous
and cancellation still propagates. `initial-status-fixed` passes all 19 live-source
tests, including the new boundary assertion. The persistent engine minimum is
237 cases. Full UI/component checks are still required, and warning removal or
performance improvement is not yet established. Installed review builds predate
this change.

Follow-up evidence: `initial-status-ui` passes all 243 functional cases but still
fails for the priority warning. `initial-status-components` passes all eight
unchanged component/redraw scenarios. Thus the readiness defect is corrected,
but the warning is not resolved and no responsiveness improvement is claimed.

### Engine measurement isolation

The engine runner now builds with `swift build --build-tests`, then measures
`swift test --skip-build`. Its host monitor receives the launched workload PID
and records that process tree separately in `workloadDeveloperProcesses`; all
unrelated developer processes remain competing workloads. The default monitor
policy used by the Simulator suite is unchanged. Eight monitor tests cover
unrelated peers, descendant ordering, unknown parents, failures and retained
records. No budget, baseline or scenario changed.

`initial-status-engine` retained the old monitor's compilation entries;
`initial-status-engine-separated` separated compilation but still counted its
own XCTest process. Those reports are not retroactively marked clean.
`initial-status-engine-owned-monitor` records 27 samples, 24 workload-process
entries, no competing developer process and no sampling error. It still fails:
235 of 237 cases pass; large HTML preparation takes 196–217 ms, and one standard
500-message enumeration sample takes 101.13 ms. A clean developer-process sample
does not prove idle hardware or physical UI acceptance. Earlier failures remain.
