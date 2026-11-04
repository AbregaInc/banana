# Selecting Banana's local inference stack

This is a repeatable **qualification process**, not a claim that one model or engine is universally best. Current Mac production-in-Pi default: Qwen3.5-4B 4-bit, thinking off, Locals. No Kev/Von/d1 router is enabled. iPad/iPhone Pi use Apple Foundation Models. Native chart controls and existing catalog food resolution require no inference.

## Reproduce the comparison

Run from the Pi checkout, after completing builds/UI tests and quitting Banana Pi. Do not close personal apps or interrupt other agents. The runner refuses an occupied Pi port and only terminates its own child. All serving stays on loopback; no app capability or remote inference is reachable.

1. Generate fresh fictional cases from the real extensions:

   `node tools/pi-evaluation/generate-cases.mjs ../pi-upstream`

2. Snapshot discovery evidence without downloading weights or changing anything installed:

   `python3 tools/pi-evaluation/discover.py --output docs/research/pi-apple-host-results/inference-candidate-discovery-2026-10-25.json`

3. Install the small benchmark dependency in an isolated environment, or use one that already has the pinned requirements: `uv run --with jsonschema==4.25.0 python tools/pi-evaluation/benchmark.py ...`.

4. Compare identical weights/settings, one engine at a time:

   ```sh
   python3 tools/pi-evaluation/benchmark.py --engine locals --model ../pi-inference-upstream/models/qwen35-4b --python ../pi-inference-upstream/locals-env/bin/python --manifest tools/pi-mac-inference/qwen35-4b-manifest.json --memory-budget-gb 6 --output docs/research/pi-apple-host-results/eval-qwen35-4b-locals.json
   python3 tools/pi-evaluation/benchmark.py --engine mlx --model ../pi-inference-upstream/models/qwen35-4b --python ../pi-inference-upstream/locals-env/bin/python --manifest tools/pi-mac-inference/qwen35-4b-manifest.json --memory-budget-gb 6 --output docs/research/pi-apple-host-results/eval-qwen35-4b-mlx.json
   ```

The stock MLX compute engine uses the same Locals HTTP frontend. Its constraint/cache behavior can differ from the custom engine; those are part of the measured serving configuration. This original baseline is not a comparison of every possible standalone server. The runner now also accepts `--engine mlx-server` to test the installed stock MLX HTTP frontend and its native tokenizer/parser; this changes the serving configuration and must be labeled separately. Keep actual templates and parsers pinned: an HTTP-compatible endpoint alone does not establish equivalent tool behavior.

For another checkpoint, use `tools/pi-mac-inference/download-model.py REPO FULL_REVISION DIRECTORY --manifest MANIFEST`. Verify license/runtime support, download size and free disk first. The benchmark verifies every manifest digest before loading and rejects a checkpoint whose weight files alone exceed the supplied memory budget. Models stay in the preserved sibling workspace, never inside the app or repository.

## What the runner measures

- Actual Banana tool schemas and rendered public extension prompt sections, with a fixed fictional date/data snapshot. The 22 cases include identity, chart/search/filter/copy, new meals/events, missing information, notes, plan, unsupported actions and explicit no-write requests.
- Complete buffered response time, startup/readiness time, returned text/tool intents, schema and task-contract checks, token/cache counters and engine memory counters. The app currently buffers model generations too; token streaming/TTFT is not fabricated.
- Same checkpoint hashes, runtime versions, engine source commit/dirty status, hardware/OS and sampling settings. Requests are serial with bounded output/cache and explicitly recorded thinking/sampling settings. Defaults retain the original nonthinking Qwen preset. Locals uses a server-global seed; standalone MLX receives seed=0 per request, so its repeats are not independent quality samples. Raw responses remain reviewable; results are written after every case and cleanup runs on failure.
- System paging before/after. Any paging makes the timing exploratory (`cleanPerformanceRun=false`). Repeats are a small mixed-task sample; their median is not a production p95. “Warm” means the second pass, not a guarantee that every prefix was cached. Cold process/model loading is separate from first request; OS and Metal disk caches are not purged.
- GPU allocation peak and observed RSS are separate, overlapping measures. **Do not add them or treat either as certified app physical footprint.** Total mobile memory qualification requires on-device footprint/available-memory and lifecycle/thermal checks.

The automatic scorer checks contracts, not every claim's truth or conversational usefulness. Review raw answers and date/amount choices manually. This is the development smoke corpus used to find bugs; it is not held-out accuracy. Freeze a separate held-out set of unseen paraphrases, typos, ambiguity, boundary dates, long histories and stale-state scenarios before making a quality claim. Do not tune prompts on that set and then present the same score as independent validation.

## Promotion gate

A fast response that chooses the wrong tool or date is a failure, not a speed win. A candidate must pass the native transport/provider contracts, stale-state/deduplication/recovery tests, real-model agent + nutrition + workspace app flows, visible native editor/navigation checks and relevant physical-device memory/lifecycle checks. Test thinking configurations separately. Retain both successes and failures, including parser/template regressions. Promote by explicit reviewed profile/pin change, with a retained rollback profile; never auto-update weights or Pi core.

Use measured Pareto choices per app-memory budget: quality, complete-turn latency, sustained thermal behavior and footprint. Keep batch-one interactive latency separate from a future Mac hub serving several devices. A concurrent-throughput claim is not a single-user latency result. Distribution/runtime support is a gate before performance, including the actual model/engine license and App Store packaging path.

## Finding replacements tomorrow

`candidates.json` is a reviewed shortlist. Discovery records upstream release/tip revisions, licenses, model asset sizes/base-model dependencies, and recent model signals from the publisher feeds listed in `candidates.json`. Compare snapshots during dependency/model updates and before a release; a new tip or trending model is a signal to review, never an automatic promotion. Check changelogs, supported architectures, native tool templates, fixes for the specific GPU/OS, and first-party benchmark methodology. Community leaderboards/issues are leads; reproduce their claims on Banana's hardware and workload. Add a candidate with exact code/model/template pins, run the same protocol, then the app gate.

Decision models are a separate experiment. Measure routing **plus** argument extraction, fallback and final UI publication, with ambiguous/out-of-domain cases and an abstain path. Freeze confidence thresholds on Banana labels and test calibration on unseen labels. Kev's head cannot be substituted by ordinary text generation, and adapter size excludes its backbone. Do not bolt a router onto every request unless the complete workflow improves. No decision model gains write authority.

See [the research findings](../../docs/research/PI-INFERENCE-SELECTION.md) for the current device/memory shortlist and source links.

Initial retained evidence: [four-run matrix and failure audit](RESULTS-2026-10-25.md).

Broader search categories and prioritized independent model families: [efficient-model landscape](../../docs/research/PI-EFFICIENT-MODEL-LANDSCAPE.md). Family-specific preset/template qualification remains required; explicit sampling/thinking and native-frontend options are documented below.

## Family-aware local testing

The runner now accepts explicit `--thinking on|off`, `--temperature`, `--top-p`, `--top-k`, `--repetition-penalty` and `--recipe-note`. Use the vendor-supported template and preset, and label every omission/experimental override. Pinned Locals does not implement repetition penalties; the runner rejects a non-neutral penalty for its frontend rather than silently ignoring it. Stock `mlx-server` accepts the documented repetition penalty and uses its own native tool parser. Neither option modifies Pi core, a model template, weights or the installed app profile.

Standalone MLX uses one prompt cache with a 2GB cap and serial prompt/decode concurrency. It has no equivalent max-context CLI flag: the fixed small fixture and output cap bound these requests; the report explicitly records that distinction. Its HTTP-ready duration is recorded separately and is **not** claimed as completed model-load time; loading can overlap readiness/first request. It provides no Locals GPU `/stats` endpoint, so GPU allocation is unknown and observed process RSS is recorded instead. Do not compare absent counters as zero.

`--memory-budget-gb` screens checkpoint bytes before loading. It is not a runtime memory limiter or certification that the whole app fits that budget. Read measured working-memory counters and include UI, cache, scratch and lifecycle overhead. Current fixture runs are not thermal/mobile acceptance.

Reproduce template qualification without loading weights:

```sh
../pi-inference-upstream/locals-env/bin/python tools/pi-evaluation/qualify-template.py ../pi-inference-upstream/models/lfm1200 ../pi-inference-upstream/models/lfm2600 ../pi-inference-upstream/models/qwen35-4b --output docs/research/pi-apple-host-results/local-model-template-qualification.json
```

Liquid 1.2B uses the already-retained manifest under `tools/pi-model-bench`. The new 2.6B checkpoint is pinned at `04efa23776ce61ec34ec95ec34c859854c89542b` with `tools/pi-evaluation/lfm2600-manifest.json`.

```sh
python3 tools/pi-evaluation/benchmark.py --engine mlx-server --model ../pi-inference-upstream/models/lfm1200 --python ../pi-inference-upstream/locals-env/bin/python --manifest tools/pi-model-bench/lfm1200-manifest.json --thinking off --temperature .1 --top-p 1 --top-k 50 --repetition-penalty 1.05 --recipe-note 'Liquid 1.2B Instruct native sampling; top_p=1 unspecified by card; stock native parser' --memory-budget-gb 3 --output docs/research/pi-apple-host-results/eval-lfm25-1p2b-mlx-server.json
python3 tools/pi-evaluation/benchmark.py --engine mlx-server --model ../pi-inference-upstream/models/lfm2600 --python ../pi-inference-upstream/locals-env/bin/python --manifest tools/pi-evaluation/lfm2600-manifest.json --thinking on --temperature .1 --top-p 1 --top-k 50 --repetition-penalty 1.1 --recipe-note 'Liquid 2.6B native reasoning/sampling; top_p=1 unspecified by card; stock native parser' --memory-budget-gb 4 --output docs/research/pi-apple-host-results/eval-lfm25-2p6b-mlx-server-thinking.json
```

Other retained runs vary the frontend, omit unsupported repetition penalties explicitly, or use Locals' experimental empty-reasoning prefix. Read each report's settings and recipe note; these are not silently equivalent model presets. Actual launch commands are retained in reports. The standalone frontend's `reasoning` response field also differs from the app transport's current `reasoning_content` contract; provider adaptation/continuation tests are required before any app promotion.

Fresh paraphrase fixture: `--fixture tools/pi-evaluation/paraphrases-v1.json`. This 17-prompt follow-up was frozen before greedy/fresh-paraphrase runs and is not a representative or blinded production quality set. No prompt/schema changes were made from its results. Read [the local follow-up and failure audit](RESULTS-LOCAL-FOLLOWUP-2026-10-25.md) alongside the original matrix.

For SmolLM3, the official template expects `xml_tools` rather than the usual `tools` keyword. The runner supports `--template-tools-key xml_tools` only with native MLX, and passes plain function schemas as documented by Hugging Face. `qualify-template.py` checks that an actual probe tool name appears in rendered templates; parser availability alone is insufficient.

`prepare-serving-view.py` creates a separate directory of symlinks to verified original assets and overrides only explicitly requested public tokenizer metadata. It refuses an original/ancestor destination and never edits the original checkpoint. The resulting manifest records the metadata delta and original manifest hash. Current uses: Ministral's documented `fix_mistral_regex=True`; SmolLM3's existing MLX `tool_parser_type=json_tools`. No new parser or model template is implemented.

The targeted `--mlx-matmul` control uses the documented `LOCALS_KERNELS=0` switch with the custom Locals runtime, retaining its other fusion/cache/frontend behavior. Runtime environment and overrides are recorded. `LOCALS_TUNE=off` is **not** a blanket fix for tuning latency: the pinned source documents first-use tuning for untuned shapes in that mode. Keep tuning/cache effects visible rather than blindly disabling them.

`probe-cancellation.py` tests the next request after closing a nonstreaming client. It verifies checkpoint hashes, establishes a long synthetic generation, closes only its own client, times the following response and releases only its owned backend. This is a provider responsiveness probe, not a replacement for the real Pi app's cancellation/lifecycle tests. Run only after the normal benchmark process exits; the same occupied-port guard applies.


## Independent families and serving lifecycle gate

The [independent-family matrix](RESULTS-INDEPENDENT-2026-10-25.md) retains actual Mac runs for Ministral 3B, SmolLM3 3B, Gemma 4 E2B/E4B, Liquid 8B-A1B and MiniCPM5 2B. Read both contract failures and [cancellation evidence](CANCELLATION-2026-10-25.md) before selecting an engine. The pinned standalone MLX frontend delayed the next nonstreaming request about 116 seconds after its previous client disconnected. The same Ministral checkpoint through Locals' frontend/MLX compute returned the next reply in about 2 seconds. This is a transport/frontend gate, not a reason to rewrite Pi or silently switch the installed provider.

To reproduce a cancellation probe after other workers have exited:

```sh
python3 tools/pi-evaluation/probe-cancellation.py --engine mlx-server --model ../pi-inference-upstream/serving-views/ministral3-3b-fixed-tokenizer --python ../pi-inference-upstream/locals-env/bin/python --manifest tools/pi-evaluation/ministral3-3b-serving-manifest.json --output docs/research/pi-apple-host-results/cancel-ministral3-native-mlx.json
```

Use a new report filename for a new experiment to preserve the original evidence. The probe requires at least 400 generated baseline tokens; otherwise it stops as inconclusive before cancellation. It records measurement completion, not an automatic pass/fail latency policy. Inspect the following reply as well as duration. The Qwen integer-array probe did not establish that workload (`[]`), so it does not establish cancellation behavior for Qwen. Use the existing full-app cancellation regression too.

After component testing, the [full-app profile comparison](RESULTS-APP-PROFILES-2026-10-25.md) retains a candidate failure invisible to one-turn schema scoring: Ministral misread a complete native note as truncated. Verification-only profile overrides and per-run inference traces now support the real-app promotion gate without swapping the saved daily configuration. The same checks demonstrate that upstream Pi can recover from a rejected missing-time draft; native validation is not weakened to improve scores.

## Mac capability routing qualification

The current Mac provider uses outcome selection followed by a restricted tool set. Use `--capability-routing` for that workflow; the default runner remains the raw model baseline. See [the design and enforcement boundaries](../../docs/research/PI-CAPABILITY-ROUTING.md) and [the common-query protocol](COMMON-QUERY-TESTING.md).
