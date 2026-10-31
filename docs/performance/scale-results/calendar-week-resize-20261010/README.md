# Native Week rotation regression — October 10, 2026

`ScaleStressUITests.testNativeWeekRotation` exercises the actual opt-in Week
viewport with varied data on iPhone: select a column, rotate to landscape, then
back to portrait. It verifies the selected column offset under each new width,
the frozen gutter and nonempty visible cells. The iPad review build is untouched.

The frozen implementation failed returning to portrait: its coordinator only
reapplied the column offset when the selected index changed. Geometry changes
were ignored. The original result bundle and attachments are retained in
`.build/calendar-week-resize-20261010/control.xcresult`, with summary and identity
beside this document. The run also emitted a SwiftUI publication-during-update
warning; this remains separate investigation work, not a passing warning check.

The candidate tracks viewport, column and content widths as well as selected
index. The first candidate also added a layout width-change callback; that callback
was removed after the shared UI tests found a startup regression.
No timer, data cache, workload reduction or baseline change is introduced.

Candidate UI verification and the full eight-case component suite passed against
unchanged baseline version 1. This is a correctness
repair, not a claimed speedup. Physical resize/frame/input performance remains
unmeasured; Simulator rotation duration includes automation and is not UI latency.


The first candidate passed Day paging but failed three Week cases: initial x=0
left all 46 descriptors outside the visible columns, and the dense-scroll test
could not find event artwork. The full suite was not run on that failed candidate.
Its results remain in `fixed.xcresult` and `first-candidate-summary.json`. The next
controlled candidate retains only geometry invalidation in the existing update
path, removing the new layout callback. Its optimized build and all four UI checks passed, zero skips: Day paging/zoom,
dense Week scrolling/selection, varied Week navigation and portrait/landscape/portrait.
The new layout callback was the only implementation difference between the failed
first candidate and this passing candidate. Full component verification passed.


The final source and app hashes match the candidate identity after the gate.
No baseline was changed or scenario removed. Both failing bundles remain retained.
The iPhone test Simulator was shut down and 17 task-owned temporary fixtures
removed (2.517 GiB logical); the iPad review instance and its data were preserved.
The reviewed iPad binary does not yet contain this repair. No new iPad/device
rotation or physical latency evidence is claimed by the iPhone result.
