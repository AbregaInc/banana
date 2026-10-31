# Native surface-backed calendar tiles — October 9, 2026

This experimental renderer improves measured desktop scrolling and paging, but **does not meet
all acceptance targets** and has not replaced the production calendar. All budgets remain unchanged.

Current disposition: native CVPixelBuffer publication is a useful desktop candidate, while the
matched iPhone storage comparison rejects it because of higher memory and worse response tails.
Keep CGImage with lazy accessibility as the iPhone candidate. Neither platform has complete
input-to-visible acceptance evidence. Physical iPad remains unmeasured. All implementation
alternatives below remain opt-in in the isolated benchmark; the shipping calendar is unchanged.

## Native framework choice

The preceding [async experiment](../calendar-async-preparation-20261009/README.md) removed foreground
bitmap drawing, but native transaction flush still took around 20 ms. AppKit's `updateLayer` path
removed draw callbacks without removing the flush stall. This suggested image transfer/conversion
as a separate bottleneck; it was a hypothesis, not a measured attribution of every CPU instruction.

Apple explicitly supports surface-backed pixel buffers as layer contents and recommends avoiding
CGImage conversion for interactive rendering in [WWDC23's image pipeline guidance](https://developer.apple.com/videos/play/wwdc2023/10181/).
The public CoreVideo SDK's `kCVPixelBufferIOSurfaceCoreAnimationCompatibilityKey` declares that
compatibility. This experiment uses that maintained native implementation rather than introducing
a custom Metal renderer or relying on private Core Animation APIs.

`RasterPage` optionally draws into a locked, IOSurface-backed BGRA `CVPixelBuffer` with a compatible
Core Graphics context. It tags the source color space, finishes drawing, unlocks, and then publishes
immutable storage to the layer. It never mutates or pools a published buffer. The live path does
not construct a CGImage; a canonical RGBA snapshot exists only when an oracle asks for `image`.
The original CGImage path remains the matched control and the default. The `tile-prefetch-async-surface`
ablation changes storage/publication only, keeping two workers, prefetch, geometry and accessibility.

The spare LRU remains 64 MiB / 24 entries, accounting for native pixel-buffer data size. Active
pages, replacements and compositor-retained storage add to that working set. Per-sample physical
footprint supplements peak RSS; the footprint value is a snapshot, not a kernel-recorded peak.

## Correctness and retained failure

The first probe passed all pixel comparisons but ended on a mistaken test assertion: `clear()`
retires active tiles while intentionally retaining the spare cache. Its failure remains in
`pixel-buffer-300.json`. The corrected probe checks active retirement, then explicitly evicts
and checks cache release; it passes 128 checks at each density. Exact pixel comparisons cover
393 pt at 1x/2x/3x and 1200 pt at 2x/3x, four tile positions including the short final tile,
100 and 300 events/day, five visible days. They also check event IDs, native layer-content types,
async handoff without synchronous fallback, cache bounds and eviction. Additional explicit
IOSurface-backing and full async lifecycle checks subsequently passed; see the follow-up sections.

A native visible preflight used the isolated `Calendar Surface Review` bundle at 100 events/day.
CUA screenshots and accessibility observations verified a populated upright timeline, Oct 8 →
Oct 13 → Oct 8 navigation, wheel scrolling, cache clear/recovery, and activation of event `4:19-40`.
The preview was closed before matched measurements. These functional observations are not latency
samples; five densely overlapping columns are still a benchmark layout, not finished product UX.

## Matched native performance

`run-mac.py --foreground-surface-only --foreground-navigation --navigation-stress` ran three
alternating trials per policy at both densities. Every case has valid coverage and a clean sampled
host monitor. The original scenarios remain unchanged. Foreground scenarios run at the final
1000 pt viewport after the retained resize phase; the initial window is 1200 pt wide, at 2x scale.
Raw reports include the display's supported maximum refresh; this is not delivered frame cadence.

| Events/day | Policy | Worst foreground response ms | Largest foreground main section ms | Scroll-offset p95 / max ms |
| --- | --- | ---: | ---: | ---: |
| 100 | CGImage | 44.50 | 21.77 | 2.79 / 14.42 |
| 100 | Native surface | 29.38 | 6.68 | 1.74 / 5.20 |
| 300 | CGImage | 61.27 | 22.05 | 2.95 / 10.00 |
| 300 | Native surface | 45.88 | 9.72 | 2.07 / 7.91 |

At 100 density the native foreground sections stay within the measured component limits in all
three trials. At 300 density a warm installation section still reaches 9.72 ms, above 8.3 ms.
The retained synchronous cold mount still reaches **102.90 ms** at 300 density, an explicit hard
failure. All 12 full-case acceptance gates therefore still fail. Programmatic offset/API/flush
measurements do not establish input-to-visible latency, GPU completion or 120 Hz frame delivery.

| Events/day | Policy | Peak RSS MiB | Largest sampled physical footprint MiB |
| --- | --- | ---: | ---: |
| 100 | CGImage | 247.27 | 175.45 |
| 100 | Native surface | 182.16 | 102.41 |
| 300 | CGImage | 243.56 | 179.58 |
| 300 | Native surface | 179.34 | 108.83 |

These are workload-specific observed values, not product memory budgets. All original cold, warm,
resize, scrolling, eviction and directional samples remain in `native-mac/`; pooled foreground
percentiles are in `pooled-foreground.json`. No baseline has been changed. The result supports
further integration work, with a reviewed baseline reduction proposed only for the ultimately
adopted and validated implementation.

## Remaining evidence

Physical iPhone/iPad and Simulator surface-buffer checks, native frame/input traces, and retained
accessibility comparisons are pending. Production feature parity, cache invalidation for changed
events/theme/fonts, real provider contention and normal calendar editing remain outside this frozen
fixture prototype. The main app's performance contract has not been satisfied by these results.

## Follow-up correctness (05:50 EDT)

The full async tile oracle passed 1,106 checks for each of four week cases: CGImage
and CVPixelBuffer at 100 and 300 events/day. `component-surface/` retains command,
binary identity, host monitoring, exact pixel comparisons, cancellation and bounded
cache checks. Physical iPhone navigation passed 44 checks in each of eight cases
(352 total), including cancellation/replacement races and eviction recovery. See
`physical-navigation-checks/`. These are correctness checks, not display timing.

Physical iPhone touch correctness also passed for the surface/lazy variant at
300 events/day: `.build/calendar-touch/iphone-surface-lazy-300/ui.xcresult`.
A separate matched-policy touch run produced a successful eight-second Animation
Hitches trace during actual swipes, PID 11659, retained locally at
`.build/calendar-touch/iphone-surface-lazy-300-lean-trace/touch.trace`. Trace coverage
and display cadence remain under analysis; zero rows in the hitch table alone
is not acceptance evidence. Earlier failed multi-instrument captures remain retained.

## Physical iPhone surface/accessibility pairing

Twelve cases completed on iPhone 14 Pro with identical signed binary, alternating
three trials at each density. All coverage and host checks passed. All original
full gates still fail; six lazy-container foreground subsets stay within their
measured component limits. No baseline or acceptance rule changed.

| Events/day | Policy | Worst foreground response | Largest main section |
| --- | --- | ---: | ---: |
| 100 | Surface, eager AX | 49.12 ms | 7.89 ms |
| 100 | Surface, lazy AX | 47.91 ms | 5.79 ms |
| 300 | Surface, eager AX | 70.91 ms | 19.28 ms |
| 300 | Surface, lazy AX | 69.65 ms | 5.09 ms |

These API-completion timings do not establish input/display delivery. Dense cold
preparation still misses the 50 ms goal. This matrix does not force an accessibility
client to enumerate all elements; that workload is a separate required comparison.
Raw results, including every original cold, eviction and navigation failure, are
in `physical-surface-accessibility/`.

The strengthened pixel oracle additionally verifies actual IOSurface allocation:
148 checks passed at each density (296 total). Native AppKit controller cancellation
and recovery passed 44 checks for each of six cases (264 total), covering CGImage,
surface, and surface with retained accessibility. The corrected upright offscreen
layer oracle passed 25 control and 31 paired checks; exact composite pixels match.
Earlier upside-down oracle snapshots remain retained, and the updateLayer timing
experiment still showed no useful performance benefit. See `followup-checks/`.

## Real iPhone swipe trace: observed render-work failure

The eight-second Animation Hitches recording contains 621 updates attributed to
CalendarLibraryBenchmark PID 11659. All 621 match compositor render and lifetime
rows by display, swap ID, and surface ID. No hitch rows were emitted, but this
does not erase the project's stricter observed 8.3 ms work failures.

| Trace interval | p50 | p95 | p99 | Maximum | Over 8.3 ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| App updates | 0.493 ms | 0.791 ms | 3.147 ms | 6.498 ms | 0/621 |
| Associated render intervals | 2.920 ms | 9.154 ms | 9.521 ms | 9.809 ms | 115/621 |

Display-wide VSync gaps vary: 607 were approximately 8.34 ms and 122 approximately
16.68 ms, with additional idle/transition rates. This is evidence of variable
cadence, not permission to normalize away render overruns. The recording lacks
app-attributed HID-to-visible timestamps and has no CPU-to-display table rows.
Direct-input latency remains unmeasured.

Frame lifetimes are pipelined spans (25.0/33.4 ms here), not single-frame CPU work
or input latency. Apple's [render-loop explanation](https://developer.apple.com/documentation/xcode/understanding-hitches-in-your-app)
describes these distinct intervals. `report-hitches.py` resolves XML references,
requires app attribution and complete compositor joins, preserves every selected
sample, and never returns a full-acceptance pass. Raw trace and table exports stay
local; the sanitized analysis and capture record are in `physical-swipe-trace/`.

## AppKit accessibility page-cache follow-up

Twelve alternating cases completed with clean host/coverage checks. The bounded
page cache improves warm-return response modestly but worsens the largest main
section; do not adopt it as a general improvement. At 100 events/day, worst response
changes 29.02→30.50 ms and largest main section 6.06→6.86 ms. At 300, worst response
changes 42.93→45.41 ms and largest main section 8.50→10.12 ms. Warm-page maxima
change 7.35→5.32 ms and 8.98→8.04 ms respectively. All original full gates still
fail. Raw paired results are in `native-surface-cache/`.

## Fresh-process controller mount

`run-mac-mount.py` runs 12 new processes, alternating synchronous/2-worker mount
at 100/300 events/day with identical CVPixelBuffer policy and complete initial
viewport. It retains setup, preparation, flush, fixture cost, coverage and memory.
Fixture construction is separately recorded and excluded from controller timing;
this is not process-launch-to-visible acceptance. Existing full phases are unchanged.

At 100 events/day synchronous mounts range 70.36–73.72 ms and async mounts
57.89–102.22 ms. At 300 they range 99.99–108.53 ms and 73.40–82.62 ms respectively.
The 102.22 ms asynchronous run is a retained hard failure, not discarded noise.
Native setup itself costs 25.14–28.41 ms. All twelve cases fail the component
main-section budget. Async mount is therefore not adopted as an acceptance fix.
Raw results are in `native-cold-mount-surface/`.

Host monitoring terminology: “clean” above means the persistent monitor observed
no competing compiler/test jobs. It does not establish an otherwise idle desktop.
The properties matrix began at load averages 28.93/16.59/13.69; a later process
snapshot showed WebKit, WindowServer and other normal applications consuming CPU.
Those user processes were not stopped. Alternating repeated controls expose some
drift but cannot eliminate it. All slow samples remain included. The native
benchmark records a 120 Hz-capable screen at 2× scale; delivered cadence is separate.

## Direct native accessibility attributes

The optional `tile-prefetch-async-surface-properties` variant supplies the same
NSAccessibilityElement attributes from its native subclass fields instead of
duplicating label, role, parent and frame storage through framework setters.
It preserves ordering, identity, activation, screen/parent coordinates and
retirement. Apple's [NSAccessibilityProtocol guidance](https://developer.apple.com/documentation/appkit/nsaccessibilityprotocol)
supports overriding native accessibility getters.

Both policies passed the existing accessibility oracle at 100/300 events/day
(230,579/690,239 checks respectively) and all four native navigation cases passed
44 checks each. `properties-correctness/` retains these results. Twelve complete
paired native cases are in `native-surface-properties/`; pooled maxima are in
`native-surface-properties-pooled.json`. Some measured main sections still exceed
8.3 ms, so this remains an experimental candidate and all full gates still fail.

At 100/day the attribute variant changes worst response 30.19→28.37 ms and largest
main section 5.79→4.56 ms. At 300/day response changes 52.04→42.09 ms, but largest
main section worsens 8.13→9.05 ms and cold mount worsens 101.91→104.59 ms. This is
a mixed result, not a blanket performance improvement or adoption recommendation.

## Additional native presentation-policy exploration

Apple's [UIUpdateLink](https://developer.apple.com/documentation/UIKit/UIUpdateLink)
can express a frame-rate preference and request immediate presentation. The latter
may reduce pipeline latency but can be denied and can introduce judder if render
work is too large; see [wantsImmediatePresentation](https://developer.apple.com/documentation/uikit/uiupdatelink/wantsimmediatepresentation).
The separate low-latency event-dispatch option applies to Pencil events, not ordinary
scrolling, and is deliberately not enabled here.

New opt-in `--presentation-policy system|immediate|prefer120` touch probes use a
native link associated with the scroll view. Each policy leaves continuous updates
disabled; the system control creates the same passive link. These preferences are
requests, not measured display delivery. They have not yet been compiled or measured
at this checkpoint and are not enabled in normal benchmark matrices. The touch
runner rejects retained binaries that do not advertise these policy capabilities.

## Full UIKit accessibility-client enumeration

The separate 12-case physical matrix explicitly materializes and validates every
visible accessibility element inside each timed phase. All workload/coverage/host
checks completed; every full gate still fails. At 300 events/day lazy enumeration
remains over the main-thread budget, despite lower cost than eager publication.
See `physical-surface-accessibility-client/` and its pooled maxima file. The cheaper
no-client path must not be substituted for this workload or described as universal
accessibility performance. Neither enumeration oracle establishes VoiceOver focus
behavior.

## Physical iPhone storage-only comparison

Twelve further cases hold accessibility eager and compare only CGImage versus
CVPixelBuffer with two foreground workers. Same signed binary and unchanged
workload/coverage gates; no original phase omitted. Raw cases and pooled response,
main-section and memory maxima are in `physical-surface-storage/` and
`physical-surface-storage-pooled.json`. iPhone results are mixed; the large native
desktop publication win must not be generalized to UIKit. All full gates still fail.

The final physical storage comparison does **not** support adopting CVPixelBuffer
on iPhone. At 100/day, worst foreground response changes 49.57→53.22 ms; peak RSS
45.69→112.61 MiB and maximum sampled footprint 24.02→82.13 MiB. At 300/day response
changes 86.35→94.34 ms, RSS 56.50→129.53 MiB and sampled footprint 23.61→94.33 MiB.
Largest main sections improve only 7.02→6.96 and 16.73→16.13 ms. Footprint samples
are not true peaks. This reverses the desktop memory result: keep the UIKit
CGImage control as the candidate for further presentation experiments.

## CGImage real-swipe control

The matched-policy CGImage/lazy 300-event touch sequence passed and produced a
valid trace attributed to PID 11740. Its 631 app updates have p95 0.865 ms and
maximum 7.778 ms. Associated render intervals have p95 9.610 ms and maximum
10.811 ms; 164 exceed 8.3 ms. Matching GPU intervals have p95 1.532 ms and maximum
1.775 ms. No hitch rows were emitted, and full input-to-visible latency remains
unmeasured. This single later trace does not establish a statistically reliable
CV-versus-CG rendering improvement. Sanitized evidence is in `physical-cg-swipe/`.

The initial presentation-policy build succeeded, but its real touch test failed
because the app trapped inside UIKit: assigning `requiresContinuousUpdates`, even
`false`, to a UIUpdateLink without an associated action triggers an assertion on
this device. Failure bundle: `.build/calendar-touch/presentation-policy-build-and-control/ui.xcresult`;
crash: `.build/calendar-touch/presentation-policy-crash.ips`. All matched policies
now attach the same no-op action. The original failure remains retained.

The corrected presentation-policy control compiled and passed the full physical
touch sequence at 300 events/day. Binary SHA256:
`885e75f15daa0cd5a31b2235101778e4947052a09a9f5306b91a2302be76285c`.
Evidence: `.build/calendar-touch/presentation-policy-control-v2/ui.xcresult`.
The retained failure above was corrected before policy timing comparisons.

All three corrected presentation policies passed physical touch correctness.
System control: render p95/max 9.630/11.115 ms (150/632 over 8.3 ms). Immediate:
9.643/10.613 ms (173/681 over), with essentially unchanged frame lifetimes.
This single matched comparison shows no useful immediate-presentation benefit.

The 120 Hz-preference capture is **invalid/unmeasured** because one of 669 app
updates lacks a matching GPU row (at 2.649 s, not merely the recording endpoint).
The parser correctly rejected it; no coverage requirement was relaxed. Its complete
render rows still contain 102 overruns and a maximum of 11.620 ms, so there is no
observed all-target pass hidden by the coverage failure. The incomplete GPU sample
set must not be accepted as a complete device comparison. Sanitized statuses and
analyses are in `presentation-policies/`; raw traces remain local. All policies
remain opt-in and disabled by default.

## Visible native Mac interaction comparison

The same signed wrapper binary was launched in two fresh processes on the 120 Hz
capable 2× display at 100 events/day. Both runs visibly completed four forward
pages, two 0.75-page down/up scroll pairs, four returns, clear cache, next and
previous. Dates advanced/reversed correctly and ended on October 8. Native CUA
accessibility reads occurred between actions in both runs; they can add overhead.

| Policy | Commit count | Commit p95 | Commit max | Run-loop busy max |
| --- | ---: | ---: | ---: | ---: |
| CGImage | 183 | 3.159 ms | 20.786 ms | 101.537 ms |
| CVPixelBuffer | 250 | 2.799 ms | 3.105 ms | 101.585 ms |

This supports the measured desktop publication improvement under visible
interaction. Commit counts differ because the instrument records commits rather
than one sample per action; p95 includes idle/other commits. This is a single
paired sequence, not a calibrated distribution or input-to-visible acceptance.
The long run-loop intervals remain unresolved. GPU/display delivery and precise
input correlation remain unmeasured. All raw local traces and failures remain
retained; sanitized tables, metadata and summaries are in `visible-native-traces/`.

### Nested run-loop interpretation correction

Inspection of the 101.585 ms parent Busy interval found nested
`NSEventTrackingRunLoopMode` iterations, including 56.536 and 27.159 ms explicit
waiting intervals. Native button tracking keeps its parent run loop entered while
waiting for release; the inclusive duration is not 101 ms of uninterrupted work.
The original raw metrics remain intact. A new diagnostic subtracts the union of
explicit nested run-loop waits while retaining all other elapsed time, including
preemption and synchronous blocking. It does not claim CPU execution time.
Remaining maximum non-waiting spans are 32.888 ms (CGImage) and 47.396 ms (surface),
so both still contain significant active/wall-time intervals to investigate.
The persistent native trace gate now flags those spans independently of commits;
it does not loosen the 8.3 ms budget or convert either run into a pass. Synthetic
regression tests cover nesting, overlapping waits, unrelated threads and slow work.

## iPhone and iPad Simulator follow-up

The new Release build completed on both dedicated iOS 26.5 Simulators. Each
platform passed eight navigation/cancellation cases (44 checks each; 704 checks
combined) and completed twelve paired foreground storage cases with valid
coverage. Every full timing gate still fails. Raw cases, binary identities,
commands and host monitors are in `simulator-surfaces/`; pooled maxima are in
`simulator-surfaces-pooled.json`. Simulator results are regression/correctness
evidence only and do not establish 120 Hz or physical input/display latency.
Physical iPad evidence remains blocked by its passcode; no new unlock request
was repeated.

## Cache recovery: main-thread improvement, cold completion failures

The Mac prototype's Clear cache button still called the synchronous renderer even
when normal paging used background preparation. `--async-cache-recovery` routes
only that interactive action through the existing bounded two-worker path. The
original synchronous benchmark phases remain unchanged. Old pixels, heading and
viewport stay coherent until replacement; obsolete recovery is cancelled when
navigation changes. No persistence or user data is involved.

Four initial control/variant cases passed 76 checks. The subsequent executor build
passed eight recovery/navigation cases: 19 recovery or 44 navigation checks per
case, 252 total. `recovery-checks/` retains results and exact commands.

`run-mac-recovery.py` is the persistent paired component collector: three
alternating trials, 100/300 events per day over 365 days, 21 recoveries per case.
Every sample evicts the cache, includes awaited preparation and API flush, verifies
complete pixels/IDs, rejects accidental synchronous fallback, and records memory.
It never claims display completion. All original cold/warm/eviction scenarios in
the broader collectors remain intact.

| Events/day | Recovery | Worst response | Worst action handler |
| --- | --- | ---: | ---: |
| 100 | Synchronous | 38.84 ms | 38.09 ms |
| 100 | Asynchronous | 71.95 ms | 1.09 ms |
| 300 | Synchronous | 64.91 ms | 64.16 ms |
| 300 | Asynchronous | **135.00 ms** | 1.37 ms |

Moving work off the action handler is measured, but completion is not uniformly
faster. Two dense first-recovery samples were 135.00 and 131.60 ms. They remain
hard failures; warm medians around 20/36 ms do not excuse them. Raw samples,
footprints, checks and host monitors are in `native-recovery-components/`.

Three visible native 100/day sequences each performed six Clear cache → Next →
Previous triplets using the same signed binary and UI automation recipe:

| Policy | Commit p95 / max | Longest run-loop span excluding explicit nested waits |
| --- | ---: | ---: |
| Synchronous recovery | 3.002 / 3.636 ms | 43.001 ms |
| Asynchronous recovery | 2.946 / 3.541 ms | 41.500 ms |
| Async + direct accessibility properties | 3.261 / 4.539 ms | 42.493 ms |

There is no useful reduction in the worst whole-interaction span in this sample.
CUA reads the accessibility hierarchy between actions; that work is included.
The complete standalone Time Profiler recording of async recovery has no sampled
main-thread RasterPage drawing, with much of the remaining work in AppKit and
accessibility. This is CPU diagnosis, not input latency. The initial combined
Logging/Commits/Run Loops/Time Profiler recording failed internally with a
`tagged-backtrace`/`backtrace` type mismatch. It remains at
`.build/calendar-async-preparation/native-recovery-control-profile`; its partial
samples are not a complete timing comparison. Reliable UI records and metadata
are in `recovery-interaction/`; standalone raw CPU traces stay in `.build`.

## Foreground executor ablation

Apple recommends bridging potentially blocking synchronous work through Dispatch
when needed rather than blocking Swift's cooperative executor
([WWDC22](https://developer.apple.com/videos/play/wwdc2022/110350/)). This is a
hypothesis for the cold tail, not proof of executor starvation. The opt-in
`--foreground-dispatch` experiment uses two serial native Dispatch queues at
user-initiated priority, preserving the same tiles, workload, cache, ordering and
complete-publication rule. Each request has a cancellation token checked during
rasterization. Queues bound concurrent raster jobs; continuations resume even
when cancelled, and stale generations cannot publish.

The same binary ran a three-trial alternating comparison with asynchronous
recovery held fixed. At 100/day, worst response was 115.13 ms cooperative versus
45.48 ms Dispatch. At 300/day, 91.12 versus 97.10 ms. This is mixed evidence:
Dispatch avoids the observed 100/day outlier in this run but is not a consistent
speedup, and does not reach the preferred 32 ms cold response. No default changes.
All 252 samples and memory costs are in `native-recovery-executors/`. Every case
has valid coverage. The full gate still cannot pass without actual display/input
evidence; the cooperative outlier is retained as a hard failure.

Exact-pixel/eviction/cancellation tests pass 1,106 checks at each density for
Dispatch, including supersession and bounded cache behavior. Both Python suites
pass 30 tests each. The dispatch oracle is now a persistent CI scenario, alongside
the existing cooperative scenario. No baseline or budget was changed.

The separate `wantsLowLatencyEventDispatch` option was researched and deliberately
not treated as a scroll optimization: Apple's documentation says only Pencil
events are eligible ([API scope](https://developer.apple.com/documentation/uikit/uiupdatelink/wantslowlatencyeventdispatch)).
It would not establish lower latency for ordinary finger scrolling or mouse input.

## Native mouse/wheel tests at 300 events/day

The new persistent `CalendarPrototypeInteractionTests` attaches only to the live
isolated renderer. Both six-triplet cache-recovery/paging and twelve-gesture wheel
scenarios passed for the standard and direct-accessibility-property policies.
The scrolling-only diagnostic test also passed. Result bundles are in
`.build/native-ui-performance/calendar-prototype-20261009/` (cooperative-ui,
properties-ui, and wheel-profile-ui `.xcresult` files).

Matched 100-second native traces used the same signed binary. Standard properties:
453 commits, p95/max 1.665/4.073 ms, longest non-waiting main-loop span 89.067 ms.
Direct properties: 495 commits, p95/max 1.634/3.054 ms, span 81.971 ms. This is not
a sufficient whole-interaction improvement or an input-latency pass. The trace
host monitor records the intentional `xcodebuild test-without-building` input
driver; it is not marked clean, and no host rule was relaxed. Percentiles include
idle/other commits; observed maxima and all raw samples are retained.

The separate complete wheel-only CPU recording contains no sampled main-thread
RasterPage rendering. Accessibility queries are prominent, especially the parent
getter. This does not support adding more scroll prefetch to address this specific
recording. It also does not prove every possible cold/high-velocity scroll is
free of tile misses. Sanitized metrics, CPU sample counts and test logs are in
`native-xctest/`. GPU delivery and input-to-visible latency remain unmeasured.

The persistent full-app component suite was rebuilt and rerun, with all eight
scenarios passing baseline version 1 unchanged. Raw build and collection artifacts:
`.build/performance-regression/calendar-recovery-followup-20261009`; compact
measurements/gate are retained in `app-regression-followup/`. This remains
Simulator component evidence, not a native or 120 Hz acceptance result.

The physical iPad was rechecked at 07:38 EDT and still requires its passcode.
No physical iPad acceptance result is claimed; the lock-state result is retained.

## Native Core Text combined with asynchronous surface publication

`--raster-native-text` composes the already pixel-validated native CTLineDraw path
with two-worker asynchronous recovery and CVPixelBuffer storage. It avoids copying
glyph, position and ink-bound arrays that never leave the raster worker. The
matched control keeps prepared-glyph drawing; other policies and workloads stay
fixed. Reproduce with `run-mac-recovery.py --comparison native-text`.

Across three alternating pairs, 300/day medians changed 36.20–37.09 → 31.73–33.00 ms.
P95 changed 40.97–53.88 → 34.09–42.76 ms, and pooled maxima 67.37 → 50.16 ms. This
supports a modest dense-recovery improvement in this sample. At 100/day medians
also improve, 19.94–20.78 → 18.42–18.52 ms, but worst response worsens 51.56 →
74.48 ms. One 100/day native-text process also reports a 93.25 MiB maximum sampled
footprint versus 73.97–79.97 MiB across controls. Retain these costs; do not claim a
universal improvement or a fix for the earlier cold >100 ms failures.

All twelve cases have valid coverage and all their measured main sections are
below 1.28 ms. These API measurements still do not establish visible response or
frame delivery. Four paired exact-pixel/cancellation/cache checks pass 4,424
assertions and retain cold, warm and eviction timing samples at 100/300 events/day.
The combined native-text surface oracle is included in CI. The benchmark Python
suite now passes 31 tests, including rejection of incorrect executor/text flags.
Raw paired cases and memory are in `native-recovery-text-composition/`; correctness
and commands are in `recovery-checks/`. The flag is disabled by default; no baseline
was updated and no production renderer was replaced.

## Final physical capture and attribution limits

The repeated `prefer120` iPhone touch scenario passed functional XCTest, but
Instruments crashed with SIGSEGV (exit -11) while finishing its eight-second
recording. The run is **failed/unmeasured**, not a second valid comparison.
Its statuses remain in `presentation-policies/prefer120-repeat/`; the partial
trace and XCTest bundle remain under the matching `.build/calendar-touch/` path.
A separate Mac build began around this capture's completion, so this run also
cannot establish a clean repeated hardware comparison. The earlier incomplete
GPU-row capture remains retained separately.

In the complete system-policy trace, matched compositor render intervals can
extend beyond the end of their GPU intervals. For example, swap 3233082 has an
11.115 ms render interval, while its matched GPU work runs from 3.818 to 4.985 ms
relative to that interval's start. Swaps 3233134 and 3233430 similarly have
10.365/10.245 ms render intervals with GPU completion at 2.628/4.113 ms. Matching
uses display, swap ID and surface ID. These observations do not prove the
remaining time is idle or identify it entirely as CPU rendering. CPU, GPU,
synchronization and presentation attribution needs further tracing; subtracting
GPU duration would not produce a trustworthy CPU measurement. Apple's
[render-pipeline explanation](https://developer.apple.com/documentation/xcode/understanding-hitches-in-your-app)
describes overlapping work across these stages. The existing conservative
8.3 ms interval failures, raw samples and gate are unchanged.

Actual input-to-visible latency remains unmeasured. Physical iPad testing remains
pending while locked, as requested. No claim of full performance acceptance is
supported by the successful functional tests or component suite.

## Latest-source platform correctness

Final Release builds succeeded for iOS Simulator and the physical iPhone. The
navigation/cancellation/eviction oracle passed all 44 assertions in each of eight
cases on iPhone Simulator, iPad Simulator and the unlocked physical iPhone:
100/300 events per day, each with control, Dispatch, native text, and both options
together. That is 1,056 assertions across 24 cases. These are programmatic
correctness checks, not touch/display timing or physical iPad evidence. The
Simulator checks ran without opening Simulator or driving the Mac desktop.

`final-validation/` retains source hashes, binary identities, commands, raw
reports, build statuses and collection scripts. The earlier physical timing
captures used the earlier retained binary and are not relabeled as measurements
of this latest build. The final Python checks pass 30 root-tool and 31 benchmark
tests (32 benchmark tests after adding the combined-policy validation). All
existing budgets and baseline version 1 remain unchanged.

## Combined executor/text interaction

`run-mac-recovery.py --comparison combined` retains another twelve valid cases,
three alternating paired trials per density with 21 recovery samples each.
At 100/day, combined Dispatch/native text changes medians from 19.76–20.36 to
18.59–18.98 ms and pooled maximum from 78.86 to 47.78 ms. At 300/day, medians
change from 36.43–37.75 to 32.15–34.11 ms, but pooled maximum worsens from
65.16 to **89.55 ms**. One 100/day combined process also reaches 89.69 MiB sampled
footprint versus 74.30–75.27 MiB for controls. These mixed results do not justify
enabling both options by default or attributing an additive gain to Dispatch.

All host monitors report clean for this comparison. Raw samples and memory are
in `native-recovery-combined/`. Component hard limits pass within this specific
matrix, while the collector correctly exits 2 for unmeasured full UI acceptance.
Earlier >100 ms failures remain failures; this matrix does not replace them.

The combined native controller checks pass 126 assertions, and the paired
100/300-day-density pixel/cancellation/cache oracle passes another 2,212. These
results and their invocation are retained in `combined-correctness/`. The dense
combined oracle is also a persistent CI scenario. This correctness evidence does
not change the performance decision above.

## Remaining acceptance work

- Correlate real input delivery with the first correct displayed result on the
  Mac and physical 120 Hz iPhone; retain separate CPU, GPU and display intervals.
  The native wheel test currently checks completion, heading and event presence,
  with a retained screenshot. It does not assert every intermediate viewport or
  measure input latency.
- Attribute the native 82–89 ms non-waiting main-loop spans with instrumentation
  that separates application work from accessibility/test-driver activity. A
  successful button test or a short layer commit is insufficient.
- Reduce cold/eviction completion tails, including retained 132–135 ms recovery
  failures, without increasing memory or hiding work behind an early indicator.
- Validate physical iPad behavior when unlocked and repeat platform-specific
  VoiceOver and display-delivery checks before adoption.
- Integrate only a verified candidate into the shipping calendar with feature
  parity and rerun its full workload. The prototype's results do not repair the
  previously failing shipping SwiftUI calendar traces.

Baseline reduction remains a separate review: the Mac surface publication
improvement is a candidate for a tighter component reference, but this report
does not silently create one or relax any whole-interaction requirement.

### Wheel trace attribution follow-up

The separate wheel-only Time Profiler recording has 469 main-thread samples.
242 stacks contain XCTest query/runtime frames, 280 contain accessibility frames,
and 175 belong to both groups. The native accessibility-parent getter appears in
63 samples, 18 of which also contain XCTest frames. These are overlapping sampled
categories, not additive timing totals. No sampled stack contains RasterPage.render.
The extractor and per-sample categories are retained in `native-xctest/`.

This confirms substantial test/accessibility activity in that diagnostic sample,
but it does not assign the 82–89 ms spans from separate recordings to XCTest or
prove ordinary interaction is fast. A visible interaction capture with less
automation activity is the next attribution check. Keep real accessibility use
in acceptance coverage; removing accessibility to improve a score is not a fix.

### Fresh-process combined-policy check

The last twelve-case comparison mounts a fresh controller in each process, with
two foreground workers in both policies. Three alternating control/combined
pairs at each density retain fixture generation separately and include controller
setup in API-completion timing. At 100/day, control responses are
65.16/72.58/66.69 ms versus combined 67.61/59.24/68.48 ms. At 300/day, control is
**113.00/116.31/217.66 ms** versus combined **89.64/89.99/103.73 ms**. Thus the
combination still has a >100 ms hard failure, and all three dense controls fail.
These failures cannot be replaced by the faster recovery results above.

Main-thread controller setup ranges from 25.07 to 29.92 ms, exceeding 8.3 ms in
every case. All twelve have valid content and clean host-monitor reports. Sampled
physical footprint is 42.56–52.39 MiB for controls and 43.28–49.49 MiB combined;
raw peak RSS is retained too. `combined-cold-mount/` includes reports, identity,
host monitoring and the exact collector. These are component timings, not
launch-to-visible measurements. No default or baseline changes are justified.

The final harness review also hardened `run-mac-mount.py`: non-finite, negative,
missing or contradictory timing fields now invalidate a report instead of being
labeled within component limits. Four focused failure-behavior tests cover this;
the benchmark Python suite now passes 36 tests. A read-only integrity check of all
24 retained mount reports passes without changing any samples or verdicts. Its
result is in `final-validation/mount-timing-integrity.json`.
