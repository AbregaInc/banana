# Data-safety verification of the revised `docs/design/MAIL-ENGINE.md` (5,516 lines)

Checked against `review/data-safety.md` (S-1…S-20), §2 invariants, §22.2's resolution table,
and the resolving sections, step by step against each original scenario. Line numbers are into
the revised file. Read-only; no spike re-run — the crash-between-commits spike's premises (two
WAL files, `intent` committed `FULL`+`fullfsync` before `index` at `NORMAL`, no cross-file
transaction) are unchanged under GRDB and the timerless group commit (4.2 L546–570, 6.2
L1801–1807), so its conclusion (index behind intent, never ahead, repaired by the overlay
rebuild) stands as evidence for 6.2.

**Counts: 18 CLOSED · 2 PARTLY · 0 NOT CLOSED.** New findings: 1 MAJOR, 6 MINOR.

## 1. Finding by finding

| Id | Verdict | Resolving text (section · lines) | How the original sequence now ends |
|---|---|---|---|
| S-1 moot-drop on unknown label state | **CLOSED** | 6.1 L1767–1776 (`isMoot(want:gmailHas: Bool?)`, nil never moot; `labelsKnown`); inv. 22 L106–108; 4.9 L1119–1128 (rebuilt rows `vis = 3`, no labels, "not moot while its labels are unknown"); 6.5 L1883–1885 (delivery never waits for an enumeration); P14a test L4585; P13a test L4836–4837 | Step 4: no row / stub / rebuilt row → `gmailHas = nil` → not moot → delivered; the 2xx or a read's `notFound` is the positive statement. One residual in how `labelsKnown` is *set* — S-N1 below. |
| S-2 full disk; failed intent write swallowed | **CLOSED** | inv. 4 L86–92, inv. 26 L117–118; 6.2 L1808–1812 (step 6 fails → group discarded, `notSaved` per receipt, rows come back, `store = .cannotSave`, writer continues), L1821–1822 (store not open → `count` 0); 4.10 L1146–1148; 11.3 L3078–3085 (floor 1 GB / 5 GB; fill, prefetch, preparation, indexer stop; eviction to +500 MB); 13.7 L3922; `MailEvent.notSaved` L3629; P14b L4597–4599; P23b L4646; P13b L4843 | Step 3: `SQLITE_FULL` → `notSaved`, rows return at rest, status says why; step 4: the snapshot is written only after step 7 (L1805–1807), so a relaunch shows the truth. Step 1 no longer happens: the fill stops at the floor. Residual for drafts — S-N3. |
| S-3 short `labels` answer empties everything | **CLOSED** | 5.3 L1455–1460 (complete = contains the seven system labels; incomplete changes nothing; a stored label not named is asked for by `label(id:)` and removed only on `notFound`; > ⅓ of memberships held); inv. 1 L68–75; inv. 3 L84–85; fake row 5 L4174; P12a L4527; P13a L4835–4836; probe item 2 L4968–4970 | Step 2: `[]` or a list without `INBOX` is incomplete → nothing changes. A genuinely deleted user label is removed on its own `notFound`, and a batch of them is held. |
| S-4 Mac ⌘Q inside the hold | **CLOSED** | inv. 27 L119–120; 7.5 L2235–2251 (`terminateLater` until no draft is `held/uploading/ready/sending` or 20 s; idle-sleep assertion; `willSleepNotification`; the 10-minute notification "on every platform"); `hasUnfinishedSends`, `finishSends(within:)` L5226; P18 L4774 | Step 3: quit is delayed and the send runs; step 4: the Mac now schedules the notification; step 5 cannot occur unless the 20 s ran out, in which case he is told at +10 min. New: the sleep assertion is unbounded — S-N2. |
| S-5 2xx clobbers a newer seq | **CLOSED** | inv. 25 L115–116; `sent_seq` L1044; 6.3 L1830–1848 (answer updates `WHERE seq = sent_seq`; a moved-on row stays pending; `message_label` still updated); `DeliveryRules.marks` L1922–1923; P14a `markAnswered` L4578; P15a L4621–4622 | Step 3: the archive's 2xx marks nothing (seq 6 ≠ sent_seq 5), records Gmail's state; step 4: the undo is delivered on the next drain. The spike's guarded variant, as designed. |
| S-6 stale fetch overwrites newer labels | **CLOSED** | inv. 23 L109–110; 5.6 L1599–1601 (`labelsApply`: `stored == nil \|\| stored <= floor`), L1625–1627, L1635–1637 (no `historyId` → floor is the position when the request left: only an extra read); 5.5 L1553–1555 (records raise `history_id`); 5.3 step 3 L1428–1435 (listings under the same floor); P06a L4500–4501; P12b L4606–4607 under `getOmitsHistoryID` | Step 3: fetch `historyId` 100 < stored 120 → labels not replaced, content stored. Listing pages get the same guard. |
| S-7 `due` on stale state delivered after sync | **PARTLY** | inv. 24 L111–114; 8.3 L2396–2404 (after every *successful* pass and again before delivery, derived rows deleted and `due` rerun; shown but not delivered until a pass succeeded and an offset exists); 6.5 step 1 L1887–1888; `origin` L1046, `derived` L691; 8.2 L2370–2383; P19a L4915 | Scenario A and B close for the ordinary case: the pass brings `Returned`/the reply, the rerun produces rule 5 / rule 3, the stale wake is deleted. **Still fails** when the device was asleep past history retention: `history` → `notFound` → reconcile handshake stores a *new* position (5.3 L1419–1421); the first poll from it succeeds at once with nothing; 6.5 step 1 reruns `due` on a cache whose `Banana/Returned` listing has not run (enumeration is backfill-lane, L1425, minutes behind) → rule 1 fires again → delivered → the archived conversation returns. 6.5 L1883 also runs the driver after a *failed* attempt and does not restate 8.3's gate. **Fix:** derived assertions are not delivered while `enum_state` is non-NULL for the account (or until that enumeration's `Banana/*` listings have closed); 6.5 step 1 names both gates of 8.3. One sentence each. |
| S-8 lost send answer, new message | **CLOSED** | 7.4 S4 L2182–2191 (`rfc822msgid:` under `SENT`, "needs no thread"; last check compares the newest 20 `SENT` headers on `Message-ID` and `X-Google-Original-Message-ID`); L2200–2201 (a later pass that stores the `SENT` copy retires the question); P18 L4771–4772 | Step 3: verified without a thread; step 5 is reached only after four checks over ten minutes and is his, with "not in Sent / draft still there" shown. |
| S-9 retry after one "draft still there" read | **CLOSED, stricter** | inv. 7 L99–102; 7.4 L2131–2132, S3 L2176–2177 (`notFound`, unknown → `verifying`), S4 L2192–2198 ("the draft is still in Gmail never sends it again by itself"), L2173 (a parsed sending-limit refusal is retried only after a Sent check); fake rows 37, 39 L4206, L4208; P18 L4768–4770 (exactly one `sendDraft` under `sendReplay = .sendsAgain` and `draftLingers`) | Step 3 no longer exists: there is no engine retry after an unknown result. |
| S-10 orphaned scheduled send | **CLOSED (design; built in P18b)** | inv. 8 L103–104; 7.6 L2280–2286 (`MailSchedule.isLate` on every device; "Send now from here"; "an owner that was wiped or restored never runs; the other devices' 'not sent yet' is what tells him"); 14 L3989 | Step 3–4: every device that syncs the draft reports it late. Note: it is a row value, not a `MailQuestion`/`MailEvent`; the UX must raise the alert card from `isLate`. Acceptable, said here so nobody assumes the engine announces it. |
| S-11 editing a scheduled draft elsewhere cancels it silently | **CLOSED (design; P18b)** | 7.6 L2287–2292 (`save` refused with `scheduleOwnedElsewhere`: take over or cancel; take-over checks Gmail and Sent first); `MailQuestion.Kind` L3610; 13.3 `save` L3774; W2 extended L5000 | Step 2 cannot happen silently. |
| S-12 invariant 3's pass undefined for verify batches | **CLOSED** | 5.3 step 5 L1444–1452 (`verify_queue.outcome`; all `gone` of one generation judged together); 5.7 L1655–1659 (reconcile: one generation; incremental: this pass + 24 h of hourly counts, `account.removals` L615); inv. 3 L81–85; P13a L4833–4835 | Step 3: fifty-at-a-time no longer matters. |
| S-13 hold with no resolution | **CLOSED** | 5.7 L1661–1673 (`held_removal`; the rest of the pass and the checkpoint applied; `removalHeld` asked once; Remove / Keep → `vis = 4`, readable, no changes accepted; a later pass adds, does not re-ask); `held_removal` L707–710; L3605, L3618; P13a L4833–4835 | Steps 3–4: sync continues; "keep" has a meaning. Residual cost in S-N4. |
| S-14 outer vs inner 404 | **CLOSED** | 5.1 L1267, L1271, L1280–1283 (`notFound` has one shape; anything else is `unexplained(404)`); no batch codec L1295–1297; inv. 1 L70–74; 5.7 L1646, L1650–1652; P22a L4862 | Step 3: an outer or HTML 404 is `unexplained` → nothing removed. A *change's* 404 now queues a read instead of deleting (L1650) — stricter than asked. |
| S-15 reply headers read from the original | **CLOSED** | inv. 28 L121–122; 7.1 L2022–2026; `in_reply_to`, `references_hdr`, `thread_id` L1067; 7.2 L2052–2053; P17 L4762–4763 | Step 3: the MIME is built from the row. |
| S-16 index ahead of blobs after power loss | **CLOSED** | 5.6 L1629–1634 (open → back to `fetch_state = 1` and fetch; after an unclean exit a paced comparison pass; eviction index-first); 11.3 L3086–3087; 4.7 L1023–1024; P33 L4850; store-fault hooks L4231–4233 | Step 3: self-heals on open; the repair pass catches the rest. (On a phone the pass is paced and runs only with Mail on screen or overnight — fine.) |
| S-17 no incremental sync during enumeration | **CLOSED** | 5.3 L1414–1417, L1419–1421 (position stored at the handshake; every poll replays from it throughout); 5.5 L1527–1529 (hourly position write keeps it inside retention); 6.5 L1883–1885; P13a L4830–4833 | Steps 2–3: new mail arrives during the listing; the position does not age out behind it. Open: what a `notFound` *mid*-enumeration does to the running generation (restart or continue) — cost only. |
| S-18 re-created draft checks the local index for Sent | **PARTLY** | 7.3 L2113–2118 (asks Gmail: `rfc822msgid:` under `SENT`; found → retired; not found → new Gmail draft, `gone_once`); 7.4 S1 L2160–2162 (a `gone_once` draft runs the Sent check before sending); P17 L4762 | Steps 1–3 now ask Gmail, which is the fix asked for. **Still fails** if the API does not honour `rfc822msgid:` in `messages.list` (dossier §11: UNVERIFIED; fake row 11 L4180 models it as understood, with a switch only for drafts, row 12): "not found" → a new draft with the same `Message-ID` → sent → twice. S4 L2186–2188 has the newest-20-`SENT`-headers fallback for *verification*; 7.3's path and S1's `gone_once` check do not. **Fix:** 7.3 and S1 use S4's check in full (operator, then the newest-20 fallback); add a fake switch `msgidFindsSent = false` and run P17's test under it; probe item 8 (L4983) and W3 (L5001) settle it before P18. |
| S-19 `batchModify` 400 refuses the batch | **CLOSED** | 6.5 table L1908 (`notFound` *or* `refused` for a batch → one `modify` per message); `.splitBatch` L1919–1920; fake row 28 L4197 (four combinations); P15a L4622–4623 | Step 3: no row is marked failed by a batch answer. |
| S-20 crash after `createDraft` 2xx | **CLOSED** | 7.3 L2101–2106 (`upload_started` committed before the first create; search before any create while it is set and no id is stored; duplicates deleted); `upload_started` L1070; fake row 12 L4181; P17 L4760–4761 | Step 2: the search is unconditional. The newest-20-drafts fallback cap (original MINOR note) still stands; probe item 8 decides whether it is ever used. |

## 2. The invariants asked for

| Asked | Present as an invariant? | Contradicted elsewhere? |
|---|---|---|
| Unknown is not absent | **22** L106–108 | Partly, by wording: `labelsKnown` "a read **or a history record** has established the set" (6.1 L1775, Appendix A L5374) — a record cannot establish a set; see S-N1. 5.5 L1556–1558 says exactly this for *unknown* messages but not for known stubs. |
| Stale-read guard | **23** L109–110 | No. 5.3 step 3 and 5.6 use the same floor rule; 5.5 raises `history_id` on records. |
| Delivery marks only the sequence it sent | **25** L115–116 | No. 6.3, 6.5 step 5, `DeliveryRules.marks`, P14a's `markAnswered` all agree. |
| Free-space floor | **26** L117–118 | No. 11.3, 4.10, 6.2 L1824–1825 agree. The floor does not cover `Intent/Attachments` writes (a 25 MB attachment copied into a draft on a device 900 MB from full) — 6.2's failure path covers the row, not the file copy; `addAttachment` should report the same `cannotSave`. Minor. |
| Held sends survive quit on every platform | **27** L119–120 | No — but the sleep half is unbounded (S-N2). |
| Tombstones | **29** L123–124 | No. 5.5, 5.6, 5.7, `tombstone` L713–715, P06a, P12b agree. |
| Derived assertions re-derived before they leave | **24** L111–114 | Yes, in effect: 6.5 L1883 runs the driver after a failed pass attempt and step 1 re-derives on whatever is stored; 8.3 L2403–2404 requires a succeeded pass and an offset. The two gates must be one (S-7). |
| Reply identity in the row | **28** L121–122 | No. |
| Reworded 1, 3, 4, 6, 7, 8 | All present L68–104 | Invariant 4 ("the person is told") vs 13.3 `save` "never fails visibly" L3774 (S-N3). |

## 3. New findings in the revision

### S-N1 · MAJOR · `labelsKnown` may be set by a history record, which reopens the moot-drop for a listed stub

- **Scenario:**
  1. First sync on the phone, enumeration running for days (5.4). Message M is listed under `INBOX`: a stub with membership `{INBOX}`, `labelsKnown` false (5.3 step 3). The `UNREAD` listing has not reached it yet.
  2. A poll applies `labelsAdded STARRED` for M — a known id, so 5.5 L1553–1555 applies it and raises `history_id`. 6.1 L1775 and Appendix A L5374 say `labelsKnown` is set when "a per-message read or a history record has established its set"; an implementer sets it here.
  3. He opens M from the inbox (it is in the view) and marks it read: `UNREAD` absent. Stored set `{INBOX, STARRED}`, `labelsKnown` true → `gmailHas(UNREAD) = false` → `isMoot(want: false, gmailHas: false)` → dropped (6.5 step 3).
  4. M is unread at Gmail and on every other device; this one shows it read until the `UNREAD` listing or a read says otherwise, and the mark-read never goes. The same drops an un-star, an un-important, a "restore".
- **What the design says:** 6.1 L1774–1776; Appendix A L5374, L5449; 5.5 L1556–1558 states the right principle ("a record says what changed, not what the label set is") for unknown messages only.
- **Outcome:** Silent loss of a marking action, during exactly the days-long window invariant 22 was written for.
- **Smallest change:** `labelsKnown` is set only by a per-message read (`minimal`, `header` or `full`, passing the stale-read rule) and by the Close of an enumeration for messages every listing has marked; never by a history record or a listing page. Reword L1775 and L5374; add "a record on a stub does not set `labelsKnown`" to P12b's tests.

### S-N2 · MINOR · The Mac's idle-sleep assertion is held for as long as a draft is `ready`, which offline is indefinitely

- **Scenario:** Send pressed with no route to Gmail; the hold ends; `uploading`/`ready` with `neverLeft` retried "when the network returns" (S3 L2172). 7.5 L2244–2247 holds `idleSystemSleepDisabled` "while any draft is `held`, `uploading`, `ready` or `sending`". Lid open on a desk, Wi-Fi off overnight: the Mac never idle-sleeps.
- **Smallest change:** Hold the assertion only for `held` and `sending`, and for at most 60 s per draft; `ready` waiting on the network needs no assertion — the network-return kick (6.6) sends it.

### S-N3 · MINOR · Draft `save` "never fails visibly" contradicts invariants 4 and 9 on a full disk

- **What the design says:** 13.3 L3774 vs inv. 4 L90–92, inv. 9 L105, 6.2 L1808–1812 (for changes). Text typed while `store = .cannotSave` lives in memory only; a crash loses it with no warning.
- **Smallest change:** `save` is "never fails visibly *while the store can save*"; under `.cannotSave` the composer shows the store state ("Not saved — this iPhone is full"), and invariant 9 names that case.

### S-N4 · MINOR · Kept rows (`vis = 4`) are re-verified at every reconcile and can re-enter the hold

- **Scenario:** After "Keep them on this device" for 4,000 messages, the next reconcile's Close (5.3 L1438–1443) finds each with stored memberships and no mark → `verify_queue` → 4,000 × 20 units → `gone` → counted again. 5.7 L1672–1673 says a later pass "does not ask again" for an *open* hold; after an answer, unspecified.
- **Smallest change:** Close skips `vis = 4` rows; invariant 3's counts exclude them.

### S-N5 · MINOR · The overlay rebuild serves the first page after only the newest 500 rows

- **Scenario:** A device offline through a day of triage holds 1,200 pending assertions. Relaunch: `first-page.json` (written from the index, overlay included) draws correctly; 6.4 L1873–1875 rebuilds 500 rows before the first read and the rest behind it; the first real page replaces the snapshot and shows conversations he archived back in the inbox until the remaining transactions commit; they then leave. 6.2 L1815–1817 ("no row flashes back") and 13.5 promise 2 do not hold for that window.
- **Smallest change:** The first read of a view waits for the rebuild (it is 0.2 ms per 500 rows on this Mac; even 5,000 rows is milliseconds), or the feed keeps the snapshot until a read tagged "rebuild complete" arrives.

### S-N6 · MINOR · A change's 404 queues a read, but nothing outside a reconcile is said to drain the verify queue

- **What the design says:** 6.5 L1909 ("queued for a per-message read; its assertions wait in pending with no retry time"); 5.3 step 5 is a reconcile step; 5.8's re-list runs steps 3–5 for one label. On a Mac the next reconcile is weekly; on a phone, an overnight window after a week. Until then the assertion is pending, the overlay applies, `waitingChanges` counts it.
- **Smallest change:** Every incremental pass drains `verify_queue` rows whose reason is "a change's 404" (incremental lane, ≤ 50), judging `gone` under the 24-hour count.

### S-N7 · MINOR · `synchronous=FULL` on `intent` is per connection, set after opening

- **What the design says:** 4.2 L456–458, L565–566; P14a L4576. Correct for a `DatabaseQueue` (one connection). It silently reverts to `NORMAL` if the intent store is ever opened as a pool, reopened, or if a second connection is made for salvage (4.10). P02's read-back test runs on the same connection.
- **Smallest change:** Set it in `prepareDatabase` *and* after open (GRDB's own pragma runs between them on a pool, not on a queue — pin which by test); P14a's test reads it back after `releaseMemory()` and from a freshly opened `MailIntentStore` on the same file; the salvage path sets it on its fresh file.

## 4. The revision's other changes, checked

- **"Shown, then durable."** What he sees and what reaches Gmail in each window (6.2 L1795–1822): before step 6 — on screen, in nothing else, lost on a crash (bounded to one commit, at most 50 changes; at a phone's 40 ms fsync and 30 presses a second that is about a second of a held key, said at L1803–1804); step 6 fails — put back, told, `cannotSave`; after 6 before 7 — durable, delivered, overlay rebuilt; after 7 — everything. Delivery reads intent only; the snapshot is written after 7. Sound. S-N5 is the one window it misses.
- **Mac delayed quit** (7.5 L2239–2243): bounded at 20 s; with no network `neverLeft` returns at once, so quit is not held; with a timeout the draft is `verifying` at the next launch (S5). Cannot hang. The sleep assertion can (S-N2).
- **Sync batch 20 and the checkpoint per history page** (5.5 L1523–1526; 5.6 L1622–1624): stubs for `messagesAdded` are created in the page transaction that moves the checkpoint, so a kill before their fetch leaves them in `message_stub_queue`; the fill's 20-message batches commit blobs then index; a kill between leaves a blob the next fetch overwrites. Safe. A fetch batch straddling a `messagesDeleted` is covered by tombstones (inv. 29).
- **GRDB and the four files.** Same SQLite, same WAL, same `NORMAL`/`FULL` split; `write` closures are synchronous and serial per pool; `afterNextTransaction(onCommit:)` fires after COMMIT, so a feed's tagged read never precedes durability. The only new hazard is S-N7. `eraseDatabaseOnSchemaChange` is grepped against (L580–581); `hasBeenSuperseded` is read-only (L581).
- **The hold's resolution path** (5.7 L1661–1673): checkpoint moves, evidence kept, one question, "keep" defined. Closed; S-N4 is cost and a re-ask edge.
- **The pass definition** (5.3 L1450–1452, 5.7 L1655–1659): one generation's `gone` outcomes together; incremental deletions over a rolling 24 hours; `labels` memberships under the same threshold (L1459–1460). Closed. One note: the rolling count is per account in `account.removals` (L615) and so survives a relaunch — good.

## 5. Verdict

**Yes — the store, sync and outbox packages (orders 1 and 2) can be built from this design, after one sentence is corrected first:** `labelsKnown` is set only by a per-message read, never by a history record or a listing (6.1 L1775, Appendix A L5374, and a line in 5.5) — S-N1, which is inside P06a/P12b/P14a. The two PARTLY items are in later packages and must be fixed before those are briefed: S-7's enumeration gate before P19a (one sentence in 8.3 and 6.5), S-18's Sent-check fallback before P17 (reuse S4 step 2; one fake switch). S-N2…S-N7 are minor and can land with their packages.
