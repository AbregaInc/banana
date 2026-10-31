# Banana service

Banana's own small server (docs/design/ACCOUNTS.md): accounts through Google sign-in, a silent push
to every device when a watched Google calendar changes, usage counts (anonymous totals, and per
account when signed in), deleting an account, and the data platform (docs/design/DATA-PLATFORM.md):
every kind of Banana data synced through the person's own space. It replaces the old usage collector (`Telemetry/`):
the anonymous `counts` table is unchanged and the batch moved from `/v1/batch` to `/v1/usage`.

Plain JavaScript modules on [Hono](https://hono.dev). The platform pieces sit behind small ports so
the same app runs on Cloudflare Workers and on Node 24:

| Piece | Workers (`src/worker.js`) | Node (`src/node.js`) |
|---|---|---|
| HTTP | Workers `fetch` | `@hono/node-server` |
| Database | D1 (`src/adapters/d1.js`) | `node:sqlite` (`src/adapters/sqlite.js`) |
| Spaces (one SQLite each) | the `Space` Durable Object (`src/space-do.js`) | a file per space (`src/adapters/spaces-sqlite.js`) |
| Blobs | R2 (`src/adapters/r2.js`) | a directory (`src/adapters/blobs-fs.js`) |
| Work after the response | `ctx.waitUntil` | a caught promise |
| The 15-minute job | Cron Trigger | `setInterval` |
| APNs (HTTP/2 only) | Workers `fetch`; see "APNs from a Worker" | `node:http2` (`src/adapters/http2.js`) |
| Crypto, settings | WebCrypto, env vars | WebCrypto, env vars |

```
src/app.js         the API: createApp({db, google, apns, config, defer, now, random})
src/calendar.js    calendar watches (shared by the API and the job)
src/job.js         renews watches a day before they end, retries failed ones
src/google.js      Google: code exchange, access tokens, events.watch, channels.stop, revoke
src/apns.js        APNs: ES256 provider token, silent pushes
src/crypto.js      refresh tokens sealed with AES-256-GCM, session tokens, ids
src/usage.js       the usage allow-list (was Telemetry/src/validate.js)
src/config.js      settings from the environment
src/space.js       a space: records, merge, history, sync, blob index, consent (synchronous, one port)
src/space-do.js    the Space Durable Object running it; src/trash.js moves blobs to the trash
src/sync-routes.js /v2: sync, blobs, consent, export, device move state
src/catalog.js     ../Shared/DataCatalog.json, the list of types the app reads too
migrations/        the schema, applied in name order on both D1 and SQLite
test/              node:test, the whole service on in-memory SQLite with fake Google and APNs
```

## API

| Call | Body | Answer |
|---|---|---|
| `POST /v1/google` | `{code, device}`, signed in or not | `200 {session?, account}`; `400 bad_request`, `401 google_refused`, `409 other_account`, `502 google_unavailable` |
| `GET /v1/account` | | `200 account`: `{id, google: [{email, status, watching, access}], devices}`; `access` = the service holds its own working Google token for that link |
| `DELETE /v1/account` | | `204`: watches stopped, tokens revoked, every row gone (one audit row `delete` stays) |
| `PUT /v1/devices/:id` | `{platform, push, pushEnv, bundle}` | `204` |
| `DELETE /v1/devices/:id` | | `204` |
| `POST /v1/google/identity` | `{idToken, device}`, signed in or not | as `POST /v1/google`, with Google's identity token for one of the app's own clients (`GOOGLE_APP_CLIENT_IDS`); no Google access for the service |
| `GET /v1/google/channels` | | `200 {channels}`: the watches devices opened |
| `POST /v1/google/channels` | `{email, calendarId}` | `201 {id, token, address, ttlSeconds}`; `404 unknown_google` |
| `PUT /v1/google/channels/:id` | `{resourceId, expiration}` | `204`; `404 not_found` |
| `DELETE /v1/google/channels/:id` | | `204` |
| `PUT /v1/google/calendars` | `{email, ids}` | `202 {watching}`; `404 unknown_google` (service-made watches, for links made with a code) |
| `DELETE /v1/google` | `{email}` | `204` |
| `POST /v1/google/notify` | Google's `X-Goog-*` headers | `200`, always; pushes every device of the account (≤ 1 per 3 s) and writes APNs's answer on each device row (`pushed_at`, `push_status`) |
| `POST /v1/usage` | the usage batch (≤ 16 KB), signed in or not | `204`; `400`, `413` |
| `GET /v1/health` | | `200 ok` |
| `POST /v2/sync` | `{device, since, changes, space?}` (≤ 2 MB, ≤ 500 changes) | `200 {now, epoch, head, next, more, applied, changes, rejected, consents}` (`epoch`: new whenever the space is emptied); a record with a clock more than 5 min past `now` is rejected whole (`clock`), for the device to stamp again; `404 unknown_device`, `403 not_member`, `413`. Pushes `{"b":{"k":"sync"}}` to the account's other devices: at once, or, within 3 s of the last push, once when the 3 s end |
| `PUT /v2/blobs/:sha256` | the file, with `Content-Length` (≤ 100 MB) and `X-Banana-Type` (a catalog type with blobs) | `204`, also when already there (always indexed, with its type's tier); `400 sha_mismatch`, `403 consent` (a T2 type without the Health consent), `411`, `413` |
| `GET`, `HEAD /v2/blobs/:sha256` | | the file, streamed; `404` |
| `PUT /v2/consents/health` | `{version, device?}` | `204` (the space, then the D1 log) |
| `DELETE /v2/consents/health` | | `204`: T2 records and history gone; every T2 blob (uploaded for a T2 type or named by T2 data) goes to the trash in batches |
| `GET /v2/export` | | `200` NDJSON: records, history, blob list, consents |
| `PUT /v2/devices/:id/sync-state` | `{seeded?, seededAt?, flippedAt?}` | `204`; `404 unknown_device` |

`GET /v1/account` also gives `seeded` (the types the account's iPhone, active in the last 30 days,
has seeded; `null` without one), `flipped` (every device active in the last 30 days has stopped
writing iCloud) and `icloud` (`purge` only when `accounts.icloud_purge_ok` is 1
and every device active in the last 30 days has `seeded_at` and `flipped_at`; else `keep`).

Signed-in calls carry `Authorization: Bearer <session>`; without a known session they answer
`401 {"error":"signed_out"}`. Nothing logs a token, a code, an email, a calendar id or a push token.

## Run it on Node

Use Node **24.22.1 or newer in the 24.x LTS line**. The October 21, 2026
[security release](https://nodejs.org/en/blog/vulnerability/october-2026-security-releases)
fixes DNS, TLS, Brotli, HTTP and other Node runtime vulnerabilities. `.node-version`, the
service's Volta pin, npm's strict engine policy and the Node entry's startup check keep
older releases from being used accidentally. With Volta, entering `Service` selects the
pinned runtime; otherwise install the version in `.node-version` before running npm.
CI uses the same version file. Update the pin and minimum together for later security releases.


    cd Service
    npm install
    npm test                                    # everything, on in-memory SQLite
    DATABASE_PATH=./banana.db DATA_DIR=./data PORT=8787 npm start

The data platform end to end, real engines and `HTTPSyncTransport` on the phone simulator against
this service on Node over plain HTTP, a fresh database every run: `tools/e2e-sync.sh` (from the
repo root; it seeds an account with `tools/e2e-seed.mjs` and runs `BananaTests/SpaceSyncHTTPTests`).

The SQLite file is created and migrated on start. Spaces (`DATA_DIR/spaces/<space>.sqlite`) and
blobs (`DATA_DIR/blobs/s/<space>/<sha>`, `trash/…`) are made as they're used; nothing empties
`trash/` on Node, so a cron `find DATA_DIR/blobs/trash -mtime +30 -delete` does what R2's rule does. Settings come from the environment (below).
APNs needs HTTP/2, which the Node entry has.

## On Cloudflare (live since 18 Oct 2026)

The live service, Durable Objects and static website use Cloudflare's managed Workers
runtime, not Node.js. `src/worker.js` does not import the Node entry or its Node adapters;
this configuration does not enable Node compatibility. The Node advisory is therefore
not a Node runtime upgrade for production Workers. Cloudflare manages runtime and native
dependency security updates; changing `compatibility_date` is not a security patch.
Use the pinned Node runtime for Wrangler/build/test tooling as well; both `Service` and
`LandingPage` select 24.22.1 through Volta.


Two deployments of this code, each with its own database, secrets and Google web client:

| | Stable | Beta |
|---|---|---|
| Address | `https://api.bananatheapp.com` | `https://beta-api.bananatheapp.com` |
| Worker / D1 | `banana-service` | `banana-service-beta` (`--env beta`) |
| Google project | the app's (411369…) | `banana-staging` (439702…) |

    cd Service
    npm test && wrangler deploy                 # Stable; add --env beta for Beta
    wrangler d1 migrations apply banana-service --remote
    wrangler d1 migrations apply banana-service-beta --remote --env beta

Secrets (`wrangler secret put NAME [--env beta]`, or `wrangler secret bulk file.json`): `TOKEN_KEY`,
`GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `APNS_KEY`, `APNS_KEY_ID`, `APNS_TEAM_ID`, all set on both.
The push key (id 4X8VPY735T, team scoped, sandbox and production) is `~/.config/banana/apns-key.p8`. Cloudflare can't show a secret back, so the two `TOKEN_KEY`s are also kept
in `~/.config/banana/service-token-key-{prod,beta}` (losing one means everyone connects Google
again), and the web clients in `~/.config/banana/google-web-client{,-beta}.json`.

The data platform's bindings (not created yet; each needs the author's yes): the `SPACES` Durable Object
namespace (class `Space`, migration tag `v1`, made by the first deploy), the R2 buckets
`banana-blobs` and `banana-blobs-beta` (`wrangler r2 bucket create NAME`), and later the `CHANGES`
pipeline (commented out in wrangler.toml). Each bucket needs a lifecycle rule that deletes
`trash/` after 30 days, the recovery window the privacy policy names:

    wrangler r2 bucket lifecycle add banana-blobs trash-30d trash/ --expire-days 30
    wrangler r2 bucket lifecycle add banana-blobs-beta trash-30d trash/ --expire-days 30

Locally: `wrangler d1 migrations apply banana-service --local`, then `wrangler dev --local`
(secrets in `.dev.vars`, which git ignores). Cron runs by hand with
`curl http://127.0.0.1:8787/cdn-cgi/handler/scheduled`. The Durable Object, its alarm and R2 all run
locally under `wrangler dev`; `--persist-to <dir>` keeps a smoke run's state out of `.wrangler`. Check the build without deploying:
`wrangler deploy --dry-run --outdir <dir>`.

Migrations: D1 is migrated only by `wrangler d1 migrations apply` (its table `d1_migrations`);
the SQLite adapter applies the same files itself on open (its table `migrations_applied`). A new
migration is a new numbered file in `migrations/`, never an edit to an applied one.

Usage report: `tools/telemetry/report.py` (`--local` reads `Service/.wrangler`).

### Deploy order for the data platform (each step with the author's yes)

The same order for both deployments; Beta first. 0009 goes on **before** the Worker: the device
upsert and `/v1/account` read 0009's columns, so a Worker ahead of its migration answers 500.

| Step | Stable | Beta |
|---|---|---|
| 1. The bucket | `wrangler r2 bucket create banana-blobs` | `wrangler r2 bucket create banana-blobs-beta` |
| 2. Its trash rule (30 days) | `wrangler r2 bucket lifecycle add banana-blobs trash-30d trash/ --expire-days 30` | `wrangler r2 bucket lifecycle add banana-blobs-beta trash-30d trash/ --expire-days 30` |
| 3. The migration | `wrangler d1 migrations apply banana-service --remote --env=""` | `wrangler d1 migrations apply banana-service-beta --remote --env beta` |
| 4. The Worker (makes the `Space` class, migration tag `v1`) | `npm test && wrangler deploy --env=""` | `npm test && wrangler deploy --env beta` |

Step 2's syntax is wrangler 4's own (`wrangler r2 bucket lifecycle add <bucket> [name] [prefix]`,
checked against `npx wrangler r2 bucket lifecycle add --help`, 4.151.2); `wrangler r2 bucket
lifecycle list <bucket>` shows the rule. `--env=""` names the top-level config, which silences the
several-environments warning. The pipeline (`CHANGES`) is a later step of its own.

Then, against `https://api.bananatheapp.com` or `https://beta-api.bananatheapp.com`:

    curl -s $HOST/v1/health                                   # ok
    curl -s -X POST $HOST/v2/sync -d '{}'                     # 401 {"error":"signed_out"}: the route is there
    curl -s $HOST/v1/account -H "authorization: Bearer $SESSION"    # seeded, flipped, icloud: "keep"
    curl -s -X POST $HOST/v2/sync -H "authorization: Bearer $SESSION" -H 'content-type: application/json' \
      -d '{"device":"<a device id of that account>","since":0,"changes":[]}'   # 200 {now, epoch, head: 0, …}

`tools/smoke-wrangler-dev.sh [beta]` runs the whole round locally first (`tools/smoke-wrangler-dev.md`
keeps the last transcript).

### APNs from a Worker

APNs only speaks HTTP/2, and workerd's own fetch is HTTP/1.1, so under local `wrangler dev` a
push fails (`Error: Network connection lost.`, 15 Oct 2026). Deployed, a Worker's requests go
through Cloudflare's proxy, which talks HTTP/2 to Apple (workerd's lead, cloudflare/workerd#4841).
So pushes can only be tried from a deployment. Should that ever change, pushes go out from the Node
entry somewhere else. A failed push is logged as `push: failed` and nothing else breaks.

## Move to another host

1. `wrangler d1 export banana-service --remote --output banana.sql` and `sqlite3 banana.db < banana.sql`.
   The export carries `d1_migrations`; the SQLite adapter reads it on first open and doesn't
   re-apply what D1 applied.
2. Run `src/node.js` there with the same environment variables (same `TOKEN_KEY`, or the stored
   refresh tokens can't be opened) and `DATABASE_PATH`.
3. Point the app's `BANANA_SERVICE_HOST` at it, and set `PUBLIC_URL` to its https address: the job
   renews every watch onto the new address within a week (or sooner, once the old ones near their
   end).

Postgres would be a third adapter (`?` → `$1…`); the SQL is plain (times are BIGINT ms, upserts are
`INSERT … ON CONFLICT … DO UPDATE`).

## Settings and secrets

| Name | What |
|---|---|
| `TOKEN_KEY` (secret) | base64 of 32 random bytes; encrypts Google refresh tokens (`v1.<iv>.<ciphertext>`, the Google `sub` as additional data). Rotating: add a `v2` key, keep `v1` to open old values. |
| `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` (secrets) | the *web* OAuth client the app names as `serverClientID` |
| `GOOGLE_REDIRECT_URI` (var) | empty for iOS `serverAuthCode` exchanges; confirm at the first real sign-in |
| `APNS_KEY`, `APNS_KEY_ID`, `APNS_TEAM_ID` (secrets) | the .p8 push key (PEM text), its id, the team id |
| `PUBLIC_URL` (var) | the service's https address; Google sends notices to `${PUBLIC_URL}/v1/google/notify` |
| `DATABASE_PATH`, `PORT` (Node only) | SQLite file (default `./banana.db`), port (default 8787) |

## Needs the author's yes before it is live

1. A web OAuth client in the Google Cloud project (its id and secret go to the service).
2. An Apple push key (.p8) for the service.
3. Push on the Mac app's App ID (the iPhone and iPad have it).
4. Deploying the service on Cloudflare, with its D1 database and secrets.
5. The privacy policy and terms wording for an account, and the website's "No server of ours in
   between".

## Cloud app

`https://app.bananatheapp.com/` (Beta: `https://beta-app.bananatheapp.com/`) is the
browser app for viewing synced data and managing calendar inclusion and alerts. It uses the live website's cream/ink/yellow palette, Plex Mono and pixel
wordmark. `src/web/page.js` serves its shell; `public/app/assets/` holds its client and styles.
These assets are part of the existing Worker deploy, with no separate build or hosting service.
The Node entry also serves them. Guest sharing uses migration `0011_web_sharing.sql` and recurring invitation receipts use `0012_series_invites.sql`; no additional OAuth registration is required.

Sign in with a Google account already linked to Banana. The existing web OAuth client's
registered API-host `/v1/google/callback` is used, asking only for `openid email profile`; a
browser-bound, single-use handoff (60 seconds, atomically consumed in D1) creates the app host’s
own cookie. Both hosts keep separate nonce cookies, preventing sign-in injection or a handoff
being replayed in another browser. Old API-host web URLs redirect to the app. Signing in here
never changes the stored calendar grants or creates a device. Browser sessions have `kind=web`,
expire after 30 days, and live in a host-only Secure/HttpOnly/SameSite=Lax cookie. Native API sessions cannot access browser reads or calendar controls; browser tokens cannot use native write APIs. Guest browser sessions can only read explicit web grants. Personal
responses are `no-store`, and signing out clears the page's in-memory copies. There is no
browser storage of personal records.

Views: Day and Week clock grids and routines/alarms/plans, meals/photos/supplements/doses/saved foods,
merged recorded and Apple Health workouts, detailed metrics/charts/routes/laps/splits/SWOLF,
90-day comparisons and full sensor recordings, Apple Health trends, podcast history/shows/progress/transcripts,
and voice notes/audio. Nutrition shows photos inline and in the meal detail. Calendar events are read on demand with the service's existing Google
access, never persisted by the web app; missing access is reported per account. The space's
`browse` and `webBlob` reads exclude deleted records and check the Health consent inside the
space. File requests must name a live record and one of its catalog blob fields, not an arbitrary
hash. Views refresh on return to the page and check for device syncs every minute; Refresh also
reloads the calendar. The Calendars screen groups calendars by account and edits Include in Banana and Notify me independently. These edits atomically patch the existing native settings snapshot, advance its sync clock and timestamp, preserve unrelated fields, and push other devices to sync. Requests require the app Origin and a web session, and only calendars available through that account can be changed. A modern native settings snapshot must already exist; the browser never seeds defaults over a device. Other data editing stays in the native apps.

Sharing is web-only and read-only. Owners select individual calendars (full details or busy only), routines, Workouts, Health, Food, Taken, Notes and Listening. A saved draft grants nothing; preview uses the same server projection as the recipient. Sending or publishing requires a current preview, and edits invalidate it. Invitations require the selected verified Google email, then bind to its Google subject. They create no native space membership. Revocation is checked on every data and blob request. Busy-only events contain no original metadata; combined Health snapshots are projected on the server so a narrower grant cannot download the original blob. Permission drafts do not change published access. Email delivery uses the existing Cloudflare email binding and is rate limited. `tools/web-preview.mjs` provides an isolated in-memory fixture and fake outbox for local QA; its authentication helpers are never imported by the Worker.

Health snapshots and transcripts are decoded in the browser using a vendored LZFSE decoder;
its source, license, upstream notices and the browser/output-size adaptations are documented
under `public/app/assets/vendor/`. `test/fixtures/web-*.lzfse` were generated with Apple's
libcompression, and `test/web.test.js` verifies decoding along with sign-in, account isolation,
consent, pagination, file authorization and the restricted calendar-settings write boundary.

For local UI QA with representative data (no production access):

    cd Service
    node tools/web-preview.mjs
    # Open http://localhost:8899/__preview/login

The preview binds to loopback and has its own in-memory database, fake Google and temporary
files. Its login helper is tooling only, never imported by the deployed Worker. Run the actual
service with `npm start` for real configured dependencies; web sign-in requires HTTPS and the
registered OAuth callback.

### Native behavior on the web

`src/web/calendar.js` ports `GoogleEventWindowBuilder`, `CalendarEventTitlePolicy` and
`AllDayEvents`: ownership markers for all Banana variants, placeholders versus invitations,
declined events, free events, deterministic richer-copy deduplication, flight duplicates,
calendar exclusions and all-day visibility. The flight dictionaries are generated from
`FlightParser.swift` and the native airport table with `python3 tools/web-flight-data.py`;
`--check` detects drift. The node tests mirror native regression cases.

`public/app/assets/plan-model.js` follows `PlannerTab`, `CalendarLaneAllocator`,
`OccurrenceProducers` and `ExceptionStore`: one 58px/hour timeline in Day and Week, synced week
start (Monday by default), local-date navigation across DST, stable lanes for overlapping
events, all-day spans, clock cues and extra slots, the phone’s synced wake plan, calendar-bound
cues, overrides and one-off alarms. Manual/on-workout-start cues keep their untimed semantics.
Calendar inclusion and notification choices are editable and shared across surfaces. Device-only reminders and other native planning/editing actions are not implemented by the web app.

`SmartScheduleSettings.mutedCalendarIDs` holds raw portable Google calendar IDs. Muting leaves events, busy time and watches intact; it filters local event/leave-by/commute notifications and device alert-calendar reports. A merged meeting remains audible if another source calendar is unmuted. The server checks the synced setting at dispatch, preventing stale device reports from bypassing a mute.

`workout-model.js` ports `WorkoutEntry.merge` (strictly less than 90 seconds), recorder source
preference, pause handling and lap stroke/SWOLF rules. The list includes Health-only history and
filters hidden Health IDs before merging. `workout-view.js` shows the measured summary series
and details that exist, with the saved distance units (browser locale when no override was
synced). Full recordings use the native 33-byte sample contract, parsed in a Web Worker with
bounded chart output. Recorded motion signals are viewable; the native hand-path/motion
analysis and map replay engines are not ported. Route traces use recorded coordinates without
sending them to a third-party map provider.

Recurring invitation announcements are deduplicated per account and series (Google iCalUID, falling back to calendar/master ID). A hashed receipt survives alert cleanup and covers new occurrences and copies on connected accounts. Baselines and known pre-upgrade series are seeded silently. This also covers automatically accepted invitations; per-occurrence lead reminders and actual reschedules remain independent. The alert body identifies a recurring series.

## Source licence and public deployments

Original code in this directory, including the browser client, is licensed under
AGPL-3.0-only; see [LICENSE](LICENSE) and [../LICENSING.md](../LICENSING.md). Vendored code
and npm dependencies retain their upstream terms. Shared code outside this directory
remains GPL-3.0-only; combining it with the service is permitted by section13 of both licences.

Before a public deployment, provide a prominent source link for remote users. It must
identify the exact deployed revision and supply its corresponding source, including
build/install scripts and required shared files, without login or payment. A moving
branch link alone is insufficient to identify the deployed revision. Source archives
must exclude secrets and production data. See the source-offer checklist in
[../docs/publication/readiness.md](../docs/publication/readiness.md).

### Versioned source offer

The service exposes `/source` (HTML) and `/v1/source` (JSON), without authentication,
on API, app and booking hosts. Web/shared-view headers and booking footers link to
`/source`; responses advertise it through an HTTP Link header. Set these deployment
variables together, using the exact reviewed release commit:

```text
SOURCE_REVISION=<full lowercase 40-character Git commit>
SOURCE_ARCHIVE_URL=https://github.com/<owner>/<public-repo>/archive/<same-commit>.tar.gz
```

The archive must be publicly downloadable and contain the corresponding source,
including the service, shared files and build/install inputs. URLs containing
credentials, query tokens, fragments, HTTP, or a moving branch are refused. An
unconfigured offer returns503 rather than claiming to provide source. Do not deploy
a public AGPL release until the archive is available and these settings are supplied.
Self-hosted mirrors may use a commit-pinned archive path too. No production source
settings or deployment are changed by the publication preparation.
