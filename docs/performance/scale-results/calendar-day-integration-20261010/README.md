# Calendar Day and independent artwork-height integration

The prepared artwork remains opt-in (`--calendar-prepared-artwork`). This is an
intermediate production-data integration, not the completed native viewport or
120 Hz acceptance. Email is unchanged.

## Corrected coverage finding

The initial Day pair returned two XCTest passes ([retained summary](day-before-height-summary.json)),
but these **do not establish Day coverage**. Subsequent Agenda screenshots show
List selected above Week content. The harness launched with `-planMode week`,
which places the value in NSArgumentDomain and overrides later persisted writes.
A [standalone defaults probe](defaults-probe.txt) reproduces `week` after persisting
`list`. Thus the earlier inference that native Day visibility was verified was
incorrect. Fresh-process Day profiling below uses `-planMode day` and is unaffected
by this specific switching error, but remains API-only evidence.

The first independent-height app run returned two passes and one failure. Its
prepared “Agenda” case tapped an element labelled Stress event 2 and displayed
Stress event 5; screenshots show it was still Week. This is not Agenda parity
coverage. The selection mismatch is retained and not declared resolved. Artifacts:
`.build/calendar-day-integration-20261010/height-ui.xcresult` and `height-ui-all/`.

Protocol 3 seeds the real persisted mode via an explicit Simulator-only stress
launch environment value instead of an overriding argument. It requires the
actual Day/Week/Agenda content identifier, not just the picker highlight, and
records the selected label/frame and before/after accessibility trees. Validation
of this corrected protocol is pending.

## Fresh-process diagnostic

`tools/calendar-artwork-tests/profile-app.py --device FIXTURE_SIMULATOR --out NEW_PATH`
collects three alternating Day/Week fresh-process launches with the unchanged
30-day stress fixture. In-app timing is explicitly enabled, bounded to 4,096
samples, and truncation or unfinished work fails collection. Normal launches do
not collect timings. Source reports, RSS samples, commands and host monitoring
are retained in `.build/calendar-day-integration-20261010/app-profile/`.

[All preparation samples and binary/device identity](app-preparation.json):

| Launch | Preparations | p95 ms | Maximum ms | Peak sampled RSS MiB |
| --- | ---: | ---: | ---: | ---: |
| 0 Day | 106 | 1.235 | 2.732 | 466.2 |
| 0 Week | 83 | 1.450 | 2.850 | 500.0 |
| 1 Week | 82 | 1.446 | 2.562 | 499.8 |
| 1 Day | 105 | 0.939 | 2.856 | 466.2 |
| 2 Day | 105 | 1.000 | 2.434 | 466.0 |
| 2 Week | 82 | 1.436 | 2.676 | 499.8 |

All six redraw probes passed. Cache pixels were 3.46–4.37 MB and consumer-accounted
pixels 2.65–2.89 MB, each within its separate 32 MiB limit. These byte counts can
overlap for shared images; they are not total-memory estimates. Host/app RSS and
compositor ownership are separate. The fixture remains uniform, so varied-calendar
app integration is still required.

These timings cover individual main-actor cache misses after key validation,
including rasterization and cache insertion. They exclude queue delay, layout,
first usable screen, frames and input-to-visible response. Multiple preparations
can accumulate in one frame. No UI budget pass follows from this table.
The [49-check instrumentation run](instrumentation-overhead.json) retains its
alternating enabled/disabled overhead comparison (medians 0.924/0.911 ms).
The six app launches precede the independent-height implementation below.

## Independent text threshold and canvas geometry

The legacy Agenda grid selects compact text using a 24-point height while its
actual frame reflects duration. Previously the prepared wrapper fell back whenever
these heights differed. Cache requests now preserve both dimensions, use the
original text threshold for drawing, and use the canvas dimensions for allocation.
The coordinator carries the threshold through both queued rendering and warm
lookup. Height changes invalidate the image; invalid heights are rejected.

[71 cache/pixel checks](height-cache-report.json) include exact frozen-reference
comparisons of both layout branches at 21/40/90-point canvases with the original
24-point text threshold, warm identity, threshold invalidation and invalid geometry.
The frozen reference is unchanged. Existing cold/warm/eviction and color ablations
remain, alongside 201 alternating samples each for uncached/cached Agenda artwork:
0.745/0.0095 ms median, 1.715/0.0533 ms maximum. This establishes lookup savings for
that component, not faster real scrolling. [210 coordinator lifecycle checks](preparation-height.json)
also pass. First-use and memory costs remain in the raw reports.

## Retained component failure and matched diagnosis

The [first full eight-case suite](component-first-measurements.json) failed its
[unchanged regression gate](component-first-gate.json): redraw-mail's first-page
p95 was 18.642 ms versus 12.830 + 2.000 ms allowed. Other seven cases passed; Mail's
redraw probe itself passed. Its seven samples are one cold scan of 60,000 fixture
threads followed by six sub-0.001 ms cached lookups. The p95 in this seven-sample
probe is the maximum. Source is `MailFixtureSource.snapshot`, which scans the
fixture dictionary and keeps a bounded top-row heap on a miss; no calendar cache
is invoked on the Mail route.

The previous passing app was recovered from the owned iPad Simulator's installation;
its SHA matches the archived prior identity (05e532ef…469179). An alternating
previous/candidate/candidate/previous comparison on the same iPhone Simulator,
with the same 30-day workload and 10-second redraw probe, measured cold first-page
12.258/12.444/12.649/12.402 ms ([all reports and host records](mail-comparison.json)).
This does not reproduce the original outlier or show a comparable sustained
slowdown. It does not establish why that individual sample was slow. No failed
sample is discarded, and no budget/baseline is changed. Original host monitoring
found no overlapping developer process, but does not exclude system contention.

The corrected build passes the [complete eight-case component gate](component-protocol3-gate.json)
([all measurements](component-protocol3-measurements.json)), baseline version 1 unchanged.
The original failed suite remains retained above. Corrected app interaction tests are running.
Native Mac visible checks, physical iPhone/iPad frame/input evidence, full viewport
reuse, all action/VoiceOver parity, varied app data and email remain outstanding.
No baseline or budget was changed.


## Protocol-3 Agenda diagnostic in progress

The corrected run observes `plan.surface.agenda`, and a Simulator screenshot
confirms the true seven-day Agenda rather than the Week grid. Its control test's
accessibility element queries take roughly 10–20 seconds each. Sampling app PID
49962 for two seconds captured 1,217 main-thread samples under
`XCTElementQuery → AXUIElementCopyMultipleAttributeValues → SwiftUI
AccessibilityCore.queryChildren → Array.sorted` (1,120 in the sorting subtree).
This locates the sampled bottleneck in automation-triggered accessibility tree
construction/sorting, not a demonstrated continuous redraw loop or measured
normal scrolling latency. A full core was observed during these queries.

Raw local evidence: `agenda-control-sample.txt`, `agenda-protocol3-current.png`,
and the ongoing `protocol3-ui.log` under the artifact directory. Protocol-3
interaction validation is still incomplete; no Agenda or native Day pass is claimed.
The earlier Week selection mismatch remains open. Full viewport integration and
physical acceptance continue after these correctness/accessibility issues.
