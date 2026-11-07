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

Steps 1–6 use the existing pacing reservation and may wait up to ten seconds. Backfill asks for
a **background** reservation: it only takes a slot that is free *now*, so a device's
content request is never queued behind backfill; otherwise the alarm is set for when the slot
frees. Pacing stays per Google identity in D1, shared by the passthrough, the content path and
the worker (4,500 units a minute).

While a device has read the feed in the last two minutes, history is polled at most every
ten seconds and any feed request asks for a poll if the last one is older than that; otherwise
every five minutes, which keeps the checkpoint inside Gmail's history retention.

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
