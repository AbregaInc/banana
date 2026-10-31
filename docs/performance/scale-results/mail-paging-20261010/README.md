# Mail paging integration — October 10, 2026

This is incomplete integration work, not UI performance acceptance.

## Reproduced session failure

`MailSessionTests.testScrollingToLoadedBoundaryRequestsAndReceivesMoreRows`
uses the real fixture source and session. The list starts at 100 rows, scroll input
requests growth, and the source must deliver older rows while preserving the
viewport ID and offset. The original ignored `.growTo` effect produced exactly
one failure: row count stayed at 100. The frozen session and failing result are
in `.build/mail-paging-20261010/MailSession-before.swift` and `before.xcresult`.

The initial handler repair passed all 219 session/list-model tests in
`after.xcresult`. The final handoff keeps the previous observation alive until the
replacement delivers its first snapshot. Leaving cancels both, including when
replacement delivery is pending. Two additional delayed-source tests exercise
these cases; `handoff.xcresult` passed all 221 tests, with no failures or skips.
This checks synchronous and delayed delivery and cancellation, not provider sync.

## Native scrolling gap

Neither native list host originally sent its viewport to the session. Therefore
the session repair alone did not fix end-user scrolling. The new persistent
`ScaleStressUITests.testMailScrollLoadsOlderThanFirstPage` targets `stress-1800`,
a day-zero message at 21:00. The fixture has 152 messages at hours 22 and 23, so
the target cannot belong to the first 100 rows. The test must scroll to and open
that exact message, then verify the conversation subject. `ui-before.xcresult`
failed exactly at the older-message reachability assertion (one failure, zero
skips), retaining the full 30-day simultaneous workload. Both native host
viewport callbacks are now wired. `ui-after.xcresult` passed both the exact older-
message case and the existing scroll/open case on iPhone 17 Pro / iOS 26.5
Simulator, with zero skips and zero runtime warnings. Raw XCTest metrics are
retained in `ui-after-metrics.json`; gesture durations are not input latency.
Delivery coalesces to the latest position after the current layout pass. The
control host sources and app SHA are retained beside the results.

## Remaining acceptance

The Apple Silicon Mac build and actual-host cache retirement checks passed.
The unchanged full component suite completed with one regression failure:
`redraw-mail/mail.firstPage.p95MS` was 14.911 ms versus 12.830 + 2.000 ms allowed.
The failing sample was the cold first read; the remaining six reads were cached.
The same query's cold samples across the other 30-day routes were 13.643–14.065 ms;
90-day cold preparation was 35.131 ms. This does not establish the cause of the
run-to-run difference. The current fixture miss scans all stored threads into a
top-50 heap; the query is not a disk-backed production read. No threshold changed
and the failed gate is retained at `components/gate.json`. Source hashes were
unchanged across verification. Native Mac UI remains untested. Check viewport
anchoring, live updates, scene rebuilding, and scrolling/keyboard behavior on Mac,
iPad and iPhone. The 2,000-row cap still needs bounded disk-backed history paging.
The source is still fixture-only in this checkout. Run the persistent component
suite and integrated scrolling measurements; no frame/input speedup or physical
120 Hz acceptance follows from the unit checks above. Baselines are unchanged.

## Additional preparation measurement

`tools/mail-display-tests/run.py` is prepared to measure the real row display
formatter at 100 and 2,000 rows. The earlier retention probe uses simplified
row/display adapters and cannot measure the cost of recreating formatted content
after eviction. The shipping probe ran after the component suite completed. Cold-working-set
100-row preparation had a 23.898 ms maximum; rebuilding 2,000 displays after
eviction had a 169.763 ms maximum (158.274 ms median). Warm 2,000-row lookups were
below 0.3 ms. See `.build/mail-display-20261010/before-fixed-harness/report.json`.
The first probe compile failed because the harness omitted `MailPerson.fromTheirMail`;
that failed attempt is retained separately. These are isolated preparation costs,
not measured physical input latency. A Foundation FormatStyle experiment is under
measurement/parity testing, with no shipping formatter change yet.

## Recurring gate

`tools/mail-paging-tests/run.py` is wired into the dedicated nightly/manual
performance workflow. Its verifier passed against the retained 221 unit and two
UI results (`persistent-verification/gate.json`); three gate tests also passed,
including rejection of missing coverage, skips, warnings and wrong devices.
The full runner command has not yet been run as one combined bundle. The prior
unit/UI commands and their separate build identities remain the evidence above.

The FormatStyle-only experiment (`.build/mail-display-20261010/format-style-first/`)
reduced 2,000-row isolated preparation to 30–35 ms, but failed 303 of 3,600 exact
locale/calendar/timezone output checks (for example, adding a Buddhist era suffix
or removing a Gregorian-era suffix in Arabic). It is **not adopted**. Both timing
and mismatches are retained. The next candidate should preserve DateFormatter's
existing output while reusing prepared formatters, rather than special-casing
locales to pass this matrix. Shipping formatting remains unchanged.
