# Mail design review — engineering

Reviewed 5 Oct 2026: `docs/design/MAIL-ENGINE.md` (all 3,465 lines), `docs/design/MAIL-UX.md`
(§0–§3, §5.2, §6.1, §12–§15 read in full; §4–§11 swept for reliance on the engine and for claims
about the code), `research/integration-map.md`, `research/gmail-api.md`, and the code the designs
plug into. Nothing in the worktree was edited, built or launched.

"EN n" is a line of MAIL-ENGINE.md, "UX n" a line of MAIL-UX.md, "D n" a line of
`research/gmail-api.md`. Code paths are relative to the worktree.

**Counts: 7 BLOCKER · 27 MAJOR · 9 MINOR.**

How things were checked:
- Code claims: read against the files named, with `grep -n`.
- The directory entry under `BananaTests`: `xcodegen` 2.46.0, run only on copies under
  `scratchpad/review/xcodegen-check/` (results in E-1 and under "Verified claims").
- Gmail facts: the engine's sections 5–8 against the dossier. Nothing was checked against a live
  mailbox; where a statement about real Gmail is a belief, it says so.
- `xcodebuild` was not run, so nothing here is a compile result. Compile failures below are read
  from the sources.

---

## Blockers

### E-1 · BLOCKER · P01 does not compile as written: `GoogleAccountCredential` is not in the test target

- **Where:** MAIL-ENGINE §17.3 (EN 2803–2806), §18 P01 (EN 2863–2882), §3.3 (EN 165–186).
- **Problem:** P01 lists `Banana/Model/GoogleAccountAccess.swift` under `BananaTests`. That file's
  protocol returns `[GoogleAccountCredential]`. The type is declared only in
  `Banana/Model/GoogleAccountStore.swift:9`, which `BananaTests` does not list. `BananaTests`
  compiles its listed sources directly (no `@testable import`), so the first test build after P01
  fails with an unknown type. P01 is "strictly first; alone" and "unblocks everything", and its own
  rules forbid adding anything to `project.yml` beyond the two entries it names.
- **Evidence:** EN 2804: "engine files may reference only types already in the test target:
  `GoogleAccountCredential`, `GoogleAccountAccess`, …". `project.yml:341–699` has no
  `GoogleAccountStore.swift` entry (`GoogleTokenMinter.swift`, `AppSupport.swift`,
  `DeviceRole.swift`, `ShellNavigation.swift`, `AppSection.swift`, `GuestDirectory.swift`,
  `CommandMenuDateParser.swift`, `CoalescingRun.swift`, `Shared/SnapshotPersistence.swift` are
  there). No file under `BananaTests/` names `GoogleAccountCredential`. The integration map's own
  "already listed" inventory (§10) does not include it either.
- **Smallest change that fixes it:** P01's `project.yml` edit gains a third entry,
  `- path: Banana/Model/GoogleAccountStore.swift` (Foundation and Security only; nothing in it
  runs unless called), and 17.3 says so. The directory entry itself works — see "Verified claims"
  — with one condition: `xcodegen` refuses the spec while `Banana/Model/Mail` does not exist
  ("Target "BananaTests" has a missing source directory"), so the entry and the first file must
  land together.

### E-2 · BLOCKER · Two contracts in one module: the first packages of the two plans collide, and no screen meets the real engine until the last package

- **Where:** MAIL-ENGINE §13 (EN 2337–2344), §17.1 (EN 2767), P23 (EN 3122–3139), Gate M4
  (EN 3194–3198), §22 "Names" (EN 3453–3457). MAIL-UX §12.1 (UX 2501–2517), §14 (UX 3153),
  U0 (UX 3198), U18 (UX 3406–3415).
- **Problem:** Each document declares its own UI-facing surface and its own fixture system, and
  each puts the join at the end. The engine plans "the screens … are built on the fixture engine"
  after M4 (28 packages). The UX plans 17 packages on `MailFixtureSource` and then U18, "the one
  place the two halves meet". Three consequences:
  1. *A compile failure on day one.* U0 creates `MailUIContract.swift` with "12.3 and 12.5
     verbatim", which declares `MailAccountState`, `MailStatus`, `MailProgress`,
     `MailConversation`, `MailEvent`, `MailTarget`, `MailReceipt`, `MailCount`. P01 — strictly
     first — creates `MailAccountRules.swift` with `enum MailAccountState` (EN 259). Both files
     are in the app module. Whichever lands second breaks every build.
  2. *The adapter is not thin.* E-8 lists 40 places where the two surfaces differ in name, shape,
     paging, ordering, units or meaning; in about twenty of them the engine offers nothing to map from.
     Several cannot be absorbed by an adapter (a split narrowed to one account; a filter set;
     totals; conversation observation; multi-label changes under one undo).
  3. *Seventeen UI packages are accepted against behaviour only the fixture has.* The fixture
     "carries out commands in memory"; the engine applies them through four files, a group
     commit, a 250 ms change notice and a sliding window. Rules T7, T8, T17, T18 and E2 are about
     exactly that timing.
- **Evidence:** UX 3153: "It runs on `MailFixtureSource`. Only U18 needs the engine." EN 3196:
  "After this the screens of MAIL-UX.md are built on the fixture engine". UX 2733 and EN 259 both
  declare `MailAccountState`. EN 3453: "there is one type, this document's" — the UX packages
  were not changed to match.
- **Smallest change that fixes it:** the requirement the owner intends, which nothing here makes
  infeasible. Concretely:
  - *One file, new first package (call it C0), before P05 and U0:* `Banana/Model/Mail/MailContract.swift`
    — the protocol (`MailSource`), every value type that crosses it with every field defined, and
    the pure row-level rule of E-3. It lives in `Mail/`, not `MailUI/`, because the UX's own rule
    is "Nothing in `Mail/` names anything in `MailUI/`" (UX 2507), so the engine could not conform
    to a protocol declared there. With it, `BananaTests/MailSourceContractTests.swift`: one
    abstract case (today planned for U18, UX 3413) run against every conforming source.
  - *MAIL-ENGINE changes:* §13 becomes that file's listing; `MailEngine` conforms to it; P23 is
    cut into slices delivered at each milestone (E-20); `MailFixtureEngine` (P23) and
    `MailFixtureFactory` (P09) take their mailbox from the one fixture definition; EN 3196–3198
    is replaced by "the screens connect at every milestone"; the missing calls of E-8 and E-9 are
    added.
  - *MAIL-UX changes:* §12.3 and §12.5 are replaced by a reference to the file; U0 stops creating
    a contract and creates the fixture mailbox and `MailFixtureSource` on the shared protocol; U18
    is deleted and its work becomes an acceptance line in every package: "the same routes and UI
    tests pass with `--mail-source engine` (the real `MailEngine` on a temporary directory, filled
    by `FakeGmail` from the fixture mailbox)"; §3.10, §6.1.7–6.1.8, §12.2 E2, §12.4 and §13.2 are
    brought in line with 12.7 (E-11).
  - *One fixture mailbox, defined at Gmail's level* (messages with headers and MIME), loaded into
    `FakeGmail`. `MailFixtureSource` derives its rows from the same definition by running the
    engine's pure rules (P05), so the two sources agree by construction. Today there would be
    three: UX `MailFixtures.swift`, engine `MailFixtureFactory`, `FakeGmail+Scenarios`.
  - *Keep both sources.* The Mac's offscreen snapshot views and the status-state gallery (UX 13.3:
    `quota-spent`, `held-removals`, `first-seconds`) need values at once and states a real engine
    reaches only slowly; those stay on the in-memory source. Interactive routes and every UI test
    run on the engine with the fake. Both sources are DEBUG-only in both documents, which is
    compatible.

### E-3 · BLOCKER · An action is "written before it is shown" and "shown before it is written"; nothing says what happens if the write fails; and the synchronous row update cannot be computed

- **Where:** MAIL-ENGINE invariant 4 (EN 73–75), §1 (EN 36–38), §6.1 (EN 1362–1364), §13.1
  (EN 2401–2409), §13.2 (EN 2459–2463), §4.4 page query (EN 631–636), `OutboxRules` (EN 1404),
  `MailReceipt` (EN 2395). MAIL-UX E2 (UX 2527–2531), §3.10 (UX 526–527), T22 (UX 375–378).
- **Problem:** three separate defects in the path every keypress takes.
  1. *Two orders.* Invariant 4: "Intent is written before it is shown." §13.1: "A command is
     accepted on the main thread and returns before any I/O … is applied to what is on screen".
     Invariants are "numbered so a review can check code against them"; P14's implementer builds
     the first, P23's the second.
  2. *No failure path.* `perform` "never throws and never waits". If the intent commit then fails
     (disk full, the `mustRefuseSaves` state of 4.10, `storeUnavailable`), the row has already
     left the screen. `MailEvent` has no case for it; the in-memory list of unwritten commands
     has no rule for dropping one. The outcome is either a silent loss or a row that returns with
     no explanation — the failure invariant 4 exists to prevent.
  3. *The feed cannot run the rules.* "`engine.perform` applies the action to every live feed's
     `rows` synchronously, using the same `OutboxRules` and `ViewMembershipRules` the store will
     use." Both take `[MessageFacts]`. A feed holds `MailThreadRow`s read by a query that selects
     thread columns only. No row-level rule is defined anywhere, so the implementer invents one,
     and it will disagree with the store's in exactly the cases that flash (a label view, a
     filter, Sent).
  Also, `MailReceipt.count` is a `let` returned "before any I/O", but for `MailTarget.view` the
  engine "resolves it on the writer". The count the toast and the selection header show ("1,204
  selected") cannot be known at return. And both documents implement the optimistic layer: the
  engine in the feed, the UX in `MailListProjection` ("`visible = snapshot + pending`"), which
  12.7 X4 conceded and §3.10/§12.6 still specify.
- **Evidence:** quotes above. EN 2459–2461; EN 1404 `assertions(for:messages:labelNames:)`;
  EN 2410: "The engine resolves it on the writer — the UI cannot enumerate what it has not
  loaded".
- **Smallest change that fixes it:** choose one place for the optimistic layer and one rule.
  The cheaper choice deletes engine code: keep the UX's E2 as written — the UI's projection lays
  its own commands over readings until `appliedThrough` reaches them — and drop the engine's
  synchronous feed edit and its "in-memory list of commands accepted but not yet written". Then:
  - Reword invariant 4: "An action is durable in `intent.sqlite` before any reading reports it
    (`appliedThrough`), before the index is touched, and before `first-page.json` can contain it."
  - Add `MailEvent.notSaved(MailReceipt)`; the projection drops that command and the toast says so.
  - Put the row-level rule in the contract file, pure: `MailRowRules.apply(_:to:in:) → .stays(row)
    | .leaves | .unknown`, with a test that it agrees with `ViewMembershipRules` over generated
    conversations. Both sources and the projection use it.
  - `MailReceipt.count` becomes exact for `.threads` and absent for `.view` until the first
    reading after it; add `count(of: MailTarget) async -> Int` for the selection header.

### E-4 · BLOCKER · One device can send a message twice

- **Where:** MAIL-ENGINE §7.4 S4 (EN 1686–1695), the walk-through (EN 1706–1709), invariant 7
  (EN 81–83), R3 and R4 (EN 3234–3235), P29 (EN 1746–1748), §6.2 (EN 1431–1432).
- **Problem:** after a timeout the engine reads the draft and concludes: "Still there → it was not
  sent → `ready`, retry with backoff." "Still there" means "not sent *yet*": the first request may
  still be executing at Gmail, or the read may lag the write (the engine itself forbids reading
  after a write to confirm, EN 1432, citing a 2–5 s lag). The retry is then a second `drafts.send`
  on the same draft id. What stops a second mail is Gmail spending a draft atomically — which the
  dossier calls an inference and the engine labels UNVERIFIED for two devices only. So invariant 7
  ("a draft id is sent at most once") is broken by the design's own retry path, R3's "only a person
  pressing Send twice within a second can reach it" is false, and R4's consequence ("—") is wrong:
  a replay that answers 2xx is a second message. The fake encodes "a second `sendDraft` → 404", so
  P18's tests cannot see any of this.
- **Evidence:** EN 1642–1645 labels the mechanism DOCUMENTED; D 374: "A 404 on replay is
  INFERENCE." EN 1708: "The request was made once." — untrue on the branch EN 1709 describes
  after a timeout.
- **Smallest change that fixes it:** in S4, "still there" alone never returns the draft to `ready`.
  It needs the draft present on three reads spanning at least two minutes from `sending_since`
  (the wait S4 step 3 already uses for the opposite case) *and* no `SENT` message with the
  `Message-ID` in the conversation; otherwise `needsDecision(.unconfirmed)`. State in 7.4 that a
  retry still rests on R3, widen R3 to "any retry after an ambiguous result", make W4 a gate for
  P18 rather than a later probe, and give the fake two modes: "send completes *n* calls after it
  answers an error" and "a replayed send succeeds", with a test that the engine sends one message
  under each.

### E-5 · BLOCKER · A returned conversation comes back again: on the same device as written, and from any device with a stale cache

- **Where:** MAIL-ENGINE §8.2 rules 1–5 (EN 1839–1862), the actions (EN 1864–1868), §8.3
  (EN 1875–1878), §6.5 step 2 (EN 1481), §6.8 (EN 1550–1555).
- **Problem:** two defects with one root — a wake is treated as something a person asked for.
  1. *On one device, as written.* Rule 1 wakes a conversation that has `Snoozed/<t>` with *t* past,
     no `Returned` and no `INBOX`. After a wake it has all three. He marks it Done in Banana:
     "Any action that takes a conversation out of the inbox also asserts `Returned` absent." The
     text does not say the action removes the snooze label, so the conversation now has
     `Snoozed/<t>`, no `Returned`, no `INBOX` — rule 1's condition — and returns after the next
     pass, every time. Rule 5 clears the labels and says it covers an archive made "here or in
     Gmail's app", but it needs `Returned` present, which that sentence has just removed; so it
     covers only Gmail's own apps. Snoozing a returned conversation again fails the same way: the
     old label is still there and already due.
  2. *Across devices, even with 1 fixed.* `due` runs "at launch and on coming to the foreground,
     *before* the network", on a cache that may be hours old, and turns what it finds into
     ordinary assertions. Delivery then follows the rule for a person's own actions: "delivered
     unless Gmail already agrees with it or its message is gone." Snoozed until 8:00; the Mac
     wakes it; he deals with it there at 8:05 and every Banana label is cleared. The phone is
     opened at 9:00 still showing the snooze label, no `Returned`, no `INBOX`. Rule 1 fires:
     `INBOX`, `Returned` and (D10) `UNREAD` present. The sync that follows shows all three absent
     at Gmail, so none is moot and all are sent. It is back in the inbox, unread, everywhere.
     `Returned` guards only a device that has already synced. The same holds for a device that
     was offline at the wake time, and for rule 6 (mute) after an un-mute elsewhere.
  The section's stated requirement was that "whichever device is awake can wake it without doing
  it twice".
- **Evidence:** EN 1867: "Any action that takes a conversation out of the inbox also asserts
  `Returned` absent." EN 1841: "A conversation has `Snoozed/<t>` with *t* ≤ now, no `Returned`,
  and no `INBOX`". EN 1875: "at launch and on coming to the foreground, *before* the network (so
  a conversation due while every device slept is back in the inbox the instant Banana opens — the
  overlay shows it, delivery follows)". EN 1550: "a pending assertion is delivered unless Gmail
  already agrees with it or its message is gone."
- **Smallest change that fixes it:** (1) every action that takes a conversation out of the inbox,
  and every new snooze, asserts all `Banana/Snoozed/*`, `Banana/Waiting/*` and `Returned` labels
  absent on its messages, in the same request. (2) Assertions produced by `due` are *derived*,
  not intent: mark them (`action_group.kind = 'due'`), show them through the overlay as now, and
  before delivery — which already follows a sync pass — run `due` again on the fresh state and
  delete every derived assertion it no longer produces. 6.8's rule then applies only to what a
  person did. Add three tests to P19: "woken, marked Done in Banana, not woken again"; "snoozed
  again after returning, stays snoozed"; and, with two engines, "woken and marked Done on A while
  B slept; B opens; B sends nothing". (P19's listed "woken, then archived elsewhere, is not woken
  again" covers only a B that has synced first.)

### E-6 · BLOCKER · Two races leave a message's labels wrong, and nothing corrects them until a drift check

- **Where:** MAIL-ENGINE §5.5 (EN 1235–1237, 1245–1252), §5.6 (EN 1290–1295), §5.3 step 4
  (EN 1146–1152), step 6 (EN 1156).
- **Problem:**
  1. *A late fetch overwrites newer history.* History records older than a message's stored
     `history_id` are skipped. The reverse guard is missing: "A message's label set from a fetch
     replaces what was stored." A fetch sent before a label change and written after the poll
     that applied the change puts the old labels back and the old `history_id` with them. The
     checkpoint has already passed the record, so nothing replays it. Both directions occur: a
     message that stays in the inbox after being archived elsewhere, and — the case §5.3 calls
     the worst — a message put back in the inbox elsewhere that is missing from it here. Mute
     (rule 6), which removes `INBOX` from a new reply on another device seconds after it arrives,
     makes this an ordinary event rather than a rare one.
  2. *A stale enumeration mark re-adds a label.* Step 4 applies "a mark with no `message_label`
     row" as an addition "at once". Marks can be hours old; fill "runs alongside from step 2 on".
     Mark at T0, archived elsewhere at T1, fetched at T2 (exact labels, `history_id` ≥ T1's
     record), apply at T3 re-adds `INBOX`; the replay from `enum_checkpoint` then skips T1's
     record because of the `history_id` guard.
  The text that covers a missing `historyId` is also wrong: "convergence still holds because whole
  passes commit together" (EN 1250) — the fill is not part of the pass.
- **Evidence:** EN 1294: "A message's label set from a fetch replaces what was stored." EN 1147:
  "A mark with no `message_label` row adds one. Positive evidence; applied at once." EN 1235:
  "unless the record's id is not greater than the message's stored `history_id`".
- **Smallest change that fixes it:** (1) a fetched label set is applied only when the response's
  `historyId` is not less than the stored `history_id`; otherwise the content is kept and the
  labels are left. If Gmail omits `historyId` in some format (R8), such a read sets content only
  and queues a `minimal` read. (2) In step 4, a mark is applied as an addition only for a message
  whose stored `history_id` is not greater than `enum_checkpoint`; the others go to
  `verify_queue`. Add both as tests, which needs the fake to delay a response while holding the
  snapshot taken when the request arrived (E-25).

### E-7 · BLOCKER · The parallel plans cannot run in one source tree

- **Where:** MAIL-ENGINE §18 rules (EN 2845–2852), "What can run together" (EN 3209–3224),
  §17.5 (EN 2820–2823). MAIL-UX §14 (UX 3157–3159, 3166–3169).
- **Problem:** both plans treat "different files" as "independent". Here they are not:
  - Every file under `Banana/` is compiled into four app targets by glob, and every file under
    `Banana/Model/Mail/` into `BananaTests` as well (confirmed with `xcodegen`). The `Banana`
    scheme builds the app for any test run. One half-written file anywhere stops every other
    implementer's build and test, in both documents' packages.
  - `xcodegen generate` rewrites the one git-ignored `Banana.xcodeproj` that every build reads.
    The engine tells each package to run it first.
  - One Simulator holds one installed `com.boris.banana`. UI tests and "looked at on an iPhone
    Simulator" from two packages replace each other's build.
  - The UX has each package edit `project.yml` (U0, U3, and every package with a pure file a test
    needs); the engine forbids anyone but P01 and P25 to. The UX's list of files edited by more
    than one package omits `project.yml`, `MacDebugSnapshotViews.swift` (seven packages),
    `MailSession.swift` (U0, U6, U9, U18), `MailFixtures.swift`/`MailFixtureSource.swift` (every
    package that adds a state or a route), `MailSection.swift`, and the route parsing.
  - Across the documents, nobody orders the packages that edit `BananaApp.swift` (U1, P24, P25,
    P26, P27, U18), `RootView.swift` (U1, P24, P25, P26), `MacRootView.swift` (U1, U5, P24),
    `AppSettings.swift` (U14, P24), `PerfWatchdog.swift` (P24, U18).
  - `pgrep -x xcodebuild && echo "another build is running"` says nothing about what to do next,
    and with packages "side by side" another build is always running.
- **Evidence:** EN 3223: "Packages on different branches of this graph create different files and
  share no seam." UX 3169: "Everything else after U4 can be built side by side." Target
  membership from the generated project: a file placed in `Banana/Model/Mail/` appears in the
  Sources phase of `Banana`, `BananaBeta`, `BananaMac`, `BananaMacBeta` and `BananaTests`.
- **Smallest change that fixes it:** one section, shared by both documents, "Working in one tree":
  1. A file that does not yet compile is wrapped whole in `#if MAIL_WIP_<package>`; its implementer
     builds with `OTHER_SWIFT_FLAGS='$(inherited) -D MAIL_WIP_<package>'` in a private derived-data
     path. Landing is removing the guard, and is one at a time (a lock directory under `.build/`),
     followed by a full iOS, Mac and `BananaTests` build before the lock is released.
  2. `xcodegen generate` only under the same lock (or into a private project directory:
     generation with `--project` outside the root succeeded here; whether that project builds was
     not tested).
  3. One Simulator device per implementer, named in the package brief.
  4. `Banana/Model/MailUI/Pure/` listed once under `BananaTests` as a directory, like `Mail/`, so
     no UX package edits `project.yml`.
  5. A single table of every shared file and the order of the packages that edit it, across both
     documents.
  With that, pure-rule packages (P03, P04, P05, P16, P20, P28; U3; the keymap table of U5) can
  overlap two or three at a time. Nothing that edits a shared file can.

---

## Major

### E-8 · MAJOR · The contract, line by line: where §12 of the UX and §13/§22 of the engine do not meet

- **Where:** MAIL-UX §12.3–12.5 (UX 2560–2907); MAIL-ENGINE §13 (EN 2346–2626), §4.4
  (EN 605–616), §22 (EN 3426–3465).
- **Problem:** forty differences. "Adapter" means a mechanical mapping is possible; "Gap" means the
  engine offers nothing to map from; "Conflict" means the two specify different behaviour.

| # | Subject | UX wants | Engine offers | Kind |
|---|---|---|---|---|
| 1 | Identity | `MailConversationID`, `MailMessageID`, `MailDraftID`, `MailAttachmentID` (UX 2562–2572) | `ThreadKey`, `MessageKey`, a `String` local id, `AttachmentRef` (undefined) (EN 2388–2389) | Adapter; not in §22's list of shared names |
| 2 | Scope | `MailScope{place, filters: Set, account}` (UX 2592–2596) | `MailViewKey` + one `MailFeedFilter` (EN 605–616, 2396) | Gap: no filter set; no account on `split`, `snoozed`, `waiting`, `muted`. The default screen cannot be narrowed to an account (UX 185, `⌃1…⌃9`) |
| 3 | Outbox, Drafts as places | `.mailbox(.outbox)`, `.mailbox(.drafts)` through `observeList`, with a cursor and a count (UX 2583) | "not views"; `outboxItems() async`, unobserved, unpaged (EN 619, 2371, 2576–2579); local unsent drafts are not in the Drafts view | Gap |
| 4 | Order | One key everywhere: `(group, sortDate, id)`, newest first (T1, UX 246–250; `MailOrderKey` UX 2575) | Per view: the newest message *with that label* (EN 718–721); Snoozed and Waiting soonest first (EN 641) | Conflict |
| 5 | Cursor | A value the UI can build, compare and store (`MailOrderKey`, Codable) | `MailCursor`, "opaque", never defined; its tie-break is `thread_pk` (EN 634), which 4.3 says never reaches the UI or `ShellState` (EN 462–465) | Conflict inside the engine; Gap |
| 6 | Paging | `observeList(scope, limit:)`, 100 then +100 to 5,000 (UX 2802) | A sliding window of at most 400 with `loadMore()` and `show(around:)` (EN 2445–2453) | Conflict (E-11) |
| 7 | Observation | Closures returning `MailObservation`, values as snapshots (UX 2794) | An `ObservableObject` with five `@Published` properties (EN 2441–2454) | Adapter |
| 8 | Conversation updates | `observeConversation` (UX 2827) | `conversation(_:) async` once; 13.4 says an open conversation "re-reads" but no change notice is exposed (EN 2366, 2549) | Gap |
| 9 | Rate | At most once a second per observation (E6, UX 2547) | At most every 500 ms; "twice a second" (EN 2544, invariant 13) | Units |
| 10 | Counts | `total` per list; a total per split "read or not"; Drafts, Snoozed, Outbox counts (UX 2633, 212–213, 2751–2752) | `unread` per feed and nothing else (EN 2448) | Gap |
| 11 | Places | `observePlaces`: splits, counts, labels by account as a tree (UX 2749–2755) | No read for labels, splits or sidebar counts | Gap |
| 12 | First page | `cachedFirstPage(scope)`, 30 rows, "never contains a change that has not been delivered dressed as fact" (E5) | `first-page.json`, 40 rows, "shows the overlay" (EN 967, 975) | Units; Conflict in wording (E-3 resolves it) |
| 13 | Bodies | Inside `MailConversation.messages[].body`, ready-made, `AttributedString` for native (UX 2641–2645, 2804) | A second call per message, `body(_:) async`, returning an HTML fragment; "native text … is built by the UI" (EN 2367, 2510–2515, 3428) | Conflict over who makes native text and when; a 40-message value re-delivered whole on every change |
| 14 | A body that is neither | A `.simple` message with an image, a table, or anything `MailNativeText` refuses "is drawn as web" (UX 3281; fixture `big-image`, UX 3076) | `document` exists only when `style == .styled` (EN 2511–2513); remote pictures come only through the web view's scheme handler | Gap |
| 15 | Row | `people` + `peopleTotal`; `labels` "the person's own only"; `reason: MailRowReason` (UX 2616–2628) | `senders` (six, no total); all labels; `outgoing`, `returned`, `hasDraft: Bool`, `delivery` (EN 2423–2438) | Adapter, except: "Draft · first line" needs the draft's text; "Couldn't apply · Done" needs the failed action's kind; "from the owner's Mac" needs another device's schedule — none is on the row |
| 16 | Back from snooze | "Back from snooze · set Mon" (UX 952; `backFromSnooze(setOn:)`) | `MailReturn` "when it was set" (EN 2434) — but the label carries only the wake time (EN 1811, 1813). When a snooze was set is stored nowhere | Gap |
| 17 | Changes | `MailChange` (UX 2871–2877) | `MailAction` (EN 1395–1400) | See 18–21 |
| 18 | Not done | `.notDone` | No action that asserts `INBOX` present except `notSpam`, `unsnooze` and undo | Gap |
| 19 | Labels | `.label(add: [..], remove: [..])`, one receipt | `.label(String, present:)`, one label per call | Conflict: several receipts, several undos |
| 20 | Move | "leave the inbox and the label being viewed" (UX 2875) | "that label present and `INBOX` absent" (EN 1383) | Conflict |
| 21 | If no reply | `.snooze(until:ifNoReply:)` hides the conversation; `MailDraft.remindIfNoReply` on a send (UX 2876, 2728, 1424) | `remind(ifNoReplyBy:)` labels the sent message and archives nothing (EN 1399, 1812); a separate `waiting` view; `send` has no such parameter (EN 2381) | Conflict; Gap |
| 22 | Drafts | `save(_ draft: MailDraft)` with `body: AttributedString`; `MailDraft.reply` is the UI's (UX 2843, 2913) | `newDraft(ComposeIntent) → MailDraftHandle` (both undefined); body is HTML; `ReplyRules` is the engine's (EN 2378, 1598–1608) | Conflict: two owners of who a reply goes to; who converts rich text to HTML and back is unassigned (E-33) |
| 23 | Draft commands | `discard → MailReceipt` (undoable), `retrySend`, `sendNow` (UX 2844–2849) | None of the three | Gap |
| 24 | Send | `send(draft, options)`; schedule in the draft | `send(localID:hold:at:thenDone:)` | Adapter |
| 25 | Check now | `status.asked`: `.running` then `.finished(new:at:)` (UX 2764, 2902) | `refresh()`; nothing reports a finished check or a count | Gap |
| 26 | Status | `MailStatusValue`: `unreachableSince`, `slowedSince`, `waitingSince`, `waitingMessages`, `downloads[].secondsLeft` (UX 2765–2774) | `MailStatus{accounts, badge, outbox, store}` + `MailProgress.byAccount` (EN 2558–2567); `rateLimited(until:)` not since; no "unreachable"; `BackfillProgress`, `OutboxSummary` undefined | Gap in five fields |
| 27 | Name clash | `MailProgress` = one attachment's fraction; `MailStatus` = a wrapper over `MailStatusValue` (UX 2780–2782) | `MailProgress` = backfill; `MailStatus` = four properties | Conflict; §22 says the engine's stand, the UX packages still use their own |
| 28 | Account state | Eight words (UX 2733–2736) | `MailAccountState` × `MailSyncHealth` | Adapter — but the UX has no words for `apiDisabled`, `domainPolicy`, `wrongAccount`, `store.unavailable(.newerVersion)` |
| 29 | Identities | `MailAccount.identities`, signature as `AttributedString` (UX 2707–2712, 2742) | `account.send_as` JSON in the index; no read | Gap |
| 30 | Attachments | `fetchAttachment`, `attachmentProgress(id)` (UX 2835, 2855) | `attachment(_:) → MailAttachmentHandle` (undefined) | Adapter once defined |
| 31 | Events | `sendFailed(…, MailSendFailure, subject:)`, events carry subjects (UX 2887–2892) | "Events carry ids and codes, not subjects"; `code: String`; plus `sendUnconfirmed`, which the UX enum lacks | Conflict |
| 32 | Search | A place: `observeList(.search(text))`, no debounce, 30 ms, a match total (UX 2803, 1518, 1971) | `search(scope:) → MailSearchSession` (both undefined); runs "150 ms after the last keystroke"; pages of 50, no total (EN 2369, 1963, 1960) | Gap; Conflict |
| 33 | Search targets | ⌘A in search results; "everything older than a week" as one action (UX 653, 790) | `MailTarget.view(MailViewKey, …)`; a search is not a view; no target by age | Gap |
| 34 | Splits | `saveSplits([MailSplit])`; a custom split may keep "the field's text" (UX 2862, 1548); built-in Important and Calendar have `query: nil` (UX 2746) | No write for splits; "not free text" (EN 1980); `MailQuery.Flag` has no "invitation" and no "from a list", so the two built-in splits cannot be expressed (EN 1930) | Gap; Conflict |
| 35 | Suggestions | `suggestions(for:)`: person, label, split | `recipients(matching:limit:)` only | Adapter once 11 exists |
| 36 | Create label | `createLabel(named:account:) → MailLabelRef` | Described in §22 (EN 3461) but absent from §13.1 | Gap |
| 37 | Unsubscribe | `unsubscribe(id) → result`, synchronous (UX 2864) | A field on the conversation; a network POST "when the person asks"; no command (EN 3190) | Gap |
| 38 | Housekeeping | `setWantsMail`, `requestPermission`, `storageUsed`, `removeDownloadedMail` | None on `MailEngine`; the setting is `AppSettings`, consent is `GoogleAccountAccess` | Gap; the adapter needs objects the pure folder may not name |
| 39 | Restore | `MailShellState.top`, `.cursor` are conversation ids (UX 543–544) | `show(around: MailCursor?)` (EN 2453) | Gap: no cursor for a conversation id |
| 40 | Notifications | Words in the UX; Important only by default; a tap lands on the conversation; "Send now" as an action (UX 2113–2119, 1780) | `NotifyRules` takes no split; identifiers only; Archive and Mark read (EN 2296–2307) | Conflict; Gap |

- **Evidence:** each row cites the lines of both documents. §22 (EN 3426–3451) answers X1–X17 and
  R1–R14; it does not address rows 2, 3, 8, 10, 11, 14, 18–21, 23, 25, 29, 33, 37 or 39.
- **Smallest change that fixes it:** resolve each row in the contract file of E-2 before P05 and U0
  start. Rows 2, 4, 5, 6, 10, 13, 19, 21, 22 and 32 are design decisions, not renames; they need
  both authors and, for 21 and 34, the owner.

### E-9 · MAJOR · States the person must answer have no way to be answered

- **Where:** MAIL-ENGINE invariant 3 (EN 70–72), §7.4 S4/S6 (EN 1693–1704), §6.9 (EN 1559–1563),
  §7.6 (EN 1765–1769), §13.1 (EN 2376–2385). MAIL-UX 7.5–7.7 (UX 2016, 2042–2061), 6.5.5 (UX 1668).
- **Problem:** the engine holds work until "the person says so" in five places and gives the UI no
  call for any of them: releasing or refusing held removals; the three answers to an unconfirmed
  send; "Send now" for a late one; Retry and Discard for a refused change; "Send from here
  instead". The UX draws all five as buttons. An account in `.held(removals:)` therefore stays
  held, and a draft in `needsDecision` stays there, for ever. The UX's own `MailDelivery` and
  `MailEvent` also have no case for "not sure it was sent", though R6 asks for it.
- **Evidence:** EN 2658: "Remove them here too?" with no command; UX 2016: "Remove here · Keep for
  now". EN 1694: "*Open Sent*, *Send again* and *Keep as a draft*"; `MailEngine` has `send` and
  `cancelSend` only.
- **Smallest change that fixes it:** add to the contract `answer(_ question: MailQuestion, _ choice:)`
  covering held removals, unconfirmed, late and changed-elsewhere; `retry(_ receipt:)` and
  `discard(_ receipt:)` for refused changes; `takeOverSend(localID:)`. Add `.unconfirmed` to the
  delivery type and the fixture.

### E-10 · MAJOR · Option A changes the calendar's behaviour as soon as anything calls it

- **Where:** MAIL-ENGINE §3.2 table (EN 149–156), §3.3 (EN 207–234), invariant 19 (EN 117–118),
  P01 (EN 2863–2886).
- **Problem:** "every existing call compiles to the same code" is true and is the wrong test. The
  seam shares mutable, published state with a daily driver. Calendar paths whose behaviour can
  change once P24 wires mail in:
  1. **A password change signs the calendar out.** A refresh token is revoked when "the user
     changes their password and the token contains Gmail scopes" (D 665). Today's token carries
     only calendar scopes and survives. After consent there is one token for both, so the account
     lands in `accountsNeedingReconnect`, the source is degraded and its meetings stop refreshing
     until he signs in again. A Workspace admin restricting Gmail (`admin_policy_enforced`, D 668)
     does the same.
  2. **"Allow Mail access" runs the whole calendar reconnect.** `reconnect` sets `isWorking`,
     clears the calendar's `lastError` (`GoogleCalendarService.swift:386–387`), replaces the synced
     keychain credential (`accept` → `upsert`, :1677), republishes the cross-device account hint
     (:1681), and reloads every account's calendar list (:401 → :1790–1849), which rewrites
     `accountsWithUnreadableCalendars` and prunes the event cache and its disk copy.
  3. **Cancelling Google's sheet writes an error into the calendar's Settings.** `reconnect`
     catches `CancellationError` (:402). GoogleSignIn reports a cancel as its own error, which
     that clause does not match, so it falls to `lastError = friendlyMessage(...)` (:404). (Read
     from the code, not run.)
  4. **Minting at mail's cadence.** `accessToken(for:)` has no single flight (:2079–2099): two
     Gmail requests and a calendar fetch at expiry are three mints. Each success runs
     `accountsNeedingReconnect.remove` (:2097) on a `@Published` set, which publishes
     `GoogleCalendarService` whether or not anything was removed. A rejection sets the
     calendar-wide `lastError` (:2109) at a moment mail's poll chose.
  5. **`googleDropAccessToken`** after a Gmail 401 discards the token the calendar was using.
  6. **`googleAdoptCredentialUpgrades`** assigns `accounts` (published) and swaps a refresh token
     under running calendar code.
  None of this is caught by "reading the diff", and the file is outside `BananaTests`.
- **Evidence:** EN 153: "every existing call compiles to the same code, because the new parameters
  default to today's values and nothing passes them yet". EN 232: "Nothing calls the new
  parameters or methods until the wiring package (P24)."
- **Smallest change that fixes it:** (a) say in 3.3 which of these are accepted, and put item 1 to
  the owner as a decision beside D1; (b) have `googleRequestScopes` call `interactiveSignIn(hint:scopes:)`
  and `accept` itself — it is in the same file and may use private members — returning its outcome
  from the errors thrown, and not touching `isWorking` or `lastError`; (c) one in-flight mint per
  account; (d) guard `accountsNeedingReconnect.remove` with `contains`; (e) split P01 (E-12).

### E-11 · MAJOR · The UX still specifies what its own 12.7 gave up

- **Where:** MAIL-UX 12.7 X4, X5, X7 (UX 2933–2936) against §3.10 (UX 526–527), §6.1.7–6.1.8
  (UX 1100, 1124–1125), §12.2 E2 (UX 2527–2531), §12.4 (UX 2802), §12.5 `save` (UX 2843), §12.6
  (UX 2911–2913), §13.2 (UX 3059–3060), U3 and U4 (UX 3233–3248).
- **Problem:** 12.7 says "This document" moves on X4 (the feed applies changes) and X5 ("the
  5,000-row foot goes"), and the engine on X7. The rest of the document was not changed. An
  implementer of U3 builds `MailListProjection` as the owner of pending changes; of U4, a list
  that grows "100 at a time" to a 5,000-row foot and is tested on 5,200 rows; of U9, a composer
  that builds a `MailDraft` value and calls `save`. Each will be rebuilt at U18.
- **Evidence:** UX 2934: "A sliding window is better; the 5,000-row foot goes." UX 1100: "The list
  has reached 5,000 rows | "Older conversations are in search."" UX 1124: "Rows are loaded 100 at
  a time". UX 2971: "Say so before U6, U4 and U9 start."
- **Smallest change that fixes it:** apply 12.7's own rulings to the eight places listed, after
  E-3 and E-32 decide which way X4 and X5 finally go.

### E-12 · MAJOR · P01 is first, touches the daily driver, and is used by nothing until P24

- **Where:** MAIL-ENGINE P01 (EN 2863–2886), EN 232.
- **Problem:** the riskiest edit in the plan — an extension inside `GoogleCalendarService.swift`
  and a change to the token minter — lands before any code can exercise it, is verified "by hand
  at M4", and sits in the calendar for the whole build. Nothing before P24 needs it: every engine
  test and every fixture route uses a stand-in for `GoogleAccountAccess`.
- **Evidence:** EN 2876: "`googleRequestScopes` tells *declined* from *cancelled* by whether the
  stored refresh token changed — stated in a comment, exercised by hand at M4."
- **Smallest change that fixes it:** split it. **P01a**, first: `GoogleAccountAccess.swift` (the
  protocol and value types), `GoogleScopes`, `MailAccountRules`, the three `project.yml` entries
  of E-1, their tests; no existing Swift file changes. **P01b**, immediately before P24: the five
  line edits, the extension, the minter change, the `--google-window` before-and-after, and the
  first live consent, reviewed together.

### E-13 · MAJOR · P01, built from the document alone: what has to be guessed

- **Where:** MAIL-ENGINE §3.3 (EN 216–230), P01 (EN 2863–2882).
- **Problem:**
  1. *The outcome of `googleRequestScopes`.* It "calls `reconnect(email:additionalScopes:)` and
     reads the outcome from the stored credential's `grantedScopes` and `lastError`". `reconnect`
     swallows every error into `lastError`, a sentence for a person. `.noWindow`,
     `.differentAccount(String)` and `.failed(String)` can only be told apart by matching English
     text ("That signed in as …", :394).
  2. *The error mapping is wrong.* "mapping its `notConnected` to `.needsSignIn` when the id is in
     `accountsNeedingReconnect`, else `.transport`". `notConnected` is also thrown for a missing
     client id (:2083–2086) and an empty refresh token (:2087–2092): neither is transport, and
     `.notConfigured` is never produced. Real transport failures arrive as
     `GoogleTokenMinter.MintError.transport` (`GoogleTokenMinter.swift:59–75`), which the mapping
     does not mention.
  3. *`GoogleTokenMinterScopeTests` cannot be written.* "the minter reads `scope` and tolerates its
     absence": `RefreshResponse` is `private` (:115) and `mint` calls `URLSession.shared` (:58).
     There is no seam, and tests may not touch the network.
  4. *"The whole-app gate against the baseline"* names no script, no command, no baseline file and
     no tolerance. A `perf-gate.sh` exists only in this session's scratchpad.
  5. *No change signal.* The protocol exposes two properties and no way to learn that either
     changed; 3.6 ("the account disappears … Mail marks it detached") depends on noticing.
- **Evidence:** as quoted; line numbers are `Banana/Model/GoogleCalendarService.swift` and
  `Banana/Model/GoogleTokenMinter.swift`.
- **Smallest change that fixes it:** E-10 (b) removes 1. Give the mapping all four cases. Add to
  the minter a pure `static func token(from data: Data, now: Date) -> MintedToken?` and test that.
  Move the gate script into `tools/` and name it. Add `googleAccountsChanged: AnyPublisher<Void, Never>`
  or state that the engine re-reads both properties at each pass.

### E-14 · MAJOR · Seventy-four types are named and never defined, and the shared ones have no owner

- **Where:** MAIL-ENGINE throughout; §13 (EN 2346–2626) and the rule files; §18 "Creates" lists.
- **Problem:** types used in the document's code and defined in neither document nor the code.
  Those private to one package are that implementer's to shape. These are not:
  - *The UI builds on them:* `MailCursor`, `MailSearchSession`, `MailSearchScope`,
    `MailDraftHandle`, `ComposeIntent`, `MailAttachmentHandle`, `AttachmentRef`, `MailOutboxItem`,
    `MailOutgoingState`, `MailSender`, `MailLabelChip`, `MailReturn`, `MailRecipient`, `BodyState`,
    `RemoteImageSummary`, `MailAccountStatus`, `MailBadge`, `OutboxSummary`, `StoreHealth`,
    `BackfillProgress`, `MailAccessGap`, `MailInvite`, `MailUnsubscribeOption`, `MailReference`.
  - *Two engine packages must agree on them:* `Assertion`, `StoredAssertion`, `LabelBatch`,
    `EchoedIntent`, `LabelChange`, `NewStub`, `StoredMessageState`, `EnumMark`, `StoredMembership`,
    `QueuedMessage`, `FetchCall`, `QuotaLane`, `MailEnvironment`, `MIMESource`, `SendQuestion`,
    and every `Gmail…` model in `GmailAPI` (P03 writes them "every field optional", P10 writes the
    protocol that returns them, and only 5.1 names them).
  - *No package creates them:* `MailThreadRow`, `MailConversation`, `MailMessageSummary`,
    `MailBodyResult`, `MailStoreChange`, `MailTarget`, `MailCount`, `MessageKey`. P06's reader
    returns rows and every write returns a `MailStoreChange` whose `origin` holds a `MailReceipt`
    — a type P23 creates, eight packages later.
- **Evidence:** a scan of every Swift block for type names with no `struct`/`enum`/`class`/
  `protocol` declaration in either document or under `Banana/` and `Shared/`: 74 names. P05's
  list (EN 2928–2929) holds `ThreadKey`, `MessageFacts`, `ThreadSummary`, the flag sets,
  `MailViewKey`, `SystemView`, `SplitDefinition`, `ViewMembership` and nothing else.
- **Smallest change that fixes it:** the contract file of E-2 defines the first and third groups.
  A second small file in P05, `M/MailEngineTypes.swift`, defines the second group field by field.

### E-15 · MAJOR · P02, built from the document alone

- **Where:** MAIL-ENGINE §4.2 (EN 412–458), P02 (EN 2893–2906).
- **Problem:**
  1. `MailDatabaseQueue.run { connection in … }` is one queue, one connection. 4.2 puts two
     connections (`writer.index`, `writer.intent`) on `mail.writer`. Which the block receives, and
     how a block reaches both, is not said.
  2. `MailClock` is "real and manual" and nothing more. It is the seam for every timed behaviour
     later: the governor's refill, the 1.5 s delivery wait, backoff, the undo hold, the three
     verify checks, the ten-minute settle, the poll, "after `suspend()` … zero scheduled work".
     If P02 ships only `now`, six later packages each invent a timer.
  3. Who checkpoints "when it goes idle and its log is over 8 MB", who writes the unclean-exit
     marker, and who runs `quick_check` "at most once a day" belong to no package (E-21).
  4. Per-file open options are needed (`auto_vacuum=INCREMENTAL` before the first table;
     `synchronous=FULL` with `fullfsync` for intent) and are described only as prose.
  5. "1,000 one-row commits under 1 s" does not say in which synchronous mode. With full fsync at
     the document's own 3 ms it is 3 s.
- **Evidence:** EN 416: "`MailDatabaseQueue.run { connection in … }`". EN 422–423: `writer.index` and
  `writer.intent` both on `mail.writer`. EN 2899: "`M/MailClock.swift` (real and manual)". EN 2905:
  "1,000 one-row commits under 1 s"; EN 450: "A full-fsync commit costs 2.98 ms p50".
- **Smallest change that fixes it:** give `MailDatabaseQueue` and `MailClock` as Swift signatures
  (`now`, `sleep(until:)`, `schedule(at:_:) -> Cancellable`, and a manual clock that reports what
  is scheduled); name the owner of each maintenance task; state the mode for the performance line.

### E-16 · MAJOR · P06 is two packages, and its scope is "whatever later packages need"

- **Where:** MAIL-ENGINE P06 (EN 2938–2951), P14 (EN 3022–3028), rule at EN 2847–2849.
- **Problem:** `MailIndexWriter` must hold "every write primitive later packages need" — for
  P12, P13, P14, P15 and P19, none of which exists. Later packages may not edit its file and must
  extend it from their own, which cannot reach its private connection and statement cache unless
  P06 guesses what to leave internal. Overlay rows are in P06's list *and* P14 creates
  `MailIndexWriter+Overlay.swift`. Not specified: the encoding of `view.key`; when view rows are
  created; `MailThreadFlags` bit positions; how `local:` label rows are replaced. The plan tests
  assert `EXPLAIN QUERY PLAN` *text*, which changes between SQLite releases (this Mac has 3.51;
  the Simulator runtime has its own).
- **Evidence:** EN 2940: "every write primitive later packages need". EN 2942: "overlay rows".
  EN 3027: "`M/MailIndexWriter+Overlay.swift`".
- **Smallest change that fixes it:** P06a — schema, storing messages and labels, summaries and
  views, the page, count and conversation reads. P06b — overlay, enumeration marks, the verify
  queue, the repair oracle. List each primitive as a signature. Declare the connection and
  statement cache `internal` by rule. Assert plans by absence ("no `SCAN`, no `TEMP B-TREE`").

### E-17 · MAJOR · P12, built from the document alone

- **Where:** MAIL-ENGINE §5.5 (EN 1206–1255), §5.1 (EN 1003–1027), §5.2 lanes (EN 1075–1083),
  invariant 2 (EN 66–69), P12 (EN 3000–3010).
- **Problem:**
  1. *Three transaction sizes.* "Apply each page in one index transaction"; "A pass of ten pages
     or fewer is applied as one transaction"; and 4.2's "A sync batch is at most 50 messages per
     transaction". A page can hold 500 records.
  2. *The checkpoint against the zero-write poll.* The checkpoint moves "after the final page, to
     the response's own `historyId`", while P12 and §15 require "a pass with nothing new makes one
     call and no commit". If the mailbox's `historyId` advances with nothing to report
     (the dossier does not settle it), moving it makes every poll commit; not moving it lets a
     quiet account's checkpoint age into a 404 and a reconcile.
  3. *A label change for an unknown message* "makes a stub with those labels": the labels in the
     change, or the message's label list in the record? Is it fetched?
  4. *A label id nobody here has seen.* `labels` is read only in reconcile's handshake (E-22).
  5. *Lanes.* Every call "is made in a lane". `GmailAPI` has no lane parameter and
     `GovernedGmailAPI` is undescribed.
  6. *Invariant 2.* "The first call with a newly minted token is `users.getProfile`." Tokens are
     below `GmailAPI`; nothing above it knows a mint happened. Which layer checks, and how the
     fake — which has no tokens — tests it, is not said. P12's test covers the handshake only.
  7. *The echo.* `HistoryPlan.echoes` is consumed by P15, which may not edit P12's files; P12 is
     built beside P14, before either knows the other's types. No hook is described.
- **Evidence:** EN 1212–1214: "Apply each page in one index transaction … A pass of ten pages or
  fewer is applied as one transaction". EN 437: "A sync batch is at most 50 messages per
  transaction". EN 3010: "a pass with nothing new makes one call and no commit". EN 1237: "A change
  to a message not known here makes a stub with those labels." EN 1075: "Every call is made in a
  lane". EN 67: "The first call with a newly minted token is `users.getProfile`".
- **Smallest change that fixes it:** state one rule for transactions (per page, split at 50
  messages, the checkpoint moving only with the page's last piece); hold the checkpoint in memory
  and write it when records were applied or five minutes have passed; define the stub and fetch
  for unknown messages; add `lane:` to the calls or a `func inLane(_:) -> GmailAPI`; put the
  identity check in `GovernedGmailAPI`, given a `tokenGeneration(account)` from the transport,
  with a test on a fake transport; define `protocol MailSyncObserver { func passDidApply(_: HistoryPlan, account:) }`
  in P12.

### E-18 · MAJOR · P15, built from the document alone

- **Where:** MAIL-ENGINE §6.5 (EN 1472–1510), §6.7 (EN 1528–1542), invariant 5 (EN 76–78),
  P14–P15 (EN 3022–3042).
- **Problem:**
  1. `modify(ids:add:remove:)` returns `Void`, yet for nine or fewer ids it is several
     `messages.modify` calls "in one HTTP batch", where each part succeeds or fails alone. P15's
     test "a 404 drops only that message's assertion" needs a result per id.
  2. "if Gmail says the name exists" has no `GmailError` case (the dossier does not give the
     status; a 409 is likely) and no row in 6.5's table. Two devices snoozing to the same minute
     reach it routinely.
  3. `MailIntentStore` has "**no** delete, reset or truncate API", while delivered assertions are
     "(row deleted)", groups are pruned to fifty, and `send_log` is "kept 90 days". Read
     literally, the store can never shrink.
  4. "Delivery waits 1.5 s after the last action (5 s at most)", backoff and the ten-minute settle
     need the clock of E-15.
  5. `undo(_ receipt:)` takes a `MailReceipt` made in memory by P23; `action_group` is keyed by a
     text `group_id` and kept "for a day". Nothing maps one to the other, and after a relaunch
     the UI holds no receipts — the stored groups cannot be reached (E-32).
  6. What `batchModify` does with one missing id is UNVERIFIED, so the fake's answer is the
     implementer's choice and the test proves that choice.
- **Evidence:** EN 1014: `func modify(…) async throws`, no result. EN 1484: "9 or fewer messages:
  `messages.modify` each (5 units) — in one HTTP batch". EN 1478: "if Gmail says the name exists".
  EN 3023: "with **no** delete, reset or truncate API". EN 1416: "(row deleted)". EN 1508:
  "`batchModify`'s behaviour with one missing id among many is UNVERIFIED".
- **Smallest change that fixes it:** `modify` returns `[GmailResult<Void>]`; add
  `GmailError.conflict`; reword invariant 5 as "no API removes the file, a table, or rows by
  anything but their key"; state the receipt-to-group mapping; fix the fake's `batchModify`
  behaviour in the table of E-25 and mark the test provisional until W1.

### E-19 · MAJOR · U4, built from the document alone

- **Where:** MAIL-UX U4 (UX 3239–3249), §6.1 (UX 922–1125), §13.3 (UX 3111–3143).
- **Problem:**
  1. The paging model is specified twice (E-11).
  2. "`--mail-state` for every list state in 13.3" is 26 states. `prefix` is U5's, `mail-off` and
     `needs-permission` are U14's, `late-asking`, `hint`, `old-mail-offer` and the alert queue are
     U15's. Which U4 owns is not said.
  3. The list's controls open things that do not exist yet: the leading swipe "opens the picker"
     (U8), the selection bar's Label and More (U10, U12), Search (U11), Compose (U9), Places
     (U10), the day pane (U13). Whether U4 ships them dead, hidden or stubbed is not said.
  4. "Held scroll through `--mail-place all` (5,200 rows) with no hitch longer than a frame on a
     phone" names no tool and needs a device; packages are judged on Simulators.
  5. `MailSelectUITest` is a name with no assertion.
  6. `MailStatusText.swift` is pure and tested, so it needs a `project.yml` entry; U4's "Touches"
     has none.
  7. Every state route needs new code in `MailFixtureSource.swift` and `MailFixtures.swift`,
     which U0 created and the same-file list does not mention.
  8. On the Mac the list would draw the phone's arrangement (E-28).
- **Evidence:** UX 3246: "`--mail-state` for every list state in 13.3". UX 3248: "no hitch longer
  than a frame on a phone". UX 1084: a full leading swipe "opens the picker". UX 3247:
  "`MailSelectUITest`." and nothing more. UX 3245: "Touches" lists `ToastCenter.swift`,
  `ToastCenterTests` and `MacDebugSnapshotViews.swift` only.
- **Smallest change that fixes it:** split U4 into the list read-only with its cursor (U4a),
  actions, swipes and selection (U4b), and the state lines (with U15). List the states each owns.
  State that a control whose target is unbuilt is drawn and disabled. Replace the hitch line with
  a measurable one (a render-count probe, a signpost).

### E-20 · MAJOR · The whole UI-facing engine is one package, the twenty-third

- **Where:** MAIL-ENGINE P23 (EN 3122–3139), §13 (EN 2335–2626).
- **Problem:** P23 creates the engine object, feeds with windowing and filters, receipts and the
  layer that lays unwritten commands over readings, the change hub with per-subscriber merging and
  two throttles, status, progress, events, the first-paint file, the badge mirror, the poll rules,
  the fixture engine, and six test classes including a privacy test that runs "a whole first
  sync, a search, a triage burst, a draft and a send". It is estimated at 1,400 lines, depends on
  five late packages, and has the least written about it. It is also the only code the screens
  ever touch. The pure folder additionally has no stated seam for what it cannot name:
  `beginBackgroundTask` for a send finishing (7.5), local notifications for wakes, unsent and late
  messages (7.5, 7.6, 8.3), the synced "Mail on" setting, the network kind. `MailEnvironment` is
  a comment: "clock, online publisher, device role, settings".
- **Evidence:** EN 3122: "≈ 1,400 lines. After P13, P15, P18, P19, P21." EN 3123–3129: eleven source
  files and six test classes. EN 2353: "environment: MailEnvironment) // clock, online publisher,
  device role, settings". EN 1735: "the send runs under a background assertion
  (`beginBackgroundTask`)" — UIKit, which invariant 17 keeps out of the folder.
- **Smallest change that fixes it:** slice it by milestone: reads (feed, conversation
  observation, hub, a minimal status) after P06a; commands and receipts after P15; drafts and send
  after P18; search after P08; then first paint, badge, events and the privacy test. Define
  `MailEnvironment` as a struct of closures and publishers, including
  `beginBackgroundWork(_ name:) -> () -> Void` and a `MailNotifier` protocol.

### E-21 · MAJOR · Designed in detail, built by no package

- **Where:** MAIL-ENGINE §4.9–4.10 (EN 919–961), §4.1 (EN 375), §10.5 (EN 2174–2179), §9.5
  (EN 2022–2025), §7.5 (EN 1741–1745), §8.2 (EN 1870–1871), §3.6 (EN 334–343), §4.2 (EN 454–455).
- **Problem:** none of these appears in any "Creates" list: corruption detection and the four
  per-file recoveries, including the intent salvage; rebuilding the index from blobs;
  `MailCache.reset()`; the unclean-exit marker and the daily `quick_check`; idle and backgrounding
  checkpoints; `MailRemoteImageLoader`; `RecipientRules`; `MailSendGate`; the label janitor; the
  seven-day deletion of a detached account's cache; "Remove downloaded mail from this device".
  17.1 promises "corruption handling with deliberately damaged files" in the store's tests; no
  package's test list has it.
- **Evidence:** a comparison of every component the text names with the 177 files of §18.
- **Smallest change that fixes it:** one package, "Store upkeep", after P14: `MailCache`,
  corruption and rebuild, checkpoints and checks, account removal. Add the loader to P21, the
  recipient rule to P06b, the gate to P18, the janitor to P19.

### E-22 · MAJOR · Timed labels: three more ways they fail

- **Where:** MAIL-ENGINE §5.3 step 1 (EN 1131–1135), §5.5 (EN 1235–1237), §8.1–8.2
  (EN 1806–1871), §6.1 (EN 1382), §8.3 (EN 1880–1882).
- **Problem:**
  1. *A label made on another device is not known here.* `labels` is read in reconcile's
     handshake and on a name clash, nowhere else, and history has no records for label creation
     (D 131). Device B receives `labelsAdded` with an id it has no row for; it cannot read
     `Banana/Snoozed/<t>` from it, so it does not know the conversation is snoozed or when to
     wake it, until the weekly reconcile. This also breaks ordinary labels made in Gmail.
  2. *A draft cannot take a label* ("You can't apply labels to draft messages", D 308). Snooze
     asserts its label "on the conversation's messages"; a wake asserts `INBOX` "on its last
     message". A conversation holding an unsent reply answers 400, which 6.5 files as *failed*;
     in a `batchModify` the whole group fails.
  3. *The janitor deletes on local evidence.* It deletes labels "which no message carries",
     judged from the cache, and `labels.delete` removes the label from every message (D 323). A
     cache that is behind deletes a live snooze — invariant 1's failure, by another route.
  Also unaddressed: Gmail's 10,000-label limit against one label per distinct minute; each device
  schedules its own "Back in your inbox" notification and only a running device can remove it, so
  a snooze cancelled or handled elsewhere still rings.
- **Evidence:** EN 1133: "`labels`: upsert every label", inside reconcile's handshake; the only other
  call is EN 1479. D 131 lists four history types, none for labels. D 308: "You can't apply labels
  to draft messages." EN 1864: "on the conversation's messages". EN 1870: "delete
  `Banana/Snoozed/*` and `Banana/Waiting/*` labels whose time is over a day past and which no
  message carries". D 323: `labels.delete` "removes it from any messages and threads".
- **Smallest change that fixes it:** on any history record naming an unknown label id, call
  `labels` once in that pass before applying it. `OutboxRules` never asserts on a message with
  `DRAFT`, and a wake takes the last message without it. The janitor first reads
  `label(id)`'s counts (1 unit) and deletes only at zero. Round snooze times to five minutes.
  A wake notification is removed by any pass that finds the label gone.

### E-23 · MAJOR · A scheduled message cannot pass its own check, and the send's identity rests on a header Gmail may replace

- **Where:** MAIL-ENGINE §5.6 header list (EN 1288–1289), §7.6 (EN 1755–1766), §7.4 S4 step 2
  (EN 1688–1690), §5.1 (EN 1023), §7.1 (EN 1576–1578), §7.3 (EN 1623–1637).
- **Problem:**
  1. The owner "reads the draft's headers (`draft(id, format: .header)`)". `.header` is "Gmail's
     `metadata` with the headers in 5.5", and that list has neither `X-Banana-Send-At` nor
     `X-Banana-Send-Owner`. As specified the check never passes and every scheduled message ends
     in `needsDecision`. The same list lacks `X-Google-Original-Message-ID`, so the fallback for
     R6 never matches, and `Delivered-To` and `List-Unsubscribe-Post`, which 13.3 and P28 use.
  2. `sendDraft(_:id:replacing:)` has no thread id. A reply needs it on the request to stay in
     its conversation (EN 1611); a scheduled reply sent this way can leave its thread, after
     which verification, which looks in that thread, cannot find it.
  3. `rfc_message_id` is "the message's identity through every upload and through the send". The
     dossier: "Do not rely on a client-chosen `Message-ID`" (D 444). If Gmail rewrites it, "unless
     a message with the same `Message-ID` is in Sent" (EN 1635) fails, and a second device turns
     a sent message back into a draft. R6 lists only "asks the person more often than needed".
- **Evidence:** EN 1761: "the owner reads the draft's headers (`draft(id, format: .header)`, 20
  units)". EN 1026: "header = Gmail's `metadata` with the headers in 5.5". EN 1288: "From, To, Cc,
  Bcc, Reply-To, Subject, Date, Message-ID, In-Reply-To, References, List-Id, List-Unsubscribe,
  Content-Type". EN 1023: `sendDraft(_ account:, id:, replacing mime:)`. D 444.
- **Smallest change that fixes it:** add the five headers to the list; add `threadID:` to
  `sendDraft`; record the sent message's Gmail id from the send's response and from history as
  the primary identity, with `Message-ID` as the fallback; make W3 a gate for P17.

### E-24 · MAJOR · A 404 on a change deletes local mail, on an unverified reading of Gmail

- **Where:** MAIL-ENGINE §5.7 (EN 1304), §6.5 table (EN 1508–1510), §6.9 (EN 1562), §5.5 (EN 1239).
- **Problem:** "404 for that id … (a read or a mutation) → Delete, if it was stored". What
  `modify` answers for a missing *label* is not in the dossier (D 368 marks modify's 404
  UNVERIFIED). The engine assumes 400. If it is 404, every message in the group is deleted from
  the device; invariant 3 stops it only at twenty messages and a third of the account. Separately,
  a 400 "fails" up to 1,000 assertions at once, and "a message that 404s when fetched in the same
  pass is dropped" loses new mail if a read just after `messagesAdded` can 404 briefly.
- **Evidence:** EN 1304: "404 for that id, from a token verified as this account's (a read or a
  mutation) | Delete, if it was stored". D 368: "Expect 404 (UNVERIFIED reason string)". EN 1562:
  "a label deleted elsewhere (400)", with no label and no probe.
- **Smallest change that fixes it:** a 404 from a mutation never deletes: it queues the message
  in `verify_queue`, and only the per-message read removes it. A fetch 404 in the pass that added
  the message is retried once in the next pass. Add both to W1.

### E-25 · MAJOR · The fake Gmail is not specified tightly enough to be an oracle, and it hard-codes the behaviours under test

- **Where:** MAIL-ENGINE §17.2 (EN 2771–2796), P10 (EN 2986–2990), P18 (EN 3072–3077).
- **Problem:** two implementers would build different fakes. Not specified: which history records
  each operation writes (a draft update, a send, a trash, a label deletion, a change that changes
  nothing) and what `labelIds` they carry; what a listing with no label returns and in what order;
  how page tokens behave when the mailbox changes; `messagesTotal` and label counts; which fields
  each format returns; which `q` operators work (the engine relies on `rfc822msgid:`); thread
  assignment on send; labels on drafts; a duplicate label name; `modify` with a missing id or
  label; which `GmailLimit` a limit answers with, over what window, with what `retryAfter`;
  whether a delayed response carries the state at request or at reply. Its lag covers "listings
  and history" only. And where the real behaviour is unknown the fake picks the convenient one —
  "a second `sendDraft` → 404", atomic spending — so "two engines, one draft, one send" proves
  the engine agrees with the fake.
- **Evidence:** EN 2774: "is the oracle the engine is judged against". EN 2782–2783.
- **Smallest change that fixes it:** an appendix, "The fake, behaviour by behaviour": one row per
  method and case, each with the dossier line, DOCUMENTED or ASSUMED, and the `FakeGmailTests`
  case that pins it. Every ASSUMED row gets a switch for the other behaviour, and the engine's
  safety tests (send, wake, removal) run under both. Add three tools the listed tests lack:
  - *a convergence check:* after any scenario settles, every message's label set in the index
    equals the fake's and no intent has vanished;
  - *a seeded random run* at Gate M2 mixing device actions, changes "on the web", kills at commit
    points, lost and delayed responses, then the convergence check;
  - *a publish recorder:* across a scenario, once a published row reflects command *n*, no later
    publish shows it without, unless an undo, a refusal or an outside change explains it. A
    flash-back is a transient publish; end-state assertions cannot see one.

### E-26 · MAJOR · Everything through Milestone 3 is built on the fake before anything asks Gmail

- **Where:** MAIL-ENGINE Gate M3 (EN 3116–3118), §19.2–19.3 (EN 3253–3285), label legend
  (EN 12–19).
- **Problem:** the read-only probe runs after M3 and the write probes "each need their own
  explicit yes" later still; until then sync, the outbox, drafts and send are judged against
  assumptions. Some claims marked DOCUMENTED are not supported by the dossier: "a filter can hide
  a message leaving that label" (EN 1211; D 196 says UNVERIFIED); "do not read after write to
  confirm" (EN 1432; D 724 is third-party); a sending limit means "Definitely not sent" (EN 1680);
  Gmail "searches attachment contents and quoted text" (EN 2005); content "never changes"
  (EN 850; the dossier documents an immutable *id*). Others are inferences with no label: the
  profile's `historyId` as a safe checkpoint (EN 1132), a record's id as `startHistoryId`
  (EN 1213), the label counts used by the drift check (EN 1320).
- **Evidence:** EN 3117: "Then, with the owner's go-ahead, the read-only probe (19.2); the fake is
  corrected wherever Gmail differs, and the suite re-run." D 196 ends "UNVERIFIED." D 724:
  "UNVERIFIED in Google docs." D 374: "A 404 on replay is INFERENCE."
- **Smallest change that fixes it:** run the probe before P10, outside the app: `curl` with a
  token for a test account answers all ten read questions and W1–W5 in an afternoon and needs no
  Banana code. Correct the dossier, then write the fake's table from it. Relabel the eight claims.

### E-27 · MAJOR · What the tests cannot reach, as designed

- **Where:** MAIL-ENGINE §17 (EN 2755–2836), Gates M0–M4.
- **Problem:** not covered by any automated check:
  - the extension in `GoogleCalendarService.swift` (outside `BananaTests`; by hand at M4);
  - invariant 2 on each mint (E-17);
  - the Mac's key handling after U5 moves the calendar's key table — both test bundles are
    iOS-only (`project.yml:330, 343`);
  - real error shapes: P22's canned responses are written before the probe, so
    `GmailErrorMapping` is tested against guesses. The dossier maps a per-user limit to 403 and
    bandwidth to 429; if per-minute limits also arrive as 429, the governor closes backfill for an
    hour and never lowers its rate;
  - the web view's refusals beyond one Simulator UI test;
  - "no request alive in the background" beyond a unit test of `suspend()`;
  - Mail's views in a Release build: fixtures are DEBUG-only, and `ScreensOpenUITest` launches
    the app bare and skips unless it is an iPad (`BananaUITests/ScreensOpenUITest.swift:36–42`),
    so before a real mailbox it sees "Mail is off";
  - data races: "the test suite under Thread Sanitizer once" at M2, before the engine, feeds and
    hub exist.
- **Evidence:** EN 3045: "the test suite under Thread Sanitizer once". EN 2876: "exercised by hand
  at M4". `project.yml:330, 343`: `platform: iOS` for both bundles.
  `BananaUITests/ScreensOpenUITest.swift:40–42`: `throw XCTSkip("walks the iPad sidebar")`.
  D 563 (403, per-user) and D 566 (429, bandwidth).
- **Smallest change that fixes it:** Thread Sanitizer at every gate; a route flag that serves the
  fixture mailbox in Release for the device smoke test; a pure `MacKeyResolution` table test plus
  a by-hand list for the monitor; canned responses replaced from the early probe (E-26).

### E-28 · MAJOR · On the Mac, `MailSection` would draw the phone's arrangement

- **Where:** MAIL-UX §6 (UX 915), §2.3–2.4 (UX 159–160, 174), U1 (UX 3209–3210).
- **Problem:** `MailSection` chooses its arrangement from `@Environment(\.layoutClass)`. Its
  default is `.compact` (`Banana/Views/AdaptiveLayout.swift:29`), the measuring modifier starts
  at `.compact` (:40), and it is applied only in `RootView.swift` (:408–471). `MacRootView` sets
  no layout class. "One `case .mail: MailSection()` in `MacRootView`'s switch" therefore gives the
  compact list, and every route and snapshot on the Mac shows it. On iOS the first frame is
  compact before the measurement lands.
- **Evidence:** `AdaptiveLayout.swift:29`: "`@Entry var layoutClass: LayoutClass = .compact`".
  `.measuresLayoutClass()` is applied nine times, all in `RootView.swift:408–471`. `MacRootView.swift`
  does not mention `layoutClass`. UX 915: "chosen in one place (`MailSection`, by
  `@Environment(\.layoutClass)`)".
- **Smallest change that fixes it:** U1's Mac case applies `.measuresLayoutClass()`, as `RootView`
  does for every section on iOS, and so do the Mac snapshot views. The document must then say what
  the Mac shows under 600 pt: the window's minimum is 760 pt including the sidebar
  (`MacRootView.swift:185`), so the content column can be narrower than that.

### E-29 · MAJOR · Claims about the code in MAIL-UX that do not hold

- **Where:** MAIL-UX, the lines named in each item.
- **Problem:** eight statements about the existing code are not true, and U1, U8, U13, U18 and P0
  rest on them.
- **Evidence:**
  1. UX 535–536, 2188: `MailShellState` is "never [written] per key press". `ShellNavigation.state`
     is `@Published` and saves on every change (`Banana/Model/ShellNavigation.swift:115–117`);
     `RootView` observes it (`RootView.swift:51`). `J`, `K` and Done in an open conversation change `open` on each
     press (T12, T16), so the root re-evaluates and `UserDefaults` is written at key rate.
  2. UX 3042: "**Now** is fixed: Monday 5 October 2026". `OccurrenceStore.injectSampleForPreview`
     seeds from `Date()` (`Banana/Model/OccurrenceStore.swift:1638`). From 7 October the `invite`
     fixture is in the past and the day pane no longer matches it.
  3. UX 3189: "`ScreensOpenUITest` in Release on a phone and an iPad". It skips on a phone (E-27).
  4. UX 2267: answering an invitation uses "the calendar's own toast and Undo … restyles at once".
     `InvitationReply` awaits Google and shows nothing; only decline has Undo
     (`Banana/Model/InvitationReply.swift:11–35`). `MailInvitationUITest` would call Google.
  5. UX 2297–2309: undo of "Add to plan" needs a handle; the occurrence write returns `Void`
     (`OccurrenceStore.swift:1156`) and `createTask` is `async throws`
     (`Banana/Model/RemindersService.swift:263`).
  6. UX 2189, 3412: registering `mailList↻` with the watchdog counts a publish per action
     (`Banana/Model/PerfWatchdog.swift:214–217`), which it logs as a storm at two a second — what
     G11 (UX 2196) says must not happen.
  7. UX 3190: P0 is "recorded in `docs/PERF-AUDIT.md`", which already holds the July audit.
  8. UX 3412: "the engine's `whenLoaded()`" does not exist; the engine has `activate()`.
- **Smallest change that fixes it:** keep `open` out of `ShellState` until the conversation view
  is at rest or the app backgrounds; give the preview seed a `now:` parameter; the rest are edits
  to the lines named.

### E-30 · MAJOR · Where the two documents assign the same thing twice, or decide it two ways

- **Where:** both documents, the lines named in each item.
- **Problem:** eight things are given to two packages, or decided two ways, and nothing says which
  holds. Each becomes a collision or a rebuild when the halves meet.
- **Evidence:**
  1. *The web view.* P26 creates `Banana/Views/Mail/MailWebView.swift` (EN 3167). U7: "if that
     does not exist yet, U7 builds it to the engine's 10.4 and the engine plan drops its own"
     (UX 3279).
  2. *Settings fields.* P24 adds `mailAccounts`, `mailUndoSendSeconds`, `mailRemoteImages` to
     `AppSettings.Snapshot` (EN 3150); U14 adds "optional fields in `Snapshot`" for `MailPrefs`
     (UX 3368). Names are not shared.
  3. *The badge.* The engine mirrors "two numbers" to `UserDefaults` key `mailBadge` (EN 2330);
     U1 adds `Counts.mail` and `Counts.mailNeedsAnswer` (UX 3210). The stored format is not
     given. The UX counts failed sends (UX 2029); the engine counts "7.4's questions" only.
  4. *Remote pictures.* Engine D2: "off by default" (EN 3302). UX D6: "Fetched when a
     conversation is opened" (UX 3438). And UX 2171 loads the *next* conversation's body into a
     spare web view, against "Nothing is fetched before the message is opened" (EN 2179).
  5. *Search timing.* UX: no debounce, 30 ms (UX 1518, 2147). Engine: "150 ms after the last
     keystroke" (EN 1963).
  6. *How long a first sync takes.* UX: "takes hours", "About 3 hours to go" (UX 1900, 1915).
     Engine: a Mac "about two days", an iPhone "a week or more" (EN 1196–1199). Body ceilings on
     a phone (EN 2211) make "Everything is here" (UX 1907) untrue there.
  7. *Launching.* Engine: "No package launches the app plainly" (EN 2836). UX: "its routes are
     looked at on an iPhone Simulator, an iPad Simulator and the Mac" (UX 3164).
  8. *A held key.* UX T18: a held action key "acts once" (UX 359). The engine budgets and tests
     "30 actions a second for 10 s (held key)" (EN 2685) and reasons from it (EN 451, 1492).
- **Smallest change that fixes it:** one owner per item, in the shared-file table of E-7; 4 is one
  decision for the owner, put once; the engine's budget row becomes "ten actions a second".

### E-31 · MAJOR · The governor is built on error shapes nobody has seen, and uploads are outside it

- **Where:** MAIL-ENGINE §5.2 (EN 1059–1102), §7.3 (EN 1617–1621), P11 (EN 2992–2998).
- **Problem:** the rate halves "on a per-user limit error" and backfill closes "on a bandwidth
  limit error"; which HTTP answer is which is unverified (E-27), and the probe's twenty reads
  cannot provoke either. The byte budget is per process, so "three-fifths of the documented
  allowance, so his … other Banana devices keep working" does not hold with two devices. Halving
  the rate leaves the 1,000-unit bucket and a 50-call batch as they were, so if Google enforces
  by the second the burst that tripped the limit repeats. Uploads are not budgeted: a draft is
  uploaded "after five seconds without a change", whole, attachments included, and each upload
  gives the draft a new message id that sync then sees and fetches. Fifteen saves of a 25 MB
  draft meet the 500 MB daily upload allowance (D 525), after which it cannot reach `ready`.
- **Evidence:** EN 1086: "On a per-user limit error the rate halves". EN 1093: "Backfill may
  download 1,500 MB in any 24 hours (three-fifths of the documented allowance, so his other mail
  clients and other Banana devices keep working)". EN 1617: "after five seconds without a change,
  and when the composer closes or the app backgrounds". D 525: "2,500 MB/day download and 500
  MB/day upload".
- **Smallest change that fixes it:** P11 ships a bucket, three lanes and "pause for Google's time,
  else back off"; byte bins, adaptive batch size and saved state wait for real limit errors
  (E-32). Upload a draft on close, on backgrounding and before sending — not on a pause in typing
  — and never re-upload an unchanged revision (the hash exists for this).

### E-32 · MAJOR · Scope: where the cost exceeds the risk it retires

- **Where:** MAIL-ENGINE §4.1, §4.9–4.10, §5.2, §5.6, §6.7, §7.6, §8, §13.2.
- **Problem:**
  - **Four SQLite files: keep.** The split is measured (file 1,249.5 → 141.3 MB; a 50-message
    sync transaction 43.2 → 5.4 ms) and intent needs its own durability. The cost is the repair
    rules between files, which is why E-21 matters.
  - **The 400-row sliding window: drop it for the first release.** It buys bounded memory for a
    list of values of a few hundred bytes each. It costs two-way paging, `show(around:)`, scroll
    anchoring in a SwiftUI `List` on three platforms, a scroll bar that jumps, and a cursor type
    nobody could define (E-8 row 5). A list that grows to 2,000 rows and then says "older
    conversations are in search" is the UX's original design, costs about a megabyte, and needs
    none of it. Scope targets (E4) are needed either way.
  - **Undo kept "fifty groups, a day", on disk: keep it in memory.** The UI's stack is "not
    written to disk: after a cold launch it is empty" (UX 404) and `undo` takes a receipt, so the
    stored groups are unreachable after a relaunch. Meanwhile a whole-view action writes a
    `before` entry for thousands of keys inside the fsync'd transaction on the action's path.
    Keep `kind` and counts in `action_group` for the failed list; keep `before` in memory.
  - **The governor's byte bins, adaptive batch size, saved state and the headers-only mode: defer**
    until a real limit has been observed (E-31).
  - **Times in label names: do not build before W5.** It is the document's most intricate
    mechanism (six `due` rules, `Returned`, name references, local label rows, a janitor), it has
    four defects found on paper (E-5, E-22), and its premise — that the labels are hidden in
    Gmail's apps — is R9, unverified, with a fallback already named. Build triage and send first.
  - **Send later with ownership headers: after the first real send.** It needs E-23 fixed and R5.
- **Evidence:** EN 384–386 (the measured split). EN 2445: "the loaded window, at most 400". UX 404:
  "The stack is not written to disk: after a cold launch it is empty." EN 1535: "The last 50 groups
  are kept, for a day." EN 3240, R9's own fallback: "one `Banana/Snoozed` label plus a
  `ControlKind` for the time".
- **Smallest change that fixes it:** move P19 and send-later behind Gate M5; replace 13.2's
  window with a capped growing list; move `before` to memory; cut P11 to its core.

### E-33 · MAJOR · Too thin: places where the design stops before the hard part

- **Where:** MAIL-ENGINE §7.1 (EN 1569–1574), §7.3 (EN 1628–1633), §10.2–10.3, §12.3, §13.6.
  MAIL-UX §6.3, §12.3 (UX 2715–2730), U7 (UX 3279–3281).
- **Problem:**
  1. *What a draft's body is.* The engine stores HTML; the UX composer holds an `AttributedString`.
     No package converts either way. A draft written in Gmail with a table or an inline image,
     opened in Banana and saved, is uploaded as whatever survived the round trip — and "the local
     row takes Gmail's content" makes that silent.
  2. *Native text.* `MailNativeText` parses the engine's sanitised fragment a second time, in the
     UI, "at `warm`" — but `warm` is the engine's and returns nothing. Where the result is kept,
     and how a body with a picture is drawn (E-8 row 14), is not said.
  3. *Notifications.* Who composes the words, what a notification's payload is, and how a tap
     reaches a conversation: the engine's identifiers carry an account hash and a message id, and
     the pure folder cannot name the UI's text.
  4. *The outbox as a list.* A new, unsent message has no thread id; the row type requires one.
  5. *Labels changing elsewhere:* renamed, recoloured, nested, deleted — only deletion is treated,
     and only in a reconcile.
- **Evidence:** EN 1569: "the authored body as HTML". UX 2724: "`var body: AttributedString`".
  EN 1630: "with no local changes since the last upload, the local row takes Gmail's content".
  UX 3279: "`MailNativeText.swift` (pure: a prepared `.plain` or `.simple` fragment →
  `AttributedString`, off the main thread; 12.7)". EN 2305: "`banana.mail.<account hash>.<message id>`".
- **Smallest change that fixes it:** decide that the composer's model is constrained HTML
  (paragraphs, emphasis, links, lists, quotes) and that a draft containing anything else opens
  read-only above an editable reply, or not at all; give `MailBodyResult` a third case for
  "simple with pictures"; put a `MailNotificationContent` value and a deep-link form in the
  contract; give outbox rows their own identity type.

### E-34 · MAJOR · Benchmarks assert device budgets on a Simulator in Debug

- **Where:** MAIL-ENGINE §15 (EN 2669–2672), P09 (EN 2970–2976), §17.5 (EN 2832–2833).
- **Problem:** "Budgets are for a device (iPhone, Release)". P09's acceptance is "the benchmark
  passes on the Simulator", through `xcodebuild test` on the `Banana` scheme, whose test action is
  Debug (`project.yml:14–15`), on the Mac's SSD. A page budget of 5 ms against a measured 0.05 ms
  cannot fail there for any regression short of a hundredfold, and the two numbers the document
  itself doubts — a full fsync and a first page after a reboot (R11) — are not measured until M4.
- **Evidence:** EN 2669: "Budgets are for a device (iPhone, Release), at 200,000 messages." EN 2975:
  "the benchmark passes on the Simulator". EN 2679: budget "≤ 5 ms p95", measured "0.049 ms p95".
- **Smallest change that fixes it:** the benchmark asserts against this Mac's measured values with
  a stated margin (a regression test), logs device-relevant numbers, and a named device pass at
  the first milestone with a real store — not M4 — measures fsync and cold open.

---

## Minor

### E-35 · MINOR · `mustRefuseSaves` is attributed to the wrong store
- **Where:** MAIL-ENGINE §4.10 (EN 961).
- **Problem:** the rule the intent store is told to copy is credited to a file that does not have it.
- **Evidence:** EN 961: "the `mustRefuseSaves` rule from `PendingCalendarWriteStore`". It is in
  `Banana/Model/WellnessStore.swift:85, 151, 192`; `PendingCalendarWrites.swift` has no such rule.
- **Smallest change that fixes it:** name `WellnessStore`.

### E-36 · MINOR · A search row id that was "bumped" cannot be recomputed after a rebuild
- **Where:** MAIL-ENGINE §4.6 (EN 761–763), §4.9 (EN 943–944).
- **Problem:** the row id is the date and a 20-bit hash, "with the low bits bumped on the rare
  collision". 4.9 relies on "its row ids are derived from dates and ids" to keep search working
  across an index rebuild; a bumped id depends on insertion order and is not derivable. Imported
  mail often shares one `internalDate`. What `fts_state` a rebuilt row gets is also unsaid.
- **Evidence:** EN 762: "with the low bits bumped on the rare collision". EN 943: "Search keeps
  working throughout: its row ids are derived from dates and ids, not from `msg_pk`."
- **Smallest change that fixes it:** on a collision take the hash of `account|gmailID|n` for
  n = 1, 2, …, which any rebuild repeats in the same order for the same message; and state that a
  rebuilt row is marked `fts_dirty` unless its id is found in `search.sqlite`.

### E-37 · MINOR · What a directory entry puts in the app
- **Where:** MAIL-ENGINE §17.2–17.3 (EN 2773, 2800–2802).
- **Problem:** with the entry in place, a non-Swift file anywhere under `Banana/Model/Mail/`
  becomes a bundled resource of all four app targets and the tests, and `Testing/FakeGmail.swift`
  is compiled into every app target (empty in Release under `#if DEBUG`).
- **Evidence:** the project generated in `xcodegen-check/B-out`: a `fixture.json` and a `NOTES.md`
  placed in the folder appear in the Resources phase of all five targets.
- **Smallest change that fixes it:** rule: only Swift files under `Mail/`; fixtures under
  `BananaTests/Fixtures/`.

### E-38 · MINOR · Invariants 13 and 14 contradict each other for an action key
- **Where:** MAIL-ENGINE invariants 13–14 (EN 97–101), §15 (EN 2704–2706).
- **Problem:** "A list feed publishes once per action" and "A held key never reaches published
  state that re-evaluates a list container". §15 then says the list body "legitimately
  re-evaluates … at the key's rate".
- **Evidence:** EN 98: "A list feed publishes once per action the person took". EN 100: "A held key
  never reaches published state that re-evaluates a list container." EN 2705: "a held key
  legitimately re-evaluates it at the key's rate."
- **Smallest change that fixes it:** invariant 14 names movement keys only.

### E-39 · MINOR · The device clock decides when a snooze is due
- **Where:** MAIL-ENGINE §8.2 (EN 1841).
- **Problem:** "*t* ≤ now" on whichever device runs first; a device whose clock is ahead wakes
  early for all.
- **Evidence:** EN 1841: "with *t* ≤ now". Section 8 names no source of time but the device.
- **Smallest change that fixes it:** when online, take "now" from the `Date` header of the pass's
  last response; offline, show the wake through the overlay only (it becomes derived, E-5).

### E-40 · MINOR · The commands section tells implementers to detect a clash and not what to do
- **Where:** MAIL-ENGINE §17.5 (EN 2821–2823).
- **Problem:** `pgrep -x xcodebuild && echo "another build is running"`; `xcodegen generate`
  "after any new file" rewrites the shared project.
- **Evidence:** EN 2821: "`xcodegen generate` # after any new file: the project is generated from
  globs". EN 2823: "`pgrep -x xcodebuild && echo "another build is running"`".
- **Smallest change that fixes it:** the rules of E-7.

### E-41 · MINOR · `GoogleAccountAccess` documents an error case nothing produces
- **Where:** MAIL-ENGINE §3.3 (EN 193), §3.4 (EN 284–287).
- **Problem:** `.notConfigured` and `.unknownAccount` exist; the mapping yields neither. An
  account with an empty refresh token is retried every poll as "transport", logging each time.
- **Evidence:** EN 193 declares four cases; EN 219–221 maps to two.
  `GoogleCalendarService.swift:2087–2092` throws `notConnected` for an empty refresh token.
- **Smallest change that fixes it:** E-13.

### E-42 · MINOR · "Always from this sender" is a domain in one document and an address in the other
- **Where:** MAIL-UX §6.2.5 (UX 1262); MAIL-ENGINE §8.5 (EN 1909).
- **Problem:** the screen offers a rule for a domain; the engine stores one per address. One of the
  two cannot be honoured.
- **Evidence:** UX 1262: "**Always from stratechery.com**". EN 1909: "one record per address".
- **Smallest change that fixes it:** choose one; a domain is what a newsletter needs.

### E-43 · MINOR · Accessibility is one package at the end
- **Where:** MAIL-UX U16 (UX 3385–3394).
- **Problem:** labels, custom actions, identifiers and Dynamic Type are retrofitted across every
  view after fifteen packages; the UI tests of U4–U15 already depend on identifiers.
- **Evidence:** UX 3389: "Section 10 as a pass over everything built". UX 3066: "its accessibility
  identifier is `mail.list.row.<key>`", which the UI tests of U4 onward already use.
- **Smallest change that fixes it:** each package's "done when" gains its own accessibility line;
  U16 becomes the sweep it also is.

---

## Proposed merged build order

Aim: a real inbox on screen, read from the real store, filled by the fake — first; then triage;
then reading; then compose and send; then search; then a live mailbox. "a/b" are the splits asked
for above. Every gate includes: iOS, Mac and `BananaTests` builds; Thread Sanitizer over the mail
tests; the contract tests on both sources; a code review; and the whole-app performance audit
against P0, on every existing route as well as Mail's.

| Order | Packages | What becomes visible or provable | Gate |
|---|---|---|---|
| 0 | Reconcile E-8 in both documents. **C0** contract file, fixture mailbox definition, abstract contract tests. UX **P0** baseline; gate script into `tools/`. **Probe by `curl`** on a test account (19.2 and W1–W5). | One surface both halves compile against. A dossier with fewer unknowns. A baseline. | Both authors sign the contract. The owner: D1, D7, remote pictures, the password-change consequence (E-10). |
| 1 | **P01a** (types only; three `project.yml` entries) → **P02** → **P03a** (wire models, addresses, headers) → **P05** (summary and membership rules; no timed labels) → **P06a** → **P10a** (protocol; the fake's mailbox, listings, reads, history, label changes — from the behaviour table) → **P12a** (handshake, head listing, header-level fetch into the index) → **P23a** (engine: `activate`, list reads, change hub, minimal status). Beside them, landing one at a time: **U0′** (fixture source and session on the contract), **U2** (design system, the row), **U3** (triage model), **U1a** (the seat; Mac regular). Then **U4a** (the list, read-only, with its cursor). | `--mail` on iPhone, iPad and Mac shows the inbox from `index.sqlite`, filled from `FakeGmail`. The same route on the in-memory source shows the same rows. | **Gate A.** Contract read tests on both sources. Review of schema, queues, invariants 10–12. Index benchmark at 200,000 (the read half of P09). Whole-app audit. |
| 2 | **P14a** (intent store, `OutboxRules`, `OverlayRules`) → **P14b** (action writer, overlay, launch rebuild) → **P12b** (history, with the guards of E-6 and the observer of E-17) → **P15a** (delivery, settling) → **P15b** (undo, in memory) → **P23b** (commands, receipts, `appliedThrough`, refusal events). UI: **U4b** (actions, swipes, selection, toast), **U5** (keys). Pure, alongside: **P16**, **P20a**, **P04**. | Done, undo, star, read, trash and labels on the real store; offline queueing; a change "on the web" applied at rest. | **Gate B.** Adversarial review of invariants 1–6. The seeded convergence run and the publish recorder (E-25). Rapid-`E` and held-`J` in the whole-app audit. |
| 3 | **P03b** (MIME structure) → **P07** → **P12c** (full-format fetch, bodies) → **P20b** → **P23c** (conversation observation, bodies, `warm`) → **P21a** (attachment download). UI: **U6**, then **one** web-view package (P26 and U7 merged), **U1b** (Notes inside Library). | Opening a conversation from the store; native and web bodies; the app's first web view. | **Gate C** (the UX's P1). Security review of preparation and the web view's contract. Memory with a newsletter open and after. |
| 4 | **P10b** (the fake's drafts, send, failure and lag switches) → **P17** → **P18** (with E-4 and E-23) → **P23d** (draft handle, send, cancel, questions answered). UI: **U9** (in two), **U15a** (delivery lines, Outbox). | Compose, reply, undo-send, a failed and an unconfirmed send — all on the fake. | **Gate D.** Review of P18 against 7.4 line by line. Kill-at-every-state and two-engine tests under both fake behaviours. W3 and W4 results in hand. |
| 5 | **P08a** (query parser, `matches`, split membership) → **P08b** (full-text index, reader) → **P23e** (search) → **P27** (synced splits). UI: **U11**, **U10**. Rest of **P09**. | Search as you type, splits, places, labels. | **Gate E.** Benchmarks. Whole-app audit. |
| 6 | **P11** (core only) → **P13a** (reconcile) → **P13b** (fill, progress, drift) → store upkeep (E-21) → **P22a** (HTTP, batch, errors, from probe fixtures) → **P22b** (uploads) → **P01b** → **P24** → **U14** → **P25** → **U15b**. | Mail on a real account, on Mac Beta first. | **Gate F.** `--google-window` before and after P01b. Review of wiring against invariants 10, 13–16. Release on a device with the fixture route. Then **M5**: the first real send, by the owner, to himself. |
| Later | **P19** + **U8** (snooze and reminders, after W5 and E-5/E-22) · send later · **P28** + **U13** · **U12** · **P21b** (prefetch, eviction) · **U16** sweep · **U17** · P29–P32. | | Each on its own decision. UX P2 final audit after P19. |

- **On the critical path to the first inbox:** C0, P01a, P02, P03a, P05, P06a, P10a, P12a, P23a,
  U0′, U1a, U2, U3, U4a — fourteen pieces, against 28 + 19 as written.
- **Can wait until a live mailbox is near:** P01b, P11, P13, P22, P24, P25, the upkeep package.
- **Can be merged:** P26 with U7; P27 into P08a's wake; U16 into every package; U18 into the
  gates.
- **Too large for one sitting; split:** P06, P10, P12, P13, P14, P20, P22, P23 (five slices), U1,
  U4, U9.
- **Can truly overlap, with the rules of E-7:** the pure packages — P03, P04, P05, P16, P20, P28,
  U3, U5's keymap table, U2's `MailRowDisplay`. Two or three at a time, each landing alone.
- **Can never overlap:** anything editing `BananaApp.swift`, `RootView.swift`, `MacRootView.swift`,
  `MacCommandCenter.swift`, `SettingsView.swift`, `AppSettings.swift`, `ShellNavigation.swift`,
  `MacDebugSnapshotViews.swift`, `project.yml`, `GoogleCalendarService.swift`, `MailSession.swift`
  or the fixture files.

---

## Verified claims

Checked and held; no need to re-check.

**The `BananaTests` directory entry (xcodegen 2.46.0, on copies only).**
- With `- path: Banana/Model/Mail` under `BananaTests.sources`, every Swift file in the folder and
  its subfolders is a member of `BananaTests`' Sources phase and, through the existing globs, of
  `Banana`, `BananaBeta`, `BananaMac` and `BananaMacBeta`. The Watch and widget targets are
  untouched. No duplicate entries arise.
- A file listed both through the directory and by its own path appears once.
- Generation writes only the `.xcodeproj`; nothing in the source root changed.
- If the directory is missing, generation stops with a spec validation error, before writing.
- `BananaTests` already lists one directory (`- path: BananaTests`, `project.yml:345`), so the
  form is not new to this project.

**MAIL-ENGINE, against the code.**
- `GoogleCalendarService.swift` is 2,281 lines, `@MainActor`, imports GoogleSignIn, not in
  `BananaTests`.
- `grantedScopes` is written in `accept` (:1680) and read nowhere.
- `interactiveSignIn(hint:)` has exactly two `additionalScopes: Self.requiredScopes` (:1701,
  :1716); `reconnect(email:)` has one call to it (:390). The five-line diff and
  `grep -c '^-[^-]'` printing 5 are achievable as described.
- `accessToken(for:)` is private; an extension in the same file can call it and read `tokenCache`,
  whose values are `MintedToken`s, so a defaulted `scopes` field reaches `GoogleAccessGrant`.
- `adoptAccountsFromStore` adopts only accounts not already held (:449–457); `performRestore`
  loads the store (:1639).
- `MassRemovalGuard`: 20 and one third (`CalendarWriteBackPolicy.swift:121–127`).
- `CloudSyncPoll` has static `resume()`/`pause()` over a main-run-loop `Timer`.
- `OvernightRefresh.register()` and `CalendarWriteBackRefresh.register()` in `BananaApp.init`
  (:110–111); `BGTaskSchedulerPermittedIdentifiers` in both `Banana` and `BananaBeta`.
- `OvernightRefresh` requires power and network.
- `NetworkMonitor`: `@Published isOnline`, one `onWiFiAvailable` slot, `isCheap`.
- `MealPhotoPrints` sets `isExcludedFromBackup`.
- `AppSupport.directory` is the root of Application Support outside Beta.
- `FoodDatabaseTests.testSystemSQLiteRunsFTS5Match` exists.
- `VisualAuditRoute.flags` (`BananaApp.swift:14–17`), `wireUp()` (:620), `configured(_:)` (:582),
  `controls.register(_:for:)` (:810–820), `PerfWatchdog.registerLateSinks`,
  `CalendarWriteBack.isDiagnosticLaunch` and its argument set (:891), `GoogleRoundTripProbe`.
- `RootView`: `adoptGoogleAccountsAddedElsewhere()` on `.active` (:283), a `.background` case
  (:311).
- `ControlKind.adoptsPhoneSet`, `CloudControlSource`, `ControlsSyncTests`; `AppSettings.Snapshot`.
- `Intelligence.promptCharacterBudget(for:)`; `GuestSources.people()`; `GuestDirectory.isPerson`;
  `GuestPerson` is in `GuestDirectory.swift`, which the tests list.
- `PlaybackClock`, `WorkoutReviewPresenter`, `MealBacklogWake`, `LaunchClock`, `RenderStats`.
- The two client ids (`project.yml:91, 239`); the Mac production target shares the first (:819).
- `SWIFT_STRICT_CONCURRENCY: minimal`; `BananaTests` is in the `Banana` scheme's test action.
- No Combine subscription to `$accounts` was found.

**MAIL-UX, against the code.**
- `AppSection`'s nine cases and their order; `iOSTabs` is `[.plan, .workouts, .nutrition, .notes, .library]`
  and is used only by tests.
- `MacRootView.swift:523` is `KeyEquivalent(Character(String(index + 1)))`, and a tenth entry
  would trap.
- `ShellState` decodes with `decodeIfPresent` and has `pruned`.
- `ToastCenter`: a six-second window, `notify`, `showPreview`, one pending commit.
- `MacKeyMonitor.handle`, `MacCommand`, `MacCommandMenu`, `MacShortcutsSheet` exist as described.
- `DayPerformanceRenderProbe` exists in `RootView.swift`.
- `SettingsView`'s five hand-kept places, `MacGatedRootView`, the 600 pt split, the `DS` tokens
  of 5.1, `AdaptiveShellUITest` (from the sweep of §2, §4, §5).

**Gmail facts, against the dossier.** Supported as cited: the quota table and unit costs (EN
1059–1063); batches of at most 50 (EN 1098); history ids not contiguous (EN 592); "records might
be unavailable" (EN 1316); no preconditions on writes (EN 1546); 35 MiB (EN 1594); the three
conditions for threading (EN 1611); a draft's message id changing on update (EN 1619); no
idempotency key (EN 1641); a 200 is not delivery (EN 1721); `sendAs` under `gmail.modify`
(EN 1787); signatures not appended for API clients (EN 1790); dates as epoch seconds (EN 1940);
attachments as one base64url string (EN 2204); no push without a server (EN 2229). The May 2026
quota figures could not be confirmed beyond the dossier.
