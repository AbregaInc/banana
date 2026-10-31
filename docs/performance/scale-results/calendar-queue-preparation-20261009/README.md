# Bounded native tile preparation — October 9, 2026

This opt-in prototype experiment compares existing utility-priority Swift task prefetch with
Apple's [OperationQueue](https://developer.apple.com/documentation/foundation/operationqueue),
capped at one or two concurrent bitmap jobs shared by scroll and page speculation. Core Text
layout objects and CGContext remain local to each job; immutable pixels cross to the main actor.
[Apple permits shared fonts but confines layout objects to their operation/thread](https://developer.apple.com/documentation/CoreText).

The cache remains 64 MiB / 24 tiles. Active images, running jobs and completed images awaiting
publication are additional memory, measured through peak RSS. Cancelled jobs cannot publish into
a retired generation, but an already-running queue job finishes its current tile before stopping.
Native cancellation alone does not preempt executing code. This limitation motivates a separate
cooperative-cancellation follow-up; it has not been measured in the results below.

## Offscreen component evidence

All three policies passed the existing 23 prefetch/eviction/generation/LRU checks. The new
availability probe also verifies every prepared tile against direct-rendered pixels and event IDs,
with seven samples at 393pt/3x and 1200pt/2x for each density. Availability uses 1 ms polling and
is not input latency. All six probes passed. Results include every sample and host monitor.

| Events/day | Surface | One worker forward-band median ms | Two workers median ms |
| ---: | --- | ---: | ---: |
| 100 | 393pt / 3x | 28.225 | 16.306 |
| 100 | 1200pt / 2x | 32.189 | 19.036 |
| 300 | 393pt / 3x | 52.386 | 34.719 |
| 300 | 1200pt / 2x | 61.226 | 37.114 |

First-tile readiness sometimes worsened. Peak process RSS rose from 61.9 to 64.3 MiB at 100/day
and 64.8 to 66.5 MiB at 300/day between one and two queue workers. The existing task policy's
forward-band medians were similar to one worker. These ordered component runs are diagnostic;
the physical matrix below alternates candidate order across three trials.

## Physical iPhone result: no integrated improvement

All 18 iPhone 14 Pro cases completed with valid visible/drawn-ID coverage and **budget failures**.
The unchanged original phases, cold mount, cache eviction, resize and 48 additional directional/rapid
pages remain present. Nominal thermal state was reported on completion. No input/display delivery
was measured. The physical iPad still requires its passcode and is unmeasured.

Pooled p95 across all 36 samples of each rapid phase, with all raw maxima retained in
`physical-iphone/pooled-phases.json`:

| Events/day | Policy | Rapid forward p95 ms | Rapid return p95 ms | Peak RSS MiB |
| ---: | --- | ---: | ---: | ---: |
| 100 | Existing tasks | 26.70 | 15.79 | 44.17 |
| 100 | Queue / one | 31.84 | 22.51 | 41.78 |
| 100 | Queue / two | 30.68 | 18.10 | 45.80 |
| 300 | Existing tasks | 46.05 | 41.58 | 50.55 |
| 300 | Queue / one | 48.37 | 47.79 | 46.47 |
| 300 | Queue / two | 53.38 | 52.51 | 51.05 |

Faster isolated preparation did not make rapid navigation faster. All alternatives remain disabled
by default; neither a UI improvement nor a reviewed baseline reduction is supported. Mac and
Simulator integrated queue matrices have not yet run. The shipping app's last complete component
suite remains the passing durability run; this experiment changes only the isolated prototype.

## Reproduce

`--tile-queue-only --navigation-stress` selects the 18-case comparison in the existing Mac and
Simulator runners. `run-device.py --matrix queue --navigation-stress` selects it on physical devices.
All default matrices and budgets are unchanged. The additional offscreen program is
`TileTests/availability.swift`, compiled with `Shared/*.swift`; use `--mode week --density 100`
or `300` and each `--ablation tile-prefetch-budgeted`, `tile-prefetch-queue-one`,
`tile-prefetch-queue-two`. Retain fresh output directories and all failures.
