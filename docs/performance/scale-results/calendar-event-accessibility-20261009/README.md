# Native event accessibility grouping — October 9, 2026

This opt-in experiment uses SwiftUI's native accessibility element API, not a new accessibility
framework. Apple supports it on AppKit/macOS as well as iOS. The implementation exposes one button
per rendered event piece, an explicit title/time label, state value, and activation action. Physical
multi-day pieces remain distinct. The default continues to expose the original child elements.

Sources: [ignore](https://developer.apple.com/documentation/swiftui/accessibilitychildbehavior/ignore)
and [combine](https://developer.apple.com/documentation/swiftui/accessibilitychildbehavior/combine).
Explicit labels and state were chosen because automatic child merging joined unrelated titles and
hour labels in the observed tree. Completed/incomplete, skipped, overdue, free, invitation and save
states are represented explicitly. Full VoiceOver navigation and travel-detail semantics remain
unverified. No performance benefit is claimed before timing comparisons.

## Native functional evidence

The new same-binary control passed all nine tests, including simulated local-write failure with a
retained draft. Its representative single-piece event had two accessibility elements; the grouped
variant had one button. The initial grouped suite had seven passes and two failures, both retained.
The click/drag probes had targeted the center of the full event frame, where the overflow badge
covers it. The failure hierarchy shows event 2 at x692.5/y287.5, width52.5/height29; its center is
inside the overflow badge at x714.6/y298.6, width36.2/height18.8. The activation failure opened that
badge's popover. Previously the probe targeted the smaller image element, whose center was clear.

The corrected probes use the event's visible leading interior. Both targeted checks passed in
`.build/native-ui-performance/uitests-20261009-025805/ui.xcresult`, preserving assertions for the
correct detail title and visible move rejection/rollback. The subsequent complete grouped suite passed all nine tests in
`.build/native-ui-performance/uitests-20261009-025928/ui.xcresult`. This is a test-coordinate correction, not a removed scenario or relaxed assertion.

Flag: `--calendar-group-events`. Use `--calendar-observation-audit` for count assertions.
Raw desktop recordings and xcresult bundles remain local. Test wall clock and element counts do
not establish input latency, frame delivery or a general calendar speed improvement.

## Matched native paging trace

Fresh processes, same Release+DEBUG binary and workload, built-in display configured at 120 Hz.
Four alternating half-page wheel pairs, four forward J pages and four K returns; AX observation
after each pair/key. No observation audit footer. Both recordings completed with the app alive
and no sampled competing developer jobs.

| Policy | Main commits | Commit p95 ms | Commit maximum ms | Busy run-loop maximum ms |
| --- | ---: | ---: | ---: | ---: |
| Original children | 326 | 56.868 | 167.543 | 103.540 |
| Grouped events | 294 | 50.570 | 167.412 | 107.978 |

Both fail the unchanged 8.3 ms commit-work lower-bound gate. The worst commit is essentially
unchanged, and this single pair does not establish a general latency improvement. Grouping
remains opt-in. The lower p95 occurs alongside a different commit count and does not establish
input-to-visible or display acceptance.

The separate [frame-instrument probes](frame-instrument-probes/README.md) preserve the failed
full-template/disk-space run and failed long hitch-analysis run, along with successful short
schema probes. They do not replace the complete commit comparison.
