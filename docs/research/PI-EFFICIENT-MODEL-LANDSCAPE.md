# Efficient local assistant models: broader discovery

25 October 2026. This expands the first Qwen 2B/4B comparison. It is a primary-source research shortlist, not a claim that these models have passed Banana acceptance. The earlier matrix only tested two checkpoint sizes in one family; it cannot identify the best local assistant.

## Search for mechanisms, not a parameter-count cutoff

| Mechanism | Candidates | What must improve in Banana |
|---|---|---|
| Small instruction models without mandatory lengthy reasoning | [LFM2.5-1.2B-Instruct](https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct), [Ministral 3 3B/8B Instruct](https://mistral.ai/news/mistral-3/), [SmolLM3-3B](https://huggingface.co/HuggingFaceTB/SmolLM3-3B) | Short complete turns, tool/date/amount correctness, clarification, no-save requests; compare their own supported nonthinking modes |
| Efficient hybrid/recurrent computation | [LFM2.5-2.6B](https://huggingface.co/LiquidAI/LFM2.5-2.6B), [Granite 4 H Tiny](https://huggingface.co/ibm-granite/granite-4.0-h-tiny) | Actual prefill, decode, state/KV growth and Apple kernel support, not generic transformer benchmarks |
| Low-active-parameter sparse models | [LFM2.5-8B-A1B](https://huggingface.co/LiquidAI/LFM2.5-8B-A1B), [Ling-3.0-tiny](https://huggingface.co/inclusionAI/Ling-3.0-tiny), Gemma 4 26B A4B | Broader quality at low per-token compute; include all expert weights in the memory qualification |
| Mobile-specific designs | [Gemma 4 E2B/E4B](https://ai.google.dev/gemma/docs/core/model_card_4) | A quantized native runtime that fits the actual app budget; effective parameter counts omit large embedding tables |
| Shorter-thinking post-training | [ThinkingCap family](https://bottlecapai.com/), including [Gemma variant](https://bottlecapai.com/post/thinkingcap-gemma-4-26b/) | Quality at a smaller generation budget, compared against the same base model; measure both supported thinking-on and thinking-off behavior |
| Target-verified speculative decoding | [LFM2.5 DSpark](https://www.liquid.ai/blog/lfm2.5-dspark) | Complete-turn improvement after draft overhead, acceptance rate, extra memory and target verification; preserve the intended target distribution |
| Task-specific small action models | [FunctionGemma 270M](https://ai.google.dev/gemma/docs/functiongemma), alongside existing decision-model research | Banana-specific fine-tuning/held-out evaluation, argument extraction and abstention/fallback; not a drop-in general chat replacement |

These mechanisms overlap. A sparse hybrid can also have a speculative drafter or shorter-thinking fine-tune. Quantization is another independent axis: evaluate the exact artifact, including tool behavior, rather than assuming every 4-bit conversion has equivalent quality. A draft model is an auxiliary model, not an alternative assistant.

## Concrete first wave

1. **LFM2.5-1.2B-Instruct and 2.6B:** prioritize the small action/agent workload. The 1.2B Instruct variant is distinct from its Thinking sibling. The 2.6B card describes mandatory reasoning, so do not silently force it through the existing Qwen thinking-off recipe. Its tool format and recommended sampling differ too.
2. **Ministral 3 3B Instruct and SmolLM3-3B:** independent compact-family controls. Measure native tool templates, short answers and hallucination/clarification behavior rather than comparing only reasoning benchmarks.
3. **Gemma 4 E2B/E4B:** native mobile qualification. Determine actual converted weight footprint, embedding handling, working memory and supported LiteRT/MLX/Metal path before any iPad/iPhone recommendation.
4. **LFM2.5-8B-A1B and Ling-3.0-tiny:** Mac and larger-budget sparse candidates. The cards specify 8.3B total/1.5B active and 7.9B total/1.3B active respectively. Check pinned native kernels and parsers; some upstream recipes require particular runtime revisions.
5. **ThinkingCap Gemma and other efficient-reasoning variants:** Mac quality lane. Compare against the base checkpoint at matched quality/budgets. The Gemma article reports roughly 39% fewer thinking tokens on its own benchmark suite, not a 39% reduction in Banana latency or RAM. Its published [recommended GGUF](https://huggingface.co/bottlecapai/ThinkingCap-gemma-4-26B-A4B-it-GGUF) is approximately 16.6 GB before cache/scratch; this is a larger-memory Mac candidate, not a 4B-sized download. Some benchmark categories regress, so inspect task-specific outcomes.
6. **DSpark plus its matched LFM target:** a separate decoding experiment. Liquid documents Apple Metal support, making it worth qualifying locally. No DSpark path is currently enabled in Banana or established by our Locals-vs-MLX comparison. An upstream speedup on another workload does not establish a gain for a five-token name response; loading/prefill can dominate.
7. **FunctionGemma:** a deliberate specialization experiment for common app actions. Google's intended use includes further training on a defined API. Evaluate the fine-tuning/data/maintenance cost and fallback path before placing it ahead of a general assistant.

This ordering is an engineering judgment about relevance and qualification cost, not a measured quality ranking. No new model weights were downloaded or activated for this discovery update; no current default or Pi core changed.

## Broader discovery that stays reproducible

The catalog now tracks 24 model/auxiliary artifacts across 13 publisher feeds, including BottleCap, Liquid, Google, Qwen, IBM, Hugging Face, Mistral, inclusionAI, NVIDIA, Microsoft, OpenBMB and TII. Keep searching outside those feeds too: use first-party model cards/papers for efficient reasoning, hybrid/recurrent architectures, low-active MoE, distillation/pruning, tool specialization and speculative/multi-token decoding. Community benchmarks are leads; validate the underlying artifacts and reported hardware.

The retained `efficient-model-discovery-2026-10-25.json` records code/model revisions, licenses, asset lists, base dependencies and recent release signals. A repository containing several GGUF alternatives is not one required download; select one concrete file and record its hash. Adapter/drafter sizes likewise exclude their required base/target models. Discovery never downloads weights or changes an app profile automatically.

Before extending the benchmark beyond Qwen, qualify each family's prompt/tool/reasoning format and record its recommended preset alongside a separately labeled controlled experiment. The runner now accepts explicit thinking/sampling settings and a standalone native MLX frontend, but it is not an automatically correct universal family adapter. Do not take a failure caused by an unsupported template or forced-off reasoning as evidence that a model itself is weak. Retain equal-workload cases, compare matched output budgets and document all recipe differences.

Use the [selection protocol](../../tools/pi-evaluation/README.md) and a fresh held-out Banana set: identity/greeting; create/search/filter; missing times; date boundaries; typos; explicit no-save requests; long history; multiple tools; cancellation and cold reopen. Measure first useful UI, full turn, cold load, prefill/decode, peak app footprint, thermal/lifecycle behavior and correctness together. Keep mobile-local and Mac-hosted results separate. Pi retains the journal/tool/capability boundary under every candidate.

## Local execution follow-up

The [retained local follow-up](../../tools/pi-evaluation/RESULTS-LOCAL-FOLLOWUP-2026-10-25.md) now tests Liquid 1.2B/2.6B as well as Qwen controls and serving/sampling variants. Parser qualification exposed a Locals fallback mismatch for Liquid 1.2B; native MLX fixes that mismatch without changing the checkpoint or Pi. Liquid 2.6B reaches 36/44 development contracts with its native reasoning recipe, while forced empty reasoning is faster but less reliable. These are measured configuration results, not elimination of a whole architecture or mobile acceptance. The installed model/profile remains unchanged.


Independent-family execution is now retained in the [Mac results](../../tools/pi-evaluation/RESULTS-INDEPENDENT-2026-10-25.md), covering Ministral, SmolLM3, Gemma, larger sparse Liquid and MiniCPM5 in addition to the Liquid/Qwen follow-up. The catalog marks these as component-tested artifacts, not app/mobile-qualified deployments. The [frontend cancellation finding](../../tools/pi-evaluation/CANCELLATION-2026-10-25.md) is a separate promotion gate: a high tool-contract score cannot compensate for a provider that leaves the next request blocked after a client abort.
