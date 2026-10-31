# Data-safety audit of `docs/design/MAIL-ENGINE.md` (5 Oct 2026 draft)

Adversarial read of the engine design against the dossier `research/gmail-api.md`, `MAIL-UX.md`
§3 and §7, and the calendar's `GoogleEventSync`, `PendingCalendarWrites`,
`PendingCalendarWriteRules`, `CalendarWriteBackPolicy` (`BlockRemovalGate`, `MassRemovalGuard`)
and `Shared/SnapshotPersistence.swift`. Line numbers are into MAIL-ENGINE.md as read today.
Spike source and output: `review/safety-spikes/crash_between_commits.c`, `output.txt`
(system SQLite 3.51.0; two runs, under a second of CPU each).

Counts: **4 BLOCKER · 16 MAJOR · 16 MINOR**, then safe scenarios, invariants, probes, fake-Gmail
injections, and open questions.

The one-sentence pattern behind most of the blockers and majors: the design's invariants are
written for *removal of mail*, and they hold there; the same "absence is not evidence" rule is not
applied to the outbox's moot check, to label listings, to the disk, or to timed assertions.

---

## Blockers

### S-1 · BLOCKER · The moot check treats "no label row" as "Gmail has no such label" and drops offline archives after any cache rebuild

- **Scenario:**
  1. Phone offline. He archives 30 conversations and marks 20 read (`INBOX` absent ×30, `UNREAD` absent ×20 committed to `intent.sqlite`).
  2. Before it is online again, `index.sqlite` is rebuilt: a `quick_check` after an unclean exit finds corruption (4.10), or he chooses "Remove downloaded mail from this device" (3.6), or the schema is downgraded (4.9). `checkpoint = NULL`; reconcile starts; message rows are recreated from blobs (no labels) or from listings (stubs, no `message_label` rows until the Apply step — 5.3 step 3 writes stubs, step 4 writes memberships).
  3. The outbox driver is kicked "on coming to the foreground" and "after every sync pass" (6.6). Step 2 of delivery (6.5): "Drop moot rows", using `OutboxRules.isMoot(want: Bool, gmailHas: Bool)` (6.1 line 1408) where `gmailHas` is read from `message_label`.
  4. For every one of the 50 messages, `message_label` has no row → `gmailHas = false`. `isMoot(want: false, gmailHas: false)` is true. The 50 assertions are deleted as "already agreed".
  5. Reconcile's Apply later adds the `INBOX` and `UNREAD` memberships that Gmail actually has. The 50 conversations are back in the inbox, unread, on every device. Nothing was sent; nothing is in the outbox; nothing is reported.
- **What the design says:** 6.1 line 1407–1408 (`isMoot` with a non-optional `gmailHas`); 6.5 step 2 line 1481 ("Drop moot rows"); 6.4 line 1465–1467 covers only the *overlay* for a message not yet in the index ("waits in memory"), not delivery; whether the driver drains while `checkpoint` is NULL is unspecified (6.5 line 1474–1475 says it drains "after that account's incremental pass"; there is no incremental pass without a checkpoint).
- **Outcome:** Intent lost silently — the exact failure invariants 4 and 6 exist to prevent — in the shape of the calendar incident: a read that says nothing is taken as "nothing there".
- **Evidence:** 4.3 line 546–549: `message_label` is "Gmail's label state, as last told"; a stub has none. 5.3 step 3 vs step 4: memberships are written only "when every listing reached its last page". 4.9 line 939–941: rows rebuilt from blobs carry "everything but labels".
- **Smallest change that closes it:** `isMoot(want:gmailHas: Bool?)`; `nil` (no message row, a stub with `fetch_state = 0`, a message with no fetched label set and no completed enumeration since it was listed) is never moot. Delivery of such rows is unconditional: a 2xx or a 404 is the positive statement Gmail makes; 5 units each. State this under invariant 6.

### S-2 · BLOCKER · A full disk makes every action show and then vanish, and the fill is what fills the disk

- **Scenario:**
  1. iPhone with 3 GB free. D3's ceilings are on cache *size* (4 GB bodies + 2 GB attachments), not on free space (section 11, lines 2211–2216). The overnight fill (12.2) and attachment prefetch run until the ceiling or the disk, whichever comes first. The disk comes first.
  2. He opens Mail and triages: 20 `E` presses. Each is accepted on the main thread, applied to the feed, and handed to `mail.writer` (13.1 lines 2400–2403: "returns before any I/O").
  3. The intent commit fails with `SQLITE_FULL` (the WAL needs a page). `MailIntentStore` throws. Nothing in the design says what the writer does with a command whose intent commit failed: `perform` has already returned a receipt; the feed shows the rows gone; `first-page.json` (4.11) is written from the feed two seconds later.
  4. He puts the phone down. Relaunch: the overlay is rebuilt from `intent.sqlite` — empty. The 20 conversations are back. Or, worse, the snapshot draws them gone until the first real page replaces it.
- **What the design says:** unspecified. 4.10 covers corruption; 11 covers eviction by LRU; nothing covers `SQLITE_FULL`, `ENOSPC` on `Intent/Attachments/`, or a free-space floor. Invariant 4 ("Intent is written before it is shown") is already contradicted by 13.1 (shown first); with a failed write it is false forever.
- **Outcome:** Intent lost silently; "a change that shows, then silently never reaches Gmail" (invariant 4's own words).
- **Evidence:** `PendingCalendarWriteStore.save()` (lines 85–92) at least logs a failed save; the mail design has no equivalent for its most precious file.
- **Smallest change that closes it:** (1) A free-space floor: the fill, prefetch and indexer stop and evict when free space is under 1 GB (iPhone/iPad) or 5 GB (Mac); `MailProgress` says "waiting for space". (2) A failed intent commit is a first-class outcome: the command stays in the in-memory accepted list, the feed reverts the rows at rest, `MailEvent.refused(receipt, code: "diskFull")` fires, `MailStatus.store = .unavailable(.diskFull)`, and `perform` returns `count 0` while the store is in that state. Add to invariant 4.

### S-3 · BLOCKER · A `labels` response that is short removes every label and every membership locally

- **Scenario:**
  1. Handshake (5.3 step 1): "A label missing from a complete `labels` response is removed locally, with its memberships and view."
  2. The response is a 200 whose `labels` array is empty or short. Three ways: a `fields=` mask typo in `GmailHTTPClient` (P22 uses `fields` for the probe; `GmailWire` makes "every field optional", so a missing `labels` key decodes as nil, and nil → `[]` is one careless line away); a Google-side partial; a proxy or captive portal returning a well-formed but wrong 200.
  3. The engine removes `INBOX`, `UNREAD`, `SENT`, every user label and every `Banana/…` label from `label`, deletes their `message_label` rows and `view_thread` rows.
  4. Every list is empty. "Inbox clear." (MAIL-UX 7.8). Pending intents referencing those label ids are still fine, but assertions by name (`name:Banana/Snoozed/…`) now re-create labels.
  5. Recovery: the label rows return at the next `labels` call — which is the next handshake, i.e. the next reconcile (weekly, or on history 404). Memberships return only through a reconcile's listings. The drift check (5.8) re-lists `INBOX` after two disagreeing checks six hours apart; the other labels wait up to a week.
- **What the design says:** 5.3 line 1133–1135; 5.7 table line 1307 ("A complete `labels` response without the label → Remove the label"). "Complete" is not defined. Invariant 3 counts removed *messages*, not removed memberships, so it does not fire.
- **Outcome:** State that is not true on one device for up to a week; deletion on absent evidence — the 291-busy-blocks shape (`vanishedCalendars` in `CalendarWriteBackPolicy.swift` lines 193–197 guards this exact case for calendars: "Only a complete list can say that").
- **Evidence:** Dossier §4.1: system labels always exist; a response without `INBOX` cannot be complete.
- **Smallest change that closes it:** A `labels` response counts as complete only if it contains every system label the account has been seen with (at least `INBOX`, `SENT`, `DRAFT`, `TRASH`, `SPAM`, `UNREAD`); otherwise it is treated as a failed call. Extend invariant 3 to memberships: a handshake that would remove more than a third of an account's label memberships is held like a message removal.

### S-4 · BLOCKER · Mac: ⌘Q inside the undo-send window leaves the message unsent with nothing to say so

- **Scenario:**
  1. On the Mac he presses Send on a reply. State `held(until: now + 10 s)` (7.5). Toast "Sending · Undo".
  2. He presses ⌘Q within the window (or closes the lid and the Mac sleeps — the hold timer is "foreground only", 6.6).
  3. 7.5 says the window ends on "Mac quit" and "the send runs under a background assertion (`beginBackgroundTask`)". macOS has no `beginBackgroundTask`; the design does not say quit is delayed. The process ends with the row `held`.
  4. 7.5's safety net — "On iOS a local notification is scheduled for ten minutes later" — is iOS-only. Nothing fires on the Mac.
  5. Monday: he launches Banana. S6: 60 hours late > `askIfLateBy` 24 h → `needsDecision(.late)`. The reply he believed went out Friday evening did not, and he learns it on Monday.
- **What the design says:** 7.5 lines 1734–1740 (iOS mechanism named; Mac named but no mechanism); 7.4 S6 lines 1699–1704; 7.6 line 1780–1781 names the Mac's expectation ("sends within its poll interval (a minute)") only for a Mac that is awake.
- **Outcome:** A message he pressed Send on silently fails to send until relaunch; "never left unsent without telling him" (7.5) does not hold on the Mac.
- **Evidence:** 7.5 line 1738: "On iOS a local notification is scheduled".
- **Smallest change that closes it:** On macOS, `applicationShouldTerminate` returns `.terminateLater` while any draft is `held`, `uploading`, `ready` or `sending`; the hold ends at once and the send is given 30 s, then `reply(toApplicationShouldTerminate: true)`. On sleep, the same (`NSWorkspace.willSleepNotification`: end the hold, send under `ProcessInfo.performExpiringActivity`). Schedule the same ten-minute "still waiting to send" notification on macOS (`UNUserNotificationCenter` works there).

---

## Major

### S-5 · MAJOR · The 2xx handler marks "the row" settling and clobbers an undo accepted while the request was on the wire

- **Scenario:**
  1. He archives conversation C: `(a, m1, INBOX, want 0, seq 5)` → pending. The driver marks it in flight and sends `modify`.
  2. Within the round trip he presses Undo. 6.3: "a second assertion for the same key overwrites the first with a higher seq" → the same primary key now reads `want 1, seq 6, state pending`.
  3. The archive's 2xx arrives. 6.5 step 4: "on success apply to `message_label` and mark settling". The handler updates by primary key → the row is now `want 1, seq 6, state settling`.
  4. Settling ends after its echo or ten minutes; the row is deleted. The undo was never sent. Gmail has the archive. The device showed C in the inbox (overlay `want 1`) for up to ten minutes, then C disappears.
- **What the design says:** 6.2 diagram and text lines 1414–1437; 6.3 lines 1441–1444; 6.5 step 4 line 1490. Unspecified: that the settling mark is keyed by the `seq` that was sent.
- **Outcome:** A person's undo silently lost, and a row that first shows the undo then reverts.
- **Evidence:** Spike mode 2 (`output.txt`): primary-key-only update → `want=1 seq=6 state=2 (settling)`; `AND seq=5` → the undo stays pending.
- **Smallest change that closes it:** The in-flight mark records `seq`; the 2xx and 404 handlers update `WHERE … AND seq = ?sent`. A row whose `seq` moved on stays pending. The overlay rule already copes.

### S-6 · MAJOR · A fetch response that lands after a newer history record overwrites the newer label state

- **Scenario:**
  1. Fill (5.6) requests a batch of 20 `messages.get` (full) including M, which the index holds as a stub. Two requests per account may be in flight (5.2); a batch takes 1–3 s.
  2. Meanwhile the poll applies a history page: record 120 `labelsRemoved INBOX` on M (archived on the web). `message_label` for M loses `INBOX`; `history_id` stays whatever the stub had (NULL).
  3. The fetch response arrives. It was served before record 120: `labelIds` contains `INBOX`, `historyId = 100`. 5.6: "A message's label set from a fetch replaces what was stored… a positive statement about that message." The writer sets M's labels to `{INBOX, …}`.
  4. M is in this device's inbox; it is archived at Gmail. No history record will ever repeat 120. The drift check (5.8) compares inbox *counts* only when "no overlay touches the inbox", and only re-lists after two disagreements ≥ 10 min apart; the weekly reconcile queues M for a per-message read because it has `INBOX` locally and no mark. Until then, up to a week, M sits in the inbox on this device.
- **What the design says:** 5.5 lines 1235–1237 guard *records* against a *newer fetch* ("unless the record's id is not greater than the message's stored `history_id`"). The reverse — a fetch older than the stored `history_id` — is not guarded. 5.6 line 1294–1295 makes the fetch unconditional. 5.5 line 1249–1251 even allows `historyId` to be absent from the fetch, in which case no guard is possible.
- **Outcome:** State that is not true, for up to a week, and it will happen routinely while the fill runs beside the poll (days, on a phone).
- **Smallest change that closes it:** When storing a fetched message, if the stored `history_id` is greater than the fetch's `historyId`, keep the stored label set and store only content. If the fetch carries no `historyId`, treat its labels as a *fallback* for a message that has none, never as a replacement. Add an invariant (see list).

### S-7 · MAJOR · `due` runs on stale state before the network, and its assertions are delivered after the sync without being re-derived

- **Scenario A (snooze):**
  1. C is snoozed until 08:00. The phone wakes it at 08:00 (BGTask): `INBOX` + `Returned` on the last message. He reads it on the phone and archives it in Gmail's app at 08:05 (`INBOX` removed; `Returned` stays).
  2. The Mac, asleep since 07:00, wakes at 09:00. 8.3: `due` runs "at launch and on coming to the foreground, *before* the network". Its local facts: `Snoozed/08:00`, no `Returned`, no `INBOX` → rule 1 → it enqueues `INBOX present` + `Returned present` on the last message. The overlay shows C in the inbox at once.
  3. The sync pass runs: `labelsAdded Returned`, `labelsAdded INBOX`, `labelsRemoved INBOX`. `message_label` now says: `Returned`, no `INBOX`.
  4. Delivery (6.5): moot check — Gmail has no `INBOX` on that message; the assertion says present → not moot → sent. C is back in the inbox on every device and in Gmail's apps, with `Returned` and (D10) `UNREAD`.
- **Scenario B (reminder):**
  1. "Remind me if no reply by Friday 17:00" on a sent message S. The reply R arrives Thursday.
  2. The iPad has been offline since Wednesday. Friday 17:30 he opens it. `due` before the network: `Waiting/Fri17:00`, t ≤ now, no reply known, no `Returned` → rule 4 → `INBOX` + `Returned` on S. Notification "No reply yet?" (MAIL-UX 7.10 hedges the title "because the device cannot know for certain at the moment it rings" — the UX author saw this).
  3. Sync brings R. Delivery: S has no `INBOX` at Gmail → the assertion is sent. The conversation now carries `Returned` on S and shows "Back: no reply" everywhere, although a reply exists. Rule 3 then clears `Waiting`; `Returned` stays until he archives.
- **What the design says:** 8.3 lines 1873–1876 (before the network, on purpose); 8.2 lines 1856–1862 argues `Returned` prevents a double wake, which is true only when every device has seen `Returned`; 6.8 lines 1546–1555 accepts last-writer-wins for *his* actions — these are not his actions.
- **Outcome:** Conversations he has dealt with reappear in the inbox; a false "no reply" return. Visible, undoable, and frequent with three devices and a Mac that sleeps.
- **Smallest change that closes it:** Assertions produced by `due` are tagged `origin = timed`. Before delivery — after the sync pass — the driver re-runs `due` on the fresh facts of the conversations those assertions name and drops any timed assertion the fresh run does not produce. The overlay still shows the optimistic wake offline; online, nothing stale is sent. Add an invariant.

### S-8 · MAJOR · A lost answer to `drafts.send` on a *new* message cannot be verified: there is no thread to read

- **Scenario:**
  1. New message (not a reply): `thread_id` is NULL in `draft` (4.8) — Gmail assigns the thread on send.
  2. `sendDraft` reaches Gmail; the mail goes; the response is lost (`timedOut(requestMayHaveArrived: true)`). State `verifying`.
  3. S4 step 1: `draft(id)` → 404 (gone). Step 2: "`getThreads([threadID], format: .header)` and look for a message with `SENT`" — `threadID` is unknown.
  4. Steps 3–4: not found three times → `needsDecision(.unconfirmed)`: "Banana can't confirm this was sent." Buttons *Open Sent · Send again · Keep as a draft*.
  5. He presses *Send again*. The recipient gets it twice.
- **What the design says:** 7.4 S4 lines 1686–1696 reads only the thread. Dossier §6.3 line 445 names the alternative (`messages.list labelIds=SENT q=rfc822msgid:` or a time bound). The design's R6 fallback ("also matches by conversation, time and recipients") is not designed.
- **Outcome:** A false "not sent", with a human-driven double send as the natural next step. The brief's exact question.
- **Smallest change that closes it:** S4 step 2 for a new message: `listMessages(labelIDs: [SENT], query: "rfc822msgid:<id>")` (5 units); if that operator is refused, `listMessages(labelIDs: [SENT], query: "after:<mime_date − 1 h> to:<first recipient>", maxResults: 20)` and `getMessages(.header)` to compare `Message-ID`, `X-Google-Original-Message-ID`, then `To`+`Subject`+`Date` within a minute. Also: while in `needsDecision(.unconfirmed)`, every later sync pass that stores a `SENT` message whose `rfc_message_id` matches retires the question to `sent` (the index already has `message_by_rfc_id`).

### S-9 · MAJOR · After a lost answer, one `drafts.get` that still finds the draft is taken as "not sent" and the send is retried

- **Scenario:**
  1. `sendDraft` succeeds at Gmail; the answer is lost. State `verifying`.
  2. S4 step 1 within a second: `draft(id, .minimal)` → 200, still there (the deletion that "automatically" follows a send is visible with some lag; dossier §14.25: no read-after-write guarantee, 2–5 s reported by third parties, UNVERIFIED).
  3. Design: "Still there → it was not sent → `ready`, retry with backoff." The driver sends `sendDraft(id)` again.
  4. If Gmail has by now deleted the draft: 404 → `verifying` → found in Sent → `sent`. One message. If Gmail's deletion is lagging *and* the draft is still sendable (R4's wrong way): two messages.
- **What the design says:** 7.4 S4 step 1 line 1687; R4 ("Any answer but success goes to verifying") — but a second *success* is the double send. The whole at-most-once argument rests on "the same draft cannot go twice" (1.summary line 40), which is an INFERENCE in the dossier (§5.2 line 374: "A 404 on replay is INFERENCE").
- **Outcome:** Possible double send through the engine's own retry, not a person's.
- **Smallest change that closes it:** Verification order: look in `SENT` first (S-8's read); only if absent, read the draft; require it present on two reads at least five seconds apart before returning to `ready` — the calendar's two-pass rule (`BlockRemovalGate`). Add to invariant 7: "`drafts.send` is retried on the same id only after the draft has been read present twice and the sent copy has been looked for and not found."

### S-10 · MAJOR · A scheduled send is orphaned by any wipe, restore or reinstall of its owner, and no other device ever says so

- **Scenario:**
  1. On the iPhone he schedules a message for Tuesday 08:00. The draft is uploaded with `X-Banana-Send-Owner: <device_id>`; the row is `scheduled` in the phone's `intent.sqlite`; `device_id` lives in that file's `meta` (4.8).
  2. Monday the phone is replaced (or restored from backup, or Banana is deleted and reinstalled). `BananaMail/` is excluded from backup (4.1) — correctly for intent, but the `device_id` goes with it. The new phone mints a new id.
  3. Tuesday 08:00: no device owns the draft. The owner's five-minute "hasn't gone yet" notification (7.6) was scheduled on the old phone. The Mac and iPad show "Scheduled for Tue 8:00 from the owner's iPhone" in Outbox — if he opens Outbox.
  4. Nothing else happens, ever. The janitor (8.2) touches labels, not drafts.
- **What the design says:** 7.6 lines 1752–1783; "Taking over" is a manual action on another device; no rule for a draft whose `X-Banana-Send-At` is past and whose owner is absent. MAIL-UX 7.7 alerts are owner-side ("this Mac was asleep").
- **Outcome:** A message he scheduled silently never goes. Every phone replacement produces this.
- **Smallest change that closes it:** Any device that syncs a `DRAFT` carrying `X-Banana-Send-At` more than five minutes past and an owner that is not itself raises `MailEvent.scheduledOverdue(elsewhere)`; MAIL-UX's alert card: "“Q3 numbers” was due Tue 8:00 from the owner's iPhone and hasn't gone. Send from here?" (take-over as designed). Also schedule the +5 min local notification on *every* device that knows of the schedule, as 8.3 already does for wakes.

### S-11 · MAJOR · Editing a scheduled draft on a non-owner device silently cancels the schedule

- **Scenario:**
  1. Mac schedules draft D for Tuesday 08:00 (headers on the Gmail draft).
  2. Monday on the iPhone he opens D from Drafts, fixes a typo, closes. The phone's row has no `send_at`/`owner_device`; `MIMEBuilder` puts "nothing Banana-specific" in the message (7.2); `updateDraft` uploads a new message id without the two headers.
  3. The phone's composer no longer shows "Scheduled" (the headers are gone). He assumes the typo fix was harmless.
  4. Tuesday 08:00, the Mac: "its message id must be the one this device uploaded" fails → `needsDecision(.changedElsewhere)` — if the Mac is awake. If it is asleep until Wednesday, the question waits until then. No device sends.
- **What the design says:** 7.6 line 1767–1769: "Cancelling or editing from another device means changing the draft in Gmail — the owner's check then fails safe." Fail-safe is the right direction; silence is the problem. R5 says "If it drops them, other devices see an ordinary draft and nothing else changes" — but a non-owner *edit* always drops them.
- **Outcome:** A scheduled message silently not sent; the person who caused it (on the phone) is not told.
- **Smallest change that closes it:** A non-owner opening a draft that carries the two headers must choose before editing: "Scheduled for Tue 8:00 from the owner's Mac · Edit and keep the schedule (send from here) · Edit and cancel the schedule". Either way the phone's upload preserves or deliberately strips the headers and records what it did in its own Outbox. Pair with S-10's overdue alert as the backstop.

### S-12 · MAJOR · Invariant 3's "pass" is undefined for the verify queue; fifty-at-a-time batches never trip it

- **Scenario:**
  1. A reconcile's Apply queues 60,000 messages for verification (a listing that ended early without a token — R18 — or S-3's empty labels, or a mailbox genuinely emptied).
  2. 5.3 step 5: verify in batches of 50 (backfill lane). A 404 "removes the message — subject to invariant 3".
  3. If the pass is the batch: 50 removals against 100,000 cached is not "more than a third". Every batch passes. 60,000 messages are removed one batch at a time over the day.
  4. If instead the hold were computed per batch against what is *left*, it would still never trigger until the cache is small.
- **What the design says:** Invariant 3 lines 70–72 ("A pass that would remove…"); 5.3 step 5 line 1153–1155; `ReconcileRules.removalAllowed(removing:cachedInAccount:)` line 1177. "Pass" is defined nowhere for verify.
- **Outcome:** The guard that is the point of invariant 3 can be bypassed by batching, which is how the design delivers removals.
- **Smallest change that closes it:** Define the pass as the whole of one reconcile's verify outcome: 404s are *accumulated* (a `verify_outcome` column) and applied only when the queue is drained, through `removalAllowed(removing: all404s, cachedInAccount:)`. For incremental passes, keep a rolling 24-hour count of removals per account and hold when the rolling total crosses the threshold.

### S-13 · MAJOR · The mass-removal hold has no way to resolve that keeps sync alive

- **Scenario:**
  1. He empties Trash and permanently deletes 45,000 promotional messages on the web (a third of the mailbox). History carries `messagesDeleted` ×45,000.
  2. The pass is held (`.held(removals: 45000)`): "nothing is removed until the person says so."
  3. What happens to the checkpoint? If it does not move, the next poll replays the same pages and is held again; new mail in the same history window is or is not applied (unspecified); on the phone, the question is an alert card he may not see for hours.
  4. He taps "Keep for now" (MAIL-UX 7.5). Now: the deletions are "kept", but the checkpoint still cannot pass them, or if it does, the rows are kept forever as mail Gmail has deleted, and the next reconcile's verify 404s them all → held again → asked again.
- **What the design says:** invariant 3; 5.5 line 1233–1234 ("invariant 3 still applies to the pass as a whole"); 14 table line 2658. Unspecified: checkpoint movement while held; the meaning of "keep"; whether other records in a held pass are applied.
- **Outcome:** Either new mail stops arriving on that device until he answers, or he is asked the same question at every reconcile. Both are "state that is not true" in normal use (a 30-day trash purge of a big mailbox is routine).
- **Smallest change that closes it:** A held pass applies everything *except* the removals, moves the checkpoint, and records the held ids in a `held_removal` table (index) with the evidence kind. "Remove here" deletes them; "Keep for now" marks them `gmailSaysGone = 1`: they are shown with that mark, excluded from counts, not re-asked, and dropped silently by a later reconcile that also fails to list them. `MassRemovalGuard` in the calendar has the same open end; do not copy it.

### S-14 · MAJOR · "HTTP 404 for that message id" needs to mean the inner part status with a parsed body, never an outer or transport 404

- **Scenario:**
  1. The verify step (5.3 step 5) or the body fill sends an HTTP batch of 20 `messages.get`.
  2. The *outer* response is 404 (the dossier's own probe found `https://www.googleapis.com/batch` returns 404; a Google front end, a proxy or a captive portal can do the same), or each part is a 404 HTML page from an intermediary with no JSON body.
  3. `GmailErrorMapping` maps 404 → `GmailError.notFound` per id. 5.7: "404 for that id, from a token verified as this account's → Delete, if it was stored". Twenty stored messages are deleted. Repeat per batch (S-12) under the threshold.
- **What the design says:** invariant 1 line 62–63 ("HTTP 404 for that message id from the account it belongs to"); 5.7 line 1304. Unspecified: inner vs outer; body parsing.
- **Outcome:** Deletion on absent evidence.
- **Evidence:** Dossier §8 line 498 (batch URL 404), §9.3 line 569 (404 reason string UNVERIFIED).
- **Smallest change that closes it:** Reword invariant 1: a 404 counts only when it is the status of the *inner* part (or of a single-call response) for a request naming exactly that id, with a JSON error body whose `reason` is `notFound` (or whatever the probe shows). Any other 404 is `GmailError.server`-class: nothing is removed.

### S-15 · MAJOR · A reply's threading headers are read from the original when the MIME is built, so a reply whose original is gone can never be built

- **Scenario:**
  1. He drafts a reply to M on the iPad, offline (`source_msg_id`, `thread_id` stored; 4.8 `draft` has no `in_reply_to`/`references` columns).
  2. Before it is sent: he turns Mail off for that account and chooses "Remove downloaded mail" (3.6 — "unsent messages… stay queued"), or M's body and headers are gone because M was deleted elsewhere (`messagesDeleted` → "delete… its content", 5.5), or `blobs.sqlite` is renamed aside after corruption (4.10).
  3. He turns Mail on / the send is due. `MIMEBuilder` needs `In-Reply-To`/`References` "read from the original when the MIME is built" (13.1 line 2416–2417). There is no original. The upload cannot happen. The state stays `uploading` (or whatever the implementer chooses); the message says "Waiting to send" indefinitely, or goes out un-threaded.
- **What the design says:** 13.1 line 2415–2417; 4.8 draft schema lines 888–903; 7.2 `ReplyRules.threading(parentHeaders:)` line 1601.
- **Outcome:** A send that silently never happens (or threads wrongly) after a flow the design explicitly promises ("turning Mail on again delivers them").
- **Smallest change that closes it:** Capture `In-Reply-To` and `References` (and the parent's `Message-ID`, `Subject`) into the `draft` row at `newDraft` — the original is on the device at that moment because he is reading it. The MIME never needs the blob again.

### S-16 · MAJOR · After a power loss the index can say "body here" for a message whose blob commit was lost, and nothing ever re-fetches it

- **Scenario:**
  1. Fill writes a batch: "content to `blobs.sqlite` first, then one index transaction" (5.6 line 1291–1293). Both files are `synchronous=NORMAL` (4.2 line 446–447): in WAL mode a committed transaction "might roll back following a power loss" (SQLite `PRAGMA synchronous` docs). Which file's WAL frames reach the platter first is the OS's choice.
  2. The phone dies (battery) during an overnight fill. On reboot the index WAL is intact (`fetch_state = 2`, `fts_dirty = 1`), the blobs WAL lost its last frames: no `content` row.
  3. He opens the message: `reader.content` finds nothing. The message is not in `message_body_queue` (that is `fetch_state = 1`). The indexer reads no text, writes an empty FTS row, clears `fts_dirty`. The message shows no body and is unsearchable, permanently, until a `derived_version` rebuild happens to notice.
  4. The same ordering hazard in eviction (section 11): if blobs drops the body first and the index's `fetch_state` update is lost, same result. The design does not state the eviction order.
- **What the design says:** 4.2 line 433–436 chooses the order only for intent→index; 5.6 covers only the crash *between* the two writes in the "blob without index row" direction; 4.10 covers whole-file corruption, not a missing row. Unspecified for a missing blob row.
- **Outcome:** State that is not true ("body here"), a body never re-fetched, search silently incomplete.
- **Smallest change that closes it:** (1) `body()` on a missing or level-1 blob row for a `fetch_state = 2` message sets it back to 1 and queues it (self-heal on read); the indexer does the same instead of indexing nothing. (2) Eviction: index first (`fetch_state 2 → 1`), then blobs. (3) The post-unclean-exit `quick_check` pass also runs `SELECT … FROM message WHERE fetch_state = 2` anti-joined against `content` over the attached blobs file and repairs the difference (one pass, cheap on the partial index).

### S-17 · MAJOR · With `checkpoint = NULL` there is no incremental sync, so a phone enumerating over days shows no new mail and may never keep a checkpoint

- **Scenario:**
  1. iPhone, first sync, or a history 404 on a full cache. Head fetches 50 inbox conversations; enumeration (backfill lane) begins: ≈ 800 pages for 100,000 messages, ≈ 50 s of budget — if the app stays open. He opens Banana for 20 s at a time; the fill task runs overnight "on power and Wi-Fi" only.
  2. 5.5: incremental sync runs "for each connected account with a checkpoint". There is none. Head runs "only when the inbox view has no dated rows" — it has 50 now. So on the second, third, fourth opening, **no new mail arrives**; the inbox is as of the first opening until the enumeration completes.
  3. Enumeration completes after three days. Apply sets `checkpoint = enum_checkpoint` taken on day one. `history(start:)` → 404 ("typically valid for at least a week… in some rare circumstances may be valid for only a few hours", dossier §1.3). `checkpoint = NULL`; reconcile again. On a phone used lightly this can repeat.
- **What the design says:** 5.3 step 1 (checkpoint taken before listing — right); 5.5 line 1208; 5.4 ("An iPhone fills in only while Banana is open") describes the fill, not the enumeration; nothing says the poll runs during an enumeration.
- **Outcome:** Stale inbox for days on the device he carries; a possible reconcile loop; outbox delivery is sequenced "after that account's incremental pass" and so may also stall (see S-1).
- **Smallest change that closes it:** While `enum_checkpoint` is set and `checkpoint` is NULL, poll `history(start: enum_checkpoint)` as usual and apply it (additions and label changes are state-based; the Apply step's "known before" set is unaffected). If that poll 404s mid-enumeration, re-take `enum_checkpoint` from `profile` and continue the listing (a later checkpoint only means the listing itself is now the evidence for the gap, which is what "add but never remove" already assumes). Delivery never waits for a checkpoint.

### S-18 · MAJOR · Re-creating a draft after a 404 checks the *local* index for the sent copy, so a message sent elsewhere can be sent again with the same `Message-ID`

- **Scenario:**
  1. Draft D (Message-ID X) is open on the Mac (row `editing`, `gmail_draft_id = D`) and on the phone.
  2. The phone sends D. Gmail deletes D, creates S (SENT, Message-ID X).
  3. The Mac has been offline. He opens the draft on the Mac, adds a line, presses Send. `held` → the driver uploads: `updateDraft(D)` → 404. 7.3: "Its next save gets a 404 and creates a new draft — unless a message with the same `Message-ID` is in Sent". The Mac's index does not have S yet (it has not synced, or the pass fetched at most 30 messages, or S is a stub). `createDraft` → D2 with Message-ID X. `sendDraft(D2)` → sent.
  4. The recipient has two messages with the same `Message-ID`; some clients collapse them, some show both.
- **What the design says:** 7.3 lines 1634–1637; 7.4 "Two devices" lines 1711–1714 (the retire path is "the other's next save"). Unspecified: whether "in Sent" is the local index or Gmail.
- **Outcome:** Double send across devices without a same-second race.
- **Smallest change that closes it:** Before any `createDraft` for a row that has ever had a `gmail_draft_id`, ask Gmail: `listMessages(labelIDs: [SENT], query: "rfc822msgid:<X>")` (5 units; fallback as in S-8). Found → retire as "Sent from another device"; the new text becomes a *new* draft with a *new* `rfc_message_id`.

### S-19 · MAJOR · A `batchModify` with one dead id that answers 400 marks the whole batch refused

- **Scenario:**
  1. A held `E` over 40 conversations → one `batchModify` of 120 ids (6.5 step 3).
  2. One id was permanently deleted elsewhere an hour ago. Gmail's answer for a bad id inside `batchModify` is UNVERIFIED (dossier "Could not verify" #5); 400 `invalidArgument` is at least as likely as 404.
  3. 6.5's table: "400, or a 403 that is not a limit → failed". All 120 assertions go to `failed`; 40 rows show "Couldn't apply · Done"; the toast says Gmail refused it; the overlay drops and the 40 conversations flash back into the inbox.
- **What the design says:** 6.5 line 1508 handles only a 404 on a batch ("falls back to per-message calls"); line 1510 makes any other 4xx final.
- **Outcome:** Forty correct actions shown as refused; the person must retry by hand.
- **Smallest change that closes it:** Any non-limit 4xx on a *batch* request (HTTP batch or `batchModify`) falls back to per-message `modify` before any row is marked failed; only a per-message 4xx is final.

### S-20 · MAJOR · A crash between `drafts.create`'s 2xx and storing the draft id creates a duplicate unless the search-before-create is unconditional

- **Scenario:**
  1. First upload of draft X: `createDraft` → 2xx with id D. Before `gmail_draft_id = D` is committed, the process dies (jetsam, a crash elsewhere).
  2. Relaunch: the row is `uploading` with no draft id. 7.3: "A create whose answer was lost… Before creating again the driver looks for its own draft" — but the driver does not know an answer was lost; it knows only that the row has no id. If the search runs only on a retry path (`attempts > 0`), it does not run here.
  3. `createDraft` again → D2. Two drafts with Message-ID X in Gmail's Drafts on every device. If X was scheduled, D carries `X-Banana-Send-At` and the owner's id, is never sent, and shows as "Scheduled from the owner's Mac" on other devices indefinitely (the janitor does not touch drafts).
  4. The fallback when `rfc822msgid:` does not work for drafts (UNVERIFIED) is "the newest 20 drafts"; a mailbox with more than 20 drafts can miss it.
- **What the design says:** 7.3 lines 1622–1627. Unspecified: that the search is run before *every* create for a row whose upload has ever started; the 20-draft cap.
- **Outcome:** Duplicate drafts; an orphan scheduled draft shown as scheduled forever.
- **Smallest change that closes it:** Commit `upload_started = 1` before the first `createDraft`; any create for a row with that flag searches first. Make the search by `drafts(query: "rfc822msgid:")` and, if that is refused, page `drafts.list` to the end (5 units a page, `.minimal`), matching on `Message-ID` from a `header`-format read only of drafts whose `internalDate` is within an hour of `mime_date`. Delete orphans with the same Message-ID, as 7.3 already says.

---

## Minor

### S-21 · MINOR · Invariant 4 says "written before it is shown"; 13.1 shows first and writes 8–30 ms later

- **Scenario:** held `E` at 30/s; group commit waits 8 ms (4.2 line 449–450); iPhone fsync 5–20 ms (ASSUMED). The app is killed by iOS or a crash elsewhere. The last 1–3 presses were shown (the rows left; T16 advanced the cursor) and are not in `intent.sqlite`. Relaunch: they are back.
- **What the design says:** invariant 4 lines 73–75 vs 13.1 lines 2400–2403.
- **Outcome:** A few actions lost in a crash; visible (rows return), bounded to tens of milliseconds.
- **Smallest change:** Reword invariant 4 (see list). Keep the in-memory accepted list until the commit succeeds (needed for S-2 anyway).

### S-22 · MINOR · Intents a week old are delivered over a week of changes made elsewhere

- **Scenario:** Google signs the Mac out (`needsSignIn`); its outbox holds 40 assertions; he works from the phone and the web for a week; he signs the Mac in; the 40 are delivered (6.8). Among them: "mark unread" for three messages he has since read and replied to; a snooze whose time is past (delivered as `Snoozed/<past>` + `INBOX` absent, then woken on the next `due` with `Returned` and `UNREAD`).
- **What the design says:** 6.8 lines 1546–1555 chooses this knowingly; 6.5 line 1509 keeps them pending.
- **Outcome:** Visible, undoable surprises; a week-old snooze returning "unread, back from snooze" today.
- **Smallest change:** Assertions older than 48 h at the moment the account becomes deliverable are not auto-delivered; they are listed ("12 changes from last week — apply / discard"). Timed assertions (S-7) are re-derived and so never deliver a past snooze.

### S-23 · MINOR · One device with a wrong clock wakes every snooze early on every device

- **Scenario:** The iPad's clock is set three days ahead (travel, a dead NTP). Its `due` finds every `Snoozed/<t>` with t ≤ its now → wakes them all, with `Returned`, so no device re-snoozes.
- **What the design says:** 8.2 rule 1; nothing on clock sanity.
- **Smallest change:** Compare the `Date` header of each Gmail response with local time; if they differ by more than five minutes, run no timed assertions on this device and say so in `MailSyncHealth`.

### S-24 · MINOR · Two devices snooze the same conversation offline to different times; the resulting state is unspecified

- **Scenario:** Phone offline: `Snoozed/T1`; iPad offline: `Snoozed/T2`. Both deliver. Messages carry both. `BananaLabelRules.state` returns which `wakeAt`? `due` rule 1 fires at the earlier; rule 2 then removes the other. Un-snooze from a device that knows only one label leaves the other until rule 2 clears it.
- **What the design says:** 8.2; silent on multiple snooze labels.
- **Smallest change:** State it: earliest wins; `state` reports the minimum; un-snooze asserts *every* `Snoozed/*` absent.

### S-25 · MINOR · The label janitor must use Gmail's count, not local absence

- **Scenario:** The weekly janitor (8.2 line 1870) deletes `Banana/Snoozed/*` labels "whose time is over a day past and which no message carries" — judged from the local cache. On a device whose cache is incomplete or whose Apply has not run for that label, "no message carries" is absence of evidence. `labels.delete` "removes it from any messages" (dossier §4.2). A snooze that was due yesterday while every device slept loses its label before any device wakes it: the conversation stays archived, never returns.
- **Smallest change:** `label(id)` → `messagesTotal == 0` is the only evidence for deletion; and the janitor runs only after this device's own `due` pass.

### S-26 · MINOR · A fetch in flight across a `messagesDeleted` resurrects the deleted message for a week

- **Scenario:** Stub M queued; `messages.get` in flight; the poll applies `messagesDeleted M` (row deleted); the fetch response (served before the deletion) is stored → M reappears, with no history record left to remove it, until the weekly reconcile 404s it.
- **What the design says:** 5.5 line 1239–1240 covers a fetch that 404s, not one that succeeded before the deletion.
- **Smallest change:** A `tombstone(account, gmail_id, at)` table in the index, kept 24 h; the writer refuses to store a message with a tombstone; also used by 6.5's 404 accounting.

### S-27 · MINOR · The settling overlay hides a newer outside change for up to ten minutes when there is no echo

- **Scenario:** His archive settles; within ten minutes he un-archives on the web; `labelsAdded INBOX` arrives and is applied to `message_label`; the overlay (`INBOX` absent, settling) keeps the row out of the inbox until the echo (which may never come: R7) or ten minutes.
- **Smallest change:** Settling ends on *any* history record for that (message, label) with an id newer than the delivery, not only the matching echo.

### S-28 · MINOR · Rewriting `name:` references to a real id spans two files; a crash leaves a `local:` label row beside the real one

- **Scenario:** Snooze offline → `local:Banana/Snoozed/T` label row in the index, `name:` reference in intent. Delivery creates the label, rewrites intent rows, crashes before the index row is rewritten. The next `labels` upsert adds the real id as a second row with the same name; memberships and the Snoozed view stay on the `local:` row.
- **What the design says:** 6.5 step 1 line 1477–1480; 8.2 line 1864–1867.
- **Smallest change:** Index first (upsert the real id onto the `local:` row by name, keeping `label_pk`), then intent; the overlay rebuild maps `name:` through `label_by_name`.

### S-29 · MINOR · A draft sent from another device stays listed as a draft here until its next save; Drafts can show two copies across id churn

- **Scenario:** Mac row `editing` for draft D. Phone sends D. Mac syncs S (SENT, same Message-ID) and the deletion of D's message. 7.4 retires the Mac's row only on "the other's next save". Until he opens it, Outbox/Drafts lists a draft that was sent. Separately: after `updateDraft`, the index holds the old DRAFT message id for a poll interval beside the local row.
- **Smallest change:** The writer, on storing any `SENT` message whose `rfc_message_id` matches a local draft row in a non-terminal state, retires the row (`message_by_rfc_id` exists for this). The Drafts list suppresses any `DRAFT` message whose `rfc_message_id` matches a local row, whatever its message id.

### S-30 · MINOR · `perform` never throws, but the intent store can be unavailable

- **Scenario:** `intent.sqlite` is newer than the code (4.9) or damaged and un-copyable (4.10 `mustRefuseSaves`). The design says "mail is read-only"; `perform` still returns a receipt and the feed still applies the change.
- **Smallest change:** While `MailStatus.store` is `.unavailable`, `perform`, `undo`, `newDraft` and `send` return `count 0` and apply nothing; the UI disables the keys (MAIL-UX should list this state).

### S-31 · MINOR · `cancelSend` answers true, the composer reopens, the process dies before `editing` is committed, and the message goes on relaunch

- **Scenario:** Row `held` on disk. Undo flips memory to `editing` under `MailSendGate`; the intent commit is queued (3–20 ms). Crash. Relaunch finds `held`, past its time → S6 → sent (and reported as late if > 24 h).
- **Smallest change:** Accept the window but make it the next commit in line: the cancel's intent write jumps the group-commit queue; and S6 asks (not sends) for any `held` row whose `hold_until` passed while the process was not running *and* whose composer id is in `ShellState.mail.composer`.

### S-32 · MINOR · Label intents for a disconnected account sit forever

- **Scenario:** 3.6 keeps unsent messages for a detached account and lists them; it says nothing about `label_intent` rows, which invariant 5 also keeps. They count in "3 changes waiting" forever.
- **Smallest change:** List them under the same "from an account no longer connected" heading with Discard.

### S-33 · MINOR · `GmailError.unauthorized` has no `DeliveryRules` outcome

- **What the design says:** 6.5's table lists needs-sign-in and scope-missing; 5.1 defines `.unauthorized` (401 after a fresh token). Unspecified → an implementer may map it to `failed` (shown as refused) or to hourly retry.
- **Smallest change:** `.unauthorized` → `.waitForSignIn`, and mark the account `needsSignIn` through the seam.

### S-34 · MINOR · Blob rows outlive their index rows; a rebuild resurrects deleted mail as label-less messages

- **Scenario:** `messagesDeleted` deletes the index row (`mail.writer`) and the content (`mail.blobs`) in separate commits; a crash between leaves the blob. 4.9's rebuild inserts a message row for every blob; it is visible (no `TRASH`/`SPAM`), appears in All Mail, and is removed only when the reconcile's verify 404s it — counted against invariant 3.
- **Smallest change:** Rebuild inserts rows only for blobs whose id the first enumeration lists, or marks rebuilt rows `vis = 3` (hidden) until a listing or a read confirms them.

### S-35 · MINOR · Undo of "Send and Done" after the hold has ended

- **Scenario:** `send(…, thenDone: true)` is one receipt. After the hold ends, T28 drops the entry ("Already sent"). The Done half — delivered or pending — is then unreachable by undo.
- **Smallest change:** `undo(receipt)` on a receipt whose send has left undoes the label group and returns `count` for it; the UI says "Already sent. Brought the conversation back."

### S-36 · MINOR · What an ordinary send sends is not stated when the draft was edited on the web during the hold

- **Scenario:** `ready` is a local judgement from the last upload's hash. A web edit changes the draft; `sendDraft(id)` without `replacing:` sends the web text he did not see here; with `replacing:` it sends this device's text and discards the web edit. 7.6 uses `replacing:` for scheduled sends only.
- **Smallest change:** Always `sendDraft(id, replacing: finalMIME)`; "what you pressed Send on is what goes". `ready` then means "draft id known"; the pre-upload is an optimisation, not a precondition.

---

## Scenarios checked and found safe

One line each, with what makes it so.

- Kill -9 between the intent commit and the index commit of one action: index behind, overlay rebuilt from intent at launch — spike mode 1, three runs; invariant 4, 6.4.
- Index ahead of intent for an action: impossible by ordering (intent `FULL`+`fullfsync` commits first; 4.2).
- Power loss after the intent commit: intent is durable; index `NORMAL` may lose it; same repair (4.2, 6.4).
- `in flight` found at relaunch → pending → re-sent; label sets converge (6.2; dossier §5.2 replay table).
- Crash after `message_label` applied but before `settling`: re-send is moot against fresh `message_label` — correct drop (6.5) — *given* S-1's tri-state.
- History page applied twice or across a kill: state-based apply (5.5 line 1242–1247); checkpoint and page in one transaction (5.5 step 2).
- History 404 on a full cache with a full outbox: `checkpoint = NULL`, cache kept, intent untouched (5.3; invariant 5).
- A message added and deleted inside one pass: neither stubbed nor fetched (5.5).
- Fetch 404 for an id never stored: job dropped, nothing removed (5.5, 5.7).
- Absence from a listing: queues a read, removes nothing (5.3 step 4, invariant 1).
- A listing page token Gmail rejects: that listing restarts; marks from the partial run remain valid positive evidence (5.3 step 3).
- Listing truncation of the unlabelled listing: `messagesTotal` shortfall re-runs it (5.8).
- Token minted for another address: `getProfile` mismatch stops the account before any derivation (invariant 2) — provided every token mail uses is checked, including ones the calendar minted (note under questions).
- Same thread id in two accounts: every key carries the account (4.3, 4.7, 4.8, 13.1).
- Beta and production on one mailbox: two devices with separate stores, device ids and quotas; a Beta send is a real send and 14 says so.
- Device restored from an old backup: `BananaMail/` excluded; fresh first sync; `notify_mark` baseline prevents a flood (4.1, 12.3) — except the orphaned scheduled send (S-10).
- Archive names messages, not the conversation: a reply that arrives in between keeps `INBOX` (6.1).
- Undo before delivery: coalesces to moot, nothing sent (6.3). Undo after delivery: inverse sent; echo order converges (6.7) — except the in-flight race (S-5).
- Scope target over thousands, some changed elsewhere: per-key `before`; delivered per 6.8; 404s dropped per key (6.7, 13.1).
- Permanent failures (403 `domainPolicy`, 400): `failed`, listed with Retry/Discard, never timed out (6.9, invariant 6). Scope missing / needs sign-in: pending until the account changes (6.5).
- `sending` committed with full fsync before the request; relaunch in `sending` → `verifying`, never a send (S2, S5).
- Lost answer to `drafts.send` on a *reply*: draft gone → thread read → `SENT` with our `Message-ID` → `sent`; one request (S4) — subject to S-9's two-read guard and R6.
- `drafts.send` on an already-sent draft id → 404 → verifying (R4), if Gmail behaves as inferred; W3 confirms.
- Two devices pressing Send on the same draft in the same second: known risk R3, held by one owner for scheduled sends and by human improbability otherwise.
- iOS backgrounding inside the hold: hold ends, send under an assertion, ten-minute notification if it did not go (7.5).
- Hold that ended 25 h ago at relaunch: asks (S6 `askIfLateBy`).
- Attachment over the limit: refused in the composer (7.2); a forwarded attachment not on the device is fetched first (11).
- Two fresh devices waking the same snooze: identical desired end state, one change (8.2) — the stale-device case is S-7.
- Snooze label deleted in Gmail settings: his action, respected; nothing else depends on it (8.4).
- Disconnecting an account with unsent messages: kept and listed; cache deleted only after seven days absent (3.6).
- Reconnecting as a different address: refused by the calendar's `reconnect` (3.5).
- "Remove downloaded mail": `Cache/` only; `Intent/` untouched by construction (`MailIntentStore` has no delete; 4.1 table) — the *delivery* of what it leaves is S-1; a reply's headers are S-15.
- Schema migration crash: one transaction per step, re-run; downgrade refuses to open (4.9).
- Search indexer crash between the FTS write and clearing `fts_dirty`: re-indexed with `INSERT OR REPLACE` (4.6).
- Group commit under a held key: one intent transaction per 8 ms window; nothing draws from `mail.writer` (4.2).
- `cancelSend` vs the driver: one lock, one dictionary lookup, whichever first wins truthfully (7.5) — the ms window after is S-31.
- The first-frame snapshot after a relaunch: every optimistic row is backed by intent (4.11) — within S-21's window.
- Notification actions while the app is not running: through the outbox, durable before the process can be killed (12.3).
- OS-initiated deletion of `BananaMail/`: not a purgeable location; does not happen.

---

## Invariants to add or reword

1. **Reword 1.** "…or HTTP 404 for that message id" → "or a 404 that is the status of the inner part (or single response) of a request naming exactly that id, with a parsed `notFound` error body, from a token verified as this account's. An outer, transport-level or unparsed 404 removes nothing." And: "A `labels` response is complete only if it contains every system label; otherwise it is a failed read." (S-3, S-14)
2. **Reword 3.** Define the pass: "…counted over the whole of one reconcile's verify outcome, or over a rolling 24 hours of incremental passes — never per batch." Extend to label memberships. State what a hold does to the checkpoint and what "keep" means. (S-12, S-13)
3. **Reword 4.** "An action is shown at once and committed to `intent.sqlite` within one group-commit window; it is never shown *after a relaunch* unless committed; a commit that fails is reverted on screen and reported, never swallowed." (S-2, S-21)
4. **Reword 6.** "…or by being proved moot by a *positive* read of that message's labels. Absence of a label row, a stub, or a rebuilt index never proves anything moot." (S-1)
5. **Reword 7.** Add: "`drafts.send` is retried on the same id only after the sent copy has been looked for and not found and the draft has been read present twice, at least five seconds apart. For a new message the sent copy is looked for in `SENT` by `Message-ID`, not in a thread." (S-8, S-9)
6. **Reword 8.** Add: "A scheduled draft whose owner has not sent it five minutes past its time is reported on every device that syncs it." (S-10)
7. **Add 22 — Unknown is not absent.** No rule in the engine may treat a missing index row, a stub, or a label set that no per-message read has established as a statement about Gmail's state. (The general form of 1, applied to the outbox, the labels table, the janitor and the rebuild.)
8. **Add 23 — A stale read never overwrites a newer state.** A fetched message's label set replaces the stored one only when its `historyId` is not older than the stored `history_id`; a response that carries no `historyId` is a fallback for a message that has none. (S-6)
9. **Add 24 — Timed assertions are re-derived before they leave.** Any assertion produced by `BananaLabelRules.due` is tagged, and is delivered only if `due` on the fresh facts after the sync pass still produces it. (S-7)
10. **Add 25 — Delivery marks only what it sent.** The in-flight mark carries `seq`; the 2xx and 404 handlers change only the row with that `seq`. (S-5)
11. **Add 26 — The disk is a resource the fill may not exhaust.** The fill, prefetch and indexer stop under a free-space floor; `intent.sqlite` always has room to commit one action. (S-2)
12. **Add 27 — A held send survives quit on every platform.** On macOS, termination is delayed until held and sending drafts have gone or 30 s pass, and a waiting-to-send notification is scheduled as on iOS. (S-4)
13. **Add 28 — Reply identity lives in the draft row.** `In-Reply-To`, `References` and the parent's `Subject` are captured at `newDraft`; building the MIME needs no blob. (S-15)
14. **Add 29 — A deleted id is a tombstone for a day.** The writer refuses to store a message whose id was deleted in the last 24 hours. (S-26)

---

## Live-mailbox probes that must run before the corresponding package ships

In order; each names the package it gates and the scenario it retires.

1. **Before P12 (incremental sync).** Read-only probe items 3, 5, 6, 10, plus: (a) one `labels.list` with a deliberately wrong `fields=` mask — what does the body look like (S-3)? (b) a `messages.get` for a non-existent id, single and inside a batch: outer status, inner status, exact error body (S-14); (c) does `history.list` include this client's own `modify`? how do `drafts.update`, `drafts.send`, trash and the 30-day purge appear (R7, S-29)? (d) `messages.get` in each format: `historyId` present (S-6)?
2. **Before P13 (reconcile).** Two complete inbox listings ten seconds apart with a web archive between them (probe 5); how often a listing ends without a token prematurely (R18, S-12); `history.list` from an id older than a week and from one two days old on an account that is heavily used (S-17: how long is history really kept for *his* mailboxes).
3. **Before P15 (delivery).** W1 as written plus: `batchModify` with one bogus id — 200, 400 or 404, and whether the valid ids were applied (S-19); `labels.create` with an existing name — status and reason (S-28); `modify` replay of an already-applied label — status (6.2).
4. **Before P17 (drafts).** Probe item 8 (`rfc822msgid:` in `drafts.list`) (S-20); W2 — and W2 extended: edit the draft in Gmail's web UI, read it back: are the two headers kept (S-11)?; `drafts.list` paging and whether a draft's `internalDate` is its creation or last update.
5. **Before P18 (send).** W3 as written plus: (a) `drafts.get` immediately after `drafts.send`, at 0, 1, 2, 5 s — present or 404 (S-9); (b) `messages.list labelIds=SENT q=rfc822msgid:<X>` right after a send of a *new* message, at 0, 2, 5, 30 s (S-8); (c) `threads.get` of the reply's thread at the same times; (d) is a client `Message-ID` kept, and is `X-Google-Original-Message-ID` present if not (R6); (e) `drafts.send` replay — 404, or something else (R4). Then W4 (R3, D8).
6. **Before P19 (timed labels).** W5 plus: a conversation carrying two `Banana/Snoozed/*` labels as Gmail's apps show it (S-24); `labels.get` counts for a hidden label (S-25); the `Date` response header's presence on every Gmail response (S-23).
7. **Before P24 (wiring), on a device, not a mailbox.** Fill the Simulator's disk image to within 50 MB of full with the fill running: what `SQLiteError` the intent commit throws, what `perform` does, what relaunch shows (S-2). Power-cycle a device (not the Simulator) mid-fill and run the S-16 anti-join.

---

## Tests the fake Gmail must be able to express

Each is a failure injection or a modelled behaviour `FakeGmail` needs beyond 17.2's list, named by the scenario it exercises.

- **Apply-then-lose-the-response** for every mutating method: `modify`, `batchModify`, `trash`, `untrash`, `createLabel`, `createDraft`, `updateDraft`, `deleteDraft`, `sendDraft` (S-5, S-9, S-20; already listed for "the lost response" generally — make it per method).
- **Delay per id**: hold one `getMessages` part's response until after a chosen history page has been served (S-6, S-26).
- **A write visible to history only after n further calls** (already listed) — and the reverse: a `messages.get` whose `labelIds` are *behind* history by n records (S-6).
- **`labels.list` returning an empty list, a list missing `INBOX`, or a body without the `labels` key** (S-3).
- **Outer 404** on a batch request; **inner 404 with an HTML body**; inner 404 with the real JSON body (S-14).
- **`batchModify` with one bad id → configurable 200 (silently skipped), 400, or 404; with and without the valid ids applied** (S-19).
- **`labels.create` with a duplicate name → configurable 400/409 and reason** (S-28).
- **`drafts.get` after `sendDraft` still present for n calls** (S-9); **`sendDraft` replay → configurable 404 / 200-and-send-again** so the test proves the two-read guard prevents the second message (S-9).
- **A web client** (`FakeGmail.web`) that: archives a woken conversation; replies to a waited-on message; edits a draft (header loss for a scheduled draft); deletes a draft; sends a draft another engine holds; permanently deletes 40 % of a mailbox in one history window (S-7, S-11, S-18, S-13).
- **A `getProfile` that returns a different `emailAddress` for one minted token only** (invariant 2) — and a token minted by "the calendar" that mail must still verify.
- **A clock per engine** so one engine can be skewed three days (S-23); and a controllable `Date` response header.
- **`createDraft`/`updateDraft` with a `threadId` that no longer exists → configurable 400/404** (S-15 follow-up).
- **History expiry mid-enumeration** (`expireHistory(before: enum_checkpoint)` once the listing has started) (S-17).
- **A listing that ends without `nextPageToken` before the end** (S-12, R18).
- **Store-side, not Gmail-side:** a `MailIntentStore` that throws `SQLITE_FULL` on the next commit; a `MailBlobStore` whose last commit is "lost" on reopen (truncate its WAL in the test) while the index keeps its own (S-2, S-16).
- **Two engines where one is "asleep" (no sync, no `due`) across a wake and an archive elsewhere, then wakes** — the S-7 shape, as the P19 test "woken, then archived elsewhere, is not woken again" must be run with the *stale* engine, not a fresh one.

---

## Questions (suspicions I could not turn into steps)

- Does the outbox driver drain for an account whose `checkpoint` is NULL? 6.5 sequences it "after that account's incremental pass". If it waits, S-1 is moot but every offline action on a phone waits for an enumeration that can take days (S-17); if it does not wait, S-1 applies as written.
- 5.5 says "Apply each page in one index transaction" and in the next sentence "A pass of ten pages or fewer is applied as one transaction". Which? Both are crash-safe; the second makes a 500-record × 10-page pass one transaction on `mail.writer` (invariant 11's 30 ms p95 budget).
- Reconcile step 4 (Apply): are "add memberships, fill `verify_queue`, set `checkpoint`, delete marks" one transaction? If not, a crash after the marks are deleted and before the checkpoint is set restarts the whole enumeration (cost only).
- Invariant 2 says "the first call with a newly minted token"; the token cache is shared with the calendar, which mints too. Does mail verify tokens it did not mint? It must track verification per token string, not per mint.
- The `verify_queue` is keyed by `msg_pk`; the rebuild renumbers. Fine because the file is rebuilt whole — but a `verify_queue` populated by the *drift* re-list (5.8) and then a rebuild loses the queue; is the re-list repeated?
- `fts_rowid` "low bits bumped on the rare collision": after an index rebuild the bump is not reproducible (it depends on insertion order), so one of a colliding pair will point at the wrong `search.sqlite` row. Two messages with the same `internalDate` to the millisecond and a 20-bit hash collision: vanishingly rare; worth a comment.
- MAIL-UX T27 says the undo stack "is not written to disk: after a cold launch it is empty" while the engine keeps 50 groups for a day; after a relaunch, More › Undo (T44) cannot reach them. Intended?
- `settings.sendAs` read "at each handshake" — a handshake is a reconcile; between weekly reconciles a new alias is not seen for up to a week (7.7 also says "at most daily", which contradicts).
- What does `perform` do with a `MailTarget.view` whose view has `built_rev < definition_rev` (a split being rebuilt)? The resolution on the writer may enumerate a half-built membership.
