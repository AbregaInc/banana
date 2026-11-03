# Local inference for Banana Pi on Mac

This is the isolated PiDevelopment app's local inference worker. Pi remains the agent runtime in JavaScriptCore/SQLite; the worker receives model inputs and returns proposed text/tool calls. It cannot reach Banana's app capabilities.

## Model and runtime

The default is now **Fast: Qwen3.5-4B, 4-bit, thinking off**, pinned at `0e7ffd5c629ef7719d4cbc04069232580bfa9d9c`. [Checkpoint](https://huggingface.co/mlx-community/Qwen3.5-4B-4bit). Its checkpoint is about 3 GB, with a 32,768-token context and a 2,048-token response cap. `qwen35-4b-manifest.json` pins downloaded file hashes. The 27B model remains preserved as an optional quality profile; it is not loaded alongside the fast model.

The previous quality profile is:

- Qwen3.8-27B, community 4-bit MLX conversion, pinned revision `10c35caafbb80f7dc6a7a432cdd11af10a6d4818`. Approximately 16 GB of downloaded weights. [Original model](https://huggingface.co/Qwen/Qwen3.8-27B), [conversion](https://huggingface.co/mlx-community/Qwen3.8-27B-4bit), Apache 2.0.
- Locals commit `4f4d03f10232c9f2adeb1e96e2a7bd79a9e7fe19`, Apache 2.0; Python/MLX dependency versions in `requirements.lock.txt`. This runs only `locals.server`, never its agent-launch commands.
- Medium reasoning, 32,768-token app context, up to 8,192 response tokens. The tested action profile uses temperature 0.6, top-p 0.95, top-k 20. Qwen's general thinking recommendation uses temperature 1.0; this profile's evidence is specific to Banana's action checks. Historical reasoning is retained locally for continuation.
- One worker/request slot and a bounded 2 GB prompt cache. Inference listens only on `127.0.0.1:41789`. No cloud inference, LAN exposure or automatic Apple fallback.

## Everything is the app's own (since 1 November 2026)

Nothing is installed or configured on the Mac. Banana Pi carries its Python runtime and Locals,
and fetches its model itself:

- **Runtime in the app.** `build-runtime.sh` makes a relocatable CPython 3.13 (python-build-standalone
  via uv), Locals at the reviewed commit and `requirements.lock.txt`, pruned and precompiled
  (~490 MB, mostly MLX's GPU kernels). It is cached by a hash of those pins in
  `~/Library/Caches/Banana Pi build/pi-runtime/` (shared by worktrees; survives `tools/clean-builds.sh`).
  The `BananaMacPi` build's *Embed Banana Pi runtime* phase (`embed-runtime.sh`, PiDevelopment
  only) copies it to `Banana Pi.app/Contents/Resources/PiRuntime` and, with a real identity,
  signs its binaries with the hardened runtime. Other configurations carry nothing.
- **Model fetched by the app.** `Banana/Pi/Resources/pi-local-model.json` pins the repo, revision,
  every file's size and SHA-256 and the serving profile. `LocalModel` downloads into
  `~/Library/Application Support/Banana Pi/Models/<name>@<revision>/`, checks every hash and stamps
  the folder. Until then Pi uses Apple's on-device model; Settings › Assistant shows one line.
- **Worker started by the app.** `MacLocalInference` runs the bundled Python (`-I -B`: only its own
  packages, never writing inside the app) on 127.0.0.1:41789 with the profile from the pin.
  Quitting the app releases the worker; the worker's parent watch releases it on a crash. The log
  is `~/Library/Application Support/Banana Pi/LocalInference/engine.log`.

`setup.py`, the sibling `pi-inference-upstream` checkout and `LocalInference/configuration.json`
are no longer used. `run-app.py` derives the same settings from the app it is given;
`--inference-configuration` still qualifies another profile (verification runs only).
`bench-actions.py`/`bench-replay.py` predate this and still expect a configuration file.

## Checks

- `bench-actions.py` captures decisions against the same twelve synthetic cases used on iPad. It never executes a capability. The 27B medium-reasoning run passed 24/24 tool/view contract checks over two passes; this is not a general accuracy estimate. Warm median was 7.23 seconds on the shared M1 Max.
- `run-app.py /path/to/Banana\ Pi.app [--nutrition]` runs the actual Mac app graph in isolated verification stores, records a nonce-correlated result and checks normal history/meals/preferences remain unchanged. Its general flow covers notes, readback, compaction/recall, ordinary conversation, arithmetic, cancellation and another input after cancellation. Nutrition covers contextual chart/filter/search/copy, native review save identity, restore and conflict rejection.
- A 32K model's short acceptance conversation does not cross its automatic compaction threshold. The large-model app test explicitly exercises manual compaction, with verification-only zero recent-token retention so the short history has a compactable prefix, and labels it accordingly; the Apple test keeps its existing automatic threshold test.
- Native transport checks reject incomplete generation, malformed calls and reasoning without an answer. Pi continues to validate registered tool schemas, bind view revisions and commit effects.

Do not enable another model just by changing its name. Its tool parser, template, checkpoint, context and reasoning behavior must be tested with the same boundary and app flows.

## Current acceptance

The installed Mac app passed both real-model general-agent and nutrition flows, plus visible native UI checks; see `STATUS.md` and `docs/research/pi-apple-host-results/mac-local-{app,nutrition,ui}.json`. The Mac transcript renders eagerly to avoid blank transitions between long chats and native workspaces. User cancellation keeps the provider ready for the next request. Stable sorted request serialization permits prefix-cache reuse.

Language interaction still takes seconds and can take tens of seconds. The 7.23-second synthetic warm median is not a real-app latency guarantee. Explicit sample exploration, chart controls, day selection and meal review run without inference. The 249 fictional meals support testing without personal data.

## Fast-model evidence

`mac-fast-app.json` and `mac-fast-nutrition.json` passed real-model checks before the final repeat-policy clarification. `mac-fast-final-nutrition.json` records the final installed extension. Normal history, meals, selection and draft state were preserved by these isolated checks.

The original user requests took 16.275 seconds (“What is your name”) and 22.038 seconds (“Can you add the salmon dinner again”) on 27B. Inference-only replays of the same wording and captured native view, with the final tool instructions, took 3.617/3.044 seconds and 2.994/2.089 seconds on 4B. These are small shared-host samples, not a controlled engine comparison or production p95. The first earlier name replay took 8.254 seconds; cache misses and startup still matter. Reports retain raw outputs, including earlier wrong-date/extra-search behavior.

The repeat policy now says to prepare the most recent matching visible meal for today unless another date is requested. It uses existing native review and never saves automatically. This instruction belongs to Banana's nutrition extension; no Pi core modification was made. The smaller model can still make mistakes; these observed passes do not establish parity with 27B on difficult tasks.

Final installed UI check: the original user conversation and saved salmon restored under the fast model. “What is your name” took 7.163 seconds for the first post-restart model call and 0.653 seconds for a warm repeated input. “Can you add the salmon dinner again” took 1.290 seconds of model time and opened today's review draft. The test draft was dismissed; all 250 pre-existing meals remained. Final nutrition acceptance's first chart took 4.248 seconds. See `mac-fast-ui.json`; model time excludes final UI rendering, and repeated warm input is not representative of every request.


## Compare a candidate inside the app without changing the saved profile

Pi Mac now supports Locals' public `locals` and `mlx` compute selections through the same Locals frontend. The `serverModel` prefix selects the compute engine; `mlx-server` is not accepted. Optional configuration fields `temperature`, `topP` and `topK` default to the existing Qwen recipe (0.6, 0.95, 20). Explicit per-request temperature still takes precedence. No model routing or automatic promotion is introduced.

Use a separate configuration file for a candidate; the app's own profile is never edited. The override is honored only in the isolated debug Pi verification namespace. First qualify the exact checkpoint/serving view with the hash-verified evaluation tools. For the retained Ministral trial, derive this file from the existing setup:

```sh
python3 - <<'PYPROFILE'
import json,pathlib
root=pathlib.Path.cwd()
config=json.loads((pathlib.Path.home()/'Library/Application Support/Banana Pi/LocalInference/configuration.json').read_text())
manifest=json.loads((root/'tools/pi-evaluation/ministral3-3b-serving-manifest.json').read_text())
config.update(modelDirectory=str(root.parent/'pi-inference-upstream/serving-views/ministral3-3b-fixed-tokenizer'),modelId='ministral3-3b-4bit-verification',serverModel='mlx/ministral3-3b-fixed-tokenizer',name='Ministral 3B · Verification',revision=manifest['revision'],thinkingLevel='off',temperature=.1,topP=1,topK=0)
(root/'.build/pi-ministral-verification.json').write_text(json.dumps(config,indent=2)+'\n')
PYPROFILE
python3 tools/pi-mac-inference/run-app.py '/path/to/Banana Pi.app' --workspace --inference-configuration .build/pi-ministral-verification.json --report-prefix candidate-trial
```

Omit `--inference-configuration` to test the actual saved default. Quit/release other inference workers first; the driver refuses occupied ports 41789/41790. Choose new report prefixes to retain earlier evidence. General agent and nutrition checks use the same driver without `--workspace`, or with `--nutrition`, respectively. A workspace pass alone does not qualify a model: the Ministral trial failed saved-note readback in the general flow.

New verification traces correlate every completed model call with the run nonce and record HTTP transport duration, request bytes, provider token/cache counters and provider wall time. These traces are written only in the verification namespace. The driver retains them with the corresponding report and records host paging/swap snapshots, normal saved-configuration integrity, normal history/meals/preferences integrity and owned-worker release. It terminates only its own app process on an outer timeout, allowing the existing worker parent monitor to release inference. Failed or stale reports cannot pass the nonce check.

The extended workspace check covers a missing-time event request, no draft before clarification, and a second user input supplying time/duration. It permits an intermediate tool error only for that case and still requires the final clarification, unchanged native safety checks and correct final event. Pi's existing tool-result recovery handles this; no core, scheduler or journal patch is involved.

See [the full-app comparison](../pi-evaluation/RESULTS-APP-PROFILES-2026-10-25.md) for the observed timings and the candidate failure.

New meal/event drafts now expose their shared native editors directly in the assistant workspace. See [the workspace UX and acceptance record](../../docs/design/PI-WORKSPACE-UX.md) for the removed transition, scoped tests, screenshots and remaining edit-persistence/visual-test limitations.
