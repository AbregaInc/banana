> 1 November 2026: superseded setup. The app now carries its runtime and fetches its model; see README.md › "Everything is the app's own" and docs/design/PI-LOCAL-MODEL.md.

# Mac Pi acceptance status

24 October 2026; isolated Pi worktree only.

- Current default: **Qwen3.5 4B · Fast**, thinking off. The previous 27B model is preserved as the explicit `quality` setup profile and is unloaded.
- Installed and visually checked: `~/Applications/Banana Pi.app`. Mac Pi opens Assistant inside the normal app sidebar and runs the configured fast local model. Main/Beta installs and Apple submissions were untouched.
- Actual general-agent acceptance passed: notes/readback, durable operation deduplication, restored history, manual compaction/recall, ordinary reasoning, cancellation and the next input after cancellation. Report: `mac-local-app.json`.
- Actual nutrition acceptance passed twice. The current sorted-serialization report is `mac-local-nutrition.json`: chart/filter/compare/search, contextual copy, native save persistence/deduplication, stale conflict rejection and conversation isolation. Verification stores preserved normal history, meals and preferences; owned workers released on exit.
- Installed UI acceptance passed: visible restored chart, language weekday follow-up, fresh conversation, inference-free sample exploration/day selection and native meal review/cancel. Normal sample dataset remains 249 meals. Report: `mac-local-ui.json`.
- Twenty native tests, twelve public-provider checks and worker-parent-lifetime check passed. Synthetic medium-reasoning action checks passed 24/24; this is limited exploratory evidence, not production accuracy.
- Latency remains uneven. Synthetic warm median was 7.23 seconds; actual cold chart publication was 16.476 seconds; the latest visible language follow-up took tens of seconds. Native day selection measured 61 ms in acceptance. Do not present these as unloaded-host p95 or promise instant inference.
- Fixed cancellation incorrectly disabling the next request, unstable prompt serialization preventing cache reuse, passive Mac chart hover revisions, duplicate interactive/headless activation and blank Mac lazy transcript transitions. Upstream Pi core remains unchanged.
- Main explicitly released its heavy window. Continue prioritizing future bounded main resource requests. No device or simulator operations were needed for this Mac acceptance.
- The normal app currently owns its fast local worker (about 3 GB active model memory) and is ready for testing. Quit Banana Pi to unload it. No cloud/LAN inference or paired-device inference service is enabled.
- Installed symbols are retained in `.build/mac-check/.keep-build`; iPad installed symbols remain in `.build/sim/.keep-build`. Preserve source worktrees, models and evidence.

Reports are under `docs/research/pi-apple-host-results`. Setup and limitations are in this directory's README.

## Faster default acceptance

- Initial 4B real-model general-agent and nutrition flows both passed: `mac-fast-app.json` and `mac-fast-nutrition.json`. After the extension clarified undated meal repeats, the final installed build passed nutrition again (`mac-fast-final-nutrition.json`), including explicit tomorrow copies, save persistence, conflict rejection and restoration. Twenty native tests passed; installed code signature and upstream core diff verified.
- Final installed UI (`mac-fast-ui.json`) restored <redacted>'s existing conversation and saved salmon. His exact name input took 7.163 seconds on the first post-restart request and 0.653 seconds on its warm repetition. His exact salmon input took 1.290 seconds of model time and opened a review draft for today. The test draft was dismissed without saving; all 250 existing meals remain.
- Final inference-only replays with captured view/current extension guidance passed both exact inputs twice (`mac-fast-user-replay-final.json`). Earlier failing replay reports remain as evidence. This is a much smaller model; difficult-task equivalence is not established.
- `setup.py --profile fast` is now the default reproducible configuration. `--profile quality` explicitly restores 27B; quit/reopen Pi when switching. Neither changes main/Beta or Pi core. Both source/model workspaces are retained.
- The old 27B measurements above are historical. Current final nutrition first-chart time was 4.248 seconds. None of the observed warm results is a cold-start or p95 guarantee.

## Broader integration and selection evidence — 25 October

Pi now opens Assistant within the normal platform shell and reuses existing meal/event editors, local data and navigation. See [integration status](INTEGRATION-STATUS.md) for real-model passes and the unresolved UI-runner/manual-control limitations. A final retained full-app workspace run took 99.54 seconds for a meal: functional acceptance is not a blanket speed claim.

The [serial 2B/4B × Locals/stock-MLX comparison](../pi-evaluation/RESULTS-2026-10-25.md) and [future qualification protocol](../pi-evaluation/README.md) are retained. All runs paged. 2B failed more task contracts and is not promoted; no Kev/Von/d1 router is deployed. The incumbent remains 4B/Locals, not a claim that it is the best possible stack.


## Full-app alternate-profile checks — 25 October, later run

The updated isolated Mac Pi app is installed with strict signature verification and arm64-only main/debug binaries. `project.yml` preserves main's SDK-scoped arm64 policy, including the Pi configuration. Normal main/Beta installs and Apple submission state remain untouched.

The saved default remains Qwen3.5-4B/Locals. Final agent, extended workspace and installed nutrition checks pass; 24 native tests pass. Workspace turns were about 2.6s meal / 1.4s event, nutrition first chart 2.2s, native selection 41ms, cancellation 1.0s. These are shared-host samples, not p95; some runs had small paging deltas. Earlier 8–11s turns spent almost all their time inside the serving engine. No default model/sampler/cache change caused the newer timing observations.

A verification-only profile override now allows controlled full-app candidate trials without editing the saved configuration. Ministral3B through Locals/MLX compute passed workspace and missing-time clarification/continuation, but failed saved-note readback by inventing truncation despite `truncated:false`. It is not promoted. Both models recovered from an incomplete event using upstream Pi's existing tool-result loop and native validation. The initial new test's intermediate-error assertion failure is retained and explained.

See [the full-app comparison and failure audit](../pi-evaluation/RESULTS-APP-PROFILES-2026-10-25.md), the raw `mac-profile-*`/`mac-boundaries-*`/`mac-ministral-*` reports, and the README reproduction commands. Normal history/meals, selection/draft and inference configuration remained unchanged. All test-owned workers are unloaded; no physical devices or simulators were used. Installed symbols remain in the existing kept Mac build folder. No new visible UI or mobile acceptance is claimed by these programmatic checks.


## Inline new-draft UX — 26 October

The installed full Mac Pi app now embeds the existing meal/event editor fields in Assistant, removing their separate Review button/sheet transition. [The UX record](../../docs/design/PI-WORKSPACE-UX.md) contains scope, passing UI/native/real-model checks, screenshots and failures. Unsaved manual corrections are still view-local; meal-copy/search navigation remain as before. Mac visual automation was unavailable and its normal-startup routine-file rewrite is retained as a caveat. The 4B default, upstream core and main/Beta installs remain unchanged; all owned inference workers and simulators are released.
