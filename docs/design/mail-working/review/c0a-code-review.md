# C0a code review

Reviewed read-only, in the worktree as it stands (uncommitted, on top of `3542829`): the six new
files, the `project.yml` change, and the two documents' diffs. Nothing in the repository was
edited, built or launched. `xcodegen` was run only on a scratch copy
(`scratchpad/review/c0a-xcodegen/`).

**Verdict: commit with the listed fixes.** No blocker. Six majors, all cheap today and all of
them either a change to the frozen file or a cell that P05's own test will contest. Paths below
are relative to the worktree; `C` = `Banana/Model/Mail/MailContract.swift`, `R` =
`Banana/Model/Mail/MailRowRules.swift`, `N` = `Banana/Model/Mail/MailSource+NotYet.swift`,
`RT` = `BananaTests/MailRowRulesTests.swift`, `ST` = `BananaTests/MailContractShapeTests.swift`.

---

## BLOCKER

None.

## MAJOR

### M1 · A label id carries no account
- **Where:** `C:690` `case label(add: [String], remove: [String])`, `C:692`
  `case move(to: String, from: String?)`; also `C:175-181` `MailLabelRef` and `C:511-515`
  `MailLabelNode`.
- **What is wrong:** Gmail's ids for a person's own labels (`Label_12`) are numbered per mailbox,
  so the same id names different labels in two accounts. Every other identity in the file
  carries its account — `MailPlace.label(account:id:)` at `C:90` does — but a change does not,
  and a target may span accounts (`.conversations` from a unified list; `.scope` with
  `account == nil`). The only guard is one sentence of UX prose for one picker (MAIL-UX 2042,
  "Label one account's at a time"); nothing says what `apply` does when it is handed such a
  change, so the engine and the fixture source are free to differ, and the cheap implementation
  puts account B's `Label_12` on account A's mail. `move` also takes it out of the inbox.
  `N:371` has the same collision by name: two accounts each making "Invoices" get
  `local:Invoices`.
- **Smallest fix:** `case label(account: String, add:, remove:)` and
  `case move(account: String, to:, from:)`, with the rule "applies to the target's conversations
  in that account; the others are untouched and not counted". About ten mechanical edits in `R`,
  `RT` and the 13.2 tables. The minimum, if the cases must not move: a doc comment on both cases
  — "the ids are one account's; a target with a conversation of another account is refused whole,
  `count` 0" — and a test of it in the contract suite. Either way, say in a comment what
  `MailLabelNode.id` is (`C:512`): if it is Gmail's id, two accounts' trees in one `ForEach`
  have duplicate ids.

### M2 · `unknown` carries no row, so a change in search does not show in the same turn
- **Where:** `C:806` `case unknown`; `R:29` and `R:36`; `RT:334-342`, `RT:344-349`.
- **What is wrong:** MAIL-UX case 19 (line 569): "Search results, cursor on C (in the inbox),
  `E` → C stays, **without its inbox glyph**", and T16 says "in one turn". The rule answers
  `.unknown` for `done` in a search, which means "show it as it is"; the engine's list feed
  applies the rule itself (MAIL-ENGINE 13.7), so C keeps its glyph until the next index read —
  "a few milliseconds when all is well and much longer when the disk is busy" is this file's own
  header (`R:6-9`). The same for Not done, Snooze, Mute, Label and Move in a search, for
  everything in Drafts and Outbox, and — because of `R:36` — for **every** marking under the
  No-reply filter: `S` under `⇧R` shows no star until the read. The end state is right; the
  promise the rule exists for is not kept in those places. MAIL-UX never says what a screen does
  with `.unknown` (the word does not occur in that sense), so the UX author assumed two outcomes.
- **Smallest fix:** `case unknown(MailRow)` — "whether it still belongs is not known here; draw
  it as changed and let the next reading decide" — and `R:29` returns `.unknown(changed)`. One
  enum case, one line of `R`, the `.unknown` comparisons in `RT`. And delete the No-reply rule at
  `R:36`: no `MailChange` alters whether anyone has replied, so a row that was in the list still
  passes; answer `.stays(changed)`. `RT:344-349` pins the current answer and should be turned
  round.
- **Related, one line:** `done` in a search under the Unread filter answers `unknown`
  (`RT:338-340` pins it) though it certainly leaves — done marks read. "Unknown and certainly
  fails a filter" is `leaves`.

### M3 · Every split is treated as the plain inbox; the Important and Other cells are wrong, and the grid pins them
- **Where:** `R:102-103` (`.split` → `.inbox`), `R:177-178` (`important`); `RT:208` (the only
  split column is `.split("important")`), `RT:244-245`.
- **What is wrong:** Important is "has `IMPORTANT`", Other is "the rest" (MAIL-ENGINE 9.3 and
  P05's `MailBuiltInSplits`; MAIL-UX 2.3). So `important(false)` in `.split("important")` moves
  the conversation to Other, and `important(true)` in `.split("other")` moves it to Important.
  The rule answers *stays* for both, and `RT:245` asserts the first. P05's
  `MailRowRulesAgreementTests` compares exactly these answers with `ViewMembershipRules` "for
  every change, every kind of place" — the cell fails there, and the file that has to change is
  this one. No key sends `important` today (it does not occur in MAIL-UX), which is why nothing
  has noticed.
- **The wider form of it:** the rule knows no split definitions. A custom split may test labels
  and flags (9.3), and custom splits are claimed first, so `L` on a row in Important can move it
  into a custom split — the rule says *stays*, the next reading drops the row, and it vanishes
  under the cursor after a *marking* action, which T17 forbids. The fixture already has a custom
  split (VIP).
- **Smallest fix:** in `R`, for `important(b)`: `.split("important")` → `b`;
  `.split("other")` → `!b`; `.split("calendar")` → stays; any other split id → unknown. Add
  `.split("other")`, `.split("calendar")` and one custom id to `RT:206-221`. For the wider form,
  one sentence each in 13.2 and in T17: the rule does not predict a custom split claiming a row;
  **a marked row is kept by the action, whatever the next reading says** (not only when the rule
  answered `leaves`); the agreement test excludes custom splits.

### M4 · A receipt's identity includes its count
- **Where:** `C:708-711` `struct MailReceipt: Hashable, Sendable { let sequence: UInt64; let count: Int? }`.
- **What is wrong:** `count` is nil for a `.scope` target "until the engine has counted". The
  receipt then comes back inside `MailEvent.applied`, `.notSaved`, `.refused`, `.sendGone`
  (`C:766-774`) and `MailRefusedChange` (`C:573`). If the engine fills the count in, the receipt
  the undo stack holds is unequal to the one in the event, and as a dictionary key it misses —
  for exactly the bulk actions (`⌘⇧A`, `E`). Nothing says "compare by `sequence`"; the file
  itself already does (`C:580`, `id: UInt64 { receipt.sequence }`).
- **Smallest fix:** `==` and `hash(into:)` on `sequence` alone, six lines, and one test in `ST`
  (`MailReceipt(sequence: 7, count: nil) == MailReceipt(sequence: 7, count: 500)`). Add to the
  comment: `count` 0 means nothing was changed and the screen shows nothing (the rule 13.2
  already uses for snooze before P19a), and no source issues `sequence` 0.

### M5 · A forgotten member is found only if a test happens to call it
- **Where:** `N:67-393` (the defaults), `N:37-39` (`reached`); `ST:298-299` (the comment);
  MAIL-ENGINE 13.3 line 4607 and P24's test at 6173 (gate F).
- **What is wrong:** every requirement has a default — confirmed twice: `NothingBuilt` compiles
  (`ST:149`), and a name-and-label match of the 56 requirements against the 56 defaults finds
  none missing and none extra. But detection is by execution. (a) A near-miss in a source — a
  wrong label, `async` on a synchronous requirement, a different return type — compiles as an
  overload, the default stays the witness, and every screen (which holds `MailSource`) gets the
  default while the source's own unit tests, calling the concrete type, pass. (b) Gate F asserts
  only that "the contract suite reaches no default", so it is as wide as the suite's calls, and
  only on the engine — the fixture source, which every screenshot and UI test runs on, is not
  asserted at all. (c) In the shipped app a reached default is silent. (d) The comment at
  `ST:298-299` overstates: a 57th requirement needs a default to compile, but nothing makes the
  probe or the list grow, and a default that forgets `reached` for a member the probe does not
  call is not caught.
- **Why it matters here:** four defaults read as success on their face — `newDraft` (`N:206`,
  the contract says "durable before this returns"; this one is held nowhere), `save` (`N:240`),
  `createLabel` (`N:369`, returns a usable label) and `saveSplits` (`N:363`, `[]` means "all
  saved"). With these signatures they cannot say otherwise, so detection is the whole defence.
- **Smallest fix, three parts:** (1) move the 56 calls of `ST:157-296` into one helper,
  `touchEveryMember(of: MailSource)`; the shape test asserts all 56 reached on `NothingBuilt`,
  and gate F runs the same helper on the engine **and** the fixture source and asserts none
  reached, less a short named list of post-release members (`createLabel`, `unsubscribe`, …).
  Decisive variant: gate F's commit deletes the defaults of everything in the first release, so
  a missing or near-miss member is a compile error in both sources. (2) Add
  `static var onReach: ((String) -> Void)?` to `MailNotYet`, called from `reached`; the app's
  composition root sets it to an `assertionFailure` in Debug and one journal line in Release.
  Four lines now, and a default reached on a device stops being invisible. (3) `N:363` returns
  `splits.map(\.id)` — every split refused, none saved — which is the true answer.

### M6 · The row family is not `Codable`, and `first-page.json` stores it
- **Where:** `C:192` `MailRowReason`, `C:210` `MailRow`, `C:235` `MailListSnapshot`, `C:254`
  `MailRemoteSearch`, `C:258` `MailCoverage`, `C:726` `MailQuestion.Kind`.
- **What is wrong:** MAIL-ENGINE 4.11 writes "the scope, its first 50 rows, the counts and a
  time" to `Cache/first-page.json` and decodes it at launch for `cachedFirstPage`. Synthesised
  `Codable` can be declared only in the file that declares the type, so P23a either reopens the
  contract or hand-writes about 120 lines of coding for a struct whose next field will then be
  dropped silently from the first frame. Every stored member is already `Codable`-capable.
- **Smallest fix:** add `Codable` to those six declarations now. Or say in P23a that
  `MailFirstPaint` has its own record type and why.

## MINOR

1. **Two cells where the rule is right and the engine's text is not** (found while checking the
   grid; no change to C0a). MAIL-ENGINE 6.1's table makes `trash` "`TRASH` present" and nothing
   else, and 4.5 says "if none is visible, all are" and "`TRASH` and `SPAM`: when any message has
   it". Read literally, a trashed conversation keeps `INBOX`, becomes all-visible again and stays
   in the inbox and in All mail; `trash` in Spam stays in Spam; `spam` in Trash stays in Trash.
   `R:147-153` says *leaves* for all of these, as 13.2's own table does and, as far as I know, as
   Gmail behaves. Settle 4.5 and 6.1 before P05 so
   the agreement test does not go looking for the fault here.
2. **`snooze` overwrites a reason that outranks it** — `R:75-77` sets `.snoozed` unconditionally;
   `C:190-191` says the cases are in rank order. Keep `.asking`, `.failedToSend`,
   `.changeRefused`, `.held`, the three sending states, `.scheduled` and `.draft`. No test covers
   it.
3. **`hasPendingChange` is set by every change (`R:47`) and drawn by nothing** — it does not occur
   in MAIL-UX; neither does `fromGmailSearch`. Since `MailRow` is `Equatable`, each delivered
   marking costs one more list publish when the flag clears, for pixels that do not change. Draw
   it, or drop it from the row while that is free.
4. **`trash` and `spam` in a search always answer *leaves*** (`R:147-153`), though
   `in:trash budget` still holds a row marked spam. Unknown is the honest cell; with M2 it costs
   nothing visible.
5. **What `nil` means for a conversation is not said** — `C:853-857`: `observeConversation`
   delivers `MailConversation?` and `conversation(_:)` returns one, with no comment. "Not on this
   device now" and "not read yet" need different screens; a restored open conversation depends on
   it. One comment line. Likewise `MailScope.account` (`C:105`) beside a place that carries its
   own account (`.label`, `.heldRemoval`): say which wins.
6. **`MailConversationID.text` has no way back** (`C:31`), and it is "for `ShellState`". Add
   `init?(text:)`, splitting at the **last** `|` (an address may contain one; a thread id cannot),
   with a round-trip test, before two packages each write a parser.
7. **`MailObservation` is not safe for what its comment allows** (`C:632-649`): "runs once, on
   whichever thread lets go", but `cancel()` reads and clears `onCancel` unlocked. Either a lock
   and `@unchecked Sendable` (the engine's `onlineChanges` hands one across threads, MAIL-ENGINE
   4811), or say "used from one thread at a time".
8. **MAIL-UX 3060 names `MailConversation.gmailURL`**; the file has it on `MailConversationID`
   (`C:35`). One word in MAIL-UX. `reconsiderKeptMail` (`C:951`) is the one protocol member
   MAIL-UX never names; Settings' text for `keptAfterRemoval` should.
9. **The stored form of the `Codable` types is not pinned.** `MailScope`, `MailPlace`,
   `MailConversationID` and `MailChange` are kept across launches, and a synthesised enum coding
   changes when a label or case is renamed. One test in `ST` that encodes a known value of each
   and compares with a literal makes "frozen" true of the bytes as well.
10. **`RT:258` claims every kind of change and checks only cell counts.** An exhaustive `switch`
    over `MailChange` in the test (case → name), compared with the names in the grid, makes a new
    case fail to compile there.
11. **The identifiers are not shared with the bundle that looks them up.**
    `Banana/Model/MailUI/Pure/MailIdentifiers.swift:6-9` exists because "each is typed twice — once
    by the view and once by the test", but `BananaUITests` (`project.yml:351-357`) compiles only
    its own folder, so every UI test will retype the strings. Add to `BananaUITests.sources`:
    `- path: Banana/Model/MailUI/Pure` with `includes: ["MailIdentifiers*.swift"]`, once, now
    (generated in scratch: both identifier files land in the UI-test bundle, nothing else does),
    and say that those files name only Foundation.
12. **"Only Swift files live there" is unenforced.** Generated in scratch: a `.json`, `.md` or
    `.html` placed in either folder becomes a bundled resource of all four apps and of
    `BananaTests`. `includes: ["**/*.swift"]` on the two entries at `project.yml:732-733` keeps
    them out of the test bundle only; the apps still take them through their own `Banana/`
    glob. So also one test that walks the two folders and fails on a file that is not `.swift`.
13. **Small.** `MailDraft.account` duplicates `from.account` (`C:435`, `C:438`) and
    `isReply`/`isForward` allow both true; `N:5` and the comment at `project.yml:726-731` still
    say "by more than one person"; `N:286` answers "it has left" for a send that never happened,
    which is only safe while screens honour `count` 0 (M4's comment).

---

## The six questions, where the findings above do not already answer them

**1. The contract as code.** Every `MailSource` member and every type MAIL-UX names resolves in
the file (a scan of every back-ticked name in MAIL-UX against the file's declarations leaves only
the UI's own types, SwiftUI modifiers, and the one mismatch in minor 8). T10–T15, T21, T23, T47,
T60 and A1–A5 are present in the shape MAIL-UX section 12 uses. Declared and unused by the
screens: `reconsiderKeptMail`, `MailChange.important`, `Outcome.unknown`, `hasPendingChange`,
`fromGmailSearch`. `@MainActor` is right: the protocol, the three observable classes and
`MailNotYet` are isolated; `MailRowRules`, `MailTuning` and the badge mirror are not, and need
not be. Every value type is `Sendable`. Nothing is expensive at list scale: a snapshot of 2,000
rows is one array of values whose strings are shared, and equality short-circuits on shared
storage. The badge mirror's key is dot-free.

**2. The three deviations.** All three are right, and the documents moved: 13's two Swift blocks
are identical to the file, and a token diff of the file against the text committed in `3542829`
shows only formatting, `MailRefusedChange` declared before `MailStatusValue`, and the
observation — as "What compiling it changed" says. Residue: minor 7 for the first; M2's two
notes for the second (No reply, and unknown beside a failed filter); nothing for the third.

**3. The defaults.** 56 requirements, 56 defaults, 56 `reached` calls, values equal to 13.3's
table. Reads are honest because the shared status says `store: .notOpened`, which MAIL-UX draws
as skeleton rows (line 2398), and the observations deliver nothing. Writes: see M5.

**4. The rules and their tests.** The grid is written by hand against 13.2, not derived from the
code, and the row-as-changed tests compare whole rows, so they pin behaviour. Case by case
against T14–T17 and the worked cases of 3.10: all agree except case 19 (M2) and the split cells
(M3). `ST` tests real things — the order of a list, the address encoding, the mirror's stored
form, an observation stopping once, witness selection, the defaults table — and two tests that
restate one line each (`ST:46`, `ST:75`), which are harmless.

**5. `project.yml`.** Checked in the generated project: GRDB and SwiftSoup are on `Banana`,
`BananaBeta`, `BananaMac`, `BananaMacBeta` and `BananaTests`, and on nothing else; the four mail
sources are in the four apps, the six files in `BananaTests`, none in the Watch, the widgets or
the UI tests. `BananaTests` is unhosted, so two static copies of a library cannot meet in one
process. Nothing imports either library yet, so this commit proves they resolve and link, not
that they work.

- **The 9.3 MB.** Acceptable. It is very likely not the price of the libraries being unused: Swift's
  conformance and type records are roots for the linker, which is why it keeps code nothing
  calls, and why calling it will not give the bytes back. (Inferred, not measured — I ran no
  build.) What this commit brings forward is GRDB by two packages and SwiftSoup by about a
  dozen (P20a, order 2). For one user that is not worth a second edit of `project.yml` — unless
  you would rather each `- package:` line land with its first import, which one-at-a-time
  landing now allows. Two things I would do either way: say the size in the commit message, so
  the jump has an owner; and take the launch marks on the phone once for this commit, since it is
  the one that changes the shipped binary while adding nothing he can see.
- **`Package.resolved`.** `exactVersion` is sufficient for *which version*: both packages
  declare no dependencies of their own, so there is nothing below them to float. It is not a
  pin of *which bytes*: a tag can be re-pointed, and a fresh derived-data path resolves again.
  This Mac happens to be protected — SwiftPM's fingerprint store
  (`~/.swiftpm/security/fingerprints/`) holds both versions' revisions — but that is one
  machine's memory, not the repository's. Pin by revision in `project.yml`, the version in a
  comment: GRDB 7.11.1 is `b83108d10f42680d78f23fe4d4d80fc88dab3212`, SwiftSoup 2.13.9 is
  `18b80329749eca5ea29fc50211dca5c7eff5bfec` (the same in this tree's checkout, in the
  fingerprint store, and in the two spike lockfiles that are committed under
  `docs/design/mail-working/spikes/`). The larger unpinned surface is older than mail:
  GoogleSignIn's seven transitive packages resolve by range on every fresh resolve.

**6. Safe to freeze?** After M1, M2, M4 and M6, yes — those four are the ones that change
`MailContract.swift` itself, and each is a few lines today and a both-authors change later. M3
and M5 are in the two files beside it and in the tests; do them in the same commit so P05 and
gate F inherit a rule that is already right. Of the minors, 6, 11 and 12 are worth doing now
because they are the ones that otherwise send a later package back to `project.yml` or to the
contract file.

## Verdict

**Commit with the listed fixes:** M1–M6, and minors 6, 11 and 12. Nothing here needs a design
decision from the owner except M1's choice between the two forms. The rest of the minors can
ride with P01a or be declined.
