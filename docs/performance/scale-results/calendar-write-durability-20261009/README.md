# Pending calendar write durability — October 9, 2026

Two actual-store fault tests reproduced bugs before the change: enqueue returned success and
published an event despite a failed local disk write, and relaunching one second later left a stored
write permanently in the writing state. The retained before run has three assertion failures across
two tests; the component measurement passed. After the correction, all 20 store/rule tests passed.

Enqueue now atomically persists the candidate snapshot before publishing or returning its ticket.
A local error propagates through creation to the composer, which retains the draft and displays the
failure instead of dismissing and starting a provider request. A reconstructed store treats every
interrupted writing entry as retryable, regardless of age. Existing accepted and failed entries keep
their state. The isolated Mac fault flag is `--calendar-fail-local-write` with the observation audit;
it is effective only in DEBUG stress fixtures. The native Mac draft-retention test passed in the complete nine-test [control suite](../calendar-event-accessibility-20261009/control-summary.json).

## Component cost

Release+DEBUG, iPhone 17 Pro Simulator / iOS 26.5 on the same host, seven new-file enqueues per size.
Each trial verifies the persisted ID, count and draft notes outside the timed interval. These are
synchronous store-operation timings, not input-to-visible latency. No performance gain is claimed.

| Existing pending entries | Before median/max ms | After median/max ms |
| ---: | ---: | ---: |
| 0 | 0.356 / 1.703 | 0.480 / 1.734 |
| 10 | 0.502 / 1.086 | 0.497 / 2.145 |
| 100 | 1.310 / 1.562 | 1.285 / 2.231 |
| 1000 | 8.770 / 9.388 | 8.924 / 10.206 |

One pair cannot separate small overhead from noise. Both versions rewrite the whole pending JSON
snapshot on the main actor; the large-queue cost already exceeds 8.3 ms. This remains optimization
work, and no baseline was changed. The native check verified the error, unchanged typed title, enabled Save action, and cancellation after a simulated local failure.

The before test finished with the expected failures, then Xcode launched verbose Simulator
`diagnose` collection. That diagnostic subprocess was interrupted after the tests had completed;
the completed xcresult, test log and timing attachment were retained. The after run used
`-collect-test-diagnostics never`. Assertions and normal test-result collection remain enabled.
`BananaModelTests` is a dedicated scheme for running the model tests without building the app/UI
runners. Both comparisons use the same Release compiler settings and derived-data directory.

## Remaining durability gaps

The provider create path still lacks a stable client-generated event ID for ambiguous retries.
[Google supports client-chosen IDs to prevent duplicate creation](https://developers.google.com/workspace/calendar/api/guides/create-events).
This has been researched but is not fixed by the local transaction change. Existing event moves
still use an ephemeral rollback/error path, not a durable retry record. These are open acceptance
items; the local tests do not certify provider idempotence, durable move retries or full UI budgets.

## Whole-app component regression

The subsequent complete eight-case suite passed unchanged baseline version 1 at
`.build/performance-regression/calendar-durability-20261009`. Raw measurements, sampled developer
workload evidence and the gate are retained in `component-regression/`. The optimized app build
includes the local durability fixes and default-off rendering experiments. This is Simulator
component evidence, not 120 Hz or input-to-visible acceptance. No baseline was changed.
