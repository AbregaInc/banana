# Independent efficient-family local checks: 25 October 2026

Follow-up to the [Liquid/Qwen matrix](RESULTS-LOCAL-FOLLOWUP-2026-10-25.md). These use the same actual Banana schemas and 22 fictional development prompts, repeated twice. No app tools execute and no app profile changed. A row is a serving configuration, not a universal ranking of the underlying family.

| Model | Configuration | Contracts | Warm median ms | First request ms | Paging observed? |
|---|---|---:|---:|---:|---|
| Ministral 3B | Native MLX + fixed tokenizer | 40/44 | 310 | 3712 | No |
| Ministral 3B | Locals frontend, MLX compute | 40/44 | 1660 | 10567 | No |
| SmolLM3 3B | Native MLX + XML template mapping | 22/44 | 499 | 3037 | No |
| Gemma 4 E2B | Native MLX, no thinking | 38/44 | 710 | 4068 | Yes |
| Gemma 4 E4B | Native MLX, no thinking | 42/44 | 3965 | 3679 | Yes |
| Gemma 4 E4B | Locals custom, no thinking | 41/44 | 2117 | 9389 | Yes |
| Liquid 8B-A1B | Native MLX, reasoning | 40/44 | 12940 | 8002 | Yes |
| MiniCPM5 2B | Locals custom, no thinking | 39/44 | 3521 | 9555 | Yes |
| MiniCPM5 2B | Native MLX, no thinking | 38/44 | 1591 | 2780 | Yes |
| Qwen 4B | Locals + MLX small-row matmul | 42/44 | 4273 | 1958 | Yes |

## Native setup qualification

The independent checkpoints have exact revision/file manifests under this directory. Model files are outside the repo and preserved. Ministral required the Transformers-recommended `fix_mistral_regex=True` flag; SmolLM3 required its documented `xml_tools` parameter and the existing MLX `json_tools` parser. Original checkpoints/templates/weights remain unchanged. Separate symlink serving views override only public tokenizer metadata, with derived manifests recording both changes and original manifest hashes.

The CPU-only template qualification shows SmolLM3's standard `tools` argument does not render a probe tool, while its documented `xml_tools` argument does. A model/server reporting tool support is not enough: verify that definitions actually appear in the rendered input. The other tested templates render the probe through the standard argument. No custom agent loop, model parser, Pi core modification or upstream inference code patch was introduced.

## Failure audit

- Ministral 3B is fast in the native frontend. Its development misses are an event proposal without a time and an invalid empty date for today's plan. Both encounter existing native validation in the app. The fresh 17-prompt fixture scores 32/34 at about 325ms warm; missing-time proposals remain. This makes it a candidate for full-agent recovery/continuation testing, not an accepted replacement from this one-turn score.
- SmolLM3 remains unreliable for this precise workflow even with the correct tool definitions/parser: it sometimes emits untagged JSON, refuses supported requests or chooses wrong tool/argument forms. Native parsing is kept strict; bare JSON is not silently promoted into an executable tool intent.
- Gemma E2B misses comparison, omits tomorrow from an event proposal and drafts without a decided time. E4B improves some of these outcomes but is slower and has a larger resident-weight requirement; the custom-compute run also includes an incorrect food-amount proposal. Higher effective/total parameter count is not sufficient for selection.
- Liquid 8B-A1B fixes some ambiguity/time behavior seen in its 2.6B sibling, but still fails filter/comparison schema contracts. Native serving slows significantly across the run despite identical token counts on repeated prompts. Do not attribute that drift to longer answers or claim a clean architecture-speed comparison. Its measured native latency is unsuitable for the interactive goal on this loaded M1 Max configuration.
- MiniCPM5 is an independent small distilled model with native XML tool support. Its retained no-thinking configurations still have copy/new-meal/event issues, including wrong-day or argument-form errors. No new default is chosen merely because the checkpoint is small.

## Measurement limits and next gate

Native MLX and Locals differ in prompt preparation, cache/checkpoint handling, constraints and RNG policy, not only parsing. Native repeats reset seed0 per request; Locals uses a server-global seeded RNG. First responses exclude completed app launch and are not disk-cold trials; checkpoint verification warms the file cache. Some Locals runs report first-use kernel tuning. A no-paging run is useful evidence but not a quiet-host/thermal certification or production p95. GPU/RSS counters overlap; missing native GPU counters are not zero. Text-only qualification does not test the vision/audio paths of multimodal checkpoints.

Model-specific sampling settings and all omissions are recorded in each report. Transport errors halt a run after retaining the failure instead of blindly repeating unsupported requests. The helper and benchmark source remain independent of the app scheduler/journal/capabilities. Original source/model workspaces and installed-build symbols are preserved. Main/Beta, devices, simulators and Apple submission state are untouched.

Do not weaken native validation, coerce incorrect quantities/dates, auto-select a router or replace Pi's tool loop to improve a score. A candidate must complete the existing transport/cancellation/continuation and real-app gates. Provider responsiveness probes are retained separately from app acceptance.


## Installed-app checks after the model matrix

The installed full `Banana Pi.app` was checked using `tools/pi-mac-inference/run-app.py`, without rebuilding, swapping its profile or touching main/Beta. It still uses Qwen3.5-4B 4-bit through Locals. These are programmatic real-model/native-store checks, not a new visible UI or physical-device acceptance claim.

- [Agent report](../../docs/research/pi-apple-host-results/mac-selection-baseline-app.json): passed real note creation/read/list, operation deduplication, history restore, compaction/recall, a local calculation without app tools, cancellation (3,152 ms) and the next input after cancellation.
- [Workspace report](../../docs/research/pi-apple-host-results/mac-selection-baseline-workspace.json): passed meal/event creation from words, draft restore, five invalid-input rejections, native meal resolution, persisted/deduplicated meal save, local search and app navigation. No external calendar write was attempted.

- [Nutrition report](../../docs/research/pi-apple-host-results/mac-selection-baseline-nutrition.json): passed chart/filter/comparison, a contextual unsaved meal-copy draft, cold surface restore, actual logged-meal grounding, persisted/deduplicated save, conflicting retry rejection, natural meal search and conversation isolation. The first chart query took 8,678 ms; a native selection took 250 ms without model inference.

All completed reports confirm the normal history/meals and selection/draft were unchanged, the test process exited successfully and its worker was released. The workspace meal turn took 11,382 ms and the event turn 8,434 ms. Those full Pi/native-workspace turns remain slower than the interactive goal; the roughly 0.74-second synthetic response median is not an app-turn latency claim. During this check the shared Mac reported about 62GB used and 21.9GB swap used. Treat timings as loaded-host observations; do not claim a clean improvement over the earlier slow app run.

The next speed investigation should measure prompt preparation, model round trips and native workspace publication separately in the real app, then test a candidate through the complete Pi recovery/continuation loop. A fast single proposal cannot bypass native validation or the cancellation gate. No model or router was promoted from this batch.
