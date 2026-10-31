# Mobile Day/Week neighbor preparation — October 10, 2026

The production grids scanned all placements twice per event, allocating filtered
arrays and repeatedly projecting dates through Calendar. The new immutable layout
snapshot prepares dates, lane spans and projected tops once, then computes the same
neighbors without temporary filtered arrays. This uses the existing native Swift
arrays/dictionaries; it adds no third-party dependency or cross-update cache.

The pair scan remains O(N²). This is a measured reduction in repeated work, not a
claim that arbitrary density is solved or that an interval index is unnecessary.
The DEBUG `--calendar-reference-neighbors` control keeps the prior app paths. Both
native Day cells and the shared SwiftUI Day/Week grid use the prepared results by
default. Calendar lane assignment, minimum widths, travel bands, event content and
move persistence are unchanged. Mac and Agenda do not use these mobile helpers.
The work remains on the main thread and allocates per-update arrays/dictionaries;
this is not a zero-allocation renderer or a move of layout onto the GPU.

## Exact parity and component measurements

444 checks compare the production helper with independently frozen old scans.
They cover different widths/zooms, lane counts, strict later-start filtering, five-
minute joining, optimistic moves, clipping and DST. In particular, minimum screen Y
cannot be replaced by earliest Date during a repeated hour. CI retains these checks.

The final monitored matrix alternates both policies 12 times at four densities,
using the unchanged uniform and varied fixture generators. The varied samples use
the busiest generated day and include overnight carry-in. Full raw timings, maxima
and actual counts are retained. The first exploratory matrix is retained separately.

Fresh processes use reference/prepared/prepared/reference, with a first neighbor
invocation followed by 12 repeats. Fixture/lane construction precedes these timings;
this is not cold app launch. There is no persistent neighbor cache to evict. The
monitor detected no competing developer process or sampling error during collection;
that does not prove zero system contention.

| Mean events/day | Actual visible count | Policy | First ms | Repeated median ms | Max ms | Process peak MiB |
| --- | --- | --- | --- | --- | --- | --- |
| 100 | 187 | reference | 1.329 | 1.287 | 1.329 | 8.75 |
| 100 | 187 | prepared | 0.351 | 0.305 | 0.351 | 8.61 |
| 100 | 187 | prepared | 0.350 | 0.305 | 0.350 | 8.61 |
| 100 | 187 | reference | 1.357 | 1.289 | 1.357 | 8.73 |
| 300 | 570 | reference | 9.422 | 9.361 | 9.664 | 9.12 |
| 300 | 570 | prepared | 2.066 | 2.001 | 2.066 | 9.05 |
| 300 | 570 | prepared | 2.056 | 2.014 | 2.106 | 9.05 |
| 300 | 570 | reference | 9.410 | 9.436 | 9.695 | 9.14 |
| 1000 | 1900 | reference | 99.247 | 96.577 | 99.247 | 10.58 |
| 1000 | 1900 | prepared | 20.477 | 19.647 | 20.477 | 10.23 |
| 1000 | 1900 | prepared | 20.053 | 19.486 | 20.432 | 10.47 |
| 1000 | 1900 | reference | 97.444 | 98.366 | 99.944 | 10.80 |

The prepared 1000/day case still takes about 20 ms in this component alone. It
does not meet the frame target and cannot support an app capacity claim. The
lower-density gains do not prove whole-frame or input-to-visible compliance.
Array strides in the reports exclude dictionary/String allocation; process peaks
above include fixture setup and are not incremental bytes retained by the helper.

## App validation

All 14 calendar UI tests passed with zero skips: four old/new/new/old varied native
Day scroll/open/page cases, seven targeted iPhone interaction cases, and three iPad
cases. Targeted coverage includes Week old/new, reference Day host, native paging/
zoom, prepared Day artwork, and overnight/durable move recovery. This is functional
Simulator evidence, not physical frame or input acceptance.

Steady app physical-memory medians (kB) across the four matched Day runs were
195398.128, 195398.128, 194415.088, 195480.048. There is no clear app-memory increase
or compelling memory-saving claim. All raw automation/scroll-duration samples remain
retained; they are not interpreted as interaction response times.

The full eight-case component suite **failed baseline comparison** on one metric:
Plan-route Notes search p95 65.746 ms versus 19.235 + 2.885 ms allowed. Its seven
samples were 65.746, 17.870, 17.786, 17.482, 17.524, 17.972, 17.776 ms. Plan redraws
were zero; the failure is a first-search tail, not a redraw-loop measurement. The
host monitor had no competing developer jobs but high load; that is insufficient
to assign the cause. The failed original run remains authoritative and retained.

A same-build old/new/new/old Plan workload, with per-sample process diagnostics,
then gave first Notes-search times 52.312, 50.433, 18.308, 17.419 ms. Both policies
reproduced the slow first query and both later completed without it. The first two
recorded 282 voluntary context switches and 28.344/26.046 ms process CPU; subsequent
fast first queries recorded zero voluntary switches and approximately 18.308/17.508
ms CPU. This establishes that the neighbor optimization is not required to reproduce
the slow search. It does not identify the underlying wait or prove absence of every
possible interaction. Process CPU is not main-thread CPU. Diagnostic instrumentation
is separate from the original unchanged suite; passing absolute 100 ms component
budgets does not turn the failed baseline gate green. Root-cause work remains open.

The failing database and all four diagnostic databases were copied and hashed before
cleanup; original integrity check returned `ok`. Raw artifacts and database copies
are under `.build/calendar-neighbors-20261010/`. The owned Simulators were shut down,
and 29 temporary fixtures (4.121 GiB logical) removed. Reports, failed evidence,
workspaces and worktrees were preserved. Thirty-eight Python harness tests passed.

Source hashes stayed unchanged through the app test sequence and component rebuild.
The later app executable hash differs from the initial identity; both are retained,
and no bit-identical claim is made across those phases. No Mac window or physical
mobile UI was driven. The pure optimized helper/oracle compiled and ran on macOS.

## Baseline proposal

After reviewing repeated dedicated-host evidence, add a platform-specific neighbor
preparation reference near the measured prepared 100/day median (about 0.305 ms),
rather than allowing the old approximately 1.29 ms cost to return unnoticed. That
would be a separate reviewed gate extension; no existing baseline or tolerance was
automatically changed here. Physical display/input acceptance remains required.
