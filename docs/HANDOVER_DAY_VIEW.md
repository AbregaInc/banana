# Day view incident handover

## Current status

Six regressions were reported after the 2026-08-26 Day-view interaction rewrite:

- paging left/right rendered stale event content under the new date; and
- vertical scrolling became extremely slow and had no normal inertial movement;
- returning from the background or relaunching reset Day to the top; and
- even after the first gesture fix, production startup/background work made the app and phone lag;
- horizontal paging was visibly rough and could briefly reset the visible time; and
- the latest improved build was still visibly laggy on an iPhone 15 Pro Max.

The builds installed on the owner's phone through 10:52 on 2026-08-27 were **not fixed**. The owner opened
the latest one and reported that scrolling was somewhat better but still unacceptably slow. Its own
journal proved the failure instead of relying on subjective test gestures: the new process reached
104% CPU with `WeekView×127` over 15 seconds and then 52% CPU with `WeekView×94` over the next 15
seconds. The second window is decisive: no root or already-instrumented publisher moved while
`WeekView` alone rebuilt about six times per second. Banana and its widget were then terminated on
the owner's phone. The user explicitly instructed that all further testing stay on the spare iPhone 14 Pro;
do not install, launch, or automate anything on the owner's phone without a new explicit request.

The new paging/ProMotion fixes plus the earlier store/workload isolation exist in the current
worktree and the retained optimized artifact. The Day implementation passed a 200-second
production-path run plus a five-test focused suite on the spare iPhone 14 Pro. The
build 17 has since been pushed to the owner's phone and Watch. Treat the Day bridge,
frame-rate entitlement, build
optimization, startup recompute orchestration, EventKit observer, root observation graph, narrow
Smart Schedule subscriptions, travel calculation, and feed-refresh loop as release-sensitive.

The exact current tested artifact is
`.build/retained-current/Banana.app`. It is a signed arm64 Debug
build compiled with `SWIFT_OPTIMIZATION_LEVEL=-O`, bundle `com.boris.banana`, version `1.0 (18)`,
and `CADisableMinimumFrameDurationOnPhone=true`. Install this exact app bundle if the user explicitly
asks for the next push; do not rebuild through the ordinary Debug install script, which would
silently return to `-Onone`.

Build 17 was installed and launched on the owner's iPhone and Apple Watch Ultra 2 on 2026-08-28. It
adds the Watch calendar agenda deep link and fixes the next/then complication hierarchy. The phone
binary SHA-256 is `45e9686eed9ab2921a78a45ab9341e2be522795492632f12a257fb0ea14432df`;
the embedded Watch binary SHA-256 is
`672a36d355e5e984f3a1fb7a85024db16a1854672555b9975f0a0e912886b7ef`.

Build 18 restores Day's blank-slot hold-and-drag creation using a UIKit long-press recognizer
coordinated with the native scroll pan, and removes the grouped-gray safe-area strip beneath the
collapsible bottom chrome. The long-press test passed on the spare iPhone 14 Pro, and a four-test
simulator cluster also verified vertical scrolling, blank-space day paging, and preserved time
position. Build 18 was installed and launched on the spare phone only; it has not been pushed to the owner's
phone. Its phone binary SHA-256 is
`f7116c65d91f7b3a2d6e7538bebc2e08c24372c9105aef286787558c0c13d7e7`.

## Paging and display-pipeline follow-up (2026-08-27)

The user's final device report exposed two problems not covered by the prior CPU-isolation tests:

- `DirectionalDayScrollView.updateUIView` deferred every hosted-root replacement while the vertical
  scroll view was dragging or decelerating. A horizontal page during vertical coast therefore
  changed the fixed date chrome immediately but left the old day's grid in place until deceleration
  ended. The later asynchronous offset restore could expose the top of the destination day for a
  frame. Explicit date changes now stop deceleration at the live vertical offset, discard stale
  pending content, replace the keyed host immediately, and preserve that offset synchronously.
  Unrelated data changes are still deferred until UIKit finishes scrolling.
- Both iPhone targets were missing `CADisableMinimumFrameDurationOnPhone`; the already-installed
  phone artifacts were also ordinary `-Onone` Debug builds. Production and Beta plists now opt into
  the iPhone's full display refresh range, and the exact spare-phone artifact uses optimized Swift while
  retaining DEBUG-only device fixtures and diagnostics.

New exact-position and load regressions use the actual Day UI rather than timing wrapper code:

- `.build/SpareDayExactOffsetGreen-20260827.xcresult` — forward, forward, back, back paging retains
  the same visible hour screen position within 2 points on every transition.
- `.build/SpareDayDensePerformance-20260827.xcresult` and
  `.build/SpareDaySparsePerformance-20260827.xcresult` — 60-event and sparse days both report about
  85.3 frames/second with zero hitches under XCTest, showing that dense event layout no longer adds
  measurable scroll cost. XCTest/spare phone remained display-capped, so this is not evidence of 120 Hz.
- `.build/SpareDayProMotionOptimizedFocused-20260827.xcresult` — the exact optimized artifact passes
  5/5 physical tests in 95.1 seconds: dense performance, real EventKit interaction, repeated exact
  paging, process-relaunch offset, and native vertical scrolling.
- `.build/SpareDayProMotionOptimizedSustained-20260827.xcresult` — the same artifact passes the
  200-second production graph: 12 alternating flicks, 45 seconds quiet, one minute background,
  foreground restoration, process relaunch, final settle, and four screenshots.

The current shared source also builds the `BananaMac` scheme successfully with signing disabled;
the remaining diagnostics are pre-existing dependency/concurrency warnings, not build failures.

All four optimized sustained screenshots in
`.build/spare-promotion-optimized-sustained-attachments/` were inspected at original resolution.
They contain the complete Day chrome and grid. Background return and process relaunch both retain
the approximately 3–6 AM time position instead of resetting to midnight. The matching journal is
`.build/spare-playback-promotion-optimized-20260827.log`: after gestures settled, every quiet
foreground sample was 2% CPU with no view bodies; background likewise remained at 2%, thermals were
nominal, and the only publisher warning was the bounded first five seconds of startup. Structured
events are in `.build/spare-diagnostics-promotion-optimized-20260827.ndjson`.

## Cache-first adjacent paging follow-up (2026-08-27)

After the optimized pager became fast once loaded, the user reported a remaining roughly one-second
load on a not-yet-opened day and explicitly asked for cache-first rendering with a smooth backfill.
The planning cache existed, but its key was the complete moving four-day request. Moving one day
changed that key even though three cached days still overlapped, so Day discarded usable data and
waited for EventKit/Google.

`OccurrenceStore.planningWindow` now merges overlapping persisted display windows by stable
occurrence ID when an exact window is absent. The first exact refresh entry inherits the best
overlapping local, Google, and local-extra slices; each provider keeps showing its stale slice until
that provider returns and replaces it. A failed provider therefore does not create a blank flash.
The cache remains display-only and cannot drive calendar writes, alarms, or notifications. Event-set
changes use a short SwiftUI ease-in/out insertion animation while the UIKit scroll offset remains
unchanged.

DEBUG launches can inject realistic provider latency with
`--simulate-planning-provider-delay-ms <milliseconds>`. This holds both EventKit/Reminders and
direct Google refreshes before they begin, while leaving the synchronous persisted-cache paint
untouched. The value is capped at 30 seconds; invalid values are ignored, and the switch is absent
from Release builds. The deterministic cache/backfill regression runs with a two-second delay and
asserts that fresh data is still absent after 750 ms before verifying the later insertion.

Physical spare-phone evidence from the optimized current artifact:

- `.build/SpareDayCacheBackfillRed-20260827.xcresult` — the new public-UI regression fails before
  implementation because the adjacent page exposes neither the overlapping cached event nor a
  later fresh event.
- `.build/SpareDayCacheBackfillProductionFinal-20260827.xcresult` — 4/4 green in 86.2 seconds:
  immediate adjacent cache, deliberately delayed provider backfill without blanking or Y movement,
  real EventKit paging, repeated exact-position paging, and a 60-event performance day.
- `.build/SpareDayCacheBackfillSustainedFinal-20260827.xcresult` — green in 197.8 seconds: a
  25-second startup settle, 12 alternating full-height flicks, 45 seconds quiet in the foreground,
  one minute backgrounded, foreground restoration, process relaunch, and a final 20-second settle.
- `.build/SpareDaySimulatedProviderDelay-20260827.xcresult` — the DEBUG latency switch is green on
  the spare phone with a two-second provider delay. Cache remains immediate, fresh data is absent at the
  750-ms checkpoint, and the later backfill preserves the cached event and hour-label position.
- The final dense scroll averaged 88.2 frames/second with zero hitches under XCTest's device cap.
- `.build/spare-day-cache-backfill-visual-final-attachments/` contains the inspected 1178×2556
  screenshot with complete chrome, the cached 4 AM event, the later fresh 5 AM event, and the same
  3–6 AM viewport.
- All four images in `.build/spare-day-cache-backfill-sustained-final-attachments/` were inspected
  at original resolution. The one-minute background return and full process relaunch both preserve
  the approximately 2–5 AM position with complete Day chrome and no reset to midnight.
- `.build/spare-day-simulated-provider-delay-attachments-20260827/` contains the inspected final
  delayed-backfill frame with both cached and fresh events visible in the unchanged 3–6 AM viewport.

The cache/backfill test asserts the cached event appears within 450 ms of XCTest returning from the
swipe (including accessibility polling), the fresh event arrives after a forced two-second delay,
the cached event remains throughout, and the same hour label stays within 2 points. The shared
source also rebuilds the `BananaMac` scheme successfully after this store change.

The sustained production journal is `.build/spare-playback-cache-backfill-final-20260827.log`, with
structured events in `.build/spare-diagnostics-cache-backfill-final-20260827.ndjson`. Persisted
occurrences and planning windows were available 135–211 ms after launch across the recorded
sessions, before wiring completed. Once startup and gestures settled, foreground samples were
normally 2% CPU with no view bodies. The one-minute background interval averaged 4.1% CPU because
its first transition sample reached 13.2%; every later background sample was 2%. Thermals remained
nominal, memory was approximately 32 MB, and the only publisher storm was bounded to the first five
seconds of startup.

## macOS Day parity follow-up (2026-08-27)

The Mac Day surface now uses the same data and invalidation constraints as iPhone rather than merely
sharing the event renderer:

- Day requests a four-day buffered planning window (`visible - 1 ... visible + 3`). Moving one day
  therefore has three overlapping cached days available immediately while providers backfill.
- `MacWeekView` no longer broadly observes `OccurrenceStore` or `SmartScheduleStore`. It subscribes
  only to the rendered occurrence/planning-window values plus calendar colors, commute legs, flight
  legs where needed, and week-start configuration. Action methods retain identity access to the
  installed stores without turning every transient publication into a full grid rebuild.
- The native macOS `ScrollView` remains responsible for vertical motion. Day's Y position is saved
  after scrolling becomes idle and on disappearance, then restored across navigation and relaunch.
  The deterministic audit route still starts at 7 AM so screenshots do not depend on prior local
  preferences.
- Cached-to-fresh event replacement uses the same short ease-in/out animation as iPhone without
  changing the scroll offset.

The current source builds `BananaMac` with signing disabled. Separate QA/Beta identities were used
so the installed production Mac app did not have to be quit. Deterministic captures are
`.build/mac-qa-day-20260827.png`, `.build/mac-beta-day-storm-20260827.png`, and
`.build/mac-qa-podcast-detail-20260827.png`. The calendar chrome, 7 AM–4 PM ruler, all-day rows,
commute and meeting bands, current-day header, and the podcast cog beside Play next episode were
inspected at the native 1120×840 capture size.

The Beta capture held the installed Mac Day tree open through an injected 800-publication
OccurrenceStore storm and two five-second watchdog samples. The startup-overlap sample was 17% CPU
with `MacWeekView×12`; the later sample saw another 519 occurrence publications at 103/s, 2% CPU,
and **zero** MacWeekView bodies. This is the intended narrow-observation behavior: the watchdog sees
and names the source storm without making Day rebuild for invisible store traffic. The isolated
evidence is in `~/Library/Application Support/Banana Beta/playback.log`. The desktop automation
bridge was unavailable during this pass, so the screenshots and watchdog samples are visual/render
evidence, not a claim that pointer-driven scrolling was measured automatically.

Current physical-device evidence, all on the spare iPhone 14 Pro and none on the owner's phone:

- `.build/SparePodcastSettingsAndDayParityKeychain-20260827.xcresult` — cache/backfill and podcast
  configuration placement, 2/2 green.
- `.build/SpareCurrentSourceFinal-20260827.xcresult` — exact final shared-Keychain source rerun of
  delayed cache/backfill plus the 30-second podcast preset mutation/persistence flow, 2/2 green.
- `.build/SpareDayPerformanceFocusedFinal-20260827.xcresult` — dense Day scrolling/paging, repeated
  exact-position paging, real EventKit interaction, process-relaunch restoration, and ordinary
  vertical scrolling, 5/5 green.
- `.build/SpareSustainedBackgroundFinal-20260827.xcresult` — 199.8-second production-path run with
  repeated flicks, 45 seconds quiet, one minute backgrounded, foreground restoration, process
  relaunch, and four retained screenshots; green.
- `.build/SparePodcastAutoSkipPersistenceGreen-20260827.xcresult` — selects a 30-second podcast
  pre-roll preset, dismisses the configuration sheet, reopens it, and verifies the selected value
  remains; green.
- `.build/spare-day-performance-focused-attachments-20260827/` — inspected dense, repeated-paging,
  and real-calendar captures plus the recorded interaction timings.

## Investigation outcome (2026-08-27)

The 2026-08-26 acceptance tests reached the wrong conclusion because the spare phone's calendar recompute is
about 40 ms and the tests never reproduced the owner's publication rate while a gesture was active.
The phone traces exposed three remaining amplifiers:

- iPhone `WeekView` still used `@EnvironmentObject OccurrenceStore`, so *every* transient
  `objectWillChange` invalidated and diffed the entire 24-hour grid. This was redundant because the
  view already subscribes explicitly to `$occurrences` and `$planningWindowRevision`.
- The production workload itself was still excessive: a feed sweep published once per changed
  feed, and the occurrence engine calculated network-backed travel for all 31 days even though Day,
  Week, wake planning, and travel notifications consume only the coming week. If the app
  backgrounded during one of those passes, the remaining route, write-back, notification, and alarm
  work continued with no visible calendar to serve.
- After those fixes, iOS `WeekView` still broadly observed `SmartScheduleStore`. Wake-plan,
  authorization, error, agenda, and other status publications therefore rebuilt the 24-hour grid
  even when none of its drawn inputs changed. A physical spare-phone regression that sends 120 invisible
  Smart Schedule publications failed with **128 WeekView renders**, matching the shape of the owner's
  final `WeekView×94` source-less window. Day now receives the installed store by identity without
  broad observation and explicitly subscribes only to calendar colors, commute bands, flight
  bands, and week-start changes.

A physical spare-phone regression now sends 800 `OccurrenceStore.objectWillChange` events at roughly
125/second while vertically scrolling Day and samples a lifetime render counter from an isolated
test subtree. With the broad observation restored, the test fails with **808 WeekView renders**.
With the current iOS-only narrow observation, it passes below the 20-render ceiling; calendar data
changes still flow through the two explicit publishers and actions still use the canonical shared
store. The hosted Day root is additionally replaced only when a token containing its actual drawn
content changes, and a legitimate change arriving during drag/deceleration is applied only after
UIKit finishes scrolling.

The production workload changes are intentionally bounded:

- a multi-feed refresh accumulates parsed results and assigns the catalogue once per sweep, then
  persists once; an explicit single-feed refresh remains immediate;
- the 31-day occurrence/calendar horizon remains intact, but provider-backed travel routing is
  restricted to eight days;
- an iOS occurrence pass that notices the app has backgrounded publishes its already-fetched base
  timeline, then stops before travel, write-back, or alarms and does not mark the partial pass fresh;
- Smart Schedule likewise stops between foreground-only stages and leaves a partial pass stale for
  the next foreground; and
- the render diagnostic now has a non-resetting lifetime counter, so watchdog rollups cannot erase
  a regression before XCTest reads it.

Final physical-device evidence from the exact source:

- `.build/SpareDayCalendarRenderRed-20260827.xcresult` — old observation graph fails with 808 Day
  renders during the calendar publication storm.
- `.build/SpareDayCalendarRenderGreen-20260827.xcresult` — the same storm and flick pass after
  narrow store observation.
- `.build/SpareDayFocusedCPUFinal-20260827.xcresult` — 6/6 hardware tests green in 93.4 seconds:
  publication storm, deliberately slow overlapping recomputes, native vertical scroll, distinct
  date/event paging, pinch density, and process-relaunch offset restoration.
- `.build/SpareDayProductionSustainedFinal-20260827.xcresult` — full production graph green in
  199.7 seconds: 12 alternating full-height flicks, 45 seconds quiet foreground, one minute
  background, foreground restoration, process relaunch, final settle, and four screenshots.
- `.build/SpareDaySmartIsolationFocused-20260827.xcresult` — 5/5 green in 83.1 seconds after the
  final phone trace: invisible Smart Schedule publications, occurrence publications, library
  publications, real EventKit visual/interaction paging, and process-relaunch scroll restoration.
- `.build/SpareDaySmartIsolationSustainedFinal-20260827.xcresult` — exact current source green in
  198.9 seconds with the full production graph, 12 flicks, quiet window, one-minute background,
  process relaunch, CPU/render assertions, and four retained screenshots.

The final spare-phone power journal is `.build/spare-playback-smart-isolation-final-20260827.log`. After
the brief 19%/five-second startup burst, the view went fully quiet at 2% CPU. During the 12 flicks it
recorded only `WeekView×2` per five-second sample; the following quiet window recorded no bodies at
2% CPU. Background averaged 3.9% CPU and then remained at 2% with no bodies. There was no Day/Week
storm in the final sustained session. The final journal event file is
`.build/spare-diagnostics-smart-isolation-final-20260827.ndjson`.

the spare phone's persisted power journal for that production run recorded one 42 ms occurrence recompute.
After the gesture interval it produced nine consecutive 2–4% samples with no view bodies. The
background minute averaged 3.9% CPU (14.7% max), contained one 9 ms backup, had no active work and
no rendered bodies, then stayed at 2%. The initial production burst was 19% for five seconds and
immediately settled to 2%; it did not become the sustained 60–83% workload seen on the owner's phone.

All four 1178×2556 production screenshots were inspected. The startup image shows the complete Day
chrome and time grid; the background-return image retains a roughly 4 AM offset and its Wake block.
The post-flick and post-process-relaunch captures exhibit the already-documented XCTest compositor
omission of outer SwiftUI chrome, while the UIKit grid, accessibility tree, and offset assertions
remain present. They are interaction evidence, not pixel-diff baselines.

## Investigation outcome (2026-08-26)

The hosted controller was the primary fault. `DirectionalDayScrollView.Coordinator.host` was
declared `weak`; no other object retained the `UIHostingController` after `makeUIView` returned.
The controller therefore deallocated and every later `host?.rootView = …` update silently did
nothing, leaving the first day's SwiftUI event subtree on screen while the date header changed.

The first production-isolation patch added:

- retains the hosting controller strongly and keys its root subtree with the calendar date;
- assigns occurrences to every day interval they actually intersect, including planning-window
  entries that started before the visible range;
- records the visible date plus ordered event IDs in the Day surface's accessibility value;
- tests three consecutive Day pages for distinct date/event snapshots; and
- removes the abandoned `TabView` pager and its unreachable state/gesture code.

The scrolling fault was separate. The UIKit bridge explicitly disabled `UIScrollView` scrolling
and copied each finger movement into `contentOffset` from a custom pan recognizer. That discarded
UIKit's coalesced scrolling, velocity, deceleration, and momentum. The bridge now leaves native
vertical scrolling enabled, uses a horizontal-only recognizer solely for day paging, and saves the
vertical position when dragging/deceleration ends. Pinch density uses the same simultaneous SwiftUI
magnification gesture as Week view; trying to attach a second UIKit pinch recognizer to the native
scroll view failed on hardware.

### Production CPU and scroll-position follow-up

The first spare-phone suite was not sufficient evidence for production performance. Its final route was
intentionally read-only and skipped `wireUp()`, CloudKit, feed refresh, and the production root
publisher graph. After that build was installed on the owner's iPhone 15 Pro Max, the app was still
unusable. The phone's own `playback.log` supplied the missing evidence:

- startup windows repeatedly consumed 80–133% CPU in older/current runs;
- one 15-second window recorded `WeekView×71`, `library↻×39`, `RootView×22`, and
  `PlannerTab×21`;
- the next recorded `WeekView×102`, `RootView×33`, and `PlannerTab×33`; and
- the installed first-fix build still reached 67% CPU with `WeekView×99` in a 15-second window.

The direct cause was `PodcastLibrary.refreshAllStale`: every feed toggled `isWorking` twice, a fresh
feed mutated six published fields separately, and each changed feed encoded and atomically rewrote
the entire multi-megabyte catalogue. `RootView` unnecessarily observed `PodcastLibrary`, so those
unrelated publications reconstructed the visible Day calendar. A foreground refresh also continued
after the app entered the background. Separately, the saved vertical offset lived in `@State`; the
intentional background CPU gate removes the whole view tree, so returning necessarily recreated that
state as zero.

The current worktree now:

- removes unused library/wake/health subscriptions from `RootView` and makes `PlannerTab` an
  equatable boundary, while its own `@AppStorage` and visibility changes still invalidate it;
- publishes `isWorking` once per feed sweep and replaces one complete podcast value per changed feed;
- writes the catalogue once at the end of a sweep rather than once per feed;
- stops a visible-app refresh between feeds after backgrounding, while the explicit overnight
  `BGProcessingTask` opts into completing in the background;
- does not advance the four-hour refresh stamp for an interrupted partial sweep; and
- persists `mobileDayScrollOffset` in `@AppStorage`, so background reconstruction and a process
  relaunch restore the same time.

### Calendar recompute/write-back feedback-loop follow-up

That patch still failed on the owner's phone. The fresh post-install trace proved the library boundary
worked (`PlannerTab` no longer followed `library↻`) but exposed a second, independent production
loop: `WeekView×143`, `RootView×60`, and `occurrences↻×23` in one 15-second window. The preceding
minute summarized five `recompute`, five `smartRecompute`, and five `calendarWriteBack` passes.

Two real-data timing differences made the spare phone's old 18-second test miss it:

- Day's `.task` could start the 31-day occurrence pass while `wireUp()` independently awaited Smart
  Schedule and then called `occ.recompute()`. On a large calendar the first pass was still running,
  so the second call set `recomputeAgain`; wake-plan and EventKit callbacks could keep extending the
  serial drain. Startup now joins an in-flight pass with `recomputeIfStale(maxAge: 0)`.
- `CalendarWriteBack` commits through its own `EKEventStore`; EventKit immediately notified Smart
  Schedule's reader, which waited five seconds and treated Banana's own availability write as an
  external edit. Do **not** drop a notification merely because it lands near Banana's own commit:
  EventKit does not identify the author, so a real user reschedule can arrive in that same window.
  The observer now coalesces that notification and defers it just beyond the ten-second echo
  window, guaranteeing one trailing convergence pass. Calendar/provider notifications are also
  prevented from launching the full calendar/travel/write-back cascade while the app is
  backgrounded.

Production and Beta must also keep distinct write-back ownership. Production writes `banana://`
markers and Beta writes `banana-beta://`; Beta reuses production mirrors rather than creating a
second layer. The migration drops Beta's ambiguous legacy `mirror-*` ledger claims without deleting
their EventKit events, while retaining Beta-only legacy task claims long enough to reconcile them.

The worktree additionally suppresses observable no-ops: planning-window timestamp refreshes publish
only if the rendered occurrence bytes changed, and Smart Schedule assigns agenda, plan, commute,
flight, health-note, and authorization properties only when their visible value changed.

The new sustained spare-phone production run lasted 201.9 seconds: 25-second startup settle, 12 alternating
full-height vertical flicks, 45 seconds quiet in the foreground, one full minute backgrounded,
foreground restoration, process termination/relaunch, and a final 20-second settle. Its phone-side
power trace recorded exactly one occurrence recompute (`45 ms`) in the first minute. After gestures
settled it produced nine consecutive `2% / no bodies` samples. The background minute averaged 4.0%
including a single 14 ms backup, then remained `2% / no bodies`. Background return and process
relaunch both retained the non-zero Day offset.

After adding durable pending-state for an external calendar notification received in background,
the exact final source was rerun for 197.8 seconds. It again passed. The final phone log recorded one
40 ms occurrence recompute, then quiet `2% / no bodies` foreground samples; its background minute
averaged 3.7%, included one 11 ms backup, and otherwise remained `2% / no bodies`. The pending bit is
consumed on foreground even if the ordinary 60-second staleness guard is still fresh, so performance
gating does not trade away calendar correctness.

the spare phone's real EventKit pass is only about 40 ms, so a dedicated DEBUG hardware regression now holds
each occurrence recompute open for five seconds to reproduce the overlap window from the owner's much
larger calendar. On the spare phone, native vertical scrolling remained responsive during the artificial
stall and all startup/wake/EventKit requests converged within the asserted maximum of two passes;
the old unbounded chain reached five in the owner's minute trace.

The earlier production-path spare-phone trace showed the limits of the first acceptance test. With the full
`wireUp()` graph
running, the first five seconds were a bounded launch burst at 19% CPU (`RootView×11`, `WeekView×8`,
`occurrences↻×7`, `library↻×5`, `PlannerTab×1`). The next three foreground samples were 2%, 2%, and
2%; after Home/background it sampled 4% once for backup work and then 2% with no view bodies. In
particular, library publications no longer rebuilt `PlannerTab`, and neither `PlannerTab` nor
`WeekView` rendered in the background.

That earlier physical-device run on the spare phone passed six focused tests (66.649 seconds total):

- three pages expose the correct date and distinct deterministic event snapshots;
- a horizontal swipe beginning on blank time changes day;
- a vertical flick scrolls the time grid;
- the vertical time position survives a day change;
- pinch increases hour density; and
- the read-only real-store route passes visual, vertical-performance, and adjacent-date checks.

The real-store performance attachment recorded 2.645 seconds for the full XCTest vertical action
and settle, then 2.008, 2.028, and 2.045 seconds for three day changes. Those numbers include event
synthesis, native deceleration, XCTest's wait-for-idle, and the assertion lookup; the visible scroll
itself remains native and continuous. Screenshots for today, the settled post-flick position,
tomorrow, restored today, yesterday, and the expanded pinch density were inspected at the phone's
native 1178×2556 capture resolution. Dates, hour ruler, event bands, current-time line, and retained
vertical position were visually correct.

The full-screen XCTest attachment taken after the vertical flick intermittently omits some outer
SwiftUI text and even pieces of the iOS status bar, including after a two-second settle. That is an
XCTest screenshot compositor artifact rather than an app state change: the grid/event layers are
present, the accessibility tree remains intact, and the immediately following full-screen day
captures render all chrome normally. Do not use that single attachment as a pixel-diff baseline.

Result bundles:

- `.build/SpareDayCombinedFinal-20260826.xcresult` — all six tests, green;
- `.build/SpareDayVisualFinal-20260826.xcresult` — final real-store and pinch screenshot pass, green.
- `.build/SpareDayCPUFix-20260826.xcresult` — five hardware tests, including relaunch persistence
  and a 20-publications/second library storm, green;
- `.build/SpareDayProductionCPUFix-20260826.xcresult` — full production startup, vertical scroll,
  Home/background, restored offset, screenshots, and persisted CPU trace, green.
- `.build/SpareDayProductionFinal-20260826.xcresult` — source-identical final rerun after the feed
  reentrancy guard; same full production/background test, green. This is the earlier run whose signed
  app bundle was installed on the owner's phone and then proved insufficient.
- `.build/SpareDaySustainedCalendarLoopFix-20260826.xcresult` — new 201.9-second full production
  sustained-scroll, quiet-idle, one-minute-background, foreground-return, and relaunch run; green.
- `.build/SpareDaySustainedCalendarLoopFinal-20260826.xcresult` — exact-final-source 197.8-second
  rerun after preserving background calendar invalidations; green with the same clean power shape.
- `.build/SpareDayPostLoopFull-20260826.xcresult` — eight post-fix spare-phone hardware tests covering
  paging data, blank-space paging, vertical scroll, paging offset retention, pinch, process relaunch,
  library publisher isolation, and real-calendar visual/interaction behavior; 8/8 green in 95.2 s.
- `.build/SpareDaySlowCalendarOverlap-20260826.xcresult` — debug-only five-second-per-pass large-
  calendar timing simulation; vertical scrolling responsive and recompute drain bounded; green.

The first attempt at a real-data UI test launched the full production startup path. XCTest's default
interruption handler selected **Don't Allow** for Banana location access, **Allow** for Local Network,
and **Start fresh** on the one-time iCloud restore offer. No calendar event, local library, or cloud
backup was deleted: `Start fresh` only dismissed the pending offer and records that it has been
shown; Settings can still request a restore explicitly. The final `--day-real-calendar` route avoids
all of those services and is read-only: it fetches the visible planning window but skips full
recompute/write-back, weather/location startup, CloudKit restore UI, notifications, and fixtures.

## Do not touch without explicit approval

- the owner's phone device ID: `<device-id>`
- The user explicitly instructed all continuing tests to remain on the spare iPhone 14 Pro. Ask again
  before any install, launch, or automated test on the owner's phone.
- the spare iPhone 14 Pro is available for hardware checks: `<device-id>` (Xcode destination `<device-udid>`).

## Scope of the bad change

The gesture/date implementation is in [WeekView.swift](../Banana/Views/WeekView.swift):

- `DirectionalDayScrollView` at approximately line 1723: new `UIViewRepresentable` used only for Day mode.
- Day-mode branch of `mobileWeekCalendarGrid` at approximately line 2353.
- Calendar-day construction in `rebuildMobileCalendar` at approximately line 2806.
- Day navigation in `moveMobileWeek` at approximately line 2836.

The view hosts a SwiftUI `mobileDayColumn(currentDay, ...)` inside a `UIHostingController`. It was
added to avoid SwiftUI nested-scroll gesture conflicts. The `UIScrollView` now owns native vertical
movement; one axis-gated pan recognizes horizontal day paging, and a simultaneous magnification
gesture handles hour density.

The production performance fault crosses these additional files:

- [RootView.swift](../Banana/Views/RootView.swift): root subscriptions, background tree gate, and
  the equatable `PlannerTab` boundary;
- [PodcastLibrary.swift](../Banana/Model/PodcastLibrary.swift): feed publication and persistence
  batching plus visible/background sweep behavior;
- [DownloadManager.swift](../Banana/Model/DownloadManager.swift) and
  [OvernightRefresh.swift](../Banana/Model/OvernightRefresh.swift): explicit permission for the
  scheduled overnight sweep to continue in background; and
- [BananaApp.swift](../Banana/BananaApp.swift), [OccurrenceStore.swift](../Banana/Model/OccurrenceStore.swift),
  [SmartScheduleStore.swift](../Banana/Model/SmartScheduleStore.swift), and
  [CalendarWriteBack.swift](../Banana/Model/CalendarWriteBack.swift): startup recompute joining,
  visible-value publication, background calendar gating, and self-authored EventKit echo suppression;
  and
- [PerfWatchdog.swift](../Banana/Model/PerfWatchdog.swift): the persisted CPU/render evidence.

## Fault lines to protect

Do not assume the gesture layer is innocent simply because its touch tests pass.

1. `DirectionalDayScrollView.updateUIView` must replace the strongly retained host root with content
   whose identity includes `resetToken` (the calendar date). An explicit page change must not wait
   for vertical deceleration or restore the offset on a later run-loop turn: stop at the live Y,
   replace immediately, and apply that same Y synchronously.
2. Do not disable native `UIScrollView` scrolling or restore per-frame SwiftUI state publication.
   The custom pan recognizer must remain horizontal-only.
3. `currentDay` remains `calendarDays.first(where: { $0.id == 1 })`; its surface accessibility
   value is the date plus ordered occurrence IDs and is the paging data-correctness oracle.
4. Day membership must use interval intersection through `DayColumn.occurrences`, not start-date
   equality, so cross-midnight and longer events are clipped into every day they intersect.
5. Planning-window refreshes must remain serialized; a stale fetch must not overwrite a newly paged
   range or cause a refresh/rebuild loop.
6. Do not re-add `PodcastLibrary` as an observed property on `RootView`, and keep `PlannerTab`'s
   equatable boundary. The production trace must continue to show library publications without
   matching Planner/Week rebuilds.
7. A foreground feed sweep must publish working state once, apply all changed podcasts in one
   catalogue assignment, save once, and stop between feeds after background. Only `OvernightRefresh` may pass
   `allowBackgroundExecution: true`.
8. Day scroll offset must remain durable state; backgrounding intentionally destroys the view tree.
9. `wireUp()` must join an occurrence pass already started by Day/Week; do not restore the direct
   launch-time `occ.recompute()` that marks the current drain for another complete horizon pass.
10. Never discard `.EKEventStoreChanged` based on proximity to Banana's own commit. EventKit does
    not expose the author, so defer and coalesce it beyond the echo window; a user reschedule in
    that window must still trigger one trailing reconciliation pass.
11. Planning-window timestamps and equal Smart Schedule values are not UI changes. Preserve the
    rendered-byte/value comparisons so quiet calendar refreshes do not rebuild `WeekView`.
12. Keep `testMobileDaySlowCalendarRecomputeDoesNotChainOrBlockScrolling`; the spare phone's naturally fast
    calendar cannot protect this race without the artificial five-second pass.
13. Do not restore broad `OccurrenceStore` observation on iOS `WeekView`. Its rendered calendar
    inputs are the explicit `$occurrences` and `$planningWindowRevision` subscriptions; transient
    store publications must not invalidate the full grid.
14. Do not widen foreground travel calculation back to the 31-day materialization horizon. The
    full timeline remains monthly; network-backed travel is an eight-day product window.
15. Do not restore broad `SmartScheduleStore` observation on iOS `WeekView`. Action methods use the
    identity-injected installed store; only calendar colors, commute legs, flight legs, and the
    configured week start explicitly invalidate the calendar.
16. Keep `CADisableMinimumFrameDurationOnPhone=true` in both Banana iPhone plists and test an
    optimized artifact on hardware. Ordinary `-Onone` Debug installs are not performance evidence.
17. Travel availability is door-to-door. A final physical appointment needs a return-home block
    beginning at its end, even when a virtual meeting begins then. If the reverse MapKit request
    fails after outbound routing succeeded, retain the matching outbound duration as the bounded
    fallback; never reopen availability merely because that second request failed.

## If the regression returns

1. Reproduce on the spare phone with both deterministic `--ui-audit` data and the read-only
   `--day-real-calendar` route. Preserve the date plus ordered event IDs for three consecutive days.
2. If `calendarDays` is correct but the visual output is wrong, remove the `UIHostingController` bridge and use a single purpose-built UIKit view or a correctly keyed host controller. Do not keep patching the current bridge with additional SwiftUI gestures.
3. If `calendarDays` is wrong, fix the data window/rebuild ownership first. The view must receive `DayData` as a value whose identity includes the date (for example, use `Occurrence.dayKey(currentDay.date)` as an explicit host identity).
4. Preserve requirements that were requested before the regression:
   - vertical time position survives Day paging;
   - pinch changes hour density;
   - an empty-time horizontal swipe pages Day;
   - vertical movement is continuous and performant;
   - no grey transition artifact or blank delayed page.

## Automated checks

[VerifyTimelineUITest.swift](../BananaUITests/VerifyTimelineUITest.swift) contains these Day checks:

- `testMobileDayPagesWhenSwipeStartsOnBlankTime`
- `testMobileDayTimeGridStillScrollsVertically`
- `testMobileDayPagingPreservesTimePosition`
- `testMobileDayPagesRenderDifferentDatesAndEventIDs`
- `testMobileDayPinchZoomStillChangesHourDensity`
- `testMobileDayRealCalendarVisualAndInteractionPerformance`
- `testMobileDayScrollPositionSurvivesProcessRelaunch`
- `testMobileDayStaysResponsiveDuringUnrelatedLibraryPublishStorm`
- `testMobileDayScrollStaysResponsiveDuringCalendarPublicationStorm`
- `testMobileDayIgnoresInvisibleSmartSchedulePublications`
- `testMobileDaySlowCalendarRecomputeDoesNotChainOrBlockScrolling`
- `testMobileDayProductionStartupBackgroundAndVisualPerformance`
- `testMobileDayProductionSustainedScrollingBackgroundAndRelaunch`
- `testMobileDayRepeatedPagingPreservesExactTimePosition`
- `testMobileDayDenseCalendarScrollAndPagingPerformance`
- `testMobileDaySparseCalendarScrollPerformanceBaseline`
- `testMobileDayAdjacentPageUsesCacheThenBackfillsWithoutJumping`

The deterministic routes remain side-effect-free. The real-calendar route is isolated and read-only.
The production test deliberately starts the full app graph on the spare phone, records 5-second CPU/render
samples, scrolls, presses Home, waits in background, activates the app, verifies the saved position,
and keeps before/after screenshots. The publication regressions inject library, occurrence, and
Smart Schedule traffic without network or account access and assert that the Day render count stays
bounded while a native flick lands.

The owner's phone **was** used in the incident response: the first tested build was installed after
explicit approval, its production journal was copied read-only after the continued-lag report, and
the Banana app plus widget were terminated to stop the phone-wide lag. Do not repeat the outdated
claim that the owner's phone was untouched.

## Build/install commands used

Hardware test on the spare phone:

```sh
xcodebuild -project Banana.xcodeproj -scheme Banana \
  -destination 'id=<device-udid>' \
  -derivedDataPath .build/day-view-spare-review \
  -resultBundlePath .build/SpareDayCombinedFinal-20260826.xcresult \
  -parallel-testing-enabled NO \
  -only-testing:BananaUITests/VerifyTimelineUITest/testMobileDayPagesRenderDifferentDatesAndEventIDs \
  -only-testing:BananaUITests/VerifyTimelineUITest/testMobileDayPagesWhenSwipeStartsOnBlankTime \
  -only-testing:BananaUITests/VerifyTimelineUITest/testMobileDayPagingPreservesTimePosition \
  -only-testing:BananaUITests/VerifyTimelineUITest/testMobileDayPinchZoomStillChangesHourDensity \
  -only-testing:BananaUITests/VerifyTimelineUITest/testMobileDayRealCalendarVisualAndInteractionPerformance \
  -only-testing:BananaUITests/VerifyTimelineUITest/testMobileDayTimeGridStillScrollsVertically test
```

The installed artifact was verified with `codesign --verify --deep --strict` and came from:

```text
~/Library/Developer/Xcode/DerivedData/Banana-gsqsznvqqxkdpidvcaqcortxvski/Build/Products/Debug-iphoneos/Banana.app
```

Do not assume that mutable DerivedData path still contains the tested binary after any later build.
Do not run another install on the owner's phone without asking first, and never use the obsolete
`.build/day-pager-owner` artifact.

The current optimized/ProMotion/cache-backfill spare-phone artifact was built and tested from this path:

```text
.build/retained-current/Banana.app
```

Build 17 was installed on the owner's phone and Watch on 2026-08-28; retained build 18 was tested and
installed on the spare phone only on 2026-08-29. Its command-line optimization override is part of the
artifact provenance; rebuilding the Debug scheme without
`SWIFT_OPTIMIZATION_LEVEL=-O` does not produce the same binary.

## Worktree warning

The repository has a very large pre-existing dirty worktree across calendar, sync, workouts,
podcasts, watch, assets, and release files. Do not reset, checkout, or broadly revert it. Restrict
follow-up to the files named in this handover. The phone journal proved the data source and root
observation graph were part of the fault, so the older instruction to restrict all fixes to
`WeekView.swift` is no longer valid.
