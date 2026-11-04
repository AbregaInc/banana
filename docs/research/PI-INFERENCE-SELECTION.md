# Local inference selection: 25 October 2026

Qwen3.5-4B 4-bit is Banana Pi's tested Mac incumbent, **not a demonstrated best model**. Mac uses the pinned Locals runtime; iPhone/iPad use Apple Foundation Models. No Kev, Von or d1 decision model is deployed. The older 27B profile remains available but its observed everyday latency was unacceptable. Default changes require both workload evidence and real-app acceptance.

## Separate the choices

An engine executes a checkpoint; its kernels, prefix cache, tokenizer, prompt template, tool parser and memory policy all affect the result. A model determines much of the quality/compute tradeoff. A decision model produces a classification/ranking distribution and needs an additional argument-extraction/fallback path. None replaces Pi's scheduling, durable journal or capability boundary. Keep these choices in public providers/extensions and native adapters; do not fork the Pi core to chase a benchmark.

The reproducible [evaluation toolkit](../../tools/pi-evaluation/README.md) freezes actual Banana prompts/tool schemas, checkpoint hashes, settings and raw outputs. Compare Locals' custom engine and stock MLX using identical weights before attributing a result to model size. Then compare 2B and 4B with the same settings. The stock baseline shares the Locals HTTP frontend; it is not a benchmark of every standalone MLX server configuration. Its adapter is currently evaluation-only, not an app-selectable profile.

## Engine shortlist

| Engine | Role to qualify | Main question |
|---|---|---|
| [Locals](https://github.com/Generated-Computers/Locals) | Current Mac worker | Does its concurrent-throughput optimization help our single serial turn? |
| [MLX LM](https://github.com/ml-explore/mlx-lm/blob/main/mlx_lm/BENCHMARKS.md) | Stock Mac baseline | Same-weight complete-turn latency, cache behavior and tool parity |
| [MLX Swift LM](https://github.com/ml-explore/mlx-swift-lm) | Native Apple app candidate | Model/operator/template parity and lifecycle footprint |
| [llama.cpp](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md) | Native Metal/GGUF candidate | Correct Jinja template and tool parser on the pinned build |
| [LiteRT-LM Swift](https://github.com/google-ai-edge/LiteRT-LM/blob/main/Package.swift) | Native mobile/Mac candidate | Compiled asset support, Gemma tool behavior and memory |
| [MLC](https://github.com/mlc-ai/mlc-llm), [Cactus](https://github.com/cactus-compute/cactus), [Ollama](https://github.com/ollama/ollama) | Secondary candidates | Conversion/distribution costs, actual backend and residency policy |

These are qualification candidates, not measured winners. Native engines are needed for packaged third-party mobile inference; the Mac's Python worker cannot simply ship on iOS. Keep Pi in charge of tools; do not enable a server's own autonomous capability execution. Official benchmark results on another chip, concurrency level or prompt are discovery evidence, not Banana latency.

## Choose against an app memory budget

Phone/iPad RAM is not all available to our process. Measure physical footprint, available memory, model/KV/cache/scratch peaks, UI/data overhead, thermal behavior and background/foreground survival on each actual target. Apple's [increased-memory entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.kernel.increased-memory-limit) is not a guarantee that a particular checkpoint fits.

The following are **screening tiers for inference headroom after app overhead**, not device guarantees or validated configurations:

| Measured inference headroom | Candidates to screen | Why |
|---|---|---|
| Below 3 GB | Apple system model; smaller quantized models | Even a 1.7 GB checkpoint still needs working memory; third-party quality must justify residency |
| 3–6 GB | Qwen3.5-2B 4-bit; LFM2.5-2.6B 4-bit; cautiously 4B | Smaller weights leave room for UI, context and scratch; real peak decides |
| 6–12 GB | 4B, Qwen3.5-9B 4-bit; quantized Gemma candidates | Compare tool accuracy and latency rather than parameter count |
| Above 12 GB | Larger Mac quality/MoE profiles | More resident weights can hurt interactive speed and shared-machine pressure |

The retained discovery snapshot records exact revisions and file sizes. Current quantized Qwen2B weights are about 1.72 GB, Qwen4B 3.03 GB, Qwen9B 5.95 GB and Qwen27B 16.05 GB; LFM2.5-2.6B MLX 4-bit is about 1.58 GB. These are download/checkpoint sizes, **not peak resident memory**. [Gemma 4](https://ai.google.dev/gemma/docs/core/model_card_4) E2B/E4B effective compute counts and a MoE's active parameter count likewise do not describe total weight residency. Require the exact quantized artifact before admitting it to a budget tier.

## What we know about decision models

The earlier Kev0.5 prototype got 6/12 Banana routing labels correct; its approximately 115.5 ms warm forward measurement excluded tokenization, argument extraction and fallback. That is not evidence for shipping it. The current [Kev0.8B card](https://github.com/jaredpalmer/kev/blob/main/docs/model-cards/kev-0.8b.md) explicitly excludes tool-call routing from its intended use. The [Kev4B card](https://github.com/jaredpalmer/kev/blob/main/docs/model-cards/kev-4b.md) reports a different, larger candidate: assess its full backbone/head memory and workload latency, not the small adapter download. Neither is a normal chat model. d1 and Von remain research candidates without a validated Banana integration.

A router should be an optional experiment with an abstain path. Label Banana-specific tasks, calibrate on a development split and evaluate unseen paraphrases/ambiguity. Measure routing plus extraction plus fallback plus UI publication. Avoid paying for two models on every request unless that complete workflow improves quality or latency. Native chart controls and explicit shortcuts already avoid inference safely; they need no decision model.

## Reproduce and find improvements

Use the commands and promotion gate in the toolkit README. Discovery snapshots upstream code/release revisions, license/model metadata, dependency/backbone information and recent first-party model signals. It never updates an installed pin or downloads weights automatically. Review new releases before a planned dependency update, compare snapshots, add an exact candidate pin, run serial controlled comparisons, inspect failures, then run native transport/durability and real-app checks. Retain a rollback profile.

The 22 synthetic cases are a development smoke corpus, not held-out accuracy. Complete buffered response latency is measured; TTFT is not invented. Any paging disqualifies a run as clean performance evidence. GPU counters and RSS overlap and must not be added. Retained reports include raw outputs and failures, so later work can reproduce or challenge the selection rather than inheriting an unsupported claim that 4B is best.

## First controlled comparison

The [four-run matrix](../../tools/pi-evaluation/RESULTS-2026-10-25.md) is now retained: 4B/Locals 42/44 contracts, 4B/stock MLX 42/44, 2B/Locals 40/44, 2B/stock MLX 39/44. Second-pass observed medians were approximately 0.74, 4.91, 2.07 and 2.01 seconds respectively; every run paged, so these are exploratory observations rather than a clean performance ranking. The smaller model's allocation peak fell from approximately 5.8 to 3.8 GB under Locals, but it made more contract mistakes, including a no-save violation. No tool intent was executed by the runner. Keep 4B/Locals as the incumbent; qualify new candidates and repeat cleanly before claiming a winner. All workers were unloaded after the serial comparison.

## Expanded discovery after the initial matrix

The [efficient-model landscape](PI-EFFICIENT-MODEL-LANDSCAPE.md) expands the search beyond Qwen: compact instruction models, hybrid/recurrent and low-active sparse architectures, shorter-thinking variants, specialized action models and target-verified speculative decoding. The catalog/discovery snapshot includes 24 artifacts across 13 publisher feeds. These additions are discovery evidence, not new app or latency acceptance.

## Executed small-model and frontend follow-up

The [local follow-up matrix, fresh paraphrases and failure audit](../../tools/pi-evaluation/RESULTS-LOCAL-FOLLOWUP-2026-10-25.md) extends the initial Qwen-only compute-engine comparison. It tests Liquid 1.2B/2.6B with native presets/parsers, a separately labeled forced-empty-reasoning experiment, standalone MLX frontend controls and greedy/current Qwen sampling. Exact recipes and compatibility failures are retained. One repeated fast 4B/Locals run observed no paging and reproduced about 0.74-second warm median; this is still a small synthetic workload, not cold-app or production-p95 acceptance. New configurations are not installed as defaults from this development evidence.


## Independent families and frontend lifecycle findings

The [independent-family results](../../tools/pi-evaluation/RESULTS-INDEPENDENT-2026-10-25.md) broaden executed testing to ten checkpoints across six families. Ministral 3B is a promising speed candidate (40/44 development contracts, 32/34 fresh paraphrase contracts), but still proposes invalid empty dates or events without a chosen time. Native validation must remain authoritative; full Pi recovery/continuation must be checked before promotion. Smaller Liquid, SmolLM3 and MiniCPM configurations make additional workflow mistakes; the tested larger Gemma/Liquid configurations do not provide an interactive speed win here.

The [cancellation probe](../../tools/pi-evaluation/CANCELLATION-2026-10-25.md) also found a concrete lifecycle blocker in the pinned standalone MLX HTTP frontend: the next nonstreaming request waited about 116 seconds after the preceding client disconnected. Locals' frontend with MLX compute and the same Ministral checkpoint returned its following reply in about 2 seconds. These are individual shared-host observations, not p95 or app acceptance. Native Qwen's perfect small-corpus contract score therefore does not make that frontend ready for the app. Keep the current 4B/Locals default and the existing Pi loop; future changes belong at the provider boundary and must pass full-app cancellation and durable continuation gates.

The installed Mac app subsequently passed all three real-model checks (agent, nutrition, workspace) with the existing profile; [the acceptance details](../../tools/pi-evaluation/RESULTS-INDEPENDENT-2026-10-25.md#installed-app-checks-after-the-model-matrix) retain results and limits. Meal/event turns were about 11.4/8.4 seconds and a chart query about 8.7 seconds on the loaded host. Those are full-app observations and remain above the interactive goal, despite shorter component replies. Native chart selection took 250 ms without inference. No new visual UI/mobile acceptance is implied.

The [later full-app profile comparison](../../tools/pi-evaluation/RESULTS-APP-PROFILES-2026-10-25.md) tests Ministral through Locals/MLX compute against the actual 4B default without changing the saved profile. Both pass two-step event clarification using Pi recovery; Ministral fails complete-note readback and is not promoted. New default-profile full-app observations are about 2.6s meal / 1.4s event / 2.2s chart, with retained paging/transport/provider counters and explicit shared-host limits. These do not establish a causal speed gain from the instrumentation.
