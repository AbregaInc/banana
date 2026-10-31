# Varied multi-calendar full-app workload — October 10

Status: **qualified iPhone/iPad varied UI checks, generator/harness checks, full legacy component gate and native Mac build passed. Physical UI timing remains unmeasured.**

`--stress-calendar-fixture varied-v1` reuses the established benchmark generator
inside the full app. The four application targets include the same source file;
its configuration type is now explicitly named `CalendarFixtureConfiguration` to
avoid shadowing GRDB.Configuration. The first app build exposed that collision
and failed; `build.log` is retained. The corrected build passed. The original
standalone invocation also omitted DayGeometry.swift; the corrected invocation
and result are retained rather than describing the first command as a pass.

The app anchors the generator to today's local day with zero leading days. The
prototype defaults (October 8 anchor, 15 leading days) remain unchanged. Existing
fixture checks plus app-anchor/density coverage passed **11,549 assertions**;
all **59 Python benchmark-harness tests passed**. Type renaming changes no
fixture algorithm. The original legacy full-app fixture retains its original
counts, timestamps, identities and uniform geometry when the flag is absent.

The supplemental workload has 12 source-calendar IDs/colors, variable overlap,
12 durations including overnight/multiday events, distinct daily/weekly geometry,
and mixed-length/multilingual titles. It preserves total and seven-day-block
volume while varying daily counts. The app records the source content checksum,
actual installed calendar counts/colors, anchor and daily/weekly diversity in
`scale-calendar-fixture.json`, and exposes that same metadata to UI tests.
No accounts, provider sync or external writes are enabled. Calendar source-picker
filtering, recurrence expansion and live updates are not simulated by this fixture.

`--stress-events-per-day N` (1...1000) is accepted only with the supplementary
fixture. It is a mean daily volume, with actual min/max daily counts reported.
This enables controlled capacity exploration; a Day test at the initial date
alone cannot establish worst-day capacity across the whole history.

New actual-app UI cases: `testVariedReferenceDayScroll` and
`testVariedNativeDayScroll`. Both require 3,000 events, 12 populated calendars,
30 distinct day patterns and four complete week patterns before measuring three
scroll pairs, opening a visible event and paging to the next day. They retain
fixture metadata and screenshots. Long titles containing commas are preserved
when checking the selected detail. These test 30-day default fixtures.

The preparation collector additionally accepts `--fixture varied-v1 --density N`,
validates the installed workload and copies its metadata into every report. Keep
R/N/N/R policy comparisons on the same checksum and density. Raw work lives under
`.build/calendar-varied-app-20261010/`. Simulator API/gesture/memory results do not
prove physical 120 Hz frames or input-to-visible performance.

## Preliminary title-quality correction

All four first R/N/N/R scroll/open/page checks passed, but visual inspection showed
that the adapter's added `Varied …` prefix dominated narrow labels. This weakened
realistic text coverage. These bundles remain in the parent output directory and
are **preliminary**, not the final comparison. After the last XCTest completed,
the orchestration parent was stopped before its queued profiles/component runs;
its terminal 137 is deliberate collector termination, not an app/test crash.

The final adapter removes both the artificial prefix and the generator's calendar
name prefix, leaving the actual multilingual meeting title first and its stable ID
suffix intact. Source calendar identity is still supplied separately to painting.
The app now additionally records `installedContentChecksum` over the actual
adapted titles, timestamps and source calendars; the collector rejects missing
checksums. Revised builds/results go to `revised-titles/`, preserving the first runs.
The source generator and its prototype fixture titles remain unchanged.

## Retained title-assertion failure

The first revised-title reference run exited 65 after opening a detail. Its log
shows the tapped label repeated `Design review · 0-7, 12:51 AM` three times; the
test incorrectly stripped only its final time suffix. The retained recording
(`identity-failure-actual-detail.png`) proves the app opened **Design review · 0-7**.
This failure is a test-expectation bug, not evidence that a different event opened.

The test now takes the complete title through its first stable fixture-ID suffix,
preserving internal commas and non-Latin text, and still requires exact matching
of the actual detail title. New collection uses `qualified-identity/`; the app
binary is unchanged by this test-only repair. The repeated accessibility label
is a separate unresolved app accessibility defect, not silently treated as correct.

The renamed standalone native benchmark also compiled. That check exposed a
pre-existing duplicate `timeZone` key in its final report literal; the duplicate
was removed and the corrected compile completed without that warning. No native
benchmark window was opened, so this is compile/report-source validation only.

## Qualified-identity comparison

All four revised R/N/N/R iPhone scroll/open/page checks passed. The same optimized
app binary was used after the test-only identity correction. The actual installed
checksum was `269619d2f27f88af` in every preparation report; the workload contains
3,000 meetings across 12 calendars, with 27–175 starting events per day (mean 100).
Native screenshots were visually inspected and show distinct calendar colors,
Japanese/Arabic glyphs and varied extents, with dense-column readability still poor.

Steady physical memory medians per run (kB): reference 204,114.416; native
195,332.592; native 194,759.176; reference 203,262.472. Across six samples per host,
native retained about 8.6 MB less. Raw scrolling/clock durations are kept, but they
include gestures/automation and are not frame or input-to-visible samples.

| Host | Preparation jobs | Sum preparation ms | p95 / max ms | Peak RSS MiB |
| --- | ---: | ---: | ---: | ---: |
| reference | 69 | 77.978 | 1.794 / 2.673 | 468.203 |
| native | 44 | 56.062 | 2.054 / 2.771 | 457.547 |
| native | 45 | 61.900 | 2.170 / 2.878 | 457.391 |
| reference | 69 | 86.463 | 2.021 / 2.642 | 468.422 |

All four collectors completed with complete samples, passing idle-redraw checks
and bounded image ownership. Native does less total preparation, but its per-job
tails are slightly higher. These timings exclude queue-to-ready and presentation;
no frame/input compliance or maximum supported event density is claimed. The
unchanged full legacy component gate and iPad checks remain separate validation.

The full legacy persistent component suite completed with exit 0 and no failures
against baseline version 1: all four history tiers and four redraw probes. The
rebuild preserved the qualified app binary hash. No baseline, threshold, legacy
workload count or checksum changed. The separate varied profiling reports also
retained passing model-operation reports; those do not replace the full gate.

The qualified iPad Pro 13-inch M5 / iOS 26.5 Simulator scroll/open/page case passed
with no skips; its metadata again required all 12 calendars. Its screenshot was
visually inspected and retained. Text diversity is now actually visible, but
narrow columns remain a usability limitation even on iPad under this overlap load.

Both owned Simulators shut down before cleanup. Removed 22 UUID-scoped temporary
fixture directories (3.246 GiB logical), retaining all preliminary/failed/corrected
results and the earlier failed-query database backups. No worktree/workspace was
removed. Physical display/input acceptance, live sync/filtering and the integrated
app's worst-day density limit remain open.

Native BananaMac Release/arm64 compile/link completed with exit 0. This is compile
evidence only; no Mac window was driven and no desktop frame/input pass is claimed.
