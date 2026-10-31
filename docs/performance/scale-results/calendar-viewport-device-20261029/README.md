# Matched viewport comparison on a physical iPhone — 29 October 2026

The first before/after of the calendar viewport change on real hardware: the pre-virtualization
Day/Week host (`--calendar-reference-day` / `--calendar-reference-week`) against the shipping
native collection viewport, in the same isolated fixture app, on the same device, in the same
interaction window, in old/new/new/old order. Scrolling samples only; not input-to-visible
latency, not a frame-budget pass, not the shipping App Store binary.

## Setup

- Device: spare iPhone 14 Pro, iOS 27.0.1, 120 Hz display, connected by USB, unlocked, nothing
  else running. Owner authorized this device; the primary phone and the iPad were not used
  (iPad XCTest automation authorization was still pending).
- App: `com.boris.banana.stressreview`, built from the BananaBeta scheme at commit `b3e12d6f`
  (plus the uncommitted test/profiler changes recorded in this folder's commit), Release
  configuration with `DEBUG STRESS_DEVICE_AUDIT` compilation conditions so the fixture and the
  reference switches compile; empty capability entitlements, re-signed with Xcode's generated
  application-identifier entitlements after renaming the bundle to `Banana Stress Review.app`
  (a global `PRODUCT_NAME` override collides with Swift package resource bundles).
  Executable SHA-256 prefix `fd6f8a485bf87bfd`.
- Workload: `varied-v1`, 100 events/day across 12 calendars for 365 retained days
  (36,500 events), plus the physical fixture's 90 days of mail, 5,000 notes and 20,000
  episodes. Asserted by the test from the fixture's `stress.ready` metadata.
- Interaction: `tools/physical-stress-tests/compare-viewports.py run`, which drives
  `profile-scroll.py` eight times: for each of Day and Week, reference, native, native,
  reference. Each run launches the app fresh, switches to the mode, then performs 16
  swipe-up/swipe-down pairs while an 8-second Animation Hitches recording is attached.
- Analysis: `report-hitches.py`, app-attributed update intervals and the compositor render
  intervals associated with them. Thresholds and budgets unchanged.

## Result

App-attributed update intervals, milliseconds. Two runs per cell, in recorded order.

| View | Host | Updates in window | p50 | p95 | Max | Over 8.3 ms |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Week | Reference (old) | 230 · 218 | 14.93 · 15.13 | 46.14 · 47.63 | 90.92 · 100.90 | 230 · 218 (all) |
| Week | Native (new) | 605 · 599 | 2.34 · 2.36 | 7.21 · 7.29 | 12.69 · 11.98 | 17 · 20 |
| Day | Reference (old) | 630 · 637 | 1.92 · 1.98 | 3.14 · 3.10 | 157.11 · 158.65 | 8 · 8 |
| Day | Native (new) | 665 · 634 | 2.01 · 2.16 | 7.65 · 7.39 | 149.40 · 143.90 | 29 · 22 |

Display cadence (display-wide VSync gaps during the window): the Week reference runs sat
mostly at 16.68 ms with many 33 ms and 50 ms gaps; every other run was dominated by 8.34 ms.

Reading:

- **Week** is where the viewport change pays on the device. The old host's median update was
  15 ms and no update met 8.3 ms, so the display fell out of 120 Hz cadence. The native host's
  median is 2.3 ms, p95 7.2 ms, worst 12.7 ms, with the display mostly at 8.34 ms gaps.
- **Day** is not an improvement in this sample. The old host built the whole day's view tree
  up front, so scrolling it was nearly free (p95 3.1 ms). The native host does per-cell work
  during the scroll (p95 7.5 ms), still inside 8.3 ms at p95 but with about three times as
  many over-budget updates. The 60% preparation saving in the article is load-time work; this
  is scroll-time work, and the two trade against each other on Day.
- Both Day hosts show the same roughly 150 ms update about every 2.7 seconds (reference at
  +1.7, +4.5, +7.7 s; native at +2.1, +4.8, +8.0 s). It is independent of the viewport, so it
  is not caused by the change and not fixed by it. It is unattributed; it is the next thing
  to profile with Time Profiler on this device.

## Limits

One device, 8-second windows, three samples of the periodic Day stall per run. Update and
render intervals are not input-to-visible latency and are not proof of CPU stack attribution.
The fixture app shares source with the shipping build but is not that binary. The iPad
comparison, both orientations, is in the iPad section below. Raw traces and xcresults are under
`.build/viewport-compare-20261029/` and are build output; this folder keeps the plan, each
run's status and its analysis without the per-sample arrays, and the summary.

## Follow-ups on the same device, same evening

### The periodic Day stall, attributed and fixed

`iphone14pro-cpu/`: an 8-second Time Profiler capture of native Day scrolling
(`profile-scroll.py --template 'Time Profiler'`), analyzed with
`tools/physical-stress-tests/cpu-stalls.py` (output in `day-native-stalls.txt`). Main-thread
CPU is 2,462 ms of the 9.3 s window; three contiguous stall windows of 100, 135 and 100 ms sit
at +2.25, +5.00 and +7.95 s. Inside them, 95% of main-thread time is one stack:
`PlanPromptCard.body` → `OccurrenceStore.nextAlertSample` → `alertCandidates(from:)`, a scan
over all 36,500 occurrences with `EventAlertPlan.allows` per event, run inside a SwiftUI
body evaluation. Outside the stalls that stack is under 2%; Core Animation layout dominates.
Both Day hosts showed the same stall in the first matrix because the card sits above either.

Fix (commit "Plan: derive the next-alert sample once per timeline change"): the candidates
are cached per occurrences revision and mute set (`AlertCandidateCache`, four unit tests).
Verification traces with the fixed app follow in `iphone14pro-alertfix/`.

### UIKit cell prefetching: measured, no gain

`iphone14pro-prefetch/`: `--calendar-prefetch-cells` (new DEBUG switch turning
`isPrefetchingEnabled` on) in clear/prefetch/prefetch/clear order, same device, fixture and
window. App-update intervals, ms:

| View | Policy | Updates | p50 | p95 | Max | Over 8.3 |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Day | clear (default) | 845 · 608 | 2.17 · 2.33 | 7.04 · 7.13 | 136.0 · 141.6 | 24 · 16 |
| Day | prefetch | 632 · 643 | 2.80 · 2.56 | 7.39 · 7.78 | 195.3 · 143.9 | 22 · 29 |
| Week | clear (default) | 603 · 695 | 2.38 · 2.26 | 7.38 · 7.06 | 16.6 · 12.4 | 17 · 22 |
| Week | prefetch | 623 · 598 | 3.03 · 2.80 | 7.43 · 7.36 | 20.1 · 16.7 | 19 · 19 |

Prefetching raised the median update (more work per update, presumably the extra cell
preparation) and did not lower p95 or the maxima. The switch stays off; the hypothesis in the
code comment is answered. The Day maxima here are the alert-sample stall, before its fix.

### With the fix installed (`iphone14pro-alertfix/`, app SHA-256 prefix `e7f340cac6736812`)

Same device, fixture and window; Day in reference/native/native/reference order, Week native
twice. App-update intervals, ms:

| View | Host | Updates | p50 | p95 | p99 | Max | Over 8.3 |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Day | Reference (old) | 676 · 645 | 2.02 · 1.91 | 3.12 · 3.04 | 8.10 · 39.73 | 59.4 · 45.3 | 6 · 8 |
| Day | Native (new) | 654 · 659 | 2.36 · 2.22 | 6.95 · 6.98 | 11.24 · 13.21 | 36.8 · 36.1 | 20 · 19 |
| Week | Native (new) | 620 · 703 | 2.23 · 2.36 | 7.43 · 7.42 | 11.28 · 10.39 | 21.6 · 13.5 | 21 · 23 |

The periodic ~150 ms update is gone from both Day hosts: the worst Day update on the native
host fell from 144–149 ms to 36 ms, on the reference host from 157–159 ms to 45–59 ms, and the
native host's p99 from 12–13 ms to 11–13 ms with the tail now a single event rather than three.
The remaining 36–59 ms maxima are a different, so far unattributed tail. Week is unchanged
within run-to-run noise, as expected: the card's scan was the same cost in Week but Week's
window happened to catch fewer of them. Medians and p95 are unchanged, which is also
expected; the fix removes a stall, not per-update work.

### Preparation work on the device (`iphone14pro-preparation/`)

The article's original headline came from a Simulator experiment on October 10. The same
measurement now runs on the phone: `tools/physical-stress-tests/profile-device-preparation.py`
launches the fixed review app through devicectl with the Simulator collector's exact arguments
(legacy fixture, 30 days, 100 new events/day, `--calendar-prepared-artwork --calendar-artwork-profile
--stress-idle-seconds 1`, plus the review build's required `--stress-actionable-calendar`),
waits, and copies the app's own `Documents/scale-idle.json` back. Two rounds of
reference/native/native/reference. Main-actor cache-miss preparation samples summed per launch:

| Launch | Day host | Blocks prepared | Total preparation | Largest single | Image bytes held |
| ---: | --- | ---: | ---: | ---: | ---: |
| 1 | Reference | 108 | 37.751 ms | 8.439 ms | 14.42 MB |
| 2 | Native | 48 | 16.348 ms | 1.570 ms | 10.00 MB |
| 3 | Native | 48 | 16.721 ms | 1.592 ms | 10.00 MB |
| 4 | Reference | 104 | 27.031 ms | 1.739 ms | 14.42 MB |
| 5 | Reference | 104 | 27.126 ms | 1.737 ms | 14.42 MB |
| 6 | Native | 48 | 16.029 ms | 1.531 ms | 10.00 MB |
| 7 | Native | 48 | 16.562 ms | 1.554 ms | 10.00 MB |
| 8 | Reference | 105 | 24.499 ms | 1.432 ms | 14.42 MB |

Reference mean 29.1 ms (24.5–37.8; launch 1 is the process-cold one and carries an 8.4 ms
first block), native mean 16.4 ms (16.0–16.7). 43.6% less preparation work on the mean, 54%
fewer blocks prepared. Every launch's redraw probe passed and every report was complete
(attempts equal samples, no drops, no pending jobs). Component measurement: not frames, not
input-to-visible latency. The Simulator run's 95→38 ms is retained in
`calendar-native-day-20261010` as the experiment that pointed here; its absolute numbers are
not comparable to the phone's.

### iPad Pro 12.9-inch (M1), first attempt: partial (`ipadpro-m1-partial/`)

Automation on the iPad initialized once the portrait requirement was relaxed (the iPad stays
landscape under XCTest; the geometry note now records orientation). Over Wi-Fi only two of
eight traces completed; two more passed their interaction test but Instruments postprocessing
exceeded the collector's deadline (90 s and 204 s), and from the fifth run the test runner
could not be installed ("createDirectoryAtURL" failure) and later the review app itself could
not be reinstalled ("Failed to stream the app asset from remote device"). The preparation
launches produced no report for the same reason. Retained as failures; not rerun silently.

The two completed Day traces, landscape, app-update intervals in ms:

| Host | Updates | p50 | p95 | p99 | Max | Over 8.3 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Reference (old) | 505 | 0.56 | 1.08 | 36.06 | 36.9 | 12 |
| Native (new) | 446 | 2.17 | 9.89 | 50.02 | 62.3 | 41 |

One run each is not a comparison. It points the same way as the phone's Day result (the old
host's prebuilt tree scrolls cheaply; the native host pays per cell, more so on the larger
viewport) and is kept only to be checked against a cabled rerun.

### iPad Pro 12.9-inch (M1), cabled, both orientations

Same fixture app (`e7f340cac6736812`, the alert-fix build the phone's final matrix used), same
workload, same 16-swipe window and 8-second Animation Hitches capture, same old/new/new/old
order; the iPad on USB, unlocked, nothing else running. Orientation is an input to the test
(`STRESS_ORIENTATION`, commit `a8def131`): the test rotates the device, fails if the rotation
is not honoured, and `status.json` records what it measured. Geometry from the tests' notes:

| Orientation | App | Day grid | Day native cells | Week grid | Week native cells |
| --- | --- | --- | ---: | --- | ---: |
| Landscape | 1366 × 1024 pt | 1366 × 680 pt | 40 | 1366 × 635 pt | 111 |
| Portrait | 1024 × 1366 pt | 1024 × 1022 pt | 59 | 1024 × 977 pt | 93 |

#### Landscape (`ipadpro-m1-landscape/` Day, `ipadpro-m1-landscape-week2/` Week)

App-update intervals, ms, two runs per cell in recorded order:

| View | Host | Updates | p50 | p95 | p99 | Max | Over 8.3 |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Day | Reference (old) | 614 · 637 | 0.84 · 1.29 | 1.62 · 1.93 | 2.48 · 4.16 | 41.0 · 41.8 | 6 · 6 |
| Day | Native (new) | 625 · 595 | 1.62 · 1.72 | 7.23 · 9.53 | 10.4 · 14.0 | 49.1 · 68.2 | 23 · 36 |
| Week | Reference (old) | 524 · 548 | 11.75 · 11.53 | 14.38 · 13.58 | 40.3 · 38.2 | 42.7 · 42.1 | all · all |
| Week | Native (new) | 590 · 613 | 2.27 · 2.33 | 12.74 · 12.44 | 16.6 · 16.2 | 19.5 · 21.0 | 79 · 92 |

Display cadence: every Day run sat at 8.34 ms for 730–761 of its 831–866 gaps, with 13–34
gaps at 41.69 ms. The Week reference runs had 93–101 gaps at 12.51 ms and 35–42 at 16.68 ms
(675 and 633 of ~850 at 8.34 ms); the Week native runs 741 and 808 of ~870 at 8.34 ms, with
22 and 10 gaps at 41.69 ms and about 30 at 12.51 ms.

The first landscape matrix also produced a third Week reference run (`week-1-reference`:
556 updates, p50 11.69, p95 14.30, max 41.2 ms, all over 8.3) before its remaining Week
runs failed; see the failures below.

#### Portrait (`ipadpro-m1-portrait/`, `ipadpro-m1-portrait2/`, `ipadpro-m1-portrait-week3/`)

Three matrices were needed because six of the ten native-host traces were rejected by the
analyzer (next paragraph). Valid runs, app-update intervals in ms, in recorded order:

| View | Host | Updates | p50 | p95 | p99 | Max | Over 8.3 |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Day | Reference (old) | 493 · 536 · 484 · 485 | 0.54 · 0.55 · 0.79 · 0.61 | 1.34 · 1.24 · 1.43 · 1.54 | 38.3 · 38.7 · 40.5 · 40.5 | 40.0 · 39.8 · 44.4 · 41.8 | 12 · 12 · 12 · 12 |
| Day | Native (new) | 443 · 436 | 2.18 · 2.21 | 9.39 · 9.82 | 48.7 · 48.9 | 90.3 · 94.9 | 32 · 43 |
| Week | Reference (old) | 486 · 608 · 552 · 474 · 478 · 529 | 11.26 · 10.93 · 11.34 · 11.38 · 11.54 · 11.57 | 13.49 · 13.27 · 14.24 · 14.10 · 14.72 · 14.58 | 39.9 · 38.7 · 42.5 · 44.5 · 62.5 · 46.5 | 45.8 · 45.0 · 43.7 · 48.4 · 64.9 · 59.0 | all (528 of 529 in the last) |
| Week | Native (new) | 483 · 476 | 2.45 · 2.52 | 8.62 · 10.54 | 25.3 · 99.5 | 116.2 · 125.4 | 28 · 51 |

Display cadence in portrait: the Day reference runs were almost entirely 8.34 ms (932 of 977,
990 of 1005, 989 of 1001, 777 of 859); the two valid Day native runs 526 of 678 and 534 of 690,
each with 46–49 gaps at 41.69 ms (one at 83 ms). Week reference ranged from 998 of 1004 at
8.34 ms down to 450 of 657 (49 gaps at 41.69); Week native 581 of 729 (39 at 41.69) in the
first matrix and 994 of 1009, no gap above 8.35 ms, in the third, the run with the 125 ms
update. A long app update and a steady display cadence coexist in that trace; the update
interval is not a frame.

Rejected traces: `ipadpro-m1-portrait/day-3-native`, `week-3-native`;
`ipadpro-m1-portrait2/day-2-native`, `week-2-native`, `week-3-native`;
`ipadpro-m1-portrait-week3/week-3-native`. Each test passed and each recording completed;
`report-hitches.py` refused them with "Incomplete app-associated GPU coverage" because one or
two of the 414–462 app updates had no row in Instruments' GPU table. The rule is
all-or-nothing by design and was not loosened; the runs are kept with their `status.json` and
the analyzer's refusal. No reference-host trace was refused in any orientation, and no native
trace was refused in landscape, so the gap is tied to the native host in portrait on this
device; it is not understood.

#### Reading

- **Week** moves the same way as on the phone, less far. The old host's median update is
  11–12 ms in both orientations and no update meets 8.3 ms; the native host's median is
  2.3–2.5 ms. But the native host's p95 is over budget on the iPad (12.4–12.7 ms landscape,
  8.6–10.5 ms portrait) where the phone's was 7.2 ms, and portrait adds a 116–125 ms worst
  update that landscape (max 21 ms) does not have. Per-cell work scales with the 93–111
  visible cells; the phone showed far fewer.
- **Day** is the phone's result, wider. The old host's prebuilt tree scrolls in 0.5–1.3 ms
  median with 6–12 over-budget updates per window; the native host pays 1.6–2.2 ms median,
  7.2–9.8 ms p95, 23–43 over budget, and worst updates of 49–68 ms (landscape) and 90–95 ms
  (portrait). Both hosts share a ~40 ms update in every run (p99 38–40 ms on the reference
  host), present in both orientations, not the alert-sample stall (fixed in this build), not
  attributed.
- **Orientation matters on the iPad.** Portrait shows more cells on Day (59 vs 40), fewer on
  Week (93 vs 111), and its native-host tails are two to six times longer than landscape's
  in both views. Any iPad claim has to say which orientation it was measured in.

#### Failures kept from the same day

- `ipadpro-m1-landscape/week-2-native`, `week-3-native`: tests passed, xctrace exited 2
  ("Transferred trace file is malformed"; "Failed to stop recording session: Data Providers
  emitted errors: Logging"). `week-4-reference`: the test runner could not be installed.
- `ipadpro-m1-landscape-week/` (four runs): every runner install failed with "not enough
  storage". The iPad's data volume was at 0 bytes free while reporting 436 GB
  `TotalDataAvailable` to the Mac; that figure includes purgeable space, and
  `AmountDataAvailable` was 0. Owner freed space (20 GB real) and the landscape Week matrix was
  rerun as `ipadpro-m1-landscape-week2/`.
- The volume filled again within about an hour of that (20 GB real free at 13:40, 0 at
  14:31, `TotalDataAvailable` down 31 GB in the same hour). Banana's containers on the iPad
  total about 3.2 GB (Stable 1.8 GB, Beta 0.3 GB, the stress fixture's `tmp/` 1.1 GB of
  per-launch `ScaleStress-*` folders it never removes); the device's own disk-write reports
  in that hour name `SetStoreUpdateService` and `spotlightknowledged.updater`, but the
  consumer was our own captures: Instruments records each trace in the device's private temp
  area and leaves it there, as it does in `$TMPDIR` on the Mac (30 `.ktrace` files, 38 GB).
  Restarting the iPad returned 43.8 GB; one further capture (`ipadpro-m1-tempcheck/`) then cost
  1.6 GB of device storage, and its Mac-side 977 MB recording was removed by the profiler's new
  cleanup. About 1.6 GB per capture, 30 captures: the whole gap.

#### Preparation work on the iPad (`ipadpro-m1-preparation-usb2/`): partial

Same `profile-device-preparation.py` run as the phone's, two rounds planned. Launches 1–3
reported; from launch 4 the app launched (exit 0, new pid each time) but never wrote a new
`scale-idle.json`, so the collector pulled the previous report and marked each launch
`stale-report`. The device had run out of storage during the run (above). Orientation at
launch is not recorded by this collector.

| Launch | Day host | Blocks prepared | Total preparation | Largest single | Image bytes held |
| ---: | --- | ---: | ---: | ---: | ---: |
| 1 | Reference | 104 | 40.667 ms | 1.943 ms | 18.51 MB |
| 2 | Native | 80 | 32.537 ms | 2.509 ms | 15.51 MB |
| 3 | Native | 82 | 32.857 ms | 2.090 ms | 15.51 MB |
| 4–8 | — | stale report | | | |

One reference launch against two native ones is not a comparison; kept as the partial it is.
The rerun follows.

#### Preparation work on the iPad, complete (`ipadpro-m1-preparation-usb3/`)

After the restart (42 GB free), the same collector, two rounds, every launch collected, every
redraw probe passed, every report complete:

| Launch | Day host | Blocks prepared | Total preparation | Largest single | Image bytes held |
| ---: | --- | ---: | ---: | ---: | ---: |
| 1 | Reference | 103 | 44.050 ms | 3.529 ms | 22.85 MB |
| 2 | Native | 53 | 30.158 ms | 2.751 ms | 15.34 MB |
| 3 | Native | 53 | 29.031 ms | 2.669 ms | 15.34 MB |
| 4 | Reference | 103 | 42.156 ms | 2.502 ms | 22.85 MB |
| 5 | Reference | 104 | 41.609 ms | 2.464 ms | 22.85 MB |
| 6 | Native | 54 | 28.777 ms | 2.416 ms | 15.34 MB |
| 7 | Native | 51 | 25.835 ms | 2.150 ms | 15.34 MB |
| 8 | Reference | 106 | 43.579 ms | 2.458 ms | 22.85 MB |

Reference mean 42.8 ms (41.6–44.0), native mean 28.5 ms (25.8–30.2): 33.6% less preparation on
the mean, 49% fewer blocks prepared, 33% fewer image bytes held. The phone's figures were 44%
and 54%.

The two iPad runs disagree on how many blocks the native host prepares: 80–82 in the partial,
51–54 here, with the reference host at 103–106 in both. This collector does not set or record
orientation; the app launches in whatever orientation the device was left in. The partial ran
after a portrait trace, the complete run after a landscape one, and the portrait Day grid shows
59 native cells against landscape's 40, which is the same ratio. The reference host prepares
the whole day either way. So the native saving on the iPad is about 34% in landscape and, from
the partial, about 20% in portrait; the collector should record orientation before either
number is quoted as more than that.
