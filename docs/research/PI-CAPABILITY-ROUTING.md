# Mac capability routing

The 900-query audit exposed a shared failure: the model could substitute a nearby tool for an unavailable outcome, such as preparing a calendar event for a routine change or saving a note for a workout log. Additional prompt warnings did not reliably prevent this.

The local Mac provider now separates outcome selection from argument extraction. Both stages use the installed model; neither executes application capabilities. Pi still executes the final validated tool intent and native editors still require review before saving.

## Enforcement

1. The selector summarizes the requested outcome and identifies features it needs. The host handles unsupported requirements explicitly and checks that a selected tool belongs to the selected app domain.
2. Argument extraction sees only tools for that capability. Nutrition chart reads and filters remain together so existing chart context works. Navigation needs no second extraction call.
3. Every generation response is checked against the tools actually exposed in that stage. A conversation cannot smuggle in a write call; a read continuation can only read a referenced note, not prepare records.
4. Calendar day values are grounded in user input. Supported relative-day and ISO values are resolved without model date arithmetic; guessed dates are discarded from time-only inputs. Older input is eligible only during an active time clarification. Native calendar code computes the actual instant and next future occurrence.
5. Missing information produces a question, not an invented value. If the selector omits the missing-field discriminator, a separate inference-only call with a required finite schema repairs that field before the host chooses its question. Unsupported outcomes produce an explicit limitation, not a promise or a substitute draft. These are separate states.

This is not an exact-sentence lookup table. Selection remains model-based and can still misclassify intent; native validation and review are safeguards, not proof of perfect understanding. The policy does not add missing workout, routine, playback, account or record-editing integrations. The Apple Foundation Models provider is unchanged.

## Verification

- `capability-routing.test.mjs` checks the deterministic boundaries with malformed selections, wrong tools, no-tool conversations, read continuations, missing information, date evidence and stale conversation context.
- `benchmark.py --capability-routing` imports the production routing function, records both model responses, and measures total workflow latency. JSON object serialization matches the production transport. A raw one-shot model benchmark is not a test of this workflow.
- Full-app workspace checks assert that unsupported requests produce no native tool activities, drafts or records. Valid drafts, time clarification, navigation, search, native agendas, flight endpoints and cold restore are also exercised.
- The nutrition integration check covers chart filters and copying an existing meal into a new draft without saving it.

The initial preflight/focused/partial reports are retained with their policy snapshots. Interrupted runs are not full-suite results. Final results are recorded separately; a passing contract does not replace semantic review or visual testing.

## Native controls and draft provenance

Exact page commands and the chart’s finite metric, period and filter controls bypass freeform selection. Bounded command grammars also reject explicit stored-record edits and unsupported playback/workout controls; quoted note/search content and supplied prose are excluded. These grammars describe native capabilities, not fixture IDs.

Drafts retain their original user request as host-owned metadata. An unrelated follow-up cannot change the draft title or the words used by the event editor. The metadata survives cold restore and is omitted from model-visible action summaries. Plain replies remain visible above an existing object.
