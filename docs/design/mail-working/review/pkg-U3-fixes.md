# U3 after the fixes — second look

6 Oct 2026. Commit `87afc45` in the worktree `agent-a201c61666b41e888`, against the main tree's
MAIL-UX §0, §3, §3.10, §3.11. All of `MailListModel.swift` (1,751 lines) and the changed parts
of `MailActions.swift`, `MailToastText.swift` and the tests were read. Nothing was built or
run; every statement below is a hand trace. Line numbers are `MailListModel.swift`'s.

**Must anything change before U4a starts: yes, three things.** All three are small, and all
three are about which readings count as "asked for". One of them comes from the fix I
suggested for P-1, which was too crude.

---

## 1. The seven findings

| | Closed? | How it was checked |
|---|---|---|
| P-1 | **Not fully.** The two traces asked for hold; a third does not (M-1). | Below. |
| P-2 | Yes. | `restore` 1622–1628 closes a conversation opened since; case 42. |
| P-3 | Yes. | Below. |
| P-4 | Yes. | `.settled(before)` at 1435; case 51 restores from it. |
| P-5 | **Only under one way of running the session** (M-3), and reopened after a pull (M-2). | `enter` no longer sets idle; `entryCredit` 1106. |
| P-6 | Yes. | `arrivalIDs` 712; with no rows and not at rest, `hold` is every row, the candidate is empty, and the chip counts them. |
| P-7 | Yes. | `MailViewport.key`; `resolved` 1130–1138 returns the first row at or after the key, offset 0. |

**P-1, hold `J` past row 100.** 1,000 in the place, 100 loaded. At row 70 `growIfNeeded`
returns `.growTo(200)`; on later moves `rows.count (100) >= limit (200)` is false, so it asks
once. The 200-row reading arrives while not at rest: `free` is false; the candidate differs;
the branch at 664 runs; `appendRowsBelowTheLast` (695) finds candidate rows 100–199 older than
the model's last row and appends them; `sameIDs` is then true and `pending` is nil. Rows 200.
In the same `handle`, 200 − 75 > 30, so nothing more is asked. **Past 400:** the same step at
rows 170, 270, 370, 470; each asks once and is appended at once; it stops at `listCap`. The
same branch fills the foot after his own Done. Closed for these.

**P-3, undo after `Tab`.** `E` on C in Important (receipt 1; `performed` raises
`appliedThrough` to 1). `Tab`: `leave` zeroes `readingsSinceLeave`. Nothing is delivered to
Important. `Z`: `enter` (not at rest; credit set), `undo` returns receipt 2,
`.restore(entry, through: 2)`. `latest.appliedThrough` is 1, below 2, so `existing` stays nil
and every row of the entry is put back (1586), marked unresolved; `appliedThrough` becomes 2;
the cursor goes to C. All in that turn. A reading with `appliedThrough` 1 arriving afterwards
fails the guard at 549 and is dropped. The answering reading (2, with C) keeps C. Closed.

---

## 2. What must change before U4a

### M-1 · A chip that is waiting stops the list growing (P-1, third trace)

- **Where:** `growIfNeeded` 1688: `rows.count >= limit`.
- **What is wrong:** an arrival held above the first row is in the reading and not in the
  rows. The model then holds one row fewer than it asked for, for as long as the chip shows —
  and when the list is scrolled down, that is until he goes back to the top.
- **Sequence:** All mail, 200 rows loaded, scrolled to row 150. A message arrives; the chip
  reads "1 new". Hold `J`: at row 170 the model asks for 300. The reading is the arrival plus
  299 rows; the 99 below the last row are appended; the model has 299. `299 >= 300` is false.
  The cursor reaches row 299 and stops. Nothing more loads until he presses ⌘↑ or the chip.
  If the list was at rest when the mail arrived, it stops one step sooner.
- **Cause:** my P-1 fix said "compare with `rows.count`". That was wrong for this case.
- **Fix:** ask when the reading for the current limit has arrived:
  `(latest?.rows.count ?? 0) >= limit`. The runaway cannot return, because the tail is now
  always appended and the 30-row margin then fails. Test: growth with a chip showing and the
  top off screen.

### M-2 · A pull or ⌘R turns the three-second rule off until the list next rests

- **Where:** `refresh` 1153 sets `askedUntilIdle`; only `becameIdle` 789 clears it; `receive`
  563 treats every reading as asked for while it is set.
- **Sequence:** pull to check; "nothing new". He starts swiping at once and does not pause
  for three seconds. A message arrives at second four: it joins the top under his thumb. So
  does every outside change, for as long as he keeps going. This is P-5's fault after every
  pull, and pulling on arrival is a habit.
- **Why the test passes:** `testP1_aCheckHeAskedFor…` sends `.idle` before his next key.
- **Fix:** the allowance is for the check's answer, and only the session knows when that is
  (`status.asked` becomes `.finished`). Add an input, `.checkFinished`, which clears it; rest
  clears it too. Do not clear it on "any input": the scroll that ends the pull is one.

### M-3 · Which reading answers an entry is guessed, and the guess depends on how the session observes

- **Where:** `enter` 1106: `entryCredit = returning && readingsSinceLeave == 0`; spent by
  whatever reading comes next (561–563).
- **Two cases where the guess is wrong:**
  1. If the session keeps a list observed while it is not in front and nothing changed there,
     the credit is still set on return. The next reading is then mail from elsewhere, up to
     three seconds later, and it joins at once. P-5 is closed only if lists that are not in
     front are never observed.
  2. A cold launch shows `cachedFirstPage` as the first reading. It is a first visit, so there
     is no credit, and the real reading that follows waits: the cached rows and a chip for
     three seconds at every launch into Mail.
- **Fix:** the session says so. Either a flag on the input — `.snapshot(reading, answersEntry:
  true)` — or one more input before it. Then drop `readingsSinceLeave`. This is one enum case
  to change now and a session to rewrite later.

---

## 3. The two faults the seeded run found

**List keys moving the cursor off an open conversation.** The guards are right
(`jumpToOldest`, `jumpToNewest`, `pagedTo`, `place`, `extendSelection`), and the invariant
`open.id == cursorID` now holds them. The class is "the model trusts the keymap to keep list
inputs away while a conversation is open, one function at a time". Two members are left,
neither reachable from the screens as specified, so neither blocks:
- a first-visit `enter` with a conversation already open moves the cursor to the first row
  (1117) — a cold launch must send `.enter` before `.open`;
- an action that names another row while a conversation is open makes `settle` (1517–1523)
  reopen the same conversation with fresh reader facts, which forgets `hasUnseen`. Follow the
  open conversation only when it was a target.

One guard at the top of `handle` for list-only inputs would close the class.

**An action publishing twice.** Predicting the total (1485) is right, and
`testAnActionPublishesTheListOnce…` holds it. The class is "the own reading differs from the
model in a field the model did not predict". What is left of it is legitimate: the row that
fills the foot, an unknown row resolved, the pending mark clearing on delivery.

---

## 4. The two disagreements

**T16, "the row it hands back equals the row it was given".**
- *The specification moves* in two places. The sentence gains "its not-yet-at-Gmail mark
  aside, and only for an action whose whole effect a row can show" — the model's list of
  actions that are never "nothing" (move, a label put on, snooze, send) is right and should
  be in the rule. And case 20 reads "(not in the inbox, and read)": Done on one that is out of
  the inbox and unread marks it read, is sent, and says "Marked “…” Done". That is what Done
  means here, and it is what was built.
- *The row rules move* by one line: `changed(.done)` should clear a `.snoozed` reason, as
  `.unsnooze` does. Their own table says Done leaves Snoozed; the row should say so too. Then
  the model's snoozed special case goes. Until then it is correct and must stay.
- *The pending mark stays* as the rules have it: a label put on changes nothing a row can
  draw and is still waiting. The model ignoring it in the comparison is right.

**§3.11, told apart by the input or inferred.** *Both move, to a split.* The model is right to
infer what its own rows show: its own command, growth (the tail), an undo. It cannot infer
what only the session knows: which reading answers an entry, when a check has answered, and
that a first reading was a cached page. Those are M-2 and M-3. §3.11 should say which is
which.

---

## 5. Speed

**It still holds by construction.** `moveCursor` sends one mark and sets no `dirty`;
`commit` assigns `list.shown` only when `dirty`. Nothing a cursor key touches reaches it.

- Per cursor key: O(log n) — `growIfNeeded` now finds the viewport by key (1690).
- `⇧J`: the anchor by key; then a walk of integer indices the length of the run, touching
  only the rows gained or lost. Not proportional to the list.
- `isSelected(row)`: a key comparison, or O(log n) with a live run.
- **One leftover:** `pagedTo` (1004) scans the list twice per page, and `Space` repeats when
  held. `MailVisibleRows` should carry keys as the viewport now does. Not blocking.

**The row array rebuilt once per action is acceptable** at 400 and at 2,000. With the
reading that follows (a dictionary of the reading, a set of ids for the tail) an `E` in a
2,000-row place is a few passes over the rows: well under a millisecond in Release, against
an 8 ms frame, and ten a second is 1 % of the time. What the host diffs is the 400-row
window, which is the larger cost and is not this package's.

---

## 6. Feel

Right as implemented: `⇧J` (one press, two rows; alone at the end); the nearest row, not the
first; `U` in a conversation; the chip over the empty state; the dimmed row; `Tab` carrying
the filters; undo closing a conversation opened since.

Wrong, or to watch:
- M-2: after a pull the list behaves as if nobody were touching it.
- M-1: the list ends for no reason he can see.
- Notes for U4a, none needing a change here: the host must report "first row on screen" as
  true for an empty list, or held arrivals never join (the model could say
  `rows.isEmpty || firstRowIsOnScreen` and not depend on it); it must not report false
  because a conversation covers the list; after `growTo`, a late delivery from the smaller
  observation must not reach the model, or the list loses its tail for a moment; and closing
  emits a stored position and then a reveal, which the host should apply as one move.
