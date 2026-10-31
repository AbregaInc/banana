# Native Day dragging investigation — October 10

Status: **native move correctness and controlled redraw comparison pass on iPhone Simulator; full integration and physical latency acceptance remain incomplete.**

After the native Day scrolling/paging/zoom/create checks passed, a new real-app
move test holds `Stress event 73` for 0.55 seconds, drags it 56 points and expects
the existing offline move-failure alert. The stress provider rejects lookup before
account restore/networking; no real calendar is edited. After dismissing the
error, the test checks rollback and that paging is no longer gesture-gated.

`before.xcresult` in `.build/calendar-native-drag-20261010/` failed both reference
and native hosts: neither reached the move error. The saved hierarchies show the
entire time grid scrolled by about 46 points (the 56-point drag less pan slop),
instead of moving only the selected event. This was not introduced solely by
native cell reuse. The app's `CalendarCreateGesture.swift` already documents a
similar iOS 26 SwiftUI/scroll gesture-ownership problem for creation.

The candidate adds a native Day root `UILongPressGestureRecognizer`, using the
same prepared rectangles for hit testing and existing recurrence/commit actions.
It has explicit end/cancel handling and allows pinch to cancel an active move.
`--calendar-swiftui-day-move` keeps the old gesture path for same-binary control.
An additional test moves the event beyond the visible viewport.

**The first candidate also failed all three move checks.** At that point no speedup or gesture
fix was established. `native-recognizer.xcresult` and its hierarchies are retained.
Bounded, opt-in `--calendar-native-move-audit` diagnostics now record registration,
hit testing, admission and recognizer states through the collection's audit value;
the subsequent runs below identify where recognition stopped.

The first candidate build failed because it used a pan-only touch-count property
on `UILongPressGestureRecognizer`. It was corrected to the documented
[numberOfTouchesRequired](https://developer.apple.com/documentation/uikit/uilongpressgesturerecognizer/numberoftouchesrequired).
That corrected build passed before the failing candidate tests were run.

## Separate correctness debt found

`WeekView.commitMove` / `SmartScheduleStore.moveMeeting` show a transient optimistic
position, then roll back and show an error on failure. Unlike new-event creation,
this move intent is not persisted in a recoverable journal. The failure test
above checks gesture routing and current rollback behavior; it **does not prove
durable failure/retry**. This needs repair before declaring contract compliance.

## Initial performance finding (addressed below)

The current native recognizer still publishes parent `@State` on every pointer
update, rebuilding full-day geometry. After gesture correctness is established,
compare direct cell transform updates with this parent-state policy. The existing
Mac `CalendarEventDragFeedback` and Day `RenderStats` probe provide useful internal
references. Retain a controlled ablation and avoid treating redraw counts or
Simulator gesture duration as physical frame/input evidence.

## Prevention identified; cooperative policy passes first comparison

The first audit showed only `nativeMoves=true;registered`: no admission callback.
The next audit additionally recorded touch reception and UIKit prevention. It
received the correct content-coordinate point `(330.33, 695.33)` on the event's
hosted view, then recorded:

```
preventedBy UIKitResponderGestureRecognizer state=1 allowed=true
```

In the **same optimized binary**, exclusive recognition failed, while the
cooperative (`--calendar-move-simultaneous`) policy proceeded through admission,
hit event 73, received changed/end states, and **passed** move-failure routing,
rollback, no accidental event detail, and subsequent paging. The summary retains
both outcomes (one pass / one failure). No private recognizer-name check was added
to production behavior; its name is diagnostic evidence only.

The new candidate defaults native moves to cooperative recognition, retaining
`--calendar-move-exclusive` as the negative control. The scroll pan still requires
the hold recognizer to fail, and pinch explicitly cancels a move. The expanded
regression run is pending; this first pass is not yet the full adoption result.


## Local cell feedback: controlled comparison

The optimized native Day host now keeps event-drag feedback in its UIKit cell:
one retained target, one cell transform/opacity/shadow update per pointer update.
The root recognizer survives leaving the viewport. Completion publishes the actual
move or recurrence decision; cancellation/no-op restores the cell immediately.
Horizontal paging is gated by coordinator drag ownership rather than parent state.
The previous parent-state feedback remains selectable with
`--calendar-parent-move-feedback` for controlled comparisons.

`local-comparison.json` and the four accompanying XCTest summaries retain a
same-binary parent/local/local/parent comparison on iPhone 17 Pro Simulator,
iOS 26.5, optimized Release + DEBUG audit flags. All **8/8 tests passed**, no skips.
Each fresh launch uses the unchanged 30-day stress fixture and event 73 at 12:10.
The short drag moves 56 points; the long drag crosses the visible viewport edge.
Both must reach the fixture's provider-failure path, restore event geometry,
avoid accidentally opening detail, and allow subsequent horizontal paging.

| Feedback | Short drag WeekView redraws | Long drag WeekView redraws |
| --- | ---: | ---: |
| Parent 1 | 14 | 128 |
| Local 1 | 2 | 2 |
| Local 2 | 2 | 2 |
| Parent 2 | 16 | 128 |

These counts include commit/failure state changes and support reduced parent
render work. They do **not** measure frame duration, presentation latency, GPU
cost, or peak memory. This optimization adds no artwork cache; it retains only
one active target and weak cell reference. Memory-pressure/physical acceptance
remains open. The existing transient failure rollback still needs durable intent
recovery before full contract compliance. No budget or baseline was changed.

Raw results and the repeatable comparison runner are in
`.build/calendar-native-drag-20261010/`; source hashes are retained in
`local-source-identity.json`. The previous cooperative-recognition interaction
run passed all six selected tests (`cooperative-summary.json`). Expanded checks completed as recorded below.


## Expanded verification and remaining acceptance

- `local-interactions.xcresult`: **4/4 passed**, no skips, on iPhone Simulator:
  native/reference-artwork scrolling + detail, prepared-artwork scrolling + detail,
  creation, and paging/zoom. Together with the move comparison this covers six
  native Day interaction scenarios.
- `ipad-local-interactions.xcresult`: **6/6 passed**, no skips, on the owned iPad
  Simulator. Both short and beyond-viewport moves also measured 6→8 parent
  render counts (delta 2). These are simulator correctness results.
- `component-regression/`: **all eight persistent cases passed**, terminal exit 0,
  unchanged baseline/budgets. `component-gate.json` and `component-samples.json`
  retain verdict, binary identity, environment and every component sample.
  The 90-day case includes 180,000 emails, 9,000 events, 90,000 notes and
  900,000 podcast episodes. Prior cold-query failures remain retained in the
  native-Day report; this isolated pass does not establish their resolution.

No new physical-device or AppKit UI acceptance was collected in this pass.
The native Day host and prepared artwork remain opt-in experiments. Full Week,
Agenda and Mac integration, live updates during a drag, recurring-action parity,
durable move retry/relaunch recovery and physical frame/input latency remain open.
The prepared iPad Agenda failure is separate and not resolved by Day's passing tests.
The next integration step is durable move intent before adopting this host by default.

The reusable comparison is now `tools/calendar-artwork-tests/compare-drag.py`;
its README documents invocation and measurement limits. This pass proposes no
baseline reduction because the existing component baseline does not measure the
new drag redraw quantity. Physical latency evidence is still required.
