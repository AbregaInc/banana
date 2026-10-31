# Merged Beta device regression — October 10, 2026

The replacement Calendar is functionally exercised on this Mac and both iPhones,
but **does not meet the performance contract**. No renderer optimization or baseline
change was made in this run. The profiled Beta uses the integrated CoreText artwork
and native collection viewport, not the separate Metal prototype. These results
are not a matched Metal comparison.

User authorized this Mac, spare iPhone and primary iPhone, explicitly excluding iPad.
DaisyDisk was terminated before testing and remained stopped. Builds and device
runs were sequential. All raw evidence, commands, source hashes, signed binaries,
failed runs and xcresults are under `.build/merged-device-regression-20261010/`.
The initial source HEAD was `5b78e1e6eb33eb8d68d236510e497750e3a49051`, plus the
preserved working-tree integration changes recorded in the source manifests.

## Measured failures

| Device/scenario | Measured interval | p95 ms | Maximum ms | Verdict |
| --- | --- | ---: | ---: | --- |
| Spare iPhone, Day scrolling | App update | 10.463 | 33.686 | Fail: 54/631 over 8.3 ms |
| Spare iPhone, Week scrolling | App update | 8.283 | 13.327 | Fail: 42/849 over 8.3 ms |
| Mac, Day/Week interactions and paging | Core Animation commit | 11.825 | 884.206 | Fail |
| Primary iPhone, Day and Week | Instruments capture | — | — | Unmeasured: both captures exceeded recorder/postprocessing deadline |

The spare runs also have associated compositor-render maxima of 18.546 ms (Day)
and 15.799 ms (Week). Associated GPU maxima were 5.126 and 4.514 ms respectively.
These are distinct pipeline intervals, not additive CPU times. Variable display
cadence is retained in the trace analysis. No full input-to-visible acceptance
measurement was obtained, and frame lifetimes are not input latency.

The Mac Calendar-only trace is `mac-corrected/mac-trace/`. Its three slowest commits
(587, 745 and 884 ms) occur during forward paging with the `j` key, based on trace
start timestamps and XCTest action logs. See `mac-corrected/commit-action-correlation.json`.
This is temporal attribution to the interaction, not CPU-stack diagnosis or proof
that the merge introduced the problem. The earlier combined Mail/Calendar trace
is retained separately under `mac-trace/` and must not be reported as Calendar-only.

The Mac host monitor flagged PID 53798, which was the run's own
`xcodebuild test-without-building`, not another build. There were no monitor errors
in that trace. The raw gate remains unchanged; the identified monitor limitation
does not erase observed slow commits. There is no matched older-build comparison.

Both phones were connected over `localNetwork`. On the primary phone, the interaction
tests passed, but each trace reached its recording time limit and failed to finish
postprocessing before the bounded collector deadline (about 203 seconds including
cleanup). Only small incomplete trace containers were retained. A direct USB retry
was requested; no successful primary-phone timing capture is claimed.

## Functional checks and harness corrections

- Spare and primary iPhones: 3/3 passing, zero skips, on the repaired fixture build:
  `testDefaultVariedDayArtwork`, `testDefaultVariedWeekArtwork`, `testMailScrollAndOpen`.
  These check populated replacement artwork before/after scrolling, exact event
  detail, and Mail scrolling/opening. Both normal Beta apps were restored afterward.
- Mac: corrected Day/Week viewport and paging tests pass 2/2, zero skips. They check
  mode changes, native viewport, scrolling, editor opening/cancellation and date
  paging/return. The earlier Mail selection/scrolling/typing test also passed.
- The first Mac Calendar tests searched for the pre-merge menu. The retained AX tree
  identifies `mac.planner.view` as a RadioGroup with Day/Week RadioButtons. The tests
  now operate that actual control; assertions about viewport and date changes remain.
- The first physical Mail test failed at `PhysicalStressReview.requireValidLaunch`,
  before reaching Mail. The guard admitted only Plan. The fixture now explicitly
  permits exactly one of Plan or Mail, retaining its isolated bundle, disabled
  cloud, actionable-fixture and bounded-day requirements. The launch helper supplies
  those requirements for Mail. New policy checks fail against the old guard and pass
  **43 checks** in both ordinary and review configurations; missing DEBUG still
  fails compilation. The only changed app source between the profiled and repaired
  device builds is `PhysicalStressReview.swift`, documented in `mail-harness/source-delta.json`.

Physical workload: 180,000 emails, 36,500 varied events over 365 days and 12 calendars,
5,000 notes and 20,000 podcast episodes. Calendar tests require 365 distinct daily
patterns and 52 distinct weekly patterns. These are isolated fixtures, not connected
Google account acceptance. Live Gmail remains unimplemented; no Apple Calendar
provider was enabled. Phone dense-overview screenshots still show severe truncation
and narrow event columns despite correct detail activation.

XCTest Mail diagnostics reported nonzero frame rates but **zero frame counts**.
The raw samples are retained in `mail-xctest-metrics.json`; they do not establish
120 Hz/frame or input-latency acceptance. Gesture durations are not response timings.

## Persistent component suite

All eight cases stayed inside their component latency, memory and baseline limits,
with zero watched unrelated redraws during the four playback-clock probes. The
suite nevertheless **failed** its evidence gate: process sampling exceeded its
2-second timeout in `scale-1d` and `redraw-mail`. No competing developer process was
observed in those cases. Preserve this failure; it is not a clean regression pass.
Host load rose substantially during the Simulator run; a later snapshot showed
about 18.6 GB of swap use. Neither observation establishes the timeout's cause.

At 90 retained days, maximum component samples were Mail first-page 36.684 ms,
Calendar visible-week query 9.523 ms, Calendar day query 0.819 ms and Notes search
45.639 ms. Maximum reported suite RSS was 684.281 MiB. Query timing is not frame timing,
and the Simulator's existing 900 MiB guardrail is not a physical-device memory budget.
See `components/gate.json`, `components/measurements.json`, and `component-summary.json`.

The owned test Simulator was shut down. The isolated Mac preview was closed; binaries,
workspaces and failure evidence were retained. No iPad tests or actions were performed.

Next measurement work is CPU attribution of the Mac paging stalls, physical Calendar
update-tail diagnosis, and a successful primary-phone trace. Dense-event readability
and Mail frame/input acceptance remain open. No performance improvement or baseline
reduction is proposed from this run.
