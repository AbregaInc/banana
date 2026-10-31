# Mail and Calendar search

### Bounded history navigation — October 11, 07:47

Mail now provides Older and Newer/Newest navigation for downloaded mail and search
results. Each window uses an exclusive date/tie cursor and retains at most 2,000
message rows; moving to another window releases the old model and observation.
Small back-navigation cursors remain in memory. Clearing search restores its
original mailbox scope, including an older-window boundary when present.

`history-windows-engine` verifies a real disk index containing 2,007 conversations:
Inbox and search each return 2,000, then seven, then zero distinct rows. The engine
passes 235 of 236 cases; HTML preparation still fails its unchanged budget.
`history-windows-ui` passes all 243 functional cases, including navigation beyond
2,000 conversations, opening a result, search/reset and Calendar search entry.
Its overall gate **fails** for a thread-priority inversion warning. Evidence lives
under `.build/mail-download-20261011/`; physical latency and live Gmail acceptance
remain open. `history-windows-components/gate.json` passes all eight unchanged
component and redraw scenarios. This does not close the UI runtime warning,
earlier retained failures, or physical frame/input acceptance.

### Installed review update — October 11, 08:02

The history-window changes, Gmail read backoff corrections and statement reuse
are now in the signed review apps installed on the Mac, both phones and iPad.
`history-review-source.json` captures app source hashes;
`history-review-device-status.json` records binary identities and device outcomes.
The Mac passed normal-app Google Calendar search/Return/clear/Escape and local
Mail submit/clear checks through CUA. The spare iPhone passed both expanded
`ReviewLaunchUITests` cases, with no skips or runtime warnings, including local
Mail submit/clear and Calendar search keyboard routing.

The primary phone refused launch because it was locked. The iPad accepted a
`devicectl` launch, but subsequently blocked XCTest at preflight with “Unlock
AyePad to Continue”; that waiting run was interrupted and retained (exit 75).
Neither device has fresh interaction acceptance. Live Gmail consent and data
remain untested. These smoke checks do not measure physical responsiveness.

The iOS build also retains a linker warning: bundled `libneedle` was built for
iOS 27.0 while the app deployment target is 26.1. The spare runs iOS 27.0.1;
these results do not establish older-OS compatibility. No warning was suppressed.

### Review build checks — October 11, morning

The signed Mac Beta built from `morning-review-source.json` displayed live Google
Calendar results for `call`. Mail submit and clear restored the expected empty
local search/Inbox states; Gmail permission has not been granted by the agent.
Native testing also reproduced a defect twice: Return activated the search sheet's
Done action and dismissed it. The correction makes Done an Escape/cancellation
action. New Mac and mobile regression assertions require Return to keep search open.
The corrected signed Mac binary passed the same live-query/Return check, clear/reset
and Escape dismissal through CUA. `search-return-native-checks.json` retains its
binary hash and functional outcome. The matching signed iOS build is installed on both phones and the iPad.
`search-return-spare.xcresult` passes both normal-Beta physical iPhone smoke tests
(2 passed, no skips or runtime warnings), including Day/Week navigation, Calendar
search Return/clear/dismiss and the Mail search control. The iPad and primary phone
refused launch while locked; their fresh UI checks remain unmeasured. This does not
verify live Gmail results or physical search latency.
Evidence is under `.build/mail-download-20261011/`, including
`morning-review-native-checks.json` and `search-return-source.json`.

The fresh `search-return-ui` run passes all 240 functional cases, including the
Return correction, but its gate still fails for a thread-priority warning.

The later `mailbox-sync-components/gate.json` passes all eight persistent component
scenarios, superseding the earlier failed component run below without discarding it.
It predates the final access-lifecycle/status and Return correction. The latest
`removal-review-ui-3` run passes all 240 functional cases, including search, but its
gate remains failed for a GRDB priority-inversion warning. The `access-lifecycle`
engine run passes 228 of 230 cases; HTML preparation and 500-message enumeration
still exceed their component budgets. No physical search timing pass is claimed.

### Earlier verification — October 11, 05:04

`.build/search-review-20261011/calendar/status.json` passes query routing checks.
All four Mail search cases pass in `.build/search-review-20261011/mail/test.log`,
including retained-history paging, account isolation and atomic edit/delete updates.
At 180,000 messages, broad local search measured 73.90–76.86 ms; selective search
measured 0.26–0.37 ms. Broad search still misses the 50 ms goal before rendering.
The complete engine run passed 189 of 190 cases: HTML preparation remains failed
at 245.23–251.56 ms against 100 ms. No physical-device latency acceptance is implied.
Existing Simulator search/open/clear coverage remains in
`.build/mail-download-20261011/triage-ui/gate.json`; live Gmail consent and physical
search timing remain outstanding. The latest full component suite failure is retained
in `.build/mail-download-20261011/search-history-components/gate.json`.

Requested October 10, 2026. Search is part of integrated user-test readiness on
Mac, iPhone and iPad, not an optional performance experiment.

## Initial scope

- Mail: search subject, sender/recipient and available message text; open the
  matching conversation. Reuse `MailScope.search`, the Mail source boundary and
  the existing dedicated search database. Search retained account data, not just
  the list's loaded rows. Offer Gmail-backed results beyond local coverage.
- Calendar: search Google event titles, locations and descriptions across the
  selected calendars; show event date/time and calendar and open the existing
  event detail. Search must not be restricted to the visible Day/Week page.
- Both: a normal search control, clear/reset, loading, empty, offline and retry
  states. Preserve account/calendar isolation and stable result identity.
  Clearly describe local coverage and provider results; incomplete cached data
  must not be presented as an exhaustive mailbox or calendar search.

## Extension boundary

Keep query interpretation and fetching outside views. Each domain owns a typed
query, bounded result page, opaque continuation and explicit coverage/error state.
Reuse the existing Mail contract rather than introduce a competing search model.
Keep provider-specific syntax behind its adapter. Later filters (date range,
account, calendar, participants, unread, attachments) should extend the query
without replacing navigation or result presentation.

Cancel superseded requests and guard publication with query identity so delayed
results cannot replace newer input. Partition continuation and cache keys by
query, account/calendar scope and data revision. Cap retained results and use
disk/provider paging. Never load or scan the entire history on the UI thread.
Document tokenization, case/diacritic handling and local/provider differences
before choosing the local index; do not promise substring semantics from a
token-prefix index. Calendar recurrence expansion must have an explicit bounded
date range, visible to the user and extendable through navigation.

## Acceptance

Verify results beyond the currently loaded mail window and calendar week;
multiple accounts/calendars; recurring and all-day events; Unicode and punctuation;
empty queries; clear/reset; fast query replacement; result opening; paging;
offline coverage; provider errors/retry; edits/deletions invalidating results.
Use controlled provider responses for correctness before live account checks.

Run the persistent component regression suite and relevant UI tests. Record
typing feedback separately from local results-ready and provider completion.
Use the unchanged UI performance contract, including cold, warm and eviction
cases at the retained-history stress workload. Physical device evidence is
required independently for Mac, iPhone and iPad; no component or fixture pass
establishes integrated search acceptance.

## Initial implementation — October 11

- Mail has a submit-to-search field, clear/reset, an explicit local coverage label,
  loading, empty and retry states. The live adapter uses SQLite FTS5 over **all
  retained message headers and snippets**, including recipient addresses. Search
  returns conversations in date/tie order with a bounded keyset continuation.
  Message insert/update/delete triggers maintain the index in the same transaction.
  Search scopes are retired when left instead of retaining every query's list model.
- The header index lives in `index.sqlite` for transactional consistency with message
  edits/deletes. This deliberately narrows the first version: prepared-body indexing
  in the dedicated search store and Gmail-backed search remain future work. The UI
  does not claim either. FTS uses `unicode61 remove_diacritics 2`: literal word-prefix
  AND matching, case-insensitive, with Latin diacritics removed. Punctuation separates
  words. Operators such as `OR` are literal words, not Gmail syntax. This is not an
  arbitrary substring search or complete multilingual linguistic search.
- Calendar has a search button in both desktop and mobile Day/Week toolbars. Its
  sheet uses Google's `events.list(q:)`, selected calendars, a visible/editable date
  window (initially one year either side of today), expanded recurrence instances,
  and 50-result pages. Results are explicitly grouped by calendar, not presented as
  a globally sorted timeline. Previous/next replaces the current page; only cursors
  are retained. Opening a result uses the existing Google event detail/editor.
  Changed queries cancel obsolete publication; closing a detail refetches the page.
  Network/auth errors offer a fresh retry, not an empty-success result. Calendar
  search currently requires internet; no offline result cache is claimed.

### Library and framework choices

Reuse SQLite/GRDB's maintained [FTS5 engine](https://www.sqlite.org/fts5.html) for
local token-prefix matching and [Google Calendar's existing query/paging API](https://developers.google.com/workspace/calendar/api/v3/reference/events/list)
for Calendar. No custom indexer/token-search algorithm or new UI renderer is needed.
[Gmail's query API](https://developers.google.com/workspace/gmail/api/guides/filtering)
provides the subsequent server-search extension; its semantics differ from local
prefix matching and must be labeled separately.

### Validation and remaining gaps

Normal Beta now opens `MailLiveSource` and its disk index; sample mail requires an
explicit fixture launch. Google consent is still required to populate a real mailbox.
Fixture search is for functional navigation only, not proof of live Gmail or
performance. Full bodies and Gmail-backed results remain open. The 2,000-row
working-set cap now has explicit older/newer navigation, verified above.
Calendar provider pagination,
recurring/all-day detail opening and device interaction need live or controlled
provider integration tests; URL construction alone cannot establish these.

Persistent Mail checks include account separation, accents, punctuation, retained
history beyond 2,000 rows, duplicate conversation hits, atomic edit/delete invalidation,
and 180,000-message query measurements. Calendar's URL routing checks are in
`tools/calendar-search-tests`; both run in CI. New UI cases cover retained fixture
Mail search/clear/open and Calendar search entry/dismissal. Keep their execution
status and performance failures in the result report; adding tests is not a pass.

### Retained verification evidence

- `.build/search-integration-20261011/search-ui.xcresult`: two Simulator UI cases
  passed, zero failures/skips/runtime warnings. Covers fixture Mail search/open/clear
  and Calendar entry/dismissal only; it does not exercise a live Google query.
- `.build/search-verification-20261011/calendar/status.json`: query URL checks pass
  against the current source, including escaped calendar IDs and page tokens.
- `.build/mail-search-20261011/run-3/search-benchmark.json`: at 180,000 messages,
  the broad query took 78.3–80.6 ms versus 139.4–141.4 ms for the frozen reference
  in alternating component samples. This misses the 50 ms goal before UI work;
  host contention and missing eviction/device evidence prevent acceptance claims.
- `.build/search-verification-20261011/mail/`: fresh full Mail engine regression
  run: all four search cases passed; broad-query component samples were 73.0–79.0 ms.
  Overall, 64 of 65 tests passed. The HTML preparation cost case failed all eight
  large-document samples at 240–249 ms against its unchanged 100 ms guardrail.
  This is the previously retained HTML failure, not a search correctness failure.
  The full suite remains failed; no physical search timing acceptance is claimed.

### Follow-up verification — October 11

Calendar now has an explicit accessible clear control; clearing resets the query,
page, cursor history and error state. The persistent entry/dismissal UI case also
checks clearing whitespace without issuing a provider request.

- `.build/search-followup-20261011/calendar/status.json`: URL checks passed.
- `.build/search-followup-20261011/mail/test.log`: all four search cases passed;
  overall 87 of 88 engine tests passed. The existing HTML preparation case still
  failed (244.6–253.4 ms). Search broad-query samples were 74.6–80.2 ms over
  180,000 messages; these miss the 50 ms goal before UI work.
- `.build/mail-download-20261011/action-components/gate.json`: full persistent
  component run failed host-isolation checks during redraw scenarios. Competing
  builds overlapped this run; samples remain retained and require a clean rerun.
  No baseline or budget changed.

Live-account result verification and physical-device input/display timing remain
open on Mac, iPhone and iPad.

- `.build/search-followup-20261011/ui/gate.json`: persistent Mail session, paging
  and search UI checks passed on the iPhone Simulator, with no failures, skips or
  runtime warnings. Includes Calendar clear/reset and Mail retained-result
  search/open/clear. This is fixture UI correctness, not live-provider acceptance.
