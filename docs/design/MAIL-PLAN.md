# Mail: the build plan

Status: plan, 5 Oct 2026. Nothing is built. This is the one order for both halves of mail.
Engine packages are specified in `MAIL-ENGINE.md` section 18 and named here by id; UI packages
are specified in `MAIL-UX.md` section 14 and, row by row, in section 7 here. The gates and the
per-package checks come from the performance review (`mail-working/perf/design-review.md`);
the order from the engineering review's merged build order
(`mail-working/review/engineering.md`). The decisions for the author, from both halves, are one
table: section 8.

The aim, in order: a real inbox on screen, read from the real store, filled by the fake Gmail;
then triage; then reading; then compose and send; then search; then a live mailbox.
**Seventeen packages to that first inbox** — ten of the engine's (the contract package became
two), seven of the UI's (the columns added two: the triage model's pane rules and the
control column) — after one item of tooling, G0.

## 1. The order

`→` means "after"; packages on one line separated by `·` do not depend on each other. They
are still built and landed one at a time, by one implementer in this tree, unless the
orchestrator gives one its own worktree (section 5).

| Order | Engine packages (MAIL-ENGINE 18) | UI packages (section 7) | What becomes visible or provable | Gate |
|---|---|---|---|---|
| **0** | **G0** (the performance auditor's: `tools/perf-gate.sh`, `tools/perf-routes.d/`, the P0′ run) → **C0a** (the contract file, `MailSource+NotYet.swift`, `MailRowRules`, `MailUI/Pure/MailIdentifiers.swift`, the one `project.yml` edit) | prototypes **P1**, **P2**, **P3**, **P4**, **P6** (section 2); **the slice** — the list, the reading pane and the details column on sample mail, for the owner to try (section 7) | One surface both halves compile against; a baseline; fewer unknowns | Section 2 |
| **1** | **P01a** → **P02** → **P03a** → **C0c** (the contract as the owner ruled: MAIL-ENGINE 13.10) → **P05** → **C0b** (the fixture mailbox and the contract suite) → *U0′* → **P06a** → **P10a** → **P12a** → **P23a**. Beside them, for the gate: **P09a** | **U0′** (fixture source and session, on the contract; **directly after C0b**, being the first thing that can run the suite) · **U2** (tokens, primitives, the row) · **U3** (triage model; built) → **U3b** (its rules for the reading pane) → **U1a** (the seat, and the columns by width) → **U10a** (the control column) → **U4a** (the list, read-only, with its cursor; after P1). Pure, alongside: **U5a** (the keymap, as data). *U1a, U2 and U4a are re-cut around the slice when it lands.* | `--mail` on iPhone, iPad and Mac shows the inbox from `index.sqlite`, filled from `FakeGmail`; the same route on the in-memory source shows the same rows | **A** |
| **2** | **P06b** → **P14a** → **P14b** → **P12b** → **P15a** → **P15b** → **P23b**. Pure, alongside: **P04** · **P16** · **P20a** | **U4b** (actions, swipes, selection, toast, undo) → **U5** (keys on the Mac; after P2) | Done, undo, star, read, trash and labels on the real store; offline queueing; a change "on the web" applied at rest | **B** |
| **3** | **P03b** → **P07** → **P12c** → **P20b** → **P23c** → **P21a** → **P26** (with U7) | **U6** (the conversation: in the pane, over the list, pushed; after P3) → **U7** (designed bodies, pictures at four levels, attachments; one package with P26) · **U20** (the details column) | Opening a conversation from the store; native and designed bodies; the app's first web view | **C** |
| **4** | **P10b** → **P17** → **P18** → **P23d** | **U9a** (the composer: the card, the phone's sheet and sending; after P6) → **U9b** (attachments, formats) · **U15a** (delivery lines, Outbox) | Compose, reply, undo-send, a refused and an unconfirmed send — all on the fake | **D** |
| **5** | **P08a** → **P08b** → **P23e** → **P27** · **P09b** | **U11** (search: the device's results and Gmail's in one list) · **U10b** (the label and move pickers) | Search as you type, splits, places, labels | **E** |
| **6** | **P11** → **P13a** → **P13b** → **P33** → **P22a** → **P22b** → **P01b** → **P24** → **P25** | **U14** (turning Mail on; settings, with the sync limit and the picture levels) · **U15b** (states: offline, signed out, first sync, the questions, the edge of the limit) | Mail on a real account, on Mac Beta first | **F**, then **M5** |
| **7** | **P19a** (snooze, mute) → **P19b** (remind me if no reply) · **P18b** (send later). **In the first release, by the owner's ruling.** Built and tested on the fake whether or not their probes have run; W2, W3 and W5 gate the first use on a real account (MAIL-ENGINE 18.10, 19.3) | **U8** (the time picker and snooze; with P19a) → **U9c** (send later, remind if no reply; with P18b, P19b) — section 7 | Snooze, "remind me" and a scheduled message — on the fake, then on the test account | **G** |
| **Later** | **P28** · **P21b** · **P20c** · **P29**–**P32** | To finish the first release: **U4c** (the phone's bottom slot; after P4 and decision 2) → **U1b** (the phone's seat; after decision 1). After it: **U13** (invitations, add to plan, the day card) · **U12** · **U5b** · **U17** · **U16** · the control column inside Banana's sidebar, if he chooses it (decision 23) | | Each on its own decision |

**On the path to the first inbox, in landing order:** G0, C0a; P01a, P02, P03a, C0c, P05, C0b, U0′,
P06a, P10a, P12a, P23a (P09a beside, for the gate); then U2, U3, U3b, U1a, U10a, U4a. (U2, U3, U3b
and U5a need only C0a and can land any time after it.)

**Can wait until a live mailbox is near:** P01b, P11, P13a, P13b, P22a, P22b, P24, P25, P33.

**In the first release, since the owner's review:** a sync limit of six months with search
that asks Gmail as well (MAIL-ENGINE 5.4, 9.4 — it runs through P05, P06a, P12a, P12b, P13a,
P13b, P23e and P33, and adds no package but C0c); four levels of remote pictures (10.6:
P20b, P23c, P27, P24); and **snooze, "remind me if no reply" and send later — order 7**
(P19a, P19b, P18b). **To the first release, in order:** C0c, P05, C0b, P06a, P10a, P12a,
P23a (order 1) · P06b, P14a, P14b, P12b, P15a, P15b, P23b, with P04, P16, P20a (order 2) ·
P03b, P07, P12c, P20b, P23c, P21a, P26 (order 3) · P10b, P17, P18, P23d (order 4) · P08a,
P08b, P23e, P27, P09b (order 5) · P11, P13a, P13b, P33, P22a, P22b, P01b, P24, P25
(order 6) · P19a, P19b, P18b (order 7).

## 2. Order 0: what must be true before order 1 starts

| Item | Whose | What it decides or provides |
|---|---|---|
| **The contract is frozen by compiling it** — that is C0a. MAIL-UX section 12 declares no types and conforms to MAIL-ENGINE 13; the differences are listed in MAIL-ENGINE 22.1. The last text pass changed it in ten places, all now in MAIL-ENGINE 13.2–13.3: `MailRowRules.Outcome.leaves(MailRow)`; `MailRefusedChange` and `status.value.refused`; `searchGmail(_:)`; `asking` carrying the question's kind; `MailRowReason.held(until:)`; `MailPerson.fromTheirMail`; `MailConversationID.gmailURL`; `MailTuning.maxEncodedBytes`; `MailSendOptions.hold` optional; `MailBadgeCounts`' mirror — plus `reconsiderKeptMail(account:)` with `MailAccount.keptAfterRemoval`, and `MailSource+NotYet.swift` beside the file. **Added to the contract earlier:** `decideLink(_:in:)` with `MailLinkRules`, `MailLinkDecision` and `MailLinkWarning`; `MailEvent.draftNotSaved`; and the UX's A1–A5 — `MailPlaceCount` (conversations per split), `MailDraftPart` with `quoteAsText`, `changeIdentity` and `resource(_:forDraft:…)`, `needsAnswer` counting sends that failed for good, `alwaysShownPictureDomains` and `stopAlwaysShowingPictures`, and the place `.heldRemoval(account:)` (MAIL-ENGINE 22.2, last table, with the package that delivers each). A6's five-second checks are within the polling rules, bounded (MAIL-ENGINE 12.1). | Both | Nothing in order 1 can be built against two contracts. |
| **G0 — the performance gate** | The performance auditor | `tools/perf-gate.sh` (moved out of `mail-working/perf/`), reading its routes from `tools/perf-routes.d/*.routes` — one file per package, so no two packages edit one route table — and the whole gate run as **P0′**, the pre-mail reference every later gate compares against. Not a mail package; nothing of mail's lands before it. |
| **C0a** | Engine | The contract file, `MailSource+NotYet.swift`, `MailRowRules`, `Banana/Model/MailUI/Pure/MailIdentifiers.swift` (MAIL-UX 10.2), GRDB and SwiftSoup resolved. P01a, P02, U2, U3 and U5a need only this. |
| **C0b** (lands in order 1) | Engine | The fixture mailbox, defined once (MAIL-ENGINE 13.6), and the contract suite. **The suite first runs when U0′ exists**; U0′ follows it directly. |
| **The owner approves two packages and one data file** (MAIL-ENGINE D19): GRDB 7.11.1, SwiftSoup 2.13.9, the vendored tracker list. | Owner | C0a cannot edit `project.yml` without it. It is the only thing C0a needs from him. |
| **Whole-app fixes F2, F5, F11, F12** (`mail-working/perf/findings.md`): the foreground cascade; timers that survive backgrounding; the Mac's ungated work and the watchdog sinks inside `#if os(iOS)`; probes gated on `--perf-trace`. | App | Mail makes each of these worse; they land first. F1 and F3 before order 6. |
| **The read probe**, by `curl`, on a test account (MAIL-ENGINE 19.2). Needs a test Google account and the owner's go-ahead (D11); D1 and D7 are console actions done at the same sitting. | Owner | Sets the defaults of the fake's switches (17.2) and records the HTTP fixtures. If it has not run when P10a starts, P10a is built on the ASSUMED defaults — every one is a switch — and corrected after. |
| **Prototype P1 — the list host.** The 5,200-row fixture on a phone and a Mac, Release: prepend three rows at depth 50; rebuild the tree at row 137; hold `J`; full swipes; `listApply` at 400 and 2,000 rows. | UX | Whether SwiftUI `List` can stay or the list is a collection view and a table view. Blocks **U4a**. Also decides whether `MailTuning.listCap` can rise from 2,000. What it must show: MAIL-UX 6.1.8. |
| **Prototype P2 — keys.** The key monitor with a scope decided by intent, a type-ahead buffer; the same on an iPad. | UX | U-3 and the iPad's key host. Blocks **U5** (its Mac half) and **U5b** (its iPad half). What it must show: MAIL-UX 4.1. |
| **Prototype P3 — bodies.** `forty`, `plain-chain`, `big-image`, three newsletters, with TextKit bodies and one web view per designed message, on a phone. | UX, with P20a's output | `mail.open`, memory with six web views, jumps while scrolling. Blocks **U6** and **P26**. What it must show: MAIL-UX 6.2.5. |
| **Prototype P4 — the phone's bars.** The bottom slot above the shell's two bars, with an episode loaded; the tab bar hidden in a conversation; the swipe along the bar. | UX | The bottom layout, and the pictures for decision 2. Blocks **U4c** and **U1b**, and nothing in orders 1 to 6. What it must show: MAIL-UX 6.1.3. |
| **Prototype P5 — the send probes.** MAIL-ENGINE's W3 and W4, and a draft deleted and sent at the same instant. | Owner, on the test account | Whether any device may take over a late scheduled message (D8). Blocks **P18b** only; **P18** needs W3. |
| **Prototype P6 — the composer.** A Gmail signature with a picture and a quoted newsletter through the editor and back. | UX | Confirms the draft model of MAIL-ENGINE 7.1 (text, plus signature and quote as fragments). Blocks **U9a**. What it must show: MAIL-UX 6.3.9. |

**Live probes and what each gates** (all on the test account, each with its own yes):

| Probe | Gates | Settles |
|---|---|---|
| Read probe, items 3, 5, 6, 10 | P12b | Which fields each format returns; stale-history errors; a missing id's error body; the `Date` header |
| Read probe, item 5 (two listings, history age) | P13a | How often a listing skips; how long history is kept |
| W1 | P15a | Replay; own changes in history; the batch with a bad id; a duplicate label |
| Read probe, item 11; write probe W7 | P20b, P23c; P05, P06a | The form of Gmail's `Authentication-Results`; how Gmail reads a malformed `From` — the rules hold either way |
| Read probe, item 12 | P12a | Whether an empty `labelIds` is omitted |
| Read probe, item 14 | P13a, P12a | **The sync limit**: dated listings; whether a thread's id is its first message's; how much mail a month |
| Read probe, item 15 | P23e | Gmail's search against the local one, for the merged search |
| W2 | P17; **the first scheduled send on a real account** (P18b is built without it) | Whether a draft keeps unknown headers, and through an edit elsewhere |
| W3 | P18; the first scheduled send and the first reminder on a real account | A spent draft's lingering; how soon Sent can be searched; whether `Message-ID` is kept |
| W4 | **Nothing.** It can only relax decision 5 — one owner for a scheduled send — which stands until it has run | Two sends of one draft at once |
| W5 | **The first snooze or reminder on a real account** (P19a and P19b are built without it) | Hidden labels in Gmail's own apps; two snooze labels; a label's counts |
| W6 | P01b | Whether a Google password change touches the calendar's token (D15) |

A package whose probe has not run is built with the fake's switch for that behaviour tested
both ways, and its gate records that the probe is outstanding.

## 3. The gates

Every gate includes: iOS, Mac and `BananaTests` builds; **Thread Sanitizer over the mail
tests**; the contract suite on both sources; a code review; and the **whole-app performance
audit against P0′ on every existing route as well as mail's**.

Thresholds are relative to the baseline: launch marks within 40 ms raw (100 ms for
`*.loaded`), normalised by `app.init.body` when the host's load differs; idle CPU at most
0.5 % absolute; footprint at most + 8 MB on existing routes; no STORM and no HIGH CPU line.
Benchmarks assert at most twice the recorded medians (`--verify-mail-bench`, Release) and log
the rest; no gate asserts an absolute time measured on a Simulator. "Device" items are the
owner's runs (MAIL-ENGINE D18); they block the *next* order. **At every gate the owner's run
includes `ScreensOpenUITest` in Release on the iPad** — it cannot show what it exists for on a
Simulator, and agents may not install on a device.

| Gate | Review | Routes added to the gate | Benchmarks that must exist | Device (deferred) | Blocks the gate |
|---|---|---|---|---|---|
| **A** (order 1) | Schema, connections, invariants 10–12 | `mail-inbox` (iPhone, iPad): `--ui-preview --dummy-health --tab mail --disable-icloud`; `mail-all`: `--mail --mail-place all` (5,200 rows) | `pageRead`, `listRead2000` (ratio to 400 rows ≤ 6), `unreadCounts12`, `conversationRows`, `syncBatch20` with a reader active, `activate`, `firstPage`; P1's `listApply` | Run 1: full fsync ×400, cold open after a reboot, the four-letter search p95, the batch hold | `mail-inbox` root.appear over `shell-plan` + 40 ms; `mail-all` idle over 0.5 % or any STORM; `activate` on the main actor over 1 ms; contract read tests failing on either source; P1 not run |
| **B** (order 2) | Adversarial, of invariants 1–6 and 22–26 against the code | `mail-triage`: `--mail --mail-place all --mail-cursor q3`, after a scripted 30 `E` a second | `intentCommit`, `writeThrough`, the coalescing test (30 changes in 20 ms share at most 2 commits), `walGrowth` (1,000 changes, then a passive checkpoint), publish counts (10 `E` = 10 list deliveries, 0 status changes) | The durable change's p95 on a phone | The seeded random run or the convergence check failing under any switch; the publish recorder seeing a flash-back; list body count rising under a held `J`; any `MailStatus` change per keystroke |
| **C** (order 3) | **Security review** of preparation and the web view contract (MAIL-ENGINE 10.3–10.7), item by item | `mail-open`: `--mail --mail-open forty`; `mail-newsletter`: `--mail --mail-open newsletter`; `--mail-webview` on the hostile fixtures; P3's UI test | `prepare` on the 63 KB, 261 KB and 1.2 MB fixtures and the hostile set (2 MB + 1 refused); `htmlBound` (the pre-parse bound: 500 KB in about 0.5 ms); `bodyRead` with a counting parser at zero | Run 2: both processes' memory with six web views; `mail.webPaint` | `mail-newsletter` over baseline + 100 MB, or not back to + 60 MB in 60 s; any HTML work on the main thread; any request recorded by the fake picture loader with the default setting; the differential test failing; any of the four nesting fixtures (`nested-100k-divs`, `nested-100k-inline`, `nested-30k-bold`, `nested-10k-tables`) failing on a 512 KB stack, or a parser being called for a message over `MailHTMLBound`; the picture loader's redirect, private-address, hop-count and inflated-size tests missing or failing (P21a); the Mac quarantine check failing (`swift test --filter MailMacChecksTests`, through the root `Package.swift` — there is no Mac test bundle and the Mac app is not launched) |
| **D** (order 4) | P18 against MAIL-ENGINE 7.4, line by line | `mail-compose`: `--mail --mail-compose reply --mail-compose-state typed` | `composerOpen`; typing delivers nothing to the list or the reader | — | Kill-at-every-state or two-engine tests failing under either fake behaviour; the ledger showing a second `sendDraft` after an unknown result; W3's results not in hand |
| **E** (order 5) | Search and splits | `mail-search`: `--mail --mail-search "shai"` (four letters) and a two-letter one | `fts2`…`fts6` over forty words, common, rare, two words; `interrupt`; `indexBatch50`; `reindexRate` paced against full | The four-letter p95 (decides D14) | The four-letter search median over twice its recorded median; `rank` in any SQL; the indexer running unpaced on battery; **a row moving when Gmail's results join a search; a row only Gmail found present in any store; more than one Gmail listing for a burst of typing** (MAIL-ENGINE 9.4) |
| **F** (order 6) | The wiring against invariants 10, 13–16, 31, 33; P01b's diff against MAIL-ENGINE 3.3 | `mail-reindex`: `--mail --mail-rebuild-search` (the paced pass as an idle run: `⚡ POWER` average ≤ 25 %, thermal nominal); the Mac `--ui-audit --mac-section mail` snapshot | `pollQuiet` (0 writes, 0 publishes); the suspend test (no request in a simulated hour) | Runs 3–6, in order; run 3 also counts the messages `MailHTMLBound` refused, to set its two numbers | **D17 not answered before order 6 starts; D15 not answered before P01b starts**; `--google-window` on Mac Beta differing before and after P01b; a mail sink inside `#if os(iOS)`; any mail sleeper alive after `.background`; the first Mac fill showing HIGH CPU or thermal ≥ fair; any existing route failing the compare; **`MailSourceProbe` reaching a default of `MailSource+NotYet` on the engine or on the fixture source**, other than the members the test names as after the first release (MAIL-ENGINE 13.3); **a released conversation leaving a tombstone or counting as a removal; a conversation with a claim released; a first sync at six months costing more than twice MAIL-ENGINE 5.4's table on the fake's ledger** |
| **G** (order 7) | P18b against MAIL-ENGINE 7.6 and invariant 8, line by line; the timed rules against 8.2–8.3 | The UX's routes for U8 and U9c | The timed rules' pass over 2,000 snoozed conversations, logged | A message scheduled on his Mac for a time when the Mac is asleep: shown late on the phone, with "send now from here" | Two engines sending one scheduled draft, under either fake behaviour; a wake or a reminder sent from a stale cache; a snoozed, waiting or scheduled conversation released by the sync limit. **W2, W3 or W5 not in hand does not block the gate: it keeps that feature off on real accounts, and the gate says which** |
| **M5** | — | — | — | The first real send, by the author, to himself | Mail is not used for anything that matters before it |

## 4. Checks before a package is handed back

The implementer runs these; they take about fifteen minutes.

1. (From G0.) `tools/perf-gate.sh run --skip-build --only <the package's routes>,shell-plan,day --label
   <package>` after a fresh build, then `tools/perf-gate.sh compare <P0′>.json <package>.json`
   — exit 0, or each line explained.
2. (From P09a on.) The package's benchmarks through `--verify-mail-bench <names>`, Release —
   at most twice the recorded medians; the numbers, with the load line, in the package's note.
3. Sixty seconds on the package's route with `--perf-trace`: every `perf` line reads
   `no bodies` after settling; `RenderStats` for `MailShell` + 0 across the package's
   interaction.
4. For any view package, a review item rather than a run: no view type large enough to need
   the stack — small, type-erased views. (`ScreensOpenUITest` in Release on the iPad is what
   catches a miss; it is the owner's, at each gate.)
5. Thread Sanitizer over the mail tests; each static test from the package that creates it
   on — `MailForbiddenAPITests` from P20a, `MailJournalPrivacyTests` from P23d;
   `grep -n '@AppStorage("[^"]*\.'` over mail's views finds nothing.

An engine package with no route (most of them before P23a) does 2 and 5 as far as they exist
yet, and builds the four apps and the tests. A package is done when the orchestrator has made
its one commit.

## 5. Working in one tree

There is no lock and no compile guard. **A package is built by one implementer, who is the
only one editing the tree while it is built. It lands as one commit, made by the orchestrator
after the package's checks and its code review have passed. A package that has to be developed
alongside another is developed in its own git worktree and merged by the orchestrator.**
(MAIL-ENGINE 18.2 says the same of the engine's packages.) `xcodegen generate` is run by
whoever is building, after any new file.

**The map of shared files.** With one package landing at a time nothing below can collide; the
table is where a collision would be if two were ever developed side by side, and it is the
order of the edits. Each file is edited only by the packages listed, in this order:

| File | Packages, in order |
|---|---|
| `project.yml` | **C0a** (the two packages; a `dependencies:` key for `BananaTests`; `BananaTests.sources`: `Banana/Model/Mail` and `Banana/Model/MailUI/Pure`) → **P24** (`MAIL_FIXTURES` for Beta's Release) → **P25** (two background task identifiers, in `Banana` and `BananaBeta`). No other package, of either half. |
| The root `Package.swift` | P21a only (the `MailMacChecks` targets, for the Mac-only checks) |
| `Banana/BananaApp.swift` | P09a (one `runIfRequested` line) → U1a → U5 (the Mac app delegate's adaptor) → P26 (one route flag) → P27 (two `register` lines) → P01b (`.onOpenURL` by scheme) → P24 (`wireUp`, the environment value) → P25 (`register()` in `init`) |
| `Banana/Views/RootView.swift` | U1a → P26 (the web view route) → P24 (resume, suspend) → P25 (schedule on backgrounding) |
| `Banana/Views/MacRootView.swift` | U1a → U5 → P24 (resume on becoming active) |
| `Banana/MacAppDelegate.swift` — the Mac app has no app delegate today | **U5 creates it** (`#if os(macOS)`; an `NSApplicationDelegate` attached with `@NSApplicationDelegateAdaptor`). P24 extends it for quit and sleep in its own file, `Banana/Model/MailApp/MacAppDelegate+Mail.swift`, and does not edit U5's. |
| `Banana/Views/MacDebugSnapshotViews.swift` | U2 → U1a → U4a → U5 → U6 → P26 → U9a → U10 (one case each) |
| `Banana/Model/ShellNavigation.swift` | U1a only (`ShellState.mail`, `librarySection`) |
| `Banana/Model/AppSettings.swift` | P24 → U14 |
| `Banana/Views/SettingsView.swift`, `MacCommandCenter.swift` | U14; U5 |
| `Banana/Model/PerfWatchdog.swift` | The order-0 fix (F11, F12) → P24 |
| `Banana/Model/GoogleCalendarService.swift`, `GoogleTokenMinter.swift` | **P01b only** |
| `Banana/Model/ControlsCloudRecords.swift`, `BananaTests/ControlsSyncTests.swift` | P27 only |
| `Banana/Model/CalendarWriteBack.swift` (`isDiagnosticLaunch`) | P09a only |
| `Banana/Model/Mail/MailContract.swift`, `MailSource+NotYet.swift` | C0a. After that only by a change both authors agree, landing alone, with the contract suite extended in the same commit — and `BananaTests/MailSourceProbe.swift` given the new member's call and name, which `MailSourceTreeTests` enforces by counting the protocol's requirements. |
| `Banana/Model/Mail/MailEngine.swift` | P23a. It holds no stubs: a member not built yet is answered by `MailSource+NotYet.swift`, and a later slice builds it by declaring it in its own `MailEngine+….swift`. |
| **`Banana/Model/Mail/MailSlices.swift` — the engine's registry** (MAIL-ENGINE 18.2) | P02 creates it (migrations). A line or a section each, in order: C0b (the fixture mailbox's parts) → P06a → P09a (benchmark lines) → P23a (pass consumers) → P15a → P07 → P08b → P19a, and any package that adds fixtures or a benchmark. The one engine file made to be edited by many. |
| **`Banana/Model/MailUI/MailSession+Parts.swift` — the UI's registry** | U0′ creates it. Each later UI package adds its command handlers and its `--mail-state` names there. |
| `Banana/Model/Mail/Testing/MailFixtureMailbox.swift` | C0b. Later packages add conversations in `MailFixtureMailbox+<package>.swift` and one line in the registry. |
| `BananaTests/MailContractTests.swift` | C0b. Later slices add `MailContractTests+….swift`. |
| `tools/perf-routes.d/` | One file per package; never a shared table. |
| `Banana/Model/AppSection.swift`, `Banana/Views/LibraryHome.swift` | U1a → U1b |
| `Shared/BananaDesign.swift`, `docs/design/DESIGN-SYSTEM.md` | U2 only |
| `Banana/Model/ToastCenter.swift` · `Banana/Model/ActionBadges.swift` | U4b only · U1a only |
| `BananaUITests/ScreensOpenUITest.swift` · `AdaptiveShellUITest.swift` | U1a → U14 · U1b only |
| `Banana/Model/MailUI/MailSession.swift`, `Pure/Testing/MailFixtureSource.swift`, `Pure/MailRoute.swift` | U0′, whole: every launch argument of MAIL-UX 13.1 is read from the start. Later packages add `MailSession+<package>.swift` and `MailFixtureSource+<package>.swift`. |
| `Banana/Model/MailUI/Pure/MailCommands.swift`, `MailKeymap.swift` | U5a, whole: every command of MAIL-UX 4.2 is listed from the start. |
| `Banana/Model/MailUI/Pure/MailIdentifiers.swift` | C0a places it (MAIL-UX 10.2). Later packages add `MailIdentifiers+<package>.swift`. |
| `Banana/Views/Mail/MailSection.swift` | U1a → U4a → U6 → U9a → U11 → U4c (one destination each) |
| The UI's slot files — a view one package draws disabled and a later one fills | `MailListScreen.swift`: U4a → U4b → U15b → U4c · `MailMessageCard.swift`: U6 → U7 · `MailReplyField.swift`: U6 → U9a · `MailDeliveryLine.swift`: U6 → U15a · `MailComposerCard.swift`, `MailComposerModel.swift`: U9a → U9b · `MailSwipeActions.swift`: U4b → U8 |

**What could be developed alongside another**, each in its own worktree and merged by the
orchestrator: the pure packages — P03a, P04, P05, P16, P20a, P08a; the UX's U3, U5a, U2's row
display. Nothing that edits a file in the table is developed alongside another that does.

## 6. Outside mail, and listed so it is not lost

- The app's global App Transport Security exception (`NSAllowsArbitraryLoads`) exists for the
  podcast library. Mail does not rely on the platform for `https` (MAIL-ENGINE 5.1), but
  narrowing the exception is worth doing in the podcast code, on its own.
- "Disconnect all accounts" may revoke one account's grant at Google and none of the others'
  (MAIL-ENGINE 3.6, D16); the wording of that button is the calendar's to fix.

## 7. The UI packages

What each builds is MAIL-UX section 14.3, and the screens are MAIL-UX section 6. This is the
row an implementer's brief is cut from. `V/` is `Banana/Views/Mail/`, `U/` is
`Banana/Model/MailUI/`, `UP/` is `Banana/Model/MailUI/Pure/` (compiled into the tests by C0a's
one line), `T/` is `BananaTests/`, `UT/` is `BananaUITests/`.

**For every UI package** (MAIL-UX 14.2): it is built on the contract and accepted on the real
engine over the fake, with the contract suite passing on both sources (from P23a on; before
that, on the in-memory source alone); it lands as one commit; it creates only the
files listed and touches only the existing files listed; its routes go in
`tools/perf-routes.d/<package>.routes`; its accessibility line is part of "done", with one
route pictured at an accessibility text size; it runs the checks of section 4; and its
checking puts no window on the owner's Mac — iPhone and iPad in the Simulator, Mac pictures
from the offscreen harness (MAIL-UX 13.4). What needs the owner is said in the row.

**Since the owner's review** (MAIL-UX section 1 has his words), three things hold for every
package below, whatever its row still says:

- **Narrow from the first package.** A package builds its screen at every width of MAIL-UX
  6.0.2 — in the reading pane, over the list, and compact — and is not done until its compact
  form is pictured on an iPhone Simulator. Where that form waits on prototype P4, it builds
  the fallback of MAIL-UX 6.1.3. No package exists to add a phone form later.
- **Mail is columns.** Pictures are taken at `--mail-width 1400`, `1100`, `800` and `640` on
  the Mac's offscreen harness, and on an iPhone and an iPad Simulator, so every arrangement
  is seen.
- **The slice comes first.** A thin slice of the list, the reading pane and the details
  column is being built on sample mail, for the owner to try and to make the picture for
  decision 23. It is not one of these packages. **When it lands, U1a, U2 and U4a are re-cut
  around what it already has** — their rows below are the specification they are cut from,
  not a promise of their boundaries.

### Order 0 — prototypes

P1, P2, P3, P4 and P6 are in section 2. Each is built in its own git worktree, in
`V/Prototype/`, on the fixture mailbox with mail's network off, and is never merged; its
numbers go in `mail-working/perf/results/` and its verdict in one paragraph at the top of the
MAIL-UX section that names it (6.1.8, 4.1, 6.2.5, 6.1.3, 6.3.9). **Needs the owner:** the Mac
halves of P1 and P2 (a visible window); P1, P3 and P4 on his iPhone (deferred; each blocks
the next order, not the current one); and his choice from P4's pictures.

### Order 1 — to the first inbox (gate A)

**U0′ — The fixture source and the session.** Directly after C0b (and so after P03a and
P05). No screen.
- *Creates:* `UP/Testing/MailFixtureSource.swift` (`#if DEBUG || MAIL_FIXTURES`; `MailSource`
  in memory, from `MailFixtureMailbox` through the engine's own pure rules — the one UI file
  allowed to name them, MAIL-ENGINE invariant 32). **It implements the list reads only**
  (`accounts`, `observeAccounts`, `observePlaces`, `cachedFirstPage`, `observeList`, `status`,
  `badges`); every other member is answered by `MailSource+NotYet.swift` until a later
  package declares it in `MailFixtureSource+<package>.swift`.
  `UP/Testing/MailFixtureSource+Rows.swift` — its summary-to-row mapping: it builds the
  stored summary from the pure rules and hands it to the engine's `MailRowMapper` (P05), so
  the two sources share one mapping. `U/MailSession.swift`,
  **`U/MailSession+Parts.swift`** (the UI's registry: each later UI package adds its command
  handlers and its `--mail-state` names there), `UP/MailNavigation.swift`, `UP/MailShellState.swift`,
  `UP/MailRoute.swift` (every launch argument of MAIL-UX 13.1, read from the start; one whose
  screen is not built is read and unused), `UP/MailReadingRules.swift` (what the session
  must tell the triage model, MAIL-UX 3.11, as a pure rule the session runs),
  `T/MailFixtureSourceContractTests.swift`, `T/MailNavigationTests.swift`,
  `T/MailRouteTests.swift`, `T/MailReadingRulesTests.swift`.
- *The session's two inputs to the triage model* (MAIL-UX 3.11): it observes the list in
  front and no other; it marks as the answer to an entry the first value of the observation
  that entry starts, and never a cached page; and it sends *check finished* once a check he
  asked for has answered. A cold launch enters the place before it reopens a conversation.
- *Touches:* nothing.
- *Routes:* none of its own.
- *Tests:* the contract suite's read tests on the in-memory source — **the first time the
  suite runs** (C0b wrote it and had nothing to run it on); every row of MAIL-UX
  13.1's table reads to the value it describes; `MailShellState` round-trips and decodes from
  data that lacks it; a restored conversation that is gone is dropped; exactly one reading
  is marked per entry, and a cached page never is; *check finished* is sent at once when a
  check found nothing, after the next reading or a second when it found mail, and never on
  an input alone (MAIL-UX cases 53, 54).
- *Performance (gate A):* contract read tests pass on the in-memory source here, and on both
  sources from P23a; a launch on any route but
  Mail's creates no `MailSession` (by structure: it is made on first use).
- *Engine slice:* C0a, C0b, P03a (wire models), P05 (conversation rules, the built-in splits,
  the row mapper).

**U2 — Tokens, primitives and the row.** After C0a. Beside U0′, U3, U5a.
- *Creates:* `UP/MailRowDisplay.swift`, `V/MailRowView.swift` (both row types, the skeleton
  row), `V/MailRowMark.swift`, `V/MailRowGallery.swift`, `T/MailRowDisplayTests.swift`,
  `T/DateTextTests.swift`.
- *Touches:* `Shared/BananaDesign.swift` (`Feature.mail`, `DS.Mail`, `DateText`, `DSChip`,
  `Monogram`, `KeyHintRow`); `docs/design/DESIGN-SYSTEM.md` (the amendments of MAIL-UX 5.1);
  `MacDebugSnapshotViews.swift` (`mail-rows`).
- *Routes:* `--mail --mail-rows` (on iPhone and iPad once U1a has landed); on the Mac,
  offscreen, `--snapshot-view mail-rows`, the one-line row at 32 and at 36 pt.
- *Tests:* one per row of the reason-line table (MAIL-UX 6.1.1); `DateText` per branch at the
  fixture clock in `en_US`, `en_GB`, `de_DE`; truncation order; the VoiceOver label in MAIL-UX
  10.2's order; equal `MailRow`s make equal displays (an `asking` reason carries the
  question's kind, so the row alone decides its line).
- *Performance (gate A):* the rows `mail-all` draws — no STORM, idle within 0.5 %; a row
  given an equal value is not re-evaluated (a probe test under `--perf-trace`).
- *Engine slice:* C0a.
- *Accessibility:* the row's label and value; Large Content on chips; the gallery at AX3.
- *Makes the picture for* decision 4.

**U3 — The triage model.** After C0a. Pure. Beside U0′, U2, U5a.
- *Creates:* `UP/MailListModel.swift`, `UP/MailUndoStack.swift`, `UP/MailActions.swift` (the
  table of MAIL-UX T14), `UP/MailToastText.swift` (MAIL-UX 7.9), `T/MailListModelTests.swift`,
  `T/MailUndoStackTests.swift`, `T/MailTriageCasesTests.swift`, `T/MailToastTextTests.swift`.
- *Touches:* nothing. *Routes:* none.
- *Tests:* one per rule T0–T45 the model decides, named for the rule; the forty worked cases
  of MAIL-UX 3.10, one test each; a seeded run of 2,000 inputs never leaves the cursor on a
  row that is not shown, nor the selection holding a row outside the scope.
- *Performance (gates A, B):* taking a 400-row snapshot within 1 ms and a 2,000-row one
  within 4 ms, Release — its share of `listApply`; a cursor move copies no row array.
- *Engine slice:* C0a (`MailRowRules`, the contract's values; a row that `leaves` is kept,
  dimmed, with the row it carries, until the place is next entered — MAIL-UX T17; one that is
  `unknown` is drawn as the row it carries until the next reading).

**U3b — The triage model's rules for the reading pane.** After U3. Pure.
- *Touches:* U3's `UP/MailListModel.swift`, `UP/MailUndoStack.swift` and their tests (the
  same implementer, the same files).
- *Builds:* the last table of MAIL-UX 3.12, exactly: *showing* as a state beside *open* —
  the session says which conversation the pane has on screen, and since when; the reader's
  facts accepted for a showing conversation as for an open one; "showing" in place of
  "open" in T8(a), T13 and T45; the undo entry of T25 records the showing conversation, its
  reading position and whether it was open. Nothing else in the model changes.
- *Tests:* cases 55–69 of MAIL-UX 3.12, one test each; every existing test still passes
  with no pane.
- *Performance:* as U3; a cursor move still copies no row array.
- *Engine slice:* none.

**U5a — The keymap, as data.** After C0a. Pure. Beside U3; before any screen.
- *Creates:* `UP/AppKeymap.swift` (`resolve(_:scope:pendingPrefix:)`), `UP/MailKeymap.swift`,
  `UP/MailCommands.swift` (every command of MAIL-UX 4.2, from the start),
  `T/MailKeymapTests.swift`, `T/MailCommandsTests.swift`.
- *Touches:* nothing. *Routes:* none.
- *Tests:* every row of MAIL-UX 4.2.1–4.2.6 resolves to its command in its scope; K3, K5,
  K6, K7, K8, K9 and K11 as tables; no stroke means two things in one scope; every key is a
  command with that key, and the reverse; every collision of 4.3 resolves as ruled.
- *Performance:* none of its own; it is a table.
- *Engine slice:* none.

**U1a — The seat, and the columns.** After U0′.
- *The columns* (MAIL-UX 6.0): `UP/MailColumns.swift` — `showing(width:options:)`, pure —
  `V/MailColumnsView.swift` (the four columns with placeholders, the stand-ins, the three
  options and their buttons), `UP/MailPrefs.swift` (`mailShowsControl`, `mailShowsPane`,
  `mailShowsDetails`), `T/MailColumnsTests.swift` (a test for each row of 6.0.2's table and
  for each option off; a width crossing a threshold changes the columns once, and a width
  that does not, never). It adds 6.0.3's rule to `docs/design/ADAPTIVE-LAYOUT.md`. Routes:
  `--mail-width`, `--mail-pane`, `--mail-control`, `--mail-details`.
- *Creates:* `V/MailSection.swift` (`RenderStats.note("MailShell")`; the arrangement; a
  plain placeholder until U4a), `Banana/Views/LibraryHome.swift` (Library's root: today's
  view, or under `--mail-seat` the Podcasts | Notes switch with Record and Write),
  `U/MailSession+Shell.swift`, `UT/MailSeatUITest.swift`.
- *Touches:* `AppSection.swift` (`.mail`; the Mac's order; `phoneTabs`, which is `iOSTabs`
  unless `--mail-seat` is given in DEBUG), `ShellNavigation.swift`
  (`ShellState.mail`, `librarySection`), `BananaApp.swift` (`--mail` in
  `VisualAuditRoute.flags`), `RootView.swift` (the route; the sidebar row; `--mail-seat`;
  Library's root; no toast host on Mail's tab), `MacRootView.swift` (`case .mail`, measured,
  with a minimum width; `.prefix(9)`), `ActionBadges.swift` (Mail's two numbers, read with
  `MailBadgeCounts.mirrored(in:)` — the key and the stored form are the contract's, so this
  is built before the engine that writes them), `ScreensOpenUITest.swift` (Mail in the walk), `MacDebugSnapshotViews.swift`
  (`--mac-section mail`).
- *Routes:* `--mail`; `--ui-preview --dummy-health --tab mail --disable-icloud` (on a phone
  this implies `--mail-seat` until U1b). Gate file: `mail-inbox`.
- *Tests:* the Mac's order and ⌘1–⌘9; a tenth section does not trap; old `ShellState` data
  decodes; fifty cursor changes write `ShellState` zero times; with `--mail-seat` the phone's
  bar is Plan · Mail · Workouts · Nutrition · Library and Library shows Record and Write in
  both parts; without it the phone is unchanged and `AdaptiveShellUITest` passes untouched; a
  route launch makes no request.
- *Performance (gate A):* `mail-inbox` root.appear within `shell-plan` + 40 ms; every
  existing route's launch marks within threshold; `MailShell` + 0 while another section is in
  front. (`ScreensOpenUITest` in Release on the iPad is the owner's run at the gate.)
- *Engine slice:* P23a for the route's default source, and to write the badge mirror this
  package reads; until it lands the route runs on the in-memory source and the mirror is
  absent, which reads as no badge.
- *Accessibility:* the sidebar row's label and badge value; Library's switch and buttons.
- *Makes the picture for* decision 1.

**U10a — The control column.** After U1a, P23a.
- *Creates:* `V/MailControlColumn.swift` (one view: the column, and Places in a popover and
  a sheet), `U/MailPlacesModel.swift`, `UP/MailPlacesDisplay.swift` (groups, order, counts
  with "+", what is folded), `UP/Testing/MailFixtureSource+U10a.swift`,
  `T/MailPlacesDisplayTests.swift`, `UT/MailControlColumnUITest.swift`.
- *Touches:* `V/MailColumnsView.swift` (its slot); `MacDebugSnapshotViews.swift`
  (`mail-places`).
- *Routes:* `--mail-places`, `--mail-control off`, `--mail-place label:Invoices`.
- *Tests:* every place of MAIL-UX 6.6 in Gmail's order; choosing one shows it; a count for
  each split, mailbox and label, with "+" where the contract says at least; accounts with
  their state word; the same view as a column, a popover and a sheet; `G` `L` puts the
  caret in its filter field.
- *Performance (gate A):* the column observes places only — forty cursor moves and ten
  Dones leave its probe + 0 except where a count changed; it is on screen in Mail's first
  frame, from memory.
- *Engine slice:* P23a (`observePlaces`, with `labelCounts` from C0c).
- *Accessibility:* the container "Mailboxes"; each row's count as its value.

**U4a — The list, read-only, with its cursor.** After U1a, U2, U3, P1, P23a, P09a.
- *With the columns:* the list is built beside a pane (a column 320 to 440 wide, three lines
  to a row), at full width (one line to a row from 720 pt) and compact with the fallback of
  MAIL-UX 6.1.3; its header in each (6.1.2). A click places the cursor; it opens only where
  there is no pane (T49). The foot of a list that ends at the sync limit, with "Get older
  from Gmail" (6.1.7). Pictured at all four widths and on an iPhone.
- *Creates:* `V/MailListHost.swift`, `V/MailListHost+iOS.swift`, `V/MailListHost+Mac.swift`,
  `V/MailListScreen.swift` (regular; compact without its slot; stubs for the slots of later
  packages), `V/MailListHeader.swift`, `V/MailStatusLine.swift`, `UP/MailStatusText.swift`
  (all of MAIL-UX 7.2: `MailStatusText.line(_ status:, accounts:, now:)` — an account's
  health is on `MailAccount`, not in the status value), `V/MailEmptyState.swift`,
  `U/MailListController.swift`, `UP/Testing/MailFixtureSource+U4a.swift`,
  `T/MailStatusTextTests.swift`, **`T/MailSourcesAgreeTests.swift`** (every scope's rows are
  equal on the two sources; the fixture's VIP split joins at gate E), `UT/MailListUITest.swift`,
  `UT/MailListRestoreUITest.swift`, `UP/MailListWindow.swift` (MAIL-UX 6.1.7: P1 ran with the
  window and it stays; the model cuts none) and `T/MailListWindowTests.swift`.
- *From prototype P1* (MAIL-UX 6.1.8): the iOS host is the native collection view hosting
  SwiftUI rows, as measured. A position is a row's key and whole points (T46), never an
  offset or an id alone; each window change is applied in the same turn as the model's
  publish, with nothing deferred between them; nothing in a hosted row reads its own geometry
  to decide anything about scrolling; the first restore waits for the first layout pass that
  has a size. The Mac's `NSTableView` host is built to the same rules and accepted only
  after its own run of P1's scenarios, which needs the owner's Mac.
- *Touches:* `V/MailSection.swift`; `MacDebugSnapshotViews.swift` (`mail-list`).
- *Routes:* `--mail-place`, `--mail-filter`, `--mail-account`, `--mail-cursor`; `--mail-state
  checking|checked|checked-nothing|stale|empty-split|inbox-clear`. Gate file: `mail-all`.
- *Tests:* the window never holds more than 400 rows, slides by 200 and is found by key; a
  row the model asks to show or restore outside the window is brought into it; a position
  whose row has left restores to the first row at or after its key; rows a growth brings are
  on screen when they arrive, not three seconds later; a
  tree rebuilt at row 137 comes back within a point; three rows arriving at depth 50 move
  nothing on screen; the first picture after launch has rows (`cachedFirstPage`); each empty
  state; every row of the status table; the same pictures on both sources.
- *Performance (gate A):* `listApply` within 4 ms at 400 rows and 16 ms at 2,000; `mail-all`
  idle within 0.5 % and no STORM; forty cursor moves leave the list's probe + 0.
- *Engine slice:* P23a (lists, places, status, the first page), P09a (the 5,200 rows).
- *Accessibility:* `mail.list.row.<key>`; split tabs as a tab list; pictured at AX3.

### Order 2 — triage (gate B)

**U4b — Actions, swipes, selection, the toast, undo.** After U4a, P23b.
- *With the columns:* selecting is built at every width here, compact included (long-press,
  the check circles, the selection's actions in a bottom toolbar until U4c); where a pane
  shows, the selection's summary and actions are drawn in it (T54), in
  `V/MailSelectionSummary.swift`. An action on a row that is not on the device says why and
  does nothing (MAIL-UX 6.4.3).
- *Creates:* `U/MailTriage.swift` (runs the model's effects), `V/MailSwipeActions.swift`,
  `V/MailRowQuickActions.swift`, `V/MailRowMenu.swift`, `V/MailSelectionHeader.swift`,
  `V/MailNewChip.swift`, `U/MailIdleTimer.swift`, `UP/Testing/MailFixtureSource+U4b.swift`,
  `T/MailTriageEffectsTests.swift`, `T/ToastCenterPresentTests.swift`,
  `UT/MailTriageUITest.swift`, `UT/MailSwipeUITest.swift`.
- *Touches:* `ToastCenter.swift` (`present`); the slot file `V/MailListScreen.swift`.
- *Routes:* `--mail-select`, `--mail-toast`, `--mail-state new-chip|sending-changes`.
- *Tests:* each action of T16 on screen, on both sources; Undo puts back the row, the cursor
  and the offset to the point; a full swipe leaves in one motion and the list still scrolls
  from a drag begun on a row; arrivals wait for idle and never land mid-swipe; a refused
  change shows Gmail's state with Retry (T36); each toast of MAIL-UX 7.9.
- *Performance (gate B):* ten actions are ten list deliveries and no status change; no
  flash-back on screen; `MailShell` + 0 across them; closing up takes 180 ms and is never
  awaited.
- *Engine slice:* P23b.
- *Accessibility:* the row's actions (MAIL-UX 10.2), the announcement, focus to the successor.

**U5 — Keys on the Mac.** After U4b, U5a, P2.
- *With the columns:* focus between the list and the pane as MAIL-UX T50 has it — the five
  keys that mean two things, `Space` scrolling the pane, list-only keys closing an open
  conversation first; the View menu's ⌥⌘S, ⌥⌘P and ⌥⌘I. Tests: cases 60, 61, 66 and 68 by
  script.
- *Creates:* `U/MailKeyDispatch.swift` (the one function every stroke goes through),
  `UP/MailTypeAhead.swift` (K12), `U/MailKeyScript.swift` (`--mail-keys`),
  `UP/CalendarKeymap.swift` (today's table, moved), `V/MailShortcutGroups.swift`,
  `T/MailTypeAheadTests.swift`, `T/CalendarKeymapTests.swift`, `UT/MailKeysUITest.swift`,
  `UT/MailCursorRenderUITest.swift`, `UT/MailRapidDoneUITest.swift`.
- *Touches:* `MacCommandCenter.swift` (the monitor asks `AppKeymap`; Mail's rows in ⌘K; the
  footer drawn with `KeyHintRow`; the shortcut sheet's Mail groups); `MacRootView.swift`
  (File › New and Refresh follow the section; the two menu chords); `BananaApp.swift` (the
  `@NSApplicationDelegateAdaptor` line — the Mac app has no app delegate today, and this
  package creates it: `Banana/MacAppDelegate.swift`, `#if os(macOS)`, listed here because it
  is the first to need one; P24 extends it in a file of its own);
  `MacDebugSnapshotViews.swift` (`mail-menu`, `mail-shortcuts`).
- *Routes:* `--mail-keys`, `--mail-menu`, `--mail-state prefix`. Gate file: `mail-triage`
  (`--mail --mail-place all --mail-cursor q3 --mail-keys "E*30@33"`).
- *Tests:* the calendar's table, written from today's `switch` before it moves, passes
  before and after; by script — `R` then "Each" at 5 ms types "Each" and marks nothing Done,
  `/` then "invoice" opens no picker, a held `J` moves on every repeat and a held `E` acts
  once, `Esc` in K9's order.
- *Performance (gate B):* the list's probe + 0 under forty `J` at 8 ms; `mail.key` to the
  mark within a frame at the 95th percentile; no `MailStatus` change per stroke.
- *Engine slice:* P23b.
- *Needs the owner:* P2's Mac half, and one look at real keys in a window before gate B.
- *Accessibility:* every key's command is in ⌘K by name; tooltips carry the key.

### Order 3 — reading (gate C)

**U6 — The conversation.** After U4b, P3, P23c.
- *With the columns:* the conversation is one view in three places — in the reading pane,
  over the list, and pushed at compact width with its action bar (a bottom toolbar until
  U4c) and More. `U/MailPaneFollower.swift` and `UP/MailPaneRules.swift`: the pane shows the
  target (T47), follows the cursor at once after a single press and 150 ms after the last
  repeat of a held key (T48), opens by focus (T49), and marks read after 400 ms open or two
  seconds showing (T51); a conversation overtaken by a newer cursor is dropped before any
  view work. Tests: `T/MailPaneRulesTests.swift`; cases 55–59 and 62–65, 67, 69 on screen; a
  held `J` leaves `mail.reader.renderCount` flat. Performance (gate C), added: the pane shows
  a prepared conversation the frame after `J`; nothing is read for rows a held key passes.
- *Creates:* `U/MailConversationModel.swift`, `V/MailConversationScreen.swift`,
  `V/MailConversationHeader.swift`, `V/MailMessageCard.swift`, `V/MailTextView.swift` (+iOS,
  +Mac; TextKit), `UP/MailTextRendering.swift`, `UP/MailFolding.swift`, `UP/MailFind.swift`,
  `UP/MailHeightTable.swift`, `U/MailRenderHeights.swift` (through `SnapshotLoader`),
  `V/MailFindBar.swift`, `V/MailOlderNewer.swift`, `U/MailSession+Show.swift`
  (**`MailSession.show(_ id: MailConversationID)`** — opens a conversation from anywhere; the
  engine's P25 calls it when a notification is tapped), stubs `V/MailReplyField.swift` and
  `V/MailDeliveryLine.swift`, `UP/Testing/MailFixtureSource+U6.swift`, `T/MailFoldingTests.swift`,
  `T/MailTextRenderingTests.swift`, `T/MailFindTests.swift`, `T/MailHeightTableTests.swift`,
  `UT/MailConversationUITest.swift`, `UT/MailReaderScrollUITest.swift`.
- *Touches:* `V/MailSection.swift`; `MacDebugSnapshotViews.swift` (`mail-conversation`).
- *Routes:* `--mail-open <key>`, `--mail-find`. Gate file: `mail-open`.
- *Tests:* folding on `forty`; read is marked after 400 ms of showing, not before (T10);
  T45 on `unseen-reply`; quotes on `plain-chain`; part of a message selected and copied; find
  steps and highlights; text size; `rtl`; `headers-only`; the reader scrolls from a drag
  begun on any card; no card moves after first paint; a designed body shows its text and
  "Open in Gmail" until U7.
- *Performance (gate C):* `mail.open` within 50 ms at the 95th percentile on `forty` and
  `plain-chain`; `bodyRead` with the counting parser at zero; the list's probe + 0 while a
  conversation is open and scrolled; the forbidden-API test clean over `V/` and `U/`.
- *Engine slice:* P23c.
- *Accessibility:* message containers and labels; the folded state; the header as a heading;
  older and newer as buttons; pictured at AX3.

**U7 — Designed bodies and attachments. One package with the engine's P26.** After U6,
P20b, P21a.
- *Since the owner's review:* pictures at four levels (MAIL-UX 6.2.6) — the line's menu from
  `MailPictures.offers`, the one question for "everyone", "Pictures shown: always from …
  · Stop" from `shownBy`, nothing in Spam but per message. Tests: each level on
  `newsletter`; the sender and domain levels greyed for an unverified sender; nothing
  fetched for a row a held key passes.
- *Creates* (P26 creates `MailWebView`, its configuration, the scheme handler and
  `--mail-webview`): `V/MailWebBodyCard.swift` (paper, recorded height),
  `UP/MailWebBodyPolicy.swift` (which messages hold a web view, under the cap),
  `U/MailWebViewPool.swift`, `V/MailPicturesLine.swift`, `V/MailLinkSheet.swift`,
  `U/MailLinkOpener.swift` (the one place a link is opened, after the engine's rule),
  `V/MailAttachmentChips.swift`, `V/MailAttachmentPreview.swift` (Quick Look),
  `V/MailProgramSheet.swift`, `T/MailWebBodyPolicyTests.swift`, `UT/MailWebBodyUITest.swift`,
  `UT/MailAttachmentUITest.swift`.
- *Touches:* the slot file `V/MailMessageCard.swift`. (`BananaApp.swift`, `RootView.swift` and
  the snapshot case are P26's.)
- *Routes:* `--mail-open newsletter|three-newsletters|big-image|attachments|attachments-many|program|lookalike|reply-to`.
  Gate file: `mail-newsletter`.
- *Tests:* at the default setting the fake picture loader records nothing on open, on
  warm-up or on a second open; "Show pictures" fetches for that message only; "Always from"
  is offered only for an authenticated sender; the seventh designed body opened releases the
  first, which shows paper at its recorded height; a link whose text names another host
  shows the sheet; an attachment chip in each state; a program asks, and is never opened.
- *Performance (gate C):* `mail-newsletter` within the baseline + 100 MB with six designed
  bodies, and within + 60 MB sixty seconds after leaving; `mail.webPaint` within 150 ms on a
  second open; no request at the default; nothing laid out in a view body.
- *Engine slice:* P26, P20b, P21a.
- *Accessibility:* the pictures line and chips focusable and labelled; a designed body read
  from its text.
- *Makes the picture for* decision 3.

**U20 — The details column.** After U6, U7.
- *Creates:* `V/MailDetailsColumn.swift` (one view: the column, the panel over the pane and
  the sheet), `V/MailDetailsCards.swift` (People, About, Attachments), `UP/MailDetailsDisplay.swift`
  (the people of a conversation in order, what is known of each, the facts, the attachments
  newest first), `T/MailDetailsDisplayTests.swift`, `UT/MailDetailsUITest.swift`.
- *Touches:* `V/MailColumnsView.swift` (its slot); `MacDebugSnapshotViews.swift`
  (`mail-details`).
- *Routes:* `--mail-details on|off|panel` with `--mail-open` or `--mail-cursor`.
- *Tests:* the people of `forty` and `q3` in order, with the address always shown and what
  is known of each; `lookalike` shows "First mail from this address"; the attachments of
  `attachments-many`; a selection shows only its count; the same view as a column, a panel
  and a sheet.
- *Performance (gate C):* it reads through the pane's conversation model and makes no read
  of its own; a held `J` leaves `mail.details.renderCount` flat; typing in a composer does
  not re-evaluate it.
- *Engine slice:* P23c (nothing new: folds over the conversation's messages).
- *Accessibility:* the container "Details"; each card a group with a heading.
- *Later seams:* the invitation and its day, the trip, a contact's card, a summary — each
  one more card (MAIL-UX 6.10).

### Order 4 — writing and sending (gate D)

**U9a — The composer: the card, the phone's sheet and sending.** After U6, P6, P23d.
- *Since the owner's review:* the compact sheet is built here, not in U9b
  (`V/MailComposerSheet.swift`, `UT/MailComposerSheetUITest.swift`: the detents as P6 found
  them; the text survives the tree being discarded). A reply is written where the
  conversation is showing; a new message is written in the pane with the list beside it,
  and over the list where there is no pane.
- *Creates:* `U/MailComposerModel.swift`, `V/MailComposerCard.swift`,
  `V/MailRecipientField.swift`, `V/MailRecipientChip.swift`, `V/MailComposerBody.swift` (the
  system's editor), `UP/MailComposerText.swift` (attributed text to `MailText` and back),
  `V/MailDraftBlocks.swift` (signature, quote), `UP/MailSendCheck.swift`,
  `U/MailSendFlow.swift`, `UP/Testing/MailFixtureSource+U9a.swift`,
  `T/MailComposerTextTests.swift`, `T/MailSendCheckTests.swift`, `UT/MailComposerUITest.swift`,
  `UT/MailUndoSendUITest.swift`.
- *Touches:* `V/MailSection.swift`; the slot file `V/MailReplyField.swift`;
  `MacDebugSnapshotViews.swift` (`mail-composer`).
- *Routes:* `--mail-compose`, `--mail-compose-state empty|typed|autocomplete|bad-address|reply-to`,
  `--mail-toast sending|too-late`. Gate file: `mail-compose`.
- *Tests:* recipients come from `newDraft` and are never worked out here; the "Replying to"
  line on `reply-to`; the address on a chip for someone never written to; the five formats
  round-trip; `R` then "Each" types into the body (K12); Send — the composer is gone the
  next frame and the row says "Sending… · Undo"; Undo within the hold reopens the draft with
  its text; "Already sent." after it; leaving ends the hold and sends; a Beta build's chip.
  Send and Done pushes one undo entry, which the composer completes from the screen half
  the triage model hands it (MAIL-UX T38): undone within the hold, the conversation and the
  composer are open again as they were; after it, the Done alone is reversed (T28).
- *Performance (gate D):* `mail.composerOpen` on screen the next frame and filled within
  50 ms; two hundred typed characters leave the list's and the reader's probes + 0; `save`
  is never awaited.
- *Engine slice:* P23d, which now also delivers `people(matching:limit:)` (moved from P23e)
  and the drawable signature and quote of A2 (`MailDraftPart`, `quoteAsText`), so autocomplete
  and both parts are accepted on the engine at gate D.
- *Accessibility:* recipients as removable tokens; Send's label says who it goes to.

**U9b — The composer: attachments and formats.** After U9a. (The phone's sheet moved to U9a.)
- *Creates:* `V/MailComposerAttachments.swift` (the system's pickers, drop, paste),
  `V/MailFormatBar.swift`, `V/MailForeignDraftNotice.swift`,
  `UP/Testing/MailFixtureSource+U9b.swift`, `UT/MailComposerAttachmentsUITest.swift`.
- *Touches:* the slot files `V/MailComposerCard.swift`, `V/MailComposerSheet.swift` and
  `U/MailComposerModel.swift`.
- *Routes:* `--mail-compose-state attachments|over-limit|foreign|program`, in the card and
  in the sheet.
- *Tests:* over the limit is said before Send, with the size; forwarding a program asks; a
  foreign draft is shown as it is, and "Edit as plain text" says what it costs; a removed
  quote or signature is not sent.
- *Performance (gate D):* as U9a; adding a 20 MB file never blocks the main thread.
- *Engine slice:* P23d.
- *Accessibility:* attachment chips labelled with name and size; the format bar's states.

**U15a — Delivery and the Outbox.** After U9a.
- *Creates:* `UP/MailFailureText.swift` (MAIL-UX 7.6), `V/MailSendQuestionCard.swift`,
  `V/MailOutboxSections.swift`, `U/MailEventToasts.swift`,
  `UP/Testing/MailFixtureSource+U15a.swift`, `T/MailFailureTextTests.swift`,
  `UT/MailOutboxUITest.swift`.
- *Touches:* the slot file `V/MailDeliveryLine.swift`.
- *Routes:* `--mail-open failed-send`, `--mail-open stale-send` (the `sendLate` card: "Not
  sent yet · waiting since …", with Send now and Keep as a draft — it is in the first
  release), `--mail-place outbox`, `--mail-state sent-after-wait`, `--mail-toast refused`.
- *Tests:* each `MailFailure` gives the words of MAIL-UX 7.6; Edit and Don't send on a
  waiting message; each answer to an unconfirmed send calls `answer` and the card leaves in
  the same turn; the `sendLate` question draws its card and each answer calls `answer`;
  refused changes are listed from `status.value.refused`, one row per action, with Retry and
  Discard (they are not rows of the Outbox place); a send that waited is
  confirmed once.
- *Performance (gate D):* a delivery change re-evaluates its own card and nothing else.
- *Engine slice:* P23d; P23b's `retry` and `discard`.
- *Accessibility:* a failed send is announced; its buttons are named.

### Order 5 — search and places (gate E)

**U11 — Search.** After U4b, P23e.
- *Since the owner's review:* one list from the device and from Gmail (MAIL-UX 6.4.3, 7.3):
  Gmail's rows join below with no heading; the `icloud` glyph on a row that is not on the
  device; the foot while Gmail is asked, offline, failed, and "More from Gmail"
  (`askGmail`); stopping on a Gmail-only row fetches it. The field is in the list column's
  header, and in the slot at compact width. "Recent with" in the details column
  (`V/MailDetailsRecent.swift`). Tests add: Gmail's rows never move a row already showing;
  each `--mail-search-state`; an action on a row that is not here yet.
- *Creates:* `U/MailSearchModel.swift`, `V/MailSearchScreen.swift`, `V/MailSearchField.swift`,
  `V/MailSearchSuggestions.swift`, `UP/MailSearchScopeText.swift` (MAIL-UX 7.3),
  `UP/MailRecentSearches.swift` (kept in memory for the session; never in `UserDefaults`), `UP/Testing/MailFixtureSource+U11.swift`,
  `T/MailSearchScopeTextTests.swift`, `T/MailRecentSearchesTests.swift`,
  `UT/MailSearchUITest.swift`.
- *Touches:* `V/MailSection.swift`.
- *Routes:* `--mail-search`, `--mail-search-state`. Gate file: `mail-search`.
- *Tests:* a stale answer never shows after a newer one; operators become chips from the
  source's tokens, and no file here splits a query; the scope line in each state; "Search
  Gmail" calls `searchGmail(_:)` once, labels its group, and tries again when pressed again; `Esc` returns to the results with the cursor where
  it was; a query is never written to `ShellState`.
- *Performance (gate E):* the device's rows on screen within 30 ms of a keystroke (the
  engine's four-letter median within twice its recorded median is the gate's line); typing
  re-evaluates the search screen only; no debounce on the device's results.
- *Engine slice:* P23e.
- *Accessibility:* suggestions as a list with their kind spoken; the scope line read on change.

**U10b — The label and move pickers.** After U4b. Beside U11. (Places became the control
column, U10a, in order 1.)
- *Creates:* `V/MailPickerPanel.swift`, `U/MailLabelPicker.swift`,
  `U/MailMovePicker.swift`, `UP/MailPickerFilter.swift`, `UP/Testing/MailFixtureSource+U10.swift`,
  `T/MailPickerFilterTests.swift`, `UT/MailPickerUITest.swift`.
- *Touches:* `MacDebugSnapshotViews.swift` (`mail-picker`).
- *Routes:* `--mail-picker label|move`, `--mail-picker-text`.
- *Tests:* `L`, "inv", Enter labels the target as one receipt and one undo; `V` moves and
  the row leaves; nested names; what is typed in a picker never runs as keys.
- *Performance (gate E):* a picker is on screen the next frame, from memory (a counting
  source sees no read at open).
- *Engine slice:* P23a, P23b; P27 for a custom split.
- *Accessibility:* the highlighted row announced with its key.

### Order 6 — a real mailbox (gate F)

**U14 — Turning Mail on, and Settings.** After P24, P01b.
- *Since the owner's review:* "Keep mail from" (`MailSyncLimit`; six months; this device
  only), with the one question when keeping less, worded from `conversationsBeyond(_:)`;
  remote pictures as "Ask first · Always, from everyone", the list of allowed senders and
  domains from `pictureRules()` with removal, and "Block tracking pixels" (MAIL-UX 6.8.1).
  Tests add: each limit's footnote; keeping less asks and keeping more does not; a rule
  removed is gone from the list and from the message that showed by it.
- *Creates:* `V/MailTurnOnScreen.swift`, `V/MailSettingsScreen.swift`, `V/MailAccountLine.swift`,
  `UP/MailAccountStateText.swift` (MAIL-UX 7.5), `UP/MailStorageText.swift`,
  `UP/Testing/MailFixtureSource+U14.swift`, `T/MailAccountStateTextTests.swift`,
  `UT/MailTurnOnUITest.swift`, `UT/MailSettingsUITest.swift`.
- *Touches:* `SettingsView.swift` (the Mail row, the account card's Mail line, the
  Permissions row); `AppSettings.swift` (the screens' own optional fields, after P24's);
  `ScreensOpenUITest.swift` (Settings › Mail).
- *Routes:* `--mail-settings`, `--mail-accounts`, `--mail-turn-on`, `--mail-state
  needs-access|first-open|admin|wrong-account|api-disabled|mail-off`.
- *Tests:* only the default account is ticked; Google's warning is shown before its sheet;
  each permission result gives its row of MAIL-UX 6.9; the second-device words read
  correctly with a credential kept per device and with one that is synced; turning Mail off
  says nothing is withdrawn at Google; a Mac shows the sentence about its store and an
  iPhone does not; no route launch asks for permission.
- *Performance (gate F):* Settings › Mail opens with no store read on the main thread;
  existing Settings routes unchanged. (`ScreensOpenUITest` in Release on the iPad, with
  Settings › Mail in the walk, is the owner's run at the gate.)
- *Engine slice:* P24, P01b, P33.
- *Accessibility:* each account's state as a value; footnotes read with their rows.

**U15b — States.** After U4a, U14; with P13b.
- *Since the owner's review:* the first-sync words in terms of the limit (`limitEdge`), and
  the route `--mail-state at-limit` (MAIL-UX 7.1, 6.1.7).
- *Creates:* `V/MailFootCard.swift`, `UP/MailDownloadText.swift` (MAIL-UX 7.1),
  `V/MailAlertCard.swift`, `UP/MailQuestionText.swift` (MAIL-UX 7.5), `V/MailStoreStateView.swift`,
  `UP/Testing/MailFixtureSource+U15b.swift`, `T/MailDownloadTextTests.swift`,
  `T/MailQuestionTextTests.swift`, `UT/MailStatesUITest.swift`.
- *Touches:* the slot file `V/MailListScreen.swift`.
- *Routes:* every remaining value of `--mail-state` (MAIL-UX 13.3).
- *Tests:* `MailStatesUITest` launches every `--mail-state` and compares the words on screen
  with MAIL-UX section 7; the foot card's third line per device and per hold; no state draws
  an empty list; each question's buttons call `answer`; each store state has its way out.
- *Performance (gate F):* the foot card redraws at most once in ten seconds; five polls that
  find nothing leave the list's probe + 0; no repeating timer in the tree but the minute's.
- *Engine slice:* P13b, P11, P13a, P33.
- *Accessibility:* a new alert card is announced once; the foot card is one element.

### To finish the first release

**U8 — The time picker and snooze.** Order 7, with P19a; after search. In the first release.
- *Creates:* `UP/MailTimePhrase.swift` (over `EventPhrase.takeDate`), `UP/MailTimePresets.swift`,
  `V/MailTimePicker.swift`, `U/MailSnooze.swift`, `UP/Testing/MailFixtureSource+U8.swift`,
  `Banana/Model/Mail/Testing/MailFixtureMailbox+U8.swift`, `T/MailTimePhraseTests.swift`,
  `T/MailTimePresetsTests.swift`, `UT/MailSnoozeUITest.swift`.
- *Touches:* the slot file `V/MailSwipeActions.swift` (the leading swipe becomes Snooze).
- *Routes:* `--mail-picker snooze`, `--mail-place snoozed`, `--mail-cursor snooze-back`.
- *Tests:* every row of MAIL-UX 6.5.2's table at the fixture clock, in three locales; the
  presets on each weekday; a past time is refused in words; `H`, "fri 3pm", Enter snoozes;
  it returns unread and first; Undo.
- *Performance (gate B's lines again, with `H` in the script):* the picker on screen the
  next frame; a keystroke is shown before it is read as a time.
- *Engine slice:* P19a.
- *Accessibility:* each preset read with its time.

**U9c — Send later, and Remind me if no reply.** Order 7, after U8 and U9a; with P18b and
P19b. In the first release, by the owner's ruling.
- *Creates:* `V/MailSendLaterControl.swift` (the clock button, the read-back line, the
  Schedule button), `V/MailScheduledCard.swift` (the card's lines and its ×),
  `UP/MailLateText.swift` (every line of MAIL-UX 6.5.5 and 7.7, by device), `U/MailSchedule.swift`,
  `UP/Testing/MailFixtureSource+U9c.swift`, `Banana/Model/Mail/Testing/MailFixtureMailbox+U9c.swift`
  (`scheduled`, `scheduled-elsewhere`, `late-asking`, `late-sent`), `T/MailLateTextTests.swift`,
  `UT/MailSendLaterUITest.swift`.
- *Touches:* the slot files `V/MailComposerCard.swift`, `V/MailComposerSheet.swift` and
  `V/MailTimePicker.swift` (its footer for a send).
- *Routes:* `--mail-compose-state schedule`, `--mail-open scheduled|scheduled-elsewhere|late-asking|late-sent`,
  `--mail-picker send-later`.
- *Tests:* ⌘⇧L, "thu 8am", Enter: the button reads Schedule and the line "Sends Thu 8 AM";
  the card says which device will send it; × returns it to a draft; on another device the
  row and the card say "from another device"; five minutes late, every device shows "Was
  due 8 AM · not sent yet"; up to thirty minutes late it goes and says so, later it asks;
  ⌘⇧H adds "back Fri 8 AM if no reply" and the conversation returns unread if nobody
  answered; Undo for each.
- *Performance (gate G):* the picker on screen the next frame; nothing of a schedule runs a
  timer in the view tree.
- *Engine slice:* P18b, P19b. Built and tested on the fake with each probed behaviour both
  ways; used on a real account after probes W2–W4 (and decision 5, with its three pictures).
- *Accessibility:* the read-back line is announced when a time is chosen; a late message's
  state is its row's value.

**U4c — The phone's bottom slot.** After P4 and the owner's choice (decision 2). No engine
package. (Selecting by touch, the conversation's action bar and More are built with their
screens in U4b and U6, on the fallback; this package replaces the fallback with the slot.)
- *Creates:* `V/MailBottomBar.swift`, `V/MailUndoButton.swift`, `UP/Testing/MailFixtureSource+U4c.swift`,
  `UT/MailPhoneBarsUITest.swift`, `UT/MailPhoneUndoUITest.swift`.
- *Touches:* `V/MailSection.swift`; the slot file `V/MailListScreen.swift`.
- *Routes:* every list and conversation route on the iPhone Simulator, with an episode
  loaded; `--mail-menu`; `--mail-state undo-button`.
- *Tests:* the slot stays where it is within a screen; splits and Places from the slot;
  selecting by touch; older and newer; the Undo button for two minutes, and "Undo send"
  during a hold; More lists every action a gesture hides.
- *Performance (the whole gate again on the phone's routes):* the mini-player's clock leaves
  `MailShell` + 0; scrolling under the slot shows no hitch over two frames.
- *Accessibility:* Large Content on every bar item; 44-pt targets.

**U1b — The phone's seat.** After the owner's choice (decision 1). Last.
- *Creates:* nothing.
- *Touches:* `AppSection.swift` (`iOSTabs`, `tabBarHome`; `--mail-seat` removed),
  `Banana/Views/LibraryHome.swift`, `AdaptiveShellUITest.swift`.
- *Tests:* the five tabs; Library remembers its part; a note is started from Library in two
  taps; the badge on Mail's tab.
- *Performance:* every existing phone route's launch marks within threshold.

### After the first release, each on its own decision

| Package | What | Needs |
|---|---|---|
| U13 | The invitation card, Add to plan, the day card in the details column (MAIL-UX 9.1–9.3, 6.10) | P28; `RemindersService.deleteTask`; a calendar create that returns a handle; a `now:` on the day's fixture |
| U12 | ⌘K's ranking, recents, rows made from what is typed | — |
| U5b | Mail's keys on an iPad | P2's iPad half |
| — | The control column inside Banana's own sidebar on the Mac | Only if he chooses B for decision 23: the same `MailControlColumn` view under the Mail row |
| U17 | Free times in a reply | — |
| U16 | The accessibility sweep; the two hints; the old-mail offer | — |

## 8. Decisions for the author

One list, for both halves of mail. It replaces MAIL-UX's own and takes in MAIL-ENGINE section
20, whose numbers are given as "E-D*n*". One recommendation each. ★ means he should be shown
a picture before he is asked; the last column says what makes it. **He reviewed the direction
on 6 Oct 2026**: what he answered is under "Answered", in his words, and the questions his
answers raised are 23 to 25.

**To choose**

| # | Decision | Recommendation | Runner-up | What changes if he chooses otherwise | Picture |
|---|---|---|---|---|---|
| 23 | **Where Mail's control column lives on the Mac** (new; MAIL-UX 6.0.6) | **A column inside Mail, beside Banana's sidebar.** One rule on every device; the app's own navigation stays a fixed set of targets; the shell stays ignorant of Mail; ⌥⌘S hides the column, and Banana's sidebar hides as it does today, which leaves his four. | Banana's sidebar is the control column: Mail's places nested under the Mail row while Mail is in front. Four columns exactly, and about 220 pt more for reading on a laptop. | One package puts the same view under the Mail row of the Mac's sidebar. The column inside Mail is still built: an iPad's sidebar is the system's and cannot hold it. | ★ Both, from the slice |
| 24 | **Tracking pixels** (new; MAIL-UX 6.2.6) | **Never fetched at any level, "always, for everyone" included — as a switch of its own, "Block tracking pixels", that is on.** | No switch: always blocked. | One row fewer in Settings, and no way to see a message exactly as its sender built it. | |
| 1 | Where Mail sits on the iPhone | **Mail takes Notes's seat; Notes moves into Library beside Podcasts, with Record and Write one tap away in both parts.** Notes is also where a note is started, so starting one must cost no more than it does now: two taps before, two after. Reading a note back goes from one tap to two. | Mail inside Plan, behind an envelope button. | Every visit to Mail is two taps and its count shows only from Plan. U1b is one line either way. | ★ The new bar, and Library with its switch — U1a's `--mail-seat` |
| 2 | The phone's bottom layout | **One strip: Places, the splits, Search, Compose, and Undo while there is something to undo; older and newer as buttons in a conversation.** | Splits across the top and a floating Compose button. | Splits and Places leave the thumb's reach. Until he has chosen, every screen ships its fallback; U4c builds whichever he picks. | ★ P4's pictures, with an episode loaded |
| 4 | The Mac's row height **when the pane is off** — beside a pane the list has three lines to a row and this does not arise | **32 pt.** | 36 pt. | About one row in nine fewer on screen. One token. | ★ The row gallery at both — U2 |
| 5 | A late scheduled message (E-D8). Send later is in the first release by his ruling (order 7): **U9c is built on this recommendation, which probe W4 may later relax; he should see the three pictures before real mail is scheduled.** | **Only the device it was scheduled on sends it. Every device shows a late one as late and notifies. Up to 30 minutes late it goes and says so; later it asks. No setting.** Decided again after probes W4 and P5: if Gmail never sends one draft twice, any device may take a late one over. | Whichever device is awake sends it. | Without the probe's answer, two devices can send it twice. | ★ Three: the picker naming the device; the lock screen at 8:05; the late card |
| 6 | Where the Gmail credential lives (E-D15) — *needed before P01b (order 6), not before order 1* | **On each device, apart from the calendar's.** Mail asks Google once per account on each device; the grant to read and send is not copied into iCloud Keychain. | One synced credential. | One consent covers every device; the grant is on every device signed in to his Apple ID; a Google password change signs the calendar out everywhere. The screens read correctly either way (MAIL-UX 6.9). | |
| 7 | The mail store on the Mac (E-D17) — *needed before order 6, which puts real mail on a Mac* | **Accept that software he runs can read it, and say so in Settings.** | Encrypt bodies and attachments under a keychain key. | About a package of work; subjects, senders and the search index stay readable. | |
| 9 | New-mail notifications | **For the first split only; the row says a phone that is not open is often tens of minutes late.** | Off, keeping Gmail's app for alerts. | — | |
| 10 | The Mac wakes the phone for new mail (E-D13) | **Yes, once Mail is in daily use.** Needs the Push capability on the App ID. | No. | A closed phone hears of mail only when the system lets Banana run. | |
| 11 | Mail's place in the Mac's sidebar | **Second, ⌘2.** Seven sections' shortcuts move down one. | Last. | ⌘9, and no shortcut moves. | |
| 12 | Swipes | **Left: Done, with Trash behind it. Right: Snooze (Unread until snooze is built).** Superhuman's. Ask only whether he has changed Superhuman's. | Apple Mail's. | — | |
| 13 | Snippets | **Not in the first release.** Ask how often he uses them. | After U9b. | A package after the composer. | |
| 14 | What "Disconnect" says and does (E-D16) | **Say that it withdraws nothing at Google, with a button to that page.** | A button that revokes. | It ends Banana's access to that account on every device, the calendar's included. | |
| 15 | When a draft reaches Gmail (E-D21) | **When the composer closes, when the app goes to the background, and before sending.** | As he types. | Unfinished text reaches Google, his other devices and a Workspace archive within seconds. | |
| 17 | Seeding one device from another (E-D12) | **Decide after the phone's first real fill.** | — | Its own design and security review. | |
| 25 | **The details column's first cards** (new; MAIL-UX 6.10) — to confirm once he has used the slice, not to decide now | **People, About, Attachments; "Recent with" when search exists. Nothing fetched, nothing looked up elsewhere, no model.** | The day's schedule as a card from the start. | One more card, and the day's fixture has to take a fixed date. | The slice shows the first three |

**Answered** — in his words, 6 Oct 2026

| # | Decision | He said | So |
|---|---|---|---|
| 16 | The first release, and the Mac first (E-D20) | "For now we can focus on Mac but we should be building to support Mobile from the get go." | The Mac-first order stands; every package builds its screen for narrow widths too (MAIL-UX 14.2). Only the phone's bottom slot and seat wait, for P4 and decisions 1 and 2. |
| — | One thing on screen, or columns | "I think a reading pane should be a valid option. I kind of expect a 3 or even 4 column layout? 1. Control Column 2. Mail list 3. reading pane 4 metadata, enrichment, etc." | Four columns by width; the pane and the side columns are options (MAIL-UX 6.0). Decided by the designer where he left it open, and his to overturn: the widths and the order the columns drop in; all three on by default; the pane follows a single press at once and a held key 150 ms after its last repeat; read after 400 ms open or two seconds showing. Decision 23 is the one question it leaves. |
| — | Superhuman's keys and triage model | "Ok." | Stands (MAIL-UX sections 3 and 4). |
| 8 | How much mail a device keeps (E-D3) | "We should allow a sync limit, so lets say 6 months by default. Also we should merge local search with cloud search if duration is not unlimited." | One month, three, six, a year or everything, per device, six months by default; the size ceilings stay only as a backstop (MAIL-ENGINE 5.4, 9.4). Search is one list from the device and from Gmail (MAIL-UX 6.4.3). |
| — | Send later, and Remind me if no reply | "I want these...." | Both in the first release: order 7, U8 then U9c with P19a, P18b, P19b, built on decision 5's recommendation. |
| 3 | Remote pictures (E-D2) | "Default to ask, but allow to set always for this sender, always for this domain, and always period." | Four levels (MAIL-UX 6.2.6). Decision 24 is the one question it leaves. |
| 18 | GRDB 7.11.1, SwiftSoup 2.13.9 and the vendored tracker list (E-D19) | "Sounds good." | Approved. C0a has what it needed from him. |
| — | The whole-app performance commits (order 0's fixes) | "Sounds good." | Approved. They stand as the baseline mail is measured against. |

**His to do** — not choices

| # | What | When |
|---|---|---|
| 19 | The consent screen: External, In production, unverified, for both projects (E-D1). Read the Gmail quota that applies (E-D7). | Order 0, one sitting |
| 20 | Live access, each with its own yes: a test account; the read probe; the write probes; Mail on Mac Beta; the first real send, by him, to himself (E-D11). | Order 0 to M5 |
| 21 | Six runs on his devices (E-D18). | From gate A; each holds up the next order |
| 22 | Time at his Mac, with a window on screen: the Mac halves of P1 and P2; one look at hover, materials and ⌘K; gate F's picture (MAIL-UX 13.4). | Order 0; before gate B; gate F |
| 26 | Try the slice — the list, the reading pane and the details column on sample mail — and say what is wrong with it. | When it lands |

**Settled — listed so that nobody reopens them**

| What | Answer |
|---|---|
| Holding a scheduled message on Google's side, so no device need be on | **Not with Apps Script.** His words, 6 Oct 2026: "No we don't want app scripts. We would build this as a saas feature down the line." Until that service exists a scheduled message waits on the device it was scheduled on (`mail-working/research/send-later-google-side.md` is the investigation). The copy about where a message waits, and who sends it, stays behind one seam so the service can take it over. The same goes for a snooze returning and "remind me if no reply". |
| ⌘N, `/`, ⌘R in Mail; `I` then `Y`, `N`, `M` | New message; search; check mail; only while an unanswered invitation is showing |
| ⌥⌘S, ⌥⌘P, ⌥⌘I | Show or hide the control column, the reading pane, the details column: the Mac's own keys for a sidebar and an inspector |
| Unread mail on the app icon (E-D4) | No, and no switch. A question waiting for him and a send that failed do count. |
| Done marks read | Yes, what was shown (MAIL-UX T45, T51). No setting. |
| The undo hold (E-D9) | Ten seconds. Leaving sends; quitting the Mac app waits up to twenty. |
| A returning snooze (E-D10) | Unread, and first. |
| A change Gmail refuses | Shown as Gmail has it, at once, with Retry; it also waits in Outbox. |
| When arriving mail joins the list | After three seconds idle; never mid-swipe. |
| Mail per account (E-D6) | Off until turned on; the first screen ticks only the default account. |
| The sync limit is each device's own | Yes (MAIL-ENGINE 5.4): a phone and a Mac have different disks, and a synced value would empty or fill a device he is not looking at. |
| What the limit keeps | Recent mail, what he has looked at, and what he has a claim on — starred, drafts, snoozed, unsent. Being in the inbox is not a claim (MAIL-ENGINE 5.4). |
| Mail-only accounts (E-D5) · the search index's prefixes (E-D14) | Not now · from the phone's number in run 1 |
| An iPad by touch | Actions in the header, no bottom bar. Looked at again after a week on an iPad. |
