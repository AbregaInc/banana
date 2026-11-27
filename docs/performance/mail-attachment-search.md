# Searching what an attachment says

[Aggregate results](scale-results/mail-attachment-search.json)

## Method

150 named attachments from the Beta mailbox (26 Nov 2026): 70 PDFs, 40 Office or CSV files and 40 images over 30 KB, one per message. They were downloaded through Banana’s service by the read-only Mac probe (`--mail-gmail-attachments`, branch `bberenberg/gmail-search-bench`) and extracted on the Mac. PDFs used PDFKit, with Vision OCR on the first five pages of a scanned PDF. Images used Vision OCR. `.docx` used `textutil` and spreadsheets used openpyxl. A local model (Qwen 3.5 4B, MLX) read only the first 1,800 characters of each attachment’s text and wrote the 1–4 word search a person would type to find it. To simulate indexing, the first 8,000 characters of the attachment text were added to the message’s indexed text, and the index was rebuilt. Gmail was searched through Banana’s connection in the account holding the email.

| Type | Files | Text found | Median extraction |
| --- | ---: | ---: | ---: |
| PDF | 70 | 69 | 62 ms |
| Office / CSV | 40 | 40 | 55 ms |
| Image (OCR) | 39 | 31 | 514 ms |

One PDF hit the 120-second timeout.

## Results

| Intended conversation in the first five | Searches | Banana today | Banana with attachment text | Gmail |
| --- | ---: | ---: | ---: | ---: |
| All | 140 | 26 | **40** | 41 |
| Words found only in the attachment | 29 | 0 | 6 | **10** |
| Words also in the email | 111 | 26 | **34** | 31 |
| PDF | 69 | 13 | **22** | 16 |
| Office / CSV | 40 | 12 | 16 | **17** |
| Image | 31 | 1 | 2 | **8** |

Indexing attachment text raised top-five hits by half, from 26 to 40, roughly matching Gmail at 41. It helped most on PDFs, 13 to 22, ahead of Gmail. Banana cannot answer a search whose words appear only in an attachment until that text is indexed. Images gained little from OCR. Gmail found eight image targets, perhaps from other signals, but 31 searches are too few to say.

## Limits

One mailbox and model-written searches. The simulation adds attachment text to the body field, which is capped at 16,000 characters. Production would give attachments their own field. Many searches named a company with lots of other mail, which makes them hard for every method.

## Ranking attachment text (26 Nov 2026)

The simulation above put the text of 139 target attachments into an index where no other message had any, so "has attachment text" alone singled out the targets. The rerun below uses the text Banana Cloud actually extracted for 2,616 of the 4,799 messages with document attachments in the same Beta snapshot. 53 of the 140 searches have a target among them. Each configuration was also replayed on the 380 header and filename searches and the 210 content searches, to catch regressions. [Aggregate results](scale-results/mail-attachment-ranking.json)

| Intended conversation in the first five | Attachment searches (53) | Words only in the attachment (10) | Header and filename (380) | Content (210) |
| --- | ---: | ---: | ---: | ---: |
| No attachment text | 10 | 0 | 144 | 101 |
| `attachments` field in the main ranking | 16 | 3 | 143 | 101 |
| The same, without length normalisation | 29 | 6 | 139 | 88 |
| The same, boosted ×8 | 21 | 4 | 141 | 96 |
| Appended to the body field | 17 | 4 | 143 | 100 |
| **Ranked on its own, best all-words match takes one of the first five** | **23** | **6** | **143** | **98** |
| Gmail (searched in the target's account) | 25 | | | |

In the main ranking, BM25's length normalisation compares each message's attachment text with the field's average over every message. Most messages have none, so every document looks very long and sinks. Removing normalisation fixes attachments but lets long files win unrelated content searches. Boosts and caps only moved along that trade-off. Ranking attachment text separately and reserving one place, as the index already does for filenames, kept first-place hits unchanged on every set (46 header, 57 content). It cost two header and three content searches whose target sat fifth.
