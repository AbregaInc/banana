# Measuring search across Banana

The baseline inventory below describes revision `f987bd34`. The Mail benchmark below evaluates human-written questions and the calendar section records field coverage before and after the implementation. The first question for each query is whether the surface can reach the intended object. The second is where that object appears. The third is how long it takes to see and open it. A faster matcher only affects part of the third question.

The [Swift Tantivy and pretrained model benchmark](mail-off-the-shelf.md) compares library defaults, fielded ranking and semantic retrieval on the existing mailbox.

## The first query in Mail

The primary interaction is typing a few remembered words and opening the right conversation. Score the first result and first five before any follow-up action. A remembered quarter supplied by the benchmark measures the potential value of a second clue. It does not predict whether someone opens a date picker. In a personal-email re-finding study, fewer than 1% of submitted queries used advanced operators. An observational email-search study found that people repeated a company-name query to reach different recent messages. Gmail describes recency, frequently contacted people and previously clicked messages as relevance signals. [Personal re-finding study](https://www.microsoft.com/en-us/research/wp-content/uploads/2019/02/Mackenzie-www19.pdf) · [Observed email search behavior](https://archives.iw3c2.org/www2017/proceedings/proceedings/p1511.pdf) · [Gmail's ranking description](https://blog.google/products-and-platforms/products/gmail/gmail-search-update-relevant-emails/)

A sender name, a sender plus a topic, a few remembered words and a filename are different tasks. For a recent-sender task, any of the three conversations with the latest messages from that address qualifies. For a particular email, only the intended conversation qualifies. For a fully typed filename, report both the exact conversation and whether the first conversation contains an attachment with that exact name. Identical filenames can belong to different documents.

| First-query task | Previous offline ranker → candidate, sample A | Previous offline ranker → candidate, sample B |
| --- | ---: | ---: |
| Reach a recent conversation from a repeat sender, top five | 31 → 62 of 120 | 34 → 55 of 120 |
| Reach a particular conversation from ordinary sender, subject or snippet cues, top five | 48 → 48 of 120 | 36 → 36 of 120 |
| Find the target thread from one filename word and its extension, top five | 3 → 18 of 100 | 7 → 23 of 100 |
| Find the original thread from a complete filename, first result | 4 → 22 of 39 | 8 → 24 of 37 |
| First result contains an attachment with the supplied complete name | 11 → 39 of 39 | 10 → 37 of 37 |

For a single word, keep the original first result and allow up to two recent sender-field matches into the list. For multiple words, search the retained filenames as well. An exact full filename can take first place. Otherwise allow up to three matching filename results for an explicit common extension and one for other multiword queries. The filename index occupied 848 KiB for 12,714 named non-inline attachment parts from 92,473 retained message structures. It used names already on disk. On sample B, local ID lookup p95 was 0.49 ms for recent-sender tasks and 7.03 ms for partial filenames, versus 0.44 and 0.75 ms for the previous ranker. These include ranking and exclude rendering, Gmail and opening files. [Case ranks, timings and ablations](scale-results/mail-first-query.json)

Sample A used seed 73128 and B used 73129 on the same Beta snapshot. The ordinary known-item group counts only the first attempt for each target. Recent-sender tasks use one word from a display name and sample 40 senders per frequency band (10–29, 30–99 and 100+ distinct threads). The exact-name cases are a subset of the sampled filename targets. These are target-derived proxies, and their frequencies do not estimate the mix of Gmail queries. On the 125 human-written public known-item queries, sender-slot mixing preserved all 88 previous top-five successes and all 57 first-place hits. Also treating one word in a short query as a possible sender and the other words as topic evidence raised first-place hits to 59 and lowered top-five hits to 87. The evidence favors keeping that interpretation experimental. The replay treats the public queries as unscoped free text. It does not consume structured filters, click histories, or target labels during retrieval.

The next relevance set should include independently written purpose queries such as `hotel confirmation` against emails that call themselves itineraries, an old distinctive phrase, and an order or tracking number. Record acceptable conversations before scoring. For broad queries, useful results can include multiple messages. For identifiers, an exact matching message should rank first. Measure time to the correct open and reformulation rate when human interaction data are available. Keep date available when the person actually supplies time information. [Secondary clue and proximity experiments](mail-search-refinements.md)

## Finding a remembered email

The local ranking prototype found the intended email in the first five for **88 of 125 human-written searches**, up from 63 with strict BM25 fusion and 30 with chronological results. All three searches used the same retained content. The new policy recovered 30 of 49 targets missing a literal query term and three of four whose terms were split between headers and body. It gained 35 top-five hits and displaced ten relative to strict fusion. Of the 37 targets still outside the first five, 27 reached ranks 6–50. Those 27 are a concrete reranking workload. Ten require better candidate retrieval. [Public ranks and timings](scale-results/mail-fielded-test.json), [original eligibility by target](scale-results/mail-trec-w3c.json)

| Task | Current chronological order | Previous strict ranker | New ranker |
| --- | ---: | ---: | ---: |
| Human-written email searches, target first | 10/125 | 38/125 | **57/125** |
| Human-written email searches, target in first five | 30/125 | 63/125 | **88/125** |
| Human-written email searches, target in first 50 | 57/125 | 70/125 | **115/125** |
| Graded discussion search, nDCG at five | 0.180 | 0.459 | **0.492** |
| Original Beta sample, target conversation in first five | 26/120 | 41/120 | **52/120** |
| Fresh Beta sample, target conversation in first five | 31/120 | 42/120 | **48/120** |

The index scores subject, sender, recipients, snippet and available body together. Matching any word admits a candidate. Matching at least three quarters of the query words earns extra weight. English stemming applies to subject, snippet and body. For one- and two-word queries, subject weight doubles and matching both words in one subject, snippet or sender earns another boost. Among the best 200 message candidates, a bounded date preference breaks close contests on short queries. One conversation contributes at most one result. The prototype uses term frequencies and numeric thread/date fields. It stores no raw message text in the extra index and makes no model or network calls at lookup. [Ranker](../../tools/search-eval/mail_field_index.py), [Tantivy](https://github.com/quickwit-oss/tantivy), [prior fielded email retrieval research](https://www.microsoft.com/en-us/research/publication/microsoft-cambridge-at-trec-14-enterprise-track/)

On 25 development queries, SQLite disjunction with weighted fields found 17 targets in the first five, up from nine. Restricting the disjunction to its two rarest terms reduced the count to 13. The local search library also reached 17. On the official test, plain disjunction in the new library reached 81 and rewarding word coverage brought it to 88. The short-query policy came from the original Beta sample and the 25 public development queries. The official test had been examined in prior experiments. The fresh Beta sample had zero target conversations in common with the original. It gained 13 and lost seven versus the strict ranker. That six-task advantage is uncertain (paired two-sided exact test, p = 0.26). Recent/middle/older successes were 19/15/14 of 40, versus 18/12/12 for strict ranking and 20/6/5 for chronological order. Reserving a top spot for the newest all-word match also hurt public discussion quality. [Development ablations](scale-results/mail-fielded-development.json), [discussion judgments](scale-results/mail-fielded-discussion.json), [original Beta sample](scale-results/mail-fielded-personal.json), [fresh Beta sample](scale-results/mail-fielded-personal-confirmation.json)

A Beta task picks a particular conversation before constructing its cue. A surname or other sender token matched a median of **1,029 conversations** under today's literal query on the fresh sample. The new ranker found five of 24 intended conversations in the first five. Supplying one randomly chosen unused word from the target subject raised that to **14 of 24**. Across the 118 fresh tasks with an available extra word, the same-target comparison was **47 to 78**. The word came from the known answer. This measures the value of an informative refinement and cannot establish that a person remembers it. [Fresh sample and paired refinements](scale-results/mail-fielded-personal-confirmation.json)

The disposable Beta index covered 199,207 eligible messages from a 256,210-message snapshot and included text for all 92,381 eligible indexed bodies. The replay reads prepared plain text for those bodies and caps it at 16,000 Python Unicode code points. The Swift indexer counts 16,000 extended grapheme clusters, so a body with combining characters at the limit can differ. Existing search excludes conversations without a positive last date. Building the additional 39.0 MiB index took 19.6 seconds on the host, including loading the existing prepared text and committing the index. The public index took 13.4 seconds and 52.5 MiB. Each build used one writer thread and a 64 MB writer setting. On the fresh Beta sample, opening a reader in a new process and executing the first query took 1.5 ms at median across 12 processes, with a median increase in process peak RSS of 6.4 MiB. OS file caches were warm. Installed migrations, ongoing writes and rebuilds under memory pressure still need measurements. [Beta resource measurements](scale-results/mail-fielded-personal-confirmation.json), [public resource measurements](scale-results/mail-fielded-test.json)

Fetching the actual summary columns for up to 50 ranked conversations took **5.75 ms median / 13.66 ms p95** on the public queries, versus 14.07/230.49 ms for the chronological page. On fresh Beta tasks the same comparison was **1.07/3.08 ms** versus 3.16/29.66 ms. Each query ran three times in randomized paired order. The slowest ranked page took 42.84 ms publicly and 20.81 ms on fresh Beta. These host measurements include ranking, deduplication and summary-row lookup. The app's debounce, native model decoding, Gmail and rendering add further latency. [Paired public pages](scale-results/mail-fielded-test.json), [paired Beta pages](scale-results/mail-fielded-personal-confirmation.json)

The experiment evaluates completed, unscoped English-language queries. The normal app still uses its current parser, account and date scopes, word prefixes, date-based pagination and Gmail merge. A native trial should first rank the shell’s five Mail results, preserving hard scopes, live updates and the destination conversation. Measure partial typing, multilingual text, account changes, deletion, background index maintenance and keypress-to-visible time before rollout. The Python binding is an evaluation dependency. Swift integration and device performance remain open.

## Benchmarking searches written by people

Mail uses two public tasks from TREC Enterprise. In the first, people wrote a query for a particular email and supplied its target message. The runner uses only the query text for retrieval. The target stays in the scorer. It preserves the official 25 development and 125 test queries and gives every query one vote. Report success at ranks 1, 5, 10 and 50, plus mean reciprocal rank through 10. The second task asks for discussions about a topic. It uses 59 topics with graded judgments and reports nDCG and precision at five. DS4 has no judgments. Unjudged results score zero and the report records how many retrieved messages the assessors judged. [NIST topics and judgments](https://trec.nist.gov/data/t14_enterprise.html), [track methodology](https://trec.nist.gov/pubs/trec14/papers/ENTERPRISE.OVERVIEW.pdf)

The public fixture contains 174,299 parsed W3C mailing-list messages. Each message represents one result so its ID matches the judgments. The runner indexes subject, reconstructed snippet, sender, supplied recipients and up to 16,000 plain-text body characters. Timestamps and punctuation come from the archive. Twelve messages lack a usable date. All 125 test targets are present. Mailing lists differ from a personal mailbox in vocabulary, threading and body coverage. [University of Maryland corpus](https://tides.umiacs.umd.edu/webtrec/trecent/parsed_w3c_corpus.html)

The companion Beta run draws actual conversations first, then takes cues from the latest fetched message. There are eight targets in each combination of three age bands and five cue types (sender, subject, sender plus subject word, snippet words, and a query refined with a second word). It scores the 120 final queries separately from the 24 first attempts at refinement. The reference date and random seed are fixed. This covers age and reformulation while Banana usage frequencies are unknown. These queries are generated proxies. The generator samples words of at least three characters, so punctuation-derived single-character searches need the public tasks. Only anonymous case IDs, counts, ranks and timings leave the temporary copy. [Personal-email re-finding study](https://www.microsoft.com/en-us/research/wp-content/uploads/2019/02/Mackenzie-www19.pdf)

For speed, the runners execute the unscoped header and body lookup, conversation merge and row projection. Each pair uses the same snapshot, query and limit of 50. Query order is shuffled each round and the execution order alternates. Every pair must agree on the entire ordered page and whether another page may exist. The public benchmark runs six pairs per query, the Beta benchmark five. These SQL comparisons feed literal free text. The native replay separately invokes the same filter parser as the shell, then runs the real local Mail engine at both surface limits. A query's latency is its median across repetitions. Report the median and p95 across queries, the raw maximum and a query-level bootstrap interval for the median paired difference. The OS file cache is warm. Results exclude app decoding, typing, render and Gmail.

### Beta findings

On 256,208 retained messages, 189,714 conversations and 93,181 body documents, stopping the body cursor when it finds the first distinct conversation beyond the page reduced median query time from **4.64 to 3.33 ms**. P95 across query medians moved from **20.30 to 19.97 ms**. The median per-query saving was **0.93 ms** (95% bootstrap interval 0.53–1.07 ms). Every ordered page and continuation flag matched. The target appeared in the first five in 26 of 120 cases and in the first 50 in 61. The cursor uses the existing index and retains the 400-message ceiling for searches dominated by duplicate hits. [Paired Beta replay](scale-results/mail-beta-tasks.json)

Two earlier trials tried a new conversation-order index. It cost 3.25 MiB and looked attractive on the common-prefix stress control. In the broader Beta sample the first version **added 1.65 ms** per query (median paired, 95% interval 0.78–2.27 ms slower). Reusing short posting lists reduced the estimated regression to 0.10 ms with an interval spanning zero. The working implementation omits that migration. [Initial experiment](scale-results/mail-header-search-paired.json), [both rejected Beta runs](scale-results/mail-rejected-beta-tasks.json)

### Native Mail lookup through the shell and list query paths

The native replay used the shipped Swift filter parser, encoded each query exactly as the search field does, then called the real local search engine, including model decoding. For the 125 human-written test queries, the shell's five-slot lookup found 30 targets with median/p95 of **11.43/214.11 ms**. The Mail list at limit 50 found 56 targets, with median/p95 of **12.58/215.69 ms**. Both put 30 in the first five. Three test queries produced a person condition and one an importance condition. Three target ranks differed between the parsed list search and a literal SQL replay. One of the 25 development queries was rejected by the parser. These are local host lookup times through the native components. The shell waits 120 ms after the last edit before dispatching work. A newly typed lookup that needs a fresh result therefore cannot display it within 100 ms of that edit under the current policy, even with instantaneous retrieval. Key-to-character paint and local SQL timing are different clocks. [900 native samples and ranks](scale-results/mail-trec-native.json)

### Mail relevance and latency on the public tasks

| Measure | Current chronological results | Offline BM25 ranking |
| --- | ---: | ---: |
| Test target first | 10/125 | 38/125 |
| Test target in first five | 30/125 | 63/125 |
| Test target in first 50 | 57/125 | 70/125 |
| Test reciprocal rank through ten | 0.152 | 0.392 |
| Discussion nDCG at five | 0.180 | 0.459 |
| Discussion precision at five | 0.231 | 0.529 |

The offline candidate requests up to 50 BM25-ranked messages from each existing FTS index, deduplicates conversations within each list and combines the lists using reciprocal rank fusion with the published constant of 60. It uses no learned weights, embeddings, model calls or additional stored data. It gained 33 test targets in the first five and lost zero. On the 25 development tasks, top-five success went from six to nine. The assessors had judged 202 of 272 retrieved discussion results for chronological ordering and 268 of 272 for the ranking candidate. These are scores for this corpus projection. [All public queries and scores](scale-results/mail-trec-w3c.json), [SQLite FTS5 BM25](https://sqlite.org/fts5.html#the_bm25_function), [reciprocal rank fusion](https://cormack.uwaterloo.ca/cormack/cormacksigir09-rrf.pdf)

On the 125 public test queries the unchanged-order cursor optimization reduced median lookup time from 14.70 to 13.90 ms, with p95 moving from 238.81 to 239.66 ms. Those large tails still exceed the local UI ceiling before display. The median paired saving per query was 0.076 ms (95% interval 0.038–0.133 ms). For the offline ranker, a separate single ID-lookup pass took 21.74 ms at median and 238.20 ms at p95. The ranker timing covers one pass after the paired trials and returns IDs only. The chronological timing includes fetching summary columns.

On Beta the ranker raised top-five success from 26 to 41 of 120. It recovered 21 targets and displaced six. All six losses were recent messages. Top-five success was 17→15 for targets from the last 30 days, 8→14 for 31–180 days and 1→12 for older targets (40 tasks in each band). Median/p95 for ranker IDs were 6.66/68.74 ms. A repeat of the chronological baseline and early-stop candidate gave 4.63/3.34 ms medians and 21.10/20.57 ms p95. The working app keeps chronological keyset paging and the Gmail merge. To adopt ranking, validate stable paging, person/date scopes, recent known items and delayed Gmail results. Reserve fresh queries for future acceptance after iterating on these published results. [Beta ranks and timings](scale-results/mail-beta-ranked.json)

### What still loses targets or time

On the 125 test queries, 72 targets matched the whole literal prefix expression in headers or in the indexed body. Chronological ordering put 30 of those in the top five. The other 53 targets could never be promoted by reordering that result set. For four of them every query term was present somewhere, split across the two indexes. For 49, at least one requested prefix was absent from both searchable representations. This distinguishes a ranking problem from missing evidence for the current exact conjunction. [Per-target eligibility](scale-results/mail-trec-w3c.json)

The slowest development queries included single-character tokens inside ordinary text, including possessives, hyphenated terms and versions. A controlled rebuild added one-character postings to the two existing FTS5 indexes and kept the same matching, ordering and body cursor. Test p95 fell from **224.85 to 35.29 ms**. The 15 queries with a single-character token improved from 208.24 to 20.77 ms at median. For the other 110, median latency was 11.12 versus 11.16 ms. Median paired across all 125 was 0.10 ms slower, so the benefit is concentrated in the tail. All 750 test pairs agreed on results and continuation. This was an offline index experiment. The two indexes consumed an additional **102.59 MiB** on the projected public corpus. Initial fixture construction, including parsing, took 61.26 and 63.85 seconds in one run each. An installed database migration, incremental writes, and rebuilding a contentless index need separate measurements. [Prefix-index samples and byte counts](scale-results/mail-trec-prefixes.json), [SQLite prefix indexes](https://sqlite.org/fts5.html#prefix_indexes)

A three-way paired trial then compared chronological retrieval on the current schema, BM25 fusion on that schema, and the same ranking on the larger prefix indexes. Each policy fetched result summary columns, on the same data, in rotating order for each query. All 125 test queries ran three times. Current chronological retrieval found 30 targets in the first five at **12.48 ms median / 218.23 ms p95**. Ranked retrieval with the larger indexes found **63 at 17.77 ms / 63.62 ms**. With ranked retrieval held fixed, adding the indexes reduced p95 from 224.00 to 63.62 ms and preserved every ordered ranked page. The combined policy's slowest recorded query was 122.52 ms. It adds about five milliseconds to a typical query and 102.59 MiB to this corpus. This is evidence for a candidate that improves quality and tail latency together. Native pagination, live Gmail integration and the costs on personal mail remain open acceptance checks. [Three-way comparison](scale-results/mail-trec-ranked-prefixes.json)

### Reproducing the comparisons

Use Python 3.11 or later with SQLite FTS5 and a checkout containing the reference revision `f987bd34`. Download the three parsed archive parts linked by UMD and the five topic/judgment files linked by NIST. From the repository root, run the following commands. Supply paths to the existing local databases for the private replay. The public runner builds disposable indexes and records SHA-256 digests of its input files.

```sh
mkdir -p /tmp/banana-trec
for part in 1 2 3; do
  curl -fsSL "https://tides.umiacs.umd.edu/webtrec/trecent/w3c-emails-part${part}.tar.gz" -o "/tmp/banana-trec/part${part}.tar.gz"
done
trec=https://trec.nist.gov/data/enterprise/05
for suffix in topics training-qrels qrels; do
  curl -fsSL "$trec/ent05.known-item.$suffix" -o "/tmp/banana-trec/$suffix"
done
curl -fsSL "$trec/ent05.discussion-search.topics" -o /tmp/banana-trec/discussion.topics
curl -fsSL "$trec/ent05.discussion.official-qrels" -o /tmp/banana-trec/discussion.qrels
python3 tools/search-eval/trec-mail.py --collection /tmp/banana-trec --out /tmp/trec-mail-results.json
python3 tools/search-eval/trec-prefixes.py --collection /tmp/banana-trec --ranked --out /tmp/trec-prefix-results.json
python3 tools/search-eval/beta-mail-tasks.py --index "<index.sqlite>" --body "<search.sqlite>" --as-of 2026-11-25 --out /tmp/beta-mail-results.json
```

The optional native replay uses the pinned GRDB through the existing Mail test runner. It prepares a disposable corpus, loads the production parser rules, calls the native header/body merge, decodes conversation rows, and records ranks at shell limit five and Mail limit 50 over three trials. Measure live Gmail and visible interaction on their own. Run in the repository's build lock on macOS.

```sh
python3 tools/search-eval/trec_corpus.py --collection /tmp/banana-trec --out /tmp/banana-trec-native
tools/agents/xcode-lock.sh python3 tools/mail-index-tests/run.py --filter TRECMailTests --trec-fixture /tmp/banana-trec-native --out /tmp/trec-native-results
```

The fielded-ranking replay uses a separate evaluation-only environment. Use the public collection and native fixture created above. The optional private run takes read-only SQLite backups in a disposable directory, then reads already-prepared body text for eligible messages. The saved result JSON contains numeric scores and anonymous case labels. Remove the disposable private directory after the replay.

```sh
uv venv --python 3.11 /tmp/banana-fielded-env
uv pip install --python /tmp/banana-fielded-env/bin/python tantivy==0.27.0
runner=/tmp/banana-fielded-env/bin/python
"$runner" tools/search-eval/fielded-mail.py --prepare --fixture /tmp/banana-trec-native --collection /tmp/banana-trec
for split in development test discussion; do
  "$runner" tools/search-eval/fielded-mail.py --fixture /tmp/banana-trec-native --collection /tmp/banana-trec --split "$split" --out "/tmp/fielded-$split.json"
done
fixture=$(mktemp -d)
"$runner" tools/search-eval/fielded-mail.py --prepare --fixture "$fixture" --beta-cache "<Beta Cache directory>"
for seed in 73123 73124; do
  "$runner" tools/search-eval/fielded-mail.py --fixture "$fixture" --split personal --as-of 2026-11-25 --seed "$seed" --out "/tmp/fielded-personal-$seed.json"
done
```

Run the first-query replay against the existing fixtures and a copy of the retained attachment metadata.

```sh
first=tools/search-eval/mail-first-query.py
"$runner" "$first" --fixture "$fixture" --prepare-files "<Beta Cache directory>/blobs.sqlite" --out /tmp/first-query-files.json
for seed in 73128 73129; do
  "$runner" "$first" --fixture "$fixture" --seed "$seed" --out "/tmp/first-query-$seed.json"
done
"$runner" "$first" --fixture /tmp/banana-trec-native --public --out /tmp/first-query-public.json
```

## Search surfaces at the baseline

| Surface | Corpus, ordering and limits | Failure to put in the benchmark |
| --- | --- | --- |
| Phone field and iPad/Mac field | Plan, Mail and Notes in fixed groups of five. Starts after two characters and a 120 ms settle. Plan folds case and accents, matches every query word against a title-word prefix, scans loaded occurrences on the main actor and sorts today/future ascending, then past descending. Notes and Mail use their own backends. | Sixth relevant item, several upcoming occurrences hiding an exact past title, location-only hit, old rows during rapid edits. Measure rank within the group and scrolling across groups. [Shell search](../../Banana/Views/Shell/ShellSearch.swift), [rules](../../Banana/Model/ShellRules.swift) |
| Return and Ask | Phone can hand a valid query to Assistant when groups are empty. Wide shell uses explicit question/request rules. Assistant's Plan-specific action reuses the title search with six slots. General workspace search walks notes, meals, workouts, routines, shows, occurrences and pages with six per section and thirty total. Module availability depends on build and runtime choices. | Return immediately versus after results arrive. An episode-title-only note can pass Notes retrieval and then fail Assistant's second check against transcript-derived title/detail. Earlier sections can exhaust the global cap. [Phone](../../Banana/Views/Shell/PhoneShell.swift), [wide](../../Banana/Views/Shell/WideShell.swift), [Assistant](../../Banana/Pi/AssistantWorkspace.swift) |
| Plan and Calendar | The day-list picker searches one day. “Search all calendars” leaves the local timeline and queries eligible Google calendars over a date window, initially roughly ±1 year. One calendar/page at a time, 50 provider rows, event field/attendee filters, automatic traversal of empty pages. | Put the only match on a later calendar, outside the local horizon, or across midnight. Count page requests to first useful row. Check hidden calendars, duplicate busy copies, offline failure and reopening an edited event. [Calendar sheet](../../Banana/Views/CalendarSearchView.swift), [provider](../../Banana/Model/GoogleCalendarService.swift) |
| Mail list and shell Mail | Local header FTS uses word-prefix conjunction; prepared bodies have a separate index. Gmail can add hits. Merge deduplicates conversations and respects date/frontier ordering. Shell observes five local/list rows through its session. Mail is omitted in App Store configuration. | One body-only, one header-only and one Gmail-only thread, the same thread in both, delayed body indexing, disconnected account, stale remote completion. Measure first local and merged results independently. [Mail search tests](../../BananaTests/MailGmailSearchTests.swift), [build configuration](../../Config/Base.xcconfig) |
| Notes and Workouts | Notes searches transcript, episode, show and excerpt, with localized substring matching and active/archive scope. Its page counts matches and orders by creation date and ID. Shell's bounded read skips the count. Workouts supports structured activity, time and duration conditions in compact and wide views. | Rare old note, common excerpt, Unicode, archived-only, exact duration boundary, DST and edited record. Benchmark the Notes page and shell call separately. [Repository](../../Banana/Model/NoteRepository.swift), [predicate](../../Banana/Model/LiveFilter.swift) |
| Nutrition | Food picker combines personal history, bundled generic and branded data, learned picks and Open Food Facts. It waits 120 ms before local work and another 300 ms before online work. Recent Meals searches meal names/foods. Supplement discovery queries the NIH catalog. | Distinguish “log a carrot”, “find my usual serving”, “find this branded pack” and “repeat this meal”. Judge identity and serving separately. Include cold brand setup and deduplication after the online response. [Food picker](../../Banana/Views/FoodSearchView.swift), [food tests](../../BananaTests/FoodSearchTests.swift), [recent meals](../../Banana/Views/RecentMealsView.swift) |
| Library and smaller native pickers | Podcast discovery searches Apple's directory or accepts a feed URL. Assistant searches subscribed show titles. Settings searches a curated index filtered by available pages. Other scoped lookups include places/addresses, booking time zones and the Shortcuts/Siri open-task entity query. | Resolve the correct feed, settings destination, place, zone or incomplete task. Repeat with ambiguous names and no network. [Podcasts](../../Banana/Views/PodcastsView.swift), [Settings](../../Banana/Views/SettingsView.swift), [task entity](../../Banana/Model/BananaIntents.swift) |
| Web owner and shared views | Search filters the current view after 200 ms. Plan combines authored items and calendar data. Workouts searches activity. Notes searches four fields and can fetch successive 100-record chunks to fill a 30-row filtered page. Nutrition, Taken and Library use record fields; the generic path searches serialized fields. Booking has a separate city/country/abbreviation picker. | Rare match on the last page, internal JSON key matching a display search, stale responses after switching views, busy-only calendar shares, revoked health consent, keyboard composition. Record pages and bytes read alongside first paint. [Web app](../../Service/public/app/assets/app.js), [sharing policy](../../Service/src/web/sharing-policy.js), [booking](../../Service/src/booking/pages/client.js) |

Use the same synthetic workspace on phone, iPad, Mac and web where the surface supports it. Keep a capability column for compiled, enabled and connected. The watch and widgets have no general search entry point identified in this pass. An unavailable module is a coverage observation. Returning an object outside the allowed account or share is a correctness failure.

## Calendar event field coverage

The Notes field inside a Google event maps to its description (`GoogleCalendarService.calendarEvent`). Use events with neutral titles and put a unique lookup term in exactly one field per event.

| Field or query | Native shell, day-list picker and Assistant Plan lookup | Native “Search all calendars” | Web Plan filter |
| --- | --- | --- | --- |
| Event title | Searched within each surface’s timeline scope | Free text | Free text |
| Event Notes or location | Omitted from matching | Free text searches description and location | Free text searches description and location when exposed |
| Attendee display name or email | Omitted from matching | Person condition, e.g. “with Noor Haddad” | Person condition on supplied attendee details |
| Organizer only, or conference URL only | Omitted from matching | Neither has a dedicated field matcher | Neither has a dedicated field matcher |

A bare participant name and an explicit “with” query need separate judgments. Google can return candidates that Banana subsequently filters out. Test an organizer absent from the attendees array and a URL absent from the description/location so incidental duplicates cannot hide a gap. Repeat on an owner account, a details share and a busy-only share. For each field record whether the source supplied it, whether the intended event survived retrieval, its displayed rank and whether it opened correctly. The initial web pilot feeds prepared predicates directly and cannot establish end-to-end field coverage.

## Frozen baseline for expanding calendar coverage

Start at the current selector, expand the fields, then optimize the expanded selector. Preserve all three results. At stage A the expected result for a *new* field is a product judgment, so a miss records a gap rather than a regression. Keep the observed title, ordering and empty-query-result controls unchanged through stages B and C.

A read-only aggregate of the local Mac Beta Google event cache found 3,823 cached event rows in 12 calendar snapshots. Of those rows, 3,094 had titles, 173 descriptions, 222 locations and 771 attendee lists. These are counts of cached rows, including possible copies across calendars. The loaded Plan timeline can have a different size and also includes authored and derived occurrences. The synthetic workload uses those field-presence counts, repeated titles, an approximately median-length populated description and an explicit first-five ordering control. Timestamps, text and participants are invented. This pilot does not reproduce Beta's query frequency, calendar joins, string distributions, recurrence patterns or memory layout.

Run `python3 tools/search-eval/shell-plan.py --out /tmp/shell-plan-run-1.json` with a fresh output path. It compiles the checkout's production Swift title matcher and selector against a synthetic in-memory store. It rotates eight queries through 21 trials at each size and retains the ordered IDs and all timings. The first trial runs in the same process as the rest; this is a resident-data scan baseline. [Stage A results](scale-results/shell-plan-f987bd34.json)

| Synthetic occurrence count | Correct title, common-prefix ordering and true miss | Desired metadata-only queries found | Selector p50 / p95 / max across 168 calls |
| ---: | ---: | ---: | ---: |
| 3,823 | 3/3 | 0/5 | 6.43 / 8.27 / 11.39 ms |
| 15,292 | 3/3 | 0/5 | 26.22 / 33.75 / 35.20 ms |

Stage B should carry permitted event description, location, attendee name/email and organizer into retrieval, with an adapter-level check that the fields survive local calendar ingestion, deduplication and edits. Replay the same workloads before introducing a speed optimization. Retain title-only positives and add collisions across fields, inaccessible events and stale-field negatives before selecting ranking weights. Measure the extra cost of populating search fields and of matching them separately.

For stage C, compare each speed candidate against B and require the same ordered IDs, including metadata matches. Test cache invalidation and eviction after edits, memory and rebuild cost, and cancellation while typing. Repeat on full app entry points and physical hardware to measure time from input to the first correct row and to opening it. A selector microbenchmark cannot establish either. Expand to other object types with their own measured corpus sizes.

## Calendar field search implementation

The main field now searches title, location, event notes, attendee names and addresses, and organizer names and addresses from the visible timeline. Title matches precede metadata matches. The two groups retain today/future first and then most recent past. The shell dispatches its scan off the main actor and discards canceled results. Assistant’s calendar-specific query uses the same selector. The day-list picker retains its substring behavior and includes the visible meeting fields. Busy-only entries expose no additional matchable detail.

The eight frozen cases passed at each size after expanding coverage. The selector also passed mixed title/notes, title priority, Unicode and busy-only controls. Median/p95 at 3,823 occurrences were 6.43/8.27 ms before expansion, 11.51/12.41 ms with the first field-aware implementation and 1.17/1.86 ms after avoiding repeated Foundation tokenization for ASCII fields. At 15,292 occurrences the corresponding values were 26.22/33.75, 45.45/48.46 and 4.83/7.70 ms. Each size has 168 calls per run. The final maxima were 6.39 and 7.91 ms. For a same-coverage Foundation control pass `--reference-matcher` to the runner. Host contention produced a 1,316 ms maximum in that separate control; all samples are retained. Results cover a synthetic resident selector with repeated titles, outside SwiftUI. They do not measure first paint, metadata ingestion, snapshot storage, provider latency or device interaction. [Selector samples](scale-results/calendar-search-fields-results.json)

Mail sender constraints now use the same header-index word prefixes on body-only hits as on header hits. The sender lookup runs once as a set of message IDs. On a local Beta SQL probe a correlated sender lookup timed out at three seconds on each of three trials for a common body and sender prefix. The set lookup returned 400 rows in 21–26 ms. This is a query-shape comparison for sender-constrained body search; the unscoped header timings below concern a different path.

The Debug Simulator build succeeded. A host replay of the Google event window fixture passed the visible notes/attendee and busy-only redaction checks. All 17 focused Mail checks passed. All eight persistent performance scenarios ran. Their absolute latency checks passed, but every scenario exceeded its checked-in RSS margin and Plan recorded one extra WeekView and weather redraw over the observation interval. These measurements do not establish a cause. The regression gate remains failed. Visible UI latency on physical devices is unmeasured. [Regression result](scale-results/calendar-mail-search-gate.json)

## Notes and calendar component improvements

On 90,000 synthetic Notes, the reference and candidate read the same committed SQLite database and agreed on page order and exact totals. The Notes list now infers the total from a short first or nonempty last page and skips localized comparisons on missing fields. A full page or an empty deep page still needs a count. Assistant now makes the bounded async read that its six displayed results require. The harness alternates nine pairs per case, reopening both database connections for the first and last pair. Rows include archived notes and a single old podcast-context match. [All 72 pairs](scale-results/notes-search-pages.json)

| Notes operation | Reference warm median | Candidate warm median |
| --- | ---: | ---: |
| Assistant first six matches | 48.78 ms | 0.28 ms |
| Assistant recent 10 plus continuation check | 4.35 ms | 0.20 ms |
| Full list page with exact count | 49.44 ms | 36.19 ms |
| Missing text | 88.27 ms | 31.31 ms |
| One old context-only hit | 211.98 ms | 79.22 ms |
| Last nonempty page | 95.14 ms | 35.22 ms |
| Empty page beyond the end | 92.50 ms | 68.87 ms |

On fresh connections the six-match case was 50.01→0.35 ms and the context-only lookup was 210.80→80.34 ms. The OS cache was warm throughout. To reproduce, run `sh tools/search-eval/notes-pages/run.sh <Mac-Release-derived-data> <new.json>` using a Mac build with its matching GRDB module. The repository tests also cover zero limits, deep offsets and archive scope. For review, add host-component ceilings of 2 ms for the warm six-result operation and 100 ms for the old context-only lookup on this fixture. Observed candidate maxima across all nine pairs were 0.40 and 81.77 ms respectively. Repeat on the reference host before making those thresholds blocking.

Calendar's interval index now shares already chronological rows, sorts offsets for disordered inputs, and constructs subtree end maxima once per nonempty subtree. Six alternating process pairs per input shape compared the production Swift index against the base revision. For 15,292 synthetic value-sized events, median first construction took **1.51→0.70 ms** in order and **15.21→3.46 ms** out of order. Median peak process RSS fell from 14.63 to 10.40 MiB and from 17.17 to 14.99 MiB respectively. Every interval query agreed with an independent scan, including ties and crossing events. An intermediate implementation slowed repeated sorted construction (1.32→2.22 ms); the final version measured 1.17→0.67 ms. Run `python3 tools/search-eval/calendar-range/run.py <new.json>`. These are index construction costs, separate from the text selector and visible calendar rendering. [Both implementations and samples](scale-results/calendar-range-search-builds.json)

### Stock simulator regression suite

The unchanged source and modified build ran the same eight stock iPhone Simulator scenarios. All component checksums matched, both runs passed the host monitor, and the candidate passed every absolute latency and redraw check. On the 90-day workload (180,000 email rows, 9,000 events, 90,000 notes and 900,000 episodes), Notes search p95 improved from **44.86 to 36.92 ms** and calendar week lookup p95 went from **8.75 to 3.14 ms**. Peak process RSS was 721.70 and 719.55 MiB. The earlier extra weather/WeekView redraw was absent in both final paired runs, so the size of any benefit from silencing diagnostic-only publication is unestablished. [Unchanged, interim and final runs](scale-results/broader-search-components.json)

The existing memory gate failed **8/8** on both binaries. It compares the current iOS 27.0/Xcode 27.2 process against measurements from iOS 26.5/Xcode 27.0. The absolute 900 MiB ceiling passed. The stricter one-day comparison permits 315.36 MiB. Two supplementary unchanged-binary runs with one note, zero episodes, 2,000 mail rows and 100 events still peaked at **350.97 and 351.36 MiB**, versus 364.14 and 364.06 MiB for the full one-day workload. Reducing note and podcast counts even this far cannot close that gap on this binary. This does not identify the cause or establish that other app or runtime changes cannot meet the target. The reference run also exceeded one relative podcast latency threshold. All failures and thresholds were retained.

For the supplemental check, run `tools/agents/xcode-lock.sh -l sim-phone python3 tools/search-eval/memory-floor.py --device <simulator-udid> --app <reference-Banana.app> --out <new-directory>` on the stock simulator. An initial zero-note attempt stopped at the fixture’s existing count precondition before reporting memory. A subsequent attempt found the simulator shut down. The retained script boots it headlessly and verifies each run's counts. These four RSS samples are a separate diagnostic, with other host work possible. Neither the component suite nor the native Mail replay measures input-to-visible latency on physical hardware.

## Mail volume and current header baseline

A read-only local Beta snapshot had 256,049 messages, 189,566 threads, four accounts and 256,049 header-index documents. Of the threads represented in messages, 20,561 contained multiple messages. Thread length p50/p95/p99/max was 1/3/8/100. The message index marked 92,274 messages body-indexed (36.0%). The searchable universe is therefore different for a subject-only query and a body-only query. This counts local retained data. The complete Gmail-side inventory was not measured.

Local body coverage follows content acquisition. The cloud service defaults to a 183-day background fill, skips known Spam/Trash and lets deployments override the window. All four local accounts had cloud feed state. Of 163,775 messages without the body-indexed flag, 104,320 were header-only and 59,455 were stubs. None was flagged by the local feed as available for bulk body download, and no prepared message was waiting for the search indexer. Of the dated messages inside the default window, 35,795/35,868 were marked indexed. Outside it, 56,479/160,737 were marked indexed. Another 59,444 had no local date. The local database cannot establish their age or the deployed server setting. [Service fill](../../Service/src/mailbox.js), [device pull](../../Banana/Model/Mail/MailCloudPull.swift)

Joining the message state to actual body documents gave 60,124 conversations with documents for every locally known message, 1,720 with partial coverage and 126,721 with none. Another 1,001 thread records had no local message rows. Indexing uses up to 16,000 characters per message. Keep the header benchmark denominator separate from searchable body documents and fully covered conversations.

An additional read-only size check counted 92,495 originals with full content. Their compressed HTML and plain parts occupied 384.88 and 111.38 MiB. The 92,496 prepared rows used 196.78 MiB for their display representation and 81.38 MiB for the plain searchable text. SQLite allocated 333.05 MiB to the body FTS and its message mapping. These numbers describe different representations of the same messages. They exclude attachments, remote images, SQLite unused space and WAL overhead. The body index tokenizes the prepared plain text, up to 16,000 characters per message. Extending coverage would also require acquiring, preparing and indexing the missing mail; the distribution of its sizes is unknown. This pass uses the existing coverage.

For meaning-aware retrieval, first evaluate field-aware query parsing and weighted lexical retrieval with the same labeled corpus. Test bounded query expansion for common paraphrases before adding any document embeddings. Judge strict person/date filters and literal identifiers separately. If relevant items are retrieved but rank poorly, compare reranking a bounded candidate set. If paraphrase targets never enter that set, test a separate semantic retrieval path. Record top-five gains, newly introduced wrong hits, storage, update CPU and first-result latency for each stage.

The existing 180,000-message performance fixture has two accounts, one message per thread, and repeated header text. Keep it as a controlled regression workload. Add a synthetic Beta-shaped fixture at 256k messages and 190k threads, then a 4× fixture at about 1.02M messages and 758k threads. Preserve the skew in thread lengths, body coverage, per-term frequency and account scoping. Test 5-row shell and 50-row Mail responses, next page, multiple matching messages in one conversation, offline results, incremental body indexing and delayed or duplicate Gmail results.

The following three inputs are historical stress controls. A direct read-only replay of the checkout's unscoped header SQL against the installed Beta index fetched up to 50 conversation rows. Twelve rotating trials for each generic term gave the following times. No message or account content was retained. These host SQLite measurements include fetching result rows in Python; app model decoding, body results, Gmail and UI presentation remain unmeasured.

| Prefix | Rows returned | Median | Maximum |
| --- | ---: | ---: | ---: |
| the | 50 | 113.54 ms | 660.59 ms |
| project | 50 | 8.40 ms | 10.68 ms |
| zzqnomatchprobe | 0 | 0.20 ms | 0.75 ms |

Record first-use and warm trials separately on the next controlled run. A common prefix costs more even when the returned row count is identical. Profile candidate message count, distinct threads and ordering before selecting an optimization. [Individual samples](scale-results/mail-beta-header-f987bd34.json)

## First measurements

Run from the repository root:

```sh
node tools/search-eval/web.mjs
LIVE_FILTER_BENCHMARK_REPORT=/tmp/banana-web-predicate.json node --test Service/test/live-filter.test.js
```

The [pilot](../../tools/search-eval/web-fixture.json) supplies independently specified expected IDs. The runner calls the production web parser and prepared predicate and prints each missing and unexpected ID. On this revision, eight of nine result sets matched. Plan passed 3/3, Workouts 2/2, Notes 3/4. For unaccented “cafe”, both “Café receipt” and “Café menu” were missing. Accent tolerance is a proposed product expectation. These nine development queries measure predicate behavior on prepared rows; they cover neither page assembly nor ranking quality in the population.

The existing web tests passed 4/4. On this arm64 Mac, Node 24.18.0, seven alternating 10,000-row trials gave a median of 1.47 ms and maximum of 3.80 ms with preparation once per query. Recomputing per row gave 12.13 ms and 18.80 ms. The production web app already prepares its predicate. This establishes a component control; a browser profile should look next at row construction, fetching and rendering. A concurrent build makes these exploratory host timings unsuitable as regression thresholds.

On the native host, 21 shared parser fixtures and the Calendar URL checks passed. Across 1,000 warmed parses of a single phrase, p95 was 0.71 ms and max was 3.73 ms. The Notes bridge passed 384 checks after adding its required module flag to the standalone compile command. The first compile failed without that flag. [Results and timing samples](scale-results/search-eval-f987bd34.json)

The [Mail retained-history test](../../BananaTests/MailLocalSearchTests.swift) already checks exact thread order against a reference on 180,000 messages for one common and one rare term. The [Notes investigation](scale-results/notes-first-use-20261010/README.md) recorded a 65.746 ms first query followed by roughly 17.5–18 ms queries. In a separate 35.444 ms instrumented query, 32.464 ms was counting. Use that as a lead for page-level profiling. Shell already omits that count. [Calendar routing checks](../../tools/calendar-search-tests/main.swift) exercise URL construction. The [Notes bridge checks](../../tools/notes-search-tests/README.md) cover localized comparison semantics. Each remains valuable alongside independent relevance judgments.

## A baseline we can hill climb

1. **Freeze tasks before changing retrieval.** Start with 20 labeled tasks each for shell Plan, Mail, Notes and food. Include known-item lookup, broad discovery, filters, ambiguous names, misses, late matches, punctuation, reordered words, accent/typo pairs and hard negatives. Use stable object and destination IDs, acceptable alternatives and explicitly forbidden IDs. Freeze seed, clock, locale, time zone, account/module state, database revision, history size, index readiness and provider responses. Independently review ambiguous judgments. Keep a held-out set split by intent family and object, so near-duplicate queries cannot leak between tuning and evaluation.
2. **Run the production entry path.** Capture the candidate IDs before truncation, displayed group/rank and selected destination. For one intended item report top-one success, success in the visible five, reciprocal rank and correct-open rate. For discovery report graded nDCG@5. For deterministic filters compare full eligible ID sets, false positives and omissions through the last page. Report correct empty, incorrect empty, stale results and false “nothing found” separately. Distinguish absent corpus, failed retrieval, bad order, wrong routing and wrong destination. Show counts per object, surface and query family before aggregating.
3. **Time the entire interaction.** Timestamp key delivery, typed character paint, dispatch, first local candidates, first visible correct row, stabilized remote merge, and opened destination. Keep settle time in input-to-result. Record p50/p95/p99/max, denominators, errors, memory peak, bytes/pages read and canceled work. Use controlled replay for remote relevance and delay/error profiles; measure live provider variance separately. Test fresh process, warm prefix edits, backspace, cache eviction, sync mutations and large history. Enforce the existing 8.3 ms frame, direct input p95 under 10 ms/max 20 ms, and local UI max 100 ms contract. Verify visible interactions on physical iPhone, iPad and Mac; browser paint needs its own trace. [Performance contract](ui-performance-contract.md)
4. **Compare one change at a time.** Alternate baseline/candidate in paired blocks on identical data and device, retaining all raw samples and failures. Compare wins/losses per query and paired uncertainty intervals across queries or independent runs. Repeat on holdout only after choosing the candidate. Reject forbidden hits, broken opens, stale completions or budget regressions regardless of average gain. For a speed-only change require identical eligible IDs, order and continuation signals. For a relevance change inspect every displaced top-five hit. Measure startup, writes, index size and recovery before adopting a cache or index. Run touched correctness/UI tests and the persistent regression suite. Any tighter baseline needs explicit review. [Regression protocol](regression-testing.md)

## Experiment backlog at the baseline

| Experiment | What would warrant keeping it |
| --- | --- |
| Replay context-only Notes through the list, shell and Assistant. Try retaining the repository's accepted IDs through Assistant presentation and using its bounded async read. | Correct eligible note opens in each supported surface, subject to each surface’s result limit. No archive leak, duplicated results or main-thread search regression. |
| Replay Return on phone and wide layouts before and after groups arrive. Exercise local miss, delayed Mail, stale previous results and explicit ask. | An identical lookup reaches the intended destination across timing conditions. Empty or pending results never independently change a lookup into an Assistant request. |
| Profile Plan scans on common, rare and missing prefixes. First ablate repeat query normalization, then bounded top-five selection, preserving chronology and tie order. Test exact-title boosting as a separate relevance experiment. | Speed candidate improves first-correct-row latency at scale with identical IDs. Boosting wins on held-out known items without burying the next occurrence on broad queries. |
| Compare accent-tolerant matching with current web behavior on human-judged multilingual positives and near-name negatives. Then profile web Notes rare misses and native Notes count/fetch independently. | Recover desired matches with acceptable precision in each locale and bounded memory. A retrieval optimization must also improve first-use or deep-page cost without shifting it into startup or writes. |
| Replay local/body/Gmail-only mail and personal/generic/branded food. Examine candidate recall before tuning rank or changing debounce. | Improve the stage that actually loses the object. Preserve offline first results, identity deduplication, ordering contracts and user-selected portions. |

Prioritize subsequent experiments by failed user tasks and measured waiting time. The public Mail replay and the paired component runs above provide the first comparisons. Device input-to-visible latency still needs its own baseline.
