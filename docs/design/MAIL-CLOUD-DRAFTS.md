# Gmail drafts, coordinated by Banana Cloud

Gmail owns draft content and stable draft IDs. Banana Cloud authenticates clients, holds provider
grants, serializes operations on each Gmail draft, and retains encrypted pending edits plus compact
operation receipts. Native clients own the composer, local cache and offline outbox. There is no
second Banana mailbox or server-owned editable draft store.

## Contract

- `/v1/mail/read` supports `drafts` (paginated Gmail listing) and `draft` (Gmail minimal, metadata,
  full or raw content). These reads include drafts created outside Banana. The existing Gmail
  history transport remains the incremental mailbox change source for native caches; a history
  change is followed by a fresh draft read/list through Banana, not a read of a shadow mailbox.
- `/v1/mail/draft` supports `create`, `update`, `delete` and `send`. Every mutation carries a durable
  `operationID`. The client persists one create identity with its local draft before delivery and
  retains the returned Gmail draft ID across edits/devices. A retry uses the identical request.
- Create and update write Gmail immediately. Each acknowledged response carries the stable Gmail
  draft ID and current message ID. Update, delete and send require that observed message ID.
  Gmail replaces a draft's message ID when its content changes.
- Banana serializes mutations on `(Google identity, Gmail draft ID)`. A second device working from
  an old message ID gets a conflict. Its encrypted pending edit remains recoverable, and its local
  outbox must retain the copy for the user to resolve.
- Send calls `drafts.send` with the existing draft ID. It does not upload another copy or reconstruct
  a separate Banana draft at send time. The removed queue/scheduling endpoints are refused; no Mail
  cron dispatch remains. This change does not implement a replacement scheduling feature.

A stable RFC Message-ID identifies each create/update operation. Unknown creation is reconciled
against one complete draft-search match; unknown update against the draft's exact header. Unknown
send is reconciled against Sent and the exact header captured before dispatch. Missing, duplicate,
incomplete or unreadable evidence never authorizes another write. A 404 after dispatching send is
ambiguous, since the draft could have been sent already. Unknown deletion resolves only after a
successful Gmail read confirms the draft is absent.

After a successful mutation, the journal retains request identity/hash and a compact receipt,
without the saved composition. Failed and uncertain writes retain encrypted pending content for
recovery. Account deletion removes the journal. The unused schema-0019 tables remain for safe
migration/rollback; current code neither reads nor writes them. Any old staging content must be
inspected and migrated explicitly before those tables are removed, never silently discarded.

## Provider limits and remaining integration

Gmail's documented draft update/send API has no atomic compare-and-swap revision parameter.
The preflight message-ID check detects already-observed external changes, but a Gmail client can
still edit between that check and the mutation. Banana's journal serializes Banana clients only;
it must not be described as an atomic lock on Gmail or as complete protection against external races.

The native live composer/outbox integration and conflict/unknown-outcome controls remain unfinished.
The service accepts bounded structured text compositions and explicitly refuses attachment upload
references until that path exists. Existing Gmail drafts, including attachments, can be read and
sent without reconstructing their MIME. This increment is not a complete Email rollout and grants
remain disabled pending native and live-provider acceptance.

## Implementation and evidence

Nodemailer's MIT-0 MailComposer streams create/update MIME without an SMTP transport. File and URL
access are disabled, input fields are whitelisted, and Bcc is retained for Gmail's envelope handling.
The previous local Worker-runtime and large-attachment composer measurements remain valid only for
that MIME component; they are not proof of end-to-end native sync or physical-device performance.

Focused tests cover immediate Gmail persistence, successful-content cleanup, concurrent device
updates, external revision conflicts, lost create/update/send/delete acknowledgements, delayed
provider reads, account gates and existing Gmail drafts. API adapter tests verify PUT to the existing
draft and ID-only send. Evidence is retained under `private/cloud-rollout/gmail-draft-*`.

References: [Gmail drafts](https://developers.google.com/workspace/gmail/api/guides/drafts),
[draft update](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.drafts/update),
[draft send](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.drafts/send),
[MailComposer](https://nodemailer.com/extras/mailcomposer).
