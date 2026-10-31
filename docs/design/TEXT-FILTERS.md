# Natural language filters

Decision, October 21, 2026: accept natural sentences and turn them into editable filter chips. The chips explain the live query and can be changed directly.

## Interaction

1. Enter “Work meetings next week, excluding declined.”
2. Interpret into Calendar: Work, Type: Meeting, Date: Next week, Status: Not declined.
3. Show matching results automatically, without Interpret, Apply or Search buttons.
4. Edit or remove chips only when needed; each change updates results immediately. Ask which calendar or person when names are ambiguous.

Keep unresolved wording visible. Literal search text gets its own Text chip; an unsupported condition must be explained rather than silently discarded. Update chips and results after a brief typing pause (350 ms in the prototype). Cancel superseded interpretation work, preserve composition input, and reject stale responses. Switching modules preserves each module’s query. Clarification blocks ambiguous results rather than broadening the search.

Use one interaction across modules, with fields specific to the current module. Calendar visibility and access permissions remain separate from a result filter. A filter cannot expand access or reveal a guest's hidden fields.

## App implementation

Introduce a versioned, typed filter definition with a scope and predicates. Start with conjunctions and explicit exclusions; add grouped alternatives only when the parser, editor and each supported query adapter agree on their meaning. Field definitions declare value types, operators and module capabilities. Resolve people, calendars and accounts to stable IDs.

Natural language interpretation proposes this definition. Deterministic code validates it and compiles it into each module's query. Follow the typed extraction and validation direction already described in `CHAT-ASSISTANT-PLAN.md`. Unsupported fields or conditions block application with an actionable explanation. Never pass model-generated query fragments into SQL, FTS or provider APIs.

Calendar search currently requires nonempty text in `CalendarSearchQuery.isValid`. Filter-only searches will need an explicit valid structured-query path, retaining bounded dates, recurrence handling and result limits. Email already has `MailScope` and typed `MailFilter` values; extend supported capabilities deliberately. `MailLocalSearchQuery` has literal text-prefix semantics, so language such as “from Alex” needs an actual sender predicate. Notes should retain revision-aware search and paging. Workout filters need to map to the stored workout fields, not labels inferred from display text.

Evaluate relative dates with the user's timezone, calendar and week-start preference. A saved “next week” remains relative; a fixed date interval remains fixed. Show the interpreted interval in the editor. Sync the canonical definition, including its version and date policy, across surfaces. Treat the original sentence as optional provenance, not executable state. Reject unsupported definition versions rather than broadening results silently.

On Apple platforms use native search tokens and ordinary field editors. SwiftUI supports [search text, tokens and suggested tokens](https://developer.apple.com/documentation/swiftui/view/searchable%28text%3Atokens%3Asuggestedtokens%3Aplacement%3Aprompt%3Atoken%3A%29). Web should expose the same fields, labels and predicate meaning. Keep module queries bounded and indexed; tab changes should restore state without repeating interpretation or fetching unchanged results.

## Review prototype

Open `/filters/` on the existing calendar mockup server. It demonstrates Plan, Email, Notes and Workouts, ambiguous people, direct chip editing, live results and per-module state restoration.

The browser prototype uses sample records and a small deterministic vocabulary, with a fixed October 21, 2026 clock and Monday week boundaries. It does not implement production natural language understanding, arbitrary boolean expressions, account resolution, persistence or sync. No production app behavior changed.

Before shipping, verify real query parity, filter-only queries, duplicate names, exclusions, unknown wording, grouped conditions, timezone/week boundaries, permission boundaries, keyboard/VoiceOver use, cross-device round trips and stable results on tab return.

## Implementation — build 68

The shared grammar lives in `Shared/LiveFilterRules.json`. Run `python3 tools/generate-live-filter-rules.py` when changing it; the service suite checks the generated web grammar against that file. Apple bundles the same JSON. `LiveFilter` is the versioned typed definition, with explicit capability validation. The current implementation runs locally without a language model or an interpretation service. Supported phrases become conditions; remaining words stay visible as text. Quoting a phrase keeps it literal.

Native Calendar, Notes, Workouts and the separate Beta app's Mail use `LiveFilterSearch`. Typing is local to that control; after a 200 ms pause, parsing runs away from the UI thread. A superseded parse cannot replace newer results. Chips can be changed or removed without an Apply step. Calendar date predicates replace the optional manual date range. Calendar search automatically continues through empty provider pages to find the next matching page, retaining one provider page. Notes predicates run before SQL counting and paging. Mail binds typed conditions to its existing downloaded-header index and retains account/keyset boundaries; flag-only searches use the thread index. Its text and sender search retain the module's documented word-prefix behavior. Workout queries use the existing deduplicated, visible workout records and prepare validation/date predicates once per result set.

Web Plans, Notes and Workouts use the same grammar and condition labels. Plans searches the entire selected relative interval, using bounded calendar reads of at most seven local days per request and a result list for filtered events. Without a date condition, its visible day/week is the search range and is shown above results. Calendar results respect visibility and guest projection before filtering. Busy-only guest events cannot acquire hidden titles, people or calendar provenance through filters. Other web sections retain literal text search. The web app has no Mail module yet; this change does not introduce one.

Relative dates use the current timezone and the account's week-start setting. The Apple definition records that week-start policy; notes' loaded-page/cache keys also include the resolved day boundary. Active search state is transient. This change supplies a shared definition/grammar, not a saved-filter library or cross-device sync of each keystroke. Saved definitions can use this versioned model when saving is introduced.

The initial language supports date intervals, calendar inclusion/exclusion, meeting/all-day/response conditions, sender words, read/star/importance flags, archive state, workout activities and duration comparisons. Grouped alternatives and arbitrary sentences remain outside this first grammar; unhandled wording is visible as text. Conflicting conditions block results. Duplicate calendar names require an account-qualified name, e.g. `Work (person@example.com)`. Canceled event tombstones cannot be displayed by the calendar adapter; that positive condition is explained rather than reported as an exhaustive empty result. Excluding canceled events is supported.

The web calendar catalog has an explicit loaded state, including an empty successful result. Refresh/account changes invalidate it. The isolated preview supports `BANANA_PREVIEW_PORT`, `BANANA_PREVIEW_EMPTY_CALENDARS=1`, and the tooling-only `BANANA_PREVIEW_FILTER_CATALOG_REFERENCE=1` ablation. Visiting Plans, typing `meetings today`, typing `with Alex today`, then refreshing made four catalog requests with the reference guard and two with the loaded-state guard (one initial read, one explicit refresh). Both flows returned the same results. This checks request reuse, not UI/frame latency.

Calendar windows also share in-flight reads between sentences. `CalendarWindowCache` retains at most eight windows, removes failed reads, aborts work on eviction/invalidation, and prevents an obsolete rejection from erasing a newer read. The window's request mode is captured before fetching, so editing the sentence during a multi-page month fetch cannot mix visibility modes. A controlled deferred-read ablation starts three loads with the former resolved-only cache and one with the shared pending cache, returning identical results. The service tests cover that count, empty results, retry, eviction and invalidation signals; no frame-time improvement is inferred.

The web prepares date bounds and workout aliases once per render and bypasses row serialization for an empty filter. A 10,000-row comparison checks prepared and per-row predicates return identical results; raw component samples are retained without treating them as UI latency measurements. Superseded Notes and Workouts renders cannot replace the current view. Final service validation: 255 tests pass under UTC and America/New_York. The final 390-pixel browser smoke returned one Training meeting today with no submit/apply step.

## Rollout and remaining validation — October 21

Native source `6e156b53`, build 68, is installed and independently verified on Mac, iPhone and iPad in both main and Beta. Signatures and production/Beta email gates pass. Targeted phone/iPad UI checks and seven selected repository/model tests pass; 21 phrase fixtures agree between Swift and JavaScript. Web source `84a77b75` is deployed: production Worker `ea4e210f-2843-4872-be03-ba505cc7109f`, Beta `624f4415-de53-4bec-bedb-b001e76b69bd`.

Evidence, raw test results, component measurements, screenshots, binary audit and deployment logs are retained in `~/Library/Logs/Banana/LiveFilters-20261021`. Installed symbols are retained; disposable build output was cleaned. The performance gate is unmeasured because installed Xcode 27.1 differs from the reference 27.0; component measurements do not certify physical frame/input budgets. Full TestFlight checks and publishing remain pending.

The Watch did not connect for installation; the author requested leaving it for later. Follow-up source `4646a310` repeats the rest timer completion notification haptic three times, 1.2 seconds apart, canceling on restart/end. watchOS controls intensity. Its device-target compile passes; physical haptic feel and installation remain pending.
