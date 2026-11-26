# Banana Mail search compared with Gmail search

Banana’s ranked local search and Gmail’s own search received the same 380 first queries from the Beta mailbox (four Google accounts, 26 Nov 2026). Gmail was queried through Banana’s connection, the service’s `/v1/mail/read` path that Mail’s Gmail search uses, in the account holding the target, as someone would search in Gmail. Each method is scored on whether the intended conversation is in the first five. [Aggregate results](scale-results/mail-vs-gmail.json)

| Search | Tasks | Gmail | Banana | Either |
| --- | ---: | ---: | ---: | ---: |
| All | 380 | 109 | **144** | 160 |
| Remembered conversation | 120 | 23 | **31** | 39 |
| Recent sender | 120 | 34 | **58** | 60 |
| Partial filename | 100 | 22 | **24** | 30 |
| Complete filename | 40 | 30 | **31** | 31 |
| Target 30 days old or newer | 84 | 38 | **45** | 54 |
| Target 31–180 days old | 102 | 34 | **37** | 43 |
| Target older than 180 days | 194 | 37 | **62** | 63 |
| Target with headers only on the device | 61 | 5 | **14** | 14 |

Gmail found 16 targets Banana missed. Banana found 51 Gmail missed.

## Why each one misses

Gmail’s API lists matches newest first. Of its 271 misses, 175 matched the query, but more than 50 newer messages also matched and pushed the target out of the list. Another 87 matched at ranks 6–50. Gmail failed to match the target six times and returned nothing three times. Gmail’s matching is strong. Its ordering loses older mail.

Banana ranks by relevance. Of its 236 misses, 49 sat at ranks 6–50 and 187 were outside the first 50. 151 of those had the body indexed, so they are ranking failures, not missing data. Gmail’s 16 wins were mostly recent: nine targets were 30 days old or newer and 15 were newer than 180 days. All were one- or two-word queries. Banana placed seven of them between ranks 9 and 21 and missed the other nine in its first 50. Its preference for recent mail is too weak for short queries.

Gmail did not rescue mail whose body Banana lacks. Those 61 targets were mostly older, and Gmail’s newest-first order buried them.

## Combining the two

| Policy | Top five, of 380 |
| --- | ---: |
| Banana alone | 144 |
| Banana’s first four, then Gmail’s first unseen match | 139 |
| Banana’s first three, then Gmail’s first two unseen | 130 |
| Banana’s first 50, conversations also in Gmail’s first 10 moved up | 144 |
| Banana’s first 50, conversations also in Gmail’s first 50 moved up | **149** |

Reserving top-five slots for Gmail lowered success, because Gmail’s first results are its newest matches. Using Gmail’s matches only to reorder Banana’s own candidates gained five, mostly remembered conversations and recent senders, and lost three partial-filename targets. Gmail answered through the service in a median 403 ms, p95 967 ms, against about 7 ms for Banana. Any Gmail signal therefore arrives after the first list is visible. Reordering rows the person is already reading costs more than five targets in 380.

## Limits

Every target conversation is held on the device, because tasks are sampled from the local index. This benchmark cannot show how often Gmail finds mail Banana never fetched. The cues are generated from sender, subject, snippet and filenames in one mailbox rather than typed by a person. Searching Gmail only in the target’s account favours Gmail. Banana searched all four accounts. In the target’s account only, Banana found 151.

## Reproduce

Private inputs stay outside the repository. Build the fixture and Banana’s lists as in [ranked integration](mail-ranked-integration.md), then run `RankedMailReplayTests/testTopLists` with `RANKED_MAIL_TOPLISTS`. Gmail’s listings come from a Beta Mac build carrying `MailGmailSearchProbe` (branch `bberenberg/gmail-search-bench`), launched hidden with `--mail-gmail-search` and `BANANA_GMAIL_SEARCH_IN`/`BANANA_GMAIL_SEARCH_OUT`. It reads through the service only and opens no mail store. Then:

```sh
python tools/search-eval/mail-vs-gmail.py --fixture "$work/beta" --local "$work/local-top.json" \
    --gmail "$work/gmail-top.json" --out docs/performance/scale-results/mail-vs-gmail.json
```
