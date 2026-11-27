# Searching what an email says

People search mail for its content: a product, an event, a request, an amount. The earlier Beta benchmarks drew their searches from senders, subjects, previews and filenames. This one draws them from the body. [Aggregate results](scale-results/mail-content-search.json)

## Method

210 conversations from the Beta mailbox (26 Nov 2026, four accounts), 70 from each age band: the last 30 days, 31–180 days, and older. Each contributes its newest message with stored body text. A local model (Qwen 3.5 4B on MLX, running on the Mac, so no mail leaves it) read the first 1,800 characters of the body only and wrote the 1–4 word search a person would type after forgetting the subject and the sender. 60 searches use only words absent from the subject, sender and recipients. The other 150 also name a company or person that appears in the headers, as people do. Gmail was searched through Banana’s connection in the account holding the email. To measure what a missing body costs, the same index was rerun with the bodies of those 210 conversations removed (`fts_state` cleared, re-indexed).

## Results

| Intended conversation in the first five | Tasks | Banana | Banana without the body | Gmail | Previous chronological |
| --- | ---: | ---: | ---: | ---: | ---: |
| All | 210 | **102** | 61 | 76 | 74 |
| Last 30 days | 70 | **35** | 24 | 34 | 31 |
| 31–180 days | 70 | **27** | 17 | 22 | 21 |
| Older than 180 days | 70 | **40** | 20 | 20 | 22 |
| Words only in the body | 60 | **28** | 12 | 24 | 24 |
| Words also in headers | 150 | **74** | 49 | 52 | 50 |

First place: Banana 56, Banana without body 27, Gmail 40. In the first 50: 144, 103 and 129.

**The body is the largest single factor.** Removing it cut Banana’s top-five hits from 102 to 61. For mail older than six months it halved them, 40 to 20. Without bodies Banana falls behind Gmail, 61 against 76. With them it leads, 102 against 76.

Gmail matched most targets but ordered newest first. Of its 134 misses, 67 older targets were pushed past 50 by newer matches and 53 matched at ranks 6–50. Gmail answered in a median 394 ms through the service.

## What this means for the Beta mailbox

The cloud mailbox fills content only for mail from the last 183 days (`FILL_DAYS`, overridable by `MAIL_FILL_DAYS`), and drops older content after 90 days unread. Devices store what the cloud has. In the personal account, 29,492 of 156,062 conversations (19%) have a body on the device. For the other 81%, content search behaves like the “without the body” column, and Gmail does better.

## Limits

The searches are written by a model from the email text, not typed by the owner, and one mailbox is sampled. The model saw the body but not the subject. Every target here had a body available, so the no-body column is an ablation of the same emails, not a sample of the mail that currently lacks one. The model and fixture paths are in [content-queries.py](../../tools/search-eval/content-queries.py).
