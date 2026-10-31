# Notes first-use investigation and search crash correction — October 10, 2026

The preceding [calendar neighbor run](../calendar-neighbors-20261010/README.md)
failed its Plan-route Notes-search baseline: one 65.746 ms first sample, then
approximately 17.5–18.0 ms. Old/new/new/old calendar controls reproduced slow first
searches under both policies (52.312/50.433 ms), followed by fast first searches
under both (18.308/17.419 ms). The calendar optimization is not required to reproduce
that tail. Its underlying wait has not been fully identified.

## Query phase investigation

An isolated Simulator executable links the actual GRDB object, note model and a
frozen repository copy against copies of the retained failing database. A separately
instrumented copy times count, payload fetch, decoding and localized comparisons.
The uninstrumented control remains separate. All 42 count/order comparisons passed.
Raw scripts, snapshots and results are retained locally under
`.build/notes-first-use-20261010/`; source snapshots are also in `probe-sources/`.

One instrumented first query took 35.444 ms: count 32.464 ms, fetch 1.667 ms,
decode 1.177 ms. Its first localized comparison cost 8.725 ms; all 1,512 comparisons
cost 11.157 ms. A later instrumented first query took 22.680 ms, with a 3.337 ms first
comparison. Prewarming localized matching cost 15.169/5.969 ms in separate processes
and moved subsequent first-page work to 21.442/20.802 ms. That moves work earlier;
it does not eliminate it and is not adopted as a fix.

The first uninstrumented process had substantial scheduling variation (47.989 ms
first page, 25.657 ms process CPU, 193 involuntary switches); later samples also
varied. The probe did not reproduce the original app's 282 voluntary switches.
These results identify expensive stages, not the original app wait's exact cause
or a controlled estimate of instrumentation overhead. The host monitor detected no
competing developer process; that is not proof of no system contention. SQLite/OS
cache conditions differ from fixture creation inside the full app.

## Reproduced crash and shipping correction

The mixed-text index experiment crashed **inside the original repository**, before
the candidate comparison could finish. A minimal Simulator reproduction is:

```swift
"Café needle".localizedCaseInsensitiveContains("needle\0")
```

It traps in `String.UTF16View._indexRange` via Swift's Foundation range conversion.
The original repository stack and standalone failure are retained, not discarded.
The native Boolean call succeeds:

```swift
("Café needle" as NSString).localizedCaseInsensitiveContains("needle\0")
```

`NoteRepository` and `NoteQueryCache` now use that native Boolean API. No substring
range is needed. No query is stripped, truncated or reinterpreted by app code, and
no schema/index/migration change is shipped. Apple's [NSString documentation](https://developer.apple.com/documentation/foundation/nsstring/localizedcaseinsensitivecontains(_:))
describes the localized case-insensitive Boolean search; its [Swift counterpart](https://developer.apple.com/documentation/swift/stringprotocol/localizedcaseinsensitivecontains(_:))
describes the range-based equivalent. The crash conclusion comes from the retained
stack and reproductions, not from assuming every Foundation version behaves alike.

The new disk-repository regression checks trailing-NUL hit/miss behavior; the pure
suite additionally covers the real in-memory cache and each of its four fields.
384 checks passed on macOS and 384 on iOS Simulator. Warm API measurements perform
3,600 comparisons per sample, with twenty alternating samples per policy:

| Platform | Swift median / max ms | NSString median / max ms |
| --- | --- | --- |
| macOS | 4.180 / 11.002 | 1.335 / 3.290 |
| iOS Simulator | 4.063 / 4.416 | 1.388 / 1.471 |

This is roughly a threefold API improvement, not a threefold repository/UI speedup.
The comparison excludes the crashing query from the old API timing and tests it
explicitly on the corrected path. Both APIs receive the same non-crashing timed
inputs. Correctness checks warm the API first; no cold matching claim is made.
The persistent `tools/notes-search-tests` suite now runs in performance-contract CI.

## Indexed candidate remains isolated

SQLite's maintained [FTS5 trigram tokenizer](https://www.sqlite.org/fts5.html#the_trigram_tokenizer)
supports substring candidates for queries of at least three characters. The probe
uses it only for eligible printable-ASCII queries, retaining all Unicode/control
rows for the original Foundation predicate. A frequency check keeps broad queries
on the existing scan. The final predicate, exact total, ordering and payload decode
remain in the measured path. Both reference and candidate use the corrected Boolean
API. This closes an important gap in the prior SQLite-only experiment.

All 504 exact count/page/payload comparisons passed across 21 queries, active/archive
states and three trials, including Unicode, controls, punctuation and quoted input.
Each policy has explicit SQLite cache-release and warm samples. OS cache remains
warm. This does not cover production index migration, concurrent edits or rollback.

Active-query median / maximum milliseconds across these samples:

| Query | Scan | Indexed candidate |
| --- | --- | --- |
| `needle` | 15.956 / 16.641 | 6.639 / 7.207 |
| `ordinary` | 24.960 / 25.472 | 25.368 / 25.959 |
| `missing` | 27.232 / 28.215 | 2.716 / 3.225 |
| `Café` (fallback) | 73.161 / 76.481 | 73.301 / 74.632 |
| Japanese `打ち合わせ` | maximum **152.803** | maximum **151.998** |

The Japanese query exceeds the 100 ms response ceiling in the query component
alone on this Simulator. The normal regression fixture's `needle` query does not
cover this gap. Neither candidate is accepted as complete Notes performance.
Index creation took 110.937 ms and cannot be put on the UI startup path. The combined
probe process peaked at 89.7 MiB; that includes both repositories and index creation,
so it is not an incremental candidate-memory measurement. Broad-query overhead and
safe migration/live-write behavior still require work. The failed original index
run and its databases remain retained alongside the corrected experiment.

## Integrated validation and remaining work

All eight repository/query XCTest cases passed, including the new crash regression.
Notes opening and paging passed on iPhone and iPad Simulators (four UI tests total),
with no skips. The full eight-case component suite passed unchanged baseline v1.
Plan-route Notes search in this run was 15.880–16.789 ms, and the 90-day search samples
were 43.115–44.328 ms. That pass does not erase the earlier intermittent failure or
establish that its underlying cause is fixed. No physical display/input acceptance
or native Mac UI result is supplied by these checks.

The changed source hashes match those captured before testing. Both executable
hashes are retained because the post-test/rebuild executable differs from the
initial one. No baseline, tolerance, workload or scenario was removed or loosened.
For a separate review, the warmed iOS API reference could be reduced from roughly
4.063/4.416 ms median/max to 1.388/1.471 ms per 3,600 comparisons on this environment.
Do not lower repository references based solely on that microbenchmark.

Both owned Simulators were shut down. Twelve temporary app fixtures (1.788 GiB
logical) were removed; original failing databases, crash evidence, reports,
workspaces and worktrees were preserved. Remaining work includes the intermittent
first-use wait, efficient localized fallback, safe index construction/update costs,
and physical UI performance. The isolated index is not enabled in the app.


An additional 84,738,048 bytes of duplicate probe databases were removed only after
SHA-256 equality with the preserved failing source was verified. All crash/index
candidate databases remain. The 38 Python harness tests passed after these changes.

To repeat the localized index experiment, compile `probe-sources/index-corrected/`
with `VoiceNote.swift`, `JSONRecordStream.swift` and the pinned GRDB object/module
from an optimized Simulator build, as in `tools/performance/statement-cache-probe.py`.
Run the resulting executable through `simctl spawn` with three absolute arguments:
a **copy** of the stress Notes database for the reference, a second **copy** for the
candidate, and a new report path. The probe inserts 18 mixed-text test records and
creates the candidate index; never point it at a user database. The frozen snapshots
preserve the compared implementation if production code changes later. A separate
review is needed before turning the extended query matrix into a regression gate.
