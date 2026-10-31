# Native interaction investigation — October 8, 2026

**Performance acceptance still fails.** These are actual native Mac interactions recorded with
Instruments, not Simulator component timings. No input-to-visible or 120 Hz display-delivery
pass is claimed. Optimized Release arm64 builds include DEBUG solely for isolated fixtures.

## Measured work

| Recording | Main-thread commit p95 | Maximum | Result |
| --- | ---: | ---: | --- |
| Original legacy Plan/Mail, AX queries inside recording | 43.861 ms | 664.422 ms | Fail |
| First fixes, same mixed scope | 23.445 ms | 501.310 ms | Fail |
| Plan only, before travel index | 273.630 ms | 277.788 ms | Fail |
| Plan only, after travel index | 154.980 ms | 170.348 ms | Fail |
| Larger mail/calendar profile, warm Plan | 134.950 ms | 150.023 ms | Fail |
| Larger mail/calendar profile, warm Mail selection/scroll | 2.498 ms | 8.544 ms | Fail: one commit over 8.3 ms |

All listed recordings completed. The JSON files beside this report preserve samples, build
identity, host conditions and limitations. These are diagnostic comparisons on a shared host,
not controlled causal benchmarks. Early runs overlapped our builds; the larger-profile runs did
not. AX observations were excluded during the Plan-only and larger-profile recording windows.

Plan recipe: warm Today in five-day mode; scroll down three pages and up three pages; Later,
J, K, K. Mail recipe: warm inbox, second row, twelve J keys, six K keys, scroll down three pages
and up three pages. Observe resulting state after recording. UI automation wall time is not
input response time. Fast Core Animation commits cannot certify GPU/compositor delivery.

## Workload correction

The legacy 30-day fixture contained 60,000 emails, 3,000 events, 30,000 notes and 300,000 episodes.
That podcast-heavy mix was inappropriate as the default user review workload. It remains intact
as a capacity regression scenario; neither workload nor baseline was weakened to manufacture a pass.

The new independent `mail-calendar` profile contains **180,000 emails, 36,500 events, 5,000 notes,
100 podcasts and 20,000 episodes**. The UI showed Inbox 180,000 and 100 scheduled events today.
The native model report confirms these totals and 615.5 MB RSS. Its cold first-page mail query
failed at 62.960 ms against 50 ms; calendar window failed at 27.713 ms against 16 ms. The other
six components passed. These fixtures use the in-memory mail source; they do not establish
production SQL paging, live sync or durable failure recovery acceptance.

## Fixes and remaining work

- Cache mailbox totals and preserve first-page rows for read/star changes that do not alter
  membership or ordering. Fixture read-mutation p95 fell from 41.397 ms to about 0.08 ms.
- Avoid scroll-offset-driven calendar view invalidation and identical hover/state updates.
- Query only the indexed visible calendar window; compute date boundaries once per day.
- Replace repeated per-event full-history travel scans with snapshot-owned minute indexes,
  preserving strict tolerance, first-match order and invalidation semantics.
- Remove whole-grid page-change animation from the immediate navigation path.
- Actual composer typing exposed a SwiftUI rich-text exclusivity crash. The error log is retained
  at `.build/mac-stress-previews/20261008-090356-918038/app-errors.log`. The attempted typing
  recording is a crashed/incomplete scenario and cannot be used as a passing measurement.

Calendar's remaining 150 ms commit, cold window/index construction, and cold mail first page
remain optimization work. Do not consider loading the preview or passing component tests enough.
Real 120 Hz iPhone/iPad/Mac display delivery and direct input latency remain unmeasured.

## Verification and retained failures

The travel-index change passed all eight persistent Simulator component scenarios:
`.build/native-ui-performance/travel-component-regression/gate.json` (copy retained here).
Mail fixture correctness passed 19 tests in `mail-correctness-arm64.xcresult`. Pure date-range
and minute-match helpers passed 140 and 722 standalone equivalence checks respectively.
Python performance-gate/trace-parser tests passed 19 checks. No baseline was auto-updated.

Native XCUITest was attempted before and after Automation Mode policy and Developer Mode were
enabled. Its standalone signed runner remained at `_dyld_start` before executing tests; native
functional XCTest is blocked, not passed. Preserve `native-functional-authorized.xcresult`, its
log/sample, and `uitests-20261008-090244/`. The actual interaction recordings above used the
existing computer-use connection. Unsupported Instruments/Time Profiler attempts and incomplete
traces are retained under `.build/native-ui-performance/before/`.

After stable repeat measurements, review a tighter fixture read-mutation baseline (candidate
1 ms versus the current 100 ms component ceiling). Do not apply this reduction automatically;
keep the product frame/input/UI budgets unchanged.

## Composer regression follow-up

The composer now stores rich edits synchronously but coalesces view notifications onto the main
actor after the editor callback returns. This preserves immediate draft/save/send reads while
avoiding reentry into SwiftUI's exclusively borrowed rich-text storage. Equal writes remain no-ops.

All **85 targeted correctness tests passed** in
`.build/native-ui-performance/composer-correctness-coalesced.xcresult`, covering composer behavior,
fixture caching and calendar/minute-index helpers. The first run is retained as
`composer-correctness.xcresult`: 84 passed and one old expectation failed because it required more
than 40 synchronous composer notifications per burst. That assertion was revised to allow
coalescing while retaining checks that inbox/reader/navigation receive no notifications; a new
regression checks that the latest text is immediately readable and no notification reenters the
editor callback. This is a correctness expectation change, not a performance-budget adjustment.

The fixed native build survived individual key events for “performance typing burst”, Select All,
Left and End. Escape kept the draft; the Drafts list and reading pane both displayed the exact
text. The completed typing trace still **fails**: 49 commits, p95 22.788 ms, maximum 24.689 ms,
21 commits above 8.3 ms. This run overlapped a component build on a heavily loaded shared host
(one-minute load 70.78); it establishes neither low-load performance nor input-to-visible timing.
The fixed preview is `.build/mac-stress-previews/20261008-091252-038410/Banana Stress Review.app`.

The next component rerun (`composer-component-regression/gate.json`) failed the relative
first-page mail baseline in the redraw-mail case: 15.042 ms versus 12.830 + 2.000 ms.
The redraw-plan case also failed notes search (548.018 ms), next podcast (344.640 ms),
and download candidates (60.796 ms), including two absolute component-budget violations.
It overlapped the next native build. The failed result is retained; the baseline is unchanged.

A subsequent CPU sample found repeated locale convention/DateFormatter construction in calendar
labels. A bounded eight-locale cache now invalidates on locale-preference changes. Standalone
before/after comparison preserved all 384 outputs across eight locales; 1,000 ranges measured
39.525 ms before and 6.884 ms after on this host. This is component evidence only.

## Final native build and verification

After the locale cache, all **91 targeted correctness tests passed** in
`.build/native-ui-performance/final-correctness.xcresult` (summary retained here).
The complete final Plan trace (`mail-calendar-plan-formatted.json`) remains a failure:
35 commits, p95 143.286 ms, maximum 144.842 ms, six over 8.3 ms. No own builds overlapped
this recording, but the shared host had one-minute load around 109 on ten logical CPUs.
The isolated formatter improvement therefore does not establish an end-to-end calendar win.

Current review app: `.build/mac-stress-previews/20261008-092250-870104/Banana Stress Review.app`.
It retains 180,000 emails and 36,500 events, and is left open for review. Earlier preview copies,
fixture stores, crashed-run logs and traces remain on disk. Final acceptance is still open;
next work must reduce calendar view construction/layout, cold page/index preparation and rich
composer redraw work, then measure actual input-to-visible and display delivery on real hardware.

The final persistent component suite passed **all eight scenarios**, with unchanged baseline:
`.build/native-ui-performance/final-component-regression/gate.json` (copy retained here).
The previous failed component run remains recorded above and in `composer-component-gate.json`.
The native UI test source passes Swift type checking with the XCTest overlay, but its functional
runner remains blocked. Python parser/gate tests pass all 19 checks. Final native workload
component metrics are separately retained in `final-mail-calendar-components.json`; the normal
regression suite pass does not erase failures in that larger independent workload or native UI.
