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

Failing on the shipping branch without the cache (Debug), and what became of each
(`tests/green-unit`): the component cost budgets were measured in a Debug build, and now go
through `CostBudget`: enforced in the Release `BananaModelTests` run that preflight makes
(`unit-optimized`), reported as "not measured in an unoptimized build" in Debug. Three of them
still fail optimized, on a quiet host holding the build lock, three runs each: Mail action commit
for 1,000 messages in one conversation 121.7–167.0 ms (every sample), HTML preparation of 261 KB
100.3–114.2 ms, account-scoped page and counts over 180,000 conversations 100.6–110.2 ms, all
against 100 ms. Index reconcile passes optimized. `MailHistoryIndexTests` opened its on-disk index
on the main thread, which a Debug build stops at (invariant 10). The stale expectations were
brought to what the app now does, or the app fixed where it had broken its own rule; the commit
message lists which.

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
| unit tests, optimized (BananaModelTests, Release, uncached) | — | see below |

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

## Release builds are not cached

Unsigned Release archive of `BananaMac`, fresh derived data each time, project mapping:

| Archive | Time | Main binary |
|---|---|---|
| no cache, 1 | 292.1 s | A |
| cache, empty | 293.1 s | C |
| cache, warm | 18.4 s | C |
| no cache, 2 | 291.4 s | B |

The two uncached archives already differ (1,876 bytes outside the signature), so this build is not
reproducible and identical output with and without the cache cannot be shown. Release,
TestFlight and archive builds therefore stay uncached (`BANANA_CACHE_CONFIGS` is
`Debug PiDevelopment`). The warm figure is what enabling it would buy once reproducibility is
established.
