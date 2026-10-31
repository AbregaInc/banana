# Mail: reuse review — what the designs hand-build that a standard component already does

5 Oct 2026. Reviewed: `docs/design/MAIL-ENGINE.md` (EN, line numbers as of today),
`docs/design/MAIL-UX.md` (UX), the repository, `review/security-privacy.md`,
`review/data-safety.md`, `review/engineering.md`, `research/gmail-api.md` (dossier).

Everything marked **RAN** was compiled and run today in
`scratchpad/review/reuse-spikes/` on this Mac (M1 Max, macOS 26.6.2, Xcode 27 / Swift 6.4,
SDKs MacOSX27.0 / iPhoneOS27.0, system SQLite 3.51.0, system libxml2 2.9.13). Another agent
was measuring on the same machine; the 1-minute load average was between 19 and 170 during
my runs and is printed beside every number. Treat every timing as rough and as *relative*:
candidates were always timed in the same process, seconds apart.

Package facts come from the checked-out sources (`.build/checkouts/…`) and from the GitHub
API (`gh api repos/…`) today. Web search was unavailable for part of the session; what I could
not confirm from a primary source is in section 5.

Recommendation codes: **REMOVE** (reshape so it disappears) · **REPO** (already in this
repository) · **SYSTEM** (SDK framework or library) · **PACKAGE** (open-source dependency: the
owner's decision) · **BUILD** (hand-built is right; smallest surface stated).

---

## 1. Inventory

| # | Component | Where specified | Hand-built size | Rec. | Chosen alternative | Confidence |
|---|---|---|---|---|---|---|
| 1 | SQLite layer: C-API wrapper, statement cache, serial queues, reader pool, async bridging, error mapping | EN §4 l.347–352, §4.2 l.412–458; P02 l.2893–2906 | ≈ 500 of P02's ≈ 900 lines + tests | **PACKAGE** | GRDB 7.11.1 (`DatabasePool` / `DatabaseQueue`) | High that it fits (13 checks ran); the choice is the owner's |
| 2 | Migrations (`MailMigrator`), "newer than the code" refusal | EN §4.9 l.919–937; P02 | ≈ 150 lines | **PACKAGE** | GRDB `DatabaseMigrator`, `hasBeenSuperseded` | High (ran) |
| 3 | Change notices (`MailChangeHub`, `MailStoreChange`) | EN §13.4 l.2530–2553 | ≈ 150 lines | **BUILD** | Keep. With GRDB, publish from `db.afterNextTransaction(onCommit:)` | High |
| 4 | HTML tokenizer / parser under the sanitiser (`MailHTMLTokenizer`) | EN §10.2 l.2057; P20 l.3086–3095 | ≈ 450 of P20's ≈ 1,400 | **PACKAGE** | SwiftSoup 2.13.9 as the tree; if no package is wanted, **SYSTEM** libxml2 2.9.13. Never a hand tokenizer | High that a parser must replace it; medium on which |
| 5 | The allow-list walk and serialiser (`MailHTMLPreparer`) | EN §10.2 l.2059–2085; security review's allow-list | ≈ 300 lines | **BUILD** | On the tree; output re-serialised, never spliced | High |
| 6 | HTML → own text, snippet (`MailText.ownText`) | EN §4.6 l.756–760; P04 l.2920–2925 | ≈ 250 lines | **REMOVE** | A second walk of the same tree; no second tokenizer. Not `ShowNotes` | High |
| 7 | HTML fragment → `AttributedString` (`MailNativeText`) | UX §6.2.5 l.1236, U7 l.3279–3281; EN §13.3 l.2525 | ≈ 250 lines | **REMOVE** | The engine emits native runs from the same parse; the UI maps runs. Layout rules from `ShowNotes.Builder` (**REPO**) | High |
| 8 | Entity decoding | implied by P04 l.2921 ("entities") | ≈ 40 lines + a table | **REMOVE** | The parser's | High |
| 9 | CSS filter (`MailCSSFilter`) | EN §10.2 l.2063–2066; P20 | ≈ 350 lines | **BUILD** | Nothing at levels 1–4 fits (B-7). Declarations first | Medium |
| 10 | Quoted-reply detection (`MailQuoteDetector`) | EN §10.2 l.2078–2080 | ≈ 200 lines | **BUILD** | A selector list on the tree plus one line pattern | High |
| 11 | Tracker host list (`MailTrackers.json`) | EN §10.2 l.2075–2077; P20 l.3089 | a hand-compiled file | **PACKAGE** (data) | Vendor an established list with its licence and an update script (B-14) | Medium |
| 12 | Plain-text linkifier | EN §10.2 l.2081 | ≈ 30 lines | **BUILD** | Tiny explicit rule (the security review excludes `NSDataDetector` here) | High |
| 13 | MIME builder: multipart, folding, headers (`MIMEBuilder`, `MailHeaderCoding`) | EN §7.2 l.1580–1595; P16 l.3053–3059 | ≈ 700 of P16's ≈ 1,100 | **BUILD** | No system or established package exists. Shrink to ≈ 300 lines (B-6) | High |
| 14 | Base64 for parts, RFC 2047, RFC 2231 | EN §7.2 l.1588–1589 | inside 13 | **SYSTEM** | Foundation base64 (76-column wrap), B-encoding only, percent-encoding. Quoted-printable stays a 40-line encoder | High |
| 15 | A raw-MIME *parser* implied by P16's round-trip test and by `FakeGmail` taking `MIMESource` | P16 l.3057; EN §5.1 l.1020–1023 (`MIMESource` is never defined) | unplanned, ≈ 300 lines | **REMOVE** | `MIMESource` carries the structured draft beside the bytes; golden files checked by an outside oracle at development time | High |
| 16 | MIME structure extraction (`MIMEStructure.extract`) | P03 l.2908–2918 | ≈ 200 lines | **BUILD** | It is a walk of Gmail's already-parsed `payload` JSON, not a MIME parser. Keep it that way: never `format=raw` | High |
| 17 | Charset decoding of parts | P03 l.2911 | unspecified | **SYSTEM** | `CFStringConvertIANACharSetNameToEncoding` (ran: 12 of 12 names) | High |
| 18 | Address-list parser, RFC 2047 decoding (`MailAddress`) | P03 l.2913 | ≈ 250 lines | **BUILD** | No SDK API (headers searched). One parser, used by the composer too. Whether Gmail has already decoded headers is unverified | Medium |
| 19 | `Base64URL`, `Base64URLStreamDecoder` (a hand decode table) | P03 l.2914; EN §11 l.2203–2207; P21 l.3098 | ≈ 150 lines | **SYSTEM** | Foundation's decoder, 64 KB at a time (ran: 41 ms for 25 MB) | High |
| 20 | Gmail batch codec (`GmailBatchCodec`), adaptive batch size | EN §5.1 l.1046–1055, §5.2 l.1096–1098, §6.5 l.1484; P22 l.3107 | ≈ 300 lines + fixtures | **REMOVE** | Plain requests over the one HTTP/2 connection (ran) | Medium-high; one probe item settles it |
| 21 | Resumable upload framing (`GmailUpload`) | EN §5.1 l.1055, §7.3 l.1620–1621; P22 l.3107 | ≈ 200 lines | **REMOVE** for release one | One request per upload; later `GTMSessionUploadFetcher`, which is already linked (**REPO**-adjacent) | Medium |
| 22 | Gmail JSON models, HTTP client, error mapping | P03 `GmailWire`; P22 | ≈ 900 lines | **BUILD** | `Codable` + `URLSession` are the standard parts. Google's generated client considered and not recommended (B-17) | High |
| 23 | iCalendar parser (`MailInvite.parse`) | P28 l.3184–3187; UX R9 l.2962 | ≈ 350 lines | **REMOVE** | Read `METHOD` and `UID` only; the event's facts come from Google Calendar | High |
| 24 | Which event an invitation is (`MailInvitationResolver`) | UX §9.1 l.2284–2286; U13 | ≈ 100 lines | **REPO** | By iCalUID: `GoogleEvent.iCalUID`, `GoogleEventWindow.index`, `GoogleCalendarService.events(calendarID:iCalUID:)` | High |
| 25 | `List-Unsubscribe` rules | P28 l.3187–3188 | ≈ 100 lines | **BUILD** | Small; `URLComponents` for the `mailto:` part (ran) | High |
| 26 | Search-query parser (`MailQueryRules.parse`) | EN §9.1 l.1916–1948; P08 | ≈ 400 lines | **BUILD** | Gmail's grammar; no standard. One tokenizer that reports ranges | High |
| 27 | Operator ranges in the typed text (`MailQueryRanges`) | UX §6.4.4 l.1541–1544; U11 l.3331 | ≈ 150 lines | **REMOVE** | A second tokenizer of the same grammar; take ranges from 26 | High |
| 28 | Building the FTS5 `MATCH` expression from typed words | EN §9.1 l.1938 | inside 26 | **PACKAGE** | GRDB `FTS5Pattern` (comes with row 1); else one quoting rule | High |
| 29 | Quota governor (`QuotaRules`) | EN §5.2 l.1057–1113; P11 | ≈ 600 lines | **BUILD** | Pure arithmetic; no library | High |
| 30 | Attachment types, previews, thumbnails, sizes, pickers | EN §11 l.2223–2224; UX §6.2.6 l.1273–1286, §6.3.5 l.1405–1413 | unspecified | **SYSTEM** | `UniformTypeIdentifiers`, QuickLook, `QLThumbnailGenerator`, `.byteCount` format, `PhotosPicker`, `fileImporter` (ran the pure ones) | High |
| 31 | zlib wrapper (`MailCompression`) | EN §4.7 l.854–855; P04 l.2923 | ≈ 60 lines | **SYSTEM** / **REPO** | `(data as NSData).compressed(using:)`, as five files here already do | High |
| 32 | Typed times (`MailTimePhrase.parse`) | UX §6.5.2 l.1627–1640; U8 | ≈ 200 lines | **REPO** | `EventPhrase.takeDate` plus one span pattern and four words (B-9) | High |
| 33 | `DateText` | UX §5.2 l.882 | ≈ 120 lines | **BUILD** | A rule over `Date.FormatStyle`, beside `TimeRangeText` (**REPO**). No hand-assembled month order, no literal "Yesterday" | High |
| 34 | The composer's rich-text editor and its five formats | UX §6.3.4 l.1396–1398 | unspecified | **SYSTEM** | `TextEditor(text: AttributedString, selection:)` + `AttributedTextFormattingDefinition` (compiles for macOS 26.0 and iOS 26.1) | High |
| 35 | `AttributedString` → HTML for a draft's body | missing from both documents (engineering review E-33.1) | ≈ 80 lines | **BUILD** | The system HTML writer was run and is unsuitable (B-11). HTML → runs is row 7's parse | High |
| 36 | Recipient ranking | EN §9.5 l.2022–2025 | — | **REPO** | `GuestSources.people()`, `GuestDirectory` — as designed | High |
| 37 | Link rules: IDN hosts; "registrable domain" | EN §10.4 l.2143–2146; security review P-5 | ≈ 150 lines | **SYSTEM** + **REMOVE** | `URLComponents.encodedHost` gives the `xn--` form (ran). Do not hand-roll a public-suffix guess (B-13) | High |
| 38 | RFC 3339 time in `X-Banana-Send-At` | EN §7.6 l.1756 | — | **SYSTEM** | `Date.ISO8601FormatStyle` (ran) | High |
| 39 | `Date:` header as a fallback sort date | EN §5.5 l.1249–1252 | ≈ 60 lines | **REMOVE** | Do not parse RFC 5322 dates; without `internalDate` a row keeps its stub order | Medium |
| 40 | `MailLink.conversation(from:)` and `MailReference` | UX §9.2 l.2300–2306; EN §13.7 l.2583–2588 | two copies | **SYSTEM** | One implementation over `URLComponents` | High |
| 41 | Reply addressing and subject rules, specified twice (`ReplyRules`, `MailDraft.reply`) | EN §7.2 l.1598–1608; UX §6.3.3 l.1374–1380, U9 | two copies | **BUILD** once | One pure file both sides use (engineering review, table row 22) | High |
| 42 | `first-page.json`, `render-heights.json` | EN §4.11; UX §6.2.7 l.1298–1300 | — | **REPO** | `SnapshotLoader` for load-or-quarantine | High |
| 43 | Web view sandbox | EN §10.4 | — | **SYSTEM** | `WKWebView`, `WKContentRuleList`, `WKURLSchemeHandler` — as designed | High |
| 44 | Remote image loader and cache | EN §10.5 l.2178–2180 | ≈ 250 lines | **BUILD** | `ImageCache` (**REPO**) does not fit: it downsamples for artwork, imports UIKit/AppKit, and has none of the privacy rules | High |
| 45 | FTS row id hash (FNV-1a), `MailClock`, journal seam | P04, P02 | < 100 lines | **BUILD** | Trivial; `Hasher` is not stable between launches | High |
| 46 | Keys, command registry, toast | UX U5, U12, §5.2 l.886 | — | **REPO** | Extend `MacKeyMonitor`, `MacCommand`, `ToastCenter` — as designed | High |
| 47 | On-device model | EN §13.7 l.2589–2595 | seam only | **REPO** | `Intelligence` — as designed | High |

Counts over the 47 rows: REMOVE 9 (6, 7, 8, 15, 20, 21, 23, 27, 39; plus the
registrable-domain half of 37) · REPO 7 (24, 31, 32, 36, 42, 46, 47) · SYSTEM 9 (14, 17, 19,
30, 34, 37, 38, 40, 43) · PACKAGE 5 (1, 2, 4, 11, 28 — **two libraries and one data file**) ·
BUILD 17.

---

## 2. Findings

### B-1 · The SQLite layer · PACKAGE (GRDB)

**Where.** EN §4 l.347–352: "SQLite through the system library and the raw C API, no
dependency… Nothing about the raw API was found materially unsafe once those four rules hold,
so the decision stands." P02 (l.2893–2906) is "the only code that touches the C API": open
flags, statement cache, typed binds and readers, `transaction`, `interrupt`, `checkpoint`,
`quickCheck`, an error type, a queue type, a migrator.

**The precedent is thinner than the decision assumes.** What the repository has is
`FoodSQLite` (`Banana/Model/FoodDatabase.swift:501–556`) and the same shape in
`BarcodeProductLookup.swift`: 55 lines, read-only, one bundled file, one argument type
(`.text`), every error turned into an empty result. There is no writer, no WAL, no migration,
no transaction and no second connection anywhere in the repository. Mail asks for all of those
in four files.

**Candidate: GRDB.swift.** Facts from the checkout and the GitHub API today:

| | |
|---|---|
| Repository, licence | github.com/groue/GRDB.swift · MIT |
| Latest release | v7.11.1, 18 Jun 2026; last push 29 Sep 2026 |
| Signals | 8,675 stars; 12 open issues; 0 published repository security advisories; 3,239 test functions in `Tests/GRDBTests`; one principal maintainer (Gwendal Roué) since 2015 |
| Platforms, Swift | iOS 13+, macOS 10.15+; `swift-tools-version:6.1`, built in Swift 6 mode; **consumed from a Swift 5-mode target without complaint** (the spike is compiled with `-swift-version 5`) |
| Dependencies | None. It links the system SQLite and defines `SQLITE_ENABLE_FTS5` |
| Size | 167 files, 71,241 lines. Clean release build 43.9 s here at load ≈ 170. The spike's stripped executable is 3.2 MB (`__TEXT` 2.28 MB) — an upper bound on what it adds |
| Other candidates | SQLite.swift (MIT, 10,185 stars, 139 open issues): a typed query builder; no pool, no migrator. Core Data / SwiftData: no FTS5, no control of WAL. Neither fits |

**Does it carry this design's specific needs?** RAN (`sqlspike/Sources/sqlspike/main.swift`;
`swift build -c release && .build/release/sqlspike <dir>`; output in `sqlspike/run2.txt`):

```
GRDB 7.11.1 · SQLite 3.51.0 · load 69 135 199
  ok    DatabasePool opens index.sqlite in WAL
  ok    writer has wal_autocheckpoint=0
  ok    migrator ran once and reports not superseded
  ok    an older build sees the file as newer than itself (4.9: do not open)
  ok    TRAP: synchronous=FULL set in prepareDatabase is overwritten by GRDB's WAL setup (reads back synchronous=1, fullfsync=1)
  ok    intent: synchronous=FULL(2) and fullfsync=1 read back once set after opening
  ok    FTS5 contentless_delete: replace dropped the old terms, kept the new
  ok    FTS5 prefix query streams newest first by our row id
  ok    search connection joins the attached index read-only
  ok    attached index cannot be written through the read-only connection
  ok    explicit passive checkpoint through GRDB runs
  ok    interrupt() ends the search query with SQLITE_INTERRUPT in 0.3 ms; the pool's read was untouched (3333)
  ok    a file that is not a database throws 26 (file is not a database); message has no bound values
```

| The design needs | GRDB |
|---|---|
| Four files, one writer each, a reader pool in WAL | `DatabasePool` for `index` and `blobs`; `DatabaseQueue` for `intent` and the search writer. Opens `SQLITE_OPEN_NOMUTEX` itself (`Core/Database.swift:2391`) |
| `writer.index` and `writer.intent` on one queue (§4.2 l.433) | `Configuration.writeTargetQueue` / `targetQueue` on both — or simply two calls in order from the engine's own serial context. Not nested |
| Per-connection pragmas, auto-checkpoint off, explicit passive / truncate checkpoints | `Configuration.prepareDatabase`; `db.checkpoint(.passive)` |
| A separate search connection, the other files attached, interruptible alone | A read-only `DatabaseQueue` on `search.sqlite` that `ATTACH`es in `prepareDatabase`; `queue.interrupt()` touches only it. (`pool.interrupt()` interrupts *every* connection of a pool, writer included — so search must not share the index pool) |
| FTS5 with our row ids, `contentless_delete`, prefix indexes | Plain SQL through GRDB; it does not get in the way. `FTS5Pattern` builds safe `MATCH` text from typed words (row 28) |
| Group-committed full-fsync writes | Pragmas plus the engine's own 8 ms grouping; the library is neutral |
| Migrations; refuse a newer file | `DatabaseMigrator`; `hasBeenSuperseded`. (It records applied steps in a `grdb_migrations` table rather than `PRAGMA user_version`) |
| Corruption detected | `DatabaseError.resultCode` (`.SQLITE_NOTADB`, `.SQLITE_CORRUPT`) |
| Invariant 11: a reader never holds a transaction across a suspension | `pool.read { db in … }` takes a synchronous closure: it cannot contain an `await`. The rule becomes a compile error instead of a convention |
| Invariant 21: errors carry no values | `Configuration.publicStatementArguments` is `false` by default: bound values are redacted from `DatabaseError` |
| R17: queue confinement is by convention | GRDB traps when a connection is used off its queue (`SchedulingWatchdog.preconditionValidQueue`) — the check the design wanted Thread Sanitizer for |
| Cancelling a superseded query | Async reads cancel through the task (`withTaskCancellationHandler` in `SerializedDatabase.swift`), besides `interrupt()` |
| Change observation at batch granularity | Not GRDB's `ValueObservation` — keep §13.4 as designed ("the one writer says what it wrote") and publish from `db.afterNextTransaction(onCommit:)`, so a rolled-back batch can never announce itself |
| The hottest loops | `statement.sqliteStatement` and `db.sqliteConnection` expose the C handles, so a loop can still be written against the C API on GRDB's connection (timed below) |

So the design's requirements do **not** push outside what the library does well. They cut
against its grain in three places, each found by reading its source or by a failed check:

1. **Durability trap (found by the failing check).** `setUpWALMode()` runs *after*
   `prepareDatabase` and executes `PRAGMA synchronous = NORMAL` (`Core/Database.swift:531–539`,
   called from `DatabaseQueue.swift:57`, `DatabasePool.swift:81`). An implementer who sets
   `synchronous=FULL` for `intent.sqlite` in the obvious place gets `NORMAL`, silently, and
   invariant 4 ("committed with a full fsync") is false. It must be set after the queue is
   open, and a test must read both pragmas back.
2. **A write at open.** When the `-wal` file is missing or empty GRDB creates and drops a
   table (`grdb_issue_102`, same function). The design truncates the log on backgrounding
   (§4.2 l.454–455), so every activation pays one small commit per file — on `intent`, one
   full fsync. Off the main thread; to be counted in `activate()`'s budget.
3. **"Open one single DatabaseQueue or DatabasePool per database file"**
   (`Documentation.docc/Concurrency.md:19`). The design has the search and background readers
   attach files that another pool owns. That is ordinary SQLite and the check above passes,
   but it is the library's "Sharing a Database" territory, not its default; say so in P02.

Also: the `SQLITE_OPEN_FILEPROTECTION_…` open flag (§4.1 l.406–410) is not exposed —
protection is set on the directory, which new files inherit; and any `DatabaseWriter` has
`erase()` and `vacuum(into:)`, so `MailIntentStore` must keep its GRDB object private to
preserve "the type that owns it has no delete method" (invariant 5).

**Performance.** RAN, same file, same SQL (§4.4's page query, 70,000 threads), load ≈ 69:

```
3. The list page (§4.4): 50 rows, 15 columns, keyset
  raw C API, prepared once, called inline                    p50  0.0649 ms  p95  0.0769 ms  p99  0.1339 ms  (n=3000)
  raw C API behind a serial queue (what §4.2 specifies)      p50  0.0654 ms  p95  0.0785 ms  p99  0.1457 ms
  GRDB pool.read + cached statement + Row                    p50  0.1068 ms  p95  0.1326 ms  p99  0.2018 ms
  GRDB pool.unsafeRead (no transaction) + Row                p50  0.1013 ms  p95  0.1108 ms  p99  0.1354 ms
  GRDB pool.read + C API on its cached statement             p50  0.1019 ms  p95  0.1134 ms  p99  0.1668 ms
  GRDB pool.read + Codable FetchableRecord (the easy way)    p50  0.1788 ms  p95  0.1912 ms  p99  0.2187 ms
  unread count on the partial index, GRDB                    p50  0.0696 ms  p95  0.0721 ms
  plan: SEARCH v USING PRIMARY KEY (view_pk=? AND sort_key>? AND (sort_key,thread_pk)<(?,?)) | SEARCH t USING INTEGER PRIMARY KEY (rowid=?)
4. A 50-message write transaction (§4.12)
  GRDB pool.write, cached statements, 50 messages            p50  0.4277 ms  p95  0.4844 ms  p99  5.4986 ms  (n=300)
  raw C API, prepared once, 50 messages                      p50  0.2955 ms  p95  0.3370 ms  p99  1.2388 ms
5. Intent commit, three rows, full fsync (§4.2)
  GRDB DatabaseQueue.write                                   p50  0.2744 ms  p95  1.0023 ms  p99  2.9464 ms  (n=150)
  raw C API                                                  p50  0.1869 ms  p95  0.4064 ms  p99  0.6953 ms
```

GRDB costs about 0.04 ms a page, 0.13 ms a 50-message transaction and under 0.1 ms a commit.
The budgets are 5 ms, 30 ms and 20 ms (EN §15 l.2679, 2688, 2684). The query plan is the
same, because the SQL is the same. (My fsync figures are far below the engine's 2.98 ms; I
could not explain the difference and did not chase it — see section 5. The comparison between
the two rows stands; the absolute number does not.)

**Security.** Neutral: values are bound either way. GRDB removes one hand-written thing that
takes typed text — the `MATCH` expression (row 28).

**Recommendation: take GRDB, pinned `exactVersion: 7.11.1` as `project.yml` pins the other
two.** Not for speed — the raw API is faster and both are far inside budget — but because the
bugs a hand wrapper grows are exactly the ones this design cannot afford and less experienced
implementers will not see: a statement left un-reset after a thrown error holds a read
transaction open (the design's own 486 MB log, l.991–992); a deferred transaction that
upgrades to a write fails `SQLITE_BUSY` at once in WAL, ignoring `busy_timeout`; an empty
`Data` bound as a blob becomes `NULL`; a `NULL` text column read as a C string; a rollback
missed on one path. GRDB has had those beaten out of it.

**What changes.**
- P02 shrinks from ≈ 900 to ≈ 350 lines: `MailSQLite.swift`, `MailDatabaseQueue.swift` and
  `MailMigrator.swift` go; `MailDirectories`, `MailJournal`, `MailClock` stay; a new
  `MailStores.swift` (≈ 150 lines) holds the four configurations and nothing else. Its tests
  become: both pragmas read back on `intent`; `wal_autocheckpoint = 0` on every writer; a
  reader sees the last commit mid-write; interrupt; the SQLite version and `contentless_delete`.
- P06, P07, P08, P14 lose their binding and column-reading boilerplate (a rule of thumb, not
  measured: 15–20 % of each).
- Invariant 17's list (l.110–113) gains `GRDB`. `project.yml` gains the package and a
  dependency on `Banana`, `BananaBeta`, `BananaMac`, `BananaMacBeta` and `BananaTests`
  (an iOS unit-test bundle; a package dependency there is ordinary). P01 already edits
  `project.yml`.
- §4.9: `schema_version` / `PRAGMA user_version` becomes GRDB's migration table;
  `derived_version` stays in `meta`.
- §21 rows to re-measure through the real layer: every row of §4.4's and §4.12's tables,
  the intent commit, the interrupt time, and `activate()` (which now includes finding 2).
- Written only because of the hand-built choice and now moot: l.347–352; the `NOMUTEX`
  sentence (l.417–418); `SQLiteError` "whose description never includes bound values"
  (l.2897); R17's "Thread Sanitizer at M2" as the only check.
- House rules to put in P02: no `ValueObservation`; no Codable records on a list's path
  (0.18 ms against 0.11 ms — harmless, but the wrong habit); one GRDB object per role, named
  as §4.2 names connections.

**If the owner says no:** keep the wrapper, and make the list above P02's test list —
`BEGIN IMMEDIATE` for every write, reset-on-throw, empty blobs, `NULL` text, and a test that a
thrown error inside a read leaves no transaction open.

---

### B-2 · The HTML parser under the sanitiser · PACKAGE (SwiftSoup), with SYSTEM (libxml2) as the fallback — never a hand tokenizer

**Where.** EN §10.2 l.2057: "A tokenizer walks the document once and writes a new one." P20
creates `MailHTMLTokenizer.swift` (l.3087). The measured basis is §21 l.3413: "Tag walk and
rewrite 320–415 MB/s". The security review (P-3) requires either the WHATWG tokenizer's states
written out, or libxml2 as the tree source, and in both cases output "serialised from an
allow-listed tree", never "spliced from input substrings".

**The engine's measured number is for the thing that may not ship.** The spike behind §21
(`spikes/content_spike.swift:41–60`) copies input bytes to the output and looks for `<`. Re-run
today beside the candidates: `prepare pass: 62907 bytes … p50 0.149 ms (402 MB/s)`,
`261257 bytes … p50 0.618 ms (403 MB/s)` at load ≈ 165. Any real parse is 6 to 90 times
slower than that (below). Whatever is chosen, §21's row, §15 l.2682, P20's "a 260 KB fixture
under 10 ms" (l.3095), P04's "under 5 ms" (l.2924) and the security review's "a 2 MB fixture
prepares under 50 ms" must be restated.

**Candidates.**

| | libxml2 HTML parser (**SYSTEM**) | SwiftSoup (**PACKAGE**) | Hand-written tokenizer (**BUILD**) |
|---|---|---|---|
| What it is | C; `libxml/HTMLparser.h`. In all three SDKs: `usr/lib/libxml2.tbd`, headers and a module map; version 2.9.13 (`xmlversion.h:37`; the runtime prints 20913). `import libxml2` type-checks for `arm64-apple-ios26.1` and `-simulator` (RAN, `sys/xmlios.txt`) | Pure Swift port of jsoup. github.com/scinfu/SwiftSoup · MIT · 2.13.9, 27 Aug 2026; pushed today; 5,126 stars; 2 open issues; 0 published advisories; 686 test functions; no dependencies; iOS 13+, macOS 10.15+; `swift-tools-version:6.0`; 60 files, 34,687 lines; stripped spike 3.7 MB (`__TEXT` 3.0 MB) | ≈ 450 lines nobody has written yet |
| Parsing model | HTML 4 era. Upstream's 2.14 notes say "The HTML tokenizer now conforms fully to HTML5… HTML5 tree construction isn't implemented yet" — and Apple ships 2.9.13, which has neither | WHATWG-style tree builder: adoption agency, table fix-ups, `noscript` as with scripting off. Not exact — see below. `HtmlTreeBuilder.swift:1121–1122, 1338` still say "todo: namespaces" | Whatever the implementer manages |
| Memory safety on hostile mail | C in the app's own process, which holds the Google tokens. Apple patches it with the OS. (The app already feeds remote XML to it: `FeedParser.swift:64` uses `XMLParser`.) | Swift; 158 lines mention `Unsafe…` (`StringBuilder`, `CharacterReader`, `Entities`, `ByteSlice`), the rest is checked. A bug is a trap, not a corruption | Swift |
| What implementers write | Pointer code: `pointee`, `xmlNodeListGetString` + `xmlFree`, `xmlFreeDoc`. Containable in one ≈ 150-line file, but it is the kind of file that leaks or double-frees | Ordinary Swift over `Element`, `TextNode`, `Attributes`; CSS selectors for the quote detector | A state machine with 80 states |
| Off the main thread; in `BananaTests` | Yes; yes (a linked system library) | Yes; yes (a package dependency) | Yes; yes |
| Maintenance risk | None of ours | High churn: 198 commits since Oct 2025, most by one contributor's performance rewrite. Pin the exact version | All ours |

**Parsing differences are real in both — measured, not assumed.** RAN
(`htmlspike hostile`; full output `htmlspike/hostile.txt`). The same allow-list walk over each
tree, plus SwiftSoup's own `Cleaner` with `Whitelist.relaxed()`:

```
[empty-comment] in:  <!--><img src=x onerror=alert(1)>--><p>after</p>
  libxml2   out: <p>after</p>                       ← read the whole run as a comment; WebKit sees an <img>
  SwiftSoup out: --&gt;<p>after</p>                 ← saw the <img> (HTML5), dropped it
[duplicate-attrs] in:  <img src="cid:a@b" onerror="1" SRC="https://evil.example/x.png" width=10>
  libxml2   out: <img src="banana-mail://cid/m/a@b" width="10">            ← first wins, as in HTML5
  SwiftSoup out: <img src="banana-mail://remote/768d99…" width="10">      ← LAST wins; WebKit uses the first
[misnested] in:  <p>one <b>bold <i>both</b> italic</i><table><tr><td>cell<div>foster</table>tail
  libxml2   out: <p>one <b>bold <i>both</i></b> italic</p><table><tr>…     ← " italic" lost its <i>
  SwiftSoup out: <p>one <b>bold <i>both</i></b><i> italic</i></p><table><tbody><tr>…
[unterminated] in:  <div title="never closed><script>alert(1)</script><p>hidden?</p>
  libxml2   out: <div title="never closed&gt;&lt;script&gt;…"></div>       ← HTML5 drops the tag at EOF
  SwiftSoup out:
[noscript-pixel] in:  <noscript><img src="https://t.example/p.gif" width=1 height=1></noscript><p>x</p>
  libxml2   out: <img src="banana-mail://remote/3ad2…" width="1" height="1"><p>x</p>
  SwiftSoup out: <p>x</p>                            ← left the pixel in <head>, where the walk drops it
[math-mglyph-mxss] …
  SS.clean  out: <img title="--><img src=1 onerror=alert(1)>" />⏎<table></table>   ← the built-in Cleaner
```

Three conclusions the design should state:

1. **No candidate parses exactly as WebKit does.** libxml2 disagrees on comments, misnesting
   and unterminated tags; SwiftSoup on duplicate attributes and `noscript` in `head`. A
   sanitiser that copied through anything it "understood" would be bypassable with either.
2. **Safety therefore rests on canonical re-serialisation plus the inert web view, not on the
   parser.** Every output above came from walking a tree and writing allow-listed elements
   with text escaped and attribute values re-quoted; nothing raw-text, foreign or commented is
   ever written. Across all twelve hostile fragments, and each output re-parsed by the *other*
   parser, the check for `<script`, handlers, script URLs, `<style` and unrewritten remote URLs
   was `unsafe=false`. A 15-second tag-soup smoke fuzz per parser on a 512 KB stack:
   `fuzz xml: 492587 documents, 244996 KB, no crash, no unsafe output` ·
   `fuzz soup: 173529 documents, 86316 KB, no crash, no unsafe output`. 100,000 nested
   `<div>`s: both survive (`deep.txt`); libxml2 stops parsing at depth 255.
3. **SwiftSoup's built-in `Cleaner` is not the sanitiser.** It cannot rewrite URLs to
   `banana-mail:`, count trackers, filter CSS, unwrap rather than drop, or enforce limits, and
   it leaves `<`/`>` unescaped inside attribute values (last line above). Use SwiftSoup as a
   parser and tree; write the walk (row 5).

**Performance.** RAN (`htmlspike bench`, the engine spike's own newsletter generator so the
sizes match §21; output `bench2.txt`, `bench3.txt`; load ≈ 110–150):

| | 62,907 bytes, p50 | 261,257 bytes, p50 |
|---|---|---|
| Hand tag-walk that splices (the §21 baseline, not shippable) | 0.149 ms | 0.618 ms |
| libxml2, parse only | 0.82 ms | 3.5 ms |
| libxml2, parse + own text only (the sync-time path) | 0.88 ms | 3.6 ms |
| libxml2, parse + allow-list walk + serialise + text | 3.7 ms | 15.2 ms |
| SwiftSoup, parse only | 2.2 ms | 9.5 ms |
| SwiftSoup, parse + `text()` | 2.6 ms | 10.0 ms |
| SwiftSoup, parse + the same walk + serialise + text | 13.4 ms | 55.7 ms |
| SwiftSoup's own `clean(Whitelist.relaxed)` | 17.9 ms | 74.7 ms |

The walk is my untuned spike code (string sets, an array of attributes per element, SHA-256
per URL) and dominates both totals; a tuned walk will be faster for both. As they stand:
libxml2 is about 3.6 times faster end to end. Neither is on the main thread, both results are
cached in `prepared`, and `warm` runs them before the conversation is opened. Against what a
person can feel — "open in 50 ms" for native mail of a few kilobytes (UX U6), 150 ms for a web
paint (U7) — both fit: a 5 KB message is about 1 ms with SwiftSoup, 0.3 ms with libxml2.
Against the numbers written in the packages today, neither fits (above).

**Recommendation.** SwiftSoup as the tree, pinned `exactVersion: 2.13.9`, behind one small
seam (`MailHTMLTree`: parse → a walkable value) so that the three walks (rows 5, 6, 7) never
name the library. Reasons, in order: it is memory-safe where the input is written by
strangers and the process holds the tokens; implementers write no pointer code; its tree is
closer to what Gmail's own page shows for sloppy markup; its selectors make the quote detector
a list. Cost: one dependency, about 3 MB, and 3–4 times libxml2's time, inside every budget a
person can feel. **If the owner prefers no new package for this, libxml2 fits** — in one
≈ 150-line file, with `HTML_PARSE_RECOVER | NOERROR | NOWARNING | NONET | IGNORE_ENC`, UTF-8
passed in after Foundation has decoded the charset, a depth cap, and the same walk. Either
way the differential test the security review asks for is free on the test host: the *other*
parser is the oracle (libxml2 is in every SDK), and WebKit is the oracle in P26's UI test.

Considered and set aside: **WebKit itself as the parser** (a hidden web view, or the HTML
Sanitizer API) — the only way to get zero difference, but it needs a web view, cannot run in
`BananaTests`, cannot produce own text for 200,000 messages at sync, and removes the second of
§10.1's two layers. **`NSAttributedString(html:)`** — ruled out by the repository's own history
(`ShowNotes.swift:6–9`) and by the security review. **lexbor** (C, Apache-2.0, v3.0.0 of
31 Mar 2026, 2,100 stars; bundled in PHP as `ext/lexbor`) — HTML5 tree construction *and* a
CSS parser, the best technical fit, but C in-process, no Swift package I could find, and ours
to vendor and wrap. It is the upgrade path if fidelity or CSS becomes the problem.
**Kanna, Fuzi** — Swift wrappers over libxml2; they add a dependency without changing the
parser.

**What changes.** P20 loses `MailHTMLTokenizer.swift` (≈ 450 lines, the riskiest file in the
plan) and gains `MailHTMLTree.swift` (≈ 100). A crash rule is added, because a Swift trap on
one message would otherwise recur at every sync: mark a message "being parsed" before parsing,
and treat one found so marked at launch as text-only. Invariant 17 gains `SwiftSoup`.

---

### B-3 · Three more HTML readers are hiding in the plan · REMOVE (one parse, three walks)

**Where.** P04 (l.2921): `ownText(html:plain:)` — "tags to text with block breaks, entities,
quoted replies and forwarded originals removed". U7 (UX l.3279): `MailNativeText` — "a prepared
`.plain` or `.simple` fragment → `AttributedString`". U9 / E-33.1: a draft's `body_html` must
become an `AttributedString` to be edited. P16 (l.1586): "text/plain derived from the HTML".
P04 and P20 "can start together" (l.2890), so two implementers would write two tokenizers in
the same week; U7 would write a third, in the UI, over the engine's output (the engineering
review notes the second parse, E-33.2).

**Already in the repository:** `ShowNotes.attributed(_:)` (`Banana/Model/ShowNotes.swift`,
163 lines): a regular-expression tag walk for podcast notes, with 17 named entities. It is
right for what it does and wrong to copy: its tokenizer has the differences B-2 lists and
more (a `>` inside an attribute ends the tag). For text that is only indexed that is a quality
problem, not a hole — but the text searched should be the text shown. What *is* worth reusing
is its `Builder` (l.93–163): whitespace collapsed as a browser would, breaks owed until the
next text, links as runs. Lift it out and feed it from the tree.

**Change.** One new package ahead of P04 and P20, "the HTML tree" (`MailHTMLTree`, B-2), and
three walks of it:
- `MailText.ownText` — text only, quote subtrees skipped (P04 shrinks by ≈ 250 lines);
- the preparer (P20);
- `PreparedBody.native: [MailNativeRun]?` — text, bold, italic, underline, strike, link,
  block kind, quote depth — emitted by the same walk that sanitises, stored in `prepared`.
  `MailNativeText` in the UI becomes a ≈ 40-line map from runs to `AttributedString`, with no
  HTML in it. That also satisfies the security review's P-4 ("a converter over the sanitiser's
  *tree*, not over HTML text again").
The composer loads a draft's HTML through the same runs, and P16's `text/plain` alternative
is `ownText` without the quote rule.

---

### B-4 · The `multipart/mixed` batch codec · REMOVE

**Where.** EN §5.1 l.1053–1055; `GmailBatchCodec.swift` with its fixtures and tests (P22
l.3107–3110); the adaptive batch size (§5.2 l.1096–1098); "in one HTTP batch" (§6.5 l.1484).
It is a writer *and* a parser: nested HTTP status lines, headers and bodies inside MIME
boundaries, from the network.

**Why it is not needed.**
- Quota is identical: "A set of n requests batched together counts toward your usage limit as
  n requests" (dossier §8). Batching saves round trips only.
- At the governor's 80 units a second a device can make four `messages.get` a second (20 units
  each). On one connection that is one or two requests in flight. Backfill is bound by quota
  and bandwidth, never by round trips. The largest burst the bucket allows is 50 reads.
- `URLSession` multiplexes. RAN (`batch/h2.swift`, unauthenticated on purpose — every call
  answers 401, so this measures transport only; `batch/h2.txt`, load ≈ 59):

```
round 0: 20 parallel GETs statuses [401: 20]; batch outer 200, inner 401 parts 20, 22496 bytes
one GET, warm connection:        median 45 ms  (all: 136 55 43 45 40 31)
20 GETs at once, one session:    median 74 ms  (all: 71 71 126 64 74 152)
one batch of 20 (multipart):     median 60 ms  (all: 64 60 46 63 59 51)
protocols: ["h2": 133] · connections opened 1, requests on a reused connection 132
```

  All 133 requests went over one HTTP/2 connection. Twenty at once cost 14 ms more than one
  batch of twenty.
- It removes a hazard the data-safety review found (S-14): an outer 404, or inner parts that
  are an intermediary's HTML, read as "these twenty messages are gone".

**What it does not settle.** Google's unpublished per-user concurrency limit ("Too many
concurrent requests for user", dossier §9.3) — the same sentence blames "many parallel
requests" *and* "batches with a large number of requests". Keep the governor's cap on requests
in flight (start at 4; back off on that error) and add to the read-only probe's item 6
(EN l.3269): twenty parallel `messages.get` against one batch of twenty — timing and any 429.
If parallel requests trip the limit where a batch does not, the codec comes back, as a later
package, with data.

**Change.** `GmailAPI.getMessages(ids:)` keeps its shape (`[GmailResult<…>]`, one per id) and
is implemented as separate tasks awaited by `.value` (invariant 20). `GmailBatchCodec.swift`,
its tests and fixtures go (≈ 300 lines of P22's 1,400). `QuotaRules.batchSize` becomes
`maxInFlight`. §6.5's "9 or fewer: `messages.modify` each… in one HTTP batch" becomes "each,
at most four at once". FakeGmail loses its batch model.

---

### B-5 · The iCalendar parser · REMOVE; the resolver is REPO

**Where.** P28 l.3185–3187: `MailInvite.parse(calendar:)` — "method, UID, title, start, end,
all-day, place, organiser, guest count… tolerant of other senders' files". UX §9.1
l.2284–2286: the event is found "by the event's id when the invitation carries Google's,
otherwise by the same title and start minute".

**No standard parser exists at levels 3 or 4.** EventKit has no public iCalendar import (SDK
headers searched: `EKRecurrenceRule.h` only mentions the format). On GitHub today: libical
(C, 366 stars, licence not confirmed here — ours to build and wrap); `swift-ical` (41 stars, no licence, a
generator); `icalendarkit` (encoder only, last push 2021); `eLud/swift-ical` (1 star). And the
hard part of the format is exactly what a hand parser gets wrong: `DTSTART;TZID=…` needs the
file's `VTIMEZONE` or a table of Windows zone names; recurrence needs `RRULE`.

**Level 1 applies.** Everything the card draws — title, time, place, guests, the day around
it — and everything its buttons do (`InvitationReply.send`) needs the *calendar event*, which
Google has already parsed. From the mail, the card needs two strings:
- `METHOD` — which is also a parameter of the part's own `Content-Type`
  (`text/calendar; method=REQUEST`), present in `payload.parts[].headers`;
- `UID` — one property, after unfolding lines (a CRLF followed by a space or tab).
That is about twenty lines with a size cap, and no dates.

**Already in the repository:** `GoogleEvent.iCalUID` (`GoogleCalendarModels.swift:103`);
`GoogleEventWindow.index(_:)`, events by upper-cased iCalUID (`GoogleEventWindow.swift:431`);
`GoogleCalendarService.events(calendarID:iCalUID:)` (`:1518`). Resolution becomes: by UID
among the events already loaded, else one Calendar API read by iCalUID, else the row the UX
already has — "This isn't on a calendar Banana can see". It is exact, which title-and-minute
is not; it is also what the security review's P-22 asks for.

**Change.** `MailInvite` becomes `{ method, uid, googleEventID? }`. P28 shrinks from ≈ 600 to
≈ 250 lines (the unsubscribe rules stay). `MailInvitationResolver` (U13) drops the
title-and-minute rule. One limit to write down: an invitation to a single occurrence of a
series carries `RECURRENCE-ID`, a date with a zone; release one resolves to the series and
says so.

---

### B-6 · MIME for sending · BUILD, at a third of the size; one hidden parser REMOVED

**Where.** EN §7.2 l.1580–1595; P16 (≈ 1,100 lines with the reply rules): multipart in three
shapes, quoted-printable, base64, RFC 2047, RFC 2231, folding at 78.

**Candidates.** System: none — no public MIME API on iOS or macOS (headers searched for
"quoted-printable", "encoded-word", "2047": nothing). Gmail: `drafts.create` requires `raw`
(dossier §6.4); it will not build the message. Packages: a GitHub search for a Swift MIME
builder returns nothing established; MimeParser (32 stars, parse only, last push 2023);
SwiftMail (99 stars, BSD-2, an IMAP/SMTP client on swift-nio); MailCore2 (C++/Objective-C,
233 open issues). None earns its place. **So it is built — but most of what P16 lists need
not be:**

| P16 says | Smallest correct form |
|---|---|
| base64 for binary | `Data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])` — Foundation |
| RFC 2047 for non-ASCII headers | "B" form only (base64 of UTF-8, split on character boundaries at 75 octets). No "Q" encoder |
| RFC 2231 for file names | `filename*=UTF-8''` + `addingPercentEncoding` — no continuations: a header line may be 998 octets |
| quoted-printable for text | Keep it: RFC 2045 §6.7 is five rules and ≈ 40 lines, and it is what Gmail itself writes for text. (Base64 for text parts would remove it entirely; I believe some spam filters score that — unverified, section 5) |
| folding at 78 | One function, at existing white space only |

**A parser nobody planned.** P16's test "what is built parses back through `MailMIME` to the
same content" (l.3057) cannot be written as stated: `MailMIME` (P03) walks Gmail's JSON part
tree, not RFC 822 bytes. And `FakeGmail` receives `MIMESource` (l.1020–1023) — a type the
document never defines — yet must answer `draft(id, format: .header)` with `Message-ID` and
`X-Banana-Send-At`, and `rfc822msgid:` searches. As written, the fake's implementer must parse
MIME, by hand, inside the oracle every send test is judged against. Remove it: define
`MIMESource` as `{ headers: [(String, String)], content: DraftContent, bytes: () -> Data }`.
The fake stores headers and content; only the HTTP client asks for bytes. The bytes are
proved by golden files and, at development time, by a parser that is not ours: `python3`'s
`email` package is on this Mac (checked) and can re-read every golden file in a script under
`tools/`.

**Reading MIME is already "do not need it":** `format=full` returns the part tree with
headers and transfer-decoded bodies (dossier §2.2). The design never asks for `format=raw`;
P03 should say it never may.

---

### B-7 · The CSS filter · BUILD (nothing standard fits), smallest surface first

**Where.** EN §10.2 l.2063–2066; `MailCSSFilter.swift` in P20; the security review asks for
"a real CSS tokenizer (CSS Syntax Level 3)" and a property allow-list.

**Candidates.** System: none usable — WebKit's CSS parser is reachable only inside a web view.
Packages (GitHub today): SwiftCssParser (273 stars, last push 2019), CSSParser (2019),
swift-css-parser (17 stars, LGPL-2.1, 2022), CiderKit.CSS (2 stars). None established.
lexbor has a CSS module (B-2). So this one is genuinely hand-built. Keep it small:
- **Declarations first.** A tokenizer for a declaration list (`style="…"`): identifiers,
  strings, numbers and units, functions, comments, escapes — CSS Syntax §4, about 250 lines.
  Output is re-serialised from tokens; any declaration containing a function outside a short
  list (`rgb`, `rgba`, `hsl`, `calc`…), an escape in a property name, or an unknown property
  is dropped whole.
- **`<style>` blocks second, or not in release one.** Rules need selectors and `@media`.
  Dropping blocks at first costs responsive layouts and senders' dark-mode rules on some
  newsletters; inline styles carry most mail. That is a product choice for the owner, and it
  halves the file.
- It is the third wall, not the only one: with one message per document, script off, the
  content rule list and `img-src banana-mail: data:`, a `url()` that slips through loads
  nothing.

---

### B-8 · `Base64URL` and `Base64URLStreamDecoder` · SYSTEM

**Where.** P03 l.2914; EN §11 l.2203–2207 and §21 l.3415: "decoding in memory with Foundation
takes 458 ms and holds about 91 MB at once; streamed, 37 ms and 64 KB" — the streamed number
is a hand-written decode table.

**RAN** (`sys/b64stream.swift`): the same 25 MB, 64 KB at a time, alphabet translated in
place, each piece through `Data(base64Encoded:)`:
`25 MB base64url, 64 KB pieces through Foundation's decoder: p50 41 ms … (ok: yes) · load 47`.
The table buys 4 ms. Use Foundation; `Base64URL.swift` is a six-line translation.

Foundation now has `Data.Base64EncodingOptions.base64URLAlphabet` and `.omitPaddingCharacter`,
for *encoding*, but the compiler reports them "only available in macOS 26.4 or newer", above
this project's 26.0 / 26.1 targets, and `Base64DecodingOptions` "has no member
'base64URLAlphabet'" in this SDK at all (both compile errors in `sys/b64url.txt`). Decoding
Gmail's alphabet is still the six-line translation.

---

### B-9 · Typed times · REPO (`EventPhrase.takeDate`)

**Where.** UX §6.5.2 l.1627–1640, U8: `MailTimePhrase.parse` — "Dates are read by the system's
date detector, as `EventPhrase` does; spans by one pattern."

The UX already chooses the system detector. What it does not say is to *call* what exists:
`EventPhrase.takeDate(_:now:calendar:)` (`Banana/Model/EventPhrase.swift:150–170`) holds one
shared detector and already has the two rules a new parser would rediscover — an hour with no
am/pm between 1 and 6 means the afternoon, and a time already past today means tomorrow.

What the detector itself reads, RAN today (`sys/detector.txt`):

```
tomorrow 8am -> Tue 2026-10-06 08:00      8am      -> Mon 2026-10-05 08:00   (today, already past)
fri          -> Fri 2026-10-09 12:00      fri 3pm  -> Fri 2026-10-09 15:00   (a bare day is noon)
in 3 days    -> Thu 2026-10-08 12:00      3 days   -> nil    2 weeks -> nil   2h -> nil   45 min -> nil
tonight      -> Mon 2026-10-05 19:00      noon     -> nil    next week -> nil   weekend -> nil
monday 9     -> Mon 2026-11-09 12:00   (read as the 9th of November)
```

So `MailTimePhrase` is `takeDate` plus: a bare day means 8 AM; one pattern for spans; four
fixed words; and a guard for "weekday number". About 80 lines, not 200. One conflict to
settle: the security review (P-4) wants a test that greps mail's folders for `NSDataDetector`.
Calling `EventPhrase`, which lives outside them, keeps both rules true.

---

### B-10 · One query tokenizer, not two · BUILD once; the UI's copy REMOVED

**Where.** EN §9.1 `MailQueryRules.parse` (rightly hand-built: it is Gmail's grammar). UX
§6.4.4 l.1541–1544 says "There is exactly one parser, and it is the engine's" — and then U11
creates `MailQueryRanges.swift`, "where each operator sits in the typed text", with its own
tests "every operator; text → chips → text is the identity". Finding ranges is tokenizing. Two
tokenizers of one grammar, in two packages, will disagree on quotes and `-`.

**Change.** `MailQueryRules.parse` returns its tokens with their source ranges; U11 draws
chips from them. Inside the parser, use what exists: `Date.ParseStrategy` and `Calendar` for
`before:` and `older_than:`; for the `MATCH` text either GRDB's `FTS5Pattern`
(`matchingAllPrefixesIn:`, `matchingPhrase:` — `FTS/FTS5Pattern.swift:39–120`) or one stated
rule: every term is an FTS5 string, `"` doubled, a trailing `*` only for the word being typed.

---

### B-11 · The composer's body · SYSTEM for editing, a small BUILD for HTML out

**Where.** UX §6.3.4 l.1396–1398: "A rich-text editor over an `AttributedString`… bold,
italic, underline, strikethrough, link." EN §7.1 l.1570: the body is stored as HTML. Nothing
converts (engineering review E-33.1).

- **Editing — SYSTEM.** `TextEditor(text: $attributed, selection: $selection)` with an
  `AttributedTextFormattingDefinition` that admits only those formats compiles for macOS 26.0
  and type-checks for iOS 26.1 (`sys/richtext.swift`). Bold and italic arrive as fonts and are
  read with `font.resolve(in: fontResolutionContext).isBold` / `.isItalic` — which needs the
  view's environment, so that one step belongs in the view, not in a "pure" model file. Paste
  is filtered by the same definition.
- **HTML out — BUILD, ≈ 80 lines.** The system writer was RAN (`sys/attr.txt`): for a
  73-character body with bold, a link, underline and strikethrough,
  `NSAttributedString.data(…documentType: .html)` produced a 697-byte HTML 4.01 document with
  `<meta name="Generator" content="Cocoa HTML Writer">`, a `<style>` block of `p.p1` /
  `span.s1 {font: 12.0px Helvetica}`, and **neither the bold nor the strikethrough**; its
  first call took 43 ms; and it lives in AppKit/UIKit. Not suitable. A serialiser over runs — `<b> <i> <u> <s>
  <a> <br> <div>`, text escaped — is small, pure and total.
- **HTML in** is B-3's native runs. A draft whose HTML holds anything the runs cannot carry
  opens as E-33 proposes.

---

### B-12 · Attachments · SYSTEM, and one line of invariant 17

**Where.** EN §11; UX §6.2.6, §6.3.5. Invariant 17 (l.110–113) lists the frameworks engine
files may import: "Foundation, SQLite3, Compression, CryptoKit, Combine, `os`".
`UniformTypeIdentifiers` is not on it — so the file extension in
`Cache/Attachments/<aa>/<sha256>.<ext>` (l.365), a picked file's MIME type and "a symbol for
the kind" would come from a hand-made table. RAN (`sys/foundation.txt`):
`UTType(mimeType:)` → `pdf`, `png`, `ics`, `xlsx`, `zip`, and `nil` for nonsense;
`UTType(filenameExtension: "xlsx")?.preferredMIMEType` round-trips; `.conforms(to: .image)`;
sizes through `.formatted(.byteCount(style: .file))` → "84 kB", "1.2 MB", "31 MB". It has no
UIKit dependency and compiles for both platforms. **Add it to the list.** In the UI: QuickLook
for preview (the UX says so), `QLThumbnailGenerator` for the 40-pt chip, `PhotosPicker`,
`fileImporter`, drop destinations — none of these should be re-implemented.

---

### B-13 · Link rules · SYSTEM for IDN; do not hand-roll a public-suffix guess

**Where.** EN §10.4 l.2143–2146; the security review's P-5 rule 3: warn "when the
*registrable domain* (public-suffix + 1) of the destination differs", and for non-ASCII or
mixed-script hosts.

- **IDN — SYSTEM.** RAN: `URLComponents(string: "https://аpple.com/login")` → `encodedHost`
  `xn--pple-43d.com`, `host` `аpple.com`. (`URL.host()` returns `%D0%B0pple.com` — use
  `URLComponents`.) "Any non-ASCII label → show the `xn--` form and ask" needs no script or
  confusables table and covers the mixed-script case.
- **Registrable domain.** There is no public API for the public-suffix list (the only SDK
  mention is a display name in `WKWebsiteDataRecord.h`). Written as P-5 has it, an implementer
  will guess "the last two labels", which is wrong for `co.uk`. Either vendor the real list
  (a data file with a licence and an update script) — or avoid needing it: warn unless one
  host equals the other or is a suffix of it on a label boundary. Shown "paypal.com" →
  `login.paypal.com.example.net`: warns. `www.paypal.com` ↔ `paypal.com`: does not. It
  over-warns only for sibling sub-domains. I recommend the suffix rule.

---

### B-14 · The tracker list · PACKAGE (data): vendor one, do not compile one

**Where.** EN §10.2 l.2075–2077: "on a host in the bundled list
(`Banana/Resources/MailTrackers.json`)". P20 creates the file; nothing says from what.

Candidates (GitHub API today): **MailTrackerBlocker** — `apparition47/MailTrackerBlocker`,
BSD-3-Clause, 1,123 stars, pushed 12 Sep 2026; its patterns are in
`Source/MTBBlockedMessage.m` (33 KB), so they need an extraction script. **Simplify
Trackers** — `leggett/simplify-trackers`, BSD-3-Clause, last push Feb 2022. **DuckDuckGo
Tracker Radar** — maintained, web-wide rather than mail-specific; licence not confirmed.
Recommend the first, with a `tools/` script that regenerates the JSON and a header naming the
source commit and licence. The size rule (≤ 2 px, hidden) is rightly Banana's own.

---

### B-15 · Headers and addresses · SYSTEM for charsets; a small BUILD; one question for the probe

**Where.** P03 l.2911–2913: parts "decoded with their charset"; `MailAddress.swift`: "address
lists, quoted names, groups, RFC 2047".

- **Charsets — SYSTEM.** `CFStringConvertIANACharSetNameToEncoding` → `String.Encoding`. RAN:
  utf-8, ISO-8859-1, windows-1252, iso-2022-jp, Shift_JIS, GB2312, gbk, big5, koi8-r,
  us-ascii, utf-16, iso-8859-15 all resolve; an unknown name is reported as unknown. No table.
- **Address lists — BUILD**, ≈ 150 lines; nothing in the SDK. One parser: the composer's
  "a pasted list makes several" chips (UX l.1386) must call it, not a second pattern.
  (`GuestDirectory.emails(in:)` is a loose finder for typed prose, not a header parser.)
- **RFC 2047 decoding — perhaps not needed.** My recollection is that Gmail's
  `payload.headers` values arrive already decoded; neither I nor the dossier (§2.2, its
  "UNVERIFIED but widely relied on") could confirm it. Add to probe item 3 (EN l.3262): one
  message with an encoded-word subject and sender — are the values decoded? If yes, the
  decoder is a fallback for malformed input only.

---

### B-16 · Smaller ones

- **Compression (row 31).** The repository's idiom is one line —
  `(data as NSData).compressed(using: .lzfse)` in `Transcript.swift:234`,
  `ControlsCloudRecords.swift:135`, `HealthWorkout.swift:116`, `PhoneConnectivity.swift:610`.
  `MailCompression.swift` should be that with `.zlib` or `.lzfse`, not a wrapper over
  `compression_stream`. (RAN: zlib through `NSData` round-trips 253 KB; my 1.0 ms inflate
  under load is not comparable with the engine's 0.05 ms — P04 should measure both and keep
  the faster. The engine's own spike had LZFSE inflating faster than zlib.)
- **RFC 3339 (row 38).** `try Date("2026-10-06T08:00:00Z", strategy: .iso8601)` — RAN.
- **The `Date:` header (row 39).** `DateFormatter` with the canonical pattern read 2 of 4
  ordinary forms; it fails on a trailing "(PDT)" and on a missing weekday (RAN). A tolerant
  RFC 5322 date reader is a small parser of its own. EN l.1249–1252 wants it only if header
  reads lack `internalDate` (R8, unverified). Do not build it: such a row keeps its stub order
  until the full read.
- **Resumable uploads (row 21).** `GmailUpload.swift` hand-builds Google's resumable protocol.
  Release one can upload in one request (the limit is 35 MiB) and retry whole. If resumable is
  wanted later, `GTMSessionUploadFetcher` implements it and is **already linked**:
  `Package.resolved` has `gtm-session-fetcher 3.5.0` through GoogleSignIn, and
  `Sources/Core/GTMSessionUploadFetcher.m` is in that tag. It would live in `MailApp/`.
- **`DateText` (row 33).** Build the rule; take the words from `Date.FormatStyle` and a
  relative formatter so month order and "Yesterday" are the locale's.
- **Duplicates between the two documents (rows 40, 41).** `MailLink` and `MailReference` read
  the same two URL forms; `ReplyRules` and `MailDraft.reply` decide the same recipients and
  subject. One file each.
- **`SnapshotLoader` (row 42)** already does "a corrupt file is ignored, not fatal" for
  `render-heights.json`.

---

### B-17 · Considered and not recommended

- **Google's own client, `GoogleAPIClientForREST_Gmail`** (Apache-2.0, v5.4.0 of 4 Aug 2026,
  860 stars, iOS 15+, depends on gtm-session-fetcher `1.6.1 ..< 6.0.0`, so it would resolve
  with what is linked). It would replace `GmailWire`, the HTTP client, the batch codec and
  uploads. Not recommended: its objects are mutable Objective-C values that would have to be
  mapped to the engine's `Sendable` types anyway; the engine's fake sits *behind* the
  `GmailAPI` protocol and is the test strategy; batching is removed (B-4); and an attachment
  would arrive as one in-memory object, the 91 MB peak §11 avoids (my reading of its design,
  not run). `Codable` over `URLSession` is ≈ 300 lines of models with the system's JSON parser
  underneath — not a parser of ours.
- **SQLite.swift, Core Data, SwiftData** — B-1.
- **WebKit as the sanitiser, lexbor, Kanna/Fuzi, `NSAttributedString(html:)`** — B-2.

---

## 3. New dependencies this would add

| Package | Replaces | Licence | Size | Maintained by | Risk of taking it | Risk of not taking it |
|---|---|---|---|---|---|---|
| **GRDB.swift** 7.11.1 (exact pin) | `MailSQLite`, `MailDatabaseQueue`, `MailMigrator`, the statement cache, FTS5 pattern quoting — ≈ 650 lines and their tests | MIT | 71k lines; ≤ 2.3 MB of code; +44 s to a clean release build here; no dependencies of its own | Gwendal Roué; monthly releases since 2015; 8.7k stars; 12 open issues | One maintainer. Three behaviours to know (B-1): it forces `synchronous=NORMAL` after `prepareDatabase`; it writes once at open when the log is empty; it prefers one object per file. Its build needs a Swift 6.1 toolchain (Xcode 27 is fine) | A home-made wrapper over the C API, written by less experienced implementers, under the app's most precious data. Its failure modes are silent: a held read transaction, a dropped fsync, a `NULL` where an empty value was meant |
| **SwiftSoup** 2.13.9 (exact pin) | `MailHTMLTokenizer`; the tokenizers inside `MailText` and `MailNativeText`; entity decoding — ≈ 950 lines across P04, P20, U7 | MIT | 35k lines; ≤ 3.0 MB of code; no dependencies | scinfu and contributors; 5.1k stars; 2 open issues; 198 commits in the last year | Heavy recent churn from one contributor's performance rewrite; 158 lines of `Unsafe…`; not exactly WHATWG (two differences found). 3–4× slower than libxml2. A trap on hostile input needs the "being parsed" marker | **Zero-dependency alternative exists: libxml2 2.9.13 from the SDK** — faster, but C in the token-holding process, an HTML 4 parser, and pointer code for implementers. The option that must not happen is the third: a hand-written tokenizer |
| **A tracker list** (data file; MailTrackerBlocker's, BSD-3-Clause) | A hand-compiled `MailTrackers.json` | BSD-3-Clause | tens of KB | apparition47; 1.1k stars; pushed Sep 2026 | Needs an extraction script; stale entries block a legitimate image (it shows as a placeholder) | A list that is whatever the implementer remembered |

No other package is recommended. Not new, but to note: `UniformTypeIdentifiers` joins
invariant 17's list; `libxml2` is linked into `BananaTests` only, as the second parser of the
differential test (or into the app, if it is chosen over SwiftSoup);
`GTMSessionUploadFetcher` is already in the build if resumable uploads are ever wanted.

---

## 4. Rightly hand-built

- The pure rule enums — `ThreadSummaryRules`, `ViewMembershipRules`, `HistoryRules`,
  `ReconcileRules`, `FetchPlanRules`, `OutboxRules`, `OverlayRules`, `DeliveryRules`,
  `BananaLabelRules`, `MuteRules`, `NotifyRules`, `PollRules`, `AttachmentRules`,
  `RemoteImageRules`, `MailAccountRules`: the product's own decisions.
- The outbox and the send state machine (`SendRules`): Gmail gives no idempotency; nothing
  generic knows `drafts.send` spends a draft.
- The quota governor (`QuotaRules`): arithmetic on Google's price list.
- The schema, the page query, views as rows, the FTS row-id scheme: design, not plumbing.
- `MailChangeHub` / `MailStoreChange`: the writer saying what it wrote beats any observer.
- `FakeGmail`: the oracle; by definition nobody else's.
- `GmailWire` + `GmailHTTPClient` + error mapping: `Codable` and `URLSession` are the parsers.
- `MIMEStructure.extract`: a walk of JSON Gmail already parsed.
- The Gmail query grammar (`MailQueryRules`) — once, with ranges.
- The allow-list walk and serialiser, the CSS filter, quote detection, tracker *rules*: policy
  over a real tree.
- The MIME builder, at B-6's size; address lists; `List-Unsubscribe`.
- `AttributedString` → HTML for five formats.
- The triage model (`MailListModel`, `MailListProjection`, `MailUndoStack`), `MailCommands`,
  `MailKeymap`, `MailTimePresets`, `MailDayStripRules`, `MailConversationModel`: the UI's own
  rules, extending `MacKeyMonitor` and `MacCommand`.
- `DateText`, `MailStatusText`, `MailSendText`, `MailRowDisplay`: Banana's words, over system
  formatters.
- The remote image loader and cache: its privacy rules are the point; `ImageCache` is for
  artwork.
- `MailRowID` (FNV-1a), `MailClock`, `MailJournal`, `MailFirstPaint`, `MailRenderHeights`:
  a few lines each.

---

## 5. Unverified

1. **Gmail's concurrent-request limit** — whether 4–20 parallel reads trip it where one batch
   does not (B-4). Needs the authenticated probe; my transport test was unauthenticated and
   says nothing about Gmail's own time per call.
2. **Whether `payload.headers` values arrive RFC 2047-decoded** (B-15), and the dossier's own
   open item that part `data` is transfer-decoded but still in its charset.
3. **Device numbers.** Everything was timed on an M1 Max under heavy, varying load. Ratios
   between candidates are sound; absolute values are not budgets.
4. **My full-fsync commit times** (0.19–0.27 ms p50) are an order of magnitude below the
   engine's 2.98 ms on the same Mac. Same pragmas as far as I can tell; I did not find the
   cause. Use the engine's figure until someone does.
5. **A tuned sanitiser walk.** Mine is naive; the end-to-end HTML numbers are upper bounds
   for both parsers. Real newsletters were not tested — only the engine's synthetic one and
   twelve hostile fragments. The fuzz was 15 seconds of tag soup per parser: a smoke test.
6. **SwiftSoup's two WHATWG differences** are what twelve fragments happened to show; there
   will be others. I did not run html5lib's conformance suite against it.
7. **libxml2's CVE record** is from memory, not looked up; so is the statement that a spam
   filter penalises base64-encoded text parts (B-6).
8. **GoogleAPIClientForREST** was evaluated from its manifest and my knowledge of its design,
   not built or run. **lexbor**: no Swift package found by search; not built.
9. **The tracker lists' contents and quality** were not inspected, only their existence,
   licence and activity; Tracker Radar's licence was not confirmed.
10. **Binary-size figures** are whole stripped spike executables, not the increase in
    Banana's own binary after dead-stripping.
11. **The iOS 26 rich-text editor** was compiled, not run: I did not confirm at run time which
    attributes paste and the format bar produce.
12. **WebKit's HTML Sanitizer API** — whether Safari 26's WebKit ships it — not checked; it
    would not change B-2 (it needs a web view).
13. **Foundation's URL-safe base64 options**: availability read from the compiler's
    diagnostic ("macOS 26.4 or newer"); the iOS version is assumed to match.
14. The system SQLite on iOS 26.1 having `contentless_delete` remains the engine's own
    assumption (R10); the SDK header says 3.54.0, this Mac runs 3.51.0.

Spike sources and raw output: `scratchpad/review/reuse-spikes/` —
`sqlspike/` (`run1.txt`, `run2.txt`), `htmlspike/` (`hostile.txt`, `bench2.txt`, `bench3.txt`,
`deep.txt`, `fuzz.txt`, `baseline-tagwalk.txt`), `batch/h2.txt`, `sys/` (`detector.txt`,
`foundation.txt`, `b64url.txt`, `b64stream.txt`, `attr.txt`, `richtext.txt`, `xmlios.txt`).
