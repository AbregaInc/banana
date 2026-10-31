# Native Day viewport integration — October 10

Status: **experimental, not default; full Calendar integration and physical latency acceptance remain incomplete.**

The real iOS/iPadOS Day screen now has a `--calendar-native-day` comparison path:
`DirectionalDayScrollView` owns a `UICollectionView` instead of a `UIScrollView`
containing the full day's event view tree. The existing ruler/background is hosted
behind reusable fixed-frame event cells. The same event geometry, SwiftUI artwork,
event actions, pending-write badges and move closures are used. UIKit owns the
actual viewport; there is no full-day collection nested inside another scroller.

Native framework choice: UIKit's custom collection layout and
[UIHostingConfiguration](https://developer.apple.com/documentation/swiftui/uihostingconfiguration),
following the existing Mail iOS host. It supports the deployment target and avoids
a third-party recycler. This is not an AppKit API; native Mac integration remains
separate. The [custom layout documentation](https://developer.apple.com/documentation/uikit/customizing-collection-view-layouts)
describes cached attributes and viewport rect queries. The initial implementation
uses a simple intersecting-frame scan, not a speculative spatial index.

The native path changes cell lifecycle and has **not yet established a speedup**.
It still computes full-day placement geometry using the existing scans. Week and
Agenda still use their previous hosts. Prepared artwork remains independently
opt-in. Existing iPad prepared Agenda failures and cold Notes/podcast budget
failures remain open; this work does not replace those gates.

## Retained first run

Raw evidence: `.build/calendar-native-day-20261010/`.
Optimized build succeeded. The first same-binary N/R/R/N comparison plus prepared
native check recorded **fail/pass/pass/fail/fail**. All three native tests failed
at the new viewport identity assertion, before performance measurement. The
saved hierarchy in `0-native/attachments/56D9833B-30BB-4FBF-A502-30879DC5AAE0.txt`
shows a real `CollectionView` containing event cells, with identifier
`plan.surface.day`: SwiftUI propagates the parent's accessibility identifier onto
the representable root. The test incorrectly expected `calendar.nativeDay.viewport`.

The corrected assertion requires **CollectionView + plan.surface.day**, so a
reference UIScrollView cannot satisfy it. The original failures and source/binary
hashes are retained. Neither successful reference run establishes native parity.

## Acceptance work

- Same-binary counterbalanced scrolling/detail checks; prepared and reference artwork.
- Paging date/identity and scroll-position preservation; zoom and creation checks.
- Reuse cancellation, active drag, travel and durable failed-write interaction parity.
- Full persistent component suite, including its existing cold query failures.
- iPad, native AppKit, physical frame/input measurements and remaining calendar modes.

XCTest gesture duration includes automation; Simulator scrolling metrics and
component timings do not establish 120 Hz or input-to-visible compliance.

## Corrected same-binary comparison

`corrected-comparison/` retains R/N/N/R plus a native-prepared run, each with the
same 30-day workload and three measured up/down gesture pairs. **All five passed**
scrolling, actual-mode checks and opening the selected event's own detail. The
native-prepared run also required installed prepared artwork. The optimized app
binary hash is in `binary-sha256.txt`; no renderer baseline or budget changed.

Across the six samples per non-prepared policy, median physical memory was
201,370 kB for reference and 192,498 kB for native. This is an observed Simulator
working-set reduction (~8.9 MB), not a physical-device budget. Gesture/deceleration
metrics do **not** establish a speedup: automation and gesture duration dominate,
and no frame-deadline or input-to-visible metric was exported.

`iphone-interactions.xcresult` passed both additional tests: four adjacent-day
swipes preserve the visible hour position and restore the original date/event IDs;
pinch expands hour spacing; holding and dragging an empty audit slot presents the
new-event editor. The creation test opens the editor without saving a real event.
Active event movement/recurring edits, live-update-during-drag and failed-write
retry parity remain unverified.

## Prepared-artwork work reduction

`preparation-{0-reference,1-native,2-native,3-reference}/` is a fresh-process R/N/N/R
comparison using `profile-app.py --mode day --trials 1 --day-viewport POLICY`.
Every run completed its redraw probe, drained the queue, dropped no samples and
had zero queue rejections. All raw cache-miss samples and binary/device identities
are retained in `preparation-comparison.json`.

| Policy | Rasterizations | Total measured raster work | Peak sampled RSS | Consumer images |
| --- | ---: | ---: | ---: | ---: |
| Reference 0 | 107 | 96.231 ms | 466.23 MiB | 2,652,480 bytes |
| Native 1 | 45 | 39.168 ms | 449.95 MiB | 1,113,920 bytes |
| Native 2 | 44 | 37.263 ms | 450.06 MiB | 1,113,920 bytes |
| Reference 3 | 106 | 93.871 ms | 466.22 MiB | 2,652,480 bytes |

This supports **less initial preparation work and image ownership**, not faster
individual rasterization or first-frame completion. The work sums multiple queued
jobs; it is not one stall. Individual maxima were 2.61–2.83 ms reference and
2.69–3.06 ms native. These runs include model-measurement fixture startup, so their
peak RSS is not comparable to the XCTest steady-scroll memory figures above.
Cold/warm/eviction artwork coordinator checks and integrated physical interaction
acceptance remain separate requirements.

## Persistent suite: still failing

The complete `component-regression/` run exited 1. Calendar/Mail component and
redraw gates had no failures. The retained failures were:

- 90-day Notes search: first 134.429 ms, subsequent six 48.636–49.849 ms.
- 90-day podcast next-across-catalog: first 247.465 ms, subsequent 46.804–48.008 ms.
- 90-day podcast download-candidates: first 268.493 ms, subsequent 58.975–62.590 ms.
- Notes redraw scenario's **query** baseline: first search 45.700 ms versus
  19.598 + 2.940 ms allowed; subsequent searches 17.567–18.145 ms. This is not a
  redraw-loop assertion failure.

`component-gate.json` and `component-measurements.json` preserve all eight cases.
The [previous cold-query diagnosis](../calendar-agenda-accessibility-20261010/README.md)
reproduced these query paths in pre-location-change binaries and sampled waits in
SQLite's file reads. No new cause was assigned from timing alone in this run.
The full suite remains failed; no baseline was raised or selectively replaced.

## iPad, lifecycle and native Mac

`ipad-native-day.xcresult` passed **4/4** tests on the dedicated iPad Simulator:
reference artwork in native cells, prepared artwork in native cells, paging/zoom,
and blank-slot creation. The source-qualified creation selector was also rerun
successfully on iPhone (`iphone-create-qualified.xcresult`). No test was skipped.
These passes do not fix or supersede the separate prepared **Agenda** failure.

The unchanged preparation coordinator's **265 lifecycle checks passed**, retaining
cold/warm, eviction, cancellation, bounded queue and consumer ownership samples.
The native Apple Silicon `BananaMac` build also passed (AppKit, arm64). This was
compile/link evidence only; no Mac window interaction was driven. Existing Intel
Needle-library compatibility remains outside this change.

The reduced initial preparation work justifies a **reviewed native-Day baseline
reduction after adoption**, rather than preserving the reference's ~95 ms aggregate
preparation cost. First freeze the date/viewport workload and collect enough cold,
warm and eviction repetitions to establish its variance. No existing frame,
input, component or memory threshold was changed here.

Next adoption work: event movement/cancellation and live-update parity, failed-write
retry/recurring actions, deterministic rendered-geometry checks, then Week/Agenda
and AppKit hosts. Real 120 Hz frame and input-to-visible acceptance remains missing.
The dense Day screenshots still show the reference's narrow overlapping lanes;
this pass does not claim a redesign or exact screenshot parity after synthetic
swipes that settle at different offsets.

Cleanup: removed 26 obsolete temporary fixture directories (3.829 GiB logical), retaining raw results, comparison binaries and backups of the failing 90-day Notes/podcast databases. Both fixture Simulators are shut down; workspaces and worktrees remain.
