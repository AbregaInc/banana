# Mail design — engineering verification pass

5 Oct 2026. Checked: `docs/design/MAIL-ENGINE.md` (5,899 lines), `MAIL-UX.md` (3,365),
`MAIL-PLAN.md` (623), against `docs/design/mail-working/review/engineering.md` and the code as
it is on the branch now. Read-only; nothing built or launched.

"EN n", "UX n", "PLAN n" are line numbers in the three documents as they stand today.

**Can C0 start now? No — not as one package, and not before sixteen text changes.**

- *Before the contract file is written* (it is frozen once C0 lands): decide the ten changes
  that alter §13 itself — T10, T11, T12, T13, T14, T15, T21, T23, T47, T60; make its text
  compilable and say which sections it is — T38, T39; and say how a member that is not built
  yet is stubbed — T52.
- *Before anything lands:* say what the lock does and that landing is a commit — T55, T56.
- *Before the fixture mailbox and the suite are written:* T37, with the mailbox's definition.

With those applied: yes, as C0a (contract, row rules, identifiers, `project.yml`, the lock) and
then C0b (the mailbox and the suite), on the owner's approval of the two packages, which the
coordinator is assuming. P01a and P02 need only C0a.

---

## 1. What became of each finding

### Blockers

| | Verdict | Where, and what remains |
|---|---|---|
| E-1 | **CLOSED** | EN 235–292: `MailAccountAccess` names account ids as `[String]`; nothing in `Mail/` names `GoogleAccountCredential`. EN 4637–4642: C0 creates the folder and its `project.yml` entry together. Residue: EN 4488 still says the entry is P01a's (T41). |
| E-2 | **PARTLY** | The structure is right: one file (EN 3452–3457), two sources, one suite, one mailbox (EN 4072–4092); UX 2892–2896 declares no types; U18 is gone; PLAN 172–174 accepts every UI package on the engine. What remains is in section 2: UX 12.6 still lists five requests as open and designs around their absence; twenty-four places where the UX or the plan uses something §13 does not give or gives differently (T10–T33); the contract's text does not compile as written (T39); and the two sources have no way to add a member later without editing the file that stubbed it (T52). |
| E-3 | **CLOSED** | Invariant 4 (EN 86–92) and 6.2 (EN 1814–1858) agree: shown, then durable, with `MailEvent.notSaved` and the rows put back. `MailRowRules` is in the contract (EN 3865–3899) with an agreement test. `MailReceipt.count` is optional, `MailEvent.applied` follows (EN 3813–3814, 3847). UX 595: "It keeps no overlay of pending changes". Residue, not the original defect: the table leaves five mailboxes unassigned (C0 question 3) and conflicts with the UX's kept rows (T10). |
| E-4 | **CLOSED** | Invariant 7 (EN 99–102); 7.4 S3–S4 (EN 2222–2262): an unknown result goes to *verifying*, which reads Sent by `Message-ID` and never sends; EN 2255: "That the draft is still in Gmail never sends it again by itself". Residue: EN 2287 names a `MailDelivery.sent` that does not exist (T19). |
| E-5 | **CLOSED** | EN 2433–2446: every change of his that takes a conversation out of the inbox asserts `Returned`, every `Snoozed/*` and every `Waiting/*` absent; EN 2459–2476 and invariant 24: rule-made assertions are deleted and derived again before delivery, behind two gates. |
| E-6 | **CLOSED** | Invariant 23 (EN 111–112). Reads: `FetchPlanRules.labelsApply` (EN 1624, 1648–1651). Listings: a membership is added only if the message's `history_id` is not past the page's floor, else it is verified (EN 1445–1452). |
| E-7 | **PARTLY** | EN 4608–4620 and PLAN 113–155 give the guard, the lock, one Simulator each and a table of shared files. Five holes, in section 3 ("Working in one tree"): edits to existing files are not covered by the guard; a stub cannot be replaced from an extension file; the lock has no owner, no stale recovery and two contradictory descriptions; "landed" is not a commit, so `git diff --stat` cannot be the acceptance check; lists that later packages must add to (fixtures, migrators, benchmarks) have no way to be added to. |

### Majors

| | Verdict | Where, and what remains |
|---|---|---|
| E-8 | **PARTLY** | EN 5532–5560 answers all forty rows, two declined with reasons (16: "set Mon" cannot be shown; 34: no free text in a split). Remaining: T1–T33 — the 12.6 leftover and twenty-four uses the contract does not match. |
| E-9 | **PARTLY** | `MailQuestion`, `MailChoice`, `answer(_:_:)` (EN 3821–3843, 3972) cover held removals, an unconfirmed or late send, and "send from here". `retry` and `discard` exist (EN 3944–3945) but take a receipt a screen holds only from `MailEvent.refused`; after a relaunch there is none, and the UX's list of refused changes has no source. Fix: T11. |
| E-10 | **PARTLY**, small | The cause is removed: mail holds its own credential (EN 195–233); P01b is three lines and an extension that "stores nothing and changes no calendar state" (EN 314–332); the password change is decision 6 (PLAN 587) with probe W6. Remaining: P01b also rewrites `.onOpenURL` (EN 337; `BananaApp.swift:618` today hands every URL to `GoogleCalendarService.handleOpenURL`) — the calendar's own sign-in return — and the table of paths that could change (EN 343–348) does not list it. Fix: a row there, and "a calendar sign-in on iOS completes" in P01b's Accept. |
| E-11 | **CLOSED** | UX 595 (no overlay), 1207–1210 (a limit that grows to `MailTuning.listCap`), 1703–1706 (`newDraft` fills the composer). Its leftover is T1–T9, counted under E-8. |
| E-12 | **CLOSED** | EN 4658: "P01a … No existing file changes"; P01b in order 6 (PLAN 28, 135). |
| E-13 | **PARTLY** | Errors and outcomes are declared (EN 269–283); `token(from:now:)` (EN 335); "re-reads … at the start of every pass" (EN 291); single flight is specified (EN 303–305). Remaining: (a) `.noWindow` still needs a string — `interactiveSignIn` throws `GoogleCalendarError.noPresentationContext`, a `private enum` (`GoogleCalendarService.swift:1695, 2197`), which `MailGoogleAccess`, in another file, cannot name; (b) `MailGrantRejection` must be parsed out of `credentialRejected(reason: String?)` (`GoogleTokenMinter.swift:30`); (c) single flight sits in `MailApp/`, which the tests do not compile, so it has no test. Fix: `googleConsent` throws a declared `GoogleConsentError`; the minter's error carries the OAuth code; the single flight is a pure type in `Mail/` over a minting closure. |
| E-14 | **PARTLY** | 13.2 and Appendix A (EN 5745–5899, with the wire models' fields) define most of what crosses packages; undeclared names in Swift blocks fell from 74 to 38, mostly private to one package. Remaining: `MailWriterWork`, `MailChangeSink`, `MailSignpost`, `StoredDraft` (EN 2085) are shared and undeclared; `MailReference`, `MailAssist`, `MailCache` have no file; and Appendix A's own file, P05's, names `GmailFormat` (EN 5845; P10a's) and `MIMEStructure` (EN 5852; P03b's, order 3), so it cannot compile where it is scheduled. Fix: T54, T64. |
| E-15 | **PARTLY** | 4.2 (EN 535–600) and P02 (EN 4666–4698) give the stores, the pragmas, the clock (EN 4128–4131), the performance line's mode. Remaining: P02 questions 1–5 in section 3; and every writer has `wal_autocheckpoint=0` (EN 571) while only `MailWriter` — index and intent — checkpoints: the writers of `blobs.sqlite` and `search.sqlite` have no one. Fix: T54, T49, and a line each in P07 and P08b. |
| E-16 | **PARTLY**, small | P06a gives every primitive as a signature, `view.key`'s encoding, when views are made, plans asserted by absence (EN 4730–4762). P06b gives names only (EN 4833–4835). Fix: its signatures. |
| E-17 | **PARTLY** | Closed: one transaction rule (EN 1541–1544), one position write an hour (1545–1547), the unknown message and label (1579–1584), lanes (1330–1334), invariant 2 in the transport (P10a's tests, 4776–4778). Remaining: `GmailSession.init(… governor: MailQuotaGovernor …)` (EN 1328) names P11's type in P10a's file, though P10a creates the protocol `MailQuotaGoverning` for exactly this; and `MailPassReport` returns to the poll loop in P23a's file, which P15a, P19a and P25 may not edit — nothing says how the outbox, the timed rules and the notifier receive it. Fix: T65, T66. |
| E-18 | **PARTLY** | Closed: `modify` per message and `batchModify` apart (EN 1258–1259); `GmailError.conflict` (1284); invariant 5 reworded (93–95); `group_seq` (1060). Remaining: `MailIntentStore` "exposes only typed operations" for `label_intent` (EN 4844–4846) and its queue is private by rule (EN 4596), so P17's drafts, `send_log`'s pruning, questions and `notify_mark` have no operation and no package may add one. Fix: T68. |
| E-19 | **CLOSED** | U4a, U4b, U4c (PLAN 276–313, 539–551); each state route names its package (UX 3133–3155); unbuilt controls drawn disabled (UX 3222). |
| E-20 | **PARTLY** | P23a–e (EN 4795, 4910, 5006, 5078, 5113); `MailEnvironment` with `beginBackgroundWork`, `MailNotifier`, `MailSettings` (EN 4098–4146). Remaining: a later slice cannot replace P23a's stubs (T52); no package implements `setWantsMail`, `requestPermission`, `forgetPermission`, `saveSplits`, `storageUsed` or `removeDownloadedMail`, which U14 and U10 call (T67); gate A's `activate` and `firstPage` benchmarks have no package (T58). |
| E-21 | **PARTLY** | P33 creates upkeep, corruption, rebuild, eviction (EN 5160–5169); the loader is P21a's (5020), `RecipientRules` P23d's (5082), `MailSendGate` P18's (5064). Built by no package: `MailCache.reset()` (EN 490); the label janitor (EN 2453); marking a detached account, deleting its cache after seven days and listing its unsent work (EN 436–440); `removeDownloadedMail` (a test only, EN 5168); `MailJournalPrivacyTests`. Fix: five *Creates* entries. |
| E-22 | **PARTLY** | An unknown label id reads `labels` once (EN 1582–1584); "Never a draft" (1782); the janitor acts on Gmail's count (2453–2455); five-minute rounding (2390). Remaining: a wake asserts `INBOX` "on its last message" (EN 2418). When that is an unsent reply, nothing is asserted, `Returned` is, and rule 5 (EN 2427) then cancels the snooze: the conversation never comes back. Fix: "the last message that is not a draft", there and in 6.1. |
| E-23 | **PARTLY**, small | The header list has the five (EN 1634–1637); the sent ids come from the response (2226); Sent is searched with a fallback (2239–2244). Remaining: the local outgoing row is retired on `Message-ID` equality alone (EN 2261, 2288), so if Gmail rewrites it the message shows twice. Fix: match the stored sent message id first. |
| E-24 | **PARTLY**, small | Invariant 1 (EN 68–75): a change's 404 "removes nothing; it queues a per-message read". Remaining: EN 1586 — a message that answers `notFound` when read in the pass that added it "is dropped as a job. It was never stored" — but EN 1571 made it a stub, and there is no second read. Fix: "read once more in the next pass". |
| E-25 | **PARTLY** | 17.2 is a 46-row table with switches, injections and a second client (EN 4404–4485); the three tools are described (4393–4402) and the recorder is C0's (4634). Remaining: rows 9, 15 and 43 are ASSUMED with no switch — 15 is what a history label record carries; no package creates the convergence check or the seeded run; the mailbox the fake is loaded with is undefined (T37). |
| E-26 | **PARTLY**, small | The probe is order 0, by `curl` (PLAN 48, 56–70), and gates P12b, P13a, P15a, P17, P18. Remaining: EN 5303 says every unsourced belief is "a row and a switch in 17.2"; the profile's `historyId` as a start, a record id as the next start, and label counts are rows without switches. |
| E-27 | **PARTLY** | Thread Sanitizer at every gate (EN 4391; PLAN 74). Remaining: `MAIL_FIXTURES` is set "in the Beta targets' Release configuration only", from P24 (EN 5208), while `ScreensOpenUITest` drives the `Banana` target — the Release walk (PLAN 106) never has a mailbox; both test bundles are iOS-only (`project.yml:330, 343`), so P21a's quarantine test "on the Mac test host" (EN 5030) and gate C's line for it (PLAN 88) cannot run. |
| E-28 | **CLOSED** | UX 128–136: the Mac's case applies `.measuresLayoutClass()` with a minimum width, and the first frame's arrangement is remembered. |
| E-29 | **PARTLY**, small | Seven of eight hold against the code now (UX 617–622; 3072; PLAN 106, 565; `MacRootView.swift:523` unchanged). Remaining, after the first release: UX 2634–2636 says an invitation's answer is "confirmed with a notice" "exactly as it behaves in Plan today" — true in the week view and ⌘K, not on the phone's event sheet. |
| E-30 | **PARTLY** | One web view package (PLAN 363–365); settings in order (PLAN 132); pictures one rule (PLAN 584); nothing launched plainly (UX 3167–3173). Remaining: UX 2216 "takes hours on a Mac" against the engine's "about two days"; the engine still budgets "30 changes a second for 10 s (a held key)" (EN 4269, 1832) against the UX's "acts once"; the badge mirror's stored form (T60); EN 3443 against UX 3015 (T42). |
| E-31 | **PARTLY** | The governor is its core; drafts upload on close, on backgrounding and before a send (EN 2146–2147). Remaining: the daily byte counter is per process, so three devices can take three times what it protects; each upload's new draft message returns through history and is fetched whole — nothing skips `uploaded_msg_id`. |
| E-32 | **PARTLY** | Engine: "One read of *n* rows replaces the first draft's sliding window" (EN 822–823); undo in memory (6.7); snooze and send later after the first release. Remaining: the UI keeps a 400-row window that slides by 200 (UX 1211–1214) and PLAN's U4a builds and tests it unconditionally (PLAN 280, 287), though the UX makes it P1's to decide; P14a's "every row of 6.1's table" (EN 4851) includes snooze and mute, whose label names are P19a's. |
| E-33 | **PARTLY** | A draft is `MailText` with fragments (EN 3695–3714); a body with a picture or table is `.designed` (5550); an unsent message's thread is `local:<draft id>` (3476). Remaining: no notification kind for a failed send (T22) and no package handles a notification's tap; a label renamed or recoloured elsewhere is seen only at the next reconcile (EN 1582 is the one trigger). |
| E-34 | **PARTLY**, small | 17.6 (EN 4537–4557): a Release run, ratios against recorded medians. Three absolutes remain against it: gate E "a four-letter p95 over 60 ms on the Simulator" (PLAN 90); P02 "under 1 s" (EN 4696); P20a "in under 5 ms" (EN 4958). |

"Small" means one or two lines of text and nothing an order-1 implementer meets.

**Totals, 7 blockers and 27 majors: 9 CLOSED · 25 PARTLY (7 of them small) · 0 NOT CLOSED.**

---

## 2. One contract: what still disagrees, as changes to apply

Sixty-eight changes: fifty-one for one contract (T1–T51), seventeen to package and plan
text (T52–T68). T1–T9 are the known leftover and its echoes. T10–T33 are places where the
UX or the plan uses something §13 does not give, or gives differently; for T10–T15 the contract
itself should change, and that must be settled before C0 freezes the file. T34–T51 are §13
against the rest of MAIL-ENGINE. T52–T68 come from the dry runs of section 3 and from what
remains of the majors.

### The known leftover: UX 12.6 and its echoes

All five requests are in §13: A1 `MailPlaceCount` and `splitCounts` (EN 3742, 3745); A2
`MailDraftPart`, `quoteAsText(in:)`, `changeIdentity(of:to:)`, `resource(_:forDraft:presentation:)`
(EN 3682, 3705–3706, 3956–3960); A3 `needsAnswer` (EN 3784–3786); A4 `alwaysShownPictureDomains()`,
`stopAlwaysShowingPictures(from:)` (EN 3981–3982); A5 `.heldRemoval(account:)` (EN 3506).

| # | File, place | Says | Should say |
|---|---|---|---|
| T1 | UX 2985–2998, 12.6 whole | "Asked of the architect: what the contract does not yet give a screen", A1–A5 each with an "Until then" workaround; then "Later … the command behind "Send now from this device"" | Heading: "What the contract gained at the screens' request". A1: tabs and chips draw `MailPlaces.splitCounts[id].total`. A2: the composer draws `draft.signature?.body` and `draft.quote?.body` as it draws a message's body and hands each `fragment` back untouched; "Edit as plain text" is `quoteAsText(in:)`; changing From is `changeIdentity(of:to:)`; their pictures come from `resource(_:forDraft:presentation:)`. A3: the badge is `MailBadgeCounts.needsAnswer`. A4: Settings lists `alwaysShownPictureDomains()` and removes one with `stopAlwaysShowingPictures(from:)`. A5: the removal card opens `MailScope(place: .heldRemoval(account:))`. A6: the engine's bounded burst (its 12.1). No "Until then" column. Later: the invitation's answer on its row; what the engine can still reverse after a relaunch. ("Send now from this device" is `answer(_, .sendFromHere)`, EN 3841.) |
| T2 | UX 216 | "(Asked of the contract: 12.6.)" | "(`MailPlaces.splitCounts`.)" |
| T3 | UX 1637 | "Drawing a fragment, and converting a quote to text, are asked of the contract (12.6)." | "Each block is a `MailDraftPart`: its `body` is drawn as a message's is, its `fragment` handed back untouched. "Edit as plain text" is `quoteAsText(in:)`." |
| T4 | UX 2505–2507 | "Asked of the engine (no contract change; its `PollRules`): for one minute … check every five seconds." | "The engine does this (its 12.1): for a minute after a check he asked for, and after Mail comes to the front, it checks every five seconds — twelve polls at most, only while Mail is on screen, not in Low Power Mode." |
| T5 | UX 2825 | "**In, if the engine agrees**" … "are asked of the engine (8.1). No contract change." | "**In**" … "are the engine's (8.1)." |
| T6 | UX 3307 | "Needs A2 of 12.6." | "Drawn from `MailDraftPart`." |
| T7 | UX 3326 | "What the contract does not yet give a screen is A1–A6 (12.6)." | "What the screens asked for after conforming, A1–A6, is in the contract (12.6)." |
| T8 | UX 2951, 2966 (12.3, 12.4, the composer rows) | Name `newDraft`, `draft`, `save`, `addAttachment`, `removeAttachment`, `rewriteAsText`, `discard`, `send`, `cancelSend`, `retrySend` | Add `quoteAsText(in:)`, `changeIdentity(of:to:)`, `resource(_:forDraft:presentation:)`; and, for the Mac's quit, `hasUnfinishedSends` and `finishSends(within:)`. |
| T9 | UX 2949, 2965, 2954, 2969 | Do not name `decideLink(_:in:)`, `alwaysShownPictureDomains()`, `stopAlwaysShowingPictures(from:)` | Add `decideLink(_:in:)` to the conversation's rows and the two picture calls to Settings' rows. |

### Where the contract itself should change — decide before C0

| # | File, place | Says | Should say |
|---|---|---|---|
| T10 | EN 3866 against UX 372 and case 17 (UX 561) | Contract: `enum Outcome { case stays(MailRow), leaves, unknown }`, and "leaves when the scope filters on exactly that flag and it is now false" (EN 3888). UX: "A row that no longer matches the list's filter is **kept**" | Either EN 3866: `case stays(MailRow), leaves(MailRow), unknown` — "`leaves` carries the row as changed, for a list that keeps it until the place is next entered (MAIL-UX T17)"; or UX 372 and 561: "…leaves, as `MailRowRules` decides; the cursor moves to its successor (T6)". The first keeps T17 and costs one line. |
| T11 | EN 3779, 4180, 2023–2024 against UX 2389–2391, 3123, PLAN 443 | UX: refused changes are listed "one row per action — "Move to Invoices · 3 conversations · that label no longer exists" — with **Retry** and **Discard**". Contract: `refusedChanges: Int`; Outbox lists "conversations with a refused change"; `retry`/`discard` take a `MailReceipt`, which a screen holds only from `MailEvent.refused` and loses at relaunch. EN 2023 names a `MailStatusValue.outbox` that does not exist. | EN 13.2 gains `struct MailRefusedChange: Identifiable, Equatable, Sendable { let receipt: MailReceipt; var change: MailChange; var count: Int; var failure: MailFailure; var account: String; var id: UInt64 { receipt.sequence } }`; EN 3779 becomes `var refused: [MailRefusedChange]`; EN 2023: "`MailStatusValue.refused` lists them, one per action"; EN 4180: "…and `failed`. Refused changes are not rows of the place: they are `status.value.refused`." UX 2389: "…listed in Outbox under that heading from `status.value.refused`, one row per action…". |
| T12 | EN 13.3 against UX 1780, 2310, PLAN 460, EN 2618 | UX: the last row of results is "Search Gmail for …", and "the "Search Gmail" row tries again". EN 2618: Gmail is asked "when he asks". The protocol has no call for asking. | EN 13.3, under *Fetching*: `func searchGmail(_ scope: MailScope)   // a .search scope: ask Gmail now; snapshot.remote follows`. |
| T13 | EN 3560, 3623 against UX 1038–1040, PLAN 218 | Contract: `case asking(MailQuestion.ID)`. UX draws three different lines for `asking` from the row alone; PLAN: "equal `MailRow`s make equal displays". | EN 3560 and 3623: `case asking(MailQuestion.ID, MailQuestion.Kind)`. (Or UX 1019: "`MailRowDisplay` takes the row and `status.value.questions`" — and then EN 4032 must list the row among status's observers, which it should not be.) |
| T14 | EN 3563 against UX 1044, 2370 | UX: the row says "Sending…" "with **Undo** … while the hold runs". Contract: `MailRowReason` has `waitingToSend, sending, checkingSent`; the hold is only `MailDelivery.held(until:)`, on the message. | EN 3563: add `case held(until: Date)` before `waitingToSend`. |
| T15 | EN 3543–3548 against UX 1609, EN 2650 | UX: people who have only written to him are "shown **by address, marked "from their mail"**"; EN 2650 says such an entry "is marked `fromTheirMail`". `MailPerson` has `isKnown` only, which guests and contacts also lack. | EN 3547: add `var fromTheirMail: Bool   // set only by people(matching:): known from mail he received, never written to`. |

### Where the UX or the plan should move to the contract

| # | File, place | Says | Should say |
|---|---|---|---|
| T16 | UX 2271, 2284, 2287, 2289; PLAN 279 | "`MailStatusText.line(_:now:)` is pure, over the contract's `MailStatusValue`"; row 9 needs an account's `health == .checking`; row 12 needs how long a send waited; row 14 says "· checking" for a check he did not ask for (`asked` is "a check he asked for", EN 3776) | "`MailStatusText.line(_ status:, accounts:, now:)`"; row 12 is raised by `MailEvent.sent` for a draft `MailSession` saw `.waitingForNetwork` for over a minute; row 14 drops "· checking". |
| T17 | EN 3777, 4917; PLAN 87, 310; UX 574 | Gate B: "10 `E` = 10 list deliveries, 0 status changes". `MailStatusValue.waitingChanges` has no stated meaning; counted naively it changes on the first `E`. | EN 3777, comment: "changes not yet at Gmail that have waited longer than the delivery debounce's five seconds, or any while offline". The gate lines then hold. |
| T18 | EN 2606–2607 against EN 3733–3736; EN 3735 against EN 5559 | "Matching order … and the order shown are two fields of `MailSplit`" — it has `id, name, query`. "nil for the built-in three" — and "the built-in splits are queries". | EN 2606: "The order shown is the order of `MailPlaces.splits` and of the array given to `saveSplits`. Matching order is the engine's and is not a field: custom splits in shown order, then Calendar, then Important, then Other (MAIL-UX 2.3)." EN 5559: "the built-in three are the engine's rules, with `query` nil". |
| T19 | EN 2287 | "`MailDelivery.sending`, `.sent`" | "`MailDelivery.sending`, then `.checking` while the Sent check runs; once it is sent the message has no `delivery`". |
| T20 | UX 2553 (G14) | "The UI logs through the engine's journal seam" — `MailJournal` is not in the contract and `MailSource` has no accessor; naming it breaks invariant 32. | "The UI logs counts and milliseconds through `MailUILog`, a closure `MailSession` is given at wiring (P24); it names no engine type." |
| T21 | EN 3474–3478 against UX 879, 1368, 1410, 1639 | "Open in Gmail" and "Copy link" are in the first release; `MailReference` (EN 4205) is named and never declared, and no call returns an address. | EN 3477, add: `var gmailURL: URL?   // https://mail.google.com/mail/u/<account>/#all/<thread>; nil for a local thread`. |
| T22 | EN 4122, 4138–4146 against UX 2466, 2096 | UX: a "Failed send" notification "posted by the engine", and the notification choice is "the screens' own" setting. Engine: kinds are `newMail, summary, backInInbox, waitingToSend`; `NotifyRules` reads the choice (EN 3396) but `MailSettings` has no accessor for it. | EN 4122: add `sendFailed`. EN 4138: add `var notifyFor: MailNotifySetting { get }` (`firstSplit`, `inbox`, `off`). UX 2096: the notification choice is one of the engine's fields, added by P24. |
| T23 | UX 1654; EN 4000–4006 | "31 MB · Gmail's limit is 25 MB" — the contract's limit is on `encodedBytes`, 35 MiB (EN 3712), and is not in `MailTuning`. | EN 4005: add `static let maxEncodedBytes = 35 * 1_048_576`. UX 1654: "over when `draft.encodedBytes` exceeds `MailTuning.maxEncodedBytes`; the words say "about 25 MB of attachments"". |
| T24 | UX 1696 | "A composer nothing was typed into leaves no draft." — `newDraft` is "durable before this returns" (EN 3948). | "A composer nothing was typed into discards its draft on close (`discard(_:)`, with no undo entry)." |
| T25 | UX 1701–1715 (6.3.9) | Nothing about a save that fails. | Add: "On `MailEvent.draftNotSaved`, and when `addAttachment` returns nil, the composer shows "Not saved — this iPhone is full" until a save succeeds (the contract's 13.3)." |
| T26 | UX 1919 | "(`newestIsMine`)" in the snooze picker, as if on the row | "from `conversation(id)`'s `newestIsMine`; not offered with several targets". |
| T27 | UX 2399 and 7.6's table | Treats "late" as a scheduled message only, after the first release | Add to 7.6: "`sendLate(_, since:)` — a message he sent more than 24 hours ago that had not gone: "Not sent yet · waiting since …", with **Send now** and **Keep as a draft**." It is in the first release (EN 2266–2268). |
| T28 | UX 428, 455–459 | Undo of a send "in one turn"; two different toasts for two undo failures | "Undo of a send awaits `cancelSend`, a few milliseconds, then reopens the composer." One toast when `undo` returns `count` 0. |
| T29 | UX 1459–1460 | Every tapped link is handed with "the words shown and whether it was a picture" to `MailLinkRules.decide` | "A link in a text body calls `MailLinkRules.decide(url:shownText:shownIsImage:)`; a link in a designed body awaits `decideLink(_:in:)`, because the web view reports only the address." |
| T30 | UX 221–222 | ""Waiting on his answer" is: … and the engine's other open questions" | "…a send that failed for good and the open questions about a send. A held removal and lost changes raise a card, not the badge." |
| T31 | UX 2545, 2979 against EN 2595 | UX keeps recent searches in `UserDefaults` (`mailRecentSearches`). Engine: "The typed text is never written to `ShellState`, the journal or `UserDefaults` (P-20)." | One must move; it is a privacy ruling. Either UX: "recent searches are kept in memory for the session"; or EN 2595 drops `UserDefaults` and says who clears them. |
| T32 | UX 2084 | "on an iPhone or iPad … newest 4 GB" | "…the newest 4 GB on an iPhone, 8 GB on an iPad" (EN 3260, PLAN 589). |
| T33 | UX 51; 1391; 3027; 3085; 1731; 6.2.5 | Places omit Inbox, Important, Muted and the held-removal list; block kinds omit `rule`; `noreply`; "Outbox 3" while six fixtures land there by EN 4180; "Back to 12 Aug here"; no drawing for `MailBodyState.preparing` or `.tooLarge` | Add the four places; add `rule`; `noReply`; count the Outbox fixtures by the contract's rule; "23,117 of 100,412 searched here" (`MailCoverage`); one line each for the two body states. |

### §13 against the rest of MAIL-ENGINE

| # | Place | Says | Should say |
|---|---|---|---|
| T34 | EN 2544 | `.operator(name:)` | `.operatorName(String)`, as EN 3861; and at EN 3862: "`range` is in UTF-16 units". |
| T35 | EN 2622 | "marked `fromGmail`" | "marked `fromGmailSearch`" |
| T36 | EN 3463, 4075 | "(`#if DEBUG`)" | "(`#if DEBUG \|\| MAIL_FIXTURES`)", as EN 4629 and PLAN 192. |
| T37 | EN 4075–4078 | The fixture mailbox "builds a `FakeGmail` state — accounts, labels, messages as Gmail `messages.get` JSON, drafts, a history — from the fixture files under `BananaTests/Fixtures/Mail/`" | As EN 4629–4631: "holds the mailbox as Gmail wire JSON in Swift literals — no file is read, because the app's routes need it and `BananaTests/Fixtures` is not in the app — and `MailFixtureMailbox+Fake.swift` (P10a) loads it into `FakeGmail`." Then the missing definition: section 3, C0 question 5. |
| T38 | EN 3454 against EN 4627 | "from 13.2–13.4 verbatim" / "13.2, 13.3 and the types of 3.4, verbatim" | Both: "13.2 and 13.3 — which include `MailAccountState` and `MailAccessGap`, with the text of 3.4". |
| T39 | EN 3865–3868, 3874–3876; EN 3452 | `enum MailRowRules { … static func apply(…) -> Outcome }` and `enum MailLinkRules { static func decide(…) -> MailLinkDecision }` inside the "verbatim" text: a function with no body does not compile, and their bodies are in `M/MailRowRules.swift` (C0) and `M/MailLinkRules.swift` (P20b, order 3). | In the contract file: `enum MailRowRules { enum Outcome … }` and `enum MailLinkRules {}`. Below the block: "`apply` is added by extension in `M/MailRowRules.swift` (C0); `decide` in `M/MailLinkRules.swift` (P20b). Until P20b, `decideLink` answers `.refuse`." |
| T40 | EN 3899 | "(`MailRowRulesAgreementTests`, in C0's contract suite)" | "(`MailRowRulesAgreementTests`, created by P05 — the first package to have both)", as EN 4719. |
| T41 | EN 4487–4488 | "as a directory, once (P01a)" | "(C0)", as EN 4620 and 4640. |
| T42 | EN 3443 | "an audit route with a mail screen runs on the fixture source (13.6)" | "…runs on the fixture mailbox: the real engine over the fake by default, `MailFixtureSource` under `--mail-source memory` (MAIL-UX 13.1)". |
| T43 | EN 4187 against EN 3915 | "or the last snapshot a feed for that scope delivered" (100 rows or more) / "Up to 50 rows" | EN 4187: "…or the first `MailTuning.firstPageRows` rows of the last snapshot…" |
| T44 | EN 4196 | "never a draft's text, a subject, a query or an address" — `MailScope.account` and `MailConversationID.text` hold his account's address and are stored | "…or anyone's address but his own accounts'"; the marker test leaves the account addresses unmarked. |
| T45 | EN 3746 | "// inbox, drafts, snoozed, outbox" | "// every mailbox", as EN 5736. |
| T46 | EN 4032–4033 | "**No shell, tab bar or list container observes it** — the status line and the foot card do." | Add: "…and the alert cards; the list's empty area reads `store` and `questions` through them (promise 8; MAIL-UX 12.3)". |
| T47 | EN 3816 against EN 4141, UX 1676, 2095 | `MailSendOptions.hold: TimeInterval` is passed by the UI; the length is the engine's synced setting (`undoSendSeconds`), which no screen can read | EN 3816: `var hold: TimeInterval?   // nil: the setting's hold; 0: Send now`. |
| T48 | EN 5543 | "(the UX says 5,000)" | Delete. |
| T49 | EN 140–141, invariant 12 | "each writer checkpoints when idle" | "the writer checkpoints between pieces of work, never inside one (4.2)". EN 585–586 says "never wait for idle either". |
| T50 | EN 4561–4563, 4577 | `xcodegen generate` listed before `tools/mail-lock acquire`; "one build at a time in this tree" | The order of T56; the comment: "one landing or regeneration at a time; ordinary private builds do not take the lock". |
| T51 | EN 1696, 2147 | "Settings keeps "Remove mail that Gmail no longer has""; a draft uploads "when the composer closes" — no call in 13.3 says either | EN 13.3: `answer(_, .remove)` later is "Settings re-raises the `removalHeld` question"; the upload needs no call (it follows `save` when the composer's model is released) — say so in 13.3's table. |

---

## 3. Dry runs: C0, P01a, P02, U0′

### C0 — the contract, the fixture mailbox, the contract tests (EN 4624–4654; PLAN 22, 43–45)

What I would have to guess:

1. **Which declarations the file holds.** T38 and T39 above. Also the types of 13.6's block:
   `MailDeviceRole`, `MailPower`, `MailBackgroundWork`, `RemoteImageSetting`,
   `MailNotificationContent`, `MailNotifier`, `MailSettings`, `MailEnvironment`. `MailClock` is
   given to P02 and `MailEnvironment` to P23a; the others to nobody, and P02's `MailWorkPace`
   needs the first two (P02 question 3).
2. **How a member that is not built yet is stubbed** (T52). It decides whether C0 also creates
   a file of defaults.
3. **`MailRowRules`' table** (EN 3882–3894). Five mailboxes are in no column: Important,
   Drafts, Snoozed, Outbox, Muted. "—" for `restore` and `notSpam` outside Trash and Spam:
   `stays` or `unknown`? "stays, labels changed" needs a `MailLabelRef` (name, colour) for an
   added label, and the rule is given only the row, the scope and label *ids*. Whether a
   `stays` sets `hasPendingChange`, and whether `snooze` sets `reason`, is not said.
4. **The suite cannot run in C0.** No source exists until U0′ and P23a; `makeSource()` "skips
   itself". C0's acceptance is `MailRowRulesTests` and the key-order test; `MailContractTests+Reads`
   is first executed by U0′. And `func makeSource() async -> MailSource` cannot test promise 6
   (sync-driven rate): the factory must also hand back a way to make a change "from elsewhere"
   and a clock. What the read tests compare a single source's rows *with* — expected keys per
   scope — is not given.
5. **The fixture mailbox has no definition**: no type, no field list, no name for the one
   value. It is consumed by U0′, P10a, P12a, P23a and every UI package.
   - Device-side state is not Gmail-level, yet MAIL-UX 13.2 asks for it: "Outbox 3"
     (`waiting`, `unsure-send`, `refused-change`), `failed-send`, `headers-only` ("the body has
     never been downloaded"), `attachments` ("on the device" / "that is not"). How a mailbox
     "defined once at Gmail's level" carries these, for both sources, is not said.
   - How `MailFixtureMailbox+<package>.swift` adds conversations to a value another file
     defines (PLAN 140) — there is no registry.
   - A 1.2 MB newsletter and a 2.4 MB PDF "in Swift literals"; presumably built at run time.
   - C0's bulk builder (`mailbox(conversations: 5_200)`) and P09a's `MailSynthetic` (EN 4821):
     two generators, or one?
   - T36, T37.
6. **`tools/mail-lock`** is specified as "a directory under `.build/`, made atomically; it
   waits" (EN 4616). Not given: the directory's name; what `release` does when another package
   holds it; how a lock whose holder died is recovered; a `status`; exit codes; whether a
   mid-work `xcodegen generate` needs the full build before release. No test is listed for it.
7. **"The contract file compiles alone (a test target check…)"** (EN 4650) is not something
   XCTest can assert. It needs a named command, e.g. `xcrun swiftc -typecheck` on the one file.
8. **Size.** "≈ 900 lines": 13.2 and 13.3 alone are about 500 lines of declarations before
   initialisers; the mailbox is some forty named conversations as wire JSON, one of forty
   messages. It is two sittings: the contract, rules, identifiers, `project.yml` and the lock;
   then the mailbox and the suite (T63).

Against the repository:

- `BananaTests` has no `dependencies:` key today (`project.yml:341–344`); the others list
  `- package:` entries at 209, 322, 881, 952. C0 adds the key. Fine, but say so.
- When this pass began `git diff --stat` named eight files of someone else's uncommitted work,
  `project.yml` among them; they were committed during it (`a44c147`). The check "`git diff
  --stat` names only the files above" (EN 4653) holds only while nobody else has work in the
  tree, and it never sees C0's new files, which are untracked (T55).
- `.build/` exists and is ignored; `tools/` has no `mail-lock`, no `perf-gate.sh`, no
  `perf-routes.d/` yet. The directory entries work only once each folder holds a Swift file —
  C0 creates one in each. GRDB 7.11.1 and SwiftSoup 2.13.9 exist (the reuse review fetched both).
- PLAN's per-package check 5 (PLAN 107) names "the journal privacy test; the forbidden-API
  test". `MailForbiddenAPITests` is created by P20a (EN 4952); `MailJournalPrivacyTests` by no
  package (EN 4362 describes it; P24 only "adds the same assertion over the real files"). Not
  runnable for any order-1 package (T57).

### P01a — account types (EN 4658–4664)

1. `M/MailAccountRules.swift (3.4)`: 3.4's block declares `MailAccountState` and
   `MailAccessGap` as well, and the contract file already has them (EN 3717). A verbatim copy
   redeclares both (T53).
2. `MailScopes.parse("")`: nil or the empty set? It decides whether an empty `scope` field
   marks a working account `.withdrawn` (EN 396–397). The test list says only "of nil, empty
   and a space-separated list".
3. Nothing else. The types compile from Foundation alone; no existing file changes; the
   acceptance commands exist (EN 4558–4577) once T50 is fixed. `GoogleTokenMinter.swift` is in
   the test target (`project.yml`), as EN 4496 says.

### P02 — the stores' foundation (EN 4666–4698)

1. **`MailWriterWork` is not defined** (two mentions: EN 4679, 4862). The loop must fold thirty
   submissions into one transaction (EN 4693), so the type has to be mergeable; its shape is
   the seam P14b builds on.
2. **`MailChangeSink` is not defined** (one mention, EN 4680), and what it carries,
   `MailStoreChange`, is declared in Appendix A, whose file P05 creates — after P02.
3. **`MailWorkPace.current(role: MailDeviceRole, power: MailPower, …)`** (EN 1215): both types
   are in 13.6's block, whose file is P23a's.
4. **Migrators.** "`DatabaseMigrator`s registered empty for later packages to add to"
   (EN 4676). `open(_ directories:)` takes no migrations, and a later package may not edit
   `MailStores.swift`. How P06a's `v1` reaches the migrator is not said.
5. **Checkpoints.** Invariant 12 says "when idle"; 4.2 says not (T49). `TRUNCATE` "on
   backgrounding and quit" — the call P24 makes is not named.
6. `MailJournal` (EN 4303–4306) uses `MailSignpost`, declared nowhere.
7. "`FileProtectionType` read back from `index.sqlite-wal`" (EN 4687): tests run on a
   Simulator, which does not enforce protection classes and may not report them. What the test
   asserts there is not said.
8. PLAN's check 2 (benchmarks through `--verify-mail-bench`) does not exist until P09a; P02's
   own performance line is an XCTest (EN 4696). Check 5 as for C0.

### U0′ — the fixture source and the session (PLAN 191–205; UX 3238)

1. **Every member of `MailSource` must exist in U0′** for the type to conform — fifty-four —
   while only C0, P03a and P05 exist: no `OutboxRules`, no `ReplyRules`, no preparer, no
   tokenizer. What each unbuilt member returns is said for `MailEngine` (EN 4797) and not for
   this source; `newDraft` and `createLabel` return non-optional values. And T52.
2. **May a file in `Pure/` name engine-internal types?** UX 2911–2913: such a file "names only
   Foundation, the contract, and app files the test target already compiles". Invariant 32
   (EN 176–177) says the same of every UI model. `MailFixtureSource` must name
   `ThreadSummaryRules`, `ViewMembershipRules`, `MessageFacts` and the wire models (T59).
3. **No pure mapping from a summary to a `MailRow`.** The engine decodes SQL columns into a
   row (EN 4177). U0′ writes its own mapping of people, labels, date, key and reason; only the
   suite, at P23a, shows whether the two agree.
4. **The built-in splits.** P05's split match "is a closure until P08a" (EN 4717), which is
   order 5. U0′ and P23a each need the Important, Calendar and Other rules, and the fixture's
   VIP split (`from:@northwind.example`), in order 1 (T61).
5. **"Accepted on the real engine … UI tests pass on both"** (UX 3210–3213) cannot apply to
   U0′: the engine arrives with P23a. The plan's own line (PLAN 203) says "on both sources"
   too.
6. C0 questions 4 and 5 land here: U0′ is the first to run the suite and the first to read the
   mailbox.

### Working in one tree: the holes (EN 4608–4620; PLAN 113–155)

1. **A stub cannot be replaced from another file.** P23a's `MailEngine.swift` holds "a stub"
   for every member it does not implement; P23b then creates `MailEngine+Commands.swift` with
   `apply`. Two declarations of one method in one type do not compile, and P23b may not edit
   P23a's file. The same for `MailFixtureSource` (T52).
2. **Edits to existing files are outside the guard.** `#if MAIL_WIP_<package>` wraps a new
   file "whole". U1a edits seven existing files; a half-made edit to `RootView.swift` stops
   every build. Say: an existing file is edited only under the lock, at landing (T56).
3. **The lock** — C0 question 6, and T50.
4. **"Landing" is not a commit.** Nothing in the three documents says a landed package is
   committed. Without it, the tree accumulates everyone's changes, a review cannot see one
   package, and no `git` check can be an acceptance test. The tree held eight such files for
   most of this pass.
5. **Lists that later packages add to** have no mechanism: the fixture mailbox's
   conversations, the stores' migrations, the benchmark's lines, the route parser's states.
   An extension can add a member; it cannot add to a list another file enumerates.

Changes for this section:

| # | File, place | Says | Should say |
|---|---|---|---|
| T52 | EN 4796–4798; PLAN 139, 147; UX 3214–3217 | "every member this slice does not implement is a stub … listed in the file's header"; later slices "add `MailEngine+….swift` files" | C0 also creates `M/MailSource+NotYet.swift`: one `extension MailSource` giving every requirement a default that returns the value in a new "Until built" column of 13.3's table (`[]`, `nil`, `.notOnDevice`, `.refuse`, a receipt with `count: 0`, `.failed`, …). A source implements a member by declaring it in its own file; nothing is edited. A test at gate F asserts no default is reached by either source. `MailEngine.swift` and `MailFixtureSource.swift` hold no stubs. |
| T53 | EN 4659, 372 | "`M/MailAccountRules.swift` (3.4)" | "…`enum MailAccountRules` only; `MailAccountState` and `MailAccessGap` are in the contract file (C0)". And for the tests: "`MailScopes.parse` of nil or an empty field is nil — unknown". |
| T54 | EN 4673–4683, 5872 | `submit(_ work: MailWriterWork)`, "`afterCommit` delivery to a `MailChangeSink`", `open(_ directories:)`, `MailWorkPace` | Give the two as Swift: `protocol MailWriterWork { func run(intent: Database?, index: Database) throws -> MailStoreChange; func absorbing(_ next: MailWriterWork) -> MailWriterWork? }` (or the shape meant) and `protocol MailChangeSink: AnyObject { func committed(_ change: MailStoreChange) }`. Move `MailStoreChange` from Appendix A's file to `M/MailWriter.swift` (P02). P02 also creates `M/MailDevice.swift` with `MailDeviceRole` and `MailPower`; P23a's `MailEnvironment.swift` does not redeclare them. `static func open(_ directories:, migrations: MailMigrations)`, with `struct MailMigrations { var index, blobs, search: DatabaseMigrator }`, built by whoever opens. Name the backgrounding call: `func truncateCheckpoint() async`. Declare `MailSignpost`. |
| T55 | EN 4652–4653 | "`git diff --stat` names only the files above" | "`git status --short`, compared with the one taken when the lock was acquired, shows only the files above" — and T56's commit. |
| T56 | EN 4613–4620; PLAN 115–119 | Guard; lock "held for `xcodegen generate`, for removing the guards, and for the full … build that follows; then released" | Add: (a) "An existing file is edited only under the lock, in the landing itself." (b) "Landing: acquire; remove the guards and make the edits to existing files; `xcodegen generate`; build iOS, Mac and `BananaTests`; **commit**; release. If the build fails: put the guards back, revert the edits, release." (c) "A mid-work `xcodegen generate` (a new guarded file) takes the lock for the generation only." (d) The lock: `.build/mail.lock/` holding `owner` (package, host, pid, time); `acquire` polls every 5 s and prints the owner; `release` refuses if the owner differs; `status`; `break <package>` only when the owner's pid is gone. |
| T57 | PLAN 107, 110–111 | "Thread Sanitizer over the mail tests; the journal privacy test; the forbidden-API test" | "…each from the package that creates it: `MailForbiddenAPITests` from P20a; `MailJournalPrivacyTests` from P23d" — and EN 5078's *Creates* gains `T/MailJournalPrivacyTests.swift`. |
| T58 | PLAN 86; EN 4795–4805 | Gate A needs benchmarks `activate` and `firstPage`; P09a is "After P06a" and P23a creates no benchmark | EN 4802: P23a also creates `A/MailBenchVerification+Engine.swift` (`activate`, `firstPage`). |
| T59 | UX 2911–2913; EN 176–177; PLAN 192–193 | A pure file "names only Foundation, the contract, and app files" | Add: "The one exception is `Pure/Testing/MailFixtureSource*.swift`, which also names the engine's pure rules and wire models (P03a, P05), so that both sources run the same rules." PLAN 203: "on both sources, from P23a". |
| T60 | EN 3433–3436; PLAN 258, 271 | U1a reads "Mail's two numbers from the engine's mirror" in `ActionBadges.swift`; the mirror is P23a's `MailBadgeMirror`, later in the order, and its stored form is not given | EN 3786: `MailBadgeCounts` gains `static let mirrorKey = "mailBadge"` and `static func mirrored(in: UserDefaults) -> MailBadgeCounts?` (its JSON), in the contract file, so U1a reads it before P23a writes it. |
| T61 | EN 4717; PLAN 23 | "a split's match is a closure until P08a" | "P05 also ships the three built-in matches as pure functions (Important: `IMPORTANT`; Calendar: `hasInvite`; Other: the rest), used by both sources from order 1. A custom split is empty until P08a; the fixture's VIP split is checked from gate E." |
| T62 | PLAN 129; EN 5204–5206 | "`MacRootView.swift`, the Mac app delegate" | The Mac app has no app delegate (no `NSApplicationDelegate` under `Banana/` or `BananaMac/`). Name the file that creates it and the package (U5 uses it first), and add `BananaApp.swift` to U5's line for the adaptor. |
| T63 | EN 4624; PLAN 22 | "C0 … ≈ 900 lines" | Two packages: **C0a** — the contract file, `MailSource+NotYet.swift`, `MailRowRules`, `MailIdentifiers`, `project.yml`, `tools/mail-lock`; **C0b** — the mailbox and the suite, after T37's definition. P01a and P02 need only C0a. |
| T64 | EN 5845–5852, 4716, 1273 | Appendix A's file, created by P05, names `GmailFormat` (declared in 5.1, P10a's file) and `MIMEStructure` (P03b, order 3) | "P03a declares `GmailFormat` and the value `MIMEStructure` in `GmailWire.swift`; P03b keeps the extraction; P10a does not redeclare `GmailFormat`." |
| T65 | EN 1328, 1411, 4770 | `GmailSession.init(… governor: MailQuotaGovernor …)`; `QuotaLane` declared in 5.2 | "`governor: MailQuotaGoverning`"; "`QuotaLane` is declared in `M/MailQuotaGoverning.swift` (P10a)". |
| T66 | EN 1592–1593, 4801; PLAN 139 | A pass's report is "a value, not a callback", returned to the loop in P23a's file; P15a, P19a and P25 must react to it and may not edit that file | Name one registry file every slice edits under the lock — `M/MailEngine+Slices.swift`, in PLAN's table — holding the pass consumers, the migrations (T54), the benchmark lines and the fixture mailbox's parts. This is the general answer to hole 5. |
| T67 | EN 4795–5130 | No package implements `setWantsMail`, `requestPermission`, `forgetPermission`, `storageUsed`, `removeDownloadedMail`, `saveSplits` | P24 creates `M/MailEngine+Accounts.swift` (the first five; `removeDownloadedMail` over P33's primitive); P27 creates `saveSplits` in `M/MailEngine+Splits.swift`. |
| T68 | EN 4844–4846, 4596 | `MailIntentStore` "exposes only typed operations" — all for `label_intent` — and its queue is private | P14a's list gains the operations later packages need and may not add: draft rows (insert, update, mark discarded, remove a day later), `send_log` (append, prune at 90 days), questions (raise, settle), `notify_mark` (set). |

---

## 4. The plan

**The order is sound in outline** — it is the merged order, with the splits — and these things
in order 1 lean on something later:

| What | Needs | Scheduled |
|---|---|---|
| P02's `MailWriter` and `MailWorkPace` | `MailStoreChange` (P05's file); `MailDeviceRole`, `MailPower` (P23a's file) | Later in order 1 (T54) |
| P05's `MailEngineTypes.swift` (Appendix A) | `GmailFormat`; `MIMEStructure` | P10a, later in order 1; P03b, order 3 (T64) |
| P10a's `GmailSession` | `MailQuotaGovernor`; `QuotaLane` | P11, order 6 (T65) |
| P14a's tests, "every row of 6.1's table" (order 2) | The snooze and mute label names | P19a, after the first release — say those rows produce nothing until then |
| U0′ and P23a showing "the first split" (UX 3022) | The built-in split rules | P08a, order 5 (T61) |
| The fixture's VIP split on the engine, "the same rows" at gate A | `MailQueryRules.matches` | P08a, order 5 (T61) |
| U1a's badge | The mirror's key and form | P23a (T60) |
| Gate A's `activate` and `firstPage` benchmarks | A package that writes them | None (T58) |
| PLAN's check 5 for every package | `MailForbiddenAPITests`; `MailJournalPrivacyTests` | P20a, order 2; no package (T57) |
| U5's and P24's "Mac app delegate" | A file that does not exist | Unassigned (T62) |

**Are the gates runnable?**

- The builds, Thread Sanitizer and the contract suite: yes, with the commands of EN 17.7.
- "The whole-app performance audit against P0′": not yet. `tools/perf-gate.sh`,
  `tools/perf-routes.d/` and the P0′ run are order-0 items whose owner is "App" (PLAN 46–47) —
  no package, no implementer. The script is still at `docs/design/mail-working/perf/perf-gate.sh`.
  Give the three to a named order-0 package.
- Gate A is also held by prototype P1, whose Mac half needs the owner at his Mac (PLAN 49,
  608). Engine packages through P23a do not wait for it; U4a and the gate do.
- Gate C blocks on "a stored attachment on the Mac without its quarantine" (PLAN 88), tested
  "on the Mac test host" (EN 5030). There is no Mac test target: both bundles are iOS
  (`project.yml:330, 343`). Either a Mac check is named (a `--verify-…` route) or the line cannot
  be run.
- Per-package check 4, "`ScreensOpenUITest` in Release on the iPad" (PLAN 106): on a Simulator
  it cannot show the stack overflow it exists for, a device install is not allowed, and before
  P24 a Release build has no fixture mailbox, so Mail's rows are never drawn in it (E-27).
- The order-0 whole-app fixes were landing while this was written (`a44c147`, during the pass):
  they are done outside any lock, which is fine only until C0 creates one.

**What still needs the owner before it can be built**

| Needs | For | State |
|---|---|---|
| Approval of GRDB 7.11.1, SwiftSoup 2.13.9, the tracker list (PLAN 604) | C0 | The coordinator is proceeding on the branch. P02 cannot be written the other way; the tracker list is not needed until P20a. |
| A test account and the read probe (PLAN 48) | P10a's defaults; hard gates at P12b, P13a | Not blocking: P10a is built on switches. |
| His time at the Mac for P1 and P2 (PLAN 49–50) | U4a, gate A; U5 | Blocks the first screen's gate, not the engine. |
| Decision 16, the Mac first (PLAN 597) | Whether P4 and decisions 1 and 2 move to order 0 | Assumed as recommended. |
| Decisions 6 and 7 (PLAN 587–588) | P01b; order 6 | Not before order 6. |
| T31, recent searches | U11 | A privacy ruling between the two documents. |

Nothing else in orders 0 and 1 waits on him.
