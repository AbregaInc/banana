# Common-query evaluation

900 synthetic development routing/argument contracts, 100 per module. 20 intent families × 5 variants; not empirical top-query rankings, not held-out accuracy, and not end-to-end action tests. Text-only responses require semantic review. Capability gaps are labeled explicitly.

900-case qualification: 804 cases use recorded responses only after verifying every consumed model request is unchanged; 96 cases use fresh inference on the final host policy. This is not a fresh 900-call model run and app tools do not execute.

Evidence counts: {"verified_replay": 804, "fresh_inference": 96}

This run evaluated 900 queries. Documented oracle corrections are applied without changing the raw responses; see the JSON report.

Automatic checks verify routing, arguments, schema, missing-input behavior, and some false completion claims. Text replies below still require semantic review. A navigation fallback does not implement the requested capability. No app tools execute in this benchmark; native/full-app tests are separate.

| Module | Tested | Tool contracts passed | Honest navigation fallback | Text to review | Contract failures | Capability-gap cases |
|---|---:|---:|---:|---:|---:|---:|
| plan | 100 | 45 | 0 | 55 | 0 | 45 |
| nutrition | 100 | 55 | 0 | 45 | 0 | 30 |
| notes | 100 | 60 | 0 | 40 | 0 | 30 |
| workouts | 100 | 25 | 0 | 75 | 0 | 70 |
| routines | 100 | 25 | 0 | 75 | 0 | 70 |
| library | 100 | 25 | 18 | 57 | 0 | 70 |
| review | 100 | 25 | 0 | 75 | 0 | 70 |
| settings | 100 | 25 | 23 | 52 | 0 | 70 |
| assistant | 100 | 15 | 0 | 85 | 0 | 25 |

## Failures

