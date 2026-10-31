# Calendar header publication — October 10, 2026

The preceding rotation/navigation suite passed functionally but recorded SwiftUI's
publication-during-view-update warning twice. The candidate routes native Week
header offsets through a coordinator policy: normal drag delivery remains
synchronous; representable make/update delivery is deferred to the main queue and
coalesced to the newest offset. New input supersedes queued geometry feedback.
Dismantling clears the target, and queued blocks retain the coordinator weakly.

`tools/calendar-header-tests` extracts the actual policy and checks these ordering
and lifetime rules in calendar-core CI. Its first 10-check pass ran while the app
compiled, so that run's timing samples are contended diagnostics only. Clean
component collection and same-binary reference/native/native/reference rotation
results are recorded below. Original artifacts are in
`.build/calendar-header-updates-20261010/`. The initial app build failed because a
static stored property was nested in a generic coordinator; the test-only flag is
now an instance constant. The failed build log remains retained.

The reference flag `--calendar-reference-header-publication` deliberately restores
old synchronous delivery. Functional test success alone is insufficient: the
collector also requires the warning in the reference and its absence in the
candidate. Navigation/pinch, Week scroll/selection, shared Day paging and the full
unchanged component gate follow the comparison.

No frame/input-to-visible speedup is claimed. Queue delivery samples do not prove
header presentation timing, and a Simulator cannot establish physical 120 Hz
acceptance. The existing iPad review instance is not updated by this experiment.
The explicit 350 ms all-day overflow transition remains separate unfinished work.


The first same-binary comparison reproduced the warning once in both the reference
and candidate rotation runs. Functional rotation passed, but the warning gate
correctly failed and stopped the run; no full component pass is claimed for it.
Restricting deferral to the representable method's dynamic scope was insufficient.
The result bundle contains no warning stack/source location or console log.

The final candidate additionally treats scroll delegate offsets with no tracking,
dragging or deceleration as programmatic. UIKit layout can adjust offsets after
`updateUIView` returns; this is the next source hypothesis to test, not a proven
attribution from the warning alone. Actual drag/coast delivery stays synchronous.
The pure tests now cover programmatic offsets outside the representable call.


## Completed warning comparison

All four rotation runs passed their functional assertions with zero skips.
Same optimized binary, varied fixture and test path, in reference/native/native/
reference order. The observed publication-warning counts were **1 / 0 / 0 / 1**.
The expanded deferral condition therefore removes the reproduced warning in this
scenario; the first narrower candidate's warning remains retained separately.

Twelve actual-policy correctness checks passed. Thirty queue-delivery samples had
p50 0.0387 ms, p95 0.5418 ms and max 0.9168 ms. Twelve alternating 100,000-delivery
batches measured median direct callback 14.7 ns/delivery versus policy 28.7 ns;
worst batch averages were 36.6 and 54.1 ns respectively. This is added bookkeeping
and bounded deferred delivery, not a scrolling speedup. These component timings
exclude UIKit rendering, frame presentation and input-to-visible latency. Every
sample remains in `policy-report.json`. The initial contended run is not used for
these numbers.

Shared Day/Week integration passed three tests with zero skips and zero publication
warnings. The persistent `compare-app.py --verify-only` reports pass for all five
comparison/integration bundles. The full component gate refused to run because a
separate Xcode test process was active; its `unmeasured` result is retained. The
comparison has no physical-device or updated iPad-preview acceptance evidence.


The competing process was PID 72823, `OnboardingWalkUITest` on Simulator
`FE9F3562-B4AC-4F63-93E3-4ABE28804CDA`, from a different checkout. It was confirmed
live and was not terminated. A background monitor waits for Xcode to be idle,
checks that all candidate source/binary hashes are still identical, and only then
runs a fresh gate under `layout-policy/components-idle`. Until that finishes, full
component acceptance for this change remains unmeasured. The monitor's 30-minute
observation deadline is not a UI performance budget.


The header-only waiting monitor was subsequently superseded while the confirmed
Mail cache-retention repair was prepared. Its cancellation and the untouched
foreign PID are recorded in `monitor-superseded.json`. Full component acceptance
remains pending and is now queued with Mail retention verification; no old-binary
gate is being represented as complete.
