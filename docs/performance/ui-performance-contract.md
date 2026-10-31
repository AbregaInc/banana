# UI performance contract

These are product requirements, specified by the user on October 7, 2026. They apply to
macOS, iPadOS, and iOS, including large retained histories. They are acceptance targets,
not a claim that the current app already meets them.

## Required budgets

| Work | Target | Slow-case limit | Acceptance rule |
| --- | --- | --- | --- |
| Rendering on a 120 Hz display | **8.3 ms or less per frame** | No intentional missed-frame allowance | Measure frame work and missed deadlines during real interaction. A slow frame is a regression to investigate. |
| Direct manipulation: scrolling, drawing, typing, dragging, selection feedback | **Under 10 ms for most responses** | **20 ms** | Immediate input feedback must stay within this budget; do not wait for persistence, networking, or full-history queries. |
| Other UI responses: opening a detail, switching a view, showing a page, applying an action | **About 32 ms**, with **50 ms** the general goal | **100 ms** | **Any measured UI response over 100 ms is a hard failure.** A good average or percentile does not excuse it. |

For repeatable tests, report every observed maximum and p50/p95/p99. Use p95 under 10 ms as
the operational definition of “most” direct-manipulation responses, and flag any response over
20 ms. Preserve individual failures and sample counts rather than hiding them in averages.
The 100 ms ceiling applies to every measured UI response, including cold-cache interactions.

A frame budget and an interaction budget measure different things. Finishing a database query
in 8 ms does not establish that a frame was displayed in 8.3 ms. Finishing a tap handler in 5 ms
does not establish that the user saw its result within 10 ms.

## What counts as a response

Measure from input delivery to the first visible, correct response. Also measure time until the
requested content is usable. Record these separately: an immediate spinner is useful feedback,
but it must not disguise a slow local navigation, search, or page transition.

Local UI work must meet the budgets above. Network transfers and long-running processing can
continue asynchronously; show their state promptly, keep the interface usable, and measure their
completion separately. A slow external operation is not permission to block the UI thread.

For continuous input, measure the entire interaction, including sustained scrolling, typing
bursts, drag updates, drawing, and deceleration. Include simultaneous playback, sync, and incoming
updates. Test steady state, first use, cold caches, warm caches, and recovery after memory pressure.

## Implementation requirements

- **Cache reusable data and prepared presentation work.** Persist the full retained history on
  disk; keep bounded working sets in memory. Cache decoded bodies, artwork, formatted content,
  query results, and layout work where useful. Give every cache an explicit invalidation rule,
  ownership, and eviction policy. Do not trade frame stalls for unbounded memory growth.
- **Preload and prerender likely next content.** Prepare adjacent pages, likely destinations,
  image decoding, and expensive presentation work ahead of demand. Reuse that work when the
  user acts. Keep speculative work cancellable, bounded, and lower priority than current input.
- **Keep expensive work off the immediate input path.** No whole-history decode, sort, search,
  synchronous network access, or large persistence operation inside view bodies or input handlers.
  Disk paging alone is insufficient if each redraw or sync callback reloads the entire history.
- **Render only what changed.** Isolate playback clocks, download progress, and other frequent
  publishers to the small views that display them. Suppress identical state publications, avoid
  notification feedback loops, and cancel obsolete work when a query or selection changes.
- **Optimistic actions are allowed when failure is durable.** Preserve the user's intent or draft
  and a recoverable pending operation. An acknowledged action must not silently disappear after a
  write failure, crash, relaunch, or offline period. Use a durable pending-operation/outbox record
  where needed, idempotent retries, explicit reconciliation, and visible retry/undo/error states.
  If local durability fails, do not report the action as successfully saved or discard its draft.
- **Correctness survives optimization.** Preserve ordering, search semantics, selection, edits,
  completion state, and restore behavior. Never truncate user history to pass a performance test.

## Required evidence

### Integration and user-testing readiness

The October 10 acceptance scope is **all three device families: Mac, iPad, and
iPhone**. Calendar Day and Week must use the integrated native implementation by
default, without a user opt-in or launch flag. Diagnostic reference paths may
remain for controlled comparisons. Follow Calendar with fully integrated Mail.

Track integration, functional validation, and measured performance separately for
each device family. One passing device, a standalone renderer benchmark, or a
fixture-only build does not establish completion across the app. Record the exact
build, device/OS, workload, result paths and remaining failures for every review
build. Untested workflows and devices remain incomplete.

Calendar coverage includes viewing and event reachability, Day/Week switching,
scrolling and paging, creation, editing, moving, recurring/overnight events,
live updates, and durable failure/retry behavior. Cover Mac window resizing and
keyboard interaction, iPad rotation and split-window resizing, iPhone rotation,
and accessibility on each platform. Mail coverage includes connected account
data, bounded full-history paging, selection and detail, search/filter changes,
live updates, and durable actions. Sample-data previews must be labeled as such.

Functional readiness and performance acceptance are distinct: neither may be
reported as complete based on evidence for the other. Physical-device frame and
input acceptance remains required on all applicable platforms under the budgets
above; Simulator correctness checks do not close it.

Use Release-optimized builds and representative workloads, including the simultaneous overload
of **2,000 emails/day and 100 calendar events/day**, plus notes and podcasts. Increase retained
history independently of the visible page size. Keep workload counts, device/OS, display refresh
rate, build identity, cache state, and background activity with each result.

Use Instruments and suitable device-side frame/interaction measurements on real 120 Hz hardware
for final acceptance. Cover iPhone, iPad, and desktop layouts. Report CPU/render work, frame
hitches or missed deadlines, and input-to-visible-response latency separately. A CADisplayLink
callback interval measures scheduling/cadence; it does **not** by itself prove compositor delivery,
GPU completion, or input-to-photon latency. Variable refresh rate must be recorded rather than
misclassified as a missed 120 Hz deadline.

Simulator measurements and XCUITest are useful regression and correctness checks. Gesture wall
clock includes automation overhead; idle redraw counts are not frame timings. Neither proves
120 Hz compliance. Do not mark an unsupported measurement as passing: report it as unmeasured.

Performance gates must fail on observed budget violations. Do not raise thresholds, discard slow
samples, average away failures, or silently substitute cached data that is incorrect or stale.
Retain failing results, diagnose the cause, fix it, and rerun the affected scenarios.

The October 8 implementation requirement is to **performance-test each optimization individually**.
Retain a reproducible before/after comparison or controlled ablation, its correctness evidence,
raw timing tails/maxima, cache state and memory cost. Measure the integrated interaction as well:
several faster components can still compose into a slow UI. Keep alternatives when needed for
comparison, but do not call added complexity an improvement without supporting measurements.
Cold loading, cache eviction and recovery remain in scope even when warm scrolling improves.

## Current validation boundaries

The [scale stress harness](scale-stress.md) currently measures model-operation latency, Simulator
peak RSS, paging correctness, UI navigation, and unrelated redraws during synthetic playback-clock
updates. Its existing model-query budgets are component checks, not substitutes for this contract.
Some are as high as 100 ms and leave no time for the rest of the UI response.

The harness's **900 MB Simulator RSS ceiling is an implementation-specific test guardrail**, not
an iOS memory limit, not a user-selected memory budget, and not a physical-device acceptance target.
Set device memory budgets from measured working sets while keeping all interaction budgets intact.

Real 120 Hz frame delivery, full input-to-visible-response latency, live provider sync, and durable
optimistic recovery still require explicit scenario coverage. Until measured, they remain open
acceptance work rather than implied passes from model tests.

## Machine-readable acceptance gate

`tools/ui-performance-gate.py` evaluates supplied frame-work and input-to-visible-response samples
against this contract. It is an evaluator, not a timing collector. Use trustworthy device traces;
do not feed it callback gaps, query timings, automation gesture durations, or invented samples.

```sh
python3 tools/ui-performance-gate.py measured-ui-timings.json --out ui-verdict.json
```

The script's help documents the input JSON. Each scenario identifies its kind (`frame`, `direct`,
`ui`), cache state, and all timing samples in milliseconds. Results retain p50/p95/p99, maximum,
and every over-limit sample. UI responses between 50 and 100 ms are explicitly marked as missing
the goal even when they stay below the hard ceiling. Direct-response p95 of 10 ms or more fails.

Exit codes: **0** = supplied scenarios meet hard limits and required coverage; **1** = observed
budget failure; **2** = invalid input or unmeasured acceptance (including Simulator-only evidence,
a display below 120 Hz, or missing cold/warm interaction or frame samples). A passing submitted
report does not certify other devices, screens, workloads, or scenarios that were not measured.
The evaluator's synthetic unit-test fixtures validate boundary handling only; they are not app
performance evidence.
