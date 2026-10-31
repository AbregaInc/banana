# The performance gate (`tools/perf-gate.sh`)

The whole-app Simulator gate: cold-launch marks, idle CPU, memory and storm lines for every section
of the app, taken the same way every time so two runs can be compared. The method, the first
reference run and its caveats are in `docs/design/mail-working/perf/baseline.md`; the findings it
produced are in `findings.md` beside it. **Simulator numbers compare runs on this Mac with each
other; they are not device numbers** (`device-protocol.md` is the device procedure).

## The reference every later gate compares against

**`docs/design/mail-working/perf/results/20261006-004009-p0prime-run1.json`** — P0′, the pre-mail
code at `3542829`, built and measured from a clean checkout (its noise pair is
`20261006-013201-p0prime-run2.json`). Earlier: `20261005-165711-baseline-run1.json` (P0, build 51
at `1155270`, before the whole-app fixes); P0′ was A/B-tested against it, see the end of this file.

## Running it

```sh
tools/perf-gate.sh run --label <milestone-or-package>          # builds, measures both simulators
tools/perf-gate.sh run --label u4 --skip-build --only mail-all,shell-plan,day   # a package check
tools/perf-gate.sh compare docs/design/mail-working/perf/results/20261006-004009-p0prime-run1.json .build/perf-results/<stamp>-u4.json
tools/perf-gate.sh routes                                       # the merged route table
```

- **Before a run:** `uptime; pgrep -x xcodebuild | wc -l`. The script records both per route. If the
  1-min load is above ~12, wait; numbers taken under load are normalised by `compare`, but a quiet
  machine is cheaper than explaining a shifted run. One `xcodebuild` at a time — the script waits if
  another is running.
- **Options:** `--src DIR` (the source tree to build; default this repo), `--dd DIR` (derived data;
  default `<src>/.build/mail-perf-dd`), `--out DIR` (results; default `.build/perf-results/`),
  `--routes-dir` (default `tools/perf-routes.d`), `--iphone/--ipad UDID` (defaults: "Mail iPhone"
  `E5232BE0-8F82-4E85-A03B-5CA7160571E2`, "Mail iPad" `7CE990BF-066D-4E79-BA7F-B5F285E6A66C` — other
  simulators belong to other sessions), `--runs 5 --warmup 1 --settle 15 --idle 65 --launch-wait 6`
  (the reference's settings; keep them for comparable numbers), `--sequential`, `--with-tests`.
- **Routes** live in `tools/perf-routes.d/*.routes`, one file per package: `app.routes` holds the 34
  whole-app route instances (19 lines); a package adds its own file (e.g. `mail.routes`) and never
  edits another's. A route is `name|iphone,ipad|<VisualAuditRoute flags>`; the gate appends
  `--disable-icloud -onboardingCompleted YES`. A flag that is not in `VisualAuditRoute.flags`
  (`BananaApp.swift`) starts the production graph — do not add one.
- **Build:** Release (`-O`, whole-module) with the `DEBUG` condition added so the audit routes exist;
  not byte-identical to a shipping Release, same optimiser. `ONLY_ACTIVE_ARCH=YES`. Never judge a
  build by `-quiet`; the script greps `BUILD SUCCEEDED`.
- **A full run** takes ~45 min after the build (both simulators in parallel). A package check with
  `--only` takes ~2.5 min per route.
- **Safety:** audit routes skip `wireUp()` (no CloudKit, Google sync, write-back or notifications);
  the simulators are booted headless with `simctl` — nothing opens on the Mac desktop; no device is
  touched.

## Reading `compare`

```
device  route     metric              base     new    delta   noise  verdict
iphone  day       launch.root.appear  1251.0  1340.0  +89.0   40.0   REGRESSION
```

- A line appears only when `|new − base| > max(floor, k·max(spread_base, spread_new))`: `REGRESSION`
  or `improved`. Floors: 40 ms for launch marks (100 ms for the async `*.loaded` marks), 0.5 % idle
  CPU, 8 MB footprint; any `🌀 STORM`/`🔥 HIGH CPU` line in the new run is `FAIL`. Exit code 1 on any
  regression.
- **`(normalised)`** on a launch line means the host load differed between the runs (the earliest
  mark, `app.init.body`, moved more than the floor) and the mark was compared as a ratio to that
  anchor, rescaled to the base run. Under contention every mark shifts together (measured: a load
  swing 8→412 moved all marks +80–120 ms; the ratios held within ±0.05), so the ratio is the honest
  comparison. A `(normalised)` regression is real; a raw regression on a run whose load line is high
  should be re-run.
- Idle metrics flagged: `cpu_pct_ps` (process CPU over the 65 s window, measured externally with
  `ps`), `power_mem_mb` (phys footprint from the app's own `⚡ POWER` line). Printed but never
  flagged: the `⚡` avg/max (they include the launch burst) and Simulator RSS (noisy).
- **A one-off must reproduce.** The two reference runs each produced one unexplained ~1 % idle
  blip on an iPad route (different routes), not reproduced on the re-run. Re-run the route
  (`--only`); two in a row is a finding, one is noise.

## The noise floor (two runs of the same binary, 34 routes)

| Metric | Run-to-run `|Δ median|` | Within-run spread (5 launches) |
|---|---|---|
| `root.appear` and earlier marks | 25–40 ms at equal load; normalised when load differs | 15–35 ms |
| `fitness.loaded` / `library.loaded` | ~70 ms (async completions) | ~35 ms |
| idle CPU (`ps`) | 0.00 % (every route 0.00–0.05 %) | — |
| footprint (`⚡ mem=`) | 0 MB (a different screen state can move it 20 MB) | — |
| wakeups per 72 s | ~8 | — |

The P0′ table in `docs/design/mail-working/perf/baseline.md` (and the figures the P0′ run adds
below) are the current numbers; the floors above were set from them.

## What it cannot measure

- Anything behind `wireUp()`: the 60 s `CloudSyncPoll`, the Google change poll, write-back, the
  foreground cascade on return from background, notifications — the audit routes never start them.
  Those are device-protocol items (A2–A5).
- Background behaviour (timers alive while a podcast plays, CPU-limit kills): device only.
- Release-only stack overflows (the 1 MB iOS main-thread stack): `ScreensOpenUITest` in Release on
  hardware.
- Real data volumes: the routes run on fixtures; a real catalogue, history or mailbox is a device
  run.
- The Mac app: not launched by this gate (its data root is the owner's live one).
- The iPad simulator shows the location prompt on every route (its TCC grant does not stick); it
  costs no measurable idle CPU but is a window in the process.

## Per-package check (an implementer runs this before handing a package back)

```sh
uptime; pgrep -x xcodebuild | wc -l                          # quiet machine, no other build
tools/perf-gate.sh run --label <pkg> --only <pkg routes>,shell-plan,day
tools/perf-gate.sh compare docs/design/mail-working/perf/results/20261006-004009-p0prime-run1.json .build/perf-results/<stamp>-<pkg>.json
```
Exit 0, or every flagged line explained in the package note with the load line beside it.

## P0′ (reference) run — 2026-10-06

- **Files:** `results/20261006-004009-p0prime-run1.json` (the reference) and
  `results/20261006-013201-p0prime-run2.json` (same binary, second pass). Commit `3542829`, clean
  worktree, Release(+DEBUG) build 310 s at 1-min load 8 (P0: 355 s at load 145–200). Executable
  55.98 MB / bundle 189.5 MB (P0: 55.76 / 189.3).
- **Load:** run 1 started at 8.1; its first five routes per device ran at 29–167 (another
  session), the rest at 6–22. Run 2 started at 12.0 and ran at 7–40 with one spike to ~100 on its
  last iPad routes. Other sessions built in the main tree during both runs; the `(normalised)`
  comparisons cover it.
- **Headline (iPhone, medians, ms):** first frame `shell-plan` 997 (P0 1,014), `day` 1,311
  (1,251), `week` 1,355 (1,311), `today` 1,189 (1,091); store inits `app.init.body→history.init`
  ≈ 513→790. Idle CPU 0.00–0.05 % on every route in both runs except the items below; footprint
  33–60 MB; **0 `🌀 STORM`, 0 `🔥 HIGH CPU`** in all 68 idle runs.
- **Noise floor (run 1 vs run 2):** `root.appear` |Δ median| 38.5 ms (max 119 under a load
  swing), within-run spread 39 ms; `*.loaded` |Δ| 41 ms; idle CPU |Δ| 0.0 %; footprint 0 MB;
  wakeups |Δ| 7 per 72 s. Same as P0's.
- **P0′ vs P0, raw:** `compare` flags +40–120 ms on many `root.appear` lines (most on iPad direct
  routes). An interleaved A/B of the two **binaries** on identical containers and host (five routes
  × both devices × 10 launches per arm, `results/ab-p0-vs-p0prime/`) shows the P0′ binary is not
  slower: Δ`root.appear` median −32 ms (worst route +11), Δ(`App.init` body) −2 ms, Δratio −0.020.
  The raw shift is environment — the Simulator containers are now seeded (a 74 KB
  `occurrences-snapshot.json` and a 26 KB weather snapshot decoded at every launch; P0's first
  routes ran on fresh containers) plus whatever changed on this Mac overnight. **Compare future
  runs against P0′, not P0.**
- **What the five fixes changed that the gate can see:** nothing measurable — audit routes never
  run the foreground cascade, the Google poll or the Mac menu-bar timer, and the new render notes
  and watchdog sinks cost nothing visible (idle wakeups: `shell-plan` 47→48, `today` 158→160).
  What it cannot see: a real return from background, background timers, the Mac.
- **Reproduced finding (not a regression — present in P0):** iPad `shell-workouts` idles at
  ~0.9–1.0 % CPU with ~9,000 wakeups per 72 s (3 of 4 runs). The idle `sample` attributes it to
  VectorKit's `md::MapEngine::onRenderTimerFired` display link — the live MapKit `Map` on the
  wide Workouts layout (`WideWorkoutsView.swift:465-479`, findings F4) renders every frame while
  nothing moves. The iPhone's compact Workouts (snapshotter) idles at 0.02 %.
- **One-offs seen once each, not reproduced:** iPhone `workouts` 1.1 % (run 1), iPhone `sleep` 1.2 %
  and iPad `library` 0.9 % (run 2), iPad `settings` 0.5 % (run 1); each with an idle main thread in
  the sample afterwards.
