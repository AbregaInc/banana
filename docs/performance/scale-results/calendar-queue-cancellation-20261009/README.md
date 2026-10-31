# Cooperative tile cancellation — October 9, 2026

The preceding bounded-queue experiment completed obsolete tile drawing even after cancellation.
This separate, default-off ablation adds cancellation polls before allocation, during hour-label
work and between events. It uses the same two-worker native queue, cache limits, workload and
renderer. Cancelled results still face the existing generation/publication checks. No production
calendar renderer or default benchmark policy changes.

## Component evidence

The new `TileTests/cancellation.swift` probe passed 32 checks. An already-cancelled request returns
no image; deterministic cancellation at the 40th poll stops event traversal; an inactive callback
preserves exact image bytes and event IDs. Seven alternating worker-stop trials retained every
sample: cancellation-to-finish was 17.893–21.262 ms without polling and 0.598–2.273 ms with it.
Neither case finished before cancellation. These are offscreen worker-stop times, not input latency.
The first compilation failed on Swift's type inference for a ternary closure; its log is retained.
Explicit typed assignment compiled successfully.

The unchanged 23 prefetch/lifecycle checks passed for existing tasks, the two-worker queue and
the cooperative queue. The waiter was subsequently strengthened to wait for every forward tile,
because parallel jobs may complete out of order. All three policies passed all 23 checks again;
`all-tiles-prefetch-*` retains that separate rerun. The
15 Python reporting/runner tests passed. CI now includes cancellation and cooperative lifecycle
checks. No baseline or budget changed.

## Physical iPhone comparison

All 12 iPhone 14 Pro cases produced valid coverage and **failed the unchanged performance gates**.
Each policy ran three times at 100 and 300 events/day, with alternating order and all original
cold, warm, scroll, eviction and resize phases plus 48 directional/rapid pages. Pooled rapid-phase
statistics contain 36 samples each. Every sample/max remains in `physical-iphone/pooled-phases.json`.

| Events/day | Policy | Rapid forward p95 / max ms | Rapid return p95 / max ms |
| ---: | --- | ---: | ---: |
| 100 | Queue, two workers | 30.65 / 40.07 | 18.24 / 18.66 |
| 100 | Cooperative cancellation | 26.45 / 28.05 | 15.81 / 16.02 |
| 300 | Queue, two workers | 52.95 / 57.89 | 52.87 / 53.01 |
| 300 | Cooperative cancellation | 50.14 / 50.63 | 41.46 / 41.68 |

At 100/day, each cooperative trial had a lower rapid-forward maximum. At 300/day, trial-level
forward results were mixed. Cold maxima barely changed at 300/day (56.95 versus 56.91 ms), as did
uncached-page maxima (88.25 versus 88.08 ms). Peak sampled RSS remained roughly 46 MiB at 100/day
and 51 MiB at 300/day. This supports faster obsolete-worker shutdown and narrower improvements
inside this queue implementation; it does not establish superiority over the existing Swift-task
policy, a general UI improvement, 120 Hz delivery, or input-to-visible latency. No adoption or
baseline reduction is justified by this result alone.

Mac and Simulator integrated cooperative matrices remain unmeasured. Physical iPad testing still
requires unlocking that device. `--tile-queue-cancel-only --navigation-stress` selects the focused
comparison in the Mac/Simulator runners; `run-device.py --matrix queue-cancel --navigation-stress`
selects it on a physical device. Default scenarios remain unchanged.
