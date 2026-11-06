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

The native driver now persists editor state and exact pending operation identities in the existing
GRDB intent store. Draft listing imports Gmail IDs/versions without rewriting original MIME;
concurrent local edits are retained for explicit Keep mine / Use other resolution. A complete
provider listing followed by a structured not-found response removes a clean cached draft;
local changes survive a disappearance and require an explicit choice. Unknown sends
reuse their original operation identity. Cached draft views are bounded and backed by disk pages.
The live composer is wired behind both Email eligibility and a connected provider grant. It supports
new drafts, replies, forwarding, attachments and explicit conflict recovery. Imported Gmail MIME is
read-only until the user chooses Edit as text; that conversion downloads and retains attachments.
An editor baseline token prevents an old open editor from silently overwriting a background import.
Scheduled send and cross-account From switching are unavailable in live Mail. A new draft uses the
selected account; fixture-only controls do not imply provider support.

Attachment uploads are temporary operation parts, not another draft store. The authenticated binary
endpoint accepts SHA-256-addressed parts up to 1 MiB, reserves a 100 MiB per-account quota, and checks
all parts before streaming MIME to Gmail. An acknowledged operation removes its temporary objects;
unresolved operations retain them. Unreferenced parts expire after 24 hours. The native client keeps
immutable synced copies and persists the exact file/hash snapshot with the pending operation.
Local attachment copies referenced by recoverable draft records remain retained; automatic local
attachment garbage collection is not yet implemented.

Email grants remain disabled pending live-provider and multi-device acceptance. The implementation
and automated checks do not establish successful Google consent or physical-device interaction.

## Implementation and evidence

Nodemailer's MIT-0 MailComposer streams create/update MIME without an SMTP transport. File and URL
access are disabled, input fields are whitelisted, and Bcc is retained for Gmail's envelope handling.
The previous local Worker-runtime and large-attachment composer measurements remain valid only for
that MIME component; they are not proof of end-to-end native sync or physical-device performance.

Focused tests cover immediate Gmail persistence, successful-content cleanup, concurrent device
updates, external revision conflicts, lost create/update/send/delete acknowledgements, delayed
provider reads, account gates and existing Gmail drafts. API adapter tests verify PUT to the existing
draft and ID-only send. Evidence is retained under `private/cloud-rollout/gmail-draft-*`.

Native focused correctness evidence: `private/cloud-rollout/native-draft-focused-9/` (30 passing
tests), transport evidence: `private/cloud-rollout/native-draft-http/` (18 passing tests), and the
Mac Dev compile: `private/cloud-rollout/native-draft-mac-build-2.log`. Broader Mail index run 7
retains 244 tests and failing HTML preparation timing assertions; it is not a passing gate.
The iOS composer/cloud mapping run passes 68 tests (`native-draft-model-tests-2.xcresult`).
The component run (`native-draft-components/gate.json`) retains seven RSS failures and no latency
failures; it preceded the external-deletion follow-up and does not certify that follow-up.
Live-provider and physical Mail interaction results remain missing.

Attachment integration evidence: service commit `0d53d787` passes 404 tests in each timezone and
is deployed to staging with schema 0020. The source endpoint matches that commit and the binary
upload endpoint rejects an unauthenticated request. Native draft/source checks pass 35 tests
(`native-attachment-focused-final/`), HTTP transport checks pass 19 (`native-attachment-http/`),
and the Mac compile passes (`native-attachment-mac-final.log`). The final iOS model run passes
70 tests (`native-attachment-model-final.xcresult`). These are automated checks, not live-provider
or physical-device acceptance; production Email eligibility is unchanged.

References: [Gmail drafts](https://developers.google.com/workspace/gmail/api/guides/drafts),
[draft update](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.drafts/update),
[draft send](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.drafts/send),
[MailComposer](https://nodemailer.com/extras/mailcomposer).
