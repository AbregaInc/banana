# Mail budgets — what the Gmail client must be held to

In the form of docs/PERF-PLAN.md §5 (scenario → budget → instrument). Assumptions: a local-first
client that caches an entire mailbox — up to **200,000 messages, several GB of bodies and
attachments** — in SQLite with FTS5, and polls Gmail for changes. Every budget is also a *gate*:
it has a Simulator measurement (added to `perf-gate.sh` as routes), a unit-level benchmark, and a
device measurement (`device-protocol.md`). Numbers are proposals to be confirmed against the first
measured milestone, not folklore; where a number comes from an existing guard it is cited.

Precedent in the tree: `Banana/Model/FoodDatabase.swift` already opens a bundled SQLite database
read-only with `SQLITE_OPEN_NOMUTEX` (FoodDatabase.swift:522) and runs FTS5 `bm25` queries
(FoodDatabase.swift:277-278). Mail should reuse that access layer's shape (prepared statements,
one connection per queue), not a new ORM.

## Reconciliation with `docs/design/MAIL-ENGINE.md` (untracked, appeared 17:52 during this audit)

The engine design already carries its own budgets (§15, "to be reconciled with" the whole-app
baseline), invariants 10–16 (performance), a first-page snapshot (§4.11, `Cache/first-page.json`,
MEASURED 0.27 ms), measured write costs at 200k messages (§4.12), a poll table (§12.1) and
PerfWatchdog/Signpost/LaunchClock wiring (§16). Read side by side:

| This document | MAIL-ENGINE.md | Verdict |
|---|---|---|
| M1 launch: snapshot ≤ 5 ms sync, SQLite off-main | §15 row 1–2: nothing before first frame except two `BGTaskScheduler.register`; snapshot ≤ 2 ms only when Mail is the restored tab; invariant 10 | **Design is stricter — adopt it.** Add: the whole-app gate's existing marks must stay within the noise floor in `baseline.md` (row 1 says "unchanged against the baseline"; the floor is 40 ms raw / normalised under host load). |
| M2 keypress ≤ 1 frame, write ≤ 50 ms off-main | §15 "An action: main thread ≤ 1 ms, no I/O; durable ≤ 20 ms p95"; invariant 14 (selection is a leaf) | Design is stricter — adopt it. |
| M3 open conversation ≤ 100/250 ms | §15 rows ≤ 5 ms p95 and ≤ 30 ms cached bodies | Design is stricter on the engine side; **keep my 250 ms as the end-to-end (incl. WKWebView layout) budget on device**, which §15 does not state. |
| M4 search p95 ≤ 50 ms, 150 ms debounce | §15 ≤ 30 ms p95, superseded query stops ≤ 10 ms | Design is stricter — adopt 30 ms. |
| M5 scroll, FrameProbe | §15 "30 actions/s: no dropped frame attributable to mail" | Equivalent; **add the FrameProbe scroll test** (§15 names `--perf-trace`/`RenderStats`, not frames). |
| M6 initial sync: CPU ≤ 25 %, 0 in background, thermal nominal, memory +60 MB | §15 "sync batch hold on writer ≤ 30 ms p95", invariant 15, §12.2 fill under `requiresExternalPower` | **Design has no foreground CPU/thermal ceiling for the fill** while the app is open — keep M6 (PerfWatchdog `alarmingCPU` 25 %, `🌡 THERMAL` = fail). |
| M7 poll ≤ 1/min foreground, 0 background, nothing-changed cost 0 writes/publishes | §12.1: **20 s** with Mail on screen, 90 s elsewhere in app, nil in background; "a poll that finds nothing: 0 writes, 0 publishes, ≤ 5 ms CPU" | **Differs: 20 s vs 60 s.** 20 s is 3× the wake rate of `CloudSyncPoll`; cheap by quota, but it is a main-run-loop timer firing 180×/h on a phone in front. Decision for the owner; the gate measures it either way (`power_wakeups` on `mail-inbox` vs `shell-plan`). |
| M8 memory ≤ 180 MB with a conversation open | §15 "engine ≤ 40 MB added, web content excluded"; SQLite page caches ≤ 31 MB | **Design excludes WKWebView** — keep M8 as the whole-process ceiling (device), measured by `⚡ POWER mem=`. |
| M9 disk: index ≤ 1.5 KB/msg, Caches-class LRU cap | §15 index ≈ 0.15 GB, search 0.4–1.1 GB, bodies 1.6–4 GB (ASSUMED), attachments to a ceiling; §11 | Design's numbers are measured — adopt them; **search 1.1 GB on synthetic text is the one to watch** (a third of the budget is the FTS file). Keep M9's eviction-off-main and charger-only `VACUUM`. |
| M10 zero impact on existing budgets | §15 last bullet: "every milestone re-runs the entire gate" | Same. Add the explicit list: no new `RootView`/`MacRootView` observers; no dotted `@AppStorage`; `PerfWatchdog` sink **outside** `#if os(iOS)` (findings F11 blind spot). |
| Guards table (§3 below) | §16 diagnostics: `RenderStats.note("MailShell")`, `mail↻` sink, Signposts `mail.sync/apply/index/prepare/send`, journal rule (invariant 21) | Same intent; the design routes engine logging through a seam because engine code may not name `PlaybackDiagnostics` (invariant 17) — fine. |
| Audit routes + `--disable-mail-network` | §18: "must not start anything in a `VisualAuditRoute` launch"; `--mail-webview` route | Adopt; **add the explicit network kill-switch flag** (the calendar's `--disable-icloud` is not honoured everywhere today — findings L1 — so make the mail one a single choke point in the transport). |

Net: the budgets below stand where the design is silent (end-to-end open latency, foreground
CPU/thermal during the fill, whole-process memory with web content, the FrameProbe scroll test,
the network kill-switch) and defer to §15 where it is stricter. File names in M9 follow the design
(`intent/blobs/index/search.sqlite`, `Cache/first-page.json`, `Cache/Attachments`).

## 0. The two laws that already exist, restated for mail

1. **Publish at the rate of meaning, not the rate of I/O** (§6). A sync pass that inserts 5,000
   messages publishes once per *batch commit* (≥ 1 s apart), never per message; progress goes
   through a leaf observable (`MailSyncTicker`, the `PlaybackClock`/`ProgressTicker` pattern) that
   only the progress pill observes.
2. **Nothing runs in a pocket.** `AppVisibility.shared.isActive` gates sync, indexing, HTML
   pre-rendering, eviction; the inbox tree sits under `RootView.gatedContent`, which replaces it
   with `Color.black` 2.5 s after backgrounding (AppVisibility.swift:40). Background work exists
   only as a `BGAppRefreshTask` (≤ 30 s, system-scheduled) or a `BGProcessingTask` with
   `requiresExternalPower = true` (the overnight-batch pattern, OvernightRefresh.swift:29-31). The
   app is a background-audio process for hours a day; iOS kills it at 80 % CPU over 60 s.

## 1. Budgets

| # | Scenario | Budget | Instrument |
|---|---|---|---|
| M1 | Cold launch → readable inbox (top 30 rows, subject/sender/snippet/date) | `mail.inbox.content` ≤ `root.appear` + 150 ms (device); the 30-row snapshot is loaded synchronously at store init in ≤ 5 ms (the §4b stale-while-revalidate pattern; OccurrenceStore.swift:166); SQLite is opened **off-main**; existing marks (`root.appear`, `today.content`, `wireUp.done`, `library.loaded`) unchanged within the gate's noise floor | LaunchClock marks `mail.init`, `mail.snapshot`, `mail.loaded`, `mail.inbox.content` in playback.log; gate route `mail-inbox` |
| M2 | Keypress-to-visual-response for triage (archive, delete, star, mark read, next/prev with hardware keys) | ≤ 1 frame (8.3 ms at 120 Hz) to the optimistic UI change; the SQLite write and the Gmail `modify` queue on a serial lane, ≤ 50 ms off-main; zero main-thread I/O; body evals ∝ keypresses (one inbox publish per action) | FrameProbe (`--frame-probe`) hitch count during a scripted 50-action UI test; `perf` lines (`--perf-trace`) body counts; `Signpost("mail.triage")` |
| M3 | Open a conversation | plain-text/first paragraph visible ≤ 100 ms; HTML body laid out ≤ 250 ms (device, warm); ≤ 400 ms cold; body row fetched off-main (bodies are never in the list query) | `Signpost("mail.open")` + journal line `✉️ open <ms> bytes=<n> parts=<n>`; UI test timing on `--mail-fixture` |
| M4 | Search-as-you-type | FTS5 query p95 ≤ 50 ms at 200k messages (unit bench, device class); 150 ms debounce; previous query cancelled; one results publish per completed query; the keyboard never waits on the query (query thread ≠ main) | `MailBench` (`--verify-mail-bench`, like `CPUVerification.runIfRequested`) writing p50/p95 to the journal; gate route `mail-search` idle after a typed query |
| M5 | Scroll the inbox at 120 Hz | 0 hitches > 2× frame duration per 10 s of fast scroll on device; ≤ 3 on the Simulator (host noise); rows are value types prepared off-main (no `DateFormatter()` in body — F24; no per-row sort/filter — H3; avatars through `ImageCache` 128 px bucket — ImageCache.swift:209-211) | FrameProbe in a `MailScrollUITest` (as `MotionRenderFrameProbeUITest` does); `RenderStats.note("MailInbox")` body counts |
| M6 | Initial sync of a whole mailbox | never on the main actor; batches of ≤ 500 messages per SQLite transaction, one publish per batch; process CPU ≤ 25 % avg while in front (PerfWatchdog `alarmingCPU`, PerfWatchdog.swift:110 — a sync that trips `🔥 HIGH CPU` is a failed budget); **0 CPU with the app backgrounded** unless inside a BG task; the sync *resumes* from a persisted cursor after any kill; memory ≤ +60 MB over idle during the pass; thermal state must stay nominal (`🌡 THERMAL` lines = failure) | `⚡ POWER` lines (cpu avg/max, mem, thermal) during the pass; `Signpost("mail.sync.initial")`; journal line per batch `✉️ sync batch n=500 ms=… bytes=…`; MetricKit next day: no `CPU-LIMIT KILLS` |
| M7 | Polling when nothing changed | ≤ 1 HTTPS request per minute while in front (`users.history.list` with `startHistoryId` — a few hundred bytes); **0 requests in the background** (CloudSyncPoll pattern: `pause()` on `.background`, CloudSyncPoll.swift:26-29); 0 SQLite writes, 0 publishes, 0 journal lines on an unchanged tick; cursor persisted only when it moves | journal: count `✉️ poll` lines over 10 idle minutes (must be ≤ 1 per changed tick); `nettop`/Charles not needed — the journal is the instrument; gate idle run on `mail-inbox`: `power_wakeups` within noise of `shell-plan` |
| M8 | Memory while rendering HTML mail | app footprint ≤ 180 MB with a conversation open (idle Simulator footprint today is in `baseline.md`; the 2026-07-23 device idle was 13.9 MB); one reused `WKWebView` (its content process is separate and must be released on background); remote images downsampled through `ImageCache` (never `UIImage(data:)` of originals); `didReceiveMemoryWarning` clears mail caches like `ImageCache.clearMemory()` (RootView.swift:230-232) | `⚡ POWER mem=` with a conversation open vs inbox; `MemoryLog.footprintMB()` in a `✉️ open` line; gate route `mail-conversation` |
| M9 | Disk growth and eviction | index (`mail.sqlite`, Application Support) bounded by message count: ≤ 1.5 KB/message of metadata+FTS (≈ 300 MB at 200k); bodies+attachments in a `Caches`-class store with an LRU cap (default 2 GB, user-settable; eviction off-main; attachments never auto-downloaded on cellular — `NetworkMonitor.isCheap`); `VACUUM`/`optimize` only on charger (BGProcessingTask with `requiresExternalPower`); WAL checkpoint size bounded (`wal_autocheckpoint`) | gate `container-sizes.txt` (`du` of Application Support / Caches) after `--mail-fixture 200000`; delete test: evict → size drops; unit test for the LRU |
| M10 | Zero impact on existing budgets | background playback stays ≤ ~2 % avg CPU with mail installed (§5 row 1) — mail must not add a timer that is alive while backgrounded; launch marks unchanged within noise; no new store observed by RootView/MacRootView; **no `@AppStorage` key with a dot** in any mail view; `PerfWatchdog` gains sinks for the mail store(s) so a storm names `mail↻`, not `RootView` | `perf-gate.sh compare` against the pre-mail baseline (every existing route must pass); PERF-PLAN §4.2 soak; grep gate for `@AppStorage("…\.…")` |

## 2. How each is measured — three levels

**Simulator gate (`perf-gate.sh`).** Add routes (one line each in the route table) once the
`VisualAuditRoute` flags exist in `BananaApp.swift` (they must be added to `VisualAuditRoute.flags`
or the route starts the production graph — RootView.swift:270):
```
mail-inbox|iphone,ipad|--ui-preview --dummy-health --tab mail --mail-fixture 20000
mail-inbox-200k|iphone,ipad|--mail --mail-fixture 200000
mail-conversation|iphone,ipad|--mail-conversation --mail-fixture 20000
mail-search|iphone,ipad|--mail-search "quarterly" --mail-fixture 200000
```
`--mail-fixture N` seeds a deterministic synthetic mailbox into the Simulator container (seeded
RNG, fixed sizes) and **never talks to Gmail**: the audit routes must have a hard `--disable-mail-
network` equivalent exactly like `--disable-icloud` (and unlike `MealBacklogWake.subscribe`, which
today ignores the flag — findings.md). The gate then yields for each route: launch marks (M1), idle
CPU/RSS/footprint/wakeups (M7, M8, M10), STORM/HIGH CPU (M5, M6), container sizes (M9). Compare mode
flags regressions beyond the measured noise floor (`baseline.md`).

**Unit-level benchmarks (deterministic, run on the Mail iPhone simulator and on a device).**
A `MailBench` entry point (`--verify-mail-bench`, DEBUG, modelled on `CPUVerification`/
`FitnessBatchVerification`) that, against a generated 200k-message database: (a) FTS5 query latency
p50/p95 for 10 fixed queries (M4); (b) insert throughput messages/s and bytes written per 10k
(M6, M9); (c) "open conversation" query time (M3); (d) inbox page query (LIMIT 50 OFFSET n) p95 ≤
5 ms (M1, M5); (e) eviction of 1 GB of bodies in ≤ 5 s off-main (M9). Results go to playback.log as
`✉️ bench …` lines and to `Documents/PerformanceRuns/<run>/result.json` via `PerformanceRunRecorder`
so `perfctl` can validate them. Plus XCTest `measure {}` blocks in `BananaTests` for the pure parts
(MIME parse, snippet extraction, HTML sanitisation) — keep the unit-test total within the 73.9 s
baseline + 10 s.

**Device (Beta).** `device-protocol.md` A2–A5 with the mail section added to A3; M6 is measured on
the real mailbox once (initial sync) with the journal open: CPU/thermal/memory per `⚡ POWER`
minute and the MetricKit line the next day. M7 by counting `✉️ poll` lines over an hour in front
and confirming silence in the background block. M2/M5 by FrameProbe with a hardware keyboard.

## 3. Guards mail must be wired into (not optional)

| Guard | Where | What mail must do |
|---|---|---|
| `AppVisibility.isActive` / `rendersContent` | AppVisibility.swift; RootView.swift:336-364 | Gate every sync/index/render task on `isActive`; stop the poll on `.background` (CloudSyncPoll.swift:26); the inbox is a `Tab` in `mainTabs` so it inherits the blank gate — keep navigation state in `ShellNavigation` (ShellNavigation.swift), not view `@State` |
| `PerfWatchdog` / `RenderStats` | PerfWatchdog.swift:151-174, 212-218 | `RenderStats.note("MailInbox"/"MailThread"/"MailCompose")` at the top of each hot body; add `MailStore.objectWillChange.sink { RenderStats.note("mail↻") }` in `PerfWatchdog.start()` (and *not* inside `#if os(iOS)` — the Mac shell is a blind spot today) |
| Journal | PlaybackDiagnostics.swift | `✉️` lines for sync passes, polls that found changes, opens > 250 ms, evictions; counts and ms, never subjects or addresses (DIAGNOSTICS.md privacy rule) |
| `Signpost`/`PowerTrace` | Signpost.swift | `mail.sync.initial`, `mail.sync.delta`, `mail.index`, `mail.open`, `mail.search`, `mail.evict` so `⚡ POWER … active=[…] done=[…]` attributes CPU minutes to mail |
| `LaunchClock` | LaunchClock.swift | `mail.init`, `mail.snapshot`, `mail.loaded`, `mail.inbox.content` |
| MetricKit | Metrics.swift | Nothing to add; read the next-day line after every sync milestone |
| `NetworkMonitor.isCheap` | NetworkMonitor.swift:41 | Attachments and bodies > 1 MB wait for Wi-Fi unless tapped |
| BG tasks | OvernightRefresh.swift, MealEstimatesInBackground.swift | Any mail background work registers an identifier in both Info.plists; full-body/attachment prefetch and `VACUUM` only with `requiresExternalPower` |
| Audit routes | BananaApp.swift:14-29 | Every mail route in `VisualAuditRoute.flags`; a `--disable-mail-network` flag honoured by every network call site (test: grep count of URLSession call sites == grep count of the guard) |
| `ImageCache` | ImageCache.swift | Sender avatars/inline images through the 128/256 px buckets; never a separate NSCache |
| Dot-free `@AppStorage` | memory note *banana-appstorage-dotted-key-storm* | `mailSortOrder`, not `mail.sortOrder` |

## 4. The three budgets most at risk (my ranking)

1. **M10 / §5 background playback.** A sync engine with a retry timer, a `Task.sleep` poll loop
   not gated on `isActive`, or a `URLSession` background session delivering events while a podcast
   plays, is the exact mechanism that got the app killed three times in a day. Gate: the journal's
   background block must stay silent; `ActionBadges`-style 60 s timers must not multiply.
2. **M6 initial sync vs. the thermal/CPU guard.** 200k messages × MIME parse × FTS insert is minutes
   of CPU; done in the foreground it trips `🔥 HIGH CPU` (25 %) and thermal `fair`; done in the
   background it is a CPU-limit kill. It must be batched, resumable, charger-preferring, and
   throttled by `ProcessInfo.thermalState`.
3. **M1 launch.** One more `@StateObject` constructor that opens SQLite synchronously, or a
   `locationManager`-class sync XPC on the first render pass (findings.md F1), moves `root.appear`
   for every tab, not just mail. The mail store must follow `WellnessStore.init`'s shape
   (WellnessStore.swift:73-104): detached decode, `whenLoaded()`, merge guard.
