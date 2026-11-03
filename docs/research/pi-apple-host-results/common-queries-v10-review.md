# Common-query evaluation

900 synthetic development routing/argument contracts, 100 per module. 20 intent families × 5 variants; not empirical top-query rankings, not held-out accuracy, and not end-to-end action tests. Text-only responses require semantic review. Capability gaps are labeled explicitly.

Final 900-case contract qualification: 55 fresh v10 model runs and 845 verified replays from v9 qualification. The v9 source itself used 96 fresh runs plus 804 verified v8 replays. Every replayed model request is checked against the archived policy. This is not a fresh 900-call run, production accuracy, or execution of app tools.

Evidence counts: {"verified_replay": 845, "fresh_inference": 55}

This run evaluated 900 queries. Documented oracle corrections are applied without changing the raw responses; see the JSON report.

Automatic checks verify routing, arguments, schema, missing-input behavior, and some false completion claims. Text replies below still require semantic review. A navigation fallback does not implement the requested capability. No app tools execute in this benchmark; native/full-app tests are separate.

| Module | Tested | Tool contracts passed | Honest navigation fallback | Text to review | Contract failures | Capability-gap cases |
|---|---:|---:|---:|---:|---:|---:|
| plan | 100 | 45 | 0 | 55 | 0 | 45 |
| nutrition | 100 | 55 | 0 | 45 | 0 | 30 |
| notes | 100 | 60 | 0 | 40 | 0 | 30 |
| workouts | 100 | 25 | 0 | 75 | 0 | 70 |
| routines | 100 | 25 | 0 | 75 | 0 | 70 |
| library | 100 | 25 | 9 | 66 | 0 | 70 |
| review | 100 | 25 | 0 | 75 | 0 | 70 |
| settings | 100 | 25 | 23 | 52 | 0 | 70 |
| assistant | 100 | 15 | 0 | 85 | 0 | 25 |

## Failures

