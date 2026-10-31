# Visible-day overlap layout reuse — October 9, 2026

`--calendar-cache-layout` is a default-off Mac experiment. The existing view computes each day's
lane allocation and overflow groups in both its header and time-grid body, repeating that work
on unrelated redraws. The candidate prepares these values once when the visible occurrence
snapshot changes. Its dictionary retains only the current visible days, replaces all entries
with the new snapshot, and shares the original allocation/grouping implementation. Synthesized
occurrence equality includes title, schedule, completion, provider details and sync state.
Palette and commute presentation continue to read their current independent inputs.

This is ordinary reuse of existing layout values, not a new calendar component or allocator.
No library dependency, default rendering policy, cache budget or regression baseline changes.

## Correctness

The same Release-optimized + DEBUG binary passed all nine native functional tests in both policies.
Coverage includes Mail selection/typing/scrolling, Plan paging, palette updates with duplicate
publication suppression, overflow reachability, event-action rebinding after paging, drag failure
rollback, event accessibility and retention of a draft after a local durable-write failure.

Raw bundles remain at:

- `.build/native-ui-performance/uitests-20261009-040923/ui.xcresult` — control, 9 passed.
- `.build/native-ui-performance/uitests-20261009-041339/ui.xcresult` — cached, 9 passed.

The persistent eight-case component regression passed for this source revision; its raw measurements,
host monitoring and unchanged gate are retained in `component-regression/`. This Simulator suite
does not exercise the Mac-only layout reuse path or certify UI latency.

## Native timing: targets remain unmet

Fresh isolated processes used the same binary, 180,000 emails and 36,500 calendar events,
five visible days, no audit footer and the built-in display configured to 120 Hz. Each recording
includes four alternating half-page down/up pairs, four J presses and four K presses, with an
accessibility query after each pair/key. Action timestamps, raw interval exports and host samples
are retained. Both sampled host monitors were clean and both previews survived recording.

| Policy | Main-thread commits | p50 ms | p95 ms | Maximum ms | Run-loop busy maximum ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| Recompute | 264 | 0.129 | 55.850 | 171.170 | 99.835 |
| Reuse visible layouts | 336 | 0.736 | 55.379 | 153.667 | 115.449 |

One paired run does not establish a meaningful improvement: p95 barely moved, the run-loop maximum
worsened, and both render paths remain far beyond 8.3 ms. The candidate stays disabled. A baseline
reduction is not justified. Commit intervals are a lower bound on frame work; they do not measure
input-to-visible latency, GPU completion or delivered refresh cadence.

## Supplemental inspection-cost diagnostic

A third fresh control process received the same number of wheel/key actions without accessibility
queries during capture. Final AX/screenshot verification occurred after recording and confirmed
the original date and rendered event columns. Its input burst lasted only 2.223 seconds versus
15.254 seconds in the queried control: intermediate SwiftUI page changes can coalesce, so this
is explicitly **not a comparable per-page latency result** or a replacement scenario.

It still recorded a 178.430 ms maximum commit (129 commits, p95 31.640 ms). This establishes that
removing those queries did not eliminate the observed failure; it does not quantify query overhead.
The earlier CPU sample identifies accessibility resolution as substantial additional work, but
view construction/layout remains a separate problem. All three failures remain retained.
