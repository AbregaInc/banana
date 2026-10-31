# Gmail REST API dossier for an offline-first native client (Swift, iOS/macOS, no backend)

Research date: 2026-10-05. Every Google doc page cited below was fetched live on this date (page "Last updated" stamps are 2026-09-10 or 2026-09-15; the Gmail discovery document is revision 20260928). Raw page text is saved under `scratchpad/research/raw/` next to this file.

## How to read the tags

| Tag | Meaning |
|---|---|
| `[key]` | Stated on the Google page that the key resolves to (see Source index). |
| `[disc]` | Taken from Google's machine-readable Gmail discovery document (authoritative for paths, params, defaults, max values, scopes, upload limits, schema text). |
| `[probe]` | I observed it myself with an unauthenticated HTTP request. |
| `[2nd]` | Non-Google source (blog, vendor docs, Q&A). Corroboration only, never the sole basis for a design rule. |
| `UNVERIFIED` | From memory or inference. I could not confirm it in Google's docs. I had no Gmail credentials, so nothing here was exercised against a live mailbox. |
| `INFERENCE` | My deduction from verified facts. The premises are stated. |

## Source index

Gmail docs (base `https://developers.google.com/workspace/gmail/api`):

| Key | URL |
|---|---|
| sync | https://developers.google.com/workspace/gmail/api/guides/sync |
| push | https://developers.google.com/workspace/gmail/api/guides/push |
| threads | https://developers.google.com/workspace/gmail/api/guides/threads |
| labels | https://developers.google.com/workspace/gmail/api/guides/labels |
| sending | https://developers.google.com/workspace/gmail/api/guides/sending |
| drafts | https://developers.google.com/workspace/gmail/api/guides/drafts |
| uploads | https://developers.google.com/workspace/gmail/api/guides/uploads |
| batch | https://developers.google.com/workspace/gmail/api/guides/batch |
| errors | https://developers.google.com/workspace/gmail/api/guides/handle-errors |
| filtering | https://developers.google.com/workspace/gmail/api/guides/filtering |
| listmsgs | https://developers.google.com/workspace/gmail/api/guides/list-messages |
| alias | https://developers.google.com/workspace/gmail/api/guides/alias_and_signature_settings |
| perf | https://developers.google.com/workspace/gmail/api/guides/performance |
| scopes | https://developers.google.com/workspace/gmail/api/auth/scopes |
| quota | https://developers.google.com/workspace/gmail/api/reference/quota |
| quota-old | Wayback capture 2026-02-07 of the same quota page (page last updated 2025-12-11): https://web.archive.org/web/20260207171337/https://developers.google.com/workspace/gmail/api/reference/quota |
| relnotes | https://developers.google.com/workspace/gmail/api/release-notes |
| policy | https://developers.google.com/workspace/gmail/api/policy |
| disc | https://gmail.googleapis.com/$discovery/rest?version=v1 (revision 20260928) |
| ref-history | https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.history/list |
| ref-msg | https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages |
| ref-labels | https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.labels |
| ref-send | https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages/send |
| ref-modify | https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages/modify |
| ref-attach | https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages.attachments/get |

Google platform, OAuth and help pages:

| Key | URL |
|---|---|
| tools-safety | https://developers.google.com/workspace/tools-safety |
| oauth-native | https://developers.google.com/identity/protocols/oauth2/native-app |
| oauth-core | https://developers.google.com/identity/protocols/oauth2 |
| granular | https://developers.google.com/identity/protocols/oauth2/resources/granular-permissions |
| gsi-ios | https://developers.google.com/identity/sign-in/ios/additional-scopes |
| aud | https://support.google.com/cloud/answer/15549945 (Manage App Audience) |
| unverified | https://support.google.com/cloud/answer/7454865 |
| restricted | https://developers.google.com/identity/protocols/oauth2/production-readiness/restricted-scope-verification |
| admin-api | https://support.google.com/a/answer/7281227 (admin control of third-party and internal apps) |
| help-conv | https://support.google.com/mail/answer/5900 |
| help-search | https://support.google.com/mail/answer/7190 |
| help-attach | https://support.google.com/mail/answer/6584 |
| help-ws-limits | https://support.google.com/a/answer/166852 |
| help-send-consumer | https://support.google.com/mail/answer/22839 |
| help-bw | https://knowledge.workspace.google.com/admin/gmail/gmail-bandwidth-limits |
| help-trash | https://support.google.com/mail/answer/7401 |
| help-labels | https://support.google.com/mail/answer/118708 |
| rfc5322 | https://www.rfc-editor.org/rfc/rfc5322 (section 3.6.4) |
| people-conn | https://developers.google.com/people/api/rest/v1/people.connections/list |
| people-other | https://developers.google.com/people/api/rest/v1/otherContacts/list |
| people-search | https://developers.google.com/people/api/rest/v1/people/searchContacts |
| people-othersearch | https://developers.google.com/people/api/rest/v1/otherContacts/search |
| people-dir | https://developers.google.com/people/api/rest/v1/people/searchDirectoryPeople |
| people-guide | https://developers.google.com/people/v1/contacts |
| mimestream | https://mimestream.com/help/user-guide/snoozing |

Other `[2nd]` sources consulted (corroboration only): https://cli.nylas.com/guides/gmail-api-eventual-consistency , https://cli.nylas.com/guides/gmail-attachment-id-stability , https://developer.nylas.com/docs/cookbook/email/gmail-api-pagination-sync.md , https://learn.emailengine.app/docs/sending/threading/sending-threaded , and a web search on `X-Google-Original-Message-ID` (no single authoritative page).

Base URL for all REST calls: `https://gmail.googleapis.com/gmail/v1/users/{userId}/...`, with `userId = me` `[disc]`.

---

## 0. The single most design-relevant change: May 2026 quota reset

- Gmail's usage limits changed on 2026-05-01. New Cloud projects (created on or after 2026-05-01) get the new quotas. Projects that used the API between Nov 2025 and Apr 2026 "continue with their previously set usage quotas". `[quota]`
- Google's rollout page says existing-project quotas stay unchanged "for at least 60 days" after 2026-05-01 and that owners will be notified before any change. That window has elapsed as of today. `[tools-safety]`
- I cannot tell which regime the team's Cloud project is in. Check Cloud Console → IAM & Admin → Quotas & System Limits → Gmail API ("per minute per user").
- Plan against the new numbers. The per-user limit fell from 15,000 to 6,000 units/min and `messages.get` rose from 5 to 20 units. Together that is about 10x less read throughput per user.

| Item | Before (Wayback 2026-02-07) `[quota-old]` | Now (live 2026-10-05) `[quota]` |
|---|---|---|
| Per-project limit | 1,200,000 units/min | 1,200,000 units/min |
| Per-user limit | 15,000 units/user/min | **6,000 units/user/min** |
| Daily threshold | none listed | 80,000,000 units/day/project. This is a billing threshold, not a hard cap. Charges are "planned later in 2026" with at least 90 days notice, and the threshold cannot be raised. |
| `messages.get` | 5 | **20** |
| `threads.get` | 10 | **40** |
| `messages.attachments.get` | 5 | **20** |
| `drafts.get` | 5 | **20** |
| `messages.trash` | 5 | **20** |
| `threads.trash` | 10 | **20** |

- The release note confirms that unit costs for `drafts.get`, `messages.attachments.get`, `messages.get`, `messages.trash`, `threads.get` and `threads.trash` changed on 2026-05-01. `[relnotes]`
- UNVERIFIED: whether a grandfathered project keeps the old unit costs or only the old limits. The docs say "quotas".
- Third-party pages quote "250 units/user/second" and "1 billion units/day" as current. Those are the pre-Dec-2025 values. Ignore them. `[2nd]` One third-party page does match the current per-user number of 6,000/min for new projects.

---

## 1. Sync model

### 1.1 Documented procedures `[sync]`

**Full sync.**
1. `messages.list` to get the first page of ids.
2. Batch `messages.get` for those ids. Use `format=full` or `format=raw` the first time, and cache the result. For already-cached messages use `format=minimal`, because "only the `labelIds` might change".
3. Store the `historyId` of the most recent message (the first message in the list response) for later partial syncs.
4. The same can be done with the `threads` methods, which "might be advantageous if your app primarily works with threads or only requires message metadata".

**Partial sync.** Call `history.list` with `startHistoryId`. Obtain that id from `messages.get`/`messages.list`, a previous `history.list`, or a full or partial sync.

### 1.2 `users.history.list` `[disc][ref-history]`

`GET /gmail/v1/users/{userId}/history`

| Param | Detail |
|---|---|
| `startHistoryId` | Required. Returns records after this id. Take it from a message, a thread, or a previous list response. |
| `maxResults` | Default 100, max **500**. |
| `pageToken` | Pagination. |
| `labelId` | "Only return messages with a label matching the ID." |
| `historyTypes` | Repeatable enum: `messageAdded`, `messageDeleted`, `labelAdded`, `labelRemoved`. |

- Scopes: `mail.google.com`, `gmail.modify`, `gmail.readonly`, `gmail.metadata`.
- Cost: 2 units. `[quota]`

Response `ListHistoryResponse`:
- `history[]`, `nextPageToken`, and `historyId` ("The ID of the mailbox's current history record").
- Any `messages` inside typically carry only `id` and `threadId`.

`History` record:
- `id` (the mailbox sequence id, uint64).
- `messagesAdded[]` → `{message}`.
- `messagesDeleted[]` → `{message}`. These are messages "deleted (not Trashed)".
- `labelsAdded[]` → `{message, labelIds[]}`.
- `labelsRemoved[]` → `{message, labelIds[]}`.
- `messages[]`: all changed messages. Google says "may duplicate" the typed fields and recommends using the specific change-type fields instead.
- One record "may affect multiple messages in multiple ways".

### 1.3 Validity, expiry and recovery

| Fact | Source |
|---|---|
| "History records are typically available for at least one week and often longer. However, the time period for which records are available might be significantly shorter, and records might be unavailable in rare cases." | `[sync]` |
| "A historyId is typically valid for at least a week, but in some rare circumstances may be valid for only a few hours." | `[disc]` |
| Too-old or invalid `startHistoryId`: **HTTP 404**. "Your client must perform a full sync." | `[sync]` |
| The 404 error `reason` string (probably `notFound`, message "Requested entity was not found"). The docs give only the status code. | UNVERIFIED. A third party reports the message text `[2nd]`. |
| History ids "increase chronologically but are not contiguous with random gaps in between valid IDs". Never do arithmetic on them. | `[disc]` |
| Records come back in chronological order (increasing `historyId`). | `[disc]` |
| "If you receive no `nextPageToken` in the response, there are no updates to retrieve and you can store the returned `historyId` for a future request." | `[disc]` |
| After a 404, don't retry the stale id. Run a full sync and take a fresh checkpoint. | `[sync]` |

### 1.4 Where a current historyId comes from `[disc]`

| Source | Cost | Meaning |
|---|---|---|
| `users.getProfile` → `historyId` | 1 unit | "The ID of the mailbox's current history record". Also returns `emailAddress`, `messagesTotal`, `threadsTotal`. |
| `messages.get` → `historyId` | 20 units | "The ID of the last history record that modified this message". |
| `threads.get` and each `threads.list` entry → `historyId` | 40 / 10 units | The last history record that modified the thread. |
| `history.list` → top-level `historyId` | 2 units | The current mailbox history id. This is the next checkpoint when paging is complete. |
| `users.watch` response → `historyId` | 100 units | The current mailbox id. Not usable without Pub/Sub. |

- **INFERENCE (recommended checkpoint):** call `getProfile` before the first `messages.list` page and use that `historyId` as the post-initial-sync `startHistoryId`. The sync guide instead suggests the newest message's `historyId`, which is an earlier, more conservative checkpoint that replays more records.
- Neither choice is documented as safe against index lag. I could not verify read-after-write consistency between `messages.list` and `history.list` (see 14).
- If the state-based merge in 1.6 is idempotent, replaying extra records is harmless, so prefer the earlier (safer) checkpoint if in doubt.

### 1.5 Does history report this client's own changes?

- Not stated in the sync or history docs. UNVERIFIED.
- Indirect evidence: the push guide warns "When handling notifications, be careful not to trigger another notification, which can start a notification loop." That implies API-originated mailbox changes do generate change events. `[push]`
- **Design assumption:** yes, they do. Your own modifies and sends will echo back through history. Merge by state, not by "unseen" ids. A message you just sent will appear as `messagesAdded` with the `SENT` label (see 14).

### 1.6 Ordering guarantees

Documented:
- History is in increasing id order `[disc]`.
- `messages.list` is "reverse chronological order (newest first)" `[listmsgs]`. The ordering key is `internalDate` `[disc]`.
- `threads.get` returns the conversation's messages "in order" `[threads]`.
- Batch responses are in request order, but "the server might perform your calls in any order" `[batch]`.

Not documented:
- Any consistency guarantee between a write and the next list or history read.
- Cross-method ordering (e.g. whether a `messages.get` after `messagesAdded` always succeeds).

### 1.7 Filters

- `labelId` is documented only as "Only return messages with a label matching the ID". What happens to a message that has just *left* that label (e.g. archived out of `INBOX`) is not documented. UNVERIFIED.
- Don't use `labelId` or `historyTypes` for a general mirror. Omit both and take all four record types, so you cannot miss a move-out or a trash.

---

## 2. Message formats

### 2.1 `messages.get` `[disc]`

`GET .../messages/{id}?format=minimal|full|raw|metadata&metadataHeaders=...`

- Default is `full`. The scope list is `mail.google.com`, `gmail.modify`, `gmail.readonly`, `gmail.metadata` plus add-on scopes.
- `metadataHeaders` is repeatable. "When given and format is METADATA, only include headers specified."
- Cost is 20 units regardless of format or `fields`. The quota table has no format dimension. `[quota]`

Format descriptions from the discovery doc:

| `format` | Documented behaviour |
|---|---|
| `minimal` | "Returns only email message ID and labels; does not return the email headers, body, or payload." |
| `metadata` | "Returns only email message ID, labels, and email headers." |
| `full` | "Full email message data with body content parsed in the `payload` field; the `raw` field is not used." Not allowed with the `gmail.metadata` scope. |
| `raw` | "Full email message data with body content in the `raw` field as a base64url encoded string; the `payload` field is not used." Not allowed with the `gmail.metadata` scope. |

- UNVERIFIED (observed behaviour, not in docs): `minimal` and `metadata` also return `threadId`, `snippet`, `sizeEstimate`, `historyId` and `internalDate`. `metadata` returns `payload` with `headers`, `mimeType` and no `parts`/body.
- Spike item: run one `messages.get` per format and diff the keys.
- `threads.get` takes `format=full|metadata|minimal` (no `raw`) plus `metadataHeaders`. `drafts.get` takes all four formats. `[disc]`

### 2.2 `Message` resource `[disc][ref-msg]`

| Field | Detail |
|---|---|
| `id` | "The immutable ID of the message." |
| `threadId` | The thread. |
| `labelIds[]` | Labels applied to this message. |
| `snippet` | "A short part of the message text." |
| `historyId` | uint64, last history record that modified the message. |
| `internalDate` | int64 epoch ms. "determines ordering in the inbox." For normal SMTP mail it is when Google accepted the message, "more reliable than the Date header". For API-migrated mail it "can be configured by client to be based on the Date header". |
| `sizeEstimate` | int32, estimated bytes. |
| `raw` | base64url RFC 2822, only with `format=raw`. Required on `drafts.create` and `drafts.update`. |
| `payload` | `MessagePart`. |
| `classificationLabelValues[]` | Workspace only, ignore. |

`MessagePart`:
- `partId` ("immutable ID of the message part"), `mimeType`, `filename` (only for attachments), `headers[]` (`{name, value}`), `body`, `parts[]` (children of container `multipart/*` parts).
- The top-level part's headers are the RFC 2822 headers (`To`, `From`, `Subject`, `Message-ID`, `References`, `In-Reply-To`, `Date`, ...).

`MessagePartBody`:
- `size` (bytes of the data, "encoding notwithstanding"), `data` (base64url), `attachmentId`.
- "When present [`attachmentId`], contains the ID of an external attachment that can be retrieved in a separate `messages.attachments.get` request. When not present, the entire content of the message part body is contained in the data field."

UNVERIFIED but widely relied on: `data` is the part body after content-transfer-decoding, still in the part's declared charset. Confirm in the spike before trusting it.

### 2.3 Partial responses and gzip `[perf]`

- `fields=` selects response fields.
  - Syntax: comma list, `a/b` nesting, `a(b,c)` sub-selection, `*` wildcard.
  - An invalid selector returns 400.
  - It reduces bytes, not quota units.
  - Example `fields=messages(id,threadId),nextPageToken` is syntactically valid per the guide. I did not run it live.
- gzip needs both an `Accept-Encoding: gzip` header and a `User-Agent` containing the string `gzip`.
- On Apple platforms: `URLSession` sets `Accept-Encoding` itself. Append `gzip` to the User-Agent string explicitly, because Google's guide requires the User-Agent token.
- Partial update via `PATCH` exists for labels (`labels.patch`) `[disc]`.

### 2.4 Cheapest format for a list row

- Quota is flat at 20 units per `messages.get` whatever the format, so choose by bandwidth and by whether you will need the body anyway.
- **Cheapest bytes:** `format=metadata` with `metadataHeaders=[From,To,Cc,Subject,Date,Message-ID,In-Reply-To,References,List-Unsubscribe,...]` plus `fields=` trimming.
- Attachment presence cannot be derived from `metadata`, because there is no `parts` tree. Use `format=full` (and a `fields` mask on `payload(mimeType,parts(filename,mimeType,body(size,attachmentId)))`) when the paperclip matters.
- Thread list rows are very cheap: `threads.list` (10 units, up to 500 threads) returns `id`, `snippet`, `historyId` per thread but no headers or labels. `[disc]` Subject/sender/date still need a `get`.
- `messages.list` returns only `id` + `threadId` "each message resource contains only an `id` and a `threadId`". `[disc]`
- `format=raw` is the best archival format (own MIME parser, faithful bytes) but includes attachment bytes inline in base64url, so it can be tens of MB per message. UNVERIFIED: `full` omits attachment bytes when `attachmentId` is present.

---

## 3. Threads

| Fact | Source |
|---|---|
| `threads.list` takes `q`, `labelIds` (AND semantics), `includeSpamTrash` (default false), `maxResults` (default 100, **max 500**), `pageToken`. | `[disc]` |
| `threads.list` returns thread stubs without `messages`; each stub has `id`, `snippet`, `historyId`. `resultSizeEstimate` is an estimate. | `[disc]` |
| With `q`: "If any message in a thread matches the query, the thread is returned." | `[threads]` |
| `threads.get` returns the messages in order; formats `full\|metadata\|minimal`; 40 units regardless of message count. | `[disc][quota]` |
| Threads "cannot be created, only deleted. Messages can, however, be inserted into a thread." | `[threads]` |
| `threads.modify` (10 units): add/remove up to 100 label ids each; "applies to all messages in the thread". Needs `gmail.modify` (or `mail.google.com`). | `[disc]` |
| `threads.trash` (20 units) trashes all messages. `threads.untrash` (10). `threads.delete` (20) is permanent and needs `mail.google.com` only. | `[disc][quota]` |
| Labels exist only on messages. A thread's labels are the union over its messages. | `[labels]` |
| Adding a label to a thread adds it to **existing** messages only. Later messages "don't inherit the existing label". | `[labels]` |
| Removing a label from the only message that carries it also removes it from the thread. | `[labels]` |

**How Gmail decides threading.**
- For the API, to put a new message or draft into a thread you must supply all three: the right `threadId` on the Message, `References` and `In-Reply-To` headers set per RFC 2822, and a matching `Subject`. `[threads][disc]`
- The Gmail UI help adds: conversations break off into a new conversation "when the subject line changes, or the conversation gets to more than 100 emails". `[help-conv]`
  - So a thread holds at most 100 messages in the web UI model. Whether the API enforces the same cap is UNVERIFIED.
- For automated mail, Gmail may group messages that share recipients, senders or subjects, or have a `References` header with the same IDs, sent within one week of a previous message. `[help-conv]`
- The threading algorithm itself is not otherwise published.

---

## 4. Labels

### 4.1 System labels and mutability `[labels][disc]`

| Label | Client can apply/remove? | Notes |
|---|---|---|
| `INBOX` | yes | Archive = remove `INBOX`. |
| `UNREAD` | yes | Read state = absence of `UNREAD`. |
| `STARRED` | yes | |
| `IMPORTANT` | yes | |
| `SPAM` | yes | |
| `TRASH` | yes (see 5) | |
| `SENT` | **no** | Auto-applied by `messages.send`/`drafts.send`, by `messages.insert` when `From` is the user, and by the web UI. |
| `DRAFT` | **no** | Auto-applied to all drafts. "You can't apply labels to draft messages." |
| `CATEGORY_PERSONAL` / `CATEGORY_SOCIAL` / `CATEGORY_PROMOTIONS` / `CATEGORY_UPDATES` / `CATEGORY_FORUMS` | yes | Mirror the web UI tabs. |

- "The preceding list isn't exhaustive and other reserved label names exist." `[labels]`
- `CHAT` is not listed in the labels guide. It is UNVERIFIED from memory.
- No documentation exists for any `SNOOZED` or `SCHEDULED` system label (see 6.7).
- Be tolerant of unknown system label ids from the server.
- Creating a user label that collides with a reserved name returns HTTP 400 "Invalid label name". `[labels]`
- The `Label.type` text: "System labels are internally created and cannot be added, modified, or deleted. System labels may be able to be applied to or removed from messages and threads under some circumstances but this is not guaranteed." `[disc]`

### 4.2 Label resource and CRUD `[disc][ref-labels]`

- Fields: `id` (immutable), `name`, `type` (`system|user`), `messageListVisibility` (`show|hide`), `labelListVisibility` (`labelShow|labelShowIfUnread|labelHide`), `messagesTotal`, `messagesUnread`, `threadsTotal`, `threadsUnread`, `color{textColor,backgroundColor}`.
- Maximum 10,000 labels per mailbox.
- Methods and cost: `labels.list` (1), `labels.get` (1), `labels.create` (5), `labels.update`/`labels.patch` (5), `labels.delete` (5).
  - `labels.delete` "immediately and permanently deletes the label and removes it from any messages and threads".
- `labels.list` returns only `id`, `name`, `messageListVisibility`, `labelListVisibility`, `type`. Counts need `labels.get` per label (1 unit each).
- `gmail.labels` (non-sensitive) is sufficient for label CRUD. Label list and get also accept `gmail.metadata`, `gmail.readonly`, `gmail.modify`. `[disc][labels]`
- Colours: `color` is only for `type=user` labels. Both `textColor` and `backgroundColor` are required to set a colour, and **only a fixed palette of hex values is accepted** (the exact list is in the discovery doc under `LabelColor`). Arbitrary RGB is rejected. `[disc]`
- Nested labels: Gmail's UI nests labels via "Nest label under" `[help-labels]`. At API level a nested label is a user label whose `name` contains `/` separators (`Parent/Child`). UNVERIFIED in the API docs. Confirm in the spike by creating `A/B` and checking the web UI.
- Label ids are immutable and survive renames. `[disc]`

### 4.3 Counts

- `labels.get(INBOX)` gives `messagesUnread` and `threadsUnread`. Use them for badge counts and drift detection.
- Whether system-label counts include trash/spam/drafts is not documented. UNVERIFIED.
- `getProfile` gives mailbox-wide `messagesTotal` and `threadsTotal`. `[disc]`

---

## 5. Mutations

### 5.1 Method table

| Method | Units | Scope(s) | Notes |
|---|---|---|---|
| `messages.modify` | 5 | `gmail.modify` (+`mail.google.com`) | Body `{addLabelIds[], removeLabelIds[]}`, up to 100 ids each. Returns the `Message` (sparse). |
| `messages.batchModify` | **50** | `gmail.modify` | Body `{ids[] (max **1000**), addLabelIds[], removeLabelIds[]}`. Same label delta applied to all ids. Response body is empty. |
| `threads.modify` | 10 | `gmail.modify` | Applies to all messages in the thread at that moment. |
| `messages.trash` / `untrash` | 20 / 5 | `gmail.modify` | |
| `threads.trash` / `untrash` | 20 / 10 | `gmail.modify` | |
| `messages.delete` | 10 | `mail.google.com` **only** | Permanent. "Prefer `messages.trash`." |
| `messages.batchDelete` | 50 | `mail.google.com` only | Permanent. "Provides no guarantees that messages were not already deleted or even existed at all." |
| `threads.delete` | 20 | `mail.google.com` only | Permanent. |

All entries from `[disc][quota]`. `gmail.modify` explicitly "does not allow immediate, permanent deletion of threads and messages, bypassing the trash". `[scopes]`

- Consequence: "Delete forever" and "Empty Trash" are impossible with `gmail.modify`. Trash items are purged by Gmail after 30 days. `[help-trash]`
- The `mail.google.com` scope would unlock them, but it is restricted and broader than needed.

### 5.2 Idempotency and replay

**What the API offers.**
- There is no idempotency key, no `If-Match`/ETag precondition and no request id on any mutating method. Verified by reading every parameter of `messages.modify`, `batchModify`, `send`, `drafts.*` in the discovery doc. `[disc]`
- Retries must therefore be made safe by the client.

| Operation | Replay after a lost response | Basis |
|---|---|---|
| `messages.modify` / `batchModify` / `threads.modify` with explicit add/remove label sets | Converges to the same final label state. Expect HTTP 200 for already-applied labels. | The request is a set delta, not a toggle. Confirmation that a repeat does not error is UNVERIFIED. |
| Same, if another client changed the labels in between (user un-stars on the web) | Your replay overwrites theirs. Last writer wins. | No preconditions exist `[disc]`. |
| Any modify on a message deleted in the meantime | Expect 404 (UNVERIFIED reason string). Treat as "drop the op". | `[disc]` shows no tolerance wording for modify. |
| `batchDelete` | Tolerant by design. | Quoted wording above. |
| `messages.trash` / `untrash` | Convergent. | Final state is the same. Error semantics for repeat are UNVERIFIED. |
| `messages.send` | **NOT replay-safe.** A repeat sends a second email. | No idempotency token `[disc]`. Also: "You can't assume that a 200 response means the email was successfully sent" and there can be "a delay of several minutes before the API begins returning 429" after the limit is hit. `[errors]` |
| `drafts.create` | Not replay-safe. A repeat creates a second draft. | |
| `drafts.update` | Convergent for content, but the draft's message id changes on every call. | `[drafts]` |
| `drafts.send` | **Naturally at-most-once.** The draft is deleted on a successful send, so a replay should 404. | "When the draft is sent, the draft is automatically deleted and a new message with an updated ID is created with the SENT system label." `[drafts]` A 404 on replay is INFERENCE. |
| `drafts.delete` | A repeat should 404. Treat as success. | |

- **INFERENCE:** the safest outbox send path is `drafts.create` → `drafts.send(draft id)`, persisting the draft id in the outbox row before calling send. The same draft id cannot send twice.
- Remaining ambiguity: if the response to `drafts.send` is lost, then 404 on retry means either "already sent" or "draft deleted by the user". Resolve by looking in `SENT` before telling the user it failed.
- If using `messages.send` directly, do not auto-retry after an ambiguous failure (timeout after the request body was sent, or 5xx). First check whether it already went out (see 6.3).
- A 400, 401 or 403 response is a definite non-send. A 429 is a non-send too, with the caveat above that enforcement of the daily send limit can lag by minutes (so an earlier 200 may not have been delivered either).

---

## 6. Sending and drafts

### 6.1 `messages.send` `[disc][uploads][sending]`

- Endpoints:
  - Metadata: `POST https://gmail.googleapis.com/gmail/v1/users/{userId}/messages/send`
  - Upload: `POST https://gmail.googleapis.com/upload/gmail/v1/users/{userId}/messages/send` (and `/resumable/upload/...` for resumable)
- Scopes: `mail.google.com`, `gmail.modify`, `gmail.compose`, `gmail.send`.
- Cost: 100 units. `drafts.send` also 100.
- JSON body: `{"raw": "<base64url RFC 2822>", "threadId": "<id>"}`. "Gmail messages are sent as base64URL encoded strings within the `raw` field." `[sending]`
- Response: a `Message` resource (id, threadId, labelIds including `SENT`).

**Upload variants.**
- Media upload (`uploadType=media`):
  - `Content-Type: message/rfc822`, and the body is the **raw RFC 822 bytes, not base64url**. `[uploads]`
  - There is no place for `threadId` in a pure media upload.
- Multipart (`uploadType=multipart`, `multipart/related`):
  - Part 1 is `application/json` metadata (put `threadId` there). Part 2 is `message/rfc822`. `[uploads]`
- Resumable (`uploadType=resumable`):
  - Initiate with headers `X-Upload-Content-Type: message/rfc822` and `X-Upload-Content-Length`, optionally with JSON metadata body.
  - Save the `Location` URI. PUT the bytes. A success returns 201 (or 200 when updating).
  - Interrupted uploads: query status with an empty PUT and `Content-Range: bytes */<total>`, then resume from the returned `Range`.
  - The session URI "expires after one week" in the summary but later says "within a day or so, if not used"; expiry returns 404 and unrecoverable errors return 410 (restart from scratch). `[uploads]`
  - Chunks must be multiples of 256 KB except the last.
- Guidance: simple upload for "5 MB or less"; resumable is "a good strategy to use for most applications" and is especially useful from mobile clients. `[uploads]`

### 6.2 Size limits

| Limit | Value | Source |
|---|---|---|
| Max media upload for `messages.send`, `drafts.create`, `drafts.update`, `drafts.send` | **36,700,160 bytes (35 MiB)** | `[disc]` (`mediaUpload.maxSize`) |
| Max media upload for `messages.insert`, `messages.import` | 157,286,400 bytes (150 MiB). The import description says "maximum size of the message is 150 MB". | `[disc]` |
| UI attachment limit, personal Gmail | 25 MB | `[help-attach]` |
| Workspace: sending limit, Business/Education | 25 MB; Enterprise Plus up to 50 MB "only on the web version of Gmail". Measured on "total size of message content and attachments before encoding". | `[help-ws-limits]` |
| Recipients per message via the API | 500 | `[quota][help-ws-limits]` |
| Consumer: more than 500 recipients in one message or more than 500 emails/day triggers a send limit | | `[help-send-consumer]` |
| Workspace daily sending | 2,000 messages/day (500 trial); counts aliases and delegates | `[help-ws-limits]` |

- INFERENCE: the 35 MiB API cap is roughly the 25 MB pre-encoding limit times base64's 4/3 overhead.
- Size limit for the plain-JSON (non-`/upload`) `raw` path is not documented. UNVERIFIED. Use the upload endpoint for any message with attachments.
- Receiving limits (inbound message size) are not in the pages I fetched. UNVERIFIED.

### 6.3 Replying so it threads

Documented requirements (all must hold) `[threads][sending][disc]`:
1. `threadId` supplied on the Message (or in the multipart metadata part).
2. `In-Reply-To` and `References` headers per RFC 2822.
3. `Subject` headers match.

Header construction per RFC 5322 section 3.6.4 `[rfc5322]`:
- `In-Reply-To:` = the parent's `Message-ID` field (angle brackets included).
- `References:` = the parent's `References` (if any) followed by the parent's `Message-ID`.
- If the parent has no `References` but has a single `In-Reply-To`, `References` = parent's `In-Reply-To` followed by parent's `Message-ID`.
- Subject: use `Re: <original subject>`.
- Take parent header values from the parent's `payload.headers` (the RFC `Message-ID` header, not the Gmail `id`).

Other points:
- The Gmail-UI conversation help says a conversation breaks off on a subject change or after 100 messages. `[help-conv]`
- **Client-supplied `Message-ID`:** third parties report that Gmail may replace a client-supplied `Message-ID`, keeping the original in `X-Google-Original-Message-ID`. `[2nd]` Not in Google docs. UNVERIFIED.
  - Spike: send with a custom `Message-ID` and read it back.
  - Do not rely on a client-chosen `Message-ID` to find the sent copy (see 5.2).
- If a send must be verified after an ambiguous failure, query `messages.list` with `labelIds=SENT` and `q=` plus a time bound (5 units), then `messages.get` metadata (20 units each). The Gmail search help lists a `header:` operator and `rfc822msgid:`. Whether the API honours `header:` is UNVERIFIED. `[help-search]`

### 6.4 Drafts `[drafts][disc]`

- A draft is a container with a stable `id`. Its inner message cannot be edited, only replaced: "the drafts resource is a container that provides a stable ID because the underlying message IDs change every time the message is replaced."
- Methods and cost: `drafts.create` (10, needs `raw`), `drafts.update` (15, PUT replaces content, new message id), `drafts.get` (20, `format` default `full`, `raw` allowed), `drafts.list` (5, `maxResults` default 100/max 500, `q`, `includeSpamTrash`), `drafts.delete` (10, permanent, "does not simply trash it"), `drafts.send` (100).
- `drafts.send`: you may send as-is, or supply a Draft with the `id` plus a new `message.raw` to update while sending.
- On send: the draft is deleted and a **new message id** with the `SENT` label is created and returned.
- Draft messages cannot carry any label except `DRAFT`.
- Scopes for draft methods: `gmail.compose`, `gmail.modify`, `mail.google.com`. `drafts.get`/`list` also accept `gmail.readonly`. `[disc]`
- `drafts.delete` is not recoverable from Trash. `[help-trash]`
- Autosave note: each `drafts.update` costs 15 units and replaces the message id. Keep editing local-first and debounce server saves (see 14).

### 6.5 Send-as aliases and signatures `[disc][alias]`

- `settings.sendAs.list` and `get` (1 unit each) accept `mail.google.com`, `gmail.modify`, `gmail.readonly`, `gmail.settings.basic`. **`gmail.modify` can read aliases.**
- `SendAs` fields:
  - `sendAsEmail`, `displayName`, `replyToAddress`, `signature` (HTML), `isPrimary`, `isDefault`, `treatAsAlias`, `verificationStatus` (`accepted|pending`), `smtpMsa`.
- The signature is "included in messages composed with this alias in the Gmail web UI" and "added to new emails only". **The API does not append it for you.** The client must insert it into `raw`.
- Create, delete and verify are "only available to service account clients that have been delegated domain-wide authority", so a user's custom aliases are created in the web UI and then appear in `sendAs.list`.
- Update of the primary address (signature, displayName) needs `gmail.settings.basic` or `gmail.settings.sharing`. Other aliases can only be updated by service accounts with DWD.
- A custom alias must be `accepted` (verified) before use. If `pending`, the owner of that address must complete a verification email. `[alias]`
- What Gmail does with a `From` that is not an alias is not documented. UNVERIFIED.

### 6.6 Scheduled send and snooze are not exposed

- **Neither is exposed by the Gmail REST API.**
  - A string search of the 217 KB discovery document (revision 20260928) finds zero occurrences of "snooze" or "schedule". `[disc]`
  - `Message`, `Draft`, `send`, and `Label` have no field or parameter for either.
  - Mimestream (a mature native Gmail API client) states plainly: "the Gmail API does not expose snooze functionality". `[mimestream]` `[2nd]`
- I found no evidence of a schedule-send field. Treat both as client-side features.
- The web UI has `in:snoozed` as a search operator `[help-search]`. Whether API calls expose such messages through a `SNOOZED` label is UNVERIFIED. Do not depend on any unknown label.
- INFERENCE: snooze can be local (hide and resurface in the app). Scheduled send needs the device or app to be running at send time, since no backend exists.

---

## 7. Attachments

- `GET .../messages/{messageId}/attachments/{id}` returns `MessagePartBody` `{size, data}` where `data` is base64url. Scopes: `mail.google.com`, `gmail.modify`, `gmail.readonly`. Cost 20 units (was 5). `[disc][ref-attach][quota]`
- There is no `alt=media` download or range support for this method. The discovery doc marks media upload only on send/draft/insert/import methods. Attachments always arrive as one JSON response with the entire part base64url-encoded, so a 25 MB file is a ~33 MB response. `[disc]`
  - Stream-parse it. Don't materialise the whole JSON string on iOS.
- Attachment parts in the `payload` tree have `filename`, `mimeType`, and `body.attachmentId` + `body.size`. `[disc]`
- `size` is the byte count of the decoded part. base64url length is about 4/3 of it.
- **ID stability:** `partId` and message id are documented immutable. The `attachmentId` stability across repeated `messages.get` calls is not documented. UNVERIFIED (I recall it can change). Key local storage on `(messageId, partId)` and re-resolve `attachmentId` from a fresh `get` before downloading if a call 404s.
- **Inline images:** Gmail's API exposes the MIME tree faithfully. An inline image is a part with `Content-ID: <xyz>` in `headers[]` (usually `Content-Disposition: inline`). The HTML references it as `cid:xyz`. The client matches `cid:` to the part whose `Content-ID` equals `<xyz>` and fetches via `body.data` (if inline) or `attachmentId`. Google's docs do not describe cid handling. UNVERIFIED as to small-image inline `data`.
- Sending inline images: put the image in a `multipart/related` container with `Content-ID`, per RFC 2387. Gmail renders other containers via heuristics. `[2nd]`

---

## 8. Batching

| Fact | Source |
|---|---|
| Batch endpoint: `POST https://gmail.googleapis.com/batch` (discovery `batchPath: "batch"`, `rootUrl: https://gmail.googleapis.com/`). Also observed to respond: `https://gmail.googleapis.com/batch/gmail/v1` and `https://www.googleapis.com/batch/gmail/v1`. The global `https://www.googleapis.com/batch` returns 404. | `[disc]`, `[probe]` |
| Limit: "You're limited to 100 calls in a single batch request." **Google recommends no more than 50**: "Larger batch sizes are likely to trigger rate limiting." The errors guide repeats "Don't send batches larger than 50 requests." | `[batch][errors]` |
| "A set of n requests batched together counts toward your usage limit as n requests, not as one request." Batching saves HTTP round trips only, not quota. | `[batch]` |
| Format: `multipart/mixed` request; each part `Content-Type: application/http` with a nested HTTP request (path only, no full URL, e.g. `GET /gmail/v1/users/me/messages/{id}?format=metadata`). Optional `Content-ID`. Outer headers (e.g. `Authorization`) apply to all parts unless the part overrides. | `[batch]` |
| Response: single HTTP response, `multipart/mixed`, one part per request, same order. A part's `Content-ID` echoes the request's with a `response-` prefix. **Each part has its own status line**, so partial failure is normal. My unauthenticated probe returned an outer 200 with an inner `401` part. | `[batch]`, `[probe]` |
| Execution order is not guaranteed. Dependent calls cannot share a batch. | `[batch]` |
| "All the inner requests must go to the same Google API." | `[batch]` |

- A per-part 429 or 403 (rate/concurrency) must be retried individually with backoff.
- A multi-hundred-unit batch spends quota instantly. Fifty `messages.get` calls cost 1,000 units, one sixth of the per-user per-minute allowance.
- `batchModify` (50 units for up to 1000 ids) is the quota-cheap way to bulk-mutate and is not an HTTP batch.
- Batch limits for the people API are separate and not researched.

---

## 9. Quotas and rate limits

### 9.1 Limits `[quota]`

| Limit | Value |
|---|---|
| Per project per minute | 1,200,000 units |
| Per user per project per minute | **6,000 units** (new projects; legacy projects possibly 15,000, see 0) |
| Per project per day (billing threshold) | 80,000,000 units. Not a block. "You can't request an increase". |
| Sending | 500 recipients per message `[quota]`; daily message limits per 6.2 `[help-ws-limits]` |
| Enforcement granularity inside the minute | Not documented. Pace with a token bucket at about 100 units/s (6,000/60) with a small burst. |

- API bandwidth limits are "equal to, but independent of, IMAP" and shared by all of the user's clients. `[errors]` The IMAP row on the Workspace page is 2,500 MB/day download and 500 MB/day upload; web client 750 MB/hour and 1,250 MB/day download. `[help-bw]` Applying the IMAP figures to the API is the errors guide's own statement.
- For a consumer `gmail.com` account the bandwidth figures are UNVERIFIED.

### 9.2 Quota units for the methods we would use `[quota]`

| Method | Units now | Was `[quota-old]` |
|---|---|---|
| `users.getProfile` | 1 | 1 |
| `labels.list` / `labels.get` | 1 / 1 | same |
| `labels.create` / `update` / `delete` | 5 / 5 / 5 | same |
| `messages.list` | 5 | 5 |
| `messages.get` | **20** | 5 |
| `messages.send` | 100 | 100 |
| `messages.modify` | 5 | 5 |
| `messages.batchModify` | 50 | 50 |
| `messages.trash` / `untrash` | 20 / 5 | 5 / 5 |
| `messages.delete` / `batchDelete` | 10 / 50 | same |
| `messages.attachments.get` | **20** | 5 |
| `threads.list` | 10 | 10 |
| `threads.get` | **40** | 10 |
| `threads.modify` | 10 | 10 |
| `threads.trash` / `untrash` | 20 / 10 | 10 / 10 |
| `history.list` | 2 | 2 |
| `drafts.create` / `update` / `delete` | 10 / 15 / 10 | same |
| `drafts.get` | **20** | 5 |
| `drafts.list` | 5 | 5 |
| `drafts.send` | 100 | 100 |
| `settings.sendAs.list` / `get` | 1 / 1 | same |
| `watch` / `stop` | 100 / 50 | same |

### 9.3 Error shapes `[errors]`

| Status | `reason` / message | Meaning and action |
|---|---|---|
| 400 | `badRequest` | Missing or invalid field or attachment. Not retryable as-is. |
| 401 | `authError` ("Invalid Credentials") | Expired or invalid access token, or missing scope. Refresh the token. If refresh fails, re-run OAuth. |
| 403 | `dailyLimitExceeded` (domain `usageLimits`) | Project hit an owner-set quota cap. |
| 403 | `rateLimitExceeded` | **Project** rate limit. Backoff. |
| 403 | `userRateLimitExceeded` | **Per-user** rate limit. Backoff, fewer requests. |
| 403 | `domainPolicy` | The Workspace admin has disabled Gmail apps for this domain. Tell the user to contact the admin. |
| 429 | "Too many requests: User-rate limit exceeded (Mail sending)" | Daily send limit. Shared across all of the user's clients. "with a retry time". |
| 429 | "Too many requests: User-rate limit exceeded" | Bandwidth limit. "with a retry time". Can persist "for multiple hours". |
| 429 | "Too many requests: Too many concurrent requests for user" | Per-user concurrent request limit. "Making many parallel requests for a single user or sending batches with a large number of requests can trigger this error." |
| 500, 502, 503, 504 | `backendError` | Retry with exponential backoff. |
| 404 | (history guide) | Stale `startHistoryId`. Also the expected result for deleted messages or drafts. UNVERIFIED reason string. |

- The 429 bodies say the response carries "a retry time". Whether this is an HTTP `Retry-After` header or text in the message is not stated. UNVERIFIED. Parse both defensively.
- Google's recommended backoff (a "truncated exponential backoff"): wait `min(2^n + random_ms, maximum_backoff)`, with `random_ms <= 1000` and recomputed each retry, `maximum_backoff` typically 32 or 64 s, retry cap by use case. Start retry periods at least one second after the error. `[quota][errors]`
- Concurrency: the concurrent-request ceiling is a number Google does not publish. Keep to a small constant (my recommendation: 2 to 4 in-flight HTTP requests per account, one batch of at most 50 at a time). UNVERIFIED as a Google number.

---

## 10. Push versus polling

- `users.watch` posts mailbox changes to a **Cloud Pub/Sub topic** you own. `[push][disc]`
  - Setup: create topic, create subscription (webhook push or pull), grant publish rights to `gmail-api-push@system.gserviceaccount.com`.
  - Renew at least every 7 days (Google recommends daily). Costs 100 units per call.
  - Payload is `{"emailAddress", "historyId"}`; then call `history.list`.
  - Max notification rate is one event per second per watched user. Delivery is not guaranteed: "in rare situations, notifications might be delayed or dropped", so fall back to periodic `history.list`.
- Google's own guidance: "For notifications to user-owned devices (for example, installed apps, mobile devices, or browsers), the poll-based Synchronize clients with Gmail guide is still the recommended approach." `[push]`
- Conclusion: there is no Gmail-originated push channel to a device.
  - Pub/Sub delivers to a webhook (needs a server) or a pull subscription.
  - APNs delivery needs a sender with the Apple key.
  - A serverless native client therefore polls.
- INFERENCE: a single-owner setup could, in principle, hold a Pub/Sub streaming-pull from the foreground app using the project owner's credentials, but that is still a live connection with no iOS background wake. I did not verify the IAM and scope details, so do not build on it.
- **Polling cost:** `history.list` is 2 units, and `getProfile` is 1.
  - 30 s polling is 2,880 calls/day = 5,760 units/day, about 4 units/min, or 0.07% of the 6,000/min per-user allowance and 0.007% of the 80M daily threshold.
  - Quota never limits polling. Battery, radio and iOS background rules do.
  - Reasonable: 15 to 30 s while the app is foreground and active, 60 to 120 s on an always-on Mac when idle, and an immediate poll on foreground, network-return and pull-to-refresh. On iOS background, `BGAppRefreshTask` is opportunistic only.

---

## 11. Search

- `messages.list` and `threads.list` take `q`, "most of the same advanced search syntax as the Gmail web interface". `[filtering]`
- Operators in the UI help `[help-search]`: `from: to: cc: bcc: subject: after: before: older: newer: older_than: newer_than: OR { } AND - AROUND label: category: has:attachment|youtube|drive|document|spreadsheet|presentation|userlabels|nouserlabels list: filename: "" () in:anywhere in:archive in:snoozed is:muted is:important|starred|unread|read has:*-star deliveredto: size: larger: smaller: + rfc822msgid: header: label:encryptedmail`.
- That the API honours each of these is UNVERIFIED. The Google API page only promises "most".
- Known API differences `[filtering]`:
  - No alias expansion. Searching `from:primary@` does not return mail sent from the Workspace alias, which the UI does return.
  - **No thread-wide search.** The UI can match across a thread, the API doesn't.
  - `threads.list` returns a thread if any message in it matches. Negative operators match messages first, so `-is:starred` can return a thread that contains a starred message. `[help-search]`
  - Dates in `q` are "midnight on that date in the PST timezone". For exact times, pass epoch seconds: `after:1388552400 before:1391230800`.
  - `q` is rejected with the `gmail.metadata` scope. `[disc]`
- `includeSpamTrash` defaults to false. Spam and trash are excluded unless set or you pass `labelIds`. `[disc]`
- `labelIds[]` is AND semantics across the given ids. `[disc]`
- Ordering: newest first (by `internalDate`). `[listmsgs][disc]`
- Pagination: `maxResults` default 100, **max 500**, with `pageToken`; `resultSizeEstimate` is only an estimate. `[disc]`
- There is no documented cap on total results via paging. UNVERIFIED.
- Search is a server operation: offline you search the local cache. Full-text parity with Gmail is not achievable locally.

---

## 12. OAuth scopes

### 12.1 Classification (per the current scopes page) `[scopes]`

| Scope | Class | Allows (per `[disc]` method scope lists) |
|---|---|---|
| `gmail.labels` | **non-sensitive** | Label CRUD only. |
| `gmail.send` | **sensitive** | Only `messages.send`. It is not accepted by `drafts.send`. |
| `gmail.readonly` | **restricted** | Read messages, threads, attachments, history, labels, drafts, settings (including `sendAs`, filters, vacation). `watch`. |
| `gmail.metadata` | **restricted** | Headers, labels, history only. No body, no `attachments.get`, **no `q`, no `format=full|raw`**. |
| `gmail.compose` | **restricted** | Drafts CRUD, `messages.send`, `drafts.send`, `getProfile`. |
| `gmail.insert` | **restricted** | `messages.insert`, `messages.import`. |
| `gmail.modify` | **restricted** | Everything above except: no permanent delete, no settings writes (`filters.create`, vacation update need `gmail.settings.basic`), no alias create/delete/verify. |
| `gmail.settings.basic` | **restricted** (as listed on the current page) | Settings read/write, primary-alias signature update. |
| `gmail.settings.sharing` | **restricted** | Admin and DWD only. |
| `mail.google.com` | **restricted** | Everything, including permanent delete (`messages.delete`, `batchDelete`, `threads.delete`) which accept only this scope. |

- The scopes page says: "Request this scope [`mail.google.com`] only if your application needs to immediately and permanently delete threads and messages, bypassing the trash. You can perform all other actions using less permissive scopes."
- The current page lists `gmail.settings.basic` under *restricted*. Older material called it sensitive. Trust the live page.
- **What `gmail.modify` covers for a mail client:** read, list, history, labels CRUD (labels list/get/create/update/delete), message/thread modify, trash/untrash, drafts CRUD, send, attachments, sendAs read, watch/stop, profile. `gmail.modify` is the one scope that covers everything in this dossier except permanent delete and settings writes.
- `gmail.modify.restricted` appears only in the `messages.modify` description for Workspace admins using service accounts with domain-wide delegation. It is not an end-user scope. `[disc]`
- One consent with several non-sign-in scopes shows the granular-permissions screen, where users can untick individual scopes. **Always inspect the `scope` field in the token response** and degrade features. `[granular][oauth-native]`

### 12.2 Publishing status matrix (what applies to a small private app)

| Status | User cap | Warning screen | Refresh token | Verification | Source |
|---|---|---|---|---|---|
| **External, Testing** | Up to **100** listed test users | "Tester" warning ("unverified app" risk message) before consent | **Expires 7 days from consent**. Authorizations expire after 7 days "and if your OAuth client requests an offline access type and receives a refresh token, that token will also expire". Only exception: apps requesting a subset of `openid`/email/profile. | Not required (development/testing exception) | `[aud][oauth-core][restricted]` |
| **External, In production, unverified** | **100 new users total, for the lifetime of the project** after the unverified screen is shown; "cannot be reset or changed" | "Unverified app" screen before the consent screen | The 7-day rule is stated for External + Testing only, so it does not apply. The ordinary invalidators in 12.4 do. | "Personal use": if you are the only user or all users are known personally to you, Google lists this as an exception to verification. The user cap still applies. | `[aud][unverified][restricted][oauth-core]` |
| **Internal** (Workspace/Cloud Identity org-owned project) | Org members only. Outside accounts get an `org_internal` error. | None for org users | The 7-day Testing expiry does not apply (External + Testing only). | No verification. But "user authorization of scopes associated with restricted Google Workspace services, including high-risk Gmail and Drive scopes, might require additional configuration by your organization's administrators". Admin console → API controls: "Internal apps: allows internal apps built by your organization to access restricted Google Workspace APIs. To allow API access for all internal apps, check the Trust internal apps box." | `[aud][admin-api][restricted]` |
| **Verified production** with restricted scopes | None | None | Normal | Brand verification (typically 2 to 3 business days if branding changed), restricted-scope verification ("several weeks"), annual re-verification. Security assessment (CASA, App Defense Alliance framework, Google-empanelled assessor) is required for apps that access restricted data "from or through a third-party server", renewed at least every 12 months. | `[restricted][policy]` |

- Consequence for a **personal two-device app with no backend**: External+Testing is unusable (7-day token death). Realistic options are *Internal* (if the Google account is in a Workspace org that owns the project) or *In production, unverified* (one-time click-through, 100-user lifetime cap, effectively irrelevant for one user).
- For a no-server on-device client the CASA trigger wording ("from or through a third-party server") plausibly does not apply, but I did not verify that Google's reviewers read it that way. Ask before any public launch. A native Gmail client is an approved use case ("Built-in and web email clients that allow users to compose, send, read, and process email via a user interface"). `[policy]`

### 12.3 OAuth flow facts for iOS and macOS `[oauth-native]`

- PKCE: `code_challenge` and `code_challenge_method` are listed as "Recommended". The only supported methods are `S256` or `plain` (default `plain` if the method is omitted), so send `S256` explicitly. Google describes PKCE as the protocol "to make the installed app flow more secure".
- iOS client type: bundle id; reverse-client-id custom URI scheme redirect (`com.googleusercontent.apps.<id>:/path`); no client secret; optional App Check (Apple App Attest). Loopback redirect is **deprecated** for iOS, Android and Chrome clients. Embedded web views are rejected (`disallowed_useragent`); use `ASWebAuthenticationSession` or AppAuth.
- macOS desktop: client type "Desktop app", loopback redirect `http://127.0.0.1:<port>` (or `[::1]`) with a local listener. "If your platform supports it, this is the recommended mechanism".
- Token endpoint: `POST https://oauth2.googleapis.com/token`. Refresh tokens are "always returned for installed applications". Access token lifetime is returned as `expires_in` (the doc's examples show 3,920 s). Always read it.
- Revocation: `https://oauth2.googleapis.com/revoke?token=...`. "Revocation removes all OAuth 2.0 scopes previously granted to a project, invalidating any issued access or refresh tokens for all clients registered under that project." **Signing out on one device must not call revoke**, or it kills the other devices' tokens too.
- Refresh tokens are per client id. Two devices using two client types hold different tokens; the limit is 100 live refresh tokens per Google account per client id, after which the oldest dies silently. `[oauth-core]`

### 12.4 Refresh token invalidators `[oauth-core]`

- The user revokes access.
- The token is **unused for six months**.
- **The user changes their password and the token contains Gmail scopes.**
- The account exceeds the limit on granted (live) refresh tokens: 100 per account per OAuth client id; a larger cross-client limit also exists.
- Time-based access expires.
- An admin sets a requested service to Restricted (`admin_policy_enforced`).
- Result: `invalid_grant` on refresh. The app must send the user back through OAuth.

### 12.5 Incremental authorization on installed apps

- **The raw OAuth flow does not support it.** "Incremental authorization is not supported for installed apps or devices" and "incremental authorization with installed apps is not supported due to the fact that the client cannot keep the client_secret confidential." `[oauth-native]`
- So `include_granted_scopes=true` is not available on the loopback or custom-scheme installed-app flow.
- Plan: request the **full union** of scopes you will ever need on first connect, or run a fresh full-scope consent when adding a feature (you receive a new refresh token).
- On iOS, the Google Sign-In SDK has `addScopes` and a `grantedScopes` check (`GIDGoogleUser`). `[gsi-ios]` Whether that path works with a raw AppAuth flow is not documented, and it gives you Google's SDK token handling instead of your own stored token.
- Granular consent still applies, so always read the granted `scope`.

---

## 13. People and contacts (recipient autocomplete, optional)

| API | Scope | Notes |
|---|---|---|
| `people.connections.list` (my contacts) | `contacts.readonly` or `contacts` | `pageSize` 1 to 1000, default 100. Sync tokens: **expire 7 days after the full sync**; error reason `EXPIRED_SYNC_TOKEN` then do a full sync. The first page of a full sync has an extra fixed quota (429 if exceeded, not increasable). Deleted contacts come back with `metadata.deleted`. Writes can take "several minutes" to propagate to sync. `[people-conn]` |
| `otherContacts.list` ("people you've emailed", auto-created) | `contacts.other.readonly` | Same sync token rules and limits. Fields limited to names, emails, phones, photos, metadata. `[people-other]` |
| `people.searchContacts` (server-side prefix search) | `contacts.readonly` or `contacts` | Prefix matching, `pageSize` max 30. **A warmup request with an empty query must precede searching**, since search uses a lazy cache. `[people-search][people-guide]` |
| `otherContacts.search` | `contacts.other.readonly` | Same warmup. `pageSize` max 30. `[people-othersearch]` |
| `people.searchDirectoryPeople` (Workspace domain directory) | `directory.readonly` | `[people-dir]` |

- Sensitivity classification of `contacts.readonly`, `contacts.other.readonly` and `directory.readonly` is UNVERIFIED. I did not find it in Google's docs. The Cloud Console labels each scope automatically when you add it. Treat contacts scopes as at least sensitive.
- **No-extra-scope alternative (INFERENCE):** build autocomplete from the local cache of `From/To/Cc/Reply-To` headers plus the `sendAs` list. That needs no People API scope and works offline.

---

## 14. Gotchas that bite client authors

Verified or documented unless marked.

1. **Draft message ids change on every update** and a draft's `drafts.send` creates a new message with a new id. Index drafts by *draft id*, never message id. `[drafts]`
2. **`messages.send` is not idempotent and a 200 is not proof of delivery**: quota-exceeded 429s can lag by minutes. `[errors]`
3. **Sent messages return to you via history** as new messages (with `SENT`). Dedupe by the id returned by `send` (or drafts.send). The history echo itself is UNVERIFIED, but follows from "messages added to the mailbox" `[disc]` and 1.5.
4. **Labels live on messages**; thread labels are derived unions. New replies do not inherit a thread-level label. `[labels]`
5. **`internalDate` is not the `Date` header.** Sort by `internalDate` (it "determines ordering in the inbox"). `Date` can be forged or wrong. `[disc]`
6. **`messages.list` returns only `id` and `threadId`.** Every list row needs a `get`. `threads.list` returns `id`, `snippet`, `historyId` only. `[disc]`
7. **`resultSizeEstimate` is an estimate.** Never use it as a count. Use `getProfile` or `labels.get` for counts. `[disc]`
8. **`q` dates are midnight PST** unless epoch seconds are used. `[filtering]`
9. **API search has no thread-wide matching and no alias expansion.** `[filtering]`
10. **Deleted messages 404 during sync**, since a message in `messagesAdded` may be gone by the time you `get` it (and `messagesDeleted` may refer to ids you never cached). Treat 404 as "gone", never as a hard error. Reason string UNVERIFIED.
11. **History can lose records**: "records might be unavailable in rare cases" and ids are not contiguous. Add periodic reconciliation (compare `labels.get(INBOX)` counts, `getProfile.messagesTotal`) to catch silent drift. `[sync][disc]`
12. **Trash purge after 30 days** appears as a deletion in history (INFERENCE). `[help-trash]`
13. **Huge threads:** `threads.get` costs 40 units however many messages it returns, and the web UI splits conversations beyond 100 messages. `[quota][help-conv]` Memory use for a large `format=full` thread is on you.
14. **Base64url, not base64.** `raw` and `data` use base64url (`-` and `_`). Padding tolerance on input is UNVERIFIED. `[disc][sending]`
15. **Media upload takes raw `message/rfc822` bytes, JSON path takes base64url `raw`.** Do not double-encode. `[uploads]`
16. **HTML sanitisation is the client's job.** The API returns sender-controlled MIME untouched. Gmail only sanitises signature HTML it stores. `[disc]` (sendAs text) Remote content, tracking pixels, `cid:` resolution and script stripping are all yours.
17. **Signatures are not auto-appended.** `[disc]`
18. **Custom aliases can be listed and used but not created** by an end-user app. `[disc]`
19. **System labels you do not recognise will appear** (reserved names beyond the documented set). `[labels]`
20. **Password change kills Gmail refresh tokens**; do not assume a token that worked yesterday works today. `[oauth-core]`
21. **Revoke affects every device** under the project. `[oauth-native]`
22. **Concurrent-request 429s are triggered by parallel requests and large batches**, not just volume. `[errors]`
23. **Autosave economics**: each `drafts.update` costs 15 units and swaps the message id. Debounce.
24. **`gmail.metadata` blocks `q`** and full/raw formats. If you ever demote scopes, searching and bodies stop working. `[disc]`
25. **Eventual consistency after a write**: no Google guarantee either way. Third parties report 2 to 5 s of lag. `[2nd]` UNVERIFIED in Google docs. Do not read-after-write to confirm a mutation. Trust the mutation response and reconcile through history.
26. **Message ids and label ids are immutable and thread ids are stable**, so they are safe primary keys. Attachment ids are not (see 7).

---

## Implications for an offline-first client

**Quota is the binding resource, and reads are expensive.**
- Per-user limit 6,000 units/min, `messages.get` 20 units. That is 300 gets/min or 5/s at 100% utilisation. `[quota]`
- Quota is per call regardless of `format` or `fields`, and a batch of n costs n. `[quota][batch]`

**Initial sync, cheapest correct strategy.**
1. `getProfile` first (1 unit). Keep `historyId` as the checkpoint, plus `messagesTotal` and `threadsTotal` so you know the mailbox size and average thread depth before spending anything.
2. `labels.list` plus `labels.get` per label (about 1 unit each) to seed labels and counts.
3. Page the entire id set with `messages.list`, `maxResults=500`. For 100,000 messages that is 200 pages at 5 units, about 1,000 units, about 10 seconds of budget. It also returns `threadId` per message, so you know each thread's message count locally (`includeSpamTrash` as the product needs).
4. Fetch details newest-first, per thread, choosing the cheaper call:
   - cost per thread = `min(20 × n, 40)` where n = messages in the thread. Use `messages.get` for 1 to 2-message threads and `threads.get` for 3 or more messages.
   - Example, assumption-driven: if 100k messages sit in 40k threads (25k singletons, 8k pairs, 7k threads holding 59k messages) the cost is 25k×20 + 8k×40 + 7k×40 = 1.1M units against 2.0M for per-message gets. Your distribution will differ, so measure from step 3.
5. Fetch the **newest window with `format=full`** (e.g. last 60 to 90 days, or the newest 2 to 5k messages) so the list and reading work immediately. Backfill older mail with `format=metadata` + `metadataHeaders` + `fields` for bandwidth, since quota is identical. Fetch a body on open (another 20 units).
6. Run `history.list` from the step-1 checkpoint when the first window is done and continuously thereafter. Background backfill and incremental sync must interleave.

**Time estimates (arithmetic on the published figures).**

| Scenario | Units | At 100% of per-user budget | At 50% of per-user budget |
|---|---|---|---|
| New-project limits, all 100k via `messages.get` | 2,000,000 + 1,000 | 5.6 h | 11.1 h |
| Same, thread-aware per the example above | about 1,100,000 | about 3.1 h | about 6.1 h |
| Newest 5,000 messages only | 100,000 | 17 min | 33 min |
| Legacy limits (15,000/min, 5-unit gets), if your project is grandfathered | 500,000 | 33 min | 67 min |

- Plan the UX for the first row. Do not promise "your whole mailbox in minutes".
- Throttle the backfill to leave 50% headroom for interactive actions (opens, sends, label edits). A token bucket at about 100 units/s peak is appropriate.
- Bandwidth also bites: API download is limited like IMAP, 2,500 MB/day per user `[errors][help-bw]`. At an assumed 25 KB average gzipped response, 100k messages is about 2.4 GB, roughly one day's allowance. That is another reason for `metadata` on old mail and lazy bodies.
- Use batches of at most 50 requests (1,000 units, roughly 10 s of budget at 100% use), one batch in flight, honouring per-part 429s. Concurrency beyond that risks the undocumented concurrent-request limit.

**Incremental sync, cheapest correct.**
- Loop `history.list(startHistoryId=cp, maxResults=500, pageToken=…)` at 2 units per page.
  - Omit `labelId` and `historyTypes` and process all four record types in order.
  - Apply label deltas straight from `labelsAdded`/`labelsRemoved` (0 extra units).
  - Delete on `messagesDeleted`.
  - For `messagesAdded`, fetch each not-yet-cached message after netting out ids deleted later in the same window (20 units each, or thread-aware).
  - A missing message on fetch is a 404, so drop it.
- Persist the new checkpoint, which is the response's top-level `historyId` after the **last** page, in the same SQLite transaction that applies the changes. If the process dies mid-sync, replay from the old checkpoint, so every apply step must be idempotent and state-based.
- On HTTP 404 from `history.list`, run the full-sync procedure while keeping pending outbox operations and local drafts intact, then reconcile by message id.
- Steady-state cost: poll at about 2 units per call, 5,760 units/day at 30 s. New mail at, say, 200 messages/day is about 4,000 units/day for fetches.
- Add a cheap drift check every few minutes or on foreground: `labels.get(INBOX)` and `getProfile` (1 unit each) against local counts.

**Mutations and the outbox.**
- Label-style ops (read, star, archive, trash-via-label, move) are set deltas, so they converge on replay. Make the outbox record desired end state, not toggles, and treat 404 as success-dropped.
  - Coalesce queued ops that share a label delta into `messages.batchModify`. That is 50 units per up to 1,000 ids versus 5 units each, a 100× saving at full batch size.
  - There are no preconditions, so replay overwrites concurrent web edits (last writer wins). Accept that, or re-read state before replaying old ops.
- `messages.trash` costs 20 but `messages.modify` with `TRASH` added costs 5, and `batchModify` can do it in bulk. Whether the label path is equivalent to trash (e.g. `INBOX` removal) is UNVERIFIED. Test it before adopting.
- **Send**:
  - Preferred path is `drafts.create` then `drafts.send(draftId)`, persisting the draft id first. A second `drafts.send` on the same draft cannot send twice, since the draft is deleted on success.
  - On ambiguity (lost response, timeout, 5xx), check `SENT` before offering a resend. Do not auto-retry `messages.send` blindly.
  - Compose locally. Debounce server-side draft saves (15 units each, new message id each time) to explicit save or compose-exit.
  - Reply threading needs `threadId` + `In-Reply-To` + `References` + matching `Subject` (RFC 5322 3.6.4 construction).
  - Use the `/upload` endpoint (multipart, or resumable for mobile) for anything with attachments. Cap at 35 MiB, which means about 25 MB of attachments pre-encoding.
  - Insert the alias signature yourself.
- **Scheduled send and snooze must be local features.** The API has neither. Scheduled send is only as reliable as the device being awake, which is a UX constraint to surface.
- **Delete forever and Empty Trash** need the restricted `mail.google.com` scope. With `gmail.modify` the client can only trash, and Gmail purges trash at 30 days.

**Scope and auth architecture.**
- Request `gmail.modify` once, covering read, labels, drafts, send, threads, attachments and sendAs read. Add contacts scopes up front if autocomplete is wanted, because installed-app flows do not support incremental authorization. Alternatively, derive autocomplete from cached headers.
- Always read the granted `scope` from the token response (granular consent).
- A small private app should run as **Internal** (if the Google account's Workspace org owns the Cloud project) or **In production, unverified**. Do not ship as External+Testing: refresh tokens die after 7 days.
- Store the refresh token in the Keychain. Handle `invalid_grant` by re-auth (it also happens after a password change with Gmail scopes). Never call the revoke endpoint on sign-out.
- Use a single client id family per platform: refresh tokens are not portable across client ids, so two devices with different client types each keep their own token.

**Polling (no push).**
- Poll `history.list` on foreground, on network return and on a 15 to 30 s timer while active. Quota never constrains polling. Battery and iOS background rules do. Background freshness on iOS will be opportunistic.

**Local DB design points.**
- Primary keys: message `id`, `threadId`, label `id`, draft `id`, and `(messageId, partId)` for parts. These are the documented-immutable identifiers.
- Do not key on `attachmentId` or on the message id of a draft.
- Store `historyId` per account, `internalDate` for ordering, `labelIds` as a set, headers (`Message-ID`, `References`, `In-Reply-To`, `Subject`, `From/To/Cc/Reply-To`, `Date`, `List-Unsubscribe`) and the body or `raw` as available.
- Keep `labelIds` per message and derive thread labels as a union.
- Treat unknown system labels as opaque.

---

## Could not verify (needs a live-mailbox spike, in priority order)

1. Whether the project's actual per-user quota and unit costs are the new (6,000/min, 20-unit get) or grandfathered values. Check Cloud Console Quotas.
2. Exactly which fields `format=minimal` and `format=metadata` return (`snippet`, `internalDate`, `sizeEstimate`, `threadId`, `payload.mimeType`).
3. Whether `history.list` includes this client's own changes and sends, and how drafts, trash and 30-day purge appear (`labelsAdded:TRASH` vs `messagesDeleted`).
4. Whether the 429 retry time is an HTTP `Retry-After` header; the 404 `reason` for stale history and deleted messages.
5. Replay behaviour of `messages.modify`/`batchModify` for already-applied labels and for a missing id inside a `batchModify`.
6. Whether Gmail keeps a client-supplied `Message-ID` on send; whether API `q` honours `header:`.
7. `attachmentId` stability across fetches; whether `full` ever inlines small attachments in `data`; whether `data` is CTE-decoded.
8. Trash via `messages.modify` (`addLabelIds:[TRASH]`) being equivalent to `messages.trash`; nested label naming (`A/B`).
9. The concurrent-request ceiling; enforcement granularity of the 6,000/min limit.
10. Sensitivity class of `contacts.readonly`, `contacts.other.readonly`, `directory.readonly`; whether a no-server on-device app triggers the CASA requirement; consumer-account bandwidth figures; inbound message-size limits; the JSON (non-upload) `raw` size limit; `CHAT` system label; whether snooze/schedule leave any API-visible label.
