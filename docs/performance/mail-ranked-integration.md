# Ranked Mail search in Banana

The shell and Mail list use the same local search service. A plain query searches subject, sender, recipients, snippet, retained prepared text and non-inline attachment names. The ranker uses the released Tantivy 0.25 engine and its Swift 0.3.4 binding. Structured filters continue to use the existing SQLite predicates. Gmail can still contribute results as they arrive. [Library and earlier experiments](mail-off-the-shelf.md)

## Results

The Beta copy had 256,188 message records. Of those, 199,185 belonged to 142,419 conversations eligible for display. The public fixture had 174,299 message records. All methods received the same query and were graded against the same targets within each fixture. The prototype column is the earlier fielded Python policy rerun on these snapshots. [Aggregate results](scale-results/mail-ranked-integration.json) · [Anonymous per-trial ranks and timings](scale-results/mail-ranked-integration-samples.json.gz)

| Target found in the first five | Chronological | Earlier prototype | Integrated |
| --- | ---: | ---: | ---: |
| W3C human-written test queries | 30/125 | 88/125 | 87/125 |
| W3C development queries | 5/25 | 17/25 | 16/25 |
| Beta known conversation | 22/120 | 36/120 | 34/120 |
| Beta recent sender | 27/120 | 55/120 | 59/120 |
| Beta partial attachment name | 2/100 | 23/100 | 29/100 |
| Beta complete filename, intended conversation | 1/37 | 25/37 | 27/37 |
| Beta complete filename, any same-named file first | 1/37 | 37/37 | 37/37 |

On the public test, 59 queries gained a top-five hit and two lost one against the chronological control. For Beta known conversations, 16 gained a hit and four lost one. Target ranks were stable across all three repeats in the final run. The earlier prototype still found two more Beta known conversations and one more public test target. Retrieval continues to miss 86 of 120 Beta known conversations in the first five.

| Warm query to decoded rows, p95 | Shell, chronological → ranked | Mail, chronological → ranked |
| --- | ---: | ---: |
| All 377 Beta tasks | 38.5 → 7.3 ms | 37.3 → 9.1 ms |
| Beta known conversation | 68.8 → 7.8 ms | 69.7 → 9.6 ms |
| Beta recent sender | 36.8 → 4.8 ms | 38.0 → 6.4 ms |
| Beta partial filename | 4.4 → 4.8 ms | 6.7 → 5.9 ms |
| Beta complete filename | 47.7 → 10.6 ms | 49.1 → 11.3 ms |
| W3C human-written test queries | 226.8 → 13.4 ms | 225.8 → 14.5 ms |

The ranked Beta shell’s median, p99 and maximum were 3.6, 10.6 and 19.6 ms. Mail’s were 4.6, 11.6 and 41.4 ms. Across 1,131 observations per surface, zero ranked Beta snapshots exceeded 100 ms. The chronological control exceeded 100 ms twelve times in shell and ten in Mail. The workload mixes task families in fixed evaluation proportions. Customer query frequencies are unknown.

The first production integration returned all candidate summaries and checked the chronological continuation eagerly. Known-item shell p95 was 146 ms. Looking up candidate IDs before decoding only visible rows, avoiding an account-scoring clause when all accounts are allowed, and reserving places for MIME filenames brought it to 9.5 ms. At that stage Mail’s public-test p95 was still 234 ms. Keeping one scrolling increment of ranked IDs, checking continuation with the next verified match, stabilizing equal scores by message ID and reserving three recent sender places produced the final results above. These successive configurations change multiple features. The timings measure their combined effect.

### Indexing, cold reads and updates

On the Beta copy, the full cache build took 50.7 seconds in the background. Sampled peak RSS of the build test process was 233 MiB. The native index occupied 48.4 MiB after updates, and the SQLite lookup table plus its covering index occupied 49.4 MiB, about 98 MiB combined. These are derived search files in addition to the retained mailbox. SQLite free pages, write-ahead logs and filesystem allocation can change the installed footprint.

Eight fresh processes reopened the built index, searched the same fixed Beta query, replaced one retained message’s snippet and restored it. Reopening took a median 4.3 ms and maximum 28.7 ms. The first five decoded rows took a further median 7.3 ms and maximum **120.3 ms**. OS disk and framework caches were uncontrolled. Median process peak RSS was 68.5 MiB. Replacing one indexed message took 143–173 ms in the background, median 160 ms. The binding commits and reloads on deletion, then commits the replacement. Heavy sync can delay the return of ranked results. Physical-device memory, battery and input-to-visible time need a device measurement before release.

The 61 focused checks passed, the independent public replay passed, and the Mac Beta app built. The stock Simulator component gate remains red. All eight RSS comparisons had also failed in the preceding recorded run. The completed run additionally flagged two fixture inbox timings, two Podcasts timings and a Plan redraw. Three attempts to repeat the measurement after the final Simulator build stopped at the existing concurrent-Xcode guard. A complete rerun on the final source on 26 Nov 2026, with no competing builds, failed the same way: peak RSS stayed within about 2 MB of the run recorded before the ranked index (scale-1d 364.3 MB, scale-90d 720.6 MB, redraw-mail 495.2 MB), and Podcasts `nextAcrossCatalog` p95 was 3.19 ms against a 2.78 ms limit. Swap was about 78% used. No Mail, Plan or redraw timing failed. [Final gate verdict](scale-results/mail-ranked-integration-final-gate.json) · [Final measurements](scale-results/mail-ranked-integration-final-gate-measurements.json.gz) The gate’s Mail timing case exercises the fixture inbox. The ranked service is measured by the dedicated snapshot replay. [Component runs and gate verdicts](scale-results/mail-ranked-integration-components.json.gz) · [Previous component measurements](scale-results/calendar-mail-search-gate.json)

For baseline review, a 15 ms warm p95 guard for each Beta surface on this fixed replay would catch the former 38 ms tail and leave margin above the measured 7–9 ms. Compare each query family’s top-five success separately. A new mailbox and fresh human-written tasks would test whether these gains generalize. Existing device and component budgets still apply.

## How results reach the list

A reusable reader scores up to 200 message candidates with BM25. An additional clause rewards matching all typed words and, for short queries, matching them together in a subject, sender or snippet. Tantivy supplies its tokenizers and English stemmer. A SQLite lookup supplies recent sender matches and exact filenames. File-specific candidates come from a Tantivy filename query, with Apple’s type registry recognizing a typed extension. Original MIME metadata describes files even when their bytes were never downloaded. An available MIME part supersedes the cached filename for the same part. Search reads prepared own text up to the existing 16,000-character limit and can run entirely offline.

SQLite verifies account access and maps message IDs to current, dated conversations. Only the visible rows are decoded. Up to 100 distinct ranked conversations precede the existing date-ordered local and Gmail results. A ranked cursor carries the position in that group. The tail excludes promoted IDs. Another verified ranked conversation establishes that a full first page has a continuation without an exhaustive prefix search. Small result sets still run the literal search to pick up prefix-only matches.

The cache has one writer, a process lease and a completion marker tied to both SQLite stores. Message, original MIME, prepared-text and attachment changes enqueue durable versions in the source transaction. A worker acknowledges a version after committing its Tantivy replacement and updating the lookup tables. An interrupted update can replay. Clean-state checks on both sides of ranking and current SQLite grants protect the read path. Building and catch-up run in the background. An active search can deliver the existing SQLite results until ranking is ready.

The app links a small local Swift package containing the unmodified generated UniFFI source from release 0.3.4 and the upstream XCFramework pinned by its SHA-256 checksum. This avoids loading an unused build-time macro on developer machines and CI. [Upstream release](https://github.com/botisan-ai/tantivy.swift/tree/0.3.4) · [package manifest](../../Packages/MailTantivy/Package.swift)

## Benchmark method

The Release-mode XCTest calls the production parser, Mail search snapshot and Swift row mapper, at the shell limit of five and Mail’s initial limit of 50. Each query is run three times per limit. Orders rotate across trials, and the chronological and ranked methods alternate. Timings include parsing, access checks, thread deduplication, pagination and decoding rows. They end before rendering. The prototype returns ranked IDs only. Target ranks are compared per query on the prespecified first trial. Repetitions assess stability and latency. The raw timings cover the shared development Mac during these runs.

The Beta fixture uses local SQLite backups of one retained mailbox. The installed Beta had an additional sender migration. The replay keeps its already-materialized schema and applies the new search migrations to the copy. The app retains its normal downgrade guard. It reuses fixed-seed, first-query known-item, recent-sender and filename tasks. No date bounds or artificial common-word stress queries are added. A sender task accepts any of the intended sender’s three latest conversations. A filename task targets one conversation, even when several contain identically named files. The exact-filename check also counts whether the first result contains that name. The public W3C corpus has 25 development and 125 test known-item queries written by human searchers with independent target judgments. Its test set has appeared in prior Banana experiments. [NIST corpus and judgments](https://trec.nist.gov/data/t14_enterprise.html)

## Reproduce

Use a private disposable directory outside the repository. The benchmark makes and mutates copies. The source cache is opened read-only. Set `cache` to the Beta Mail cache and `collection` to the W3C collection with topics and judgments, as described in the [search evaluation](search-evaluation.md). The Python reference uses the previously benchmarked Tantivy Python binding.

```sh
work=$(mktemp -d)
uv venv --python 3.11 "$work/env"
py="$work/env/bin/python"
uv pip install --python "$py" tantivy==0.27.0
"$py" tools/search-eval/ranked-mail-fixture.py --cache "$cache" --out "$work/beta"
"$py" tools/search-eval/trec_corpus.py --ranked --collection "$collection" --out "$work/public"
"$py" tools/search-eval/ranked-mail-reference.py --fixture "$work/beta" --out "$work/beta-ref.json"
"$py" tools/search-eval/ranked-mail-reference.py --fixture "$work/public" --collection "$collection" --out "$work/public-ref.json"
tools/agents/xcode-lock.sh python3 tools/mail-index-tests/run.py --ranked-fixture "$work/beta" \
    --out "$work/tests" --scratch-path "$work/build" --filter 'MailGmailSearchTests|MailLocalSearchTests|MailLiveSourceTests|RankedMailReplayTests'
export TREC_MAIL_RULES="$PWD/Shared/LiveFilterRules.json"
RANKED_MAIL_FIXTURE="$work/public" RANKED_MAIL_RESULTS="$work/public.json" swift test --skip-build -c release \
    --package-path "$work/tests" --scratch-path "$work/build" --filter RankedMailReplayTests/testFirstPage
RANKED_MAIL_FIXTURE="$work/beta" RANKED_MAIL_MAINTENANCE="$work/maintenance.json" swift test --skip-build -c release \
    --package-path "$work/tests" --scratch-path "$work/build" --filter RankedMailReplayTests/testReopenAndOneMessageChange
"$py" tools/search-eval/ranked-mail-summary.py --beta "$work/tests/ranked-results.json" --public "$work/public.json" \
    --beta-reference "$work/beta-ref.json" --public-reference "$work/public-ref.json" --out "$work/summary.json"
```
