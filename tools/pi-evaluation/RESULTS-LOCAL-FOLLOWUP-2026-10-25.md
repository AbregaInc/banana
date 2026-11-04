# Local model/serving follow-up: 25 October 2026

These are serial inference-only runs against the real Banana tool schemas and fixed fictional context. No app capability executes. Each row has 22 development prompts, repeated twice; those 44 contracts are not independent production samples or held-out accuracy. The parser/preset/cache changes are part of each labeled configuration, not silently identical experiments.

| Model | Serving configuration | Contracts | Warm median ms | First request ms | Paging observed? |
|---|---|---:|---:|---:|---|
| Liquid 1.2B | Locals fallback | 12/44 | 1336 | 3027 | Yes |
| Liquid 1.2B | Native MLX | 16/44 | 1043 | 1670 | Yes |
| Liquid 2.6B | Native MLX, reasoning | 36/44 | 2647 | 3288 | Yes |
| Liquid 2.6B | Locals, reasoning | 32/44 | 1438 | 8130 | Yes |
| Liquid 2.6B | Locals, forced empty reasoning | 29/44 | 404 | 5968 | Yes |
| Qwen 2B | Native MLX | 42/44 | 1607 | 2057 | Yes |
| Qwen 4B | Native MLX | 44/44 | 3621 | 4629 | Yes |
| Qwen 4B | Locals, current sampling | 42/44 | 739 | 1766 | No |
| Qwen 4B | Locals, greedy | 42/44 | 737 | 1923 | Yes |

Raw JSON responses, timings, paging deltas, launch commands, checkpoint hashes and logs are in `docs/research/pi-apple-host-results/`. The reports record each recipe. Host: M1 Max, 64GB. First response excludes a separately recorded Locals startup duration; standalone MLX HTTP readiness is not a certified completed-model-load measurement.

## Failure audit and decision

- The pinned Locals frontend misdetects the 1.2B template as fallback, while the tokenizer/native MLX parser recognizes Liquid Pythonic calls. The 12/44 row is an integration diagnostic, not a clean estimate of model ability. Native MLX recovers parsing but the 1.2B model still refuses supported requests and emits incorrect tool/argument forms in this workload.
- Liquid 2.6B with native reasoning/template/sampling gets 36/44. It often omits the calories metric, which would leave the protein default, and unnecessarily invokes tools for missing-time/ambiguous/unsupported requests. The valid native parser therefore does not remove the model/workload errors.
- Locals 2.6B reasoning reduces observed warm median but adds schema, food-count and tool-selection misses. Pinned Locals does not implement the recommended repetition penalty; omission is explicitly recorded, so this is not claimed to match the native preset.
- Forced empty reasoning is a server-supported experiment outside Liquid's native always-reasoning recipe. It is fast but drops to 29/44; it is not promoted.
- Native MLX improves Qwen 2B to 42/44 here; missing-time drafting remains a failure. Native Qwen 4B gets 44/44 on this small corpus. Native MLX is a distinct frontend and cache implementation from the earlier Locals-hosted stock compute-engine baseline.
- Current fast Qwen 4B/Locals reproduces 42/44 and roughly 0.74-second warm median, with one run showing no paging during its measurement window. Its unnecessary read-tool calls for greetings remain. Greedy decoding does not eliminate them. This is not a production p95, cold-app guarantee or universal best-model result.

## Fresh paraphrase comparison

A separate 17-prompt fixture was frozen before the greedy/fresh-paraphrase runs. It changes wording and includes an all-day event, explicit no-note/no-save requests, missing day/time and unsupported undo. It was not used to change prompts or tool schemas. It is a small follow-up check designed with knowledge of the development failures, not a blinded/representative production evaluation. Repeats are not independent samples.

| Configuration | Contracts | Warm median ms | Paging observed? |
|---|---:|---:|---|
| Qwen 4B Locals greedy | 32/34 | 654 | No |
| Qwen 4B Locals current | 33/34 | 565 | No |
| Qwen 2B native MLX | 28/34 | 1521 | No |
| Qwen 4B native MLX | 34/34 | 3578 | Yes |
| Liquid 2.6B native MLX reasoning | 28/34 | 2593 | Yes |

## Scope and reproducibility

Use the benchmark's explicit thinking/sampling/recipe options and `--engine mlx-server` for the native frontend. `qualify-template.py` reproduces the parser finding without loading weights. Every checkpoint is hash verified. No Pi core, model template/weight or installed app profile was changed. No third-party model was deployed to iPad/iPhone, and these results do not qualify mobile memory/thermal behavior.

The checkpoint budget flag screens weight bytes; it does not hard-limit runtime memory. Locals reported first-use Liquid kernel tuning; cache/tuning state was not purged, so do not attribute all timing differences solely to architecture or reasoning mode. GPU/RSS counters overlap and cannot be summed; native MLX exposes no Locals GPU counter. Observed 2.6B Locals GPU peak exceeded 4GB in its reasoning run, so it does not establish a 4GB working-memory fit. RSS values are observations, not certified total app footprint.

The initial Liquid download was admitted after checking a 5GiB free-disk reserve. Main subsequently released its own disposable output, and the shared volume rebounded to about 60GiB free, enabling the independent-family downloads recorded separately. Existing weights/workspaces and installed-build symbols were preserved. No main output or personal files were removed by this task.

Keep the installed profile unchanged pending the full native transport/continuation/durability and real-app promotion gate. Standalone MLX returns `reasoning` where the current app transport expects `reasoning_content`, and it is not an app-selectable serving profile yet. Adaptation must stay at the provider/transport boundary. A one-turn tool error may be recoverable by Pi, but the benchmark does not simulate that full loop or silently count a rejected/incorrect proposal as success.
