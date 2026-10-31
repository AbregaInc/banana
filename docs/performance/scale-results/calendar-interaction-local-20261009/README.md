# Mac pointer-state isolation — October 9, 2026

Controlled native SwiftUI experiments retain the original inline parent state as the default.
`--calendar-local-hover` confines snapped pointer position to a background modifier.
`--calendar-local-drag` uses per-event GestureState for the transient transform; the existing
recurrence, commit and failure path handles gesture completion. Neither experiment changes storage.

All previews use the same optimized Release+DEBUG binary, 180,000 emails and 36,500 calendar
events, plus 5,000 notes and 20,000 podcast episodes. Native windows were explicitly moved to the
built-in display configured at 120 Hz. This does not prove the compositor delivered at 120 Hz.

## Correctness and redraw evidence

The corrected control and hover-only variant each passed all seven native UI checks. Across twelve
pointer movements, whole-week body evaluations were 33 with inline parent state and zero with
local hover state. The unchanged parent drag path recorded 18 and 19 evaluations respectively.
These are counts, not milliseconds. See the retained JSON attachments and summaries.

Manual context-menu validation held the pointer stationary while paging October 9 to October 14.
The new-event action opened a draft on October 14 at 03:30, ending 04:30. The draft was cancelled.
No external calendar write was performed. This validates current-day rebinding, not save durability.

The initial corrected-control suite failed because its unscoped OK selector matched both the sheet
and Touch Bar. The still-open sheet blocked subsequent interactions; that run's apparent successful
counts cannot establish coverage. The failure is retained. The selector now scopes to the sheet and
setup rejects any leftover sheet. A fresh complete control run passed.

The drag-only variant also passed all seven checks. Local drag recorded three whole-week body
evaluations, versus 18 in the matched control (completion/error presentation still changes parent
state). Its unchanged parent hover path recorded 31 evaluations. Native timing comparisons are
in progress. No input-to-visible,
frame-delivery or latency improvement is claimed from these functional checks. Raw xcresult bundles
and desktop recordings remain in `.build/native-ui-performance`; small logs and summaries are here.

## First paging/scrolling traces

Four alternating half-page wheel pairs, four forward J pages, four return K pages.
These traces do not exercise dragging, and cannot establish drag latency. The same recipe also
does not reproduce the twelve-hover redraw probe. All three first traces have clean sampled host logs.

| Variant | Commit count | Commit p95 ms | Commit max ms | Main run-loop busy max ms |
| --- | ---: | ---: | ---: | ---: |
| Inline control | 124 | 151.314 | 192.841 | 105.156 |
| Local hover | 130 | 152.862 | 162.788 | 115.767 |
| Local drag | 123 | 149.904 | 161.585 | 108.260 |

All three fail the unchanged 8.3 ms commit-work lower-bound gate. The mixed tails and one trial per variant do not
establish a general paging improvement. Commit work is not input-to-visible latency.

## Persistent component regression

The complete eight-case suite passed unchanged baseline version 1 in
`.build/performance-regression/calendar-interaction-20261009-fixed`; measurements and gate are
retained here. This build includes the separate, default-off event-accessibility grouping experiment
but precedes pending-write durability fixes. The initial build failed on an incorrect accessibility
action overload, before producing measurements; its build log is retained. The call was corrected
to use the default action with a trailing closure. No baseline changed.
