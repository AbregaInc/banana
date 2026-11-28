# First-use assistant evaluation

The catalog has 500 hand-written user requests. It includes 200 mail cases, 200 calendar cases, and 100 cases for other Banana features. Email includes 100 assistant requests and 100 composer instructions. These are fictional requests and fixtures. The catalog is a product checklist, with room for tasks the current app cannot fulfill.

## Reproduce the installed Mac Beta baseline

```sh
node tools/pi-evaluation/first-use/run.mjs --out private/ai-evals/my-beta-run
uv run --no-project --with jsonschema==4.25.0 python tools/pi-evaluation/first-use/score.py \
  private/ai-evals/my-beta-run --out private/ai-evals/my-beta-run/scored.json
```

The runner verifies every file in the installed Beta model pin, starts an owned copy of the bundled worker on a separate loopback port, authenticates it, and loads the actual tool registry and production routing code from the installed app's JavaScript bundle. It records each case's proposal and raw inference, with one row per case. If the route itself needs no inference, an additional shadow request goes to Qwen and is recorded separately. The route verdict remains the actual route result. App capabilities are inert in this harness. No network outside the local worker is needed.

Use an existing output directory only to resume the same experiment. The runner verifies the catalog, exact bundle and request metadata before skipping completed cases. Run one evaluation worker at a time. Use `--ids FILE` for exact paired subsets and `--bundle FILE` for regenerated candidate code. For a build that uses the native composer prompt builder, pass its rendered cases with `--composer-requests FILE`.

## Exercise email continuations with fictional data

Supply `--mail-fixtures tools/pi-evaluation/first-use/mail-evidence-fixtures.json` and the selected case IDs with `--ids`. For cases that request the right email read, the runner feeds the recorded fixture response to the real routing policy and records the continuation separately. A calendar lookup or draft proposal in that continuation is evidence for its arguments. The native store, connected provider, and review screen are outside this runner.

## Evaluate the native Mail composer

```sh
mkdir -p private/ai-evals/bin
xcrun swiftc -O -target arm64-apple-macosx27.0 -D BANANA_AI \
  Banana/Pi/AppleFoundationModel.swift Banana/Views/Mail/MailDraftPrompt.swift \
  tools/pi-evaluation/first-use/AppleComposer.swift -o private/ai-evals/bin/apple-composer
private/ai-evals/bin/apple-composer \
  < private/ai-evals/my-beta-run/composer-requests.jsonl \
  > private/ai-evals/my-beta-run/apple-composer.jsonl
```

The historical 500-case composer track sends the same 100 frozen body-writing requests to each evaluated backend. It measures a single generation. The current composer also runs a native evidence workflow. On Mac it uses an eligible installed local model or Apple Foundation Models. On iOS it uses Apple Foundation Models. The native Apple runner uses the app's Foundation Models adapter. Use `--render-candidate` with the original 186 composer input to build exact candidate requests with `MailDraftPrompt`.

## Run all 500 with Apple's on-device model

Build the native runner above, then use that executable with the same Pi bundle, composer requests, and optional fictional mail fixtures used for a Qwen comparison.

```sh
node tools/pi-evaluation/first-use/run.mjs --out private/ai-evals/my-apple-run \
  --apple-runner private/ai-evals/bin/apple-composer \
  --bundle Banana/Pi/Resources/pi-agent.js \
  --composer-requests private/ai-evals/my-beta-run/composer-requests.jsonl \
  --mail-fixtures tools/pi-evaluation/first-use/mail-evidence-fixtures.json
uv run --no-project --with jsonschema==4.25.0 python tools/pi-evaluation/first-use/score.py \
  private/ai-evals/my-apple-run --out private/ai-evals/my-apple-run/scored.json
```

The Apple worker uses the app's native adapter and the app's 1024-token chat output limit. The result records provider errors and successful Apple responses separately. If an app route is deterministic, a text-only shadow request records fresh Apple inference without changing the route verdict. A provider error remains a scored failure even when a separate shadow request succeeds.

## Compare a local trial model

For an OpenAI-compatible server bound to loopback, pass `--local-url http://127.0.0.1:PORT`, `--local-model MODEL`, and `--local-revision REVISION`. The model must appear under `/v1/models`. Freeze the Pi bundle and keep the same `--ids`, composer inputs, and fictional fixtures across trial models. Use `--local-reasoning none` where the server supports non-thinking mode. The default trial reasoning setting is low.

## Run the native boundary contracts

```sh
mkdir -p private/ai-evals/bin
xcrun swiftc -D BANANA_AI Banana/Pi/AssistantFreeTime.swift Banana/Views/Mail/MailCalendarReply.swift \
  Banana/Views/Mail/MailDraftPrompt.swift tools/pi-evaluation/first-use/NativeContracts.swift \
  -o private/ai-evals/bin/first-use-contracts
private/ai-evals/bin/first-use-contracts
xcrun swiftc Banana/Views/Mail/{MailDraftPrompt,MailDraftWorkflow}.swift \
  tools/pi-evaluation/first-use/ComposerWorkflowContracts.swift \
  -o private/ai-evals/bin/composer-workflow-contracts
private/ai-evals/bin/composer-workflow-contracts
```

This checks overlap handling, weekday and week-start resolution, DST wall times, absolute email timestamps, and grounded composer facts and links. The workflow contracts exercise source selection, citations, owner authority and when to withhold a draft using scripted model responses.

## Interpret the results

- **Pass** means a supported tool proposal met the explicit contract. This only establishes the behavior checked by that contract.
- **Gap** means the task remains unfulfilled, even if Banana explained the limitation or chose a tool that the native app cannot execute for the requested range.
- **Fail** includes wrong tools, wrong arguments, unverified actions, missing boundaries and malformed drafts.
- **Review** means basic checks passed and a reader still needs to assess meaning, factual grounding and usefulness.

The paired candidate checks report each selected case, including unsupported cases. A claimed improvement needs fixed evidence on that same case. Keep the original result even when adding a more accurate oracle or retesting a candidate. Report native store and UI evidence separately. The launch score should never count a fallback or an unrelated tool as a fulfilled task.

For a preregistered chat holdout, pass `--workflow-cases FILE`. The JSON array supplies unique IDs, prompts, expected outcomes, and optional fictional mail and calendar results. The runner records the input hash. A calendar result reaches the continuation only after the assistant asks to check the exact fixture interval. Inspect the initial proposal, `continuation`, and `afterCalendar` against the frozen criteria. The 500-case scorer uses the original catalog's contracts.

The fictional email matcher compares query and sender prefixes with the supplied fixture vocabulary. It does not execute the native index or prove live account scope, ranking, cache coverage or provider permissions. Use the native Mail tests for index behavior and a controlled account for provider verification.

### Native composer workflow

Run the Foundation-only contracts from the repository root.

```sh
scratch=$(mktemp -d)
swiftc Banana/Views/Mail/MailDraftPrompt.swift Banana/Views/Mail/MailDraftWorkflow.swift \
  tools/pi-evaluation/first-use/ComposerWorkflowContracts.swift -o "$scratch/composer-contracts"
"$scratch/composer-contracts"
rm "$scratch/composer-contracts"
rmdir "$scratch"
```

Each request stays on one same-device provider. A simple writing task can finish in one generation. Up to two native read operations can supply cached messages or extracted text from cached attachments. When the request explicitly requires a recognized source, the workflow requires that source before accepting a draft. Related searches use phrases grounded in the task or selected email. Implicit searches require an incoming reply with the original audience and a matching participant in the earlier correspondence. FTS matches, attachment extraction and source excerpts have bounded coverage. A missing source, invalid citation or unsupported recognized hard fact leaves the draft intact. Natural-language source recognition and semantic relevance still require evaluation on real examples.
