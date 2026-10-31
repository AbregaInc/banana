# Review of package U3 — the triage model

6 Oct 2026. Commit `4170b6e` in the worktree `agent-a201c61666b41e888`, read against MAIL-UX
§0, §1, §3, §6.1.7, §7.6, §7.9, the U3 entry of MAIL-PLAN §7, `MailContract.swift`,
`MailRowRules.swift` and MAIL-ENGINE 13.5.

**Verdict: merge with the listed fixes.** One BLOCKER and six MAJORs have to be fixed, with
tests, before U4a builds on this. Twelve MINORs can follow.

**How this was checked.** Every line of the four source files and the four test files was
read. Nothing was built or run, so every finding below is from tracing the code by hand; each
gives the sequence that was traced. Line numbers are `MailListModel.swift`'s unless a file is
named.

**What is good, in one paragraph, because it bears on the verdict.** The shape is right: one
entry point, effects out, no source and no clock inside; the cursor is an id and a key and is
found by binary search; `MailRowRules` is the only membership rule; the undo entry carries the
screen half. The cursor and selection outcomes of cases 1–13 are right in every position I
traced (first, last, only row, direction newer, selection above or below the cursor). The
faults are at the seams: readings the person asked for, undo, and Send and Done.

---

## Findings

### P-1 · BLOCKER · A reading the person asked for is treated as an outside change: more rows wait three seconds, and the model then asks for the whole list

- **Where:** `receive` 499–510; `merge` 582–608 (the branch at 595); `growIfNeeded` 1400–1407.
  Rules: T7 ("a change that did not come from this device's own hands"), 6.1.7 ("more rows are
  asked for before the end is reached"), 3.11 (the model's inputs distinguish its own reading
  from an outside one).
- **What is wrong:** the input says "Its own or not makes no difference here" (line 189). So
  every reading whose rows differ in number is a structural change and waits for `idle`. That
  includes the next page he scrolled or `J`-ed towards, the row that fills the end of the
  window after his own Done, and the full first reading after `cachedFirstPage`. T7 delays
  outside changes only.
- **Sequence 1, the stall.** A place of 1,000; 100 rows loaded. Hold `J` to row 70.
  `growIfNeeded` returns `.growTo(limit: 200)`. The 200-row reading arrives; `isIdle` is false;
  `candidate.count != rows.count`; line 595 keeps the 100 rows and stores the reading in
  `pending`. The cursor reaches row 99 and stops. The other rows appear three seconds after he
  lets go. By touch it is the same: `.scrolled` sets `isIdle = false`.
- **Sequence 2, the runaway.** In the same `handle(.snapshot)`, `growIfNeeded` runs again:
  `deliveredCount` (200) ≥ `limit` (200), and `rows.count - nearest` is still ≤ 30 because the
  rows were not taken in. It returns `.growTo(limit: 300)`. Each reading triggers the next, to
  `listCap`: nineteen re-observations and 2,000 rows held in `pending`, while the screen shows
  100.
- **Sequence 3, the list that runs dry.** In a long place press `E` every second. Each own
  reading has one row more at the end than the model, so it too goes to `pending`. The
  model's rows only shrink until he pauses for three seconds. At the last loaded row `E` sends
  the cursor back up (T6's "the other way") although older mail exists, and with a
  conversation open it returns to the list.
- **Not tested.** `TriageHarness.snapshot` always says `hasMore: false` and delivers every
  member (`MailListModelTests.swift:114–120`). `growTo`, `limit` and `deliveredCount` appear in
  no test.
- **Smallest fix:**
  1. In `merge`, rows of the reading that sort after the model's last row are appended at
     once, idle or not: adding below the last row moves nothing.
  2. `growIfNeeded` asks only when the last limit asked for has been taken in (compare with
     `rows.count`, not `deliveredCount`).
  3. Tests: a 200-row reading while not idle shows 200 rows; one growth per step; ten `E`s in
     a place with more leave the tail filled.
  4. Give the harness a source with a limit, so `hasMore` is true wherever the mailbox is
     longer than the limit.

### P-2 · MAJOR · Undo while another conversation is open leaves it open and puts the cursor elsewhere

- **Where:** `restore` 1310–1347. Rule: T26 ("the cursor, the selection and the list's
  position are as recorded; and if a conversation was open it is open again"); §0 ("An open
  conversation is always the cursor").
- **What is wrong:** `restore` handles `entry.open != nil` only. When the action was taken in
  the list and a conversation is open now, nothing closes it.
- **Sequence:** cursor on C; `E` (cursor D); `Enter` (D open); `Z`. C is put back and
  `moveCursor(to: C)` runs; `open` is still D; no `.close` is emitted. The screen shows D, the
  toast says "Undone", and nothing he can see has changed. State is now `open.id == D`,
  `cursorID == C`. `J` then "opens" the neighbour of C, which is D: the key looks dead once.
- **Not tested.** The seeded run's invariant (`MailListModelTests.swift:1582–1588`) checks
  only that an open conversation shown in the list has *some* cursor.
- **Smallest fix:** in `restore`, when `entry.open == nil` and `open != nil`: `open = nil`,
  emit `.close`. Add `open.id == cursorID` to the seeded invariants.

### P-3 · MAJOR · Undo puts rows back only if a reading has already said they exist

- **Where:** `restore` 1311–1312 (`latest`), its comment 1307–1309. Rules: T26 ("in one
  turn"), T30, case 16.
- **What is wrong:** the entry carries `rowsBefore` so rows return "without waiting for a
  reading" (`MailUndoStack.swift:8–9`), and `restore` then filters them by the newest reading
  this model has. If that reading is from before the undo, nothing is put back; the cursor
  goes to C's successor; the reading that follows is a structural change and waits for idle.
- **Sequence (case 16 as the session is likely to run it):** `E` on C in Important; `Tab` to
  Other; `Z`. Unless the session keeps observing lists that are not in front — six models are
  kept, and observing all six would cost six merges a key — Important's `latest` is the
  reading after the Done. `putBack([])`. Important shows without C, cursor on D; C appears
  three seconds later.
- **Why the test passes:** the harness delivers every reading to every model, in front or not
  (`MailListModelTests.swift:123–125`), and `show` sets the model idle.
- **Smallest fix:** put every row of `rowsBefore` back, marked `unresolved`, which already
  removes the ones the next reading lacks (T30). Pass the undo's receipt in the input —
  `.restore(entry, through: sequence)` — raise `appliedThrough` to it, so an older reading is
  dropped by the guard at line 500 and cannot take the rows away again. Test with a model that
  received nothing while away.

### P-4 · MAJOR · Send and Done: the screen half of the undo entry is built and thrown away

- **Where:** `act` 1157–1163 builds `before`; 1185 returns. `MailUndoStack.swift:77–79`.
  Rules: T38 ("one action with one undo entry"), T26, T28.
- **What is wrong:** the model moves the cursor and the open conversation, then returns
  without handing anyone what was showing. The composer is to push the one entry, and it has
  no way to know the cursor, the viewport, the reader's position or the row as it was. So
  undo within the hold cannot reopen the conversation where it was, and undo after the hold
  ("…is back in the inbox") cannot put the row back.
- **Smallest fix:** for `.sendAndDone` emit one effect carrying the entry without a receipt —
  `.settled(MailUndoEntry)` — which the composer completes with its send receipt and pushes.
  `testT38_sendAndDone…` then asserts that effect instead of an empty stack.

### P-5 · MAJOR · Entering a place makes the list "idle", so mail that arrives in the next three seconds moves the rows

- **Where:** `enter` 942 (`isIdle = true`); the default at 316. Rules: §0 Idle, T7, T9, O1.
- **What is wrong:** `Tab` or a tap on the tab is a key press or a touch. Until his next input
  the model treats the list as idle, so an arrival joins the top at once. This is the wrong
  swipe O1's three seconds exist to prevent.
- **Sequence:** tap Mail; read the second row; mail arrives at 1.4 s; every row moves down one
  as the thumb comes in.
- **Why the tests pass:** `testT9_arrivalsJoin…` (657) and case 24 never send `.idle`; they
  rely on this.
- **Smallest fix:** `enter` applies what was pending and leaves `isIdle` false. The reading
  that answers an entry is one he asked for and is taken whole — the same notion P-1 needs.
  The two tests send `.idle` first.

### P-6 · MAJOR · Mail that arrives in an emptied list shows no chip; the place says it is clear

- **Where:** `arrivalIDs` 620 (`guard let first = rows.first else { return [] }`); `merge`
  606–607. Rules: T9 ("Otherwise they are not added: a chip … counts them"), promise 8.
- **Sequence:** `E` on the last row of Important; a message arrives a second later. `rows` is
  empty, `arrivals` is 0, `hasDelivered` is true: the screen draws "Important is clear." for
  two more seconds over mail that is there. Case 36's test asserts only the state after
  `.idle`.
- **Smallest fix:** with no rows, every row of a reading that is waiting counts as an arrival.
  The screen's empty state must also yield to a chip.

### P-7 · MAJOR · A position is a row's id without its key, so it cannot be restored once that row has left

- **Where:** `MailViewport` 16–19; `enter` 947–948; `restore` 1345; `viewportIsAtTop` 958–961.
  Rules: T3, T26, 6.1.7 ("found by key"), the list host's "a row key plus points".
- **What is wrong:** the viewport is reported only when scrolling stops. After an action
  removes the first visible row, or a kept row is dropped on return, `.restoreViewport` names a
  row the host does not have. Nothing resolves it to the nearest row.
- **Sequence:** scroll so D is first on screen; `E` on D; `Tab`, `⇧Tab`. The effect is
  `.restoreViewport(firstRow: D, …)`.
- **Smallest fix:** `MailViewport` carries the row's `MailOrderKey`. Before emitting, the model
  replaces a missing row by the first row at or after that key, offset 0.

### P-8 · MINOR · Work proportional to the list on keys that should cost nothing

- `growIfNeeded` 1403: `indexOf(viewport.firstRow)` is a linear scan on **every** input once a
  viewport has been reported in a place with more to load — every repeat of a held `J`. The
  performance test measures a model with no viewport and `hasMore: false`, so it never runs
  this (`MailListModelTests.swift:1855–1857`). Fix: find it by key (binary search), which P-7
  makes possible.
- `extendSelection` → `changeSelection` → `selectedRowIDs` → `runRange` 998–1002: two linear
  scans for the anchor and two set copies per `⇧J`, which repeats when held.
- `isSelected` 343–347 builds the whole selection set per call; with a selection by scope it
  scans the rows per call. It is called per row drawn. Compare the row's key instead.
- `successor` 830–831 allocates two index arrays as long as the list per action.
- `applyToRows` 1199–1223 rebuilds the row array to change one row, then walks `pending`.

None of these breaks a budget at 2,000 rows. The first is the one to fix now.

### P-9 · MINOR · Turning a filter on scrolls to the top with the cursor carried off screen

- **Where:** `enter` 953–954. Rule: T32.
- **Sequence:** cursor on row 40; `⇧U`. The new model puts the cursor on the same
  conversation (right), then `enter` emits `.scrollToTop`. The cursor is off screen.
- **Fix:** when the cursor was carried, emit `.reveal(cursor, beyond: nil)` instead.

### P-10 · MINOR · `E` does nothing in Snoozed

- **Where:** `MailActions.swift:185–186`. Rule: T16 with `MailRowRules` (`.done` leaves
  `.snoozed`, lines 201–204 of that file).
- **What is wrong:** a snoozed row is not in the inbox, so Done "would change nothing";
  nothing is sent and the cursor moves on. The engine's table says Done ends the snooze.
- **Fix:** `wouldChangeNothing(.done)` is false when the row's reason is `.snoozed`.

### P-11 · MINOR · "Would change nothing" is decided from loaded rows for a selection by scope

- **Where:** `act` 1148–1154. Rule: T22 ("includes rows not loaded").
- **Sequence:** a search whose first 100 results are all Done and whose later ones are not;
  `⌘⇧A`, `E`: nothing is sent.
- **Fix:** never short-circuit a `.scope` target.

### P-12 · MINOR · A selection by scope is applied on screen by placement keys, and counted with mail that is waiting

- **Where:** `resolveTarget` 1121; `selectByScope` 1060–1065. Rule: T45, third bullet.
- **Sequence:** `⌘⇧A`; new mail arrives in D, which is held where it was (line 644 keeps its
  old key); `E`. The engine leaves D alone, as T45 says. The model removes D with the rest,
  and also from `pending` (1229–1235). D returns after the next reading and three idle
  seconds; with P-6 the place says "clear" meanwhile.
- **Also:** with a chip "2 new" already showing, `⌘⇧A` reads back `total`, which counts the
  two it excludes.
- **Fix:** a row is a local target only if its key in the newest reading is at or after
  `from`. Subtract `arrivals` from the count.

### P-13 · MINOR · Read-by-opening ignores a message that has not been on screen

- **Where:** `readDelayElapsed` 925–935. Rule: T45, second bullet ("…or Read").
- **What is wrong:** after 400 ms it sends `.read(true)` for the whole conversation even when
  the reader says `hasUnseen`. And once the new message has been seen, nothing marks it read:
  the conversation stays unread while he reads it.
- **Fix:** use `.message(newestSeen)` when `hasUnseen`. The second half is a gap in T10/T13 for
  the UX author.

### P-14 · MINOR · A live `⇧J` run changes what is selected without telling the rows

- **Where:** `pruneSelection` 772–782; `runRange` 998–1002. Rule: T24.
- **What is wrong:** while a run is live (no other key yet), the selection is "every row
  between the anchor and the cursor now". If an outside change at idle removes the anchor,
  the run vanishes with no `.selection` mark: rows stay drawn as selected and `E` acts on the
  cursor alone. If a row lands between the two, it is selected without being drawn so.
- **Fix:** fold the run into `selectionBase` (`endRun`) whenever rows are added or removed.

### P-15 · MINOR · Kept rows: one is never dimmed, and the mark is cleared in only one branch

- **Where:** `applyToRows` 1209, 1219; `merge` 590. Rule: T17; the plan's "kept, dimmed".
- A row kept after `stays` or `unknown` that the next reading omits is drawn as an ordinary
  row and vanishes on the next `Tab`. The model knows it has left; set `kept[id] = true` then.
- A kept row the reading confirms is un-kept only when the reading could be applied whole
  (590). In the other branch it stays "kept" and is dropped by the next `enter` or `refresh`,
  taking the cursor off it for an instant. Clear it before the branch.

### P-16 · MINOR · When every row was a target and some stay, the cursor jumps to the first row

- **Where:** `settle` 1271 (`moveCursor(to: nil)` forgets the key); `ensureACursor` 492–493.
- **Fix:** keep `cursorKey`; `ensureACursor` then uses the nearest row to that place.

### P-17 · MINOR · `U` just after opening an unread conversation marks it read and stays

- **Where:** `MailActions.swift:158–160`; `act` 1176. Rules: T10, T17.
- **Sequence:** `Enter` on an unread conversation; `U` within 400 ms. The row is still unread,
  so the toggle is `.read(true)`: marked read, still open. He asked for the opposite.
- **Ruling:** in an open conversation `U` always means "leave it unread and go back". If it is
  still unread, send nothing and close.
- **Also:** `U` on an open conversation that has left the list has no row, so it sends
  `.read(true)`.

### P-18 · MINOR · Words

These are the invented strings (question g) and three that follow the spec but read wrongly.

| String | Problem | Use instead |
|---|---|---|
| `"\(count) marked Done"`, every plural, every description (`MailToastText.swift:81–104, 138`) | A count is interpolated bare: "1204 marked Done". 7.4 groups thousands and the header says "1,204 selected". | Format the number once, with grouping. |
| "Marked “…” Done", "Marked “…” as spam", "Moved “…” to Trash" with an unbounded subject (59–61) | The outcome is the last word. On a phone a one-line toast cuts the tail, and Done and spam then read the same. | Shorten the quoted subject in the text (about 30 characters, then "…") so the outcome always shows. |
| "Couldn't label “Q3 numbers”: …" for `Y` and for taking a label off (177) | He was removing a label. | "Couldn't take Invoices off “Q3 numbers”: …" |
| "Couldn't save that: Mail can't use its files on this iPad." (213–215) | Vague, alarming, three causes, no way out. | Damaged: "…Mail's data on this iPad is being repaired." Newer version: "…this iPad's mail was made by a newer Banana. Update Banana." Unavailable: "…Mail's data can't be opened right now." |
| "Removed “Q3 numbers” from Invoices" | Acceptable; it is the mail idiom. | Keep. |
| "Muted “Q3 numbers”", "3 muted", "3 snoozed until Thu 8 AM", "2 are back in the inbox", "Starred", "Unstarred", "Marked read", "Marked unread" | Fine. | Keep. |
| Description "Done" for Add to plan, Unsubscribe and an invitation's answer (135) | Unreachable today; "Done" is the product's word for something else. | Trap, or an empty description. |
| "“…” is back in the inbox" after Restore from Trash (98–99; the spec's row) | The contract says where a restored conversation returns is Gmail's to say. It may not be the inbox. | "Restored “Q3 numbers”". For the UX author. |
| "Couldn't …: Gmail's limit for today was reached. Try again tomorrow." with **Retry** (the spec's 7.6 and T36 together) | Two sentences in a one-line toast, and a button that contradicts the second. | No Retry for `limitReached`. For the UX author. |
| "Marked “Q3 numbers” Done" after a Done that acted on seen messages only (T45) | The conversation is still in the inbox. | "Marked Done · a new reply keeps “Q3 numbers” in the inbox". For the UX author. |

Three defaults that will leak if a caller forgets to inject them: `deviceName: "iPhone"`
(413) says "this iPhone is full" on a Mac; `plainTime` (426–431) drops minutes and forces a
12-hour clock; `cleanSubject` (43–56) is a second subject cleaner beside the one U2 will write
for the row. Make the first two required parameters and share the third.

### P-19 · MINOR · Small seams

- An action that names a row which has left the list is dropped without a word
  (`resolveTarget` 1107). A picker must pass the conversation it was opened for (`on:`), not
  rely on the cursor, which T8a may have moved; and the model should still send the change.
- `receive` (500) compares a reading's `appliedThrough` with earlier readings only. Receipts
  never raise it, so a stale reading is not refused and resolves `unresolved` rows (568–576).
  Promise 2 says none arrives; one line in `performed` makes that not matter.
- `restore` does not start the 400 ms read for a conversation it reopens unread.
- A reading taken while the model has only held rows as its first rows relies on
  `arrivalIDs` breaking at the first older key; correct today, untested.

---

## Rule by rule

"Test holds it" means the named test would fail if the rule were broken.

| Rule | Behaviour | Test holds it? |
|---|---|---|
| T0 | Right. | Yes. |
| T1 | Right. Kept and held rows are placed by key, which T1 allows. | Yes. |
| T2 | Right, except P-2 (open ≠ cursor) and P-16. | Partly: the invariant does not compare `open` with the cursor. |
| T3 | Cursor and direction right. Position: P-7, P-9. | Cursor yes. "At the top" and "first again" only as an effect that names a row. |
| T4, T5 | Right. | Yes. |
| T6 | Right, except P-16. | First three clauses yes; the mixed case no. |
| T7 | Says-at-once right. Structure: P-1 delays his own and asked-for readings; P-5 admits outside ones too early. | **No.** The own-action test checks only that his row leaves. |
| T8 | Right. | Yes. |
| T9 | P-5, P-6. Otherwise right. | **No** for "idle" (relies on `enter`); no test for an empty list. |
| T10 | Right; P-13, P-17. The timer is the session's. | Yes for what it asserts. |
| T11 | Right once the removal has been applied. See question (c). | Only with an `.idle` the rule does not mention. |
| T12 | Right. "Acts once" is K7's. | Yes; the held half is not the model's. |
| T13 | Stays open; next key by the list. | First two yes. The third (`…MovesNothingInTheList`, 834) asserts only that reader facts were stored. An action on a conversation that has left the list is untested. |
| T14 | Table right. Mute is built though "after the first release"; harmless. | Yes. |
| T15 | Right. | Yes. |
| T16 | Right; P-10, P-11. | Yes, clause by clause. |
| T17 | Right; P-15, P-17. | Yes, except "coming back from the background" (nothing models it). |
| T18 | Ten presses right. | Yes. |
| T19 | Right. | Yes. |
| T20 | Right. | Yes. |
| T21 | As written, literally. See question (a). | Yes, to the literal reading. |
| T22 | Right; P-11, P-12. | Yes; the "+" count is not exercised. |
| T23 | Right. | Yes. |
| T24 | Right for `X`; P-14 for a run. | For `X` only. |
| T25 | Right; P-4 for Send and Done. | Yes for an action. Send and discard: only that a stack accepts an entry. |
| T26 | P-2, P-3. | **No** for those two; a scope selection restored is not asserted. |
| T27 | Right. | Depth yes. Six seconds is a constant compared with itself. |
| T28, T29 | Right. | Yes. |
| T30 | Right in the stack. "Skipped" rides on P-3's filter. | Through the harness's delivery. |
| T31 | Place right. See question (h). | Yes. |
| T32, T34 | Cursor right; P-9. | Cursor yes; the view no. |
| T33 | Right. | Thinly: move, star, open, close. |
| T35, T41 | Not the model's. Agreed. | — |
| T36 | Right. | Yes. |
| T37 | Right. | Yes. No test that an action publishes exactly once. |
| T38 | Opening right; P-4. | Encodes P-4 as correct. |
| T39, T40, T42 | Right. | Yes. |
| T43 | An effect. | Trivially. |
| T44 | Right. | Yes. |
| T45 | Bullets 1 and 2 right; P-12, P-13. | Bullets 1 and 2 yes; bullet 3 at the source only. |

**Rules whose test would still pass with the behaviour wrong:** T2 (open ≠ cursor), T3 and T32
(the view), T7 (asked-for readings), T9 (idle after entering; an empty list), T11 and case 27
(the added idle), T12 and T18 (held), T13 (third test), T17 (background), T22 (short count),
T24 (runs), T25 (send, discard), T26 (three ways), T27 (six seconds), T30 (skipped), T33, T43,
T45 (third bullet; read-by-opening).

---

## The forty cases

Thirty-two set up the case as stated and assert its outcome. Eight assert less.

| Case | What the test does instead |
|---|---|
| 1 | "D is where C was on screen" is asserted as "no scroll effect was emitted". Fair: the rest is the host's. |
| 13 | "One undo entry" is counted; what it restores is not checked here (T26's 500-row test does). |
| 16 | Passes because the harness delivers readings to a model that is not in front (P-3). |
| 27 | Adds `.idle` between opening and the change, which the case does not state. A second test closes first and asserts only after `.idle`; in between, the list shows C with the cursor on it. See question (c). |
| 28 | Pushes a hand-made send entry and checks the stack's answer. The model is not involved. Acceptable until U9a. |
| 30 | Sets a flag nothing reads and compares two identical runs. |
| 31, 39 | Send one input and assert one result. A held key is K7's; these tests hold nothing. |

Case 36 is right and worth keeping as it is; add the chip assertion from P-6 before `.idle`.

---

## Rulings on the eight questions

**(a) T21, the first `⇧J`.** *Change it: the first press sets the anchor and moves.* One
`⇧J` from C selects C and D. That is Superhuman's behaviour and `⇧↓` in every Mac list; the
literal reading makes the first press a second `X` and leaves every run one row short of what
his hands expect. T21's text should say so. I disagree with what was built.

**(b) Rows but no cursor.** *T2 wins when no conversation is open; agreed.* The cursor goes
to the nearest row to its place, target or not — not to the first row (P-16). While an open
conversation has left the list, no row has the cursor; that is T13 and is right as built.
T6's last clause should read "none only when the list is empty".

**(c) Idle while a conversation is open.** *A list covered by a conversation is idle.*
Nothing can move under a hand that cannot reach it. Outside changes apply at once while
`open != nil`, and what was pending applies when a conversation opens. Case 27 then holds as
written. I disagree with the implementer that case 27 needs T7's idle first: the case is
right and the code should move. Closing is a key press, so the three seconds start again.

**(d) Arrivals into an empty list.** *The wait is right; the missing chip is wrong.* The row
must not appear at once: the last of a run of `E`s would mark unseen mail Done. But T9 says
what waits is counted, and an empty state that says "clear" over waiting mail is false (P-6).

**(e) Kept rows that are not dimmed.** *Dim a kept row as soon as a reading omits it.* Dimmed
means "kept though it no longer belongs"; from that reading on, the model knows it (P-15).
Until then, not dimmed is right.

**(f) Send and Done.** *The composer pushes the one entry, and the model gives it the screen
half* (P-4). `undo(receipt)` within the hold cancels the send and reverses the Done; after the
hold it reverses the Done only, the model restores the row and the cursor from that entry,
and the toast is T28's. As built this cannot work.

**(g) The invented words.** *Accept most; change five.* See P-18: group the numbers; bound the
subject so the outcome shows; "take … off" for a label removal; three plain lines for a store
that cannot save; no "Done" placeholder. Three of the spec's own lines should change too.

**(h) `Tab` and the scope.** *`Tab` changes the split and nothing else.* The account and the
filters carry, the header shows them, and `Esc` clears the filters (K9). That is one rule, and
it is what case 18 implies. A `G` key keeps the account and drops the filters. Returning the
place alone is right; write the rule into T31.

**The two beliefs.** Case 27: disagree, as (c). T0 step 3 citing T16 for scrolling: agreed —
it should cite T4 (show the cursor row whole, one more beyond it), which is what the code does
with `.reveal(next, beyond: direction)`.

---

## The feel

Walking the triage steps of the five walk-throughs through this model:

| Step | Through the model | Same as Superhuman? |
|---|---|---|
| `E` down a split of twelve | Right every time, including the first, last and only row. | Yes. |
| `E` down Other, 300 conversations | The loaded rows run out and the cursor turns back (P-1). | No. |
| Hold `J`, or scroll, past row 100 | Stops for three seconds (P-1). | No. |
| Open, `E`, `E`, `E` | Next opens each time; at the end, the list. | Yes. |
| A split empties | Empty state, place stays. Mail arriving then is invisible for three seconds (P-6). | Nearly. |
| Accidental `E`, then `Z` | Right in the list. | Yes, and not limited to ten seconds. |
| `E`, open the next, then `Z` | Nothing visible happens (P-2). | No. |
| `E`, `Tab`, `Z` | Depends on a reading the model may not have (P-3). | At risk. |
| `Z`, `Z` | Right: second undo offered by name. | Better. |
| New mail just after entering Mail | Rows move at once (P-5). | Not decided this way. |
| New mail one second after `E` | Chip, then joins. | As decided. |
| A change elsewhere removes the cursor's row | Stays until idle; then the cursor goes on in the direction of travel. `E` on it meanwhile does nothing and moves on. | As decided. |
| `⇧J` twice | Two rows, not three (question a). | No. |
| `⇧U` at row 40 | Jumps to the top (P-9). | No. |
| Reply and ⌘⇧↩ | Screen moves; undo cannot restore it (P-4). | No. |

---

## Speed by construction

**The requirement holds.** "Which row is the cursor" and "which rows are in the list" are
separate by construction:

- A list container observes `MailListModel.list` (`MailListFeed.shown`): rows, dimmed ids, the
  chip's count, totals. It is assigned only in `commit` (1411–1420), and only when `dirty`.
- A row's leaf observes `markChanges` and reads `cursor` and `isSelected` once when made.
- `moveCursor` (732–744) sends one mark and sets no `dirty`. `move`, `step`, `place`,
  `pagedTo`, `jumpToOldest` and `extendSelection` publish nothing the container reads. Dimmed
  rows, the selection and undo change `shown` only on an action. I found no path where a
  cursor move reaches `shown`. The test for it (1852–1884) checks the publisher and the
  buffer's address, and is sound.

Three leaks, none through the container (P-8): the viewport scan on every input in a long
place; two scans and two set copies per `⇧J`; `isSelected` per row drawn.

An action is linear in the rows held: one rebuild of the array, one pass over `pending`, one
over the selection. At 2,000 rows that is a fraction of a millisecond. A row array is copied
per action (1199–1223), never per cursor move.

---

## Fit with the contract and the list host

- **By key, not by index: yes.** The cursor is an id and a key; successors, neighbours and
  put-back use binary search on keys; the selection by scope is a key. Indices are internal.
- **What it assumes:** that its rows are the *first* `limit` rows of the scope, which is what
  `observeList` delivers. `arrivalIDs`, `selectByScope`, `jumpToNewest` and a first visit all
  read `rows.first` as the top of the list. That is right for the contract as written and
  would be wrong if a source ever delivered a window that does not start at the top.
- **It does not window.** `shown.rows` is everything delivered, up to 2,000. The 400-row
  window of 6.1.7 has to be cut by U4a between the feed and the host. The host must also bring
  a row into its window when `.reveal` or `.restoreViewport` names one outside it.
- **Positions:** P-7. An id is not enough once the row has left.
- **Nothing needs the whole list in memory** except P-11 (deciding "nothing would change")
  and the toggles, which the comment at `MailActions.swift:133–135` admits.

---

## The tests as a safety net

What could break without a test failing:

1. Everything about limits and growth (P-1). No source in the tests has more rows than it
   delivers.
2. Any reading whose only difference is at the end.
3. Undo with a conversation open, with a model that was not observed, or with a selection by
   scope to restore.
4. `open.id == cursor`; "kept rows are rows"; "the chip counts what is waiting" — none is a
   seeded invariant. The seeded harness also keeps every model observed and idle on entry, so
   it cannot reach P-3 or P-5.
5. That an action publishes once, and only once.
6. Selection marks: only a cursor mark is ever asserted. A selection change without a mark
   (P-14) passes everything.
7. The view effects after a carried cursor, after a row named in a viewport has left.
8. The cursor-move timing, which is measured where the linear scan cannot run.
9. Number formatting and long subjects in every toast.

Fixing P-1, P-5 and (c) changes what several existing tests must send (`.idle` in T9's first
test and case 24; no `.idle` in case 27). Those edits are the point: the tests currently hold
the model to the faults.

---

## Verdict

**Merge with the listed fixes.** Before U4a starts: P-1 (asked-for readings and growth), P-2
and P-3 (undo), P-4 (Send and Done's entry), P-5 and P-6 (idle and the chip), P-7 (positions
by key), each with the test named above, and the harness given a source with a limit.
Rulings (a) and (c) change code and tests and should be settled with the UX author in the
same pass. The MINORs can follow; P-8's viewport scan and P-18's number grouping are the two
to do first.
