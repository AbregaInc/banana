# Mail row/display retention repair — October 10, 2026

Both native hosts retained every row/display ever seen across scope changes.
The actual-method probe reproduced 512 retained records per dictionary after
replacing eight 64-row scopes, plus retention after an empty scope.

The iOS candidate associates retired IDs with their snapshot generation, retains
them until UIKit's completion, and only evicts if that generation still owns the
retirement. Reinsertion cancels retirement; re-removal gets a new generation, so
an older completion cannot evict a row belonging to a later transition. The weak
completion does not extend coordinator lifetime. The Mac non-animated update
removes IDs leaving the current order.

The frozen code fails 18 expanded membership/retirement checks. The candidate
passes the same scenarios, retaining 64 settled rows/displays per 64-row scope,
then none for an empty scope. The iOS probe preserves outgoing rows until simulated
completion, including out-of-order completion/reinsertion cases. Real in-flight
memory remains proportional to outstanding transitions; it is not claimed to be
strictly one page during animations. These adapter counts are not byte accounting,
framework animation coverage or a scrolling speedup.

`tools/mail-row-retention-tests` now runs the correctness checks in CI and supports
frozen-source comparisons. Optional cold/warm/replacement/eviction timing refuses
to run while Xcode is active. The first probes are functional only. App swipe/
Undo/scope-change and stress scroll/open passed three iPhone Simulator tests, zero
skips and zero runtime warnings (`ui-summary.json`). Mac compilation, matched
component timings and the unchanged full component gate remain pending. Physical/iPad/native Mac interaction acceptance is not established.

The unrelated Xcode test still occupies the host's performance gate. A combined
verification run is being prepared for this repair and the preceding Calendar
header-publication correction; the earlier header-only idle monitor was explicitly
superseded, with its unmeasured result preserved. The iPad Calendar preview remains
unchanged. No baseline or workload is reduced.
