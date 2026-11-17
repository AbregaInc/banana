# Shared data feeds

A share can explicitly allow its owner and verified recipient to create independent read-only
connections. In Sharing, enable **Allow external data feeds**, choose **Review and save access**, then
confirm **Save access** in the guest preview. Create a named connection in the same screen. A recipient opens **Data feeds** in the
shared-view banner. Copy the JSON/CSV URL or API token when creating the connection; secrets
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

## Importing into another system

Use JSON for a recurring import. The creation response contains a signed manifest `url` and a
separate `token`. A signed URL works without cookies. A server integration can instead remove
the signature query parameter and send `Authorization: Bearer <feed-token>` to that feed's
endpoints. Do not send a feed token to native sync APIs or use a native account session here.

```
GET /app/feeds/<feed-id>
GET /app/feeds/<feed-id>/records.json?type=food.meal&limit=25
GET /app/feeds/<feed-id>/records.csv?type=food.meal&limit=25
GET /app/feeds/<feed-id>/calendar.json?from=<unix-ms>&to=<unix-ms>
GET /app/feeds/<feed-id>/calendar.csv?from=<unix-ms>&to=<unix-ms>
Authorization: Bearer <feed-token>
```

The manifest (`schema: banana.share-feed.v1`) lists only authorized, consented datasets and their
JSON/CSV endpoints. It also includes `generatedAt`, `expiresOn`, `contentVersion`, `shareVersion`
and `grantVersion`. Feed credentials never expand to include permissions granted after their
creation. Create a new connection to grant newly shared datasets. Narrowing current permissions
always narrows an existing feed, including calendar details becoming busy-only.

Record responses contain `type`, `generatedAt`, `records` and `next`. Each record has `id`, `data`
and `assets`. `data` contains the shared type's synced fields, unwrapping the existing `v` object
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

Follow JSON `next` until null, even after an empty page. CSV pages use the HTTP `Link` header with
`rel="next"`; a CSV URL is one page, not a complete-download promise. `limit` defaults to 25 and
accepts 1–100. The underlying scan is bounded to 100 raw records per page; deleted records may
produce empty pages with a continuation. CSV nested scalar objects become dotted columns;
arrays remain JSON cells. Columns can vary between pages. Quoting follows RFC 4180, and strings
that could start spreadsheet formulas are escaped; numeric negative values remain numeric.
Use JSON for structures with colliding dotted keys or more than 1,024 columns.

These are live snapshots, not a change stream. Reconcile the complete dataset by record ID,
including deletions, rather than only appending returned rows. `contentVersion` covers the
authorized synced datasets; compare the manifest before and after a full import and retry if it
changed. It does not cover live Google calendar changes. Calendar queries use explicit windows
of at most eight days, with the start within 366 days of now. Busy-only calendars retain the same
redaction and busy-time merging as the shared web view. JSON reports unavailable calendars;
CSV returns 503 rather than silently export a partial schedule.

Asset URLs expire within one hour, or earlier when the grant expires. Fetch assets promptly;
refresh their record page for new URLs. Assets always recheck the current share, feed, record
and consent, and are live references rather than immutable historical snapshots. Store the
image yourself if an authorized import needs a durable copy.

## Access and operational boundaries

- Feed tokens are 256-bit random secrets; only their SHA-256 hashes are stored. Signed URLs use
  purpose-separated HMACs. Tokens and signatures are never returned by connection listings.
- The effective scope is the intersection of the issued and current published share. The
  earliest expiration applies, through the stated UTC date. Consent is checked on every read.
- At most ten unrevoked connections per share; revoke unused ones. Reads share the existing
  60 requests/minute share budget, including images. A 429 response includes `Retry-After`.
- Data responses are private/no-store/no-referrer/noindex. Keep signed URLs out of tickets,
  analytics, logs and public spreadsheets. Prefer bearer headers for server integrations; URL
  credentials can leak through history or logs ([RFC 6750](https://www.rfc-editor.org/rfc/rfc6750.html)).
- Feeds cannot write data, accept invitations, create account sessions or broaden permissions.
  Sharing links still require verified Google sign-in to create a connection. Feed consumers
  need only the independent credential, so revoke it if forwarded beyond the intended system.
- Apply additive migration `0030_web_share_feeds.sql` before deploying the new service and web
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
