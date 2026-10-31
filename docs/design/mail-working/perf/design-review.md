# Performance review of the mail designs — before any code

Reviewed: `docs/design/MAIL-ENGINE.md` (§2 inv. 10–16, §4, §5.2/5.4/5.6/5.9, §9–§13, §15, §16, §20, §21),
`docs/design/MAIL-UX.md` (§3.10, §6.1, §6.2, §8, §13, §14), the spikes (`scratchpad/spikes/*`), and the
four reviews (U-1/U-5/U-11/U-25, E-32/E-34 and the merged build order, S-2, P-3). Read-only; nothing run.
Labels as in `findings.md`: MEASURED (a number from this audit's runs or the spikes, with its caveat),
READ-IN-CODE / READ-IN-DOC (cited line), INFERRED.

**Depends on the build-versus-reuse review** (still running: GRDB.swift for SQLite, libxml2/SwiftSoup
for HTML): R-1, R-4's re-measurement, the §21 write numbers, the P09 benchmark thresholds, and the
"prepared at fill time" change all have to be re-measured with whatever it picks. The rest of this
review does not depend on it.

Counts: **4 BLOCKER · 9 MAJOR · 7 MINOR.**

---

## Findings

### R-1 · BLOCKER · "Open any conversation in 50 ms" rests on a byte scan that is not the sanitiser, and the design prepares HTML at open

- **Where:** ENGINE §10 (2034-2057, 2087-2092), §15 row "bodies, cached" (2682), §21 (3413); UX 8.1
  rows "Open any conversation 50/100 ms", "web body painted 150/300 ms" (2143-2144), 8.2 item 4
  (`warm` at 150 ms rest); P-3 (security review) and the reuse spike (`review/reuse-spikes/htmlspike`).
- **Problem:** the only measured preparation cost is `content_spike.swift`'s linear `<`-scan
  (0.02–0.6 ms, 320–415 MB/s) which drops `<script>/<style>` whole, filters no `style` attributes, decodes
  no entities, rewrites only `src/href/background`, and uses FNV-1a not SHA-256 (digest §B;
  `content_spike.swift:5-7, 46-119`). The design itself tags the real sanitiser "ASSUMED up to ten times
  slower" (2087-2089). P-3 requires a real HTML5 tokenizer or libxml2 plus a CSS tokenizer, with input
  limits; the reuse spike is testing libxml2 and SwiftSoup. A tree parser plus serialisation on a 1.2 MB
  `newsletter` is tens of milliseconds on this Mac and INFERRED 2–5× that on a phone; SwiftSoup is
  slower still. Preparation happens at `warm` (150 ms after the cursor rests) or at open, and only the
  "newest few hundred" prepared documents are cached (831-834). So the first open of any conversation
  the cursor did not rest on — every `J` through Other, every notification open, every search hit — pays
  the parse inside the UX's 50/100 ms budget.
- **Evidence:** MEASURED tag-walk 0.19 ms/63 KB, 0.60 ms/261 KB (`content.txt`); READ-IN-DOC "prepared at
  open" (§10 title, 2034), cache "newest few hundred" (831-834); P-3's own target "a 2 MB fixture prepares
  under 50 ms" (R-SP:216) is on the Mac and is itself the whole open budget.
- **Smallest change:** prepare at fill time, not at open: `writer.search`'s `mail.indexer` queue already
  walks every new body for FTS; add "prepare + record facts (height boxes, tracker count, style class)"
  to the same pass, bounded like bodies (D3) rather than "a few hundred". Open becomes a cache hit
  (inflate 0.02 ms + hand-over). Keep `warm` for the uncached tail. Budget row to add to §15: "prepare
  one message, chosen parser: ≤ 10 ms p95 per 100 KB on device; a 2 MB part refused before parsing".
  Re-measure once the parser is chosen (reuse review).

### R-2 · BLOCKER · The UX's speed budgets assume a list host that does not exist, and the two list models have different costs

- **Where:** UX 6.1.8 "The list is a `List`" (1104-1105), T9/T11/T26 (295-300, 309-311, 394-400), 8.4
  (2204-2206), 12.7 X5 (2934); ENGINE 13.2 "sliding window of at most 400 rows" (2445-2458); U-1; E-32's
  counter-proposal (R-ENG:921-926: a capped growing list of 2,000).
- **Problem:** U-1 shows `List` cannot set an offset or compensate inserts above the viewport, so "no
  row on screen moves", "within one point" and "exactly what was showing" after the 2.5 s discard are
  not reachable on it. From the performance side the two list models differ in cost, and the budgets
  (U3: a 5,000-row apply < 16 ms on a phone; U4: no hitch longer than a frame through 5,200 rows) were
  written for a `List` that diffs the whole array per publish. With invariant 13's "≤ 2 publishes/s from
  sync", a 5,000-row `Equatable` diff on the main thread twice a second during a first sync is a steady
  main-thread cost the design does not budget; a 400-row window bounds it but needs a host with
  `show(around:)` and offset control. Either way, the number that decides the host is not in the
  documents.
- **Evidence:** READ-IN-DOC as cited; the app's own precedent is the Day grid's UIKit bridge
  (`DirectionalDayScrollView`, `WeekView.swift:2375-2571`) chosen for exactly this class of control, and
  the lesson recorded against it (never a content token — memory note *banana-day-grid-stale-content*).
- **Smallest change:** decide the host with P1 measured, not argued (spec in §4 below); my verdict and
  the reasons are in §4. Whichever host wins, add to §15 the missing row: "list apply, window of W rows:
  ≤ 4 ms main-thread at W = 400 on device; ≤ 16 ms at W = 2,000" and make W a constant the benchmark
  sweeps.

### R-3 · BLOCKER · The local CPU-bound passes have no duty cycle, and the app's own watchdog will call them a failure

- **Where:** ENGINE §4.9 rebuild "6,700 msg/s ≈ 30 s; re-index 1,300–1,900 msg/s, 2–3 min" (926-931),
  §5.10/D12 seeding (3354-3356), §8.? indexer "50 dirty rows per transaction on `mail.indexer`"
  (806-812), §5.6 header-only mode (1281-1285) which later re-reads every body and re-indexes; §15 has
  no CPU or thermal row for any of these; PERF-PLAN §5 "foreground browsing: body evals ∝ interactions",
  `PerfWatchdog.alarmingCPU = 25` (`PerfWatchdog.swift:110`), thermal line (`:175-183`).
- **Problem:** the first sync is quota-bound (80 units/s ≈ 4 full reads/s, §5.2 1073-1074), so per-message
  indexing at that rate is ≈ 1 % CPU — fine. But every *local* pass runs at machine speed on a utility
  queue: a search re-index is 155 s of one core at 200k on an M1 Max (`build200k.txt`: 1,287 msg/s with
  FTS), INFERRED 4–8 min on an iPhone with throttling; an index rebuild 30 s Mac; D12 seeding = a full
  local rebuild. `PerfWatchdog` measures process CPU, not QoS: one core at 100 % is `🔥 HIGH CPU 100 %`
  every 15 s and thermal `fair → serious` within minutes on a phone, which §4.2/§4.3 of PERF-PLAN treat
  as a bug. Invariant 15 covers the background only; nothing bounds a utility-queue pass with the app in
  front, and the indexer catch-up after header-only mode is the same pass at the same speed.
- **Evidence:** MEASURED build rates above; READ-IN-CODE watchdog threshold; READ-IN-DOC: no throttle in
  §4.6/§4.9/§5.6/§15.
- **Smallest change:** one `MailWorkPace` rule for the indexer, the rebuild and seeding: full speed only
  on the Mac on power or inside `com.boris.banana.mail.fill` (`requiresExternalPower`); in front on
  battery ≤ 20 % of one core (sleep ≥ 4× the batch's duration between batches), paused at thermal ≥
  `.fair` or Low Power Mode; progress line says so. §15 row: "any local pass, app in front: `⚡ POWER` avg
  ≤ 25 %, thermal nominal; `🔥 HIGH CPU` = failed". Gate: the `mail-reindex` route in §5.

### R-4 · BLOCKER · "Durable ≤ 20 ms p95" and the 8 ms group commit rest on an ASSUMED phone fsync

- **Where:** ENGINE §4.2 (449-453: "iPhone flash is ASSUMED to cost 5–20 ms per full fsync; P14 measures
  it on the Simulator and the device pass confirms"), §15 row "An action: durable ≤ 20 ms p95"
  (2684), `fsync.txt` (2.98/5.0/9.3/13.0 ms on this Mac, 400 commits).
- **Problem:** the measured number is a desktop SSD; the phone number is assumed, and the two files a
  person's action touches share `mail.writer` with every sync batch (433-439). If `F_FULLFSYNC` on the
  phone is 20–40 ms (it has been, on NAND), a held key at 30 repeats/s is 30 commits/s only if the group
  commit coalesces everything that arrives *while a commit is in flight*; the design's rule is a fixed
  "within 8 ms of each other", which at 20 ms per commit queues ~2.5 commits per commit and the writer
  falls behind — the overlay write-through lags, `appliedThrough` stalls, the "at most one batch" wait
  (437-439) is false, and `first-page.json` (written 2 s after the last change) can record a feed ahead of
  the store. "The Simulator measures it" measures the Mac's SSD again (E-34).
- **Evidence:** MEASURED Mac 2.98 ms p50 / 13 ms max; READ-IN-DOC ASSUMED; `fsync.txt` method: fresh file,
  three inserts, `BEGIN IMMEDIATE`, no concurrent reader or index write.
- **Smallest change:** (1) coalescing rule = "everything that arrived during the previous commit shares
  the next one", with a cap (50) and a journal counter; (2) measure full fsync on the owner's phone
  before P14 lands — a 20-line `--verify-mail-bench fsync` route in the Beta (device-protocol.md), 400
  commits, p50/p95/max into the journal; (3) move §15's "durable" budget to "≤ 2 × measured device
  fsync, p95" until measured.

### R-5 · MAJOR · The four-letter search cliff is at the budget on the Mac and INFERRED over it on a phone

- **Where:** ENGINE §4.6 (770-798), D14 (3362-3365), §15 "≤ 30 ms p95" (2686); `fts200k.txt`.
- **Problem:** with `prefix='2 3'` a four-letter word has no prefix index: 16.4 / 18.4 / **33.8** ms
  p50/p95/p99 at 200k on this Mac, warm cache, 40 iterations of one word (`mid` = the 900th most common);
  five letters drop to 3.9 ms because the candidate set shrinks. §15 quotes the p95 and omits the p99,
  which already exceeds the budget here; a phone's FTS5 prefix scan is CPU- and page-cache-bound
  (INFERRED 2–3× slower cold). This is the row that flips the prefix decision if it moves 2×, not 10×.
- **Evidence:** MEASURED as cited; the spike's prefix test ran under a host 1-min load of ~30–50
  (`spikes/fts200k.txt` 17:14 vs my per-route load lines), so the tails are suspect in both directions.
- **Smallest change:** re-measure at 4 letters on the device first (the benchmark route of §5, order 5);
  if p95 > 30 ms there, add `4` to the prefix set (D14's size arithmetic) or answer four letters from the
  three-letter candidate set filtered in Swift against subject/sender, which are already in `message`.
  Record the FTS file size with each option on real mail (§21's 124 % is for pseudo-words).

### R-6 · MAJOR · E-34 is a performance finding: the benchmarks as planned cannot fail, and the gate build is not Debug

- **Where:** R-ENG:974-986; ENGINE §15 "Checked by: Benchmark"; UX §14 performance lines "on a phone".
- **Problem:** a Debug Simulator benchmark against a 5 ms page budget measured at 0.05 ms cannot catch a
  twentyfold regression; the whole-app gate already builds Release(-O, WMO) with the DEBUG condition
  (baseline.md), so the mail benchmarks have a Release home today.
- **Smallest change:** §5 below: benchmarks run in the gate's Release build via a `--verify-mail-bench`
  route (the `CPUVerification.runIfRequested` pattern, `BananaApp.swift:197-203`), assert ≤ 2× this Mac's
  recorded baseline (regression), log everything to `PerformanceRuns/<run>/result.json` through
  `PerformanceRunRecorder`, and leave absolute budgets to the device pass. What Debug can assert is listed
  in §5.

### R-7 · MAJOR · Mail makes six whole-app findings worse; four must be fixed before order 1

- **Where:** findings.md F1, F2, F5, F11, F12, F19; ENGINE §12.1 (2242-2255), §13 `activate()` from
  `wireUp()` (2358-2360), §16 `mail↻` sink (2743-2744); UX G3/G4/G10/G11.
- **Problem / which:**
  - **F2 (foreground cascade on every glance) — fix first.** §12.1 adds "plus at once: on coming to the
    foreground" a history poll per account; through `RootView.swift:273-301` that becomes one more
    network request per Control Center glance, on top of ≥ 4 CloudKit round trips, during background
    playback. Mail must hang `MailRuntime.resume()` off the `cameFromBackground` flag F2 asks for.
  - **F11 (Mac ungated, watchdog blind) — fix first.** §12.1 polls the Mac at 60 s with the window
    hidden, and invariant 13's publishes and sync writes run with nobody looking; the Mac shell has no
    `AppVisibility`. The `mail↻` and `mailList↻` sinks must be registered outside `#if os(iOS)`
    (`PerfWatchdog.swift:160-174`) or a Mac mail storm is logged as `MacRootView`.
  - **F5 (timers alive in background) — fix first.** The design pauses its own timer on `.background`
    (good); it must not be undone by F5's three survivors being copied as a pattern, and the Mac timer
    needs tolerance (`MenuBarAgenda.swift:31` has none).
  - **F12 (PerfWatchdog coverage) — fix first.** UX G11's DEBUG probes (`mail.list.renderCount`, the
    `DayPerformanceRenderProbe` pattern) poll `RenderStats` at 4 Hz; the gate build has DEBUG on, so they
    must be gated on `--perf-trace` as the Day probe is (`RootView.swift:196-199`), or every gate idle run
    with Mail on screen pays 4 wakeups/s.
  - **F1 (sync XPC in a `@StateObject` init)** — independent, but `activate()` must not repeat the shape:
    four WAL opens (each may replay a log of unbounded size) and the overlay rebuild run from `wireUp()`,
    which already awaits five loads before sync starts (`BananaApp.swift:668-863`). `activate()` must be
    fire-and-forget on the writer queues, never awaited on the main actor.
  - **F19 (covers outside the blank gate)** — independent; mail's reader must sit under `gatedContent`.
  - F3, F4, F6–F10, F13–F18: independent of mail.
- **Smallest change:** land F2, F5, F11 and F12's sink/probe parts in order 0 (they are five small
  diffs); add "`activate()` ≤ 1 ms on the main actor, measured by `✉️ activate`" to §15.

### R-8 · MAJOR · First sync on a phone is days, not hours, and its foreground cost is unbudgeted

- **Where:** UX 7.1 "usable in seconds, complete in hours" (1898); ENGINE §5.4 (1183-1202: 100k messages
  = 3.8–7 h of units, two days of bytes; "a week or more" on a phone), D3 (3313-3314), D12 (3354-3356);
  invariant 15.
- **Problem:** on the phone the fill runs only with the app in front or inside a BGProcessingTask on power,
  so a 200k mailbox completes in weeks unless seeded (D12). While it runs in front the phone keeps the
  radio up at ~4 requests/s with two in flight for hours: `⚡ POWER` wakeups/syscalls, battery and heat
  the design does not budget; §15 has rows for a quiet poll and for background, none for "first sync,
  app in front". The UX promise is the Mac's.
- **Smallest change:** state the phone's truth in 7.1 and the first-sync card; add §15 rows "first sync,
  in front, battery: ≤ 10 % avg CPU, thermal nominal, ≤ N wakeups/min (set from the first Mac run)";
  make D12 the default plan for a phone, and give the seeding transfer and its local rebuild the R-3 pace.

### R-9 · MAJOR · The engine's memory budget excludes what will actually be resident

- **Where:** ENGINE §15 "engine ≤ 40 MB added, web content excluded; page caches ≤ 31 MB" (2692-2693);
  UX 8.2 items 5–6 (eight conversation models, a spare web view loaded), 6.2 `MailRenderHeights`
  (1298-1300), 3.10 six list models; U-5's "one web view per open designed message, cap six"
  (R-UX:204-205).
- **Problem:** 31 MB of page caches is the floor, not the ceiling: FTS5 merge buffers during a catch-up,
  `temp_store=MEMORY` sorts, eight conversation models whose prepared bodies for `forty` with three
  1.2 MB newsletters are several MB each, six list models of up to 5,000 rows (≈ 1 MB each, E-32), and
  — excluded by fiat — the WebContent process, which with six open newsletters is INFERRED 50–150 MB and
  is what jetsam actually pressures on a phone that is also decoding a podcast. The baseline footprint
  today is 33–57 MB (baseline.md); PERF-PLAN's device idle was 13.9 MB.
- **Smallest change:** budget the whole: "app footprint ≤ baseline + 60 MB with Mail in front; ≤ + 100 MB
  with a conversation of six designed messages open; web content process ≤ 150 MB; back to +60 within a
  minute of leaving the reader (the pool release U7 promises)". Measure in P3 on device with `footprint`
  (both processes) and in the gate with `⚡ POWER mem=` (app only).

### R-10 · MAJOR · The spike's store is not the design's store

- **Where:** `mailstore_spike.swift:181-182, 575` (PRAGMAs), `:166-168, 326-368, 458-463` (schema);
  ENGINE §4.2 (443-448), §4.3 (539-544, 576-581), §4.4 (631-636).
- **Problem:** every spike connection used `cache_size=-8000` (≈ 7.8 MB) and `wal_autocheckpoint=1000`
  (the design: 1–8 MB per connection, auto-checkpoint 0); the spike keeps a `view_count` counter table the
  design rejects, lacks `fetch_class`/`fts_dirty`/`sort_key > 0`, and its page query selects a different
  column set. The "FTS in its own file" search numbers were taken by attaching the FTS-in-file build (which
  also holds a full index copy). The numbers are evidence of order of magnitude, not of the design.
- **Smallest change:** P09's benchmark *is* the design's schema and PRAGMAs, run against the real
  `MailSQLite` wrapper (or GRDB, per the reuse review), on a quiet machine; §21 is regenerated from it.

### R-11 · MAJOR · Sync batch size was tuned on an SSD; on a phone the 50-message batch likely exceeds its own writer-hold budget

- **Where:** ENGINE §4.2 (437-439), §15 "a sync batch's hold on the writer ≤ 30 ms p95 — 25.4 ms measured
  (50 messages); batch size is the knob" (2688); `buildnofts.txt` p95 25.6 ms, `write200k.txt` p95 117 ms
  under concurrent ingest with two readers.
- **Problem:** 25.4 ms is already 85 % of the budget on an M1 Max with a warm cache and no reader; on NAND
  with `synchronous=NORMAL` the WAL append and page writes are slower (INFERRED 2–3×). The budget flips
  at 1.2×.
- **Smallest change:** start the knob at 20 (the governor's starting batch size anyway, 1096-1098) and let
  the benchmark on the device set it; add the under-ingest number (p95 with `reader.ui` active) to §15
  because that is the case the person feels.

### R-12 · MAJOR · S-2's full disk is also a writer-queue death

- **Where:** R-DS:34-44; ENGINE §4.2 one writer queue, §13 `perform` returns before I/O (2401-2409).
- **Problem:** `SQLITE_FULL` on `mail.writer` with no stated handling turns every later action into an
  accepted-then-lost change (S-2). From the performance side the fill is what fills the disk, and it runs
  at NAND write speed inside a BGProcessingTask. Agree with S-2's floor (1 GB phone/iPad, 5 GB Mac) and
  add: the eviction planner on `reader.background` must run *before* the fill resumes, not after.
- **Smallest change:** as S-2, plus a `✉️ store` line "free=… evicted=…" per maintenance pass.

### R-13 · MAJOR · The budgets were measured on a loaded machine

- **Where:** `spikes/*.txt` timestamps 17:14–17:30 on 5 Oct; my gate's per-route host load (baseline.md
  §caveats: 1-min load 405 at 16:57, ≈ 50 at 17:09, ≈ 10 at 17:21); E-34.
- **Problem:** the spikes ran while another session's test run was finishing: medians at that load are
  roughly right (my own marks moved +80–120 ms uniformly under heavier load and ratios held), but p99 and
  max values (archive max 46.9 ms, 4-letter p99 33.8 ms, rank p95 665 ms, under-ingest reader max 30 ms)
  may be contention. §15 and §21 quote several tails.
- **Smallest change:** re-run `mailstore_spike` and `content_spike` once on a quiet machine (1-min load
  < 4, `pgrep -x xcodebuild` = 0, five repeats, medians and p95s reported with the load line) before any
  §21 number is used as a threshold; §5 says which rows.

### R-14 · MINOR · Polling at 20 s with Mail on screen triples the app's poll rate

- **Where:** ENGINE §12.1 table (2250-2255); `CloudSyncPoll.interval = 60` (`CloudSyncPoll.swift:14`); the
  Google change poll at 120 s (`SmartScheduleStore.swift:1508`).
- **Problem:** cheap by quota (2 units) and by CPU (≤ 5 ms), but it is a main-run-loop timer at 180
  wakes/h on a phone in front, with a request each; with four accounts, four requests per tick. The
  design's own "new mail on screen ≤ 30 s target / 60 s ceiling" (UX 2155) is met by 30 s.
- **Smallest change:** 30 s on screen, 90 s elsewhere, tolerance 5 s, doubled in Low Power Mode (already);
  measure `power_wakeups` on `mail-inbox` vs `shell-plan` in the gate and keep the delta ≤ 100 per
  72 s.

### R-15 · MINOR · Invariant 13 and "publish at the rate of meaning" are compatible; one rate is missing

- **Where:** ENGINE inv. 13 (97-99), §13 `MailListFeed` (2441-2454), `MailProgress` ≤ 1/2 s (2564-2572);
  UX T7 (280-284), G4.
- **Problem:** none in direction — the caps are the right shape. Missing: the number of publishes per
  search keystroke (local then Gmail group = ≥ 2) and per conversation open (header, native bodies,
  web height, attachment rings). Each is a leaf by design; say so with a count so the publish-rate unit
  test (E-34's proposal) has a number.
- **Smallest change:** add "≤ 2 publishes per search answer; opening a conversation publishes once to the
  reader and once per web height" to inv. 13.

### R-16 · MINOR · `first-page.json` is 40 rows in §4.11 and 50 in the measurement; the budget is 2 ms

- **Where:** ENGINE 967 vs 971; UX 8.1 "Mail adds ≤ 10 ms to Banana's first frame" (2151).
- **Problem:** cosmetic, but the two budgets differ 5× and the UX's 10 ms is the one the gate can see
  (`mail.snapshot` − `root.body`).
- **Smallest change:** one number (50 rows, ≤ 2 ms read, ≤ 10 ms to first frame), both documents.

### R-17 · MINOR · `quick_check`, `integrity-check` and the daily `du` are phone seconds, not Mac seconds

- **Where:** ENGINE §4.10 (950-954): quick_check 0.38 s, FTS integrity-check 8 s, "which is why it can run
  at all"; `du` daily (2694).
- **Problem:** both are page scans over 1.3–1.5 GB; on NAND they are INFERRED 3–10× — the FTS check is
  minutes inside a BGProcessingTask whose window is minutes. Fine if they yield to the expiration
  handler; nothing says they do.
- **Smallest change:** run them only in `mail.fill` on power, after the fill, check the expiration flag
  between files, and log `✉️ store check … ms`.

### R-18 · MINOR · The overlay rebuild at every launch has no stated cost

- **Where:** ENGINE 436, 552-555, 944; `✉️ activate` logs "overlay rows" (2727).
- **Problem:** intent is "small, precious"; the overlay is a copy keyed locally — a few rows normally,
  thousands after a whole-view action offline (E-32's `before` point). It runs in `activate()` on the
  launch path.
- **Smallest change:** cap what `activate()` rebuilds synchronously (first 500 rows), rest on the writer
  queue; journal the count and ms.

### R-19 · MINOR · `temp_store=MEMORY` and `ORDER BY rank` must stay apart

- **Where:** ENGINE 443; `fts200k.txt` rank 468 ms p50 / 665 p95 (a sort of 177k rows in memory).
- **Problem:** the design never ranks (761-765) — keep it that way; any future "best match" toggle would
  sort in memory on a phone.
- **Smallest change:** a unit test that the generated search SQL contains no `ORDER BY rank`.

### R-20 · MINOR · The gate's audit routes need the mail kill-switch the calendar never got

- **Where:** UX §13 routes (2982-3013); findings L1 (`--disable-icloud` not honoured by
  `MealBacklogWake.subscribe`); ENGINE §18 "must not start anything in a `VisualAuditRoute` launch".
- **Smallest change:** one `MailTransport` choke point that refuses every request when the process has any
  `VisualAuditRoute` flag or `--disable-mail-network`; a test counts URLSession call sites against guard
  sites (mail-budgets.md §3).

---

## Budget by budget (my M1–M10 against both designs)

| | Engine | UX | Verdict / who moves |
|---|---|---|---|
| **M1 launch** | inv. 16 (two registrations), §4.11 snapshot ≤ 2 ms only when Mail restored, `activate()` from `wireUp()` | 8.1 "≤ 10 ms added", 8.2 item 1 | **Meets, stricter than M1 — adopt.** Add R-7's `activate()` ≤ 1 ms main-actor rule and the gate check: every existing route's marks within the noise floor (40 ms raw, normalised under load; 100 ms for `*.loaded`). |
| **M2 triage keypress** | inv. 14, `perform` returns before I/O, durable ≤ 20 ms p95 | T0 next frame, 8.1 rows 1–3, G2 | **Meets on the main thread; contradicts on durability only via R-4** (assumed fsync). Engine moves: coalescing rule + device fsync first. |
| **M3 open conversation** | §15 rows ≤ 5 ms / ≤ 30 ms cached; §10 prepared at open | 8.1 50/100 ms, web paint 150/300 ms | **Contradiction (R-1):** the end-to-end budget rests on a non-sanitiser number and an at-open parse. Engine moves: prepare at fill. Keep my 250 ms end-to-end on device as the ceiling until measured. |
| **M4 search** | §9 150 ms debounce, 2+ chars, newest-first, interrupt; ≤ 30 ms p95 | 8.1 30/100 ms | **Meets at 2–3 and ≥ 5 letters; at risk at 4 (R-5).** Engine moves after a device measurement. Adopt 30 ms. |
| **M5 scroll 120 Hz** | — (silent) | 8.1 "holding J: no frame dropped", U4 line "no hitch longer than a frame", G2/G5 | **Silent in the engine; UX's rules are right but host-dependent (R-2).** UX moves: host decided by P1 with FrameProbe numbers (§4). |
| **M6 initial sync CPU/thermal** | governor (quota-bound), inv. 15 (background), `mail.fill` on power | 7.1 "complete in hours" | **Silent on foreground CPU/thermal and on local passes (R-3, R-8).** Engine moves: `MailWorkPace`, two §15 rows. |
| **M7 polling** | §12.1 20/90/nil (iOS), 20/60/60 (Mac); nothing-changed tick = 0 writes/publishes/≤ 5 ms | 8.1 "new mail ≤ 30 s / 60 s" | **Contradicts M7 (≤ 1/min) by 3× on screen (R-14); Mac background polling collides with F11.** Engine moves to 30 s; the Mac needs a gate first. |
| **M8 memory** | ≤ 40 MB engine, web excluded, 31 MB page caches | pool of two → U-5's "one per open message, cap six" | **Contradiction by omission (R-9).** Both move: whole-process + web-content numbers, measured in P3. |
| **M9 disk** | D3 ceilings in **Application Support** (offline-first, not purgeable), LRU with keep rules, `auto_vacuum=INCREMENTAL`, no free-space floor | — | **My M9 was wrong** (Caches-class store cannot hold offline mail); adopt D3 + S-2's floor. Keep: eviction off-main, `VACUUM` on power only, `du` daily. |
| **M10 zero impact** | §16 sinks, inv. 15/16, `mailBadge` mirror (one defaults int) | G3/G4/G10/G11, P0/P1/P2 audits | **Meets in intent; the Mac half fails until F11 is fixed (R-7).** The whole-app `compare` against P0 is the gate, every existing route, every milestone. |
| **Law 1 vs inv. 13** | ≤ 1/s status, ≤ 2/s feed from sync, once per action | T7 (400 ms rest) | Compatible (R-15). |

---

## Are the measured numbers the right numbers?

**What the methodology hides** (digest §C, `mailstore_spike.swift`):
- **Warm OS file cache, desktop SSD:** every read is a page-cache hit; `cold200k.txt` says so itself. On a
  phone after a reboot the first `index.sqlite` page reads are NAND (hundreds of µs per 4 KB page cold),
  WAL replay on open is unbounded (the design's reason for `first-page.json` — correct), full fsync is
  5–40 ms (R-4), a 38 MB passive checkpoint is INFERRED 100–300 ms not 20, and the 50-message delete
  (80 ms p95 here) is the one that will hurt during eviction.
- **Synthetic text:** plain words, Zipf pseudo-vocabulary, 3.8 KB/message, no HTML, no quotes, no MIME,
  no URLs or entity residue; `unicode61` on real mail produces more distinct terms (URLs, hex ids), so the
  FTS size ratio (124 % of text) and the insert cost per message are unverified for real mail; the
  design's 1.5–2.5 KB/message is ASSUMED (801-802). The HTML spike's inputs are generated newsletters
  with 8–250 blocks; no real campaign HTML, no 20 MB part, no 100k-element bomb (P-3's fixtures).
- **Single process, no contention from the app:** no `AVPlayer`, no CloudKit engine, no other SQLite
  (`Foods.sqlite`), no SwiftUI on the main thread. The under-ingest test used two reader threads on
  global queues, not the design's eight serial queues with QoS.
- **Load:** R-13.

**Likely far worse on an iPhone** (ordered by how much): full-fsync and intent durability (R-4); the
rebuild/re-index/seeding passes and any indexer catch-up (R-3: CPU-bound, throttled, hot); checkpoint and
delete/eviction latency (NAND); the 4-letter search cliff (R-5); memory with web content and four page
caches (R-9); cold open after reboot (mitigated); the 50-message batch hold (R-11). Likely fine: list page
reads (0.03 ms → still < 1 ms), counts, keyset paging, snapshot decode, zlib, interrupt.

**Decisions that flip if a number moves** (with the number and the flip factor):

| Decision | Rests on | Flips at |
|---|---|---|
| FTS in its own file | 43 → 5.4 ms sync txn; 1.25 GB → 141 MB index; quick_check 8.8 → 0.4 s | does not flip (9×, 9×, 22× margins) |
| `wal_autocheckpoint=0` | p99 18.6 → 0.96 ms archive | strengthens on NAND (a checkpoint inside a commit costs more there) |
| `prefix='2 3'` | 4-letter 16/18/34 ms vs budget 30 p95 | **2×** (R-5) |
| 8 ms group commit, `FULL+fullfsync` on intent | 3/5 ms Mac fsync | **~2×** (R-4): at > 8 ms per commit the fixed window stops coalescing |
| 50-message sync batch | 25.4 ms p95 vs 30 budget | **1.2×** (R-11) |
| Overlay written through | archive 0.33 ms p50 | does not flip (50× margin to 16 ms) |
| JSON snapshot over plist / DB | 0.27 vs 0.61 / 0.41 ms | does not flip; cold DB open is the real reason |
| Keyset over OFFSET | 0.04 vs 1.2 ms | does not flip |
| Twin unified views over IN-list | 0.03 vs 49 ms; 9.8 MB | does not flip |
| HTML prepared at open | 0.6 ms per 261 KB (tag walk) | **already flipped** by P-3 + the reuse review (R-1) |
| Readers hold no transaction | 14 MB vs 486 MB WAL | does not flip; it is a correctness rule |
| 2-letter minimum | 205 ms one-letter | does not flip |

**Must be re-measured, and under what conditions** (do not do it now — the machine has had a load average
in the hundreds all day):
1. `mailstore_spike` and `content_spike` on this Mac at 1-min load < 4 with no `xcodebuild` running, five
   repeats, medians + p95 (R-13) — the §21 table regenerated from that.
2. The same against the design's own schema/PRAGMAs/wrapper (R-10), once P02 exists (order 1).
3. On the owner's iPhone (Beta, Release; device-protocol.md): full fsync ×400 (R-4), 4-letter search p95 at
   200k (R-5), a 50-message batch under `reader.ui` (R-11), a 38 MB passive checkpoint, a 50-message
   delete, cold open after reboot, index build rate for 20k messages (R-3's pace constant) — one
   `--verify-mail-bench` route, 15 minutes.
4. Prepare cost with the chosen parser on the hostile fixtures and on 50 real newsletters from the owner's
   mailbox (Mac Beta first) (R-1).
5. Real-mail FTS size and index size after the first Mac fill (replaces every ASSUMED KB/message).

---

## Whole-app impact (what the designs add)

| Surface | Added by the designs | Cost / guard |
|---|---|---|
| Launch (every launch, Mail never opened) | two `BGTaskScheduler.register` calls | ≈ 0; keep inv. 16 |
| Launch (Mail opened before, not restored) | `activate()` from `wireUp()`: 4 WAL opens, overlay rebuild, drivers start; first page fetched off-main | must be off the main actor and not awaited (R-7, R-18); `wireUp.done` unchanged in the gate |
| Launch (Mail restored) | `MailFirstPaint.load()` sync read (0.27 ms Mac) | `mail.snapshot` mark; ≤ 10 ms to first frame |
| Badge | `mailBadge` int in UserDefaults; `ActionBadges` reads it on its 60 s timer (F5) | one defaults read; no new storm source; F5 unchanged |
| Memory | 31 MB page caches + models + heights + web content | R-9 |
| Background (podcast playing, iOS) | nothing by inv. 15 (poll paused, fill stops at batch boundary, outbox timer cancelled) | verify with the §5 soak; the risk is a `URLSession` background session or a retry `Task.sleep` escaping the rule |
| Background (Mac) | 60 s poll + sync + index writes with the window hidden | F11: ungated; add a Mac visibility signal before order 6 |
| 60 s pollers | `MailRuntime` at 20/90 s (iOS), 20/60/60 s (Mac) beside `CloudSyncPoll` 60 s, Google 120 s, `ActionBadges` 60 s | R-14; wakeups budget in the gate |
| Foreground cascade | one poll per `.active` | F2 first |
| Mac shell | Mail section, ⌘2, menu commands; `MacRootView` must not observe `MailStatus` (G3) | watchdog sinks outside `#if os(iOS)` (F11) |
| Diagnostics | `✉️` lines, 5 signposts, `mail↻`/`mailList↻` sinks, `sqlite3_status` in the minute line | cheap; the minute line grows one field |

Fix before order 1 because mail makes them worse: **F2, F5, F11, F12** (sinks + probe gating). Independent:
F1, F3, F4, F6–F10, F13–F19 — F1 and F3 should still land before order 6 because the device pass measures
launch and UserDefaults churn with mail present.

---

## UI feasibility at speed, and the prototype measurements

**The list host.** My verdict: a `UICollectionView` list layout (iOS/iPadOS; system leading/trailing swipe
actions come from `UICollectionLayoutListConfiguration`) and an `NSTableView` (Mac), each row a SwiftUI
view through `UIHostingConfiguration` / an `NSHostingView` cell, fixed row heights, self-sizing off,
prefetching on. Reasons from this app's history: (1) it is the only host with an offset and
`performBatchUpdates` compensation, which T9/T11/T26 and the 2.5 s discard need (U-1); (2) the Day grid
already went this way for the same reason (`DirectionalDayScrollView`) and the one bug class it produced —
a hand-kept content token — is a known rule now; (3) a 400-row window with `show(around:)` is natural on a
collection view and awkward on `List`; (4) `List` diffs the whole array per publish; a collection view
applies a diffable snapshot, and `MailRowMark` cells flip without a snapshot. Cost: hosting-configuration
cells carry a SwiftUI graph each — fine at 25 visible, which is why fixed heights and reuse matter, and why
the per-row `Equatable` rule (G1) still applies. If P1 shows `List` holding offset within a point and
compensating inserts, keep `List`; I expect it will not.

**Cursor under a held key:** the per-row leaf observable is the `PlaybackClock` pattern and is right on any
host; on a collection view the scroll-to per repeat is `scrollToItem` with no animation, cheaper than
`ScrollViewReader`. **32 pt rows on the Mac:** `NSTableView` with `rowHeight = 32`, no automatic row
heights, cell reuse — fine; the drawing U-17 asks for is cheap. **Bodies:** TextKit 2 views per message
(non-scrolling, height from `usedRect` measured off-main on a private layout manager), one `WKWebView` per
open designed message capped at six with recorded heights and an empty paper placeholder — U-5's proposal is
the one that holds; heights keyed by (message, width bucket, text size, pictures shown). **State across the
discard:** everything in `MailSession`; the host restores (first key, whole-point offset) stamped on
backgrounding; web bodies repaint into placeholders of recorded height — the 100 ms "back from blank" is
reachable only with the host, which is why P1 decides it.

**Prototype measurement specs** (all in the gate's Release(+DEBUG) build on the Mail iPhone simulator *and*
on the owner's phone when he says go; every number into the journal and `results/`):

| | Measure | Instrument | Passes when |
|---|---|---|---|
| **P1 list host** | (a) marked row's frame per display frame during: prepend 3 at depth 50, tree rebuild at row 137, window slide, 2,000 `J` repeats at 30/s, 20 full swipes; (b) hitches; (c) list body count; (d) first frame after a scripted background > 3 s | `FrameProbe` (`--frame-probe`, 1 s windows, fps/hitches); `mail.list.renderCount` probe (`--perf-trace`); a UI test reading the marked row's `frame` via accessibility each 16 ms; screenshot diff at return | marked row moves 0 pt on prepend/rebuild; restored within 1 pt after discard; 0 hitches > 2 frames per 10 s of held `J` on device (≤ 3 on Simulator); list body count +0 during held `J`; shell `RenderStats.note("MailShell")` +0 |
| **P2 keys** | time from key event to the row mark's frame; type-ahead at 5 ms/char lost chars; iPad `Tab` focus | `Signpost("mail.key")` begin at the monitor, end at `MailRowMark` publish; journal | p95 ≤ 1 frame (8.3 ms) on device, ≤ 16 ms Simulator; 0 lost characters; focus reaches the list in ≤ 2 events |
| **P3 bodies** | `mail.open` for `forty` (⇧O), `plain-chain`, `big-image`, three unread `newsletter`s; app footprint and WebContent footprint with six web views; jumps while scrolling up | `Signpost("mail.open")`/`"mail.webPaint"`; `⚡ POWER mem=`; on device `footprint`/Instruments for the content process; `FrameProbe` during the scroll-up; a UI test asserting each card's `frame.minY` never changes after first paint except by the recorded-height rule | open ≤ 50 ms (p95 of 20) with prepared bodies cached, ≤ 100 ms uncached native; web paint ≤ 150 ms second open; app ≤ baseline + 100 MB, web ≤ 150 MB, back to + 60 MB within 60 s of leaving; 0 card jumps > 1 pt |
| **P4 bars** | tab bar states vs the now-playing bar with an episode loaded; swipe conflicts | screenshots per state in the gate's route folder; FrameProbe during the swipe | no hitch; no gesture lost in 20 trials; the route's idle CPU unchanged |
| **P6 composer** | composer open with signature + quoted newsletter; detents with keyboard | `Signpost("mail.composerOpen")`; `mail.composer.renderCount`; FrameProbe during typing at 10 chars/s | open ≤ 50 ms; list and reader probes +0 while typing; 0 hitches |

---

## The gates, per milestone of the merged build order

Thresholds are **relative to the P0 baseline** (`results/20261005-165711-baseline-run1.json`): launch marks
within 40 ms raw, normalised by `app.init.body` when host load differs (100 ms for `*.loaded`); idle CPU
≤ 0.5 % absolute (a one-off must reproduce); footprint ≤ + 8 MB on existing routes; STORM/HIGH CPU = 0.
Benchmarks assert ≤ 2× this Mac's recorded medians (regression, Release) and log the rest. "Device" items
are deferred to the owner's phone and block the *next* order, not the current one.

| Order | Routes to add to `perf-gate.sh` | Benchmarks that must exist (Release, `--verify-mail-bench`) | Device (deferred) | Blocks the milestone |
|---|---|---|---|---|
| **0** | none new; re-run the whole gate as P0′ after F2/F5/F11/F12 land; add `--perf-trace` gating for the DEBUG probes | — | — | any regression vs P0 on an existing route; the four whole-app fixes not landed |
| **1** (store, fake, read-only list) | `mail-inbox\|iphone,ipad\|--ui-preview --dummy-health --tab mail --disable-icloud`; `mail-all\|iphone,ipad\|--mail --mail-place all` (5,200 rows) | `pageRead` (50 rows, 6 views) ≤ 2× 0.03 ms; `unreadCounts12` ≤ 2× 0.22 ms; `keysetWalk` last 100 pages; `syncBatch50` p95 ≤ 2× 25 ms *with `reader.ui` active*; `activate` ≤ 1 ms main-actor, ≤ 60 ms total; `firstPage.json` ≤ 2× 0.27 ms; `listApply` W = 400 / 2,000 / 5,000 rows (main-thread ms, ratio 2,000:400 ≤ 6) | fsync ×400; cold open after reboot; 4-letter prefix p95 (R-4, R-5, R-11) | `mail-inbox` root.appear > `shell-plan` + 40 ms; `mail-all` idle CPU > 0.5 % or any STORM; `activate` on main > 1 ms; P1 not run |
| **2** (actions, undo, selection) | `mail-triage\|iphone,ipad\|--mail --mail-place all --mail-cursor q3` (the idle run with a scripted 30 `E`/s UI test before it) | `archiveOne` ≤ 2× 0.33 ms; `intentCommit` group-commit coalescing test (30 actions in 20 ms share ≤ 2 commits); `walGrowth` 1,000 archives ≤ 40 MB then PASSIVE ≤ 2× 20 ms; publish-count test: 10 `E` = 10 feed publishes, 0 status publishes | fsync-bound durability p95 (R-4) | list body count rising under held `J` (probe); any publish per keystroke from `MailStatus`; `mail-triage` idle > 0.5 % |
| **3** (bodies, first web view) | `mail-open\|iphone,ipad\|--mail --mail-open forty`; `mail-newsletter\|iphone,ipad\|--mail --mail-open newsletter`; P3's UI test | `prepare` per fixture with the chosen parser: 63 KB / 261 KB / 1.2 MB / hostile set, ≤ 10 ms per 100 KB Mac, 2 MB + 1 refused; `open` cached ≤ 2× 0.63 ms rows + inflate; `heightsCache` load ≤ 5 ms | WebContent footprint; `mail.webPaint` on device | `mail-newsletter` footprint > baseline + 100 MB or not back to + 60 MB in 60 s; any HTML work on main (a `dispatchPrecondition(notOnQueue: .main)` in the preparer, tested) |
| **4** (compose, send) | `mail-compose\|iphone,ipad\|--mail --mail-compose reply --mail-compose-state typed` | `composerOpen` ≤ 2× measured; typing publish test (0 list/reader publishes per keystroke) | — | reader/list probes moving while typing |
| **5** (search, splits) | `mail-search\|iphone,ipad\|--mail --mail-search "shai"` (four letters, the cliff) and a two-letter variant | `ftsQuery` 2/3/4/5 letters, common/rare/two words ≤ 2× §21 medians, p95 reported; `interrupt` ≤ 5 ms; `indexBatch50` ≤ 2× measured; `reindexRate` msg/s at pace 20 % vs full (R-3's pace constant proven) | 4-letter p95 (R-5) | 4-letter p95 > 60 ms on the Simulator (2× the budget); `ORDER BY rank` present (R-19); indexer runs unpaced with `AppVisibility.isActive` and battery |
| **6** (real account, Mac Beta first) | `mail-reindex\|iphone,ipad\|--mail --mail-rebuild-search` (the paced local pass as an idle run: `⚡ POWER` avg ≤ 25 %, thermal nominal); the Mac `--ui-audit --mac-section mail` snapshot | `pollQuiet` (0 writes, 0 publishes, ≤ 5 ms CPU) with a fake transport; `suspend()` test (zero requests for a simulated hour) | the owner's runs below, in order | Mac `mail↻` sink inside `#if os(iOS)`; any mail timer alive after `.background` (journal silence test); first Mac fill shows `🔥 HIGH CPU` or thermal ≥ fair; `compare` vs P0 fails on any existing route |

**Per-package checks before handing a package back** (the implementer runs these; they take ~15 min):
1. `perf-gate.sh run --skip-build --only <the package's routes>,shell-plan,day --label <pkg>` after a fresh
   Release(+DEBUG) build, then `perf-gate.sh compare <P0>.json <pkg>.json` — exit 0, or explain each line.
2. The package's benchmark via `--verify-mail-bench <names>` on the Mail iPhone simulator in Release —
   ≤ 2× baseline; numbers pasted into the package note with the load line.
3. 60 s on the package's route with `--perf-trace`: every `perf` line reads `no bodies` after settle;
   `RenderStats` for `MailShell` +0 across the package's interaction.
4. For any view package: `ScreensOpenUITest` in Release on the iPad (G12) — the only place the stack test
   exists.
5. Thread Sanitizer over the mail tests; the journal privacy test; `grep -n '@AppStorage("[^"]*\.'` over
   `Banana/Views/Mail*` = 0.

**What Debug-on-Simulator benchmarks can assert** (E-34): shapes and ratios, not milliseconds — zero
publishes/writes on a quiet poll; publish counts per action; no SQLite on the main thread
(`dispatchPrecondition` in the wrapper, exercised); WAL size bounds; the 2 MB + 1 refusal; interrupt stops
a query; `ORDER BY rank` absent; complexity (time at 10 n ≤ 2× time at n for paging, counts, apply);
allocation counts within 2× (`XCTMemoryMetric`); and ≥ 3× regressions against a recorded Debug baseline.
Absolute budgets: Release on device only.

---

## What to ask the owner for (in order)

1. **Beta on his iPhone, the fixture route, 30 min:** `--mail --mail-place all` in Release with the P1 UI
   test and `--verify-mail-bench fsync,fts4,batch50,checkpoint,delete50,coldOpen`. Tells us the real full
   fsync (R-4), the 4-letter search p95 (R-5), the batch hold (R-11), hitches on the chosen host — the four
   numbers the design assumed. Nothing of his data is touched (fixture only).
2. **P3 on his iPhone, 20 min:** six web views open; `footprint` of both processes before, during, after a
   minute away (R-9). The Simulator cannot show WebContent memory or jetsam.
3. **First sync of his real mailbox on the Mac Beta, order 6, ~2 days wall / 10 min of attention:** the
   journal's `✉️ sync/quota/index/store` lines and `⚡ POWER` per minute, store sizes at the end. Tells us the
   governor's real rate (D7), real-mail KB/message and FTS size (replaces every ASSUMED), prepare cost on his
   newsletters (R-1), and whether the Mac's unthrottled indexer heats a laptop (R-3).
4. **One hour of his iPhone in front during its first sync, then one night on the charger:** `⚡ POWER`,
   thermal lines, wakeups; the next day's `📊 MetricKit` line (CPU-limit kills). Tells us the phone's
   foreground cost (R-8) and whether `mail.fill` survives its windows.
5. **The §4.2 soak, 2 h, podcast playing, Mail's tab last shown:** proves inv. 15 and M10 — the one budget
   a mail client is most likely to break silently.
6. **Five minutes of Control Center glances mid-episode, before and after F2:** the journal counts the
   CloudKit and mail requests per glance.
