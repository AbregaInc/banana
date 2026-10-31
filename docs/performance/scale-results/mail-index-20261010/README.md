# Mail disk-index integration — October 10

`MailSlices.migrations()` now registers the actual index schema. `MailIndexReader`
reads bounded pages from prepared view membership, continuing by `(sort_key, tie)`
instead of OFFSET. Account and state filters are bound SQL values, display dates
remain separate from view sort keys, unknown-date stubs are counted separately,
and corrupt summaries fail explicitly. It uses the existing GRDB pools; no new
database library or full-history in-memory collection was introduced.

This is engine integration, **not live Gmail or removal of the UI's 2,000-row cap**.
The writer, provider sync and live source still need implementation/connection.
The real app targets built the preceding auth change successfully; these newer
index files have component compilation/checks but await a refreshed app build.

## Retained checks

Artifacts: `.build/mail-index-20261010/`.

- `run-1`: build failed. The query argument array selected a failable GRDB
  initializer; corrected to the typed optional-value array. The harness also
  unnecessarily included UI files with newer platform/dependency requirements;
  it now compiles the actual engine source set only.
- `run-2`: 11 correctness checks passed with explicit schema registration.
- `run-3`: 11 checks passed using the app's actual migration registry.
- `run-4`: all 12 checks passed, including the 180,000-conversation ablation.
  Its primary-file-only byte count was incomplete: most data remained in WAL.
- `run-5`: all 12 checks passed; disk accounting now includes database/WAL/SHM.
  No failed run, sample, scenario or baseline was discarded or loosened.

The tests walk all 6,001 rows across ties and multiple accounts, verify filtering,
newer arrivals between pages, stubs, corrupted summaries and bounded totals.
The registered schema preserves unsigned 64-bit history IDs as text and exposes
recipient/attention fields independently. Query-plan tests reject a temporary
sort or full membership scan for the standard dated/unread page query.

## Query-cost experiment

The fixture has 180,000 distinct conversations (90 days × 2,000 emails, one message
per conversation). Both controls use identical fields, row decoding and result
identity. Twelve samples alternate order for each depth/window combination.

| Reading 50 rows | Keyset median | OFFSET median |
| --- | --- | --- |
| First page | 0.489 ms | 0.497 ms |
| After 179,950 rows | 0.535 ms | 48.213 ms |

The worst keyset sample across first/warm/eviction reads was **11.838 ms**; large
2,000-row windows remain expensive. This supports the planned small moving UI
window; it does not establish a faster integrated app. Three window sizes and
four depths, individual samples and eviction timings remain in `benchmark.json`.
GRDB memory release is page-cache eviction, not a cold disk/filesystem test.

Recorded process peak RSS: **112,934,912 bytes** for the test process including
fixture setup. Index + WAL + SHM: **33,334,544 bytes**. This compact synthetic
schema workload is not representative body/attachment storage or the full app's
working set. Do not use it as a device memory budget.

The host monitor sampled another `xcodebuild` (PID 66029) during measurement;
XCTest PID 6932 was this experiment. No sampling error occurred. This is a useful
controlled preliminary result, **not a calibrated regression baseline**. The
full persistent application suite and physical Mail frame/input/UI checks remain
outstanding. No performance baseline was changed.
