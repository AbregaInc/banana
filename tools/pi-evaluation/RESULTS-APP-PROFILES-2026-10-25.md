# Full-app profile qualification — 25 October 2026

The current Qwen4B/Locals default remains in place. Ministral3B can complete the native workspace and clarification flows, but fails the general agent saved-note readback gate. No candidate is promoted. These are actual full Pi/native-app flows, not the earlier one-turn HTTP corpus.

| Configuration | Meal turn ms | Event turn ms | Clarification + continuation | Paging delta (in/out/pageout) |
|---|---:|---:|---|---|
| Qwen4B / Locals | 2581 | 1438 | Both pass; 1 intermediate tool error | 4/0/0 |
| Ministral3B / Locals MLX compute | 3542 | 1073 | Both pass; 1 intermediate tool error | 0/0/0 |

The first shorter 4B control also passed with 2,584ms meal / 1,454ms event and zero paging delta. An earlier loaded-host run took 11,382ms / 8,434ms for the same basic actions. The earlier trace attributes 10,704ms / 7,712ms to the inference server itself; almost all of that slowdown preceded native workspace publication. The new code did not change the default sampler, model weights, Pi loop or cache policy. Do not claim the new instrumentation caused the speed difference, or attribute the entire difference to one proven hardware cause.

## Actual candidate failure

In `mac-ministral-locals-mlx-app.json`, the native reader returned the complete saved note and `truncated:false`. Ministral nevertheless claimed it was a truncated reference, reinterpreted the note marker as another ID and asked for another read. The test failed before the remaining general-agent compaction/cancellation stages; do not count those stages as tested for this candidate. The failure report and raw model turns are retained. Successful schema selection or a fast draft does not establish faithful use of tool results.

Manual review of both workspace traces confirmed two eggs / one banana and the requested event date, time and duration. Ministral was faster for the event and slower for the meal in these samples. Neither the sample size nor shared-host conditions support a universal ranking. No Kev/Von/d1 routing or second model is enabled.

## Existing Pi recovery, tested through the app

The extended workspace case asks for a dinner event tomorrow without a time, checks that no draft exists and that the model asks about time, then supplies 19:00 for 45 minutes. Both profiles first attempted an incomplete event. Native validation rejected it, upstream Pi recorded the tool error and continued generation, the model asked for time, and the next user input produced the correct titled/datetime draft. No external calendar save occurred.

The initial new assertion incorrectly treated every intermediate tool error as a final failure; `mac-boundaries-control-workspace-initial-assertion.*` retains that result. Raw model turns showed successful clarification. The final assertion allows an intermediate tool error only for this specific recovery case and still requires a clarification, no premature draft and a correct follow-up event. Pi core, native validation, scheduler, replay and journal are unchanged. Intermediate tool diagnostics remain in the transcript; this batch does not change their visible rendering.

## Final default-profile gates

The final 4B general-agent report passes notes/readback, deduplication, history restore, compaction/recall, local reasoning without tools, cancellation (1,010ms) and another input after cancellation. Final nutrition was run from the updated installed app and passes chart/filter/comparison/search, copy draft and restoration, data grounding, persisted/deduplicated save and conflict rejection: first chart 2,181ms; native selection 41ms without inference. The extended workspace report above passes the native meal/event/search/navigation and clarification flows.

All these runs confirm normal history/meals, normal selection/draft and saved inference configuration were unchanged; owned workers exited. They use separate verification stores and are programmatic checks, not new visible UI or iPad/iPhone acceptance. The Mac app and debug dylib are arm64 only, matching main policy at `48ede27b`; no main/Beta installs, simulators, physical devices or Apple submissions were touched. Twenty-four scoped native tests pass.

## Reproduce and inspect

See [the profile override commands](../pi-mac-inference/README.md#compare-a-candidate-inside-the-app-without-changing-the-saved-profile). Both compute paths use Locals frontend 0.2.1, the retained environment/source pins and the existing model/serving-view manifests. Ministral uses temperature .1, top-p1, top-k0, thinking off; default Qwen remains .6/.95/20, thinking off. A standalone native MLX HTTP frontend is not used or newly qualified by these runs.

New per-run `.model-turns.jsonl` files capture the synthetic requests/replies with nonce, HTTP transport duration and provider wall/token/cache counters. Companion JSON records paging/swap before/after and normal data/config integrity. HTTP time includes response decoding; full-turn time includes Pi and native publication. Neither is TTFT. The verification prompt does not represent long-history or production p95, and checkpoint verification/prior trials warm disk/Metal caches. Some runs page; preserve that qualification rather than presenting all results as a clean benchmark.

Primary reports in `docs/research/pi-apple-host-results/`: `mac-profile-control-workspace`, `mac-ministral-locals-mlx-workspace`, `mac-ministral-locals-mlx-app` (failed), `mac-boundaries-control-workspace-initial-assertion` (assertion failure), `mac-boundaries-final-{control,ministral}-workspace`, `mac-profile-final-control-app`, `mac-profile-final-installed-nutrition`. Raw evidence and failures are retained rather than rerun away.
