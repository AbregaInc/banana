# Native calendar observation correction — October 9, 2026

MacWeekView reads SmartScheduleStore through an identity-only environment reference. Its color
and commute publishers previously called `rebuild`, but unchanged occurrence arrays suppressed
the state update. Relevant visual changes therefore remained stale until another interaction.

The retained native control reproduces this: changing the isolated audit palette leaves the
visible value unchanged; paging then reveals the new value. The fixed run updates twice without
navigation. These are functional observations, not input-to-visible latency measurements.

The production path now increments a local revision for these two relevant publishers. Existing
`removeDuplicates` operators suppress identical values. No broad store observation was added.
The same invalidation path serves commute updates; actual commute presentation still needs
separate functional coverage. DEBUG `--calendar-observation-control` retains the former path
for ablation; `--calendar-observation-audit` exposes probes only in a stress fixture launch.

A native XCTest checks changed palette visibility and duplicate-publication redraw suppression.
Its completed result and the final app-wide component regression are pending. The earlier
bundle-ID attachment test failed despite a running preview; that failure is retained under
`.build/native-ui-performance/uitests-20261009-003959/`. The runner now resolves the unique
running isolated preview by its actual app URL instead of a stale Launch Services registration.

## Completed native functional validation

`uitests-20261009-004745/ui.xcresult` passed all four tests: Mail selection/scroll/typing,
Plan paging/scrolling, last hidden-event wheel reachability/opening, and palette invalidation.
The palette changed without navigation and identical republishing left the recorded render
count unchanged over the observation interval. XCTest timing includes automation overhead and
is not latency acceptance. The final component suite and commute-specific UI remain pending.

The second retained failed run attached to the correct PID but initially saw no window;
selecting the running preview through CUA exposed it. Its final failure used a TableRow lookup
for an Outline sidebar. Tests now select the actual sidebar StaticText by value/label. Keep the
preview visibly open before running native tests. The test file's newer event-rebinding scenario
and inspector-specific assertions were added after this successful build and need their own run.
