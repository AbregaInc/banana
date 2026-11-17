# Shared data feeds

A share can explicitly allow its owner and verified recipient to create independent read-only
connections. In Sharing, enable **Allow external data feeds**, choose **Review and save access**, then
confirm **Save access** in the guest preview. Create a named connection in the same screen. A recipient opens **Data feeds** in the shared view’s navigation. The page contains connection
creation, one configurable feed URL and revocation. Guest previews show the same page with creation disabled;
they never issue credentials as the recipient. Choose included data types and JSON or CSV, then copy the feed URL when creating the connection; secrets
are shown once, kept only in page memory and cleared on sign-out. Neither creating a share nor
editing an unpublished draft enables feeds by default.

The owner can list and revoke every connection on that share. The recipient can list and revoke
only connections they created. Removing guest access or disabling feeds blocks requests and
image downloads immediately. Disabling feeds permanently revokes existing connections; enabling
it again does not restore old keys. Already downloaded copies cannot be recalled.

## Personal feeds

In Sharing, open **Your data feeds**, select the calendars and sections, optionally set an
expiration date, name the connection and choose **Create private feed**. No guest, share or
invitation is created. The same JSON, CSV and expiring image links work for a personal feed.
Each connection has fixed permissions; changing the selection prepares the next connection,
not an expansion of an existing credential. Revoke and recreate a connection to change its scope.
Health and transcript consent still apply on every request. The owner alone can list or revoke
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
request bounds and feed metadata use Unix milliseconds and ISO timestamps respectively. A
future normalized analysis schema should be separately versioned; consumers must retain the
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
redaction and busy-time merging as the shared web view. The unified endpoint returns 503 for unavailable calendars in either format; the legacy JSON
calendar alias retains its `unavailable` list.

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
