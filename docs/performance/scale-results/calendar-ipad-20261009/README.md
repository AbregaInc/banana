# Physical iPad follow-up — October 9, 2026

**Scope correction following user review:** these measurements use the original
uniform fixture. It repeats daily timing/overlap patterns, has unique event IDs
and dates, and has no calendar identity or varied calendar colors. Raster keys
include dates, so this is not evidence of one cached week being reused for every
week. It is nevertheless insufficient evidence of representative calendar
performance or supported daily/weekly capacity. A separate varied multi-calendar
fixture is being validated; these results remain as the frozen control.

The user unlocked the previously blocked iPad. These results exercise the isolated
calendar prototype on the physical iPad13,8 running iPadOS 27.0.1, with a 1366 ×
1024 point screen at 2× scale and maximum refresh capability of 120 Hz. Capability
is recorded separately from measured display cadence. The fixture retains 365
days at 100 or 300 events/day (36,500 or 109,500 events). It does not include the
shipping app's data stores, mail, sync or complete feature set.

Build identity and source commit are in `environment.json`. Local build, XCTest
bundles and Instruments traces are under `.build/calendar-ipad-20261009/`. Raw
traces remain local because Instruments may include unrelated process environment
data. Retained summaries contain only the inspected measurements and test results.
No renderer default, workload, latency budget or regression baseline is changed.

## Real touch checks and first trace

Both 100/day and 300/day passed the physical XCTest sequence: four forward pages,
four up/down swipe pairs, cache eviction and four reverse pages restoring the
original date. The policy was CGImage tiles with asynchronous foreground preparation
and lazy UIKit accessibility (`tile-prefetch-async-lazy`, two workers). The test's
automation timeouts and gesture wall clock are not performance measurements.

The 300/day run also captured an eight-second Animation Hitches trace. Recording,
all nine selected table exports and app/process attribution completed successfully.
It overlaps only part of the real swipe sequence. The retained analysis reports:

| Interval | Samples | p95 | Maximum | Over 8.3 ms |
| --- | ---: | ---: | ---: | ---: |
| App update | 631 | 0.828 ms | 4.259 ms | 0 |
| Matched compositor render | 635 | 4.635 ms | 9.720 ms | 1 |
| Matched GPU | 631 | 1.592 ms | 2.068 ms | 0 |

The strict interval gate **fails** on the 9.720 ms render interval even though
Instruments records zero app hitch rows. Display-wide cadence is variable: most
recorded intervals are around 8.34 ms, with longer intervals also retained. Neither
the cadence histogram nor the absence of reported hitches establishes app delivery
at 120 Hz or direct-input acceptance.

The overrun starts about 330 ms into the trace. Its matched app update takes
0.444 ms, beginning 7.259 ms before the render interval; matched GPU work runs from
2.275 to 4.343 ms relative to render start. The remaining render interval cannot
simply be labeled CPU execution or idle time. Full frame lifetimes describe a
pipelined render loop and are not single-frame CPU work. No app-attributed HID
timestamp or complete input-to-visible measurement was collected.

The trace and touch summaries are retained in `touch-profile-300/`; the independent
100/day correctness result is in `touch-100/`. Screenshot attachments remain in
their local XCTest bundles. These tests do not establish VoiceOver focus behavior
or correctness of every intermediate scroll viewport.

## Interrupted component follow-up

The twelve-case storage matrix completed with content coverage, but its whole-run
host monitor detected unrelated xcodebuild/XCTest/compiler work beginning during
collection. Treat it as **contended evidence**, not a quiet performance comparison.
The following accessibility matrix was interrupted when this contention and the
fixture realism issue were identified. Completed samples and all pending or
interrupted cases remain in their summaries. No slow run was discarded.

`foreground-surface/`, `foreground-accessibility/`, both host-monitor files and
`matrix-status.json` preserve the collected evidence. All failures remain in
scope. No adoption decision or performance baseline is based on these runs.
