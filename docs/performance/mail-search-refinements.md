# What helps someone find a remembered email?

These experiments measure how much a second clue helps after a first search. The date and sender rows supply information from the intended message, so they measure the value of a clue once supplied. The default product benchmark starts with the words someone types unaided. [First-query results and priorities](search-evaluation.md#the-first-query-in-mail)

## Dates and people

Each column below uses the same 120 targets as its own baseline. Success means the intended conversation appears in the first five. Samples A, B and C use seeds 73124, 73125 and 73126. C was the additional test of the contextual sender picker. The three samples share two target conversations across pairs.

| Action | A | B | C |
| --- | ---: | ---: | ---: |
| Search with the initial cue | 48 | 46 | 43 |
| Choose the correct calendar quarter | 74 | 71 | 67 |
| Choose the correct calendar month | 84 | 79 | 78 |
| Supply the exact sender when available | 76 | 63 | 61 |
| Supply a recipient when available | 59 | 53 | 61 |
| Append a random unused subject word when available | 77 | 68 | 63 |
| Choose a helpful applicable suggestion, or keep the original results | 59 | 53 | 51 |

Date uses the conversation’s last activity, in UTC for this replay. Person filters require the lexical match and the selected address on the same message. A participant can be its sender or any recorded recipient. The remembered-participant cue comes from the newest fetched message’s recipients and excludes the owner and sender. Across methods the scope applies to the whole searchable index before ranking. The runner independently checks the date or address constraint for every returned thread. For unavailable remembered clues, the table counts the original result. Subjects supply the extra topic word. Perfect knowledge of any of these clues is an optimistic assumption.

**Let people type a few letters of a sender they remember.** Using the existing composer lookup as a control, the runner supplied three characters from the first eligible sender-name word, falling back to the address local part. The search-specific version first shows matching senders from the top 50 results, ordered by how many of those conversations they sent most recently, then fills remaining slots from the composer lookup. Neither lookup sees the target address when generating choices. The scorer checks for it afterward.

| Sender experiment | A | B | C |
| --- | ---: | ---: | ---: |
| Tasks with an eligible sender prefix | 106 | 112 | 101 |
| Intended address in the composer’s first three choices | 21 | 20 | 16 |
| Intended address in the search-specific first three choices | **97** | **103** | **92** |
| Extra email targets recovered if the person selects that address, composer → search-specific | 4 → 22 | 1 → 12 | 2 → 14 |

A suggestion generated before the person supplies a clue has less information. The replay proposed at most one sender, other participant, month and subject word using only the first 50 results. It favored values that divided the results into roughly equal groups and skipped sparse or nearly universal options. Even a person who always recognized a helpful applicable option and otherwise did nothing would recover only 11, 7 and 8 extra targets. Automatically applying the suggested month would displace 35, 32 and 28 existing top-five targets. This tests one suggestion policy. Other ways to choose suggestions may do better.

People in a personal-email re-finding study often appended a term or rewrote their query. An earlier Gmail study generated filter suggestions from visible conversations and collected actual selection behavior. Both support evaluating the interaction itself. For Banana, expose date and sender as optional controls, preserve the typed query, and let one action remove the scope. In a counterbalanced user test, record first-correct-open time, successful opens, incorrect selections, and recovery from a wrong date or sender. Include senders the person has only received mail from. [Mackenzie et al., personal email re-finding](https://www.microsoft.com/en-us/research/publication/exploring-user-behavior-in-email-re-finding-taskshttps-www2019-thewebconf-org/) · [Gmail filter suggestion study](https://ijcai.org/proceedings/2009/237)

## Reranking the first 50

The first-stage list stays fixed. For each adjacent pair of distinct query words, the text scan rewards exact adjacency in order and gives half credit for either order within eight tokens. Matches cannot cross field boundaries. The primary rule averages that evidence across pairs and subtracts it once from the base log₂ rank. Tests at weights two and four measure sensitivity. On the 25 development searches, the primary header and full-text versions both retained 17 top-five targets. The full-text version had the better reciprocal rank of those two. The weight-four full-text version dropped to 16. The official test queries had already been used in earlier Banana experiments. The study borrows the ordered and unordered evidence used in prior retrieval work. Its scoring rule is a simpler rank adjustment. [Metzler and Croft, term dependencies](https://cs.uwaterloo.ca/~jimmylin/workspace/Ivory/docs/publications/Metzler_Croft_SIGIR2005.pdf) · [NIST topics and judgments](https://trec.nist.gov/data/t14_enterprise.html)

| Reranking rule | Public target first / top five, of 125 | Discussion nDCG@5 | Personal top five A / B / C | Extra lookup p95, sample C |
| --- | ---: | ---: | ---: | ---: |
| Previous fielded ranker | 57 / 88 | 0.492 | 48 / 46 / 43 | — |
| Subject and snippet, primary weight | 57 / 91 | 0.489 | 49 / 46 / 44 | 0.71 ms |
| Add prepared body, primary weight | 57 / 90 | 0.494 | 49 / 46 / 44 | 7.66 ms |
| Add prepared body, weight four | 54 / 95 | 0.509 | 50 / 48 / 44 | Same body scan |
| Positional index, primary weight | 57 / 90 | 0.495 | 48 / 46 / 44 | 2.44 ms |

Header reranking is cheap enough for a native trial and had a small cost in graded discussion quality. The strongest body weight gained seven public top-five targets and moved three targets out of first place net. The primary full-text rule gained two public top-five targets and displaced zero. A reranker restricted to 50 cannot recover a target missing from those 50.

A separate Tantivy rebuild stored token positions and indexed the numeric thread key so phrase queries could be constrained to the original 50 candidates. It searched all matching messages in those threads with stemming, whereas the raw Beta scan used the newest indexed prepared body per thread and literal tokens. Both use the same first-stage ranking. The positional option added **46.3 MiB** on Beta and **75.1 MiB** publicly. Public positional reranking took 31.9 ms p95 versus 10.6 ms for the direct body scan. The per-query postings collector never reached its 1,000-message cap in these replays. The modest personal-mail gains give little reason to pay that storage cost now. [Tantivy query syntax](https://docs.rs/tantivy/latest/tantivy/query/struct.QueryParser.html)

## Measurement and reproduction

The public fixture uses 174,299 archival emails. The Beta header snapshot held 256,214 messages and 189,720 threads. The three experimental indexes used exactly the same frozen SQLite inputs, 199,211 eligible messages and 92,374 available prepared bodies. Eleven eligible index entries lacked recoverable prepared text in the blob snapshot. Exact address fields added 1.43 MiB to the personal index. Unscoped page order differed between independently built base and address indexes for zero, two and one queries across A, B and C. All refinement comparisons use the address index for both arms. The host file cache was warm. Timing for proximity is incremental to the first-stage lookup, with three repetitions per query. Suggestion times are single-pass observations. Native UI, partial typing, account changes, and the Gmail merge still require testing. [Case-level measurements](scale-results/mail-proximity-and-refinements.json) · [Replay code](../../tools/search-eval/mail-search-study.py) · [Existing sender completion](../../Banana/Model/Mail/MailCorrespondents.swift)

Use the evaluation environment and prepared public fielded fixture from the [search benchmark](search-evaluation.md). These commands write into disposable directories. The private fixture contains local mailbox copies and should be removed after evaluation. The result files contain anonymous case labels, scores and timings.

```sh
runner=/tmp/banana-fielded-env/bin/python
study=tools/search-eval/mail-search-study.py
public=/tmp/banana-trec-native
collection=/tmp/banana-trec
"$runner" "$study" --prepare --fixture "$public" --collection "$collection"
"$runner" "$study" --prepare --positions --fixture "$public" --collection "$collection"
for split in development test discussion; do
  "$runner" "$study" --fixture "$public" --collection "$collection" --split "$split" --out "/tmp/proximity-$split.json"
  "$runner" "$study" --positions --fixture "$public" --collection "$collection" --split "$split" --out "/tmp/postings-$split.json"
done
fixture=$(mktemp -d)
"$runner" "$study" --fixture "$fixture" --snapshot-beta "<Beta Cache directory>"
for seed in 73124 73125 73126; do
  "$runner" "$study" --fixture "$fixture" --split personal --seed "$seed" --out "/tmp/refinements-$seed.json"
  "$runner" "$study" --positions --fixture "$fixture" --split personal --seed "$seed" --out "/tmp/postings-$seed.json"
done
```
