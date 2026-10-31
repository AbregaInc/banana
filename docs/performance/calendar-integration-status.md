# Calendar integration status — October 10, 2026

Native Day and Week viewports are enabled by default in source for Mac, iPad and
iPhone. Full Calendar integration is **not complete**, and physical frame/input
acceptance is still open. “Ready for user testing” requires working review builds
and functional verification on **all three device families**, without renderer
opt-ins. A Mac-only preview or Simulator-only pass does not fulfill that scope.
Mail must meet the same all-device readiness standard after Calendar integration.
The standalone Metal/Skia benchmarks are not the production Calendar renderer.

The user's comparison build is the non-Beta app. Beta must exercise the replacement
by default, without a user-facing legacy switch or silent rendering fallback.
Google Calendar remains the provider; do not re-enable the Apple Calendar provider.
Beta now selects the custom Core Text / Core Graphics event backend by default.
**Latest delivery: build 55 is installed on Mac, spare iPhone and iPad**, including oversized direct
drawing, the VoiceOver routing repair and explicit unsupported-preview failure.
Normal launch, cached Google events in Day/Week, picker switching, keyboard paging,
matching event detail and the sample Mail UI were checked through CUA. The Mac is
left on Calendar. Each physical mobile device passed two normal-launch/navigation
tests with zero skips. Both show the Google Calendar Connect prompt and zero
prepared/direct event images: populated mobile event rendering, real-account
workflows and performance remain unverified. Track exact build identities and device status in
`.build/calendar-integrated-review-20261010/readiness.json`. Performance acceptance
and the persistent suite after these changes remain open.

The iOS build returned exit 0 but emitted an inconsistent SwiftCompile diagnostic
(`failed with exit code 0`). Signing verification and both installations passed;
an unchanged incremental build returned 0 with an empty log and the identical
binary SHA-256. Both logs remain in the delivery directory. The binary contains
the new preparation-identity symbols. This diagnostic is not silently discarded.

Previous signed Release build 54 was installed on Mac, spare iPhone and iPad; identities and
results are in `.build/calendar-native-event-redaction-20261010/readiness.json`.
Mac cached Google events were visibly checked in Day/Week, including scrolling,
paging and matching event detail. Spare iPhone launch/relaunch and navigation passed
two tests with zero skips, but all event-image counts were zero. iPad remains locked
and unverified. This is not the standalone Metal tile renderer. Non-event cues,
populated mobile checks and off-main preparation remain open; do not call integration
complete. The VoiceOver reference route has since been removed in source, retaining
the existing action-bearing cell's accessibility semantics. Its 291 preparation
checks pass, but a new installed build and real accessibility checks remain pending.
The completed persistent suite fails on 90-day Notes/Podcast query tails (222–281 ms)
and flags first-case host contention; raw results are in the same directory's
`components` folder. It is the unchanged standard non-Beta component configuration,
not a custom-renderer frame test. No physical frame/input acceptance is established.

A wide two-hour event also exceeds the existing 2 MiB image guard; the tiled
candidate's unresolved stroke differences are retained in
[the large-event investigation](scale-results/calendar-large-event-20261010/README.md).
Source now routes oversized blocks through the same custom drawing engine on a
Canvas, preserving the image-cache guard. It is not yet installed or accepted:
its strict pixel comparisons, live interaction and backing-store measurements
remain open. The 291 preparation checks pass after the route was added.

A subsequent source-only correctness repair lets unsupported explicit symbol
styles finish with an unavailable-preview state instead of keeping Beta's spinner
indefinitely. Switching between supported and unsupported styles changes the
preparation task identity, and unsupported styles cannot reuse a prepared image
or silently enter direct drawing. The event's parent action remains available.
The final preparation runner passes 295 lifecycle checks, including rejection,
queue drain and supported-style recovery; evidence is in
`.build/calendar-unsupported-preview-20261010`. This repair is not in the normal
installed builds or the isolated oversized-event review binary. Live visual
validation and the persistent suite after this repair remain pending; collected
component timings on this heavily contended host are not a speedup claim.

## Current delivery priority — October 10, afternoon

The user explicitly prioritized full integration and usable builds across Mac,
iPad and spare iPhone over further performance work, with a review requested in
about an hour. New density/reuse experiments are deferred. Finish any already
running check without starting another benchmark matrix. Performance targets and
known failures remain unchanged; functional review readiness is a separate gate.

Build normal Release Beta apps that launch from their icons and use native Day
and Week by default. Verify install/relaunch, tab and Calendar mode switching,
event opening and authoring, and adaptive layout on each test-device family.
Never substitute the command-line-only stress app for a normal review build.
Mail's Beta UI currently labels itself as sample mail; connected Gmail remains
unfinished and must be disclosed. Retain build/signing/install/smoke evidence in
`.build/integration-review-20261010` and update the device checklist there.

## All-device completion gate

Track Mac, physical iPad and the spare physical iPhone separately. Each needs an
identified installable build, default Day/Week routing without launch flags, and
verified scrolling, paging, event opening, creation/editing, moves, durable failure
recovery, live updates and accessibility. Check Mac window resizing, iPad rotation
and split-screen resizing, and iPhone rotation where supported. Verify production
data access as well as varied multi-calendar stress data; fixture-only behavior
does not establish production integration.

For each device, retain the build identity, workload, test results, outstanding
failures and frame/input measurements. A missing or disconnected device remains
unverified. Simulator results supplement this record but cannot replace physical
device acceptance. Report functional user-test readiness separately from meeting
the performance contract; neither status is complete across devices until every
required device has the corresponding evidence. Apply this same gate to Mail.

Physical-device preflight on October 10 now confirms both the spare iPhone 14 Pro
and iPad Pro 12.9-inch are connected, with Developer Mode enabled and development
services available (`slot-menu/physical-device-readiness.json`). This supersedes
the earlier disconnected-iPad observation, but establishes no app acceptance.
The previously tested stress binary excludes physical devices at compile time.
The new `STRESS_DEVICE_AUDIT` source path includes the fixture loader and badge, writable initial mode,
isolated AppSupport directory, Mail fixture source, note-cloud exclusion,
podcast/occurrence injection and Google mutation rejection together. It requires
the separate `com.boris.banana.stressreview` identity and guarded launch arguments;
ordinary builds are unchanged. The launch-policy matrix passes 21 checks in each
of two configurations and rejects a review build lacking DEBUG. Results are in
`.build/physical-stress-policy-run`; calendar-core CI now runs them. Full physical
compilation is underway in `.build/physical-stress-review-20261010/compile`.
Signing, installation, device interaction and data-isolation verification remain
pending. Never target the main phone.

### Physical review follow-up

The initial physical compile passed. Startup inspection then found unconditional
Watch/background-service registration in `BananaApp.init` and push/trip-learning
startup in `AppDelegate`. The dedicated review mode now excludes those calls;
ordinary builds retain them. `startup-guard-build` compiled successfully, and the
review app was signed with an existing profile covering both test devices and
verified with `codesign --verify --deep --strict`. The isolated copy also removes
URL scheme registrations and background modes. Both device installs succeeded.

The spare iPhone launched and its retained `spare-scale-stress.json` confirms
180,000 emails, 36,500 events, 5,000 notes and 20,000 episodes, with 560.81 MiB peak
RSS. The collector **failed** `calendar.visibleWeek`: maximum/p95 16.685 ms against
its unchanged 16 ms component budget. Other component checks passed. This is one
physical component run, not a frame/input acceptance result or a supported-density
limit. Investigate the cold query and repeat matched measurements before claiming
an improvement. The iPad launch was denied because the device was locked; its
functional and performance evidence remains missing.

Artifacts are under `.build/physical-stress-review-20261010`. The first phone
launch command failed argument parsing before app launch; the corrected command
uses `--` to separate app arguments and is retained separately. A standalone
physical XCTest runner is being built from the existing `ScaleStressUITests`,
explicitly targeting only `com.boris.banana.stressreview`. Its first build failed
because an Xcode-managed profile cannot be selected with manual signing; the
automatic-signing retry retains that failure. The physical Day scrolling/event-opening
case passed. Week failed because the selected Saturday's day-list button was
outside the phone viewport (x=718 on a 393-point screen), with Monday–Wednesday
shown instead. A focused initial-selected-day regression fails on the unchanged
app as well. Retained bundles: `spare-calendar-ui/ui.xcresult` and
`spare-initial-week-before/ui.xcresult`. This is a functional startup-positioning
failure, not evidence of frame or input latency. The diagnostic trace in `column-diagnostic-value/attachments` shows
`selected=4;requested=4` with a 393-point viewport and 869-point content, but
actual `x=0`. Selection reached the coordinator; the collection did not retain
the applied offset. A candidate moved native selection application after
`UICollectionView.layoutSubviews`, keeping the existing geometry/selection
change guard. It still failed the same physical startup regression; artifacts
are retained under `column-layout-fix`. That unsuccessful behavior change was
removed. `column-transition-diagnostic` reproduced and isolated the cause:
selection sets x=476 at content width 869, then the deferred creation callback
sets content width 36 (the gutter-only week captured before data loaded), which
clamps x to zero. `current-width-fix` uses the coordinator's current week width
in that callback. Its physical startup regression passes: x stays at 476 and
11 cells are visible. Day and Week scrolling/event-opening also pass (38.129 and
49.392 seconds are XCTest case durations, not interaction latency). Rotation
fails at the viewport-width change expectation, before the column alignment
check. The retained pre-fix binary also fails rotation in
`rotation-before-control`, but at the later visible-cell assertion; this does
not explain or establish the cause of the corrected build's resize timeout.
The corrected app was restored. `rotation-state-diagnostic` then passes on that
same corrected app with test-only orientation/viewport attachments: portrait
width 393/x357, landscape width 734/x0, portrait width 393/x357, all with visible
cells and a synchronized gutter. Keep the original intermittent resize timeout
open; a later pass does not erase it. The full persistent component suite completed under
`current-width-components` and failed (exit 1): 30-day Notes/podcast baseline
tails, 90-day Notes/podcast baseline and absolute budgets, and the Notes query
in the redraw scenario. The 90-day maxima were 158.593 ms Notes search,
213.234 ms podcast next-across-catalog and 256.868 ms download candidates;
all three maxima were first samples. Warm samples remained roughly 45, 47–57
and 57–62 ms respectively. All four watched redraw probes recorded zero root
redraws; Calendar component budgets passed. Host monitoring detected no competing
developer jobs/sampling errors, but recorded load averages around 490 during the
90-day scenario, so this is not quiet-host evidence or an established cause.
Do not attribute these failures to the width fix or dismiss them as noise without
controlled evidence. The test Simulator was shut down after completion.
No speedup or complete device acceptance is claimed. The DEBUG-only
bounded transition trace is enabled only with `--calendar-viewport-audit`. The user asked to continue on the spare iPhone while the iPad is locked;
iPad acceptance remains pending.

### Spare-phone interaction coverage after the width fix

`calendar-interaction-coverage/ui.xcresult` under the physical review artifact
root passes all four additional cases with zero skips: varied native Day
scroll/open/next-day, native Week column paging/pinch/week navigation, and native
Day/Week move recovery. Recovery checks a failed provider write, restored event
geometry, durable operation identity after relaunch, and a rejected retry that
remains recoverable. These use the isolated fixture provider; successful live
provider writes, creation/editing/recurrence and production sync remain open.
The varied cases explicitly verify 36,500 retained events, 12 installed calendars,
365 distinct daily patterns and (Day case) 52 distinct weekly patterns. Simulator
assertions retain their original 3,000 events/30 days/4 weeks; no workload was
reduced to obtain these passes. The installed app binary SHA is
`308679152979d5e34efe1c4cfe1a0b608658bd39f12a8f3f17ab4a9839d9704e`.
These are functional tests, not physical frame/input acceptance.

`calendar-create-coverage/ui.xcresult` additionally passes Day and Week blank-slot
creation gestures on the spare phone. These retain the full fixture dataset and
navigate to a preceding day/week; an explicit zero-descriptor check verifies the
chosen slots are empty. Both open the event authoring form; Week also verifies
typed draft content. Neither saves a provider event. Successful editing cannot
be inferred: the isolated fixture service deliberately rejects event-detail
fetches, so connected/provider-backed edit and recurrence checks remain open.

The original physical scroll metrics were exported to
`current-width-fix/interaction-metrics.json`: Day reports about 83.6–84.6 fps and
Week about 81.7–82.3 fps, while both report zero counted frames and zero hitches.
These internally incomplete aggregates do not prove 120 Hz delivery or zero
missed frames. The first bounded full-app Instruments attempt in `integrated-week-trace`
failed to attach by device UDID (exit 21), despite `devicectl` confirming the PID.
The same PID attached using `Spar<redacted> (27.0.1)` from the Instruments device list.
That three-second `name-attach-probe` captured integrated Week scrolling with the
36,500-event varied workload. The report has 266 app updates: p95 6.373 ms,
max 10.650 ms, two over 8.3 ms. Associated render intervals have p95 11.460 ms,
max 15.614 ms and 67 over 8.3 ms; they include waits/overlapping work and are not
proven CPU execution. GPU p95 is 3.900 ms, max 4.819 ms. The conservative measured
work gate fails despite zero hitch rows. Display cadence varies; pipeline frame
lifetimes must not be treated as single-frame work or input latency.
The longer `integrated-week-portrait-trace` completed with explicit portrait
validation (one UI test passed, zero skips). Its eight-second requested recording
reports 730 app updates: p95 7.165 ms, p99 10.059 ms, max 11.232 ms, 18 over 8.3 ms.
The 727 associated render intervals have p95 9.226 ms, max 16.363 ms and 81 over
8.3 ms. GPU p95 is 3.899 ms, max 5.306 ms. Instruments recorded five app hitch rows;
the measured-work gate fails (exit 1). Keep pipeline lifetimes (up to 50 ms) and
variable display cadence separate from single-frame work and input latency.
This is a full-app default-renderer baseline, not an optimization comparison.
The next comparison must hold workload, portrait viewport, gestures and capture
policy fixed and investigate both app-update tails and associated compositor
intervals. GPU timings alone do not identify the cause of the render intervals.
These remain partial traces, not input-to-visible acceptance.
The persistent runner is `tools/physical-stress-tests/profile-scroll.py`; it now
requires the Instruments name/version and verifies its listing matches the
explicitly authorized device UDID before starting the test.

### Integrated Week CPU investigation

`integrated-week-cpu-trace` records the same portrait/full-workload scroll case
with Time Profiler. Recording and its one physical test completed successfully.
The matching app/dSYM UUID is `B81FFECE-BC74-3325-9609-7566F6040F45`; raw and
symbolicated traces are retained. `trace/summarize-cpu.py` reproduces
`cpu-summary-v2.json` from the exported `time-profile.xml` (PID 13538).
It finds 2,011 weighted samples, 1,913 on the main thread. Inclusive main-thread
categories include 897 ms layout, 646 ms hosting and 749 ms accessibility;
they overlap. Cell configuration/reuse setter stacks account for only 3 ms by
the stated name filter, while the app's full cell configuration function appears
in 53 ms of samples. Accessibility queries from XCTest are a potential measurement
influence; this trace does not establish which stacks caused the earlier hitches.

A bounded DEBUG-only `--calendar-preserve-cell-host` ablation leaves the current
hosting configuration in place during reuse, allowing UIKit to update compatible
content views. Apple's UIKit SDK `UICollectionViewCell.h` explicitly documents
that setting the configuration to nil replaces the content view; the
[content-view compatibility contract](https://developer.apple.com/documentation/uikit/uicontentview-5fh3z/supports(_:))
also permits updating compatible configurations. This is a native UIKit reuse
experiment, not a new renderer. Default/release behavior remains unchanged pending
matched frame, memory, lifecycle and interaction evidence. The experimental build and updated physical runner compiled successfully in
`cell-host-ablation-build`, and the signed review app was installed on the spare
phone. `cell-host-ablation-matrix` ran clear–preserve–preserve–clear on the
same binary, portrait viewport and 36,500-event varied fixture. Each test retains
initial viewport/10 AM label geometry to detect changing starting positions.
Additional preserved-host Day/Week scroll/open cases have been added to carry the
existing XCTest memory measurements and event-identity checks; those checks remain
pending after the trace matrix. No production default has been changed. `profile-scroll.py --cell-host-policy clear|preserve` selects
the cases explicitly, and `--template 'Time Profiler'` retains a CPU trace instead
of applying the Hitches interval gate. No reuse speedup is claimed.

### Physical cell-host comparison completed

The four clear–preserve–preserve–clear runs in
`.build/physical-stress-review-20261010/cell-host-ablation-matrix` completed.
`comparison.json` verifies identical binary, device, mode, fixture metadata and
initial viewport geometry. All four captures and interaction tests succeeded;
**all four measured interval gates failed**.

| Policy / run | App-update p95 (ms) | Maximum (ms) | Updates over 8.3 ms / samples | Hitches |
| --- | ---: | ---: | ---: | ---: |
| Clear 1 | 6.527458 | 24.690083 | 9 / 755 | 3 |
| Preserve 2 | 6.678208 | 10.210625 | 10 / 741 | 3 |
| Preserve 3 | 6.698083 | 10.024750 | 10 / 710 | 2 |
| Clear 4 | 6.952875 | 13.232958 | 21 / 867 | 7 |

The candidate has lower observed maxima, but its p95 falls within the control
range; render-interval p95 and hitch counts are also mixed. Two trials per policy
and unequal samples do not establish a repeatable improvement or causality.
**Do not adopt it or reduce the baseline on this evidence.** The DEBUG experiment
remains off by default. Memory and exact event-opening checks completed in
`cell-host-memory-and-identity`: four passed, zero failures/skips/runtime warnings.
Physical peak samples were 435,391–436,062 kB for default Day versus
434,146–438,618 kB for preserved Day; default Week 438,307–439,487 kB versus
437,865–438,897 kB preserved. These are single-case, three-iteration observations,
not a calibrated memory improvement or acceptance budget. Cold/eviction and full
lifecycle evidence remain missing. Input-to-visible latency is still unmeasured. All raw failures remain.

A separate native capability to evaluate after the current ablation is UIKit cell
prefetching. The current `CalendarDayCollectionView` explicitly disables it.
Apple's [collection-view documentation](https://developer.apple.com/documentation/uikit/uicollectionview/isprefetchingenabled)
and [WWDC session](https://developer.apple.com/videos/play/wwdc2021/10252/) describe
preparing cells ahead of display, distinct from asynchronous data prefetching.
This could move hosting work ahead of a visible frame, but it is only a hypothesis:
measure unchanged workloads, memory bounds, reverse scrolling and invalidation
before enabling it. No prefetch implementation change has been made in this run.

Cleanup for the completed component run shut down the dedicated Simulator and
removed five successful temporary fixture directories (511,189,212 logical
bytes). The three failed-scenario datasets were moved to
`current-width-components/failed-fixtures` for diagnosis. All raw results, failed
runs, builds and workspaces remain; `fixture-cleanup.json` records the paths.

| Path | Current integration | Remaining work |
| --- | --- | --- |
| iPhone/iPad Day | Native collection view owns scrolling and recycles visible event cells. Native local drag feedback, shared geometry and durable move recovery are integrated. | Dense-lane reachability, real-device frame/input traces, concurrent updates and eviction acceptance. |
| iPhone/iPad Week | Native two-axis collection viewport is now the iOS production/DEBUG default in source; only DEBUG `--calendar-reference-week` selects the old host. Frozen gutter, synchronized header, column paging, pinch and searchable day-item lists are integrated. | Seven iPhone default/reference checks plus Week recovery passed; seven iPad default-path checks passed, all with zero skips/warnings. Finish iPad split resizing, creation/move and lifecycle parity, then validate all devices. |
| Agenda | Shared clipped day geometry and accessibility grouping. | Integrate bounded viewport reuse; keep the elapsed-time DST policy distinct from Day/Week's wall-clock ruler. |
| macOS Day/Week | Native AppKit collection viewport connected by default in source; DEBUG `--calendar-reference-mac` retains the old host. Existing actions, background creation and overflow remain wired. | Eight native default-path action checks passed with zero skips/warnings. First-launch window availability remains unresolved. The same-binary R/N/N/R comparison fails: native commit p95 203–214 ms versus reference 127–133 ms. Resize/live-update coverage and physical input/display acceptance remain open. |
| Prepared artwork | Opt-in production-data adapter; lifecycle/pixel and functional checks exist. | Close parity/device gaps before default adoption. |
| Snapshot lane reuse | Opt-in; prepared snapshot DST filter corrected. | A verified app-level benefit is still required before default adoption. |

For Week, reuse the current `CalendarDayCollectionView` implementation and native
UIKit facilities instead of importing a fixture renderer. Apple documents region-
based attributes and bounds invalidation in [custom collection layouts](https://developer.apple.com/documentation/uikit/customizing-collection-view-layouts),
and column snapping can use [target content offsets](https://developer.apple.com/documentation/uikit/uicollectionviewlayout/targetcontentoffset(forproposedcontentoffset:withscrollingvelocity:)).
The [native Week comparison](scale-results/calendar-native-week-20261010/README.md) shows lower Simulator process memory, but no demonstrated scrolling speedup. Overnight
occurrences need distinct per-day cell identity while retaining their provider
identity for actions. Header/gutter movement must not publish a full parent redraw
on every scroll tick.

Every native adoption needs matched default/candidate measurements, complete event
reachability, selection identity, scrolling/paging, pinch, creation, recurring and
overnight moves, durable failures, live snapshot replacement, accessibility,
rotation/split resizing and cold/warm/evicted behavior. Keep the unchanged standard
component suite and supplement it with varied calendars/density searches. Do not
reduce visible density without an explicit, tested way to reach every event.

Mail follows Calendar. Its existing iOS collection view and Mac table view already
recycle cells. Audit retained row/display dictionaries and the 2,000-row list cap;
use bounded disk paging, then profile text/configuration and snapshot updates.
Selection, keyboard/VoiceOver, unread state and durable offline actions remain
acceptance requirements. No Mail optimization is claimed by this status document.

## Mac integration boundary

The current `MacWeekView.timeGrid` builds each full-height day column and all its
visible-lane event views inside a SwiftUI scroll view. Move, recurring-span choice,
creation selection, contextual reminder creation, travel bands, offered slots and
overflow lists are attached there. Native integration must preserve those actions
and decorations while moving event view lifetime to the viewport.

Use AppKit's `NSCollectionView` and cached `NSCollectionViewLayout` attributes;
Apple's [layout contract](https://developer.apple.com/documentation/appkit/nscollectionviewlayout)
and [region query](https://developer.apple.com/documentation/appkit/nscollectionviewlayout/layoutattributesforelements%28in%3A%29)
provide the required viewport boundary. The previously audited UIKit calendar
libraries do not supply AppKit support (see the pinned rendering research). This
is an integration direction, not an implemented or benchmark-accepted Mac renderer.

The AppKit adapter now exists in `CalendarMacCollectionView.swift` and compiles
independently. Its 72 layout-contract checks pass, including offscreen active-item
inclusion and identity lookup; calendar-core CI runs the persistent probe. The Mac
screen is now wired to it by default in source, including per-event frames/content,
background creation/context menus and initial scroll restoration. The integration
build exited 0 and the new executable contains native viewport symbols. Its log also
contains a contradictory SwiftCompile failed-with-exit-0 diagnostic, retained with
the binary SHA in `.build/calendar-mac-integration-20261010/binary-identity.json`.
Visible functional checks remain pending.
`testDefaultDayAndWeekNativeViewport` asserts the native collection on both modes;
the existing action/recovery tests remain required. This adapter has no performance
acceptance yet.

The native paging check now requires a changed set of visible day identities after
four forward commands and exact restoration after four backward commands. The
former check only required the view picker to remain present. Retain earlier runs
as their narrower evidence; use the same strengthened recipe for reference/native
comparisons. This is functional coverage, not keyboard-response timing.

The default Mac Day/Week case also clicks a blank late-night grid slot and types in
the opened event editor before cancelling. This specifically checks background
hit routing through the native collection, rather than relying on a toolbar
shortcut. The native scroll/page comparison resets to the top before its wheel
sequence so it does not inherit the previous test's bottom-of-day position.

## First visible Mac integration run

`.build/native-ui-performance/uitests-20261010-111937/ui.xcresult` has **one pass and
two failures**, zero skips/runtime warnings. Overflow reachability passed. The
Day/Week case failed at the setup `stress.ready` lookup before exercising its body.
Paging failed the changed-date expectation; subsequent native inspection showed
the window had advanced from October 10–14 to October 30–November 3. Test observation
versus delayed update is unresolved, so neither a keyboard regression nor a passing
paging result is established. The failed run is retained. A same-app follow-up
records exact before/after date sets and hierarchy evidence.

The creation test now navigates to the prior period before clicking: the retained
legacy fixture contains 24-hour appointments, so late-night time alone does not
establish blank background. Visible Mac integration remains unaccepted.

The diagnostic follow-up (`uitests-20261010-112431/ui.xcresult`) retained two failures.
Its logs show that header queries enumerated up to 21 AX elements individually,
spending roughly 0.15–0.2 seconds per identifier and retrying indexes as the tree
changed. The same log records October 5–11 before paging and November 2–8 afterward:
the dates did advance correctly. This establishes a test-observation problem;
these failures are not evidence that keyboard paging stopped working. The revised
checks use one `XCUIElement.snapshot()` tree per evaluation, retain the exact
column-count/date-restoration assertions, and keep the three-second timeout. A
same-app rerun is underway; no renderer change was made for this test repair.

The same-app snapshot-query follow-up (`uitests-20261010-112717/ui.xcresult`)
passed both cases with zero failures/skips/runtime warnings. Day and Week each
rendered the expected column count and opened a typeable creation editor from
blank grid space; cancellation worked. Paging advanced the date set and restored
it exactly. No app change or timeout increase was needed between the failed
per-element-query run and this pass. Event actions, drag recovery and palette
checks are now running separately. Physical Mac UI performance remains unmeasured.

## Narrow-column event accessibility

The five action checks in `uitests-20261010-112910/ui.xcresult` yielded three passes
and two failures, no skips/runtime warnings. At seven columns the old ungrouped
artwork hides its icon and exposes short events as text with help text, rather
than a reliably named event action. This broke lookup of the actual visible
`Stress event 2` and the generic event action after scrolling. Native inspection
confirmed those events were drawn; this was not evidence of missing data.

The identical executable with `--calendar-group-events` passed all five unchanged
checks in `uitests-20261010-113310/ui.xcresult`, zero skips/runtime warnings, including
drag failure recovery and page-rebound event activation. Both SHA-256 values are
`6d8e753ce667c158f22bf01e7750687b70b0e4ab5a0dfd2a73aa1b77986d91c6` (retained in
`grouping-binary-comparison.json`). Grouped accessibility is now the production and
DEBUG default in source. Only `--calendar-reference-mac-event-accessibility`
selects the old DEBUG behavior. Rebuild/default-path validation is pending. This
is a correctness adoption; no frame/input speedup is claimed from XCTest durations.

## Rebuilt default Mac path — launch investigation

The default build completed successfully (`default-build-exit.json`, exit 0).
Preview `20261010-113916-916586` launches without renderer/accessibility opt-ins.
The first eight-case run, `uitests-20261010-113921/ui.xcresult`, failed all eight
checks at setup: `stress.ready` was absent. Exported failure hierarchies contain
the correct process (43998) and menu bar, but no app window or stress marker.
A three-second process sample shows the main thread mostly waiting for events,
not busy generating fixtures. Subsequent native inspection exposes a populated
Calendar, native collection and grouped event actions in that same process.
This narrows the failure to startup/window availability, but does not establish
the root cause or justify erasing the failures. The unchanged eight-case suite
is running again against the now-visible window. Artifact root:
`.build/calendar-mac-integration-20261010/default-ui-failed-*`. No timing acceptance
or default-path functional pass is claimed yet.

The unchanged visible-window follow-up (`uitests-20261010-114120/ui.xcresult`)
passed all eight tests, zero failures/skips/runtime warnings. The rebuilt preview
uses native Day/Week and grouped event accessibility without opt-in flags. Coverage:
Day/Week column counts and creation editor, overflow reachability, scrolling/paging
with exact date restoration, event actions after reuse, palette invalidation,
drag failure recovery and local-write-failure draft retention. The first launch's
missing window remains unresolved; this follow-up does not erase those failures.
Binary identity and exact summary are retained in `default-binary.json` and
`default-ui-summary.json`. These are functional checks, not UI latency evidence.

## First varied Mac rendering comparison — both fail

The same-binary first reference/native pair is retained under
`.build/calendar-mac-integration-20261010/comparison/{reference-1,native-1}`.
365 days / 36,500 events / 12 calendars use checksum `1550fd1978dd9444`;
the mail-calendar profile retains 180,000 emails alongside that calendar.
Both fresh processes were moved to October 12–18 before recording. CUA drove
up-eight-page reset, four down/up one-page scrolls each, four J and four K keys,
then verified restoration to the starting week. Both recordings completed, with
no sampled competing developer processes; system load and all samples remain.

| Main-thread commit work | Reference 1 | Native 1 |
| --- | ---: | ---: |
| Samples | 134 | 145 |
| p50 ms | 1.200 | 0.212 |
| p95 ms | 127.458 | 202.928 |
| Maximum ms | 488.722 | 677.809 |
| Post-interaction RSS KiB | 658480 | 658016 |

The initial native tail is worse, so this is not a demonstrated speedup. Both
fail the 8.3 ms budget. Reverse-order repeats remain required before attributing
the difference; then collect matched diagnostic CPU profiles. CUA accessibility
observation overhead is included, and the first reference control attempt was
rejected before action until its state was refreshed. These are rendering-work
diagnostics, not input-to-visible or physical display-delivery measurements.
No baseline or acceptance target changed.

The completed R/N/N/R comparison (`four-run-comparison.json`) reproduces the
native tail regression. Native 2: 155 commits, p50 0.259 ms, p95 213.911 ms,
p99 576.242 ms, maximum 648.863 ms. Reference 2: 115 commits, p50 1.674 ms,
p95 132.999 ms, p99 429.840 ms, maximum 501.453 ms. All four recordings completed
with the identical SHA and no sampled competing developer process; all four fail.
System load remains recorded, so host-monitor cleanliness is not proof of no
contention. Native lower medians do not compensate for worse tails. Next: matched
CPU-profile diagnostics of scrolling/paging, then isolate and measure each fix.

## CPU profile diagnosis

The combined Logging/Commits/Run Loops/Time Profiler recording failed with an
Instruments `set-column` backtrace/tagged-backtrace type error. Retain
`profile/reference` as incomplete (`recordingComplete:false`), not clean evidence.
Standalone Time Profiler succeeded for `profile/reference-cpu` and
`profile/native-cpu`, using the same executable and varied fixture. Both used
two preceding full interaction passes before the sampled scroll/page recipe.
The reference's preceding pass included the failed combined instrument, so these
diagnostics are not a replacement for the four-run rendering comparison.

The retained XML and `time-profile.summary.json` show 3,754 one-ms main-thread
sample weights for reference and 5,586 for native. Reference NSHostingView.layout
has 2,526 ms inclusive sample weight; native NSView layout-subtree paths exceed
4,100 ms. Native app frames include item creation, prepareForReuse, setContent
and coordinator update, alongside event-view construction/formatting. Inclusive
weights overlap and do not measure latency. The next controlled ablation should
isolate hosted-cell lifecycle/graph rebuild work; this profile does not yet
identify one operation as the proven cause. Parser retained as
`profile/summarize-cpu.py`; no renderer change or budget relaxation made.

## Hosted-cell reuse experiment (pending measurement)

DEBUG-only `--calendar-retain-reused-content` skips setting the hosting root to
EmptyView in prepareForReuse. The cell still installs new content wrapped in the
new occurrence identity before display. Production/default behavior is unchanged.
Hypothesis: avoid intermediate graph teardown during recycling; counter-risk:
pooled views retain old content and its captured context until replacement.
This is deliberately not described as an optimization yet. The launcher accepts
the flag so one rebuilt executable can compare both lifecycle policies.

Default component layout/initial-mount checks passed under
`reuse-ablation/component-default`; they do not validate visible recycling or
timing. An optimized audit build is running (`reuse-ablation/build-command.json`).
Required next evidence: same-binary control/candidate/candidate/control scroll
and page recordings, memory before/after cycling, empty replacement/lifetime
checks and the eight native Calendar action tests. Run the persistent component
regression suite before adoption. Reject or remove the candidate if its extra
retention brings no demonstrated benefit.

The windowless ownership diagnostic (`reuse-ablation/ownership`) replaces 100
pages of 100 token-bearing descriptors through the actual coordinator. Both
clear/retain policies hold 100 live tokens on each page and 12 after empty
replacement. This bounds growth in that probe but also shows that emptying the
collection alone retains pooled content under both policies. It does not prove
full-app object retention, visible recycling, or timing. Raw per-page counts,
probe source and binary are retained. The optimized app build remains running;
no candidate acceptance or performance benefit is claimed.

The reuse-ablation build succeeded. Its first same-binary clear/retain pair
(`reuse-ablation/first-pair.json`, SHA `684a9f89d626fa25160df6ab13b16ee43e0b17c220636c8d414cb56781d96a3f`)
shows no benefit: control commit p95 190.938 ms / maximum 672.103 ms versus
candidate p95 237.215 ms / maximum 684.872 ms. RSS is 653520 versus 654880 KiB.
Both traces completed and fail; no sampled competing developer process was seen,
but load samples are retained. Reverse-order repeats remain pending. Candidate
is still DEBUG-only and must not be adopted based on this result.

## Reuse experiment rejected

The completed clear/retain/retain/clear matrix is retained in
`reuse-ablation/four-run-comparison.json`. Control p95 is 190.938/191.152 ms;
candidate p95 is 237.215/190.435 ms. Control maxima are 672.103/687.142 ms;
candidate maxima are 684.872/582.901 ms. RSS varies from 640880 to 654880 KiB
without a stable policy advantage. All four fail the unchanged frame-work gate.
There is no reproducible benefit sufficient to retain the extra policy. The
DEBUG experiment and launcher option were removed; candidate source, launcher,
exact binary clones, ownership probe and traces remain available for reproduction.
No candidate UI acceptance was claimed or needed for adoption: it was rejected.
Restored default component checks run under `reuse-ablation/restored-default-checks`.

Additional profile inspection: NSHostingView.layout inclusive sample weight is
2526 ms reference / 3921 ms native; AG::Subgraph::update is 1736 / 3105 ms.
The native coordinator update accounts for 245 ms inclusive, item creation 115 ms,
prepareForReuse 15 ms. These overlapping statistical weights direct the next
investigation toward graph construction/update costs, rather than the rejected
intermediate-empty-root tweak.

## Prepared-artwork eligibility checked before alteration

The Mac host lacks the explicit `calendarNativeCell` environment marker used by
UIKit. A counter probe disproved the initial hypothesis that this prevented
preparation: the unchanged binary with `--calendar-prepared-artwork` prepared
28 images, zero rejections/dropped samples, and drained the queue. The proposed
marker insertion was removed before any build; no eligibility repair is claimed.
`artwork-eligibility/before-scale-idle.json` retains 28 cold API samples with
maximum 1.937292 ms, cache pixels 1132320 bytes and consumer pixels 1092480 bytes.
These per-image timings exclude queue delay and are not frame/input acceptance.
The existing 100-tick idle probe observed its root, passed and recorded zero
MacWeekView/MacWeekTimedLayout redraws in that interval.

The Mac preview launcher now accepts `--calendar-artwork-profile` to expose the
existing app counters via a ten-second clock probe. This is diagnostic collection
only; inspect the recorded roots instead of assuming Mac coverage from the option.
Next compare existing prepared artwork against native reference artwork on the
same binary, with cold/warm scrolling, page changes and memory/eviction evidence.
Prepared artwork remains experimental until functional and performance acceptance.

## Prepared-artwork first/warm diagnostic — still fails

`prepared-comparison/initial-comparison.json` retains the same SHA as both native
clear controls. Prepared first recipe: 216 commits, p95 103.037 ms, maximum
760.417 ms, 4560.798 ms summed commit durations, 17 over-budget commits,
RSS 674432 KiB. Same-process warm recipe: 102 commits, p95 617.954 ms, maximum
767.760 ms, 4973.051 ms summed durations, 15 over-budget commits, RSS 681248 KiB.
Control totals were 4185.891–4766.305 ms and maxima 672.103–687.142 ms.
All recordings completed. Lower first-run p95 is not an improvement claim: sample
counts differ, maxima still fail, and warm total work does not improve.

This is diagnostic evidence, not a complete adoption matrix: controls were earlier
fresh processes, prepared first launch also ran the clock/counter probe before
measurement, warm history may include cache eviction, and physical input/display
latency remains unmeasured. Prepared artwork stays off by default. Before altering
the larger graph path, isolate scroll-only and page-only traces to attribute the
spikes; the combined recipe alone cannot distinguish them.

## Default native scroll/page isolation

`phase-isolation/comparison.json` splits the same varied native app into 30-second
scroll-only and page-only recordings. Scroll: 122 commits, p95 159.109 ms,
maximum 331.875 ms, summed commit durations 1836.603 ms, 10 over budget.
Paging: 61 commits, p95 549.419 ms, maximum 658.125 ms, summed durations
4953.220 ms, 10 over budget. Both completed with no sampled competing developer
processes, and both fail. Paging is the larger cost in these isolated recipes;
scrolling is not accepted. Recordings are separate scenarios, not directly
additive or interchangeable with the combined workload.

Next inspect/measure the existing Canvas-grid ablation against shape-based grid
construction on the same native viewport. This tests a larger SwiftUI graph
reduction while retaining event visuals/actions; no improvement is asserted yet.

## Canvas grid diagnostic

The existing `CalendarHourLines` oracle passed 18 exact pixel comparisons under
`canvas/pixels` (widths 172/215.5/900, scales 1/2/3, light/dark). Native Canvas
paging (`canvas/paging-1`) produced 51 commits, p95 476.922 ms, maximum 655.286 ms,
summed durations 2518.122 ms and six over-budget commits, versus the earlier
shape-grid paging sample's 4953.220 ms sum and 658.125 ms maximum. The lower sum
is promising but not an adoption result: both fail, sample counts differ, and
the performance CUA recipe only verified return to the starting week after
sending four J/four K commands. It did not independently retain the forward
destination (the separate functional XCTest does).

Strengthen the next matched performance recipe to retain both November 9–15 after
four forward keys from October 12–18, and October 12–18 after four back keys.
Run both policies with that same observation protocol before inferring benefit.
Historical results remain diagnostic and are not erased or silently relabeled.
Canvas remains opt-in until repeated benefit, interaction parity and regression
evidence are established.

## Verified paging comparison and next graph experiment

Both `canvas/v2-canvas-1` and `canvas/v2-shapes-1` verified November 9–15 after
four J commands and October 12–18 after four K commands, with one preceding
paging pass. Canvas: p95 522.343 ms, max 635.366 ms, total commit durations
4573.888 ms. Shapes: p95 546.742 ms, max 654.640 ms, total 4024.606 ms.
Both fail; the lower total seen in the earlier Canvas diagnostic did not repeat
under this observation protocol. Canvas is not adopted.

The rejected empty-root-only reuse ablation still replaced `.id(occurrenceID)`
on every cell reassignment, so it did not test retaining the event graph itself.
A new DEBUG-only `--calendar-stable-cell-graph` jointly keeps the hosting root
and updates content without that identity boundary. Production remains unchanged.
This can retain event-local state: require explicit action rebinding, drag,
prepared-key invalidation and memory/lifetime checks before any adoption.
The existing eight native action checks and same-binary controlled timing matrix
remain required; a functional or speed benefit is unproven.

`stable-graph/component-control` passes the 78 default layout/mount checks.
The optimized audit build completed successfully (`stable-graph/build-exit.json`, exit 0).
This is a source-supported hypothesis about graph construction, not a proven
root cause or an accepted optimization.

The first candidate UI run, `uitests-20261010-122854/ui.xcresult`, failed all nine
cases in setup because `stress.ready` was absent. Its retained AX attachments
show the correct preview PID 57046 with a menu bar and no window. The one-second
process sample predominantly waits in the main run loop; this does not establish
a fixture-computation stall. Selecting that exact running app through the native
app connection then exposed the Calendar window and ready marker. This repeats
the earlier cold-launch failure and remains an unresolved launch issue, not a
Calendar interaction result. Raw attachments, sample and summary are retained in
`stable-graph/startup-attachments`, `startup-sample.txt` and `initial-ui-summary.json`.

The action suite now additionally checks three successive forward pages, opens
each page's event and compares its detail title, then verifies restoration of the
initial occurrence after returning. This specifically challenges stale closures
across repeated cell reuse. The nine-case follow-up run after window availability
is `uitests-20261010-123110`: all nine cases passed, zero failures and zero skips.
The three-page case verified each opened detail and the original occurrence on
return. `stable-graph/candidate-ui-summary.json` and `candidate-provenance.json`
retain results and source/binary identity. The runner log contains DisplayManager
messages about an infinite/empty rectangle during synthesized keyboard input;
retain these diagnostics even though the destination/detail assertions passed.
This does not resolve cold launch, prepared-artwork state, memory tradeoffs or
performance. Same-binary controlled timing is the next adoption requirement.

### Stable graph paging comparison

`stable-graph/{control-1,candidate-1,candidate-2,control-2}` completes the
same-binary alternating comparison, each in a fresh process with one warm paging
pass. The varied workload is unchanged: 36,500 events, 365 days, 12 calendars,
checksum `1550fd1978dd9444`, alongside 180,000 emails. Every measured pass verifies
November 9–15 after four forward keys and October 12–18 after four back keys.

| Policy/run | Commit p95 ms | Max ms | Total commit ms | Commits over 8.3 ms |
| --- | ---: | ---: | ---: | ---: |
| Identity reset 1 | 657.393 | 661.722 | 4546.700 | 9 |
| Stable graph 1 | 477.354 | 587.817 | 4425.475 | 11 |
| Stable graph 2 | 522.293 | 555.951 | 3505.191 | 9 |
| Identity reset 2 | 660.590 | 734.141 | 5263.309 | 10 |

The candidate lowers maximum and aggregate commit duration in both trials, with
variable gain and no reduction in all over-budget counts. All four recordings
fail. No sampled competing developer processes were detected; recorded host load
still varies, so this is not contention-free evidence. Commit work is not
input-to-visible latency or display delivery. Raw traces, destinations, binary
identity and samples remain local; `paging-comparison.json` summarizes them.

The actual adapter's windowless ownership probe (`stable-graph/ownership`) holds
100 payloads through each of 100 page replacements under both policies and 12
pooled payloads after an empty replacement. No additional accumulation appeared
in this probe. This is not full-app memory-pressure/eviction or visible reuse
evidence. Prepared-artwork state replacement, cold behavior and full regression
checks remain required before adoption; production still uses identity resets.

### Prepared state and cancellation follow-up

`uitests-20261010-124157/ui.xcresult` passes four graph-reuse + prepared-artwork
checks: actual Day/Week switching, drag-failure recovery, palette invalidation,
and three-page detail rebinding/restoration. `stable-graph/prepared-ui-summary.json`
retains the verdict; `prepared-installed-counters.json` confirms actual preparation
was enabled with nonzero retained images, rather than a fallback-only launch.
These tests validate actions/state but do not establish exact pixel identity.

The independent preparation lifecycle check failed with “Replaced viewport cannot
publish cancelled artwork.” The cancellation handler queues actor work, which can
lose a race to the scheduled drain; the coordinator now rechecks cancellation in
the requesting task after its continuation resumes. The view already independently
checks cancellation before publication. This fix is subsequent to the tested app
binary and still needs rebuilt-app/regression evidence.

Retained `stable-graph/cancellation` evidence includes the initial failure, three
passing pre-change runs, and a post-change busy-loop sample. That hang exposed a
test synchronization defect: its wait for a nonempty queue could miss an already
completed request forever. The wait is now bounded and fails explicitly if it
misses admission. Five bounded post-change runs yield four passes (287 checks each)
and one synchronization failure. The suite is **not green**; deterministic queue
synchronization remains required. Neither the failure nor hang is discarded, and
these concurrent functional runs are not a controlled performance comparison.

The synchronization follow-up injects a held drain scheduler into the real
coordinator; production retains its one-millisecond main-queue scheduling. Queue
admission can now be observed before releasing the callback. A separate forced
race drains immediately after cancellation, before the actor cancellation
callback can run, and requires both a nil result and released consumer bytes.
Six alternating control/fixed trials (`cancellation/verified-*`) all reproduce
the exact regression in the control (only the final cancellation check omitted)
and pass all 290 lifecycle checks in the fixed implementation. Both compile logs
are retained. Historical synchronization failures remain above; the new controlled
check resolves them without dropping the original admission scenarios.

The full persistent component suite ran at `stable-graph/components` on
the dedicated iPhone Simulator; its final validity failure is detailed below.
The scheduler/cancellation correction still needs rebuilt-app validation and is
not a claim of faster UI or completed physical-device coverage.

Follow-up: this full run completed with a failed validity gate. All component
metric, memory and redraw comparisons passed, but `scale-1d-host.json` records
a two-second `ps` timeout, so the one-day comparison lacks complete monitoring.
No overlapping developer processes were recorded; that does not establish their
absence during the missed sample. Load averages were approximately 68–77 during
that case. Keep the failed `gate.json`; do not relabel it a passing suite. The
dedicated iPhone Simulator was shut down after completion, while the existing
review iPad Simulator was preserved. After confirming all eight scenario reports
and the failed gate were retained, the exact-device cleanup removed eight temporary
fixtures (1.205 GiB logical); `components/fixture-cleanup.json` records every path.
No review build, result or worktree was removed. Collect a fresh full comparison when host
conditions permit. `scroll-end-app` contains the subsequent Mac rebuild for
actual-app persistence validation; it cannot repair this failed gate.

### Native Day scroll persistence parity

Source inspection found that the reference host invokes `persistDayScrollPosition`
on idle, while the native host only updated reference bookkeeping and relied on
screen disappearance for persistence. The AppKit adapter now exposes an end-scroll
callback from `NSScrollView.didEndLiveScrollNotification`; Mac Day wires that to
the existing guarded persistence method. Bounds notifications still only update
bookkeeping. The callback is refreshed on representable updates and removed on
teardown.

`scroll-end-contract` passes 83 actual-adapter checks, including no save callback
on bounds changes or another scroll view's notification, one callback on the
owned end notification, callback replacement and teardown. These are notification
contract checks, not proof that physical wheel/trackpad momentum emits the expected
lifecycle. Rebuilt-app idle persistence and scroll timing remain pending. The
already-running iPhone component suite cannot validate this Mac-only correction.

The real-app regression is `NativeInteractionTests.testNativeDayPersistsScrollWhileVisible`: switch to Day, scroll to top and require a stored zero offset, then scroll down and require a positive stored offset before leaving Day.

**Observation correction:** `uitests-20261010-125314`, `125616`, `125656` and
`125733` are retained test-observation failures, not valid before/after persistence
results. The sandboxed XCTest runner's `defaults` child exits 1 with empty output;
removing test-injection environment variables did not repair it. An external
read saw 735 on the old app and zero after the new app's scroll, but that is
insufficient for the complete automated claim. The test now reads the app's
stored offset through a DEBUG observation-audit label. This checks in-app stored
state; disk flush/relaunch needs separate evidence. The revised label/test still
needs a rebuilt audit app. The previous assertion that the old failed test proved
the persistence bug was incorrect; source comparison and notification checks
remain the evidence for the implementation gap.

The rebuilt audit observation is valid: `uitests-20261010-130215` finds the saved
offset label, passes the top/zero assertion, then fails the down-scroll/positive
assertion. Native inspection shows the actual scrollbar at 0.5442 while saved
offset is still zero. Thus the live-scroll notification alone does not cover this
tested wheel path. The source now adds a discrete-wheel fallback: one reusable
150 ms idle timer, extended by wheel events without phases, invokes the existing
save callback only after input stops. AppKit's phased-scroll callback remains.
Timer cancellation is part of viewport teardown; no per-event state publication
is added. The `discrete-contract` probe checks burst coalescing and teardown;
`discrete-app` is the pending real-app build. Performance and real input validation
remain required; this is not yet an accepted end-to-end repair.

The discrete-wheel follow-up `uitests-20261010-130821/ui.xcresult` passes the
unchanged audit-label persistence check, with zero skips/runtime warnings:
saved zero at the top, then a positive saved value after down-scrolling, both
before leaving Day. `scroll-end-app/discrete-app/ui-summary.json` and `binary.json`
retain its evidence. This closes the tested functional wheel path; trackpad,
relaunch durability and matched scroll-performance coverage remain separate.

### Real-app minimum-density capacity probe

`capacity/one-per-day` measures warm native Week paging with the audit-observation
build, 365 events across 365 days and 12 calendars, checksum `43471ca9b6420a1b`.
Other load remains 180,000 emails, 5,000 notes and 20,000 podcast episodes. Both
November 9–15 and return to October 12–18 were verified during the trace; one
unmeasured warm-up pass preceded it. Compilation had finished before recording.

The 40 commits have p95 103.018 ms, maximum 120.262 ms and 11 violations of 8.3 ms.
No sampled competing developer work was detected. This lowest positive generator
density still fails, so no passing capacity is established; it points to fixed
page/view work in addition to density cost. This single warm trial does not prove
monotonic capacity or cover scrolling, cold/eviction, input latency or physical
mobile devices. Keep its failing raw trace and build identity. The standard
100-events/day workload remains unchanged.

The subsequent low-density Time Profiler run (`capacity/one-cpu`) uses the newer
discrete-wheel build, retains its SHA and verifies the same forward/return weeks.
Of 1,104 ms statistical main-thread sample weight, 734 ms includes
`NSHostingView.layout`, 524 ms includes `AG::Subgraph::update`, and 18 ms includes
the collection coordinator update. Inclusive values overlap and are not elapsed
latencies. This supports investigating view-graph/layout work even at low event
density; it does not identify one operation as the proven cause.

The existing DEBUG `--calendar-reuse-columns` ablation preserves day-column slots
across date changes. Its earlier reference-host report did not establish acceptance.
In the integrated native host, it now applies to the event-free background grid;
measure this existing option against the unchanged default before adding another
renderer. Current low-density CPU diagnosis is not adoption evidence.

The first integrated background-column comparison is retained at
`capacity/columns-{control,candidate}`. Both use the same binary and density-one
checksum, two prior paging passes, and verify both measured destinations. Date
columns: 42 commits, p95 106.332 ms, max 132.647 ms, total 927.706 ms. Reused
columns: 45 commits, p95 51.003 ms, max 74.775 ms, total 571.462 ms. Each has
11 over-budget commits and no sampled competing developer jobs. Both fail.

This is preliminary: the control's second warm-up was the Time Profiler recording,
while the candidate's warm-ups were unprofiled. `columns-preliminary.json` retains
the shared SHA and metrics. Repeat fresh processes with identical unprofiled warm-up
before claiming reproducible improvement. High-density behavior, stationary-pointer
state, action rebinding and cold/eviction performance remain unverified; column
reuse stays DEBUG-only and off by default.

The fresh-process matched follow-up (`capacity/columns-matched-{candidate,control}`)
uses two unprofiled warm-up passes for each, the same binary/checksum, and verifies
both destinations. Candidate: 29 commits, p95 53.603 ms, max 124.071 ms, total
498.961 ms, nine violations. Control: 35 commits, p95 99.992 ms, max 117.455 ms,
total 906.203 ms, twelve violations. No sampled developer overlap occurred.
The p95/aggregate reduction persists in this pair, but the candidate's worst
commit is higher. Both fail. Preserve the tail and investigate it rather than
describing column reuse as a complete or uniformly faster result. Dense/cold,
pointer/gesture state and memory validation remain open; no default changed.

The reused-column native preview passes all ten functional Calendar cases in
`uitests-20261010-131745/ui.xcresult` (zero failures/skips/runtime warnings):
Day/Week actual viewport switching, creation draft failure, scroll persistence,
drag recovery, accessibility, overflow reachability, paging/scrolling, single-
and three-page action rebinding, and palette invalidation. This uses the legacy
100-events/day functional fixture, not the varied low-density timing fixture.

`testNativeCalendarWindowResizePreservesEventActions` additionally passes in
`uitests-20261010-132113/ui.xcresult`: real native corner drag changes dimensions,
date identities remain unchanged, an event opens its matching detail at the new
size, and dimensions/date identities restore. It is one Week-size transition,
not exhaustive display/Day/full-screen coverage or resize-latency evidence.
`capacity/columns-ui-summary.json` and `columns-resize-ui-summary.json` retain
both summaries. Stationary-pointer/context-menu behavior and dense/cold timing
remain adoption requirements.

## Empty-slot menu accessibility — integration correction

Expected: right-click or Control-click an empty Day/Week slot, expose event and
reminder actions to accessibility, and open an editor for the displayed day after
paging with a stationary pointer. Existing event menus must retain their own actions.

The untouched default binary also fails the menu lookup, so this is not confined
to experimental column reuse. These failures occur before the paging/date assertions;
they do not prove a wrong draft date. Earlier descriptions of a missing visual menu
were too broad: the isolated adapter can draw a popup while omitting it from the
accessibility tree.

The controlled AppKit probe under
`.build/calendar-mac-integration-20261010/slot-menu/routing-probe` established:

- A popup anchored to the SwiftUI background is visually present but absent from
  the queried accessibility hierarchy.
- A standard native button popup exposes its item and dispatches its action.
- Changing the calendar popup anchor to the native scroll view exposes its item;
  selecting it changes the probe window title to `Selected slot`.

The geometry diagnostic rejects a suspected stale-width explanation: captured and
live widths are both 902 points; the click is `(482, 599)`, inside a 1,392-point
calendar with one day, and the callback supplies two actions. Its output is retained
in the `20261010-135745-942435` preview log. It is not a timing measurement.

The current correction scopes an AppKit local event monitor to this window and
background hit target, resolves the current document point, and anchors the native
menu to the scroll view. Ordinary clicks and event-cell menus continue normally.
The monitor is removed on viewport teardown. The reference SwiftUI path remains
available for comparisons. Full-app verification is pending; the isolated probe
is not all-device readiness.

Retained native results (all paths below are in `.build/native-ui-performance/`):

| Result | Scope and outcome |
| --- | --- |
| `uitests-20261010-132542/ui.xcresult` | Original reused-column candidate: blank-slot menu lookup fails. |
| `uitests-20261010-133004/ui.xcresult` | Collection menu handler: blank-slot failure; existing-event menu/detail passes. |
| `uitests-20261010-133508/ui.xcresult` | Background method handler: same failure/pass; finite viewport coordinates verified. |
| `uitests-20261010-133958/ui.xcresult` | Removing the SwiftUI menu modifier does not close the menu-accessibility failure. |
| `uitests-20261010-134605/ui.xcresult` | Untouched binary with normal defaults: Day and Week menu lookups both fail. |
| `uitests-20261010-134741/ui.xcresult` | Native click recognizer: Day/Week menu lookups still fail; existing-event actions pass. |

DisplayManager `inf`-rectangle diagnostics remain in the logs; do not describe
these as clean runtime-warning evidence. Failed revisions and their binaries are
retained under `.build/calendar-mac-integration-20261010/slot-menu/` and the
corresponding preview directories. No failed run or baseline was discarded.

The twelve-pointer-movement probe reports 36 whole-Week evaluations for the original
and zero after removing native parent-hover observation; both end on the same empty
week. Exported attachments are in `slot-menu/{original,gesture}-hover`. This is a
redraw-count comparison, not input/frame latency. The persistent test now explicitly
resets to Week/Today and requires zero parent redraws for native viewports; its
updated matched comparison and full component gate remain required.

### Full-app menu verification follow-up

`uitests-20261010-142039/ui.xcresult` passes all five focused tests, with zero
failures or skips: Day and Week empty-slot creation after stationary-pointer
paging, Control-click creation after paging, existing-event menu/detail identity,
and twelve pointer movements without a whole-Week body evaluation. The tested app
is the `20261010-140923-296059` isolated preview, built from the retained
`slot-menu/scroll-anchor-build` sources. This supersedes the pending full-app menu
verification above; it does not establish all-device or frame/input acceptance.

The intervening failures exposed test-observation problems, not wrong event dates:
`140937` queried menu labels while AppKit supplies item titles; `141427` and
`141551` assumed the adjacent Starts text labeled the native date picker;
`141737` reached the picker but could not parse XCTest's `Unsafe value, description`
serialization of its NSDate. The repaired assertion reads the first of exactly two
native date pickers, parses the explicit timezone, and still compares the draft
date against the newly displayed calendar day. No app change, relaxed date
assertion or increased timeout was needed for these query repairs. All failed
bundles remain retained. Earlier menu-lookup failures alone must not be treated
as proof of an application regression.

The xcresult summary lists no runtime warnings, but the text log still contains
DisplayManager `inf`-rectangle diagnostics. The full component gate in
`slot-menu/components` completed all eight scenarios and **failed validity**:
the 90-day host monitor's process-list command timed out after two seconds.
No component latency, memory or redraw baseline failed, and no overlapping
developer process was sampled. Retain this failure; a clean comparison is still
required. This binary predates the physical-review compile-mode changes.
The dedicated test Simulator was shut down and its eight disposable fixtures
removed (1.205 GiB logical), retaining all reports and the review iPad Simulator.
The matched Week/Today hover control remains outstanding.
