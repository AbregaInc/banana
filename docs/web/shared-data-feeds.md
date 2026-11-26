# Shared data feeds

A share can explicitly allow its owner and verified recipient to create independent read-only
connections. In Sharing, enable **Allow external data feeds**, choose **Review and save access**, then
confirm **Save access** in the guest preview. Create a named connection in the same screen. A recipient opens **Data feeds** in the shared view’s navigation. The page contains connection
creation, one configurable feed URL and revocation. Owner previews show the configured types and a live response from the same export projection.
They never create a connection or issue recipient credentials. Choose included data types and JSON or CSV, then copy the feed URL when creating the connection; secrets
are shown once, kept only in page memory and cleared on sign-out. Neither creating a share nor
editing an unpublished draft enables feeds by default.

The owner can list and revoke every connection on that share. The recipient can list and revoke
only connections they created. Removing guest access or disabling feeds blocks requests and
image downloads immediately. Disabling feeds permanently revokes existing connections; enabling
it again does not restore old keys. Already downloaded copies cannot be recalled.

## Preview and on-page instructions

In the owner’s guest preview, Data feeds loads an actual JSON response immediately. Select data
types or CSV to inspect the corresponding data, use Next page for the next response, or Open full
response to inspect a full page. The on-screen display is bounded to 65,536 characters; this does
not truncate the feed itself. Preview uses the configured share permissions for a new connection;
existing connections can retain a narrower original grant.

Preview requests use the owner-authenticated `/app/api/shared/<share-id>/feed-preview?preview=<version>`
route and the same record/calendar/blob projection as real feeds. They are not public integrations.
Preview JSON is marked `preview: true`; its image and next-page links require the owner’s browser
session, and image `expiresAt` is null rather than pretending a signed public image link was issued.
The displayed example private feed URL is non-working. The recipient creates their own private
connection, which receives the real signed URL and API token.

**Use this feed** instructions are visible on the page before creating a connection, for recipients
and owners. They describe the selected groups, HTTP GET examples, query parameters, JSON/CSV
pagination, expiring image links, original field/unit encodings, separate URL signatures and API
tokens, and error responses. A created recipient connection also offers the same response viewer.

## Personal feeds

In Sharing, open **Your data feeds**, select the calendars and sections, optionally set an
expiration date, name the connection and choose **Create private feed**. No guest, share or
invitation is created. The same JSON, CSV and expiring image links work for a personal feed.
Each connection has fixed permissions; changing the selection prepares the next connection,
not an expansion of an existing credential. Revoke and recreate a connection to change its scope.
Health sync consent and shared-data filtering still apply on every request. The owner alone can list or revoke
these connections; signing out clears the one-time credentials from the browser.

Personal management uses `GET/POST /app/api/feeds` and `POST /app/api/feeds/<feed-id>/revoke`
with an owner browser session and same-origin mutations. Signed feed URLs and bearer credentials
remain independent of browser/native sessions. The manifest has `scope: personal` and a null
`shareVersion`; the existing schema, paging and field/unit rules below still apply.

Existing shares may retain or narrow a previously published calendar permission when the
provider temporarily cannot list it. New calendar grants and wider permissions still require
current availability. Unavailable selections remain visible and removable in the editor.

## One URL, filtered within the shared access

A connection has one stable endpoint. Select multiple **Included data types**, choose JSON or CSV,
and use **Copy feed URL**. The screen shows the effective shared sections and full/busy-only
calendar access. Types not in that grant are not offered. These query parameters filter an
existing grant; they never authorize additional data.

```
GET /app/feeds/<feed-id>?signature=<credential>&types=all&format=json
GET /app/feeds/<feed-id>?signature=<credential>&types=food.meal,food.myFood&format=csv
GET /app/feeds/<feed-id>?signature=<credential>&types=calendar,food.meal&format=json&calendarDays=7
```

`types=all` means all currently authorized, consented data within the connection's original
permissions and the current published share. An explicit comma-separated selection may only
narrow that set. Requests containing an unshared type fail with 403, including mixed authorized
and unauthorized types. Unknown or repeated parameters fail rather than being silently ignored.
The current sharing model selects entire sections and specific calendars; selecting Food grants
its meals, photos and saved foods. It does not offer per-meal selection or a record-date access
policy. Calendar full-details/busy-only redaction remains part of the server projection.

Creation returns `dataURL` for the signed data endpoint and `manifestURL` for metadata. A server
integration can remove the signature and send `Authorization: Bearer <feed-token>` instead.
`format` is `json` or `csv`, `limit` defaults to 100 and accepts 1–100. Neither cookies nor native
account sessions authorize feed reads. Tokens cannot be used on native sync endpoints.

JSON uses `schema: banana.feed.v2`, with a typed `records` stream and a `next` URL. CSV includes
`type` and `id` columns and carries the next-page URL in the HTTP `Link` header. Follow every page,
even an empty one, until the continuation is absent. Pages are bounded to 100 returned records
and 8 MiB. Signed cursors expire within one hour and bind to the connection, selected types,
format, page size, resolved calendar window and effective permission policy. A changed query or
policy requires restarting from the original feed URL; a cursor never restores revoked access.
Native records may change during a pull, so reconcile by type and ID and compare content versions.

For calendars, `calendarDays=1..8` selects a rolling window beginning at the current UTC day;
the default is seven days. A recurring importer can keep this URL as the days advance. Fixed
`from` and `to` Unix-millisecond bounds can be used instead, up to eight days with the start within
366 days of now. Next-page URLs freeze the resolved window. If calendar results change while
paging, restart after a 409. Unavailable calendars return 503 instead of a partial export.

For compatibility, the legacy `url` creation field and bare endpoint still return the
`banana.share-feed.v1` manifest. `/records.json?type=...`, `/records.csv?type=...`, and the
`/calendar.json` and `/calendar.csv` aliases remain supported. New integrations should use the
single data endpoint above. The manifest lists only authorized, consented datasets, exposes an
access summary without private account identifiers, and includes generated/expiry times and
content, share and grant versions.

JSON responses contain `types`, `generatedAt`, `records` and `next`. Each record has `type`, `id`,
`data` and `assets`. `data` contains the shared type's synced fields, unwrapping the existing `v` object
where used. Health snapshots are decoded and projected through the same workout/trend filter
as the guest UI; hidden workouts and unrelated snapshot fields are excluded. Blobs become
signed URL objects, not storage keys. Meals include photo links in `assets`; photo records also
include URLs in `data`. Other shared binary attachments retain their existing formats, such as
compressed transcripts or workout sample files. A blob URL is not a promise that every binary
format has become JSON.

This first feed preserves each source type's field names, units and date encodings. It does not
silently reinterpret nutrient units or Swift reference-date values as Unix timestamps. Calendar
request bounds and feed metadata use Unix milliseconds and ISO timestamps respectively. The
normalized analysis schema below is separately versioned; raw consumers must retain the
record type and handle missing fields rather than infer units from a number.

CSV nested scalar objects become dotted columns; arrays remain JSON cells. Columns can vary
between pages, so retain the type and column names rather than column positions. Quoting follows
RFC 4180 and untrusted formula-like strings are escaped. Use JSON for colliding dotted keys or
structures wider than 1,024 columns.

These are live snapshots, not a change stream. Reconcile the complete dataset by record ID,
including deletions, rather than only appending returned rows. `contentVersion` covers the
authorized synced datasets; compare the manifest before and after a full import and retry if it
changed. It does not cover live Google calendar changes. Calendar queries use explicit windows
of at most eight days, with the start within 366 days of now. Busy-only calendars retain the same
redaction and busy-time merging as the shared web view. Feeds return readable calendars and other selected data. JSON pages that read an incomplete calendar window include `calendarIssues`. CSV callers must check the `Banana-Calendar-Unavailable` response header on each page for the count of unreadable calendars. The legacy calendar JSON alias retains its `unavailable` list.

Asset URLs expire within one hour, or earlier when the grant expires. Fetch assets promptly;
refresh their record page for new URLs. Assets always recheck the current share, feed, record
and consent, and are live references rather than immutable historical snapshots. Store the
image yourself if an authorized import needs a durable copy.

## Access and operational boundaries

- Feed tokens are 256-bit random secrets; only their SHA-256 hashes are stored. Signed URLs use
  purpose-separated HMACs. Tokens and signatures are never returned by connection listings.
- The effective scope is the intersection of the issued and current published share. The
  earliest expiration applies, through the stated UTC date. Consent is checked on every read.
- At most ten unrevoked connections per share or personal owner; revoke unused ones. Reads share the existing
  60 requests/minute share budget, including images. A 429 response includes `Retry-After`.
- Data responses are private/no-store/no-referrer/noindex. Keep signed URLs out of tickets,
  analytics, logs and public spreadsheets. Prefer bearer headers for server integrations; URL
  credentials can leak through history or logs ([RFC 6750](https://www.rfc-editor.org/rfc/rfc6750.html)).
- Feeds cannot write data, accept invitations, create account sessions or broaden permissions.
  Sharing links still require verified Google sign-in to create a connection. Feed consumers
  need only the independent credential, so revoke it if forwarded beyond the intended system.
- Apply additive migrations `0030_web_share_feeds.sql` and `0031_web_personal_feeds.sql` before deploying the new service and web
  assets together. Production deployment follows the existing release approval and preflight.

## MCP direction

MCP is a future adapter, not part of this change. Reuse the permission intersection and shared
projection behind read-only tools/resources, with separate revocable authorization grants.
Implement the standard OAuth resource-server discovery and audience validation rather than
claim these custom feed tokens are MCP authorization. See the
[MCP authorization specification](https://modelcontextprotocol.io/specification/2025-06-18/basic/authorization).

## Design and validation

The opt-in stays inside the existing preview/save permissions flow (familiarity and explicit
control). Named connections and a dataset selector reduce recall; recipients expand one inline
section instead of encountering a form above every page. Copy and revoke give immediate truthful
results, keep failed requests retryable and preserve one-time credentials across view rerenders.

Service tests cover permission publication, guest/owner isolation, hashed secrets, JSON/CSV
pagination, formula escaping, signed images, consent withdrawal, Health projection, expiration,
calendar redaction, scope narrowing, revocation and disable/re-enable. Browser checks use only
fictional local data and cover opt-in/preview/save, creation, URL retrieval, revocation and narrow
layout. Native performance tests are unrelated to this server/web-only feature.

Local browser fixture: from `Service/`, run
`BANANA_PREVIEW_COACH=1 BANANA_PREVIEW_FEEDS=1 node tools/web-preview.mjs`, then open
`http://localhost:8899/__preview/coach`. It uses only fictional records and an in-memory service.
Validation for this change: 23 sharing/feed checks; the complete service suite passes in UTC
and America/New_York (522 checks each). Owner and recipient creation, copied URL retrieval,
revocation, calendar CSV/date selection, selector keyboard focus, 390-pixel layout and sign-out
credential removal were checked in the local browser. Private evidence is retained off-tree.

## Discovering valid type parameters

The on-page **Valid types for this connection** table is exhaustive for the current grant and
consent, including permitted datasets that have no records yet. It shows exact, case-sensitive
identifiers and descriptions, plus a **Copy valid types** action. Before creation, recipient
views use the server’s consent-filtered allowed types; after creation the connection manifest
is authoritative, preserving any narrower original grant. Checkbox labels also show identifiers.

For programmatic discovery, GET the connection’s `manifestURL` (the endpoint with `view=manifest`).
Read every `types[].type`; add `calendar` only if the top-level `calendar` is non-null. Use `all`
for every currently permitted type or join a subset with commas, without spaces or duplicates.
Unavailable types return 403; reload metadata when access or consent changes.

## Complete coach download and normalized analysis contract

A signed-in recipient can select types and use **Download complete ZIP** without creating an
external credential. This one-off read uses `/app/api/shared/<id>/export-data`, requires the actual
recipient or an authorized owner preview, and still requires the share's external-data-feed opt-in.
It uses the same section/calendar/consent projection as credential-based feeds. Its page/image links
require the same browser session; `expiresAt: null` does not make them public or permanent.

The ZIP contains:

- `tables/*.csv`: all pages assembled into fixed-column scalar tables, UTF-8 with a BOM, compatible
  with Excel/Numbers and CSV analysis tools. Empty selected datasets keep their headers. Formula-like
  strings are escaped. Null is an empty cell, never an invented zero.
- `analysis.json`: `banana.analysis.v1`, the same normalized tables, `sourceRecords`, collection
  metadata, selected types, scope, calendar window and warnings. All fetched source records are
  retained, including additional fields and selected Notes/Taken/Listening types that do not have
  fitness-specific normalized tables. Do not sum source records with normalized observations.
- `schema.json`: every normalized column's type, meaning, unit, enum semantics and relationship.
  The same dictionary is available on the page and at `/app/assets/analysis-schema.json`.
- `manifest.json`: row counts per table, selected scope/types, collection and verification times,
  calendar bounds and warnings; `README.txt` explains import and reconciliation.
- `images/`: optional meal image files. `assets.csv.file_path` and `meal_photos.csv.asset_id` join
  them to meals. Other binary attachments remain source links. With images unchecked, links are
  remote and may expire (credential links) or require a current session (session links). Downloaded
  image copies remain usable offline and cannot be recalled by revocation.

Normalized fitness coverage includes meals, individual meal items, meal/photo relationships, saved
foods, merged workouts, workout plans/exercises/completions, Health readings and sleep nights/wakes,
routine definitions/time slots/keywords/explicit overrides, alarms, added occurrences and wake plans.
Calendar events retain full/busy-only projection and exclusive all-day end dates. Definitions and
explicit completion history are exported; no future routine occurrence or unrecorded completion is
invented. A missing referenced plan/routine is possible when its source type was not selected.

All normalized instants are ISO 8601 UTC. Local-day and local-clock fields remain explicitly local;
routine weekdays use 1=Sunday through 7=Saturday. A local clock alone does not establish a UTC
occurrence. Food energy is kcal and macronutrients are grams; saved-food nutrition is per 100 g,
meal-item nutrition is for the logged portion, and meal totals sum those portions. If any item lacks
one nutrient, that meal's total for that nutrient is null, not a misleading partial sum. Body fat is
percent (20 = 20%), BMI is kg/m², distances are metres, durations are explicitly seconds/minutes/hours,
heart rate is bpm, HRV is milliseconds and VO₂ max is mL/kg/min. The dictionary lists every metric.

`workouts` is the canonical counting table. It calls the shared website's actual `mergeWorkouts`
implementation using the same owner source preference supplied by the server, not a separate
heuristic. Starts **less than 90 seconds** apart pair, nearest first. Source preference is owner
bundle, Banana, Apple Watch, Workoutdoors, Nike/Slopes/Daypart, default, Strava, Whoop; metric
completeness and ID break equal-source ties. Health metrics take precedence, with recorded values
as fallback. A paired recording keeps its ID and retains `summary_id` and `health_id`. Plans and
plan completions are prescriptions/history, not additional recorded workouts. Hidden Health
workouts are already removed by the server. Multiple source snapshots produce an explicit warning;
as on the website, the first snapshot in record order supplies normalized Health data. All source
snapshots remain in provenance. Unknown future Health metrics are retained in sourceRecords and
produce a warning rather than receiving an invented unit.

### Developer importer

Download `/app/assets/banana-feed.mjs` (Node 24; bundled, no package installation required):

```sh
export BANANA_FEED_URL='<private feed URL>'
# Optional bearer mode: remove signature from the URL and set BANANA_FEED_TOKEN.
node banana-feed.mjs --output banana-analysis.zip
# Optional: --no-images --max-mib 128
```

For your own Node program:

```js
import {importFeed, exportFeed, analysisSchema} from './banana-feed.mjs';
const data = await importFeed(process.env.BANANA_FEED_URL, {
  token: process.env.BANANA_FEED_TOKEN,
});
// data.schema === 'banana.analysis.v1'
// data.tables.workouts, data.tables.meals, data.sourceRecords
```

`importFeed` returns a complete normalized JSON pull; `exportFeed` returns ZIP bytes and optionally
includes photos. Both accept `signal`, `onProgress`, `maxBytes` and `maxRecords`. Browser work runs
in a dedicated module worker. Cancellation, selection changes, navigation and sign-out terminate
it. The importer starts from the beginning even if given a continuation URL, follows empty pages,
rejects loops/duplicate records, rejects redirected or cross-origin continuation/asset URLs, and
never forwards the credential to another origin. Keep tokens in environment variables or secret
storage, not command arguments/logs. A raw source-record normalizer is also exported for advanced
use, but must receive the complete selected dataset; use `importFeed` for a verified collection.

Every page checks `contentVersion`, access, selected types and workout source preference against
the first page. The server checks synced content before and after constructing each page. The
importer verifies again at the end and, for ZIPs, after downloading images. Any mismatch, revoked
access, unavailable image, malformed record, duplicate, or exhausted retry fails without
saving a partial archive. This is optimistic consistency, not an atomic multi-provider database
transaction. Calendar pagination checks its own stable window/version; calendars can change after
collection. Reconcile deletions by type and ID for complete datasets. When `calendarIssues` is present, preserve existing calendar data for the affected window.

The importer defaults to at least 1.1 seconds between requests under the shared 60/minute budget,
respects `Retry-After`, and retries 429 three times before surfacing failure. Other consumers on the
same share may still consume the budget. Browser downloads cap fetched data at 64 MiB and 100,000
records, including verification reads and image bytes, and fail explicitly when exceeded. Use
fewer types or the Node importer's explicit size override (CLI up to 1 GiB) for larger exports;
large imports require corresponding process memory. Cursor validity remains one hour. Refresh
source pages for fresh credential image URLs; session URLs require a current signed-in session.

The analysis schema is versioned independently from `banana.feed.v2`. Additive columns can be
introduced; address columns by name. Breaking type/unit/meaning changes require a new analysis
schema version. Existing raw feed URLs and source representations are unchanged.

### Native source encoding reference

For consumers choosing raw `banana.feed.v2` rather than the normalized importer:

| Source type | Date fields and interpretation | Relationships / numbers |
| --- | --- | --- |
| `food.meal` | `date`: Unix milliseconds | `items[].macros`: logged portion kcal/g; `items[].grams`: g; `photoIDs[]` → mealPhoto; `items[].reference.per100g`: per-100g kcal/g, not portion totals |
| `food.myFood` | `addedAt`, `uses[].at`, `bought[]`: Unix milliseconds | `per100g`: kcal/g per 100 g; `servingGrams`, `packageGrams`: g; source barcode/label |
| `food.mealPhoto` | No date conversion | `v` is an image URL descriptor; asset ID joins meal photoIDs |
| `health.workout` | `start`, `end`: Unix milliseconds | distance m, energy kcal, heart rate bpm; pauses are relative elapsed seconds; recordings remain binary assets |
| `health.snapshot` | `workouts[].start/end`, trend `date`, night/wake dates: seconds since 2001-01-01 UTC | Convert with `(seconds + 978307200) * 1000`; workout duration s, distance m, energy kcal, HR bpm. Body fat raw fraction, not percent; hidden workouts/unshared fields already removed |
| `health.workoutPlan` | `createdAt`: Unix milliseconds | `exercises[].id` prescription ID; sets/reps counts, duration/rest seconds; focus strength/mobility/mixed |
| `health.workoutCompletion` | `startedAt`, `endedAt`: Unix milliseconds | `planID` → workoutPlan; `completedExerciseIDs[]` → prescription IDs |
| `plan.routine` | Local `hour`, `minute`, weekdays (1=Sunday) | trigger time/earliestMeeting/workoutStart/wakeUp/calendarMatch/manual; calendar-match lead is before event, wake lead is after wake; extra slots have their own IDs/weekdays/time |
| `plan.alarm` | `fire`: Unix milliseconds | Label and one-off definition |
| `plan.extra` | `start`: Unix milliseconds | `seriesID` → routine |
| `plan.override` | `completed.at`, `completed.scheduledStart`, `reschedule._0`: Unix milliseconds | ID routine\|slot\|local-day; completed, skip or reschedule enum payload; absence is not inferred incomplete |
| `core.wakePlan` | `plan.days[].date/wake`: Unix milliseconds | Synced plan, not newly generated occurrences |
| `calendar` | `start/end.dateTime`: ISO 8601 with offset; `start/end.date`: local YYYY-MM-DD, exclusive end | Projected IDs and busy/full-details policy; from/to query bounds use Unix milliseconds |
| `food.supplement` | Local hour/minute | kind supplement/medication, free-text dose, ingredients/anchor definitions |
| `food.dose` | `date`: Unix milliseconds; `day`: fixed local YYYYMMDD | `supplementID` → supplement; status taken/skipped |
| `notes.voiceNote` | Synced Date fields: Unix milliseconds | Text metadata plus recording/transcript source attachments |
| `podcast.show` | Synced Date fields: Unix milliseconds | Podcast definitions and source metadata |
| `podcast.listen` | Synced Date fields: Unix milliseconds | Listening observations, linked show/episode identifiers |
| `podcast.progress` | Synced Date fields: Unix milliseconds | Playback position/duration are seconds, not dates |
| `podcast.transcript` | No blanket conversion of blob contents | Metadata plus original binary/text attachment representation; decoder required for compressed content |

Additional native fields and unknown future enum cases are preserved in sourceRecords. Optional
fields can be absent. Do not infer measurement units from magnitudes or parse opaque IDs. The
versioned analysis dictionary is the supported scalar fitness contract when those native details
are not needed.

### ZIP implementation and checks

Browsers provide no native ZIP writer. The export uses pinned MIT-licensed fflate 0.8.3, stored
locally with its license, in an isolated module worker. ZIP storage mode avoids recompressing
already-compressed photos and does not use nested blob workers or a CDN. Tests open the resulting
archive and verify every page, scalar table, schema, image join and count. Size caps are checked
while streaming responses before JSON parsing; the worker bounds main-thread work independently
of total source history. This is a functionality/resource boundary, not native frame-performance
acceptance.

## Calendar recovery and deleting old connections

A revoked personal or shared connection offers **Delete**. Deletion removes only that credential
record from the list; source data and the share remain. Active connections must first be revoked.
Owners may delete revoked connections for their shares, recipients only their own. Deletion checks
the same identity/origin boundary and does not re-enable URLs or image links. Management endpoints
are `DELETE /app/api/feeds/<id>`, `DELETE /app/api/shares/<share>/feeds/<id>` (owner), and
`DELETE /app/api/shared/<share>/feeds/<id>` (recipient), with a same-origin authenticated JSON body.
An active key returns 409, unknown or out-of-scope keys 404.

Each `calendarIssues` entry has a share-scoped `calendarRef` and a reason of
`reconnect`, `unavailable` or `retry`. The importer and ZIP manifest retain these issues.
The preview offers Retry and an edit link for owners. Owner preview identifies account and
calendar IDs. The recipient warning protects busy-calendar names, account addresses and Google IDs.
If every calendar fails, the warning still appears alongside the other selected data.

Explicitly selected hidden or unsubscribed calendars are read if Google still permits the events
request. Sidebar membership is not the permission check. Deleted/inaccessible calendars and missing
Google links each produce an issue alongside the readable data. The existing share editor's unavailable
calendar rows can remove a stale permission, followed by Review and save access → Save access.
