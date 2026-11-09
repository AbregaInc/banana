# Build pipeline: measurements

Measured on the build Mac (M1 Max, 10 cores, 64 GB), Xcode 27.2, 8 Nov 2026, one build at a time
under the build lock. A logger recorded every other xcodebuild on the machine during the runs;
it recorded none. The first attempt at these figures overlapped another agent's TestFlight archive
and was thrown away whole. Package checkouts were pre-resolved and shared for the runs marked
"shared packages", so those figures are compile time, not downloads. Each figure is one run; the
runs are listed, none dropped.

## Every core (`BUILD_JOBS`)

Clean Debug `build-for-testing` of scheme `Banana` for `generic/platform=iOS Simulator`,
`.build/sim` deleted before each clean run, shared packages.

| Build | `-jobs 2` | all 10 cores |
|---|---|---|
| clean | 560.5 s, 598.1 s | 174.5 s, 187.7 s |
| incremental (touch `Banana/Views/PodcastsView.swift`) | 28.5 s, 25.8 s | 27.9 s, 24.7 s |

Clean builds are 3.2 times faster. The incremental build is bound by one module's serial work and
shows no measurable difference.

## Simulator builds compile arm64 only

A generic simulator destination compiles every file twice, for arm64 and x86_64, although every
simulator on this Mac is arm64. With `ARCHS=arm64` the same clean build took 99.8 s and 88.8 s.
`tools/ui-tests.sh` and `tools/preflight.sh` now pass it for simulator builds.

## Shared compilation cache

`COMPILATION_CACHE_ENABLE_CACHING=YES` with one CAS at `~/Library/Caches/banana-xcode-cas`. What
makes it work across worktrees is mapping every path that differs between them: Swift and Clang
prefix mapping for the SDK and toolchain (`*_ENABLE_PREFIX_MAPPING`), for the checkout, its
intermediates and its products (`*_ENABLE_PROJECT_PREFIX_MAPPING`), and for the derived-data folder
(`*_OTHER_PREFIX_MAPPINGS`, where each worktree keeps its package checkouts). With only the SDK
mapped, a second worktree hit the SDK modules and missed every source compile (159.5 s against
171.6 s cold).

Clean Debug simulator builds, arm64, through `banana_xcode` (the scripts' own path; each worktree
resolves its own packages), worktree A then worktree B at the same commit, each with a deleted
`.build/sim`:

| Build | Time | Cache hits / misses |
|---|---|---|
| no cache (reference, above) | 99.8 s, 88.8 s | |
| A, empty cache | 99.6 s | 13 / 966 |
| B, first build, fresh derived data | 39.5 s | 739 / 180 |
| B, again, fresh derived data | 29.1 s | 936 / 0 |

Filling the cache costs nothing measurable. The 180 misses in B's first build are the Swift
packages' own compiles (GRDB, SwiftSoup, GoogleSignIn and their dependencies): they hit in the
same worktree but not across worktrees, for a reason not yet found; the app, its extensions and
its tests hit.

A commit that differs by one file (a string in `PodcastsView.swift`, fresh derived data, shared
packages): 64.3 s with project mapping (99.7 s and 99.4 s with SDK mapping only, both archs). Every
file of the `Banana` module recompiles, because each Swift compile of a module takes all of its
sources as inputs; the other targets and packages come from the cache.

### Proof the cache serves no wrong results

- Stale output: a unique string was put in that view, the app built from the cache, and the
  string looked for in the built app; then changed to a second string, then reverted. Each build
  carried exactly the current string and none of the earlier ones (four edits, both mapping
  variants).
- Tests: the whole `BananaTests` target (Debug, phone simulator) on an uncached build and on the
  cached build made in the second worktree: 4061 passed, 16 failed, 16 skipped in both, the same
  16 failures (they fail on the shipping branch without any cache; listed below).
- The hazard this found: with project mapping, `#filePath` reads `/^src/…`. Without a fix, 26 tests
  failed and 12 more skipped silently because "the source tree is not on this machine". The tests
  now find the checkout through `SourceTree.root` (BananaTests/SourceTree.swift), which the build
  writes into the test bundle's Info.plist; that run is the one above.

Failing on the shipping branch without the cache (Debug): four component cost budgets in Mail
(index, actions, reconcile, HTML preparation) measured in a Debug build, `MailHistoryIndexTests`
crashing, and stale expectations in `AppVariantTests`, `StoreListingTests` (2), `AppSectionTests`
(2), `MailTestingFenceTests`, `MailStoresTests`, `MailBodyRulesTests`, `MailSourceTreeTests` and
`SupplementLabelExtractorTests`.

Size: 1.4–2.9 GB per commit and configuration. `tools/clean-builds.sh` deletes the cache when it
passes 30 GB (`BANANA_CACHE_LIMIT_GB`); Xcode is also given the same limit
(`COMPILATION_CACHE_LIMIT_SIZE`).

## Preflight and the rollout

`tools/preflight.sh` on the shipping branch, Beta channel, all cores:

| Step | Cold (empty derived data) | After a new commit |
|---|---|---|
| iOS Beta Release build | 6m10s | 0m11s |
| Stable iOS archive + check | 5m24s | 5m07s |
| Mac Beta archive + check + export | 5m53s | 5m44s |
| unit tests (BananaTests, Debug, 4,093 tests) | — | 4m46s |

`xcodebuild archive` deletes its intermediates at the start of every archive (every folder under
`ArchiveIntermediates` is re-created and every package recompiles), so an archive is never
incremental, whatever ran before it. The rollout therefore adopts preflight's archive when it is
the same commit, version and build (and, for the Mac, the same feed and update key), instead of
archiving a second time: `tools/testflight.sh … prepare` and `tools/mac-distribution/build.sh
release` check the archive's Info.plist against the plan and archive again on any difference.
Tried with a throwaway build number: after the checks, the Mac release step adopted the archive
in 8 s (342 s for the archive) and TestFlight `prepare` in 28 s with its signed export (309 s for
the archive). That removes one Mac archive (about 6 minutes) from a Beta rollout and three (about
16 minutes) from a Stable one.

## Release builds: reproducibility and the cache

Measured 8 Nov 2026 (evening) on the same Mac, Xcode 27.2. Two builds: an unsigned Release
archive of `BananaMac` (`generic/platform=macOS`, `ARCHS=arm64`, `CODE_SIGNING_ALLOWED=NO`) and an
unsigned Release build of the iOS `Banana` scheme (`generic/platform=iOS`, `CODE_SIGNING_ALLOWED=NO`;
it carries the widget, the Watch app and the Watch widget). Every run went through `banana_xcode`
with fresh derived data in the same folder of its worktree, the source commit and build number
stamped (`BANANA_SOURCE_COMMIT`, `CURRENT_PROJECT_VERSION=95`), and package checkouts resolved once
beforehand. The cached runs used a cache folder of their own, empty at the start.

Compared file by file and byte by byte. Only the code signature is left out: in each Mach-O, the
bytes `LC_CODE_SIGNATURE` points at, that command's offset and size fields, and the `__LINKEDIT`
segment's file and memory sizes are zeroed before comparing; `_CodeSignature/` folders are listed,
not compared. (Once fixed, the signatures matched too.)

### What differed between two uncached builds, and the fix

| Where | Why | Fix |
|---|---|---|
| Main executable, Mac and iOS: `__TEXT,__objc_stubs` (1,853 bytes on the Mac, about 2,200 on iOS), one `__stubs` entry, and with them `LC_UUID` and the dSYM's UUID | When objects already reference `objc_msgSend` through the GOT, the linker gives it a second GOT slot for the fast Objective-C selector stubs, which it builds in parallel; each stub loads from one slot or the other. Relinking the same objects gave different stubs in two of three tries. Only the main app has the second slot (the Google packages' Objective-C) | `OTHER_LDFLAGS: -Xlinker -objc_stubs_small` for every target (`project.yml`). Small stubs branch to the one `objc_msgSend` stub: the second slot is gone, and three relinks were byte-identical. The executable is 49 KB smaller; each selector call takes one more direct branch (its run-time cost is not measured) |
| `NarratorVoiceModel.mlmodelc/coremldata.bin` | `coremlc` writes a model's user-defined metadata map in a different order on every run (four runs, four orders; a C++ hash map, so `SWIFT_DETERMINISTIC_HASHING` does not help) | The four coremltools provenance entries (version, conversion date, source, dialect) move from the model to `docs/publication/voice-model-provenance.json`, which records the converted and the new `model.mlmodel` hashes; weights and manifest are unchanged, and the parsed model is otherwise equal. `tools/check-release.sh` refuses a compiled model with more than one such entry |
| iOS `Metadata.appintents`: `extract.actionsdata`, `root.ssu.yaml`, the `nlu/*.version` file name | The App Intents processors are Swift programs that write Sets in hash order, and Swift seeds hashing at random per process: `resolvableInputTypes` and the entity list came out in a different order each run | `banana_xcode` gives build actions `SWIFT_DETERMINISTIC_HASHING=1`, which the tools Xcode starts inherit; test runs keep random hashing (`tools/tests/test_development_config.py`). Six reruns of the extraction with it were identical; four of four without it differed |

### Proof

Two uncached builds of the same tree (Mac f1 and f2, iOS f1 and f2 below). Hashes are over every
file's path and raw bytes, signatures included:

| | build 1 | build 2 |
|---|---|---|
| Mac archive `Products/` (91 files) | `0dd1eb89fdea3efc…` | `0dd1eb89fdea3efc…` |
| Mac archive `dSYMs/` (3 files) | `a300e7d1bc492074…` | `a300e7d1bc492074…` |
| Mac executable and dSYM `LC_UUID` | `E1054240-C092-389D-9646-CAA7C4BEABD2` | the same |
| iOS `Banana.app` without `nlu/nlu.lzfse` (108 files) | `f6e299a0e5db8aae…` | `f6e299a0e5db8aae…` |
| iOS dSYMs: app, widget, Watch app, Watch widget | `1827133b…`, `301ca21f…`, `8f052362…`, `d132b12d…` | the same |
| iOS executable and dSYM `LC_UUID` | `A44E315C-D327-38A1-84A9-B5820DAC60FE` | the same |

The dSYMs symbolicate: in every build the executable's UUID equals its dSYM's, and `atos` against
the dSYM resolves the same addresses to the same functions and lines.

Still different between two uncached builds:

- **iOS `Metadata.appintents/nlu/nlu.lzfse`.** App Shortcuts flexible matching (the App Intents SSU
  training step) writes the second it ran into its NLU asset: four bytes, then compressed. It
  ignores `SOURCE_DATE_EPOCH`; reruns a few seconds apart differed by those seconds. Only turning
  flexible matching off (`APP_SHORTCUTS_ENABLE_FLEXIBLE_MATCHING=NO`, not tried) would remove it, and
  Siri would then take only the exact App Shortcut phrases. Left as it is. The Mac app has no SSU
  assets.
- **iOS `Assets.car`, now and then.** The order of the two appearance names (Any, Dark) in the
  compiled catalog flipped in 3 of 9 iOS builds (16 bytes), with and without the cache and with
  hashing seeded; `actool` has no option for it. The Mac catalog never changed.
- **The archive's own `Info.plist`**: `CreationDate`, written by `xcodebuild archive`; not part of the
  app or the dSYM.
- Not shipped: the `.swiftsourceinfo` files beside the iOS build products (6–12 bytes each).
- **A different checkout path.** The same commit built uncached in a second worktree differs from
  the first in 19 instructions of the executable, its `LC_UUID`, and the dSYM's paths (see below). So
  "reproducible" here means the same commit in the same place.

### The cache still changes the output

With the compilation cache on, the Mac archive (empty cache, warm cache, second worktree, and the
one-file change) differs from the uncached archive of the same commit in two places, and no setting
fixes either:

- **The executable: 19 instructions and `LC_UUID`.** A closure handed to an Objective-C API as a
  non-escaping block is checked with `swift_isEscapingClosureAtFileLocation`, and the optimised call
  passes the length of the source file's path as the compiler saw it (with an empty string for the
  path). Uncached, that is the checkout's absolute path; cached, the prefix-mapped `/^src/…`, so
  `mov w2, #83` becomes `mov w2, #37`. `-file-prefix-map` and `-debug-prefix-map` don't reach it
  (tried on a one-file program). Every other byte of `__text` matched in all four comparisons.
  Between two cached builds in different worktrees only `LC_UUID` differs: the linker hashes the
  debug map, which names each object file by its absolute path.
- **The dSYM.** A cached build refers to Clang modules by cache id (`llvmcas://…`, 315 of them)
  where the uncached one names `.pcm` files, its paths read `/^src`, `/^sdk` and `/^toolchain`, and
  it gains `CASConfigs.json`, which names this Mac's cache folder. `atos` gives the same functions
  and lines, but the file differs, and its module type information lives in a cache that
  `tools/clean-builds.sh` deletes at 30 GB.

The one-file change (a button title in `PodcastsView.swift`, committed in the second worktree,
built from the warm cache) differed from the uncached build of that commit in exactly the same 19
instructions, `LC_UUID` and dSYM, and nowhere else, while both differ from the unchanged commit's
executable throughout: the cache served the change and nothing stale.

So the condition for caching Release, identical output with and without the cache, does not hold,
and Release, TestFlight and archive builds stay uncached (`BANANA_CACHE_CONFIGS` is still
`Debug PiDevelopment`). What would change that: a compiler that maps the path it passes to the
escaping-closure check, and accepting a dSYM that differs by design. The cached executables are
the same code as the uncached ones; whether that is enough is the owner's call, not a measurement.

### Runs

Each time is xcodebuild's own, from when it held the build lock. Overlap is another agent's
xcodebuild running at the same time (a test run on the simulator, which does not take the lock),
from a sampler that recorded every xcodebuild every 5 s.

Mac archive:

| Run | Source | Cache | Time | Hits / misses | Overlap |
|---|---|---|---|---|---|
| u1 | 3dd09656 (before the fixes) | none | 321.8 s | | test run, first 2 min |
| u2 | 3dd09656 | none | 302.1 s | | |
| c0 | model fix only | empty | 318.9 s | | test run, 40 s |
| f1 | all fixes | none | 295.5 s | | |
| f2 | all fixes | none | 294.0 s | | |
| r0 | 5c05c29d | none | 345.5 s | | test run, 3.5 min |
| ce | 5c05c29d | empty | 296.3 s | 6 / 578 | |
| cw | 5c05c29d | warm | 19.3 s | 528 / 0 | |
| ub | 5c05c29d, second worktree | none | 294.6 s | | 15 s |
| cb | 5c05c29d, second worktree under `/tmp` | warm | 289.5 s | | |
| cb2 | 5c05c29d, second worktree | warm | 92.4 s | 378 / 150 | |
| 1c | one-file change, second worktree | warm | 213.4 s | 549 / 1 | |
| 1u | one-file change, second worktree | none | 340.8 s | | test run, 4.5 min |

Run cb is the experiment's mistake, kept: its worktree sat under `/tmp`, a symbolic link to
`/private/tmp`, and the package sources were not mapped (15 of the 19 path lengths kept the real path),
so nearly every compile missed. Run cb2 repeated it in `.claude/worktrees/`. The 150 misses there
are the Swift packages, which miss across worktrees as in the Debug figures above. The one-file
change recompiles the whole `Banana` module, which is most of a Release build: 213 s against 295.

iOS Release build:

| Run | Source | Cache | Time | Hits / misses | Overlap |
|---|---|---|---|---|---|
| u1 | 3dd09656 (before the fixes) | none | 323.5 s | | |
| u2 | model fix only | none | 311.5 s | | |
| keep | model fix only, another derived-data folder, kept for relinking | none | 357.6 s | | test run, 1.5 min |
| f1 | all fixes | none | 310.3 s | | |
| f2 | all fixes | none | 318.8 s | | |
| r0 | 5c05c29d | none | 311.4 s | | |
| ce | 5c05c29d | empty | 307.5 s | 8 / 968 | |
| cw | 5c05c29d | warm | 18.5 s | 932 / 0 | |
| cb | 5c05c29d, second worktree | warm | 136.9 s | 781 / 151 | test run, 2 min |

The iOS build is a `build`, not an archive, so its executables keep their symbol tables, and those
name the source and object paths: cached against uncached they differ there (about 240 KB of string
table) as well as in 20 escaping-closure instructions and `LC_UUID`; across worktrees, cached, only
in the symbol table and `LC_UUID`. Every other byte of code matched. `nlu.lzfse` differed in every
pair, as it does between any two builds.

What the cache would buy, from these runs: a Mac archive of a commit already built 295 s → 19 s, the
same commit in another worktree 92 s, a commit that changes one Swift file 213 s; the iOS build
311 s → 19 s, 137 s in another worktree.
