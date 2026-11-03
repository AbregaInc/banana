# Health web view audit — 2026-11-03

The coach view uses the same client as the owner's web view, with server-side section
projection. Viewer display choices must never expand those permissions.

## What exists, and what the web exposes

| Area | Existing data / native behavior | Web result in this change | Remaining gap |
| --- | --- | --- | --- |
| Activity | Steps, active/resting energy, exercise minutes, flights climbed, walking speed | Independent 7/30/90/365-day ranges and daily/weekly/monthly grouping; preceding-period ghost traces; daily averages, coverage and clickable buckets/readings | Native correlations |
| Heart and recovery | Resting HR, HRV, respiratory rate, VO₂ max, walking HR | Selected-range averages, ghost traces and individual daily summaries | Native adaptive-wake recovery calculation is not a standalone synced recovery score |
| Body | Weight, body fat, lean mass, BMI, height | Selected-range readings and ghost traces; units follow the existing distance-unit preference | Native weight trend / energy-balance analysis; height in inches rather than native feet/inches |
| Sleep duration | Daily sleep hours and detailed nights | Range/group controls, duration ghost traces and nightly duration | Daily series and detailed nights can have different retained history |
| Sleep timing | First recorded sleep and final wake, plus wake-up intervals and steps | Clickable nights and wake-ups, onset/wake timestamps, awake time within the night | These are not actual bedtime/time-in-bed; no REM/deep-stage breakdown in this snapshot |
| Sleep consistency | Night timestamps/durations exist; no existing consistency score was found | New descriptive range of sleep onset, wake time and duration across the selected range’s recorded nights | No clinical interpretation, quality grade or target is inferred; at least two nights required |
| Sleep quality context | Native `SleepNights` computes awake time, longest stretch, first bathroom trip, trip counts, and classified wake-ups | Awake time and neutral recorded interruptions are exposed | Longest stretch / bathroom / baby labels depend on native classification and personal settings; do not present raw guessed labels as confirmed |
| Workouts | Merged native recordings and Apple Health history; detailed charts, route, lap/SWOLF, splits, weather, comparisons, full recording | Day/week browsing; Health now opens the same rich workout details as Workouts instead of the old thin history detail | Native motion playback, edit/revert workflows, planned-versus-completed training reports |
| Food | Meals, photos, notes, per-item calories/protein/carbs/fat, source, estimates, references, saved foods | Day/week meal browsing and logged macro totals; existing clickable meal details retained | Per-item macro columns, provenance/estimate corrections, goals and native nutrition completeness report |
| Nutrition completeness | `EnergyBalance` uses 28 completed days, weight/energy coverage and plausibility gates; `EstimateLedger` tracks corrections | Audited, not ported | Requires faithful parity tests, coverage rules and authorization to combine Food and Health; a simple intake-minus-exercise subtraction would not reproduce it |
| Taken | Supplement/medication schedules, ingredients, timing anchors; taken/skipped logs with authored day | Day/week dose browsing, preserving authored day across time zones; readable dose details and ingredients | Timing-anchor presentation, native interaction/clash analysis; no inferred adherence percentage |

Sources inspected: `Banana/Model/HealthWorkout.swift`, `HealthKitStore.swift`,
`SleepNights.swift`, `EnergyBalance.swift`, `SmartScheduleStore.swift`,
`Banana/Views/ReviewView.swift`, `TrendViews.swift`, `SleepView.swift`,
`Shared/WellnessModels.swift`, and the existing web workout model/view and sharing projection.
All 17 base Health series were already present on the web; the main omissions were
period navigation, detail access and derived context, not missing base metric types.

## Behavior and boundaries

- Health has independent visible-range and grouping controls: 7/30/90/365 completed
  days, grouped by day, week or calendar month. Food, Workouts and Taken retain
  day/week log browsing. Date navigation reaches retained history.
- Daily Health points are aggregated snapshot readings, not raw sensor samples.
  Following native MetricTrends, cumulative metrics show daily averages, counting
  missing days as zero only after the first-ever recorded point. Sampled metrics
  average available readings and leave gaps unknown. Today is excluded.
- A dashed ghost trace shows the preceding equal-length window on the same vertical
  scale, aligned by elapsed days. Weekly buckets start at the range boundary; monthly
  buckets follow calendar months with partial edge months. Grouping does not change
  headline summaries. Buckets open their underlying daily readings.
- Date boundaries and sleep clock times use the browser's explicitly displayed time
  zone. Dose logs use their authored calendar day when available. Snapshot points do
  not carry a separate source time-zone identifier.
- Health metric visibility is saved in browser storage per viewer account and share.
  Native details/checkboxes/date inputs provide keyboard interaction without a new UI
  library. Choices do not alter the owner's sharing policy or other viewers' layouts.
- Routine status polling is limited to once per five minutes while visible; tab-return checks share that limit. A data change offers
  **Updates available · Refresh** without replacing content, shifting focus or closing
  details. Refresh explicitly applies it. Sharing/consent changes invalidate on the next check;
  revoked/expired access still clears private content. Polling also checks while a
  detail is open. A browser back-forward-cache restore still reloads to recheck access.
- No server permission, native app implementation or deployment changed. Content revisions use the existing space metadata table; no schema migration is required.

## Verification

- `Service/test/web-health.test.js`: calendar/DST boundaries, Swift epoch decoding,
  missing/zero readings, cumulative versus sampled aggregation, midnight timing ranges,
  interrupted nights, authored dose days, unit conversion and refresh invalidation.
- `Service/tools/web-health-browser.mjs`: synthetic-data headless browser tests for
  day/week browsing, summary/reading/night/wake details, saved preferences, separate share
  preferences, consent withdrawal, meal details and a 390 px viewport.
  Set `PLAYWRIGHT_MODULE` to an installed Playwright package and optionally
  `PLAYWRIGHT_CHANNEL=chrome`; no personal browser profile is used.
- Refresh ablation: extract the previous `app.js` with `git show`, set `WEB_APP_SOURCE`
  to that file, and run the browser tool with `--refresh-only`; repeat without the override.
  Five identical sync-timestamp changes produce **10 content child-list mutations before,
  0 after**. This establishes suppression of background content replacement, not a frame
  rate or input-to-visible latency improvement. Both versions retain the existing snapshot
  cache and explicit-refresh invalidation; no new data cache or eviction policy is added.
- Local artifacts, including failed attempts, are retained under
  `private/coach-validation/`. Service tests run in UTC and America/New_York.
  Physical-device frame/input performance remains unmeasured.

Initial validation: 300 service tests passed in each of UTC and America/New_York; the
headless browser suite passes, including shared-view isolation and dose details.
The required native Simulator component suite **fails** its unchanged baseline:
RSS tolerance failures in scale-1d, scale-7d, redraw-library, redraw-plan and redraw-mail;
competing workload/incomplete-monitoring failures in scale-30d, scale-90d and redraw-mail.
The exact verdict is `private/coach-validation/components/gate.json`, with measurements
and host reports beside it. Native sources were not changed. No baseline was replaced,
no failed scenario discarded, and no clean native/physical performance acceptance is claimed.


## Update detection and request budget follow-up

A new sync timestamp is not evidence of new content. The client now compares an opaque
content version from a small authenticated status endpoint. The space records per-type
revisions only when visible field values or deletion visibility change. Empty pulls,
retries and clock-only changes do not advance it. Native-only types are not tracked.
Calendar preference edits, consent purges and space wipes are covered; repeated identical
calendar toggles do not create updates.

The status path makes one Durable Object call and reads existing metadata/consent rows.
It does not scan records, read R2 blobs or call Google. One bounded metadata-row write
is added per sync batch with changed web content, not per record or per poll. Initial
account loading reuses that status read in place of its prior separate consent read.

At most 12 periodic checks per visible-tab hour replace 60 account checks. The old account
path used four space RPCs per poll; the new status path uses one: 240 versus 12 background
RPCs/hour (95% fewer). Browser loads/manual refreshes and authentication/share-policy
database work still cost requests; this is not an overall bill estimate. Cloudflare bills
each Durable Object RPC method call as a request:
https://developers.cloudflare.com/durable-objects/platform/pricing/

The tradeoff is up to roughly five minutes before background access changes are noticed.
Every actual data request still checks authorization. Hidden tabs do not poll and rapid
tab switching does not bypass the interval. External Google event changes require explicit
Refresh; there is no new provider polling.

A version establishes changed stored records, not guaranteed differences in the current
chart. In particular, the Health snapshot is one combined blob: a replacement (including
a change to its workout portion) may leave a health-only shared chart unchanged. No blob
is downloaded merely to decide whether to show the update button. A decoded semantic
digest would require separate ingestion work and is not claimed here.

Update-detection validation: the service suite passed 305 tests in each time zone. Additional API checks
assert one status RPC, no record scans/writes on a warm status read, no false notification
for heartbeat/retry/clock-only updates, same-count edit detection, private-type isolation,
and revocation. Browser checks use the five-minute timer and repeated tab-return events.
The synthetic status ablation retains cold, empty, same-value, edit and warm-empty samples
at 1/100/1000 records in private/coach-validation/status-ablation.json. It records one
extra metadata write for a changed batch and zero extra writes for no-op batches; it
does not establish a latency improvement or physical UI performance.

Local review: run from Service with BANANA_PREVIEW_COACH=1 and optionally
BANANA_PREVIEW_PORT=18999, using node tools/web-preview.mjs. The login shortcut
/__preview/login opens the owner view; /__preview/coach opens an actual read-only
guest share (choose Health). The fixture has 400 days of synthetic metrics, 120 detailed
nights and 21 days of meals and dose logs. The page labels all data as fictional.
The guest cannot access owner endpoints or unshared supplement records.


## Range, comparison and coach preferences follow-up

Viewer preferences save automatically in browser local storage, scoped to the signed-in
viewer and share: hidden metrics, date range, grouping, log period, searches and filters.
They survive reload and do not alter owner permissions or another viewer’s layout.
They are not synced across browsers/devices; unavailable storage is reported in the UI.
Changing range/grouping uses the existing snapshot without API requests.

Final validation: 310 service tests pass in each of UTC and America/New_York.
`web-trends-browser.mjs` exercises actual local guest authentication/authorization,
independent range/group controls, shared-scale ghost traces, bucket drill-down,
reload persistence, owner isolation and mobile layout. The existing health browser
suite also passes after the change. Evidence is retained in
`private/coach-validation/trends-browser-final.log`, `trend-service-tests-final.log`
and `health-browser-trends.log`.

The controlled model ablation (`trend-model-ablation-final.json`) checks identical
results across all range/group combinations before measuring the sorted single-pass
bucket implementation. No new cache or eviction policy is added. Headless browser
software-dispatch-to-next-frame samples span 22.5–57.4 ms (`trend-browser-timings.json`);
these are not physical input-to-visible or 120 Hz acceptance evidence.

The required native component run remains failed: podcast lookup p95 and RSS in
scale-1d, RSS in scale-7d/redraw-library/redraw-mail, and competing workload or incomplete
monitoring in scale-7d/30d/90d. Exact results remain at
`private/coach-validation/trend-components/gate.json`. Native sources and baselines
are unchanged. No failed run was discarded; physical-device performance is unmeasured.

## Guest access and copy review

Guest sharing now supports an optional expiration date, inclusive through the selected
UTC date. The published policy enforces expiration on every shared endpoint; elapsed
shares disappear from the guest landing list. Existing grants without a date remain
unchanged. Draft changes require preview and publication, including extensions. No
scheduled job, extra status polling or schema migration is introduced.

Each published guest row has Preview access, an owner-only projection of the published
permissions. It does not approve unpublished edits. The editor retains its separate
draft-preview flow. Add new guest reveals the invitation form; the form is otherwise
collapsed when guests exist and opens by default for an empty list.

Decorative page taglines, overview card slogans, overview footer copy, login slogans,
and the Health explanation banner were removed. Metric detail explanations were
trimmed; values, coverage, dates, permissions, errors and actionable controls remain.

Validation: 313 service tests pass in both time zones, including exact expiry-boundary,
invalid-date, extension and published-preview authorization cases. Guest browser tests
cover collapsed/default forms, date persistence, publication, preview, guest expiry
labels and mobile layout. All ten owner views pass the copy/rendering smoke check.
Artifacts: `private/coach-validation/guest-copy-tests-final.log`,
`web-guest-access-browser-final.log` and `copy-smoke.log`. The first trend browser check
waited for deliberately removed explanatory text; its failure is retained, and the
selector now checks the actual daily-reading rows. These feature/copy changes make no
new performance claim; the preceding native component failure remains unresolved.

The guest overview now uses the owner card counts, filtered to permitted sections,
including merged workout history. Repeated sharing descriptions and card footers are
removed. `private/coach-validation/guest-overview-browser.log` verifies matching meal
and workout counts, absence of private cards, and existing trend/filter behavior.
The local owner-login shortcut creates a fresh session each time so it also works after
sign-out; this route exists only in the local preview tool, never the production Worker.
Final release checks: 313 service tests per time zone and a production Worker dry-run
bundle pass (`release-service-tests.log`, `worker-dry-run.log`).
