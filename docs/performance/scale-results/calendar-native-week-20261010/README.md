# Native Week viewport — October 10, 2026

The real iOS/iPad Week screen now has a DEBUG opt-in native collection viewport
(`--calendar-native-week`). Day remains native by default. This is a review
candidate, not default Week adoption or physical performance acceptance.

The viewport reuses Day event cells, clips each event to its day, namespaces
continuations by day, pins the time gutter and updates the narrow header offset
without publishing the whole Week body on each scroll. UIKit owns both scroll
axes; column snapping, pinch, creation and move callbacks use the shared bridge.

## Measured comparison

Same optimized DEBUG application, reference/native/native/reference, three scroll
iterations each, unchanged 30-day legacy stress workload. Four tests passed with
zero skips. Exact identity and memory samples are in `scroll-identity.json` and
`results.json`; full metrics, logs, host samples and result bundles remain under
`.build/calendar-native-week-20261010/reachable/`.

| Run | Viewport | Median absolute process memory (kB) |
| --- | --- | ---: |
| 0 | Reference | 239290.864 |
| 1 | Native | 198461.912 |
| 2 | Native | 198134.232 |
| 3 | Reference | 239503.856 |

Native used approximately 41 MB / 17% less process memory in these runs. This is
not a bounded-history proof. XCTest gesture durations did not demonstrate a
speedup: reference ranges were 4.882–5.284 and 5.195–5.346 seconds; native ranges
were 5.287–5.319 and 5.333–5.355 seconds. These include automation and are not
frame or input-to-visible measurements. The current legacy week sits at the
fixture boundary, so this is not seven fully populated days or a capacity ceiling.

## Retained failure and coverage correction

The first candidate failed while locating event 61, before timing. The reference
accessibility tree exposed that event outside its day column: its x=343 frame was
past the column's x=280 right edge. The old test used it as a scroll anchor, then
opened a different event. Native clipping removed that invalid anchor. Original
reference and failed native bundles and attachments remain in the artifact root.

Both policies now expose a searchable day-item list in populated Week headers.
Protocol 4 explicitly searches and opens event 61 and verifies its detail title,
then uses the clock as the common scroll anchor. No workload was reduced, and the
old result is not substituted for the corrected comparison. Narrow visual lanes
remain an unresolved usability issue; the list provides full event reachability.

## Correctness and remaining acceptance

Actual descriptor helper tests passed 97 checks (`descriptor-report.json`),
including day identity, clipping, callbacks and deferred content construction.
These run in calendar-core CI. iPhone navigation passed one test with varied
3,000 events, 12 calendars and 30 distinct daily patterns; it checks cell reuse,
pinned gutter, horizontal paging, pinch and week changes. The three Day checks
passed paging/zoom, creation and durable move recovery. Summaries are retained.

The full eight-case component suite passed against unchanged baseline version 1
(`components-gate.json`). The first iPad run passed Day paging and dense Week
scrolling, but failed the navigation test's initial reuse assertion (59 visible
cells / 59 descriptors). Its viewport was 1,180.5 points high in 1,344 points of
content, spanning almost the full day; all seven columns fit horizontally. The
test now zooms 2.5× before requiring offscreen cells, preserving the reuse check
under an actual partial-day viewport. The failed summary and full attachments
remain retained. Corrected iPad verification passed all three tests, zero skips
(`ipad-reuse-summary.json`): Day paging/zoom, dense Week scroll/selection, and varied
Week navigation/reuse. `reuse-identity.json` confirms the app binary is unchanged
from the matched memory comparison. Only the test was rebuilt. Rotation/split resizing, Week creation/moves/recurrence, concurrent
updates, eviction, physical accessibility and physical frame/input traces remain
open. The day-list-to-detail transition also needs latency work. Agenda, AppKit
and Mail integration are separate unfinished work.


## Review delivery

The unchanged reviewed binary is installed and running headlessly on task-owned
`Calendar-Artwork-iPad-20261009` (`DFF60927-BA4A-4E8E-9A6E-63A1A4178858`).
Fresh launch metadata confirms 3,000 events, 12 calendars and 30 distinct day
patterns. The actual screen was inspected in `review/calendar.png`; the fixture
starts today, so earlier days in this week are empty. Page forward for full weeks.
Review instructions are `.build/calendar-native-week-20261010/REVIEW.md`.

Removed 26 obsolete task-owned temporary stress fixtures, 3.683 GiB logical,
after both test Simulators shut down. Reports and failure attachments were kept.
The iPhone Simulator remains shut down; the iPad was deliberately restarted and
its fresh dataset retained for the user review. No workspaces were removed.
