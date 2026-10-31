# Disk-backed Mail index checks

```sh
python3 tools/mail-index-tests/run.py --out NEW_DIRECTORY
```

The runner compiles actual engine sources and XCTest cases with the GRDB and SwiftSoup revisions
pinned in `project.yml`. For local checkouts, pass `--grdb-checkout PATH` and `--swiftsoup-checkout PATH`;
the runner rejects a different revision or tracked changes. No app window,
Simulator, credentials or network provider is involved.

Fifty-four cases check registered migrations, unsigned Gmail history IDs, account ID
namespaces, preserved summary fields, indexed query plans, a complete 6,001-row
keyset walk, filters, stubs, arrivals between pages, bounded counts, corrupt data
and a 180,000-conversation query-cost matrix. The same row decoder and ordered IDs
are used for keyset and frozen OFFSET controls. Raw first/warm samples and explicit
GRDB page-cache eviction samples are retained; eviction is not a cold filesystem.
The keyset query fails if a sample exceeds the entire 100 ms UI budget. Passing
does not certify integrated frame or input latency.

Writer coverage includes persisted summary/readback after reopening the stores,
label membership replacement, cross-account provider IDs, transaction rollback,
and preservation of scheduler/attention state and existing label metadata.
`MailIndexWriter` requires the complete effective facts for one conversation in
the existing writer transaction; it is not a raw Gmail page importer. Sync and
body persistence still need their own integration checks.

MIME extraction checks cover alternate bodies, attached text, charset/NUL handling,
missing and malformed data, width/depth/byte limits and invitation metadata. The
`mime-benchmark.json` artifact retains 63 KiB, 261 KiB and 2 MiB extraction samples
without a result cache. A 100 ms extraction sample fails; this component ceiling
does not prove the stricter integrated UI/input/frame contract. No HTML parsing,
disk reads or rendering is included in those extraction samples.

Body-cache checks cover bounded native zlib decoding, corrupt length rejection,
empty/Unicode/incompressible round trips, account isolation, rejection of
incomplete replacement content and readback after reopening the stores. The blob
migration is registered with the real store registry. The cache envelope is
`MBZ1`, four bytes of big-endian decoded length, then zlib bytes; an empty value
has no compressed payload. Decode allocates at most the bounded declared length
plus one byte and rejects mismatches. These checks do not yet measure complete
body-store latency or establish reader integration.

HTML preparation uses SwiftSoup's cleaner and maps the inert document into native
text runs. Checks cover scripts/resource tags, dangerous link schemes, formatting,
quotes, tables/lists and input/depth limits. Generated 63/261 KiB HTML costs are
retained in `html-benchmark.json`; these are not the earlier newsletter fixtures.
Prepared cache entries require both the current preparer version and matching
content revision. Replacement invalidation, stale-writer rejection and reopened
prepared-cache reads run against the real disk store.

The page-loader tests run a controlled asynchronous Gmail provider through the
real writer/importer/reader. They cover continuation across 53 messages, a
four-request concurrency bound, provider failure, account/scope mismatch,
cancellation and post-commit-only notifications. The loader deliberately does
not advance the history checkpoint: enumeration is not completed reconciliation.
The known HTML preparation budget failures remain part of this suite's verdict.

Live-source adapter checks use controlled consent/provider implementations and
real disk stores to verify permission-to-list publication, first-page caching and
label-account precedence. They are not real OAuth or installed-app UI checks.
Unsupported search is explicitly failed rather than populated with unrelated rows;
search implementation and normal app source replacement remain integration work.

Metadata importer cases exercise provider JSON through the real database reader:
unknown versus explicitly empty labels, stale responses, incomplete headers,
overlay preservation, tombstones, account isolation, repeated imports and rollback
on conflicting thread identity. Metadata import deliberately does not mark a body
as persisted. The sync driver and body store remain separate integration work.

`benchmark.json` includes process peak RSS and the index database **plus WAL/SHM**
bytes. It is a deliberately severe one-message-per-conversation dataset, not the
full application's simultaneous email/calendar/notes/podcast workload.
`host.json` includes build and measurement periods; use the benchmark's Unix start
and finish timestamps to inspect the measurement interval. The benchmark's own
`testProcessID` identifies XCTest; any other developer process remains contention.
Do not treat the monitor's own driver overlap as an unrelated job or silently
discard other overlaps. No baseline is created or replaced.

Run the persistent full component suite and all-device Mail UI checks after
integration. This index alone does not remove the UI's 2,000-row cap or connect
Gmail. The `mail-index` CI job retains logs, source hashes, raw timings and host
evidence on failure as well as success.
