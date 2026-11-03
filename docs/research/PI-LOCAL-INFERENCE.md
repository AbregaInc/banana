# Banana Pi local inference investigation

Current 25 October status: [broader app integration](PI-APP-INTEGRATION.md), [engine/model selection and reproducible evaluation](PI-INFERENCE-SELECTION.md). The dated results below retain their original scope.

24 October 2026. Sources checked at code level; reviewed commits are in `tools/pi-model-bench/research-sources.json`. Experimental model weights stay outside the app/worktree, under the preserved sibling `pi-inference-upstream/models`. No Pi core changes or production backend switch.

## Separate inference from execution

Pi remains the durable agent on the originating device. An inference engine proposes text/tool intents; it never runs Banana capabilities. Native validators, revision checks, durable operation IDs and explicit meal review continue to govern execution. Replacing a model must not replace Pi's scheduler, journal, compaction or tool loop.

`AppleFoundationModel.generate` now accepts an optional session factory. Its default remains the existing Apple executor wrapper. The isolated benchmark passes an MLX model through the same FoundationModels transcript/schema and intent-only tools. Every tool throws before any application effect; Pi normally receives those intents. The benchmark links no Banana data store or capability executor.

The public MLXFoundationModels adapter supports `LanguageModelSession`, guided output and tool calling on OS 27. MLX supports iOS as well as macOS; the native adapter avoids implementing another agent. This does not make custom decision heads automatically compatible.

## What the cited approaches actually provide

| Candidate | Source/code finding | Banana implication |
|---|---|---|
| Liquid RIPL | Enterprise NVIDIA inference engine; announced H100/H200/B200/RTX PRO 6000 support. | Its published latency is not evidence of that latency on an iPad. Liquid's small model weights are a separate mobile candidate. |
| Locals | Python/macOS server, MLX and custom Metal kernels, compatible inference HTTP APIs and structured output. Published 3x result is concurrent throughput; single-request gains differ. | Potential paired-Mac inference worker. Not a drop-in native iOS package. Keep Pi/execution on the origin and authenticate any LAN service. |
| Von | Archived ModernBERT decision model, one forward pass over named choices/conditions/scores. Python/OpenVINO/MPS paths. | Useful concept for routing/ranking. Its author recommends d1 for new work. No provided native Swift decision runtime was found. |
| Kev-0.5B | Original release uses Qwen2.5-0.5B backbone, LoRA, isolated question branches and a trained pointer head. The 38 MB release is an adapter/head, not the whole model. | Can test route selection cheaply, but cannot generate arbitrary meal text/dates/amounts. A mobile port must preserve head, token packing and attention mask. |
| Current Kev | New 0.8B/4B/9B/27B family and a Python MLX backend with a custom decision head. | Evaluate separately from the original prototype. Ordinary Qwen text-generation support does not imply Kev compatibility. |
| Liquid d1-omni-600M | Maintained decision model, direct distributions over typed questions. 381M shared text trunk/head plus vision/audio encoders. | Promising routing/entity-selection candidate. Needs native conversion and output-parity/calibration checks before mobile use. |
| Cactus | Native mobile runtime and model bundles. Published small-LFM mobile benchmarks measure prefill/decode throughput. | A real mobile option, but its current runtime license has commercial eligibility conditions; not an interchangeable permissive dependency. |

Sources: [RIPL](https://www.liquid.ai/blog/low-latency), [Locals code and benchmarks](https://github.com/Generated-Computers/Locals), [Von](https://github.com/wfzyx/von), [Kev original release](https://github.com/jaredpalmer/kev/releases/tag/v0.1.0), [current Kev](https://github.com/jaredpalmer/kev), [d1 model card](https://huggingface.co/LiquidAI/d1-omni-600M), [MLX adapter](https://github.com/ml-explore/mlx-swift-lm/tree/main/Libraries/MLXFoundationModels), [Cactus](https://github.com/cactus-compute/cactus).

## Where decision models fit

Use a decision model to choose among explicit, bounded candidates: chart versus note versus schedule versus clarification; the referenced meal among search results; or a nutrient/filter/relative-period enum. Include an abstain option and evaluate ambiguous, unsupported and out-of-domain requests. An uncalibrated confidence score must not grant write authority.

A router helps only when it removes work. Running a router before an unchanged full model call can increase latency. Measure routing plus required argument extraction and view publication, not just forward-pass speed. Native touch controls and explicit search/suggestions need no inference and already use the same persisted Pi view path.

For a paired Mac, send bounded inference inputs and receive an intent. Keep authoritative conversation state, base revision, operation identity and saves on the iPad/iPhone. Reachability, authentication, cancellation, deadline and stale-response handling are required; silently replaying a timed-out external write is not acceptable. No paired service is implemented in this investigation.

## Reproducible probes

- `generate-requests.mjs` derives all seven tool schemas from the actual Banana registrations against the pinned Pi checkout. Twelve synthetic fixed-clock independent cases cover chart selection, food search, follow-ups, meal copy, notes, schedule, greetings, explanation, unsupported deletion and ambiguity. Active-view facts are synthetic; this is not a representative quality benchmark.
- `PiModelBench` runs Apple or a locally copied MLX model through the same intent capture. It saves per-case latency, proposed content and simple contract checks to its own sandbox. No runtime network downloader is enabled. Model loading is timed separately; pass zero includes first-generation shader work. No native capabilities run.
- `bench-kev05.py` uses unchanged v0.1.0 `model.py`, verifies source/checkpoint provenance in the report, and runs the original pointer head. It measures **routing only** on a Mac, excluding tokenization from forward timings. Results must not be compared as full-action latency against the generative probe.
- Quantized LFM and Qwen base manifests pin repository revisions and file digests. The Kev release tarball is checked against its published SHA-256 before loading. No training, cloud inference or telemetry service was started.

## Measurements from this investigation

All three generative engines ran natively on the physical M1 iPad Pro, iPadOS 27.0.1, in the separate Release benchmark app. Twelve independent synthetic requests were repeated twice, temperature zero, maximum response 256 tokens, seven actual tool schemas, a simplified synthetic active-view section, and no application effects. These are captured-intent timings, not full Pi turn/view latency. Each backend ran sequentially; this is a small exploratory test, not a production quality estimate or p95.

| Engine as configured | Median of second pass | Tool/view contracts passed, both passes |
|---|---:|---:|
| Apple system model | 3,698.5 ms | 18/24 |
| LFM2.5-350M, 4-bit MLX | 935 ms | 14/24 |
| LFM2.5-1.2B-Instruct, 4-bit MLX | 3,028.5 ms | 10/24 |

The scorer validates actual JSON schemas, accepts equivalent explicit dates/current view fields, and treats revisions as metadata bound by Pi's existing hook. The original on-device `correct` field is a stricter expected-field check and can reject equivalent dates; use `semanticContractSummary` for the table. Neither score evaluates the truth/helpfulness of ordinary reply text. For example, the small model's protein explanation was unhelpful despite choosing no tool correctly.

Observed failures include malformed filter arguments, an unwanted food filter, confusion between meal and note IDs, missing requested actions, and invented note/schedule prose. Apple also missed some synthetic searches/follow-ups. The 1.2B configuration did not improve this probe: its refusals/hallucinated data need adapter/prompt/weight evaluation rather than assuming more parameters solve the issue. These findings apply to these configurations, not all deployments of each model. No new engine was made the app default.

Source inspection explains one structural limitation: MLXFoundationModels uses native unconstrained tool generation in its default allowed mode; its grammar-constrained tool path is entered only in required mode. Declaring `.guidedGeneration` capability alone does not constrain optional tool calls. A future router can select a tool and then request constrained arguments, but forced-tool mode must not be applied indiscriminately to greetings/unsupported requests. Native/Pi validation remains required even with grammar constraints.

The original Kev-0.5B pointer head, using its unchanged release implementation and matching PEFT 0.21.0, routed 6/12 unique cases correctly on the M1 Max Mac (three repeats, 18/36). Median warm forward pass was 115.5 ms, excluding tokenization and all argument extraction/UI work. A greeting and an unsupported deletion request were among its incorrect nutrition routes. Its shipped temperature is not proof of calibration on Banana requests. This suggests testing task-specific adaptation and current decision models; it does not justify shipping this prototype unmodified as an automatic router.

Raw captures and provenance: `pi-apple-host-results/ipad-{apple,lfm350,lfm1200}-actions.json` and `mac-kev05-routing.json`. The separate benchmark app's model files are local copied weights; no remote inference or application capability ran. Pi core remains unchanged.

## Integrated Mac acceptance

The isolated Mac Pi app is installed at `~/Applications/Banana Pi.app` and opens Assistant inside the normal app sidebar. Qwen3.8-27B 4-bit uses a separate `mac-local` public Pi provider and a Mac-owned, loopback-only Locals inference worker. Pinned model/runtime/dependency metadata and setup are under `tools/pi-mac-inference`. Pi core remains unchanged. The worker proposes text and tool intents through the existing durable boundary, and unloads when its owning app quits or crashes. Main/Beta installs and stores remain separate.

Actual Mac acceptance now passes for notes/readback, durable operation deduplication, restored history, manual compaction and recall, ordinary reasoning, cancellation and the next input after cancellation. Nutrition acceptance passed twice: natural chart/filter/compare/search, contextual meal-copy draft, native save persistence and deduplication, stale conflict rejection, conversation isolation and restoration. The tests use isolated verification stores and confirm normal history/meals/preferences are unchanged and the owned worker exits. Reports: `pi-apple-host-results/mac-local-app.json` and `mac-local-nutrition.json`.

The installed UI was separately inspected using native accessibility and screenshots. Chart restoration, a natural “Only weekdays” follow-up, fresh conversation welcome, sample-chart shortcut, day selection and shared native meal review/cancel all worked. Those native actions made zero additional inference requests; the normal sample store retained 249 meals. Report: `mac-local-ui.json`.

Integration fixes include excluding passive chart hover selection on Mac, keeping headless verification out of the interactive view, stable sorted request serialization for prefix-cache reuse, one tool call per generation, and preserving readiness after user cancellation. Mac uses an eager transcript stack and resets scroll identity when switching conversations, correcting a blank chart transition. iOS retains its lazy stack. Twenty native tests, twelve public-provider checks and the worker lifetime check passed.

The medium-reasoning synthetic action probe passed 24/24 checks, with a 7.23-second warm median on the shared M1 Max. Actual cold chart publication measured 16.476 seconds; the latest visible language follow-up took tens of seconds. Native day selection measured 61 ms in acceptance. This is limited exploratory evidence, not a production accuracy estimate or unloaded-host p95. The model is substantially larger than the mobile candidates, but this setup does not deliver consistently instant language interaction. Native controls and explicit shortcuts remain the immediate path.

No paired Mac-to-iPad/iPhone inference bridge is implemented. Existing mobile inference remains Apple-based. Main's release workload retains resource priority; quit the Mac Pi app to release its owned model worker when needed. Sources, model files and results are preserved.

## Faster Mac default after user testing

The 27B model took 16.275 seconds to answer the user's name question and 22.038 seconds to prepare a salmon repeat. The Mac default has therefore switched to Qwen3.5-4B 4-bit with thinking disabled and a 2,048-token response budget, using the existing Locals provider/worker. The pinned checkpoint is [mlx-community/Qwen3.5-4B-4bit](https://huggingface.co/mlx-community/Qwen3.5-4B-4bit), revision `0e7ffd5c629ef7719d4cbc04069232580bfa9d9c`; file digests and both model profiles are under `tools/pi-mac-inference`. The 27B weights and quality profile are preserved and unloaded.

Both actual-app acceptance flows passed on 4B: nutrition and the general agent, including cancellation/recovery, compaction/recall and note persistence. The initial chart measured 5.559 seconds versus the earlier 16.476-second 27B observation. A replay exposed a wrong tomorrow assumption for a repeat request, followed by unnecessary lookup in a later candidate. The nutrition extension now explicitly instructs using the most recent matching visible meal for today unless the person specifies another date. Final inference replays passed both exact inputs twice: name 3.617/3.044 seconds; salmon draft intent 2.994/2.089 seconds. No native effects execute in replay, and the original visible view is captured while tool guidance reflects the current extension. The first earlier name replay took 8.254 seconds, so warm results must not be presented as cold guarantees. These are small shared-host observations with different model/reasoning configurations, not an isolated comparison of engines.

Reports: `mac-fast-app.json`, `mac-fast-nutrition.json`, final-extension `mac-fast-final-nutrition.json`, and `mac-fast-user-replay-final.json` under `pi-apple-host-results`. Earlier failed replay reports are retained. Native review still controls meal saving, and Pi's core remains unchanged.

Final installed UI check: the original user conversation and saved salmon restored under the fast model. “What is your name” took 7.163 seconds for the first post-restart model call and 0.653 seconds for a warm repeated input. “Can you add the salmon dinner again” took 1.290 seconds of model time and opened today's review draft. The test draft was dismissed; all 250 pre-existing meals remained. Final nutrition acceptance's first chart took 4.248 seconds. See `mac-fast-ui.json`; model time excludes final UI rendering, and repeated warm input is not representative of every request.
