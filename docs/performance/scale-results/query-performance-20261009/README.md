# Notes and podcast query investigation — October 9

This follows the unchanged persistent gate failures retained in
`../calendar-varied-fixtures-20261009/app-regression-repeat/`. It does not certify
frame delivery, direct input latency or device UI acceptance.

## Hypotheses and scope

The 90-day fixture retains 90,000 notes and 900,000 episodes across 900 shows.
SQLite query plans use `episodeDate` for podcast paging. Notes candidate filtering
uses `notesBrowse` to visit the unarchived rows before substring rejection; exact
counting repeats work even when only 100 rows are displayed.

Podcast paging uses GRDB `Data.fetchAll(db, sql: ...)`, which constructs an uncached
`SQLRequest` by default in the pinned GRDB source. The candidate changes only that
page request to `SQLRequest<Data>(..., cached: true)`. The five possible SQL order
strings form the cache keys; snapshot ID, limit and offset remain bound arguments.
GRDB owns statement lifetime and serialized access. There is no decoded-row/result
cache, query-result invalidation change, schema migration, or history truncation.
Correctness tests must preserve snapshots, date ties, playback direction and filters.

The first control collection overlapped an independent iPad UI test and is retained
as contaminated evidence, not a clean paired reference. Subsequent runs must keep
host-monitor results, binary identities, memory, cold launch and repeated-query tails.
No baseline is automatically updated.

## Notes index exploration

`tools/performance/notes-trigram-probe.py` tests SQLite's maintained FTS5 trigram
substring index, documented in [SQLite FTS5](https://www.sqlite.org/fts5.html#the_trigram_tokenizer).
It operates on a SQLite backup of an isolated fixture database. It compares ordered
candidate IDs for literal ASCII queries of at least three characters, including
punctuation/quotes, while retaining Unicode/control rows for subsequent Foundation
verification. Short/non-ASCII queries keep the original candidate scan. This is a
candidate-filter experiment: Foundation's localized predicate and JSON decoding are
not measured. It cannot substitute for the repository or UI benchmark.

The experiment retains build time, database growth, query plans, three alternating
repetitions, warm and `PRAGMA shrink_memory` states. Releasing SQLite's page cache does
not clear the OS disk cache. Process memory, production mutation/rollback behavior,
and physical-device performance remain unmeasured.

Adoption requires more than fast queries: `VoiceNoteStore.load()` currently opens
and migrates the repository on the main actor. A large index rebuild there would
introduce a launch stall. A background build, atomic readiness transition, correct
concurrent edits/deletes, rollback, and localized-search parity must be designed and
tested before this index enters production. No Notes schema change is made here.

## Podcast result: retained implementation

Three alternating full-app control/candidate pairs at 90 days completed with clean
host-monitor reports. No competing developer process or polling error was recorded;
one-second process samples still cannot exclude all system activity. These are
fresh-process launches with seven calls per metric, not physical UI measurements.

| Across three app runs | Control | Cached statements |
| --- | ---: | ---: |
| Next-across-catalog median of run medians | 52.701 ms | 48.480 ms |
| Next-across-catalog observed maximum | 55.697 ms | 55.723 ms |
| Download-candidates median of run medians | 67.384 ms | 61.109 ms |
| Download-candidates observed maximum | 73.006 ms | 64.564 ms |
| Peak process RSS across runs | 668.656 MiB | 668.875 MiB |

Next-episode timing did not improve in the first pair, and its aggregate maximum
was essentially unchanged. Download-candidate medians improved in all three pairs.
This supports a modest benefit, not a universal tail reduction or achievement of
32 ms UI responses. Counts/checksums stayed unchanged. The code change is retained.

`statement-pairs/` isolates SQL fetches across all 900 snapshots, including explicit
`DatabaseQueue.releaseMemory()` and warm reads. That GRDB method clears SQLite page,
schema and statement caches; the OS file cache stays warm. Each process passed 120
ordered-payload/binding comparisons across snapshots, offsets and four sort orders.
For three-row fetches, median released-cache time was 41.68 → 36.07 ms and warm time
41.44 → 35.90 ms. Released-cache maximum worsened 44.30 → 49.32 ms; warm maximum
was 102.62 → 40.82 ms. No slow sample was excluded. Peak RSS was about 78.97 versus
79.09 MiB. The persistent CLI was then exercised separately (`persistent-probe/`):
all six cases and host monitoring completed; its uncached 233.69 ms outlier remains
retained. SQL-only samples omit JSON decoding and cannot replace app measurements.

The first full candidate suite met every numeric gate but remained **failed** because
two process-monitor polls timed out in Plan. No competing developer process was
recorded in that case. One bounded complete repeat **passed all eight scenarios**
against unchanged baseline v1 (`cached-statements-repeat/gate.json`). Both runs are
retained. The earlier notes failures are not fixed by this podcast-only change;
variation without a notes code change reinforces the need to investigate shared-host
noise and the actual search path separately.

18 selected XCTest checks passed (catalog, narrator filter, notes repository), with
results retained at `.build/query-performance-20261009/correctness.xcresult` and a
text log here. Python suites passed 30 root and 41 calendar-runner tests. New probes
compile/run successfully. No native Mac/physical-device UI timing was performed.

## Notes probe: promising selective path, not adopted

The 90,000-note SQLite database grew from 40.56 to 58.29 MiB. The first index build
took 412 ms. Each invocation retains 288 candidate-equivalence/timing comparisons.
The original all-ID probe, followed by count-plus-first-100-row probes, are retained
separately. Neither includes Foundation localized verification or payload decoding.

For count plus page, always using the index changed `needle` median 43.62 → 14.36 ms,
but `ordinary` regressed 26.44 → 98.90 ms (101.76 ms maximum). It is not adopted.
A subsequent FTS5 vocabulary-based chooser falls back to the scan when a trigram's
document frequency exceeds 25% of all notes. This is an experimental threshold,
not a tuned or accepted product policy. The chooser cost is inside each timing.

A bounded 32-gram lookup reduced the broad-query penalty but still added substantial
work. A separately measured one-gram ablation gave:

| Count + first page, median / maximum | Original scan | One-gram chooser |
| --- | ---: | ---: |
| `needle` | 46.28 / 75.20 ms | 14.40 / 15.31 ms |
| `ordinary` | 26.90 / 28.14 ms | 27.69 / 36.14 ms |
| `missing` | 85.80 / 88.97 ms | 8.56 / 9.85 ms |

All reported candidate checks passed; broad-query tails still regressed. Every run
and its host report is retained. This is not a shipping optimization. Localized
Unicode/control-containing records, mutation/migration safety, background building,
physical devices and process-memory cost still need integrated validation. Using a
single gram can miss selective opportunities when a phrase begins with a common
trigram; falling back preserves the existing scan rather than dropping results.

## Reviewed baseline reduction proposal (not applied)

For a separate review, consider reducing the 90-day podcast reference from
63.724/65.378 ms median/p95 to approximately 52.691/55.724 ms for next-across-catalog,
and 77.974/80.569 to 62.264/64.565 ms for download-candidates. These conservative
candidate values round up the worst candidate run median/maximum across the three
pairs and two full suites; `paired/0-cached/cached-90d.json` is their source. Do not
replace unrelated metric references or alter tolerances/budgets as part of that
review. The baseline file is unchanged, and physical UI acceptance remains open.

## Reproduction

Use the read-only copies of isolated stress databases, not a live user database.
The GRDB CLI links the exact module/object from an existing Release Simulator build:

```sh
python3 tools/performance/statement-cache-probe.py \
  --derived-data .build/calendar-varied-fix/app-regression/derived-data \
  --device 5829A24D-81B4-49D9-A31A-C7553C32D527 \
  --database .build/query-performance-20261009/podcast-catalog.sqlite \
  --out .build/new-statement-probe
python3 tools/performance/notes-trigram-probe.py \
  --database .build/query-performance-20261009/notes.sqlite \
  --out .build/new-notes-probe --shape page-and-count \
  --strategy selective --frequency-grams 1
```

The Simulator must be booted for the first command; neither command opens Simulator
or drives desktop input. Initial and later probe-source snapshots are retained here;
the current tool exposes the same explicit ablations rather than replacing them.

Final cleanup shut down/erased the owned test iPhone simulator and removed 0.87 GiB
of rebuildable caches and regenerated probe databases. About 120.1 GiB was free
afterward. Source fixture copies, binaries, reports and worktrees were preserved;
other simulators were untouched. See `cleanup.json`.
