# Physical calendar component tests — October 9, 2026

All **18 physical iPhone cases completed with valid coverage and budget failures**. This is
renderer component evidence on an iPhone 14 Pro running iOS 27.0.1 (24A446), not the full app
and not input-to-visible or compositor-delivery acceptance. The screen reports 393×852 points,
3× scale and a 120 Hz maximum. All cases finished at nominal thermal state with low-power mode
off. Maximum capability is not actual refresh delivery. No Mac build ran during this matrix.

The unchanged matrix retains 365 days at 100/300 events per day, three alternating-order trials
of each cache policy, 12 warm pages (250 ms settling), 120 offsets, six uncached pages, recovery
and three resizes. The 64 MiB / 24-tile cache cap remains unchanged. Raw results, all timing
samples, environment and source snapshots are retained alongside this report.

| Density/day | Policy | Cold max ms | Page max ms | Scroll max ms | Uncached max ms | Recovery max ms | Resize max ms | Peak RSS MiB |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 100 | Prior prefetch | 43.147 | 9.614 | 4.213 | 63.724 | 33.205 | 20.101 | 44.12 |
| 100 | Lookahead | 32.887 | 10.086 | 4.234 | 63.355 | 32.869 | 20.363 | 43.50 |
| 100 | Budgeted | 32.863 | 10.021 | 4.080 | 71.173 | 33.361 | 20.106 | 43.44 |
| 300 | Prior prefetch | 56.478 | 19.064 | 8.609 | 89.700 | 41.264 | 39.812 | 48.19 |
| 300 | Lookahead | 57.043 | 19.424 | 9.946 | 89.869 | 41.468 | 39.771 | 48.19 |
| 300 | Budgeted | 57.888 | 20.337 | 10.034 | 90.220 | 41.512 | 39.690 | 48.25 |

These policies do not establish an iPhone improvement. The first process-cold control may carry
additional first-use cost; do not attribute that alone to the cache algorithm. Cold/miss work
remains synchronous and misses the frame requirement. No budgets or baselines were changed.
RSS is the existing getrusage process measure; it is not total GPU/render-server allocation or
a device memory budget. The fixture store is in memory and feature parity remains incomplete.

## Launch failure and harness correction

The first physical attempt crashed before producing a report. Its crash stack begins at
`UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption`; the reduced crash summary and
all planned cases are retained in physical-iphone-cache. The runner was interrupted after
confirming this startup cause; all remaining scenarios are explicitly unmeasured. Raw device
crash logs remain local in `.build/calendar-tiles/physical-iphone-crash.ips`.

The isolated harness now uses UIWindowSceneDelegate and a scene-bound window, following
[Apple's scene migration guidance](https://developer.apple.com/documentation/technotes/tn3187-migrating-to-the-uikit-scene-based-life-cycle).
The generated build-setting-only ProMotion key was also absent from the built plist. An explicit
Info.plist now carries that key, the scene manifest, launch screen and supported orientations;
its built values were verified. This fixes harness compatibility, not app rendering speed.

The device runner writes all planned scenarios before starting, preserves interruptions and
marks remaining cases unmeasured after three consecutive missing launch reports. Numerical
performance failures never stop the matrix. Twelve Python evidence/runner tests pass, including
install failure, interruption and repeated-startup-failure retention. Simulator compatibility
of the scene lifecycle still needs a fresh run. The connected iPad required a passcode, so its
physical measurements remain pending. The spare iPhone was unlocked; no security setting was
changed.

## Next measured bottleneck

In the first dense budgeted trial, page work reached 15.410 ms with no additional foreground
tile builds. The corresponding accessibility-update increment was 13.069 ms. Warm pixels alone
do not remove that cost. A bounded cache of same-identity accessibility objects across pages is
a candidate experiment; recycling objects to represent different events would break retained
assistive references and is not acceptable.
