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
