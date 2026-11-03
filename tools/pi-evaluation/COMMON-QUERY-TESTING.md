# Common-query qualification

The development corpus has **900 queries: 100 each for Plan, Nutrition, Notes, Workouts, Routines, Library, Review (including Sleep and Trends), Settings, and Assistant**. Each module has 20 intent families exercised with five entity/phrasing variants. These are synthetic common-use cases, not a frequency-ranked list from user telemetry and not an independent held-out accuracy benchmark.

## Principles

- Distinguish reading, navigating, preparing a new draft, and modifying an existing record. A new draft is never a substitute for an unsupported edit or cancellation.
- Require the necessary information before an action. Preserve exact quoted note text; do not invent quantities, personal measurements, a date, invitees, or successful effects.
- Treat tools as a capability boundary. Opening a page is a fallback, not completion of a request to change the data on that page.
- Let native code resolve relative dates and convert times. Store absolute instants together with source IANA timezone identifiers. Show which timezone an agenda uses, and preserve distinct departure/arrival zones. Include intervals crossing midnight; distinguish repeated DST hours.
- Present structured tool results in native views rather than asking the language model to reproduce a table of times or records.
- Keep development fixtures in their own labeled workspace. Fixtures should contain both ordinary records and meaningful boundaries: sparse logs, overlapping windows, missing values, overnight flights, and dates on either side of DST changes.
- Require native review before persisting model-generated meals, events, or notes. A mistaken tool selection must not silently create a record.
- Check state, not claims: an effect is only complete after native persistence succeeds; a populated store is not proof that its calendar grid reads it.

## Layers of evidence

1. **Model contracts:** one-turn local inference; check the selected tool, argument schema, dates, literal values, required fields, and some false completion claims. App tools are never executed in this benchmark.
2. **Native contracts:** the full-app sample check verifies populated stores, calendar cache/refresh behavior, time formatting in New York/London/Tokyo/Kathmandu, repeated DST hours, and flight serialization and duration across differing US/UK DST schedules.
3. **App flows:** real model → native tools → persisted conversation and drafts. Checks include native tomorrow agendas, source timezones on a future flight, cold reopen, clarification, deduplicated saves, and unchanged personal files.
4. **UI review:** validate readable native layout on the actual app. A build or headless check does not establish visual correctness. Desktop automation was unavailable during this run.

Text-only replies are placed in a semantic-review queue. They are not automatically declared correct because they are nonempty. Capability-gap cases remain marked as gaps even when the model gives an honest limitation or a navigation fallback. Reports expose both the failures and the review queue; there is no single inflated “accuracy” figure.

## Reproduce

```sh
node tools/pi-evaluation/generate-cases.mjs ../pi-upstream
python3 tools/pi-evaluation/generate-common.py
uv run --with jsonschema==4.25.0 python -m unittest discover -s tools/pi-evaluation -p test_common_contracts.py
```

Use `benchmark.py --fixture tools/pi-evaluation/common-queries-v1.json --repeats 1` with the pinned runtime/model arguments documented in the main README. It writes every result immediately, retains raw replies, bounds each request, and releases only its own worker. Run one model worker at a time. The baseline and preflight reports are partial exploratory runs, stopped after identifying shared problems and corpus issues; they are not comparable full accuracy baselines.

```sh
uv run --with jsonschema==4.25.0 python tools/pi-evaluation/summarize-common.py \
  docs/research/pi-apple-host-results/common-queries-v1-current.json \
  --output docs/research/pi-apple-host-results/common-queries-v1-review.json
```

The summary verifies the fixture hash, records the scorer hash, reports all nine modules separately, retains failure responses, and generates a readable query catalog. The original model responses remain unchanged when a contract is corrected (for example, treating `tomorrow` and its exact ISO date as equivalent).

The model suite uses a fixed date and actual tool registrations. It is intentionally not a claim to cover all conversational state, device locale settings, provider failures, or live integrations. Add separate fixtures and full-app regressions when a new failure class appears, rather than memorizing a single sentence in the prompt.

## Recorded results

See [the qualification report](../../docs/research/PI-COMMON-QUERY-RESULTS.md) for the broad 900-query run, focused 185-query follow-up, semantic sample, and remaining limitations. Frozen v1/v2 fixtures preserve the exact prompts used for those runs; generate subsequent fixtures under a new filename.

## Capability routing (Mac)

The Mac provider now classifies the requested outcome before argument extraction. It records required features, rejects unsupported requirements and domain/tool mismatches, and exposes only the relevant capability's tools. Chart reads and chart filters share a capability; no unrelated draft tools are available. The selector itself cannot execute any app capability. Navigation uses a native tool intent, unsupported operations use explicit limitation text, and read continuations cannot gain write tools.

Calendar day arguments require user evidence. The host recognizes the native API's relative-day/ISO vocabulary, strips invented days from time-only requests, and only reuses older date input during a pending time clarification. Native Swift still computes the actual calendar instant and next occurrence. This is value validation, not a catalog of exact query matches.

Use `benchmark.py --capability-routing` to run the production JavaScript routing function, not merely the original one-shot model prompt. The runner records both inference stages, source hashes and total latency. Its JSON serialization preserves the production transport's sorted object keys. This changes the workflow being measured; do not compare raw generation latency as if it were the same single call. The routing policy is still a model classifier, so refusal or clarification is not proof of correct understanding; supported cases and semantic review remain necessary.

`node --test tools/pi-host-proof/runtime/capability-routing.test.mjs` checks capability isolation, malformed choices, cancellation, grounded dates, clarification context, and conversation/read-only tool boundaries. The full-app workspace verifier additionally checks unsupported requests produce no tool effects or stored records. The policy currently applies to the local Mac provider; the Apple Foundation Models provider is unchanged.
