# Banana: rules for agents

## Product and design decisions

Cut taglines, helper text and secondary labels. If a screen needs them to make sense, fix the layout.

Make the best decision that will elevate all three: the user experience (UX), developer experience
(DX), and agent experience (AX) always, without breaking anything.

## Every fix is general

Fix the rule that was broken, not the case that was reported (the owner's policy, 8 Nov 2026). No
special cases keyed on a calendar id or address pattern, an account, a name, a device or one
reported example. Name the invariant the bug violated, make the code hold it for every input, and
show the reported case passing as one instance of it. When a general fix has a cost (behaviour
changes for other users or data), say what changes and measure it; don't narrow the fix to dodge it.

## Build output: clean up as you go

Each xcodebuild derived-data folder is 1.5–3.5 GB. One session left 34 GB and filled the disk
(11 Oct 2026).

- One build folder per purpose, reused: `.build/sim` for simulator builds and tests,
  `.build/mac-check` for Mac compile checks (every Mac scheme, one after the other). Never a new
  folder per scheme, per experiment or per comparison.
- A build made to answer one question (a comparison against an older commit, a compile check)
  is deleted in the same step that reads its answer.
- Before a final report, run `tools/clean-builds.sh` (add any scratchpad build folders as
  arguments). It keeps what symbolicates the installed builds and anything in use.
- A worktree's sources stay; its `.build` is build output and goes. The worktree a Beta was
  installed from keeps its build: put a `.keep-build` file in each folder to keep.
- `tools/clean-builds.sh --worktrees` also clears the `.build` of every idle worktree (no program
  working in it, no `.agent-owner`, nothing built for 6 hours) and Xcode's default DerivedData
  folders untouched for 3 days. It keeps the symbol folders and `.keep-build` folders, and caps
  the shared compilation cache (below) at 30 GB.

## Builds: every core, one shared cache, named locks

- Build through the scripts or `banana_xcode` / `banana_xcodebuild` (`tools/config.sh`), never a
  bare `xcodebuild`: they pass `-jobs $BUILD_JOBS` (every core; 8 Nov 2026 a clean Debug build
  took 560–598 s at the old `-jobs 2` and 175–188 s with all ten cores), the compilation cache
  settings, and take the locks. Simulator builds pass `ARCHS=arm64` (89–100 s): a generic
  simulator destination otherwise compiles everything a second time for x86_64.
- Debug and test builds share one compilation cache, `~/Library/Caches/banana-xcode-cas`, keyed
  by source relative to the checkout, so a fresh worktree compiles only what no worktree compiled
  before (a clean simulator build in a second worktree: 39.5 s, against 99.6 s). Release,
  TestFlight and archive builds are not cached. Figures and the proof that cached products are
  correct: `docs/performance/build-pipeline.md`.
- Under that cache `#filePath` reads `/^src/…`. A test that reads the repository's files uses
  `SourceTree.root` (BananaTests/SourceTree.swift), never `#filePath`.
- Locks (`tools/agents/xcode-lock.sh`, installed to `~/.config/banana-agents/` by
  `tools/agents/install.sh`): `build` for any compile (one at a time: a build uses every core),
  `sim-phone` / `sim-pad` for a test run on that simulator, and a guard per derived-data folder so
  two xcodebuilds never write one folder. `banana_xcode` and `tools/ui-tests.sh` take what they
  need themselves; don't wrap them. A bare command that compiles: `tools/agents/xcode-lock.sh
  CMD` (the build lock). `tools/agents/xcode-lock.sh --status` shows who holds what.
- Two agents can now build in one worktree and run UI tests in another at the same time; two
  compiles still queue on `build`.

## Worktrees: a small pool, reused

A new worktree starts with an empty `.build`: 15–25 minutes of cold builds, and 24 worktrees
held tens of GB (8 Nov 2026). Reuse instead of creating:

- The pool is `Banana-work-1` … `Banana-work-4`, beside the other worktrees. Take an
  idle one: it is idle when it has no `.agent-owner` file. When every existing one is taken and
  there are fewer than four, add the next (`git worktree add --detach ../Banana-work-N`). Write yours
  (`echo "$$ <task> $(date)" > .agent-owner`), then `git switch -c <branch> origin/<base>` (or
  `git switch <branch>`). Remove `.agent-owner` when you finish; leave the build in place.
- Commit or stash before you leave a pool worktree; the next agent switches branches in it.
- Create a worktree outside the pool only when all four exist and are taken, and say so in your
  report.
- With the shared cache a pool worktree's build stays warm across branches: switching branches
  recompiles what changed, not everything.
- The release worktree (`Banana-release`, branch `release/banana-ready`) and `Banana-stable` are
  not pool worktrees.

## Instruments captures: each one leaves 1–2.5 GB behind, on both ends

An 8-second Animation Hitches capture of a physical device writes its recording to
`$TMPDIR/instruments*.ktrace` on the Mac (1–2.5 GB) and the same again in the device's private
temp area. 30 captures on 30 Oct 2026 left 38 GB on the Mac and filled a 512 GB iPad twice; the
iPad reported 436 GB "TotalDataAvailable" while installs failed with ENOSPC, because that figure
counts purgeable space.

- `tools/calendar-library-benchmark/profile-device.py` removes its own Mac-side recording after
  xctrace exits and records what it removed in `record-status.json`; `tools/clean-builds.sh`
  sweeps the rest. Don't leave a recorder's temp behind.
- The device-side copy cannot be listed or removed from the Mac. **Restart the device after a
  trace session** (`idevicediagnostics restart -u UDID`, with the owner's word); the reboot
  returned 44 GB on the iPad. Budget about 1.6 GB of device storage per capture.
- Before a device run, read `AmountDataAvailable` from
  `ideviceinfo -u UDID -q com.apple.disk_usage`; `TotalDataAvailable` is not free space.
- The stress fixture removes its previous launches' `tmp/ScaleStress-*` folders at launch
  (`ScaleStressFixtureDirectory`); they were 1.1 GB after one day.

## The tree is public: no names, ids or addresses, and a guard on every push

Everything tracked here is published. The author's, family and device names, the team id, key ids,
device UDIDs, Google client ids and private addresses stay out of sources, docs, tests and retained
evidence. The sample persona is Noor Haddad (`noor@plan.example`); prose says "the owner" and "the
spare phone"; ids are placeholders such as `<device-udid>`, `<key id>` or `$(DEVELOPMENT_TEAM)`.

- `tools/private-text-check.sh --commit HEAD` lists what the deny list
  (`~/.config/banana/public-export.deny`, never printed, quoted or copied into the tree) still
  catches; the public support address sits on the allow list beside it.
- `tools/git-hooks/pre-push` (installed with `git config core.hooksPath tools/git-hooks`) runs that
  check on every commit being pushed and refuses the push on a hit, on a tracked file under
  `private/`, or when the deny list is missing.
- `private/` is ignored: notes that stay off the record (the ASO plan and research) live there, not
  in a second repository.
- After copying device evidence into `docs/`, run
  `tools/redact-evidence.py --deny ~/.config/banana/public-export.deny <folder>`.

## Simulators: reuse, don't create

A simulator is 1–2 GB once it has booted, and a new one per run piles up.

- Before a run, `xcrun simctl list devices available`. Use one that is already there, and erase
  it (`xcrun simctl erase <udid>`) instead of making a fresh one.
- The two this repo's tests use: phone `6DFFC0F9-AA09-41C8-B868-FB0D9CC28255` ("Banana tests
  iPhone") and iPad `43EFC551-5368-4F79-9E52-E3DB87A72F48` (iPad Pro 13-inch). Always name a
  simulator by its UDID.
- Create one only when no simulator of the needed kind exists, and then update the line above.
  Never one per run, per test or per agent.
- A simulator another agent has booted is in use: wait for it or ask, don't take it and don't
  make a second one.
- Keep the test simulator booted between runs; `tools/ui-tests.sh` resets its apps, keychain and
  privacy grants instead of erasing, and shuts it down after 30 idle minutes. Erasing or cloning
  means a first boot: hundreds of iOS services that loaded the Mac past 800 and, when killed at
  shutdown, showed "Family quit unexpectedly" (8 Nov 2026). `FRESH=1` erases when a test needs it.

## UI tests: run what the change touches, in parallel, with time limits

A full UI run was 37 minutes clean and 70 with failures, and was run as the gate for every small
change (11 Oct 2026). The owner waited a day for four fixes.

- `tools/ui-tests.sh [phone|pad] [Class[/test] ...]` is the one way to run them: copies of the
  simulator share the classes (`WORKERS`, 1 by default; more only for a whole suite), every test has a time limit, and what
  failed is printed with its reason. `tools/ui-tests.sh phone timing` runs the tests that
  measure the clock, one at a time; they are not part of the everyday run.
- After a change, run the classes it touches. The whole suite is for before a build goes to
  TestFlight, not for each fix. A fix that is done and checked is installed; it does not wait
  for unrelated tests.
- A test waits for the screen to be ready (`waitForExistence`, `waitUntil { … }` in
  `Ready.swift`), never for a guessed time. A `sleep` is only for a test whose subject is time
  itself (a quiet minute, a minute in the background).
- A failure is read before it is rerun: sample the app (`sample <pid>`) when a query times out.
  "Timed out while evaluating UI query" on Nutrition was the app's main thread waiting on the
  notification daemon, not a slow simulator.
- Check memory first (`top -l 1 -n 0 | grep PhysMem`, `sysctl vm.swapusage`). With swap full
  every test times out and no number of workers helps; say so instead of rerunning.
- Tests that depend on the time of day (a meeting still ahead, late-evening reminders, events
  made near midnight) must say so and skip or adapt; better, give them a fixed clock.

## Releases: preflight, then one script per channel

- `tools/preflight.sh` must pass before any rollout: clean tree, xcodegen, the iOS Beta Release
  build, the Stable iOS archive with `tools/check-release.sh`, the Mac Beta direct archive and
  export, unit tests, and the Service tests when `Service/` changed since the last release tag.
  The rollout reuses its work: the iOS build is incremental and the archives are adopted when
  they are the same commit, version and build (an archive is never incremental).
  Debug builds and simulator tests alone missed Release-only and Mac-only failures (a `RootView`
  helper inside the wrong `#if`, stray files failing the clean-tree check).
- `tools/release/ship-beta.sh N --notes-file F` and `tools/release/ship-stable.sh N …` are the
  rollouts; `tools/release/deploy-service.sh beta|prod` deploys the service (prod needs
  `--yes-prod`). Every one has `--dry-run`. Private values come from `~/.config/banana/`
  (`tools/release/README.md` lists them); never copy a rollout script per build.
- Stable, TestFlight and production deploys run only on the owner's word for that build.

# Workspace preservation

Keep workspaces and git worktrees after completing work. Remove them only when the user explicitly asks.

# Performance requirements

Read `docs/performance/ui-performance-contract.md` and `docs/performance/regression-testing.md`
before changing UI rendering, data access, observation, caching, sync or playback behavior.
Preserve the 8.3 ms frame, direct input p95 <10 ms / max 20 ms, and UI max 100 ms requirements.
The UI goal is 50 ms, preferably about 32 ms. Optimistic actions must preserve durable failures/retries.

For performance-sensitive changes, run the persistent component regression suite and relevant
correctness/UI tests. Keep result paths and report failures or missing device evidence explicitly.
Do not claim Simulator component results prove 120 Hz or input-to-visible UI performance.
Never auto-update a baseline, loosen a budget, drop a scenario or discard failed runs to get a pass.
After verified improvements, propose a reviewed baseline reduction so future changes preserve them.

Performance-test each implementation optimization with a reproducible before/after comparison or
controlled ablation, plus relevant correctness checks. Preserve cold, warm, eviction and memory
tradeoffs; do not describe an unmeasured change or a noisy/no-benefit result as an improvement.

While the user is working on the computer, keep tests in the background: pure component checks
and `simctl` probes without opening/focusing Simulator. Do not open/focus native test windows or
drive desktop input. Defer visible native UI checks to an idle session or dedicated test machine;
hidden/occluded-window timing is not a substitute for visible interaction performance.

# Library-first engineering

Before building a substantial custom component, research established libraries and native
framework capabilities that address the problem. Prefer a suitable maintained implementation
over reinventing it. Check actual platform support (AppKit versus Mac Catalyst), source-level
rendering/reuse behavior, licensing, accessibility, customization, and maintenance. Benchmark
shortlisted candidates against this project's unchanged stress workloads and performance
contract before adoption; a library's performance claims do not constitute acceptance evidence.
Document the concrete gap if custom implementation is still needed.
