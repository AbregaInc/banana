# Cloud Mail drafts and handoffs

This is an implementation increment behind the existing account Email gate. The native live
composer is not connected yet; attachment upload and the user-facing resolution flow remain
unfinished. Staging runs source `229c787c` with schema 0019 and no enabled Email grants.
No live email was sent during validation. Do not enable this as a complete Mail release.

`POST /v1/mail/draft` uses the existing Banana session, linked Google identity, feature eligibility
and service-held Gmail grant. It never accepts a provider token from a device. Draft metadata and
content are encrypted with account/draft-bound authenticated encryption. Revision checks preserve
concurrent edits instead of silently choosing a device's copy. Clients must retain a conflicting
local revision for the user to resolve.

A save accepts at most 512 KiB of composition data. There are at most 200 active drafts per account;
list pages contain ten records. Discard replaces the content with an encrypted null and leaves a
revision tombstone, preventing an old offline create from resurrecting discarded content. Account
deletion cascades through drafts, handoff identities and provider receipts.

Queue freezes the exact saved revision. A separate durable handoff identity survives cancellation,
so an old request cannot be reused for a later incarnation of that draft. Cancellation succeeds only
before dispatch claims the handoff. Queued work is drained by the service's minute job even when
apps are closed. A queue more than thirty minutes late requires a new explicit user decision.

The provider journal first creates a Gmail draft with a stable RFC Message-ID, then sends that
specific draft with the frozen MIME. This adapts the earlier device-owned design in MAIL-ENGINE:
the service now owns the queue; ordinary editing copies remain Banana drafts, not Gmail drafts.
The frozen content accompanies `drafts.send`, so an external Gmail edit cannot substitute different
recipients or text for the revision reviewed in Banana. Gmail-side editable-draft interoperability
has not been implemented by this increment.

Unknown creation is reconciled against one complete Gmail draft search and an exact Message-ID
header. Unknown sending is reconciled against Sent plus the exact header. Missing, duplicate,
incomplete or unreadable search results never authorize a new create/send. A missing Gmail draft
is also ambiguous, because it might already have been sent. A terminal provider refusal retains the
Banana draft and receipt. Later native controls must distinguish reconnect, conflict, refusal,
late schedule and unknown outcome; none should silently create a replacement send.

## MIME implementation

The implementation uses Nodemailer's maintained MIT-0 MailComposer, without an SMTP transport.
File and URL access are disabled. Input is a whitelisted composition, not arbitrary MIME headers or
library options. Bcc is deliberately retained in the Gmail upload: Gmail derives recipients from
MIME headers. Binary attachment streaming was tested at the composer boundary, but the API refuses
attachment references until the authenticated storage/upload path is implemented.

The library comparison used fresh Node processes for 2,000 small messages and one 25 MiB attachment.
MIMEText was faster for small messages (p95 0.018 ms versus 0.36 ms). Nodemailer's streamed large
attachment used about 74 MiB peak RSS versus 156 MiB for the buffered candidate, at 44 ms versus
12 ms. These are local process measurements, not Worker heap limits or UI performance evidence.
The selected composer also passed an actual local Workers runtime check with Unicode-capable MIME,
Bcc, stable Message-ID and a binary attachment. Worker production/live-provider acceptance remains.

References: [MailComposer](https://nodemailer.com/extras/mailcomposer),
[Gmail drafts](https://developers.google.com/workspace/gmail/api/guides/drafts),
[Gmail draft send](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.drafts/send),
[media uploads](https://developers.google.com/workspace/gmail/api/guides/uploads).

Validation evidence remains in ignored `private/cloud-rollout/mail-*` files. The full service suite passes 399 tests in each timezone. Focused tests exercise
concurrent saves/sends, cancellation, expired schedules, revocation, lost creation/send responses,
missing drafts, account deletion, input validation and MIME output. Fake provider tests do not prove
live Gmail behavior or complete native integration.
