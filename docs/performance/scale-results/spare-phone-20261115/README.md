# Spare-phone physical performance experiments — November 15

The existing cell-host preservation experiment did not produce a consistent
scrolling-tail improvement in a matched clear/preserve/preserve/clear comparison.
The production policy is unchanged. All measured frame-interval gates failed;
this session does not establish performance acceptance.

## Build and workload

The owner authorized exclusive overnight use of the spare phone. The main phone
and its installed apps were not changed. A separately signed stress-review app
was built from `96d23d6f`, Release optimized with DEBUG, STRESS_DEVICE_AUDIT and
BANANA_BETA instrumentation. Hardware: iPhone15,2; iOS 27.2.1. Actual display cadence
varies in the retained VSync samples; hardware capability is not evidence of
constant 120 Hz delivery.

Every full-app case retains 180,000 emails, 36,500 varied calendar events across
12 calendars and 365 days, 5,000 notes and 20,000 podcast episodes. No provider
sync or production-account data is enabled. Eight-second Instruments captures
sample part of 16 up/down gesture pairs. They do not measure cold navigation,
input-to-visible latency, live sync, eviction recovery or retained memory.

## Matched reuse experiment

All four recordings used the same installed app and UI-runner binary, portrait,
current-period native Week, unchanged density and gesture sequence. Each process
loads a fresh fixture; OS caches are uncontrolled. The Thermal State instrument
reports nominal throughout all four recordings. Both repeated baseline and
candidate results are retained, including failures.

| Order / policy | Update count | p50 | p95 | p99 | Maximum | Updates >8.3 ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 / clear | 596 | 1.544 | 3.178 | 12.568 | 13.859 | 11 |
| 2 / preserve | 586 | 1.414 | 3.258 | 12.567 | 13.859 | 15 |
| 3 / preserve | 581 | 1.461 | 3.300 | 12.785 | 13.800 | 13 |
| 4 / clear | 590 | 1.440 | 3.031 | 12.966 | 14.369 | 13 |

Times are milliseconds. These are app-attributed update intervals, not isolated
CPU execution or input latency. Associated render intervals also fail the
unchanged gate. The JSON retains their distributions, GPU samples, lifetime
intervals, sample counts and display-cadence histograms separately. Do not add
inclusive pipeline intervals together or count a pipelined frame lifetime as
single-frame CPU work.

The initial diagnostic Week recording also failed: update p95 5.390 ms, maximum
13.936 ms, 22/607 over budget. Its explicit render-wait export reduces the
wait-excluded diagnostic render p95 from 11.602 to 4.226 ms; the original inclusive
render maximum remains 14.841 ms. This explains part of the interval without
changing its gate or proving CPU cost. It is not an extra vote for the candidate.

## Populated-period and Day probes

The fixture begins today. Screenshot review found that a current-week viewport
can include empty dates before that anchor. The new supplementary `--period next`
Week case verifies navigation into the following populated week before scrolling.
It preserves the current-period cases, density, history and budgets.

The first populated-week frame recording reports fair thermal state throughout:
update p95 6.736 ms, maximum 15.949 ms, 15/588 over budget. Retain it as a failing
observation under that condition, not a controlled before/after comparison.

The current-Day recording is nominal throughout: update p95 6.850 ms, maximum
35.110 ms, 17/575 over budget; GPU maximum 3.082 ms. The 35.110 ms update interval
is a failure. It does not supply a HID timestamp or prove input-to-visible latency.
The repeat after cooldown/restart remains fair throughout: update p95 6.826 ms,
maximum 15.408 ms, 17/593 over budget. It is retained separately and is not
relabeled nominal. All four current-period reuse cases instantiate 13 initial
cells; populated-week cases instantiate 54. These distinct windows must not be
merged into one before/after comparison.

## CPU attribution

The populated-week Time Profiler capture is nominal throughout. Its application
UUID matches the retained executable and dSYM. Sample weight is 2.39 seconds,
2.31 seconds on the main thread; this is sampled CPU attribution, not a frame or
interaction percentile. Inclusive calendar collection-layout weight is 233 ms:
221 ms inside UIKit layout, 200 ms updating visible cells, with 118 ms in its
visible-view removal subtree. Hosting-view teardown accounts for 60 ms within
that subtree. These weights overlap and must not be summed.

The measured subtree supports investigating view lifecycle/layout further, but
does not justify changing the production reuse policy after the negative ablation.
The separate Day CPU sample is fair throughout: approximately 2.37 seconds of
sample weight, 2.30 seconds on the main thread, and 183 ms inclusive calendar
collection-layout weight. Its app UUID also matches. It is exploratory attribution
under a different thermal condition and viewport population; it does not identify
the cause of the nominal Day frame recording's individual 35.110 ms interval.

## Harness repairs and checks

- The standalone Release runner now explicitly includes the Mail identifiers its
  cases compile against. Both app and runner build successfully.
- Day/Week artwork checks now use the existing `sheet.close` accessibility
  identifier and verify dismissal. Both pass with exact selected-event checks.
  Their original failures against the obsolete Done label remain retained.
- The populated-period clear case passes its physical scroll test in three captures
  (two frame captures and one CPU capture). The preserved-host populated-period
  variant compiles but was not executed. The probe verifies its date snapshot changes and retains the
  workload/geometry attachments. Unsupported renderer, density, prefetch and Day
  combinations are rejected before device access. The current-period default
  remains unchanged.
- All 43 launch-isolation checks pass in both configurations; missing DEBUG is
  rejected. These policy checks do not establish runtime performance.

No application renderer, cache policy, budget, baseline or reference workload was
changed. The persistent Simulator component suite was not rerun for these
runner/collector changes; its previously reported failures remain unresolved.
Physical memory, accessibility, editing, concurrent sync, all-platform acceptance,
and direct input-to-visible measurements remain incomplete.

## Retained evidence and cleanup

Private raw traces, xcresults, every failure, workload/geometry attachments,
exact commands, build identity, binary/dSYM UUIDs, battery/storage checks and
recording cleanup logs are under `private/performance-spare-20261115/` in the
preserved performance worktree. Public [summary.json](summary.json) contains
redacted timing summaries only. Device identifiers, account details and raw traces
are not published.

Ten captures completed: eight Animation Hitches and two Time Profiler. All ten
scroll tests passed; every measured frame-interval gate failed. Seven captures
report nominal thermal state and three report fair, each retained explicitly.

Each session checks real AmountDataAvailable, bounds recordings, removes its
Mac-side temporary ktrace and restarts only the spare afterward to clear the
inaccessible device-side recording temporary files. Installed build symbols stay
protected. No baseline reduction is proposed because no optimization was adopted.
