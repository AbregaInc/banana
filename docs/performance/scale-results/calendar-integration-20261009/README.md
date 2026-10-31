# Production calendar integration — October 9, 2026

This work is **in progress**, not acceptance of the prototype renderer or of the
120 Hz/input latency contract. Calendar integration precedes email changes.

## Shipping path and integration boundary

The real day/week grid lives in `Banana/Views/WeekView.swift` on Mac, iPhone and
iPad. The Skia/Metal surface lives in a separate benchmark app. Its unresolved
pixel differences and missing interaction semantics prevent a direct replacement.
The native surface prototype also uses fixture-owned data and cannot be substituted
for the production occurrence/pending-write graph as-is.

The first opt-in production-path integration prepares overlap lanes when a day snapshot is
built, instead of sorting/repartitioning on each view evaluation. Mac prepares
its existing overflow groups alongside that layout. Mobile day/week and agenda
grid preserve their distinct filtering policies. Existing block visuals, source
calendar ribbons, free/tentative states, travel bands, all-day controls, context
menus, recurring edits, drag/create gestures, accessibility and durable write
failures remain in the current rendering/interaction layer.

`CalendarLanePlan` is a pure, width-independent index plan. It adopts the prototype's
flat placement storage while retaining production's stable start/end/ID ordering
and strict displayed-minute overlap tolerance. It does not import the prototype's
half-open lane policy, which would change production behavior at sub-minute boundaries.
No new dependency is needed for interval partitioning. The library/platform review
is in [rendering research](../../rendering-research-20261009.md).

Plans are owned by the current immutable day snapshot (Mac: visible-page dictionary
replaced with `days`; mobile: a property on `DayData`). They do not key by event ID
alone. A replacement snapshot includes new title/completion/pending-write data.
The working set is the existing one/seven-day Mac page, three-day mobile day window
or seven-day mobile week/agenda. This is not a retained-history cache. Releasing the
page releases its plans; returning to an evicted page rebuilds them. Prepared
placements currently retain occurrence values as well as lane metadata; pure index
benchmark bytes below do **not** estimate the entire production memory cost.

`--calendar-cache-layout` enables reuse on both platforms in DEBUG audit builds;
`--calendar-recompute-layout` overrides it for a controlled comparison. Production
reuse remains disabled. The prior [Mac comparison](../calendar-layout-reuse-20261009/README.md)
passed functional tests but did not establish an app rendering improvement (p95
55.850 → 55.379 ms; run-loop maximum 99.835 → 115.449 ms). Its evidence does not
justify enabling the candidate by default. There is no baseline change.

An initial local build with reuse enabled by default was canceled before measurement
when that prior evidence was reviewed; its logs remain in `component-suite/`.
The corrected candidate retains opt-in behavior.

## Evidence and scope

`tools/calendar-lane-tests/main.swift` contains a frozen copy of the previous
allocator as an independent oracle. 483 checks pass, including stable-ID ordering,
59-/60-second boundaries, nested/overnight/zero/negative intervals and seeded inputs
through 4,000 events. The test runs in the persistent calendar-core CI job.

Reproduce the pure component comparison:

```sh
swiftc -O Banana/Model/CalendarLanePlan.swift tools/calendar-lane-tests/main.swift -o /tmp/calendar-lane-tests
/tmp/calendar-lane-tests /tmp/calendar-lanes.json
```

All three variants are interleaved across 201 samples at each density. Cold/rebuild
and warm reads are separate. The current result is retained at
[lane-ablation.json](lane-ablation.json). Host scheduling was not sampled in this
microbenchmark, so cold-tail attribution remains unresolved. At 100 events, old/new
cold medians were 0.0158/0.0137 ms; at 4,000, 1.278/1.259 ms. Cold tails are mixed
(new 4,000-event maximum 11.773 ms versus old 3.923 ms), so **this does not establish
a cold-layout speedup**. Prepared reads avoid recalculation; this test includes a
checksum traversal but excludes Occurrence adaptation, SwiftUI layout, painting,
input delivery and presentation. It is not evidence of smooth scrolling.

The Release iOS Simulator app build and full persistent eight-case component suite
passed against the unchanged baseline: [measurements](component-measurements.json),
[gate](component-gate.json). Raw logs/host samples are retained in
`.build/calendar-integration-20261009/component-suite-opt-in/`. Despite that directory
name, the standard suite runs the default policy; it does not enable the experimental
cache. The suite preserves its original fixture distribution and workload counts.
33 Python harness tests also passed.

Five selected iPhone 17 Pro / iOS 26.5 Simulator UI tests passed: default and prepared
dense-calendar scrolling, cue time/tap behavior, and both crowded all-day controls.
[Summary](iphone-ui-summary.json), [raw diagnostic metric samples](iphone-ui-metrics.json).
The result bundle is `.build/calendar-integration-20261009/iphone-ui.xcresult`.
The new prepared-path test preserves the existing 30-day full-app stress workload.
Peak physical memory was approximately 267.1 MB control and 266.5 MB prepared; a
single pair does not establish a memory improvement. Gesture wall-clock samples
were 4.615–5.141 s control and 5.271–5.310 s prepared, including automation/idling and
scroll duration. They do not establish input latency or a rendering speedup.
The Mac Release + DEBUG build also passed (isolated stress-review bundle, not launched).
The same five UI tests passed on an iPad Pro 13-inch (M5) / iOS 26.5 Simulator:
[summary](ipad-ui-summary.json), [raw diagnostic samples](ipad-ui-metrics.json).
iPad peak physical memory was 265.8 MB control versus 267.9 MB prepared; retain this
~2.1 MB increase rather than calling preparation free. Gesture wall-clock ranges
were 2.132–2.146 s control and 2.115–2.152 s prepared. Neither paired Simulator run
establishes an app rendering improvement. Test bundles remain in
`.build/calendar-integration-20261009/`; [build/source identities](build-identity.json)
identify the checked binaries. Both temporary Simulators were shut down and deleted;
`cleanup.json` in the local artifact directory records their IDs. No worktree or
unrelated Simulator was removed. Physical Mac/iPhone/iPad input-to-visible and frame measurements are
also pending. No frame or UI latency target is marked passed by this change.

## Remaining calendar integration

1. Validate prepared layout in the real app, including page changes and edited/failed
   occurrences; record before/after app memory and redraw work.
2. Adapt native prepared artwork/viewport reuse to real occurrence snapshots and
   preserve the existing interaction/accessibility actions. Establish pixel parity
   for multilingual text, calendar colors, merged ribbons, state treatments, travel,
   appearance, resizing and zoom before replacing the rendering layer.
3. Measure native scroll, horizontal paging, cold/adjacent/evicted pages, simultaneous
   incoming updates and direct manipulation on all three physical device classes.
   Keep the Metal path as a measured alternative until its parity and latency gates pass.
4. Optimize measured bottlenecks individually and propose a reviewed baseline reduction
   only after repeatable improvements. Do not advertise lane-plan reuse as completion
   of the full renderer integration.

## Email follow-on

Email already uses `NSTableView` on Mac and a `UICollectionView` list on iPhone/iPad,
with SwiftUI row content and fixed heights. Replacing these with a calendar renderer
is not justified. Start with the existing native recycling path, measure row
configuration/text work, snapshot application and disk paging at 2,000 emails/day,
then optimize the measured cost while preserving selection, unread state, keyboard
navigation, VoiceOver, offline actions and durable retry behavior.
