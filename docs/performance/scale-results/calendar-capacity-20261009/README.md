# Physical calendar component capacity search

Two seeds (`20261009`, `20261010`), three alternating trials per density, 12 calendars,
varied-v1 timed events, five-day viewport, fixed `tile-prefetch-async-two` renderer.
No text memo or batched fills. Budgets and baselines unchanged.

**No supported UI capacity is established.** These are API/preparation/publication components,
not input-to-visible latency or delivered frames. Every complete case still has synchronous
work above 8.3 ms, including one event/day. The highest verified volumes below refer only to
the 100 ms component response ceiling, not all performance requirements.

| Physical device | Average/day | Events/seven-day block | Retained days/events | Worst component response | Result across six runs |
| --- | ---: | ---: | ---: | ---: | --- |
| iPhone 14 Pro | 100 | 700 | 365 / 36,500 | 92.07 ms | Within 100 ms |
| iPhone 14 Pro | 125 | 875 | 365 / 45,625 | 93.68 ms | Highest tested volume within 100 ms |
| iPhone 14 Pro | 150 | 1,050 | 365 / 54,750 | 105.18 ms | Failure; also 21.38 ms scroll component |
| iPad Pro 12.9-inch M1 | 50 | 350 | 365 / 18,250 | 90.37 ms | Within 100 ms |
| iPad Pro 12.9-inch M1 | 60 | 420 | 365 / 21,900 | 93.63 ms | Highest tested volume within 100 ms |
| iPad Pro 12.9-inch M1 | 75 | 525 | 365 / 27,375 | 103.56 ms | Failure, despite all three second-seed runs staying under 100 ms |

Daily values vary: the 125/day fixtures peak at 241/day, and 60/day at 116/day.
The seven-day block load is distinct from the five-day rendered viewport. Retained history,
checksums, thermal/power state, per-run maxima and the actual seeds are in
[the aggregate](all-components.json). Do not infer a monotonic or mathematical maximum
between tested densities. This is an adversarial overlap workload, not typical appointments.

At 125/day the iPhone's maximum foreground main section reached **8.78 ms**; at 100/day
it reached **7.46 ms**. iPad 60/day reached **6.19 ms**. These section timings are not
whole-frame measurements; other synchronous phases still fail 8.3 ms.

## History and low-volume checks

With six trials across two seeds, ten-year retained history stayed within the 100 ms
component ceiling at the tested boundary volumes:

- iPhone: 125/day, 456,250 retained events, maximum **96.49 ms**.
- iPad: 60/day, 219,000 retained events, maximum **97.29 ms**.

This isolated renderer keeps fixture history in memory; this does not test production disk
paging, provider sync, or full-app memory. It demonstrates only the tested renderer's history
sensitivity. Physical completion thermal/power readings are retained; they are not continuous
thermal or host-contention monitoring. Host compilation/research overlapped parts of these
device runs, and no continuous host monitor was attached to this capacity collector.

Reducing the iPhone to 210 retained events (210 days × 1/day) still produced a **44.93 ms**
maximum component response over six trials. At 365 events it was **43.20 ms**. The iPad's
365-event maximum was **53.91 ms**. Smaller data does not remove fixed cold/recovery costs.

Four iPad 210-day launches failed because the device was locked; the other two completed.
That subset lacks the required repetition coverage and remains incomplete. Failed launch
logs and all preceding runs remain in `.build/calendar-capacity-20261009/`.
210 days is the smallest selected history that still covers the fixed navigation scenario;
using a shorter history would leave visited weeks outside the fixture and bias the result.

The earliest coarse 1/day runs also exposed a diagnostic bug: correct empty viewports were
rejected by `expected == actual && !expected.isEmpty`. Fixed diagnostic builds compare sets
and record expected/actual counts while retaining independent pixel/date/coverage checks.
Old invalid evidence remains invalid; it is not relabeled as a pass. Confirmations above all
use the corrected binary SHA recorded in the aggregate.

## Reproduction and acceptance work

`run-device.py` now accepts explicit `--densities`, `--trials`, `--days` and `--variant` without
changing its default matrix. For each device, run seeds separately with an unused output path:

```sh
python3 tools/calendar-library-benchmark/run-device.py --device DEVICE \
  --app .build/calendar-library-touch-dd/Build/Products/Release-iphoneos/CalendarLibraryBenchmark.app \
  --out NEW_DIRECTORY --fixture varied-v1 --seed 20261009 \
  --matrix foreground --variant tile-prefetch-async-two \
  --foreground-navigation --navigation-stress --days 365 --densities 1 100 125 150 --trials 3
python3 tools/calendar-library-benchmark/report-capacity.py RUN_DIRECTORY_1 RUN_DIRECTORY_2 \
  --out NEW_AGGREGATE.json
```

Use 1/50/60/75 for the iPad confirmation. The reporter keeps invalid/missing runs, separates
response, scroll and main-section gates, rejects duplicate input directories and never returns
a UI acceptance pass. [44 harness tests passed](report-tests.log). Its scope is aggregation of
runner-validated reports, not independent revalidation of every raw pixel or interaction.

Full raw reports are retained locally rather than duplicated here; [hash manifest](raw-manifest.json)
records their paths and identities. [365-day confirmations](confirmed-components.json) and the
complete aggregate are retained in this directory. Sparse real-touch traces are separate;
their status/results must be reported before making any frame-delivery claim. Recurrence,
all-day events, live mutation/filtering, VoiceOver focus and simultaneous full-app load remain
outside this immutable component search. No baseline reduction is justified yet.

## Real-touch sparse follow-up

Both physical XCTest paging/swipe/cache-recovery scenarios passed at **one event/day**.
Each was paired with an eight-second Animation Hitches capture started after the first swipe
log, so gesture overlap is partial. This is the existing CG tile renderer, not the Metal probe.

| Device | App update max | Associated render p95 / max | Associated GPU max | Verdict |
| --- | ---: | ---: | ---: | --- |
| iPhone | 2.239 ms | 9.693 / 11.735 ms | 1.600 ms | 167/686 render intervals exceed 8.3 ms |
| iPad | 1.865 ms | 4.569 / 7.953 ms | 1.782 ms | Recorded work intervals within budget; full acceptance unmeasured |

Both traces contain zero app hitch rows, but that does not erase the iPhone interval failures.
Render intervals include scheduling/pipelining and may overlap GPU work; they do not prove
11.735 ms of CPU execution. Neither frame-lifetime spans nor variable display-wide VSync gaps
are input latency or automatic missed-120-Hz counts. The iPhone trace includes substantial
16.68 ms as well as 8.34 ms cadence. Do not label this sustained 120 Hz delivery.

[iPhone analysis](iphone-touch-analysis.json), [iPad analysis](ipad-touch-analysis.json),
[iPhone collection status](iphone-touch-status.json), [iPad collection status](ipad-touch-status.json).
Raw traces, exported tables, touch logs and XCTest results remain under
`.build/calendar-capacity-20261009/{iphone,ipad}-touch-floor/`; raw trace environment contents
are not copied into the repository. These traces still lack app-attributed HID-to-visible
measurements. They confirm that a complete device-independent capacity pass cannot be inferred
from reducing the data or from low GPU duration alone.
