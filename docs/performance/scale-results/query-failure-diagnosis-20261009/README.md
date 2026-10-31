# Query tail-latency diagnosis — October 9, 2026

This investigates the failed background component suite at
`.build/xctest-unblock-20261009/monitor-v2/component-suite`. It tests notes search and
podcast model queries, not the experimental calendar renderer or physical UI latency.
Budgets, workloads, sample counts and historical failures are unchanged.

## What the original failure establishes

The 90-day case retained 90,000 notes and 900,000 episodes across 900 shows.
Notes search median/p95 was 47.62/125.38 ms; next-across-catalog 45.50/142.74 ms;
download candidates 60.49/172.08 ms. With seven calls, p95 is the observed maximum.
These are intermittent tails, not evidence that every call doubled in cost.

The resource watcher found load 6.21 before creating its Simulator. By the 90-day
launch, recorded load was 306.32. The case's developer-process monitor found no
Xcode/compiler overlap, but did not monitor CPU utilization, scheduling delays,
Simulator services or memory pressure. `clean: true` meant only that its narrow
check passed. The original collector discarded ordered samples and recorded no
per-call CPU counters. Exact attribution of each historical outlier is therefore
not recoverable from that run alone.

## Reproduction with preserved binaries

Artifacts and scripts: `.build/query-failure-diagnosis-20261009/`.
Three alternating-order trials compare the original uncached control, the prior
cached candidate and the exact binary from the failed suite. SHA-256 identities
match their retained reports. No source is rebuilt for this comparison. Each launch
regenerates the same full 90-day workload and measures seven calls per operation.
Orders: control/cached/failed, failed/cached/control, cached/control/failed.

The old control reproduced all three absolute failures: 160.12, 132.31 and 229.20 ms.
The prior cached binary also reproduced them in a later trial: 129.19, 158.40 and
185.89 ms. The exact failed binary's three repeated trials remained below 100 ms
for these operations, with observed maxima 52.27, 57.28 and 65.23 ms respectively.
Every failed run is retained. This rules out a failure requiring the latest binary
or the cached-statement change; it does not excuse observed stalls.

Across the three trials, median-of-run-medians for the original control versus
cached candidate were 53.72 → 47.48 ms for next-across-catalog and 67.05 → 62.04 ms
for download candidates. Notes were 51.77 → 49.43 ms despite no notes implementation
change. These results support the prior modest caching benefit but not elimination
of tail failures. The isolated first and later slow trials must not be averaged away.

The accompanying two-second process samples show Simulator startup creating over
200 runnable processes and substantial Simulator service CPU activity. A top sample
recorded 15.52% CPU idle, 14 GiB compressed memory and 465 MiB unused physical memory.
Load alone is not CPU utilization. This is evidence of environment activity, not
proof that a particular background process caused an individual historical sample.

## Added diagnostics

The debug-only collector now retains the seven ordered `samplesMS` values. The gate
checks that their count, median and maximum agree with the existing summary; older
references remain readable. An optional `--diagnostics` on `tools/scale-stress.py`
records per-call process CPU deltas, major page faults, context switches, uptime and
thermal state. Process CPU covers all app threads and is not thread-specific work.
Counter collection occurs outside the timed action but can still perturb execution;
same-binary instrumentation-off/on runs are retained separately.

The host monitor also retains a load time series, without reclassifying load as
CPU utilization or silently changing the gate. No baseline or tolerance is changed.
A controlled Simulator-boot ablation and the full persistent suite follow the
unchanged-binary comparison; their results will be recorded below.

## Controlled contention result

The diagnostics-off run and two diagnostics-on runs used the same rebuilt binary,
fresh full fixture processes and the same seven calls. Their tails remained below
100 ms. There was no material instrumentation-induced slowdown in these samples;
this is an overhead check, not a new performance baseline.

We then booted a separate, newly created disposable iPhone Simulator while running
the identical diagnostic binary/workload on the existing test Simulator. Two
predeclared runs were retained. The first rose moderately; the second reproduced
all three hard-limit failures:

| Operation | Settled diagnostic maxima (two runs) | Boot-contention maximum | Process CPU during slow sample | Involuntary context switches |
| --- | ---: | ---: | ---: | ---: |
| Notes search | 50.96 ms | 135.35 ms | 69.71 ms | 615 |
| Next across catalog | 49.70 ms | 290.70 ms | 102.56 ms | 91 |
| Download candidates | 60.75 ms | 343.19 ms | 135.63 ms | 249 |

All three slow samples were the first call of their respective metric. Subsequent
calls were much faster. The slow samples reported nominal thermal state and zero
major page faults; minor faults were not collected. Aggregate process CPU was far
below elapsed time, alongside increased involuntary context switches. This supports
significant non-executing time under contention; the difference is not an exact
scheduler-wait measure because CPU covers all app threads and I/O waits are not
separately attributed. Some CPU cost also increased, so this is not pure waiting.

This controlled intervention establishes Simulator background contention as a
**sufficient cause** of the same class of failures without changing app code or data.
It strongly supports that explanation for the earlier run's startup/load sequence,
but cannot identify the exact background process responsible for each historical
outlier. The extra Simulator was shut down and deleted before the recovery suite.
Both pass-like and failing ablation runs remain in the evidence.

## Actual application work remains

Even settled, notes search consumes roughly 47–51 ms of CPU and podcast catalog
operations roughly 45–61 ms. Code inspection shows notes search counts all matches
before fetching its page; the catalog metrics invoke per-show queries across 900
shows. These are real scaling costs with inadequate headroom for the preferred
32 ms UI goal. The contention diagnosis does not turn those costs into a solved
performance problem. No production query or renderer optimization is made in this
investigation; changes improve evidence collection and summary integrity only.

Future idle-run setup must boot the fixture Simulator before assessing readiness,
record conditions during the calls, and retain a matched control when investigating
a regression. A pre-boot quiet check and absence of compiler jobs are insufficient.


## Recovery and verification

After removing the additional Simulator, the complete eight-scenario persistent
suite **passed the unchanged baseline and absolute component gates**. Its 90-day
p95/maxima were 49.53 ms notes search, 50.93 ms next-across-catalog, and 58.04 ms
download candidates. All four redraw scenarios passed. This is one recovery suite,
not a deletion or replacement of the failing run and not physical UI acceptance.
See `recovery-suite.json` and `recovery-gate.json` for all scenarios.

The Release Simulator build passed; 33 performance-policy/host-monitor tests passed,
including raw-sample outlier/count integrity checks. Same-binary diagnostics-off/on
runs exercised the optional counters. App fixture counts and correctness checksums
remain unchanged. No query implementation, baseline or performance budget changed.
Both owned Simulators are removed by the run scripts; final results are retained
in `.build/query-failure-diagnosis-20261009/{cleanup,contender-cleanup}.json`.

Conclusion: an intermittent failure was incorrectly discussed as though it were a
code-regression verdict. The old pre-change binary reproduces the failures; the
new binary does not consistently regress; and a controlled Simulator startup
intervention reproduces large stalls with substantial non-CPU elapsed time. Startup
contention is a demonstrated cause and a strong explanation for the historical
failure, whose missing per-call telemetry prevents exact retrospective attribution.
