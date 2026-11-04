# Pi query and travel qualification

See [the public rebase and clock repair](PI-PUBLIC-REBASE.md) for the subsequent integration and its validation. Results below are retained historical evidence.

The development corpus contains 900 synthetic queries, 100 for each of nine modules. These are common-use scenarios with phrasing/entity variants, not an empirical top-100 ranking or held-out accuracy measurement.

## Pre-rebase capability-routing qualification

Installed the verified Mac build at `~/Applications/Banana Pi.app` on 3 November 2026.

The Mac provider now separates capability selection from argument extraction, exposes only the selected tools, validates calendar-day evidence, and handles finite page/chart controls directly. Unsupported record changes and playback/workout controls return limitations instead of substitute drafts. Missing clarification fields are repaired with an inference-only required schema. Drafts retain the request that created them, even after unrelated messages and cold restore. See [the implementation principles](PI-CAPABILITY-ROUTING.md).

The [v10 contract report](pi-apple-host-results/common-queries-v10-review.md) contains **900 cases with zero automated contract failures**: 300 tool-contract passes, 32 navigation fallbacks, and 568 text replies requiring semantic review. It combines **55 fresh v10 model runs with 845 verified replays** of prior responses. The preceding v9 qualification combined 96 fresh runs with 804 verified v8 replays. Replays verify every consumed model request against archived source before reusing its response; changed requests require live inference. This is deliberately not described as a fresh 900-call final run. Reports retain source hashes and raw evidence.

The [readable 900-query catalog](pi-apple-host-results/common-queries-v10-review-catalog.md) is a development regression corpus, not proof of production accuracy. Passing unavailable-action cases means the app states its limitations; it does not implement missing integrations. Native/full-app checks are separate because benchmarks never execute app capabilities.

A separate [25-paraphrase live run](pi-apple-host-results/routing-fresh-v10.json) passed all tool contracts. Manual review rated 20 acceptable, four partially acceptable (generic refusal wording), and one incorrect general explanation of daylight saving time. This small follow-up is not a held-out accuracy estimate.

Manual review checks meaning beyond schemas. [Known semantic limitations](pi-apple-host-results/routing-semantic-review.json) include occasional vague replies to ambiguous requests, interpreting quoted context as a conversational instruction, and imprecise general explanations. The ten checked meal-draft responses preserved both food quantities. These findings prevent treating a zero-contract-failure score as “every answer is correct.”

The final [v10 full-app workspace verification](pi-apple-host-results/routing-v10-workspace.json) passed with the real local model: missing-time and missing-amount clarification, time-only next occurrence, tomorrow agenda and cold restore, source timezones and future flight endpoints, note review/save deduplication, original-request provenance after an unrelated message, and seven unsupported outcomes with no tool effects. Personal history, meals, selection, and draft were unchanged outside the isolated verification store. No external calendar writes were attempted. The worker released its resources on exit.

The [v10 nutrition integration](pi-apple-host-results/routing-v10-nutrition.json) also passed: native chart grounding, natural chart/search queries, weekday/comparison filters, selected-meal copying, deduplicated reviewed save, and cold restore. Personal history and selection were unchanged outside the verification store.

The Mac build, 33 routing unit tests, 13 workspace conformance checks, 12 provider conformance checks, and 10 evaluator tests passed. Desktop automation remained unavailable, so this does not claim visual verification.

## Historical model runs (before capability routing)

| Run | Queries | Tool contracts passed | Honest navigation fallback | Text needing review | Contract failures |
|---|---:|---:|---:|---:|---:|
| Broad v1 | 900 | 273 | 138 | 288 | 201 |
| Focused v2 | 185 | 98 | 1 | 29 | 57 |

The focused run covers Plan, navigation, note creation, selected nutrition inputs, and unsupported workout/routine changes after refining shared instructions. It is a different subset, not a comparable overall accuracy score. It still fails substantially; instruction changes alone are insufficient. The final note review flow was added afterward and tested in the full app, not rerun across all 900 prompts.

[All 900 queries](pi-apple-host-results/common-query-catalog.md), [broad failures](pi-apple-host-results/common-queries-v1-review.md), and [focused failures](pi-apple-host-results/common-queries-v2-review.md) retain the evidence. Five mistaken Assistant-navigation expectations were corrected without altering the original model responses. Date aliases equivalent to the fixed reference date are accepted.

A nonexhaustive [manual review of 35 text responses](pi-apple-host-results/common-query-semantic-sample.json) found 22 acceptable, 8 failing, and 5 partially acceptable. Text responses outside that sample are not established as correct. These model runs do not execute app tools or prove end-to-end effects.

## General fixes verified in the app

- Daily schedules use structured native agenda rows. Native code resolves relative days and formats absolute instants in a labeled timezone; the model does not rewrite event times.
- Calendar windows include overlapping intervals, including an overnight flight on its arrival day.
- Fixtures include a fictional JFK–London flight three days ahead and a return flight. Departure/arrival IANA zones survive import, persistence, and agenda rendering, and drive the calendar secondary timezone.
- Timezone comparisons examine daylight-saving transitions throughout the trip. Two zones sharing an offset at arrival can diverge later.
- Model-generated notes now require native review and Save, matching meal/event drafts. Mistaken tool selection cannot silently save a note through the real-model tool path.

The final [full-app local-model verification](pi-apple-host-results/agenda-notes-final-workspace.json) passed: tomorrow agenda and cold restore, future flight source zones, next-occurrence event time, missing-time clarification, draft transitions, no-write note preparation, deduplicated reviewed saves, and unchanged personal history. The model worker exited cleanly; no external calendar writes were attempted. Eleven trip-timezone tests and ten evaluator tests passed. Sample-store checks passed, including cache refresh and overnight arrival-day inclusion. The Mac build passed. Desktop automation was unavailable, so visual layout has not been verified.

## Historical findings that motivated capability routing

The model still substitutes new calendar events for unsupported edits, routines, or workout logging, sometimes invents dates/quantities, and sometimes claims information without reading it. Native review limits accidental persistence but does not make those answers correct. Unsupported capabilities need explicit product behavior; supported operations need better routing and argument fidelity before this can be called broadly reliable. Track these as capability and behavior classes, with frozen clocks, source-timezone fixtures, and state assertions, rather than adding a special case for each sentence.
