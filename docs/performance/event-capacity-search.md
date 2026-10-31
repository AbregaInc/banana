# Finding the supported calendar event volume

The user requested a capacity search if optimization reaches a measured floor.
This supplements optimization; it does not relax the UI performance contract.

Before searching, validate varied multi-calendar fixtures and eliminate blank,
stale or truncated rendering. Keep the uniform historical fixture as a separate
control. Record the seed, content checksum, history length, calendar count, daily
minimum/mean/peak, seven-day total, overlap and title mix. A five-day viewport is
not a seven-day calendar week; record viewport width separately from weekly load.

For each physical device, bracket the boundary with a coarse volume sweep, then
refine around passing/failing bands. Include at least three repeats and multiple
fixed seeds. Do not assume monotonicity: cache boundaries, overlap topology and
layout changes can make a larger volume behave differently. Check neighboring
volumes and report the highest **verified** passing workload with its tested
range, rather than claiming an untested mathematical maximum.

Hold retained history independently of visible volume. Include warm and cold
navigation, first use, eviction, rapid paging, continuous scrolling, bursty days,
multiple calendar visibility states, and accessibility use. Keep every failure,
memory cost, thermal state and host-contention record. If even minimal volume
fails, investigate fixed UI overhead rather than reporting an event-count limit.

Acceptance still requires frame work at or below 8.3 ms, direct input p95 below
10 ms/max 20 ms, and other UI responses max 100 ms with a 32–50 ms goal. Report
input-to-visible, render/GPU work and completion separately. Physical display
delivery and real input evidence are mandatory for a supported UI capacity claim.
An API/component-only search can establish a component boundary, **not supported
app capacity**. Missing evidence is unmeasured, never a pass.

The [October 9 physical component search](scale-results/calendar-capacity-20261009/README.md)
retains two-seed, three-trial boundaries and independent history checks. It establishes
component response bands, not supported UI capacity; synchronous work still exceeds
8.3 ms at minimum density. The original repeated single-calendar fixture cannot
support a capacity claim. Baselines and product budgets remain unchanged.
