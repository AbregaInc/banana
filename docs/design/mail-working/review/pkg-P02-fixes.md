# P02 — second look, at `9b204ca`

Read-only, by reading `git show 9b204ca` and GRDB 7.11.1's trace code. Nothing built, run or
measured; the cost figures below are counted from the code, not timed.

## Verdict

**A small follow-up commit, yes. It need not hold up P05 or P06a**: nothing either builds on
is wrong, and the five majors are closed as written. But these files are now closed to every
later package, three of the four changes are to their shape, and one changes what P09a will
record as its medians.

Must change:

1. **The statement guard takes a process-wide lock on every statement.** Check the thread
   first; reach for the lock and the replaceable handler only when the check has failed
   (`MailStores.swift:242-244`, `:342-345`). Details under 1.
2. **`install` has a default for `durability`** (`MailFiles.swift:216`, `:251`). Remove it.
   Details under 2.
3. **There is no way to the first-frame file's path without making the tree.**
   `MailDirectories.init` now traps on the main thread (`MailDirectories.swift:58`) — rightly —
   and `firstPage` (`:52`) is an instance property. 4.11 has `MailFirstPaint.load()` read
   `first-page.json` on the main thread at launch. Add a static that is only path arithmetic
   (`MailDirectories.firstPage(under:)`). Needed by P23a; one line today.
4. **The eight-thread test cannot see the fault it was asked for**
   (`MailWriterTests.swift:629-653`). Details under 4.

Comments only, same commit: `ManualMailClock`'s header still says sleepers wake "in the order
the real time would have woken" them — one `advance` is one jump (first review, MINOR 6; P23a
depends on it). `MailWriter.swift:275-278` says `standing` spares a checkpoint while a reader
holds the restart off; the new held-up test shows the opposite, correctly (the count goes
1 → 2 with the reader still there). What `standing` spares is a piece that wrote nothing.

## 1. What the statement guard costs

**How.** `db.trace(options: .statement)` — GRDB's wrapper over `sqlite3_trace_v2` with
`SQLITE_TRACE_STMT` — set last in `prepareDatabase` (`MailStores.swift:242`). It is therefore
on every connection `MailStores` makes, a pool's later readers included, and
`testABlockingReadOrWriteFromTheMainThreadReachesTheGuardOnEveryStore` pins that after
`releaseMemory()`. Nothing in GRDB resets it. **One thing can remove it:** SQLite keeps one
trace per connection, so a later `db.trace(…)` for timing would replace the guard silently.
Add `.trace(` outside `MailStores.swift` to the source scan.

**Per statement, top level:** no SQL text and no Swift string. SQLite calls a C function;
GRDB's thunk takes an unretained reference to its `Database`, fills a four-field struct of
pointers (`sql` is computed only if asked, and nothing asks) and calls the closure. The
closure calls `MailMainQueueGuard.requireOffMainQueue`, which is: **`NSLock.lock`, a closure
load, `unlock`**, then `dispatch_assert_queue_not` and `Thread.isMainThread`. On the order of
a tenth of a microsecond uncontended — well under one per cent of a 30–100 µs page read, so
the gate's "twice the median" is not at risk from it.

**It is more than a thread check in two ways.**

- *The lock is one lock for all nine connections.* Every statement on the index writer, both
  readers, the three blobs connections, the two search connections and intent passes through
  the same mutex — a `userInitiated` list read and a `utility` indexer contend on it for no
  reason. Rare, short, and avoidable.
- *A nested statement has its SQL copied — by SQLite, not by us.* With any statement trace
  installed, a statement that starts while another is running on the connection is reported
  as `"-- " + its SQL`, allocated and freed for the call. FTS5's own shadow-table statements
  inside a `MATCH` or an insert are nested; so is a statement run while a cursor is being
  stepped. Tens per search. No form of the trace avoids this; only not tracing does.

**The cheap form.** In the trace closure: `if pthread_main_np() != 0 {
MailMainQueueGuard.requireOffMainQueue("a statement") }`. The passing path is one call and no
lock; the test seam is untouched, because a test only ever looks at the failing path. The
`dispatchPrecondition` adds nothing for a statement, as the file's own comment explains.

**Two things to decide on purpose, not by default:**
- It traps in Release. A stray blocking read on his phone is then a crash, not a hitch. That
  is what the opening guard already does; a statement guard multiplies the places.
- If P09a's search rows show the nested copies, leave the trace off the search reader, or make
  the trace Debug-only. Measure with and without before the medians are recorded.

For P09a: `MailBenchVerification.runIfRequested()` sits beside launch checks that run on the
main thread. A bench run there now stops at its first statement.

## 2. The `.atomic` default

Require the argument. A default is right when forgetting it is harmless; here forgetting it is
the fault MAJOR 5 was about, and nothing would show it. There will be half a dozen call sites
in the whole engine. `protection:` already has no default for the same reason.

`quarantine: MailQuarantine? = nil` (`:215`, `:250`) has the same shape: forget it on a stored
attachment and a `.command` file is on the Mac unquarantined, silently. Require it too, with
`nil` written out where none is meant. I see no reason not to; the tests gain an argument.

## 3. The kept-logs `defer`

Right. `commit` (`MailWriter.swift:229-254`) has three exits — the intent step threw, the index
step threw, both returned — and the `defer` runs on each, after `failed` or after the sink.
The two new tests pin the order for all three. A piece cannot be cancelled: the queue is a
`DispatchQueue`, and `perform`'s caller being cancelled does not stop its work. Work handed to
`perform` is not a piece and is not followed by a check, as 4.2 now says.

It cannot run inside an action. By the time it runs, that piece's commit has returned and its
sink has been told; what it delays is the *next* piece, which is what 4.2 prescribes.

One thing for P14a: the check also runs after an intent step that threw because the store is
unavailable. `checkpointIfDue()` must be safe to call on a store that would not open.

## 4. The new writer tests

| Promise | Pinned? |
|---|---|
| A sink, an intent step or `failed` may submit | **Yes**, deterministically: each test waits on a gate for the follow-up to run *before* it settles. |
| `failed` is on the writer's queue | **Yes**, for both steps. |
| A checkpoint a reader held up stays due | **Yes**: gates hold the reader; 1, 2, 3, 3. |
| Many submitters | **Partly.** Exactly once, and each thread's order: yes. The lost wake-up: no. |

The lost wake-up strands work only until the next submission, and the test's own
`settle(writer)` at `:645` is a submission: it would start the drain the fault forgot, and
every assertion would pass. Have the pieces open a gate when the two-thousandth has run and
wait on it before settling, as the re-entrancy tests do. It stays a test of chance, but the
iterated runs then mean something.

Gate and rendezvous timeouts now fail the test, by name. Good.

## 5. What the fixes introduced

- **The search reader's cache is now 4 + 3 + 1 MB.** The spike that measured search
  (`spikes/grdb/Sources/mailgrdb/main.swift:119-120`) set a bare `cache_size=-8192` and
  attached `idx` alone: 8 MB on `main` and SQLite's default, another 8 MB, on the index. So
  the design's search figures were taken with up to 16 MB, half of it on the file a search
  joins against, and 4 + 3 is new. The split is the implementer's guess and a fair one;
  P09a's search rows should decide it, and 4.2 should say the measured figures predate it.
- **`cannotOpen` also covers a migration that failed** (`MailStores.swift:258-266`). For P33:
  only `SQLITE_NOTADB` and `SQLITE_CORRUPT` mean a damaged file. A migration that hit
  `SQLITE_FULL` is not a reason to rename `index.sqlite` aside.
- **`MailDiskWatch.state()` traps on the main thread** and is the only way to its answer
  (`MailDiskWatch.swift:39-50`). The status model that says "nearly full" will want the last
  answer there; P23a must carry it across, or the watch needs a reader that does not look.
- **P02's commit edits `MailClock.swift`**, P01a's file — two comment lines, at this review's
  prompting. Harmless; 18.1 says no, so the entry's *Touches* should say so.
- **`journal_size_limit`** leaves each log file standing at 8 MiB once it has grown: 32 MiB
  across four stores until the next `TRUNCATE`. Not a problem; said so nobody is surprised.

## Checked and correct in the fixes

The pragma is on every writer, intent included, and read back from each; `checkpoint_fullfsync`
is set and read back on the three cache writers. The clamp is applied before the rule is asked,
and the Simulator's 12,718,472 → 8,388,608 matches the Mac's 12,714,352 → 8,388,608. `keep`
takes the lock; `truncateCheckpoint()` empties the index's log first, on the writer's queue.
An opening error names its store for all four, and `notDurable` and `newerThanThisVersion`
pass through unwrapped. The attached caches are set by name after each `ATTACH` and the 31 MiB
is now summed from what the connections say. `.synced` syncs the bytes before the move and the
directory after; a failure at either leaves nothing half-installed. The source scan refuses a
connection made outside `MailStores`, a snapshot, an observation and `.erase(`.
