# Code review — package P02, the stores' foundation (uncommitted)

Worktree `~/orca/workspaces/gtfuwgth/stingray`, branch `google-email-functionality`,
on top of `9da98e4`. Read-only review by reading the code and GRDB 7.11.1's source
(`.build/mail-dd/SourcePackages/checkouts/GRDB.swift`, `b83108d1`). Nothing in the tree was
edited, built or run, so the implementer's numbers (1,658 tests, Thread Sanitizer over 197,
1,420 repeats, Release builds) are not confirmed here.

**One thing was run, outside the tree:** the Mac's own `/usr/bin/sqlite3` (3.51.0) on
throwaway files in the scratchpad, to read its compile options and to watch a log file's
length across a checkpoint. Three findings below rest on it and say so. It is the host's
library, not the Simulator's or a phone's.

**The document moved during the review.** The architect's rulings on P02's own questions
(section 22, rows K1–K8; 4.2; 4.12; 11.3; the P02 entry) reached `MAIL-ENGINE.md` at 03:14.
The source files were last written between 02:01 and 02:29, so **the code reviewed is the code
from before the rulings**. Line numbers of the document are the working tree's.

Files: `Banana/Model/Mail/` — `MailStores` (268), `MailWriter` (290), `MailFiles` (189),
`MailClocks` (161), `MailDirectories` (79), `MailJournal` (77), `MailWorkPace` (73),
`MailDiskRules` (64), `MailKnobs` (61), `MailDevice` (28), `MailSlices` (23);
`BananaTests/` — `MailStoresTests` (871), `MailWriterTests` (433), `MailClockTests` (198),
`MailFilesTests` (188), `MailWorkPaceTests` (152), `MailDiskRulesTests` (55).

## Verdict

**Commit with the listed fixes.** No BLOCKER.

- The three changes the entry now lists under "Before it is committed" are **not in the code**.
  They come first below, with what reading the code adds to each.
- Five MAJOR of my own, twelve MINOR.

What is built is careful and, where it can be checked by reading, correct: the durability of
the intent connection, the order of the writer, what the sink is told. What is wrong is at the
edges the entry did not draw: what guards the main thread, what the search connection really
holds, what an opening error says, and what "installed" means for a file.

**Why now:** every file here is closed to later packages by 18.1. `MailStores.swift`,
`MailWriter.swift` and `MailFiles.swift` are the three everything else goes through.

---

## Ruled, and not yet in the code

**R1 — the checkpoint measure (K1).** `MailStores.swift:180-183` sets `wal_autocheckpoint`
and no `journal_size_limit`; `MailWriter.swift:268-278` never lowers `standing`.

- *The ruling is right, and the host's SQLite does what it needs.* A log written to 12.7 MB,
  checkpointed `PASSIVE` (file still 12.7 MB), then written to once: with
  `journal_size_limit = 8388608` the file is **8,388,608 bytes**; with `-1` it stays 12.7 MB.
- *But the premise in the code and in 4.2 (:813-816) is not what this SQLite does.* Apple
  builds it with `DEFAULT_JOURNAL_SIZE_LIMIT=32768`: with no pragma at all, the same file is
  **32,768 bytes** after that one write. So a rule that read length alone would *not* have
  checkpointed after every later piece — only after a piece that wrote nothing. As built,
  `standing` therefore buys almost nothing and costs the rule: it only rises. After a 12 MB episode a
  log holding 8–12 MB is no longer due, and it creeps up by one piece's size each cycle even
  without one. `MailWriterTests.swift:401-404` (the 14 MB step, "longer than the file has ever
  been") encodes that, and the comments at `MailWriter.swift:228-235` and
  `MailWriterTests.swift:383-385` state the premise. All three change with the fix.
- With the pragma, `standing` is nearly redundant: once clamped, the only thing it still does
  is skip a no-op checkpoint after a piece that wrote nothing. Keeping it is harmless.
- Set the pragma explicitly as ruled — the 32 KB is a compile-time default nobody promised.

**R2 — other logs (K1).** No `MailWriterLog`, no `keep(_:)`; `truncateCheckpoint()`
(`MailWriter.swift:140-145`) empties the index's log only. One thing for whoever adds it:
`commit` returns early on both failures (`:200-203`, `:208-211`), before the check at `:218`.
A piece whose index step failed has still written intent. **Kept logs must be asked after
every piece, failed or not** — otherwise an index that keeps refusing (a full disk) leaves the
intent log growing with nobody looking. `keep` will be called from another thread than the
writer's: it needs the lock or the queue.

**R3 — the disk rule (K3).** `MailDiskRules.state(free:floor:)` (`MailDiskRules.swift:41-43`)
has no `was:`; `MailDiskWatch.swift` does not exist. `MailDiskRulesTests.swift:19-30` never
tests `free == floor`, so today `<` could become `<=` unnoticed; the new tests cover it.

**R4 — one comment.** `MailWorkPace.swift:14-17` still says the two tables disagree.

---

## MAJOR

### MAJOR 1 — the main-thread guard is on the two opening calls and nothing else

`MailStores.swift:56, 105, 248-268`; MAIL-ENGINE 4.2 (:752-759); invariant 10.

4.2 says the precondition "proves" that nothing calls a blocking GRDB method from the main
thread. It proves that nothing *opens* a store there. The handles are raw GRDB objects, by
rule, and GRDB's `read` and `write` each have a blocking and an `async` form with one
spelling. Inside an `async` function Swift prefers the `async` one and insists on `await` —
that much does not compile. **In a synchronous function on the main actor it is the blocking
one that is chosen: `try stores.index.read { … }` compiles and runs SQLite on the main
thread**, and no precondition, test or warning says so. The contract is full of synchronous
main-actor members (`setVisible`, `cachedFirstPage`, `forgetPermission`, `status`), the feeds
live on the main actor, and a closure handed to `MainActor.run` is synchronous too.

The same holds for file work: `MailDirectories.init` (`MailDirectories.swift:56-78`, six
directory calls and their attributes) and `MailFiles.install` (`MailFiles.swift:145-188`,
which writes megabytes) have no guard, and the file tests call them from the main thread.

Smallest fix that covers every connection that can exist, lazily made readers included: in
`configuration(_:)`'s `prepareDatabase`, `db.trace(options: .statement) { _ in
MailMainQueueGuard.requireOffMainQueue() }` — a statement run on the main thread then stops
the first run that does it. One callback a statement; the architect says whether that is
Debug only. Otherwise: guarded `read`/`write` doors on `MailStores` and a source scan that
refuses the raw ones. And the guard's first line in `MailDirectories.init` and
`MailFiles.install`. Either way 4.2's sentence should say what is actually proved.

### MAJOR 2 — the search connection holds three times the cache 4.2 gives it

`MailStores.swift:179, 189-192`; 4.2's table (:746, :748); section 15's 31 MB budget.

`PRAGMA cache_size` without a schema name sets `main` only (SQLite: the pragma applies to the
database named, `main` when none is). The two attached databases keep the system default.
Read on the host: after `PRAGMA cache_size = -8192` and `ATTACH … AS idx`,
`PRAGMA idx.cache_size` is **2000 pages of 4,096 bytes — 8 MB**. So that connection may hold
8 + 8 + 8 = 24 MB, and the stores together 47 MB, not 31. `idx` is the one a search joins
against, so it is the one that fills.

`MailStoresTests.swift:308-310` reads back `main`'s size only, and `:422-427` proves 31 MB by
adding five constants. Fix: after each `ATTACH`, `PRAGMA <name>.cache_size = -N`; read all
three back; the architect says how the 8 MB is split.

### MAJOR 3 — an opening error does not say which store

`MailStores.swift:55-83, 226-240`; 4.10's table; P33 (`M/MailCorruption.swift`).

A store that is newer than the code is refused by name (`newerThanThisVersion(file)`). A store
that is not a database, is damaged, or cannot be created is thrown as GRDB's own
`DatabaseError` (`MailStoresTests.swift:624`), which names no file. 4.10 does three different
things for `index`, `search` and `blobs` — rename and rebuild, delete and re-index, rename and
refetch — and `open` opens all three in one call. P33 cannot tell which, cannot edit this
file, and (MINOR 1) should not be opening probes of its own.

Fix: wrap each of the four openings — `MailStoreError.cannotOpen(MailStoreFile, code:
ResultCode)`, the file and SQLite's number, nothing of the message. Test it for `blobs` and
`search` too; today only `index` is tried.

### MAJOR 4 — the writer's hand-off is tested from one thread, and four of its promises not at all

`MailWriter.swift:149-170`; `MailWriterTests.swift`.

The hand-off between `enqueue` and `drain` is right (below). It is also the place where a
mistake is a change that is submitted and never committed until something else is. Every test
submits from the one test task, so nothing asserts it: move `draining = false` out from under
the lock and no assertion fails (Thread Sanitizer may object; that is not a test of it).

- **Many submitters.** Eight threads, a few hundred pieces each: every piece ran once, and
  each thread's ran in the order it handed them over.
- **Re-entrancy.** The comment at `:212-215` promises a sink may submit work in reply. No test
  has a sink, a piece's `failed` or a piece's `writeIntent` call `submit`.
- **`failed` on the writer's queue** is in the protocol's comment (`:16`) and unasserted.
- **A checkpoint a reader held up** (`:277`, the branch that leaves `standing` alone) is never
  taken by a test: hold a read open across a heavy piece, see the count stay due.
- **The gates swallow their own timeouts.** `MailTestGate.waitAsync()` and
  `MailTestRendezvous.arriveAndWait()` (`MailStoresTests.swift:20-30, 66-73`) give up after
  sixty seconds and say nothing. `testTwoReadsOnAPoolReallyRunAtTheSameTime` (`:430-436`)
  therefore *passes*, a minute late, with one reader — its comment says it "never finishes".
  Return the result and assert it at every use.

### MAJOR 5 — the one door makes a file atomic, not durable, and the precious tier uses it

`MailFiles.swift:145-188`; 4.1 (`Intent/Attachments`); invariants 4 and 9. For the architect:
the entry asks for the move, not for this.

`install` writes, renames and returns. Nothing is synced. A file he attaches to a draft is
copied through here, and the row that names it is then committed to `intent.sqlite` with a
full fsync. Sequence: attach a PDF → installed → row durable → power fails within the
seconds before the system writes the file's data. After the restart the row is there and the
file is at its final name with the right length and nothing in it; the send goes out with an
empty attachment and nothing says so. The same for a cached attachment, less seriously (it
can be fetched again), and for `first-page.json`, which must already tolerate garbage.

Smallest fix, here because this is the door: sync the temporary file before the rename when
the caller asks (`F_FULLFSYNC` for the Intent tier; nothing for the cache), so a crash leaves
the whole file or no file. A caller that streams can sync its own handle; a caller of
`install(_ data:)` cannot.

Also in this function: when the destination already existed and `protect` then fails,
`:164-169` removes the destination — the new file *and* the one it replaced are gone. Say so
in the comment, or do not use `install` to replace a file that matters.

---

## MINOR

1. **A connection can be made outside `MailStores`.** `Settings` and
   `configuration(_:attaching:)` are internal (`MailStores.swift:123-195`).
   `DatabaseQueue(path: …intent…, configuration: MailStores.configuration(.intent))` compiles
   and is a `NORMAL` intent connection: the second `makeDurable` is in `openIntentQueue` only.
   Make them `private`, and add to this package's source scan: no `DatabasePool(` or
   `DatabaseQueue(` in `M/` outside `MailStores.swift`. That one line is what makes "every
   connection that can exist" true. (P14a's scan covers `openIntent(` only.)
2. **"NORMAL cannot corrupt" rests on a default nobody set.** On this SQLite
   `checkpoint_fullfsync` is 1 by compile option; that, not `synchronous`, is what makes the
   log durable before pages are copied back. Set it on the three cache writers and read it
   back, as for `journal_size_limit`.
3. **Invariant 11 has holes that compile.** `makeSnapshot()`, `ValueObservation`, and a cursor
   returned from a synchronous `read` each keep a read transaction open after the closure.
   Add `makeSnapshot`, `ValueObservation`, `allowsUnsafeTransactions` and `.erase(` to the
   scan at `MailStoresTests.swift:592-611`.
4. **`MailStores.migrate` is private** (`:202-208`). P14a must refuse a newer `intent.sqlite`
   by the same test and will have to write it again. Make it internal.
5. **Two things the writer's protocol does not say** (`MailWriter.swift:8-18, 107-109`).
   `failed(_:)` is one call for two outcomes — not saved (the intent step threw) and saved but
   not indexed — and one call for a piece and everything it absorbed. And `isOnWriterQueue`
   is false inside `writeIndex`, which runs on GRDB's queue; calling `stores.index.read`
   there is GRDB's "not reentrant" trap.
6. **`ManualMailClock` promises more than one jump can give** (`MailClocks.swift:30-41,
   113-122`). One `advance` moves the time once: every sleeper it wakes reads the time *after*
   the jump, a loop that sleeps again is not woken a second time, and "earliest first" is the
   order of resumption — the tasks then run together. An hour of a repeating sleeper is walked
   one moment at a time, with `untilSleeping` between. Say so; P23a's poll and burst tests
   depend on it. `untilSleeping` (`:130-141`) hangs if its count never comes.
7. **`SystemMailClock`'s comment is half wrong** (`:8-13`). A wall clock set *back* is noticed.
   Set *forward*, it is slept through: the sleeper wakes late by the size of the jump.
8. **No test runs the system clock's real path** — a sleep to a moment 20 ms ahead that
   returns at or after it. Only "already passed" and "cancelled" are tried.
9. **Nothing asserts that a pool's reader cannot write**, which is the whole of K7's argument.
   One line: a `CREATE TABLE` through `pool.read` is `SQLITE_READONLY`.
10. **Orphans.** A crash between create and rename leaves `.mail-<uuid>.partial` beside the
    destination for good; the pattern is a literal inside `temporaryURL` (`MailFiles.swift:127`)
    and nothing sweeps it. Name it, so eviction and the disk-usage walk can. `createTemporary`
    reports `errno` after `FileManager.createFile` (`:136`), which may not be that call's.
11. **The Mac's quarantine closure is run by no test here** (`MailFiles.swift:70-91`): the test
    target is iOS, and the keys are spelled as strings. P21a's Mac check must read
    `com.apple.quarantine` back and look at its type, as 11.2 says.
12. **Housekeeping.** The test helpers every later store test will stand on —
    `MailStoreTestCase`, `MailTestGate`, `MailAttributeRecorder` — live in
    `MailStoresTests.swift`; name them in the entry. And P01a's follow-up is uncommitted in
    this same tree (`MailTokenFlight.swift`, `MailAccountAccess.swift` and their tests are
    modified): P02's commit must name its own files and no others.

---

## The flagged items, one by one

| Flagged | Judgement |
|---|---|
| Checkpoint due over 8 MiB *and* over what the last full checkpoint left | The rule as built is wrong in the direction opposite to the one feared (R1). The ruling — the pragma, the clamp — is right, and the pragma is seen working on the host. |
| The intent log's checkpoint is not built | Right that the writer cannot reach it. `keep` is the right seam; ask kept logs after failed pieces too (R2). |
| Warm or Low Power is `stopped` inside the overnight task | Agree, as ruled: it is the invariant's words, and it makes the task its own thermostat. What reading cannot say is how often a phone on a charger sits at "fair" (below). |
| `ok` / `belowFloor`, no resume rule | The rule is pure once it is told its last answer; as ruled (R3). |
| Protection classes set, not asserted | Agree: the calls and their order are what a Simulator can show, and they are shown. |
| Sink told after `write` returns | Right. GRDB's `write` returns only after `commit()` (`DatabaseWriter.swift:416-424`, `Database.swift:1511-1563`): a failed or aborted one throws. The callback would have run inside the database's own queue. |
| Quarantine on the temporary file, before the move | Right, and better than "at the move": the attribute travels with a rename, so the file never has its final name without it. |
| The journal id | As section 16 specifies, bars and all. |
| `submit(task:)`, `openIntentQueue(at:)`, `directories` | All three earn their place. See MINOR 1 for the one that is still open beside them. |
| Pool readers at `wal_autocheckpoint` 1000 | Inert. A read-only connection commits nothing, and only a commit runs the hook. Pin the read-only (MINOR 9). |

## For the next packages

- **P06a.** Read with `await`; a blocking `read` from a synchronous main-actor function is
  caught by nothing yet (MAJOR 1). Inside `writeIndex` use only the `db` you are given. Never let a cursor leave a
  read. An index write made through `perform`, or straight on the pool, is not announced and
  is not followed by the checkpoint check. Foreign keys are off, so the migrator runs no
  foreign-key check.
- **P14a, P14b.** The connection `openIntent()` returns is FULL with full fsync and stays so:
  GRDB sets `synchronous` once, at open, and SQLite keeps an explicit setting. Refuse a newer
  file yourself (MINOR 4). A piece must remember whether its own intent step returned, to know
  which failure `failed` is telling it about (MINOR 5).
- **P07, P08b.** Each store's writer needs a queue and a `MailLogCheckpointer` of its own. The
  blobs pool is one quality of service: a `utility` queue under an open conversation's
  `await`ed read is not raised by the waiting task.
- **P23a.** `ManualMailClock` jumps (MINOR 6). `first-page.json` may be empty or cut short.
- **P33.** `MailCache.reset()` on `Cache/` itself removes the directory's class and backup
  exclusion with it: make a `MailDirectories` again before reopening, or the new log files are
  born without either. There is no reopening one store — the four handles, the search reader
  that attaches two of them, and the writer built on them go together.

## What reading could not rule out

- **The Simulator's and the phone's SQLite** have the host's compile-time defaults (32 KB
  journal limit, `checkpoint_fullfsync` 1, 2,000-page cache). Apple builds them alike; I read
  one. R1's own test is the check.
- **A launch while the phone is locked.** `MailDirectories.init` sets `.complete` again on two
  directories that already have it. If that call is refused while locked, the directories
  cannot be made, no store opens, and every background refresh on a locked phone does nothing.
  D18 should include one.
- **The quarantine dictionary** produces the attribute Gatekeeper reads (MINOR 11).
- **"Fair" on a charger.** If a charging phone is usually at thermal state fair, the overnight
  fill rarely runs. The `bg` journal line should say when a run stopped for heat.
- **The cost of a statement trace** on the measured paths (MAJOR 1).
- **Whether a rename without a sync has ever left a hollow file on this hardware** (MAJOR 5).
  The fix does not depend on the answer.

## Checked and correct

- **Settings, connection by connection** (`MailStores.swift:151-195`, against GRDB's
  `Database.setUp`, `setUpWALMode`, `DatabasePool.init`, `readerConfiguration`):
  - A pool's readers are made lazily from the same `prepareDatabase`, and again after
    `releaseMemory()` or iOS's memory warning, so their settings are a connection's, not the
    first one's. GRDB's ten-second busy timeout is set before the closure and overridden by it.
  - `auto_vacuum` precedes the first page; nothing is set inside a transaction.
  - Intent: `prepareDatabase`, then GRDB's `NORMAL`, then FULL and full fsync outside a
    transaction, then read back or refuse. Nothing in GRDB touches `synchronous` after open;
    a queue's `releaseMemory()` does not close it.
  - The search reader is read-only and so are the files it attaches; `interrupt()` reaches it
    alone. No connection attaches `intent.sqlite`.
  - No reader can checkpoint; no writer checkpoints by itself.
- **The writer** (`MailWriter.swift:149-219`): one drain at a time, started only when none is
  queued, the flag cleared under the same lock that finds nothing waiting — no lost wake-up
  and no second drain. Order is the order of arrival across pieces and tasks. A thrown intent
  step runs no index step; a thrown index step is rolled back by GRDB; either way the next
  piece runs and the sink hears nothing. The sink is told on `mail.writer`, never the main
  thread, after the commit is visible to any new read. Submitting from inside a callback
  cannot deadlock: no lock is held across one. A burst holds the queue but starves nothing in
  it; what arrives during a batch is folded in the next.
- **Opening and failing:** a file that is not a database is refused and left byte for byte; a
  newer cache store is refused by name; a failure part-way releases what was opened. **No path
  in the package deletes, renames, resets or migrates `intent.sqlite`**, or sets
  `eraseDatabaseOnSchemaChange`.
- **Files:** the temporary file is beside its destination, the move is `rename(2)`, errors
  carry a step and a number. Every test's directory is under the temporary folder; none
  touches Application Support.
- **Clocks, pace, disk:** the manual clock resumes each sleeper exactly once whatever the
  order of wake and cancel; the pace is the table's four rows in order, each tested, the warm
  overnight case among them; `pause` is four times the work at a fifth.
- **Structure:** Foundation, GRDB and CryptoKit only; no task group, no `async let`; nothing
  logged; nothing from outside the folder named. Every file the entry lists is there.
- **Tests** read the settings back from the open connections — writer, both readers at once,
  the search pair, intent, and again after memory is released — not from the configuration.
  No sleep and no timing; the waits have bounds that only a failing test reaches.
