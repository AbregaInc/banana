# Shared cloud mailbox

Status: built on branch `mail/cloud-shared-sync`; the service runs on staging only, behind
per-account `email` eligibility; no client build carrying it is installed anywhere. Recorded 6 November 2026. Extends [the cloud plan](CLOUD-AND-RELEASE-PLAN.md)
workstream 6 and keeps every invariant of [the Mail engine](MAIL-ENGINE.md) §2.

Before this change each device listed, polled and downloaded the same Gmail mailbox through
the `/v1/mail/read` passthrough. Banana Cloud paced the requests ([pacing](MAIL-READ-PACING.md))
and stored nothing. Now **Banana Cloud downloads each message from Google once per account and
every device of that account syncs from Banana Cloud.** Google stays the upstream record;
Banana Cloud is the shared sync authority; devices keep their durable caches, offline search
and pending actions.

## 1. What the cloud holds, per Google account

One Durable Object with SQLite storage per Google identity (`Mailbox`, named by the Google
`sub`; a `sub` belongs to one Banana account). It holds metadata only:

| Table | Holds |
|---|---|
| `meta` | email, owning Banana account, `epoch` (random, new for every mailbox), Gmail history `checkpoint`, last poll, the running scan, the feed counter, `horizon` (highest purged sequence) |
| `msg` | per Gmail message: id, thread id, `hist` (newest history record or read reflected), `labels` (JSON, sorted), `known` (the label set is exact), `date`, feed `seq`, `gone` (Gmail deleted it), `cached` (bytes of stored content), `used_at` |
| `mark` | which (label, id) pairs the running scan has listed |
| `verify` | ids that need a per-message `minimal` read before anything is concluded |
| `fetch` | ids whose content should be downloaded ahead of any device asking (new mail, the Inbox head) |

**Content** — Gmail's `format=full` JSON for a message, and attachment bodies a device asked
for — lives in R2 under `mail/<sha256(sub)>/<sha256(id)>`, sealed with AES-256-GCM by the
existing `TOKEN_KEY` (`crypto.js` `sealBytes`). The additional data is
`mail-content:<sub>:<message id>`, so an object only opens as its own account's own message.
Nothing in SQLite carries a subject, address, snippet or body. Content over 16 MB is not cached;
it is passed through as before.

A D1 table, `mail_mailboxes`, lists which Google identities have a mailbox and when a device
last read it, so the quarter-hour job can re-arm an alarm that died and account deletion can
find every mailbox.

## 2. The ingestion worker

The mailbox's alarm runs one bounded step at a time, never two at once (an in-memory lock), in
the agreed priority order:

1. **Handshake** (first request): `profile` — the address must be the mailbox's own
   (invariant 2) — stores `checkpoint = historyId` *before any listing*, then `labels`, then
   starts scan generation 1 and queues the Inbox head (the newest 50 Inbox messages) for
   content.
2. **After a device action**: the messages it changed are read (`minimal`) first, so the
   result reaches the other devices with Gmail's own `historyId`.
3. **History**: `history.list` from the checkpoint, every page, applied page by page; each page
   moves the checkpoint. A 404 on history starts a new scan generation (5.3's reconcile) and
   keeps every row.
4. **Content for new mail and the Inbox head** (`fetch` queue), full reads stored in R2.
5. **Inbox check**: one listing of `INBOX` (up to 1,000 ids) every ten minutes while a device
   is reading, compared with the stored Inbox (5.8).
6. **Verification** reads.
7. **Backfill**: listings of every label, `INBOX` first, then the unlabelled listing
   (`includeSpamTrash`, 500 ids a page, 5 units), then the close.
8. **The content fill** (§5a): every message without content, newest first, on the
   background lane only, with whatever of the identity's budget is free.

Steps 1–6 use the existing pacing reservation and may wait up to ten seconds. Backfill asks for
a **background** reservation: it only takes a slot that is free *now*, so a device's
content request is never queued behind backfill; otherwise the alarm is set for when the slot
frees. Pacing stays per Google identity in D1, shared by the passthrough, the content path and
the worker (4,500 units a minute).

While a device has read the feed in the last two minutes, history is polled at most every
ten seconds and any feed request asks for a poll if the last one is older than that; otherwise
every two minutes for a day after a device last read, then every 30 minutes, which keeps the
checkpoint inside Gmail's history retention. With a live Gmail watch (§2a) polling is the
safety net only: every minute while a device reads, every 10 minutes for a day, then every two
hours.

## 2a. Gmail push, and the push to the devices

Built 7 November 2026 on branch `mail/body-prefetch`; not deployed.

**Gmail to the service.** Each mailbox calls `users.watch` (100 units) with the topic in
`MAIL_PUSH_TOPIC`, at its first alarm and then from the quarter-hour job a day before the
watch's 7 days end (`mail_mailboxes.watch_expires_at`, migration 0023). The watch has **no
label filter**: an include filter is evaluated on the message's labels after the change, so an
archive (INBOX removed), a label added on the web outside the Inbox, or a message sent from
another client would never notify; each notice costs only a coalesced history read (2 units).
Pub/Sub pushes each notice to `POST /v1/mail/push` with an OIDC token. The route verifies
Google's signature (Google's published keys), issuer, audience (`MAIL_PUSH_AUDIENCE`, default
`<PUBLIC_URL>/v1/mail/push`), expiry, and that it was minted for `MAIL_PUSH_SERVICE_ACCOUNT`,
verified; anything else is 401. The notice's `emailAddress` finds the mailbox through
`mail_mailboxes` ⋈ `google_links`; its `historyId` is not used for anything but "wake up": the
mailbox polls history from its own checkpoint at once, which queues new mail's content (step 4).
An unknown address or a malformed notice is acknowledged (204) so Pub/Sub does not retry it.
A refused `users.watch` (a missing topic grant) is not lost access: the mailbox logs it, polls
at the unwatched cadence and tries again hourly. Turning Mail off, unlinking Google or deleting
the account calls `users.stop` first, while the grant still works. Setup: `Service/tools/gmail-push-setup.md`.

**The service to the devices.** When new mail's content (history's `messagesAdded`, fetch
queue prio 1) is stored and published, the mailbox sends one silent push to the account's
devices through the existing `pushTo`: `{"aps":{"content-available":1},"b":{"k":"mail"}}`,
collapse id `mail`, no address or content in it. A burst sends one; the next waits out 15 s.
The fill and the Inbox head never push. On iOS the app handles `k: "mail"` like `calendar` and
`sync`: within the push's background window (about 30 s; no new background mode — the app's
existing `remote-notification`), one feed pass for each account and a bulk pull of the new
messages' text (`MailPushWake`), on a device where Mail was ever opened (MAIL-ENGINE invariant
16). On the Mac the same pull runs when the push arrives. No visible new-mail notification is
sent: that is the owner's product decision.

End to end: Gmail → Pub/Sub (Google states seconds) → `/v1/mail/push` (verify, one D1 read,
one DO call) → history read (one paced 2-unit read, normally no wait) → content (one paced
60-unit read; ≤ 0.8 s queueing) → R2 → APNs (silent; iOS may delay or coalesce background
pushes, especially on low battery) → device feed page + one bulk content request.

## 3. Order: newer always wins

- **Listings add, never remove.** A scan's listing floor is the checkpoint when the scan
  *started*. A listed membership is added only when the message's `hist` is not newer than that
  floor; otherwise the message is verified ([backfill order](MAIL-BACKFILL-HISTORY-ORDER.md)).
  An archive applied from history after the scan began is therefore never undone by a listing.
- **History** applies a record only if its id is greater than the message's `hist`; applying is
  by state, so replay is harmless.
- **A read** replaces the label set only when its `historyId` is not older than `hist`
  (invariant 23). A read of a message Gmail deleted is not stored (invariant 29).
- **Removal** only on a positive statement: `messagesDeleted`, `labelsRemoved`, an exact read's
  label set, or a parsed `notFound` for that message id (invariant 1). Absence from a listing
  queues a verification; at the close of a scan, a membership not listed again on a message that
  existed before the scan and has no newer history is verified, never removed.
- A message's labels are **published only once exact**: after a per-message read, or at the
  close of the scan that listed every label. Partial knowledge never reaches a device.

## 4. The device feed

`POST /v1/mail/feed {email, after, limit, fresh}` (a POST, so no address sits in a URL) returns, in `seq` order, every message whose
published state changed after the cursor: `{id, thread, history, date, labels}`, or
`{id, history, deleted:true}`. Each message has one row and one `seq`, so the feed is
compacted: catching up from zero (`after` absent) is a snapshot of the whole known mailbox, and
from a cursor it is the changes since. The response carries `epoch`, `cursor`, `more` and
`complete` (the first scan has closed). Deleted rows stay 30 days; a cursor older than the
horizon, or from another `epoch`, answers `410` and the device starts again from zero.

**On the device**, an entry is applied exactly as a per-message read
(`MailMessageImporter.apply` with `floor = history`): the stale-read rule, tombstones, kept
messages (`vis = 4`) and the overlay all hold. A deleted entry goes through the device's own
removal rules, including the bulk hold of invariant 3. A new id becomes a stub with its exact
labels; the fill then fetches its body. The cursor is saved in the same transaction as the page.

**Catch-up from zero** on a device that already holds mail: every row the feed delivers is
marked. When the device has reached the head *and* the cloud says `complete`, the rows it holds
that the feed never named are sent to `POST /v1/mail/check` (100 at a time). The cloud verifies
each with a `minimal` read and publishes the state or a deletion, which reaches the device
through the feed like anything else. Nothing on the device is removed for being absent.

## 5. Content

The device keeps its fill. `/v1/mail/read` for a `message` in `full` (Gmail's default) asks the
mailbox: a stored copy is opened and returned with the mailbox's current labels and `historyId`;
on a miss the mailbox fetches it from Google once (concurrent requests for one id share the
fetch), stores it, and applies the read under the stale-read rule. `attachment` reads are
cached the same way. `profile` is answered from the mailbox (its checkpoint, never newer than
Gmail's), which the device's floors treat as conservative. `minimal`/`metadata` reads, thread
reads, listings and history still go to Google: they are verification and must be fresh.

### 5a. The content fill, and bulk content for the devices

Built 7 November 2026 on branch `mail/body-prefetch`; not deployed.

**The fill.** After the scan has closed, the alarm stores content for every message without
it, **newest first**, until it walks out of its window (`MAIL_FILL_DAYS`, default 183: the
engine's default sync limit). Listings carry no dates, so the walk orders by the Gmail id —
`(length(id), id)` descending, a partial index `msg_fill` over rows with no content — which
Gmail assigns in time order (ASSUMED of real ids; true of the fake's). It stops after 20
messages in a row dated before the window (one imported old message cannot stop it). Spam and
Trash are skipped. Its watermark (`meta.fill`: the last id taken) survives alarm restarts and
Durable Object eviction; a closing scan, or six hours after a finished walk, starts it again
from the newest (cheap: the index holds only rows still without content). It reads on the
background lane only — a slot that is free now, never one a person's read reserved — so it
uses whatever of the identity's budget nobody else is using, up to the 4,500-units-a-minute
ceiling less one full-read slot a minute kept for interactive reads: 74 units a second, one full
read every 811 ms. A person's read arriving during a fill burst waits at most one slot (800 ms).
When Google says "too many" (a 429, or `rateLimitExceeded` on any of the mailbox's reads), the
fill halves its rate for five minutes — again for each further limit, to an eighth — then ramps
back to full over five more; interactive reads keep their existing behaviour. Listings,
verification, history and new mail's content all run before it in the step order. Content inside the window is not dropped as "unused for 90 days".
Storing content publishes the message again with `content: true`, so the devices learn from
the feed what they can pull.

Cost per account during the fill, in a quiet period: **4,440 messages and 266,400 Gmail units an
hour** (74% of the 6,000-units-a-minute per-user quota; the ceiling is not raised). Whatever a
person or a device reads in that time comes out of the fill's share. Six months at the engine's
assumed 110 messages a day (≈ 20,000 messages) is about **four and a half hours**, once;
afterwards only new mail. R2: Gmail's `full` JSON
(base64 bodies, ≈ 1.35× the raw message) sealed; at an ASSUMED 50–75 KB a message, **1.0–1.5 GB
a mailbox** for six months (≈ $0.015–0.02 a month at R2's storage price). Content over 16 MB is
never stored.

**Bulk content.** `POST /v1/mail/content {email, ids ≤ 50}` answers, for each id, the stored
`full` message with the mailbox's current labels and position, `missing` (not stored yet),
`gone`, or `later` (the answer reached 8 MB). It never asks Google: a pull costs no Gmail quota.
It is answered only for the session's own Mail link (the same checks as the feed), and each
object opens only with its own sub and id as AAD; an object that does not open is forgotten and
answered `missing`.

**On the device** (`MailCloudPull`), one bulk request of up to 25 at a time, in three tiers: a
conversation being opened (every message of it not here, newest first, at most 8 — and no thread
read when the feed already holds the conversation); the rows on screen and ten ahead in the
scroll direction (`MailSource.onScreen`, debounced 150 ms, replaced as the list scrolls); then,
while Mail is in use or a push's window is open, every message the feed flagged, newest first.
What the cloud lacks comes the per-message way at once for the first two tiers (for an account
on the cloud mailbox that read is itself stored by the cloud); for the fill the flag is cleared
until the feed sets it again. A pull is applied like a per-message read at the cloud's position
(invariant 23), in one index transaction per batch. A `429` backs the account off until its
retry time. An account whose service has no mailbox keeps the per-message fill, now newest
first (`MailSyncFill`, keyset on `(internal_date, msg_pk)`).

**Prepared ahead, too.** Every message pulled is prepared (`MailHTMLPreparer`) as it is stored,
in the same background batch, at utility priority and at the work pace of MAIL-ENGINE invariant
31 (`MailPaceGauge`: paused four times the work on a phone with Mail on screen, stopped when warm
or in Low Power Mode; a push's short window counts as Mail in use, so new mail is prepared
before the next open). A new `MailHTMLPreparer.version` makes every prepared body stale at once:
`MailReprepare` walks the stored originals newest first (`content_by_date`, blobs migration v3),
a piece of 64 at a time, and prepares what is missing or stale at the same pace; an opened
conversation's stale messages are prepared first. An open reads prepared output only; it
prepares on request only when nothing current is stored (counted:
`GmailConversationLoader.preparedOnRequest`). The reader styles each body's blocks off the main
thread as it arrives (`MailAttributedText.blocks`), so drawing builds no attributed text; fonts
are applied by the view, so nothing depends on the pane width. Layout of the text for the width
still happens on the main thread, in SwiftUI.

## 6. Device actions

The outbox is unchanged: shown at once, durable in `intent.sqlite`, delivered through
`/v1/mail/operation` with its operation identity and journal. On success the mailbox queues a
`minimal` read of the message (step 2), so the result carries Gmail's own `historyId` and reaches
the other devices without overwriting newer state. Drafts and sends (`/v1/mail/draft`) ask for a
history poll. Silent pushes to the other devices are a later addition; they poll the feed.

## 7. Turning it off, retention, deletion

- Content of a message Gmail deleted goes with its tombstone; content no device has read for
  90 days is dropped and fetched again on demand.
- **Mail turned off or disconnected** (`DELETE /v1/google/mail`), **the Google account unlinked**
  (`DELETE /v1/google`) or **the Banana account deleted**: the mailbox is wiped at once — its R2
  objects, then its storage — and its D1 row removed.
- **Eligibility or grant lost** (expiry, Google refusing the token): the next step finds it and
  wipes. Turning it back on starts a new mailbox (`epoch`); devices start their feed from zero.
- Device caches are never deleted by any of this; `intent.sqlite` is never touched.

## 8. Fallback

A device uses the feed when `/v1/mail/feed` answers. When the service has no such route
(production today) or refuses the account, the device keeps its existing Gmail-through-passthrough
sync. This is the only fallback, kept because clients may run against a service that has not yet
been upgraded (deploy service first, then clients). Once the feed has answered for an account,
the device does not list or poll history at Google for it.

## 9. Open item for the owner: Google restricted scope

Gmail's `gmail.modify` is a restricted scope. Storing message content on Banana's servers moves
Banana into Google's server-side data-handling requirements: the annual third-party security
assessment (CASA) and the Limited Use disclosures, plus a privacy-policy update saying Banana
Cloud stores mail content encrypted. This does not block the build, which runs only for
accounts with `email` eligibility on staging. It must be settled before production or any wider
release.

## 10. Verification

- Service: `Service/test/mail-mailbox.test.js` (12 tests) covers two devices with one Google
  download per message, archive-after-backfill ordering under a lagging listing, the Inbox head
  before other labels, the Inbox check repairing a skipped listing, catch-up from zero and from a
  cursor (and after the horizon), an action on one device reaching another with Gmail's own
  position, the content miss path and sealed storage, the catch-up check, wipe on Mail off /
  unlink / account deletion / lost eligibility, and pacing (backfill takes no busy slot). The
  full suite passed 424 tests in each of UTC and America/New_York.
- `Service/tools/mailbox-check` passed on local workerd: a real Durable Object with SQLite
  storage and alarms, local D1 with every migration, local R2, the fake Gmail.
- Client: `BananaTests/MailCloudFeedTests.swift` (7 tests, fakes only) covers catch-up from zero
  then the cursor with no Google request, stale entries, deletions through the bulk hold, the
  catch-up check waiting for a complete cloud mailbox, a new epoch or expired cursor, the
  fallback for a service without the feed, and the transport. The Mail engine classes ran
  together: 862 tests, 10 failing methods, none in a file this change touches (timing budgets
  on a host at load average above 100, and four existing source-rule tests). The Mac Beta
  scheme compiles.
- Component gate (Simulator, unchanged budgets): fails its memory comparisons on this branch and
  on the base commit alike. Same host, same hour, peak RSS in MB, branch / base: scale-1d
  363.7, 362.2 / 362.2; scale-7d 401.9, 403.3 / 403.2; scale-30d 482.2, 481.9 / 480.9; scale-90d
  703.3, 702.8 / 703.3; redraw notes 482.3, 482.4 / 482.0; library 485.9, 485.6 / 484.7; plan
  503.6, 505.4 / 504.4; mail 484.0, 484.2 / 484.6. No latency metric over budget. The fixture
  runs no cloud feed, so this shows no regression, not the feed's cost on a device.
- Staging (`banana-service-beta`) runs this service with migration 0022; anonymous checks
  answer 401 on the Mail routes and `/v1/source` names the deployed commit. No mailbox exists
  there yet: one is made by the first client that reads the feed. Production is unchanged.
- Not yet shown: a real mailbox through the feed, devices against staging, push of feed changes,
  and physical-device performance.

## Beta 103 rollout — 6 November

Release source `510dd8f0` (this branch merged into `release/banana-ready` with the mail
preparation and thread-facts speedups). The full Mail engine suite passed on the merged tree:
273 cases, 0 failures (the runner's summary mislabels a run containing a skipped case).
Mac Beta 1.0.4 (103) was signed, notarized and published as the GitHub prerelease
`mac-beta-v1.0.4-103`; the Beta update feed and download redirect name build 103. iOS Beta
103 was installed and launched on the owner's phone and iPad. These clients now use the
staging shared mailbox feed; real-mailbox acceptance is in progress, not yet claimed.

## 11. Snooze wakes in the cloud mailbox

Built on branch `mail/snooze`, not deployed. [MAIL-ENGINE](MAIL-ENGINE.md) §8 had whichever
device was awake wake a snooze. The mailbox now owns the wake, so a snoozed conversation returns
on time in Gmail with every device asleep. Devices may still wake overdue snoozes: each change is
a desired end state, so two wakes make one change.

- **Labels.** `/v1/mail/operation` takes `{email, action: "createLabel", name, operationID}` for
  `Banana/Snoozed/<yyyyMMdd'T'HHmm'Z'>`, `Banana/Returned` and `Banana/Muted` only. It answers
  Gmail's label (`id`, `name`, …). A label that already has the name is the answer, so a second
  device gets the same id. New labels are created with `labelHide`/`hide`. The mailbox keeps label
  names (table `label`), from the handshake, from each createLabel, and from a reread of the
  labels. That reread runs when a `modify` added an id it cannot name, and with every Inbox check.
- **Schedule.** Every conversation with a Banana label on a live message has a `snooze` row,
  updated after each write to its labels: due at its latest Snoozed time (rule 1); a minute after
  it was first seen when a reply or a Gmail move brought it back early (rule 2), when it left the
  Inbox after returning (rule 5), or when every snoozed message is in the bin; none once it has
  returned and stays in the Inbox. The minute is for a device still delivering a snooze one
  message at a time, which for a moment reads as "came back early".
- **The wake** (`src/mailbox.js`, after the device-action reads and the history poll): for each
  due conversation, a fresh `threads.get` (minimal, paced), then `src/mail-snooze.js` on what Gmail
  says now, then one `modify` per message: `INBOX`, `UNREAD` and `Returned` on the last message
  that is not a draft, first; then `Returned` on the other snoozed messages. `Banana/Returned` is
  created first when needed. Writes take 5 units of the identity's pacing each. Each changed
  message is read back like a device action, so the feed carries Gmail's `historyId`. One silent
  push (`b.k = "mail"`) follows each step that woke a conversation.
- **Alarm.** Each run sets the alarm to the sooner of its next step and the earliest due wake,
  and stores that wake in D1 (`mail_mailboxes.wake_at`, migration 0024). The quarter-hour job sets
  the alarm again for every mailbox with a `wake_at`, at that time, as well as for every mailbox a
  device read this week. A conversation whose change keeps failing waits 1, 2, 4… minutes, up to
  an hour, between tries. A read-only grant wakes nothing. Losing the Email feature or the grant
  wipes the mailbox before anything is woken.
- **Verification.** `Service/test/mail-snooze.test.js` (13 tests, fake Gmail): the label names and
  rules; createLabel (made once and hidden, a lost race, other names refused); a wake with no device
  reading; two snoozes in order; a conversation a device already woke; one write per message;
  restart and the job's re-arm; the Email feature or grant lost before the wake; a reply during
  the snooze; an archive after the wake; failing writes backing off; a snooze half delivered. The full service suite passed
  438 tests in both UTC and America/New_York. `tools/mailbox-check` passed on local workerd with
  migration 0024 (the Worker bundle with the new modules loads; its checks do not snooze). Not
  shown: a real Gmail account (probe W5).
