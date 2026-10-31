# Banana accounts and the Banana service

Decided 15 Oct 2026. Banana gets an account and a small service of its own. Slice 1 uses it for
three things: calendar changes reach every device within seconds, usage is counted per account,
and the account can be deleted from Settings. Mail stays on the device for now and moves onto the
service later, so everything here is built to carry it.

## The account

- **Google sign-in is the account.** Connecting a Google account in Banana also hands the service
  a one-time code (Google Sign-In's `serverAuthCode`, requested with a *web* OAuth client as
  `serverClientID`). The service trades it for its own refresh token. There is no password and no
  separate sign-up.
- An account has one or more Google accounts linked. A Google account (by Google's `sub`) belongs
  to one Banana account. Connecting a second Google account on a signed-in device links it to the
  same Banana account.
- **Devices share one session.** The session token goes into the same iCloud Keychain item family
  as the Google credentials, so signing in on one device signs in the others, as Google already
  does. Each device registers itself (`device id` → push token) under the session.
- **A session lives until Google stops saying yes** (The author, 18 Oct 2026: like Google Calendar's
  own sign-in). It never times out. When Google refuses a link (invalid_grant: access removed,
  password changed, account disabled or deleted), the link forgets its refresh token and its
  watches; when that was the account's last working link, the account's sessions end. The job
  asks Google about each working link once a day, so a refusal is noticed within a day.
- **Nothing is deleted without a working Google sign-in.** An account whose Google links all
  fail goes dormant and stays (Google id, email, devices, usage) until its owner signs in again,
  which finds the same account by Google's `sub`. No automatic deletion.
- **Deleting** the account (Settings, later the website) needs a fresh Google sign-in: its
  one-time code, from a Google account linked to the account, goes with the request. A session
  alone never deletes. Deleting stops every calendar watch, revokes every Google token at
  Google, and deletes every row about the account, usage included.
- **Disconnecting** a Google account in Banana keeps its `sub` and email (status `unlinked`, no
  token, no watches), so it can sign in to the same account again and delete it.

## What the service holds

| Table | What | Why |
|---|---|---|
| `accounts` | id, created | the account |
| `google_links` | sub, account, email, refresh token (encrypted), scopes, status (ok, refused, unlinked), last checked | to watch calendars, later mail; who may sign in and delete |
| `sessions` | SHA-256 of the token, account | sign-in |
| `devices` | device id, account, platform, push token, push environment, bundle id | to push |
| `watches` | Google channel id, account, link, calendar id, resource id, secret, expiry | Google's change notices |
| `calendar_sync`, `event_state`, `alerts`, `held_alerts` | sync tokens, event times/status/reply + title hash, alerts to send (title, words) for a day, which device holds which alert | event alerts (docs/design/EVENT-ALERTS.md) |
| `account_usage` | account, day, event, name, detail, platform, version, count | usage per account |
| `counts` | the anonymous daily totals from before (docs/design/TELEMETRY.md) | unchanged |
| `audit` | account, time, action (link, unlink, delete, google refused, watch failed) | access log |

No attendees or mail, and no events beyond what event alerts need (docs/design/EVENT-ALERTS.md,
19 Oct 2026): per calendar a sync token; per event its times, status, his reply and a hash of its
title; and for each alert waiting to be sent, its title and the words of the push, deleted a day
after it is sent or cleared. Google's notice carries nothing: only "this calendar changed".

**Refresh tokens** are encrypted with AES-256-GCM. The key is a secret of the deployment
(`TOKEN_KEY`), never in the database; each value carries its key version (`v1.`) so the key can be
rotated. The Google `sub` is the authenticated data, so a value can't be moved to another row.
This is what Google's yearly security assessment for Gmail access will look at, so it is in place
from the first slice.

## Calendar changes, end to end

Since build 57 (18 Oct 2026) the devices do the watching; the service only answers Google and
pushes. Nothing is turned on: every connected Google account joins by itself.

1. **Joining.** For each Google account connected in Banana that the Banana account doesn't hold
   yet, the app mints Google's identity token with the refresh token it already has and sends it
   (`POST /v1/google/identity`). The service checks Google's signature, the issuer, the app's
   client as audience, the expiry and the verified email, and signs the device in or links the
   account. No sign-in sheet, no code, and the service gets no Google access of its own.
2. **Watching.** The app asks the service for a channel (`POST /v1/google/channels`: an id, a
   secret, the notify address, a week), opens it at Google itself (`events.watch`, with the
   device's own access token), and reports Google's answer (`PUT /v1/google/channels/:id`).
   `BananaService.watchPlan` settles the account's watches on one live watch per wanted calendar:
   it renews the ones ending within a day (new first, then the old one closes), closes spares and
   the ones no longer read, and leaves another device's pending one alone. Calendars Google won't
   watch (holidays, subscribed feeds) are remembered per device and read by the ask instead.
   Every pass (launch, coming forward, the calendar list or the excluded set changing, and every
   six hours while the app runs) brings the watches in line.
3. **Notice.** Google calls `POST /v1/google/notify` when a calendar changes. The service checks
   the channel's secret and sends every device on the account a silent push
   (`content-available`, `{"b":{"k":"calendar"}}`, collapse id `calendar`), at most one per
   account every 3 s. What APNs answered is written on each device row (`pushed_at`,
   `push_status`), so a push can be traced from the database.
4. **The device.** In front, it asks Google once (the incremental read it already has), logs
   `☁️ push` in the journal, and when something is new recomputes within a second. In the
   background on a phone, it runs the look the background refresh makes
   (`CalendarWriteBackRefresh.look`). Pushes go to the APNs environment the build registered
   with: hand-installed builds `development` (sandbox), TestFlight and the App Store `production`.

On a closed iPhone iOS decides whether a silent push wakes the app, and limits how many do. With
the app open, or the Mac running, a change shows in seconds; without a push, the app still asks
every two minutes in front and every five behind.

What goes wrong on its own stays off the screen: a pass the service couldn't be reached during is
retried after a minute and after five, and the journal has it (`☁️ account` lines). Settings
shows one line of state, "Calendar changes: Instant" (this device's push token is with the
service and a Google account has a live watch) or "Every 2 minutes", and Delete account.

**Busy blocks stay on the devices in slice 1.** What they mirror (scheduled tasks, routines,
travel between places) is the plan, which lives in iCloud and is worked out on the device. Writing
them from the service needs the plan's inputs on the service: that is a later step, and the
reason to keep devices as the only writer until then (two writers would fight).

## Moving off Cloudflare

The service is ordinary HTTP code with its platform pieces behind small interfaces:

- **HTTP:** Hono, which runs unchanged on Workers, Node, Bun and Deno.
- **Database:** one interface (`all`, `first`, `run`, `batch`) with two adapters: D1 and Node's
  built-in SQLite. The SQL is plain (no SQLite-only features), and the migrations in
  `Service/migrations/` are applied by both. Postgres would be a third adapter (`?` → `$n`).
- **Work after the response** (`defer`): `waitUntil` on Workers, a caught promise on Node.
- **The 15-minute job:** a Cron Trigger on Workers, a timer on Node.
- **Crypto:** WebCrypto only, which both have.
- **Secrets and settings:** environment variables on both.

`Service/src/node.js` runs the whole service on any machine with Node 24; the tests run it that
way.

**Apple's push service needs HTTP/2.** Workers' own `fetch` speaks HTTP/1.1, so under local
`wrangler dev` a push fails ("Network connection lost", 15 Oct 2026). Deployed, a Worker's
requests go through Cloudflare's proxy, which talks HTTP/2 to Apple: the workerd lead says so
(github.com/cloudflare/workerd/issues/4841, Aug 2025) and others send APNs pushes from Workers
that way. Checked from our own account on 18 Oct 2026: a deployed Worker's push with our key to a
made-up device came back `400 BadDeviceToken` from both production and sandbox APNs (key accepted). If it ever stops, pushes go out from the Node
entry (`src/adapters/http2.js`) on another host.

## API

All JSON. Signed-in calls carry `Authorization: Bearer <session>`.

| Call | Body | Answer |
|---|---|---|
| `POST /v1/google` | `{code, device}`; signed in or not | `200 {session?, account}`. Not signed in: the account the Google account belongs to, or a new one, and a session. Signed in: links it to this account. `401 {error:"google_refused"}`, `409 {error:"other_account"}` |
| `GET /v1/account` | | `200 account` |
| `DELETE /v1/account` | `{code}`: a fresh Google sign-in's; a session is optional | `204`, everything gone. `401 {error:"google_sign_in_required"\|"google_refused"}`, `404 {error:"no_account"}`, `409 {error:"other_account"}` |
| `PUT /v1/devices/:id` | `{platform, push, pushEnv, bundle}` | `204` |
| `DELETE /v1/devices/:id` | | `204` |
| `POST /v1/google/identity` | `{idToken, device}`; signed in or not | as `POST /v1/google`, with Google's identity token for the app's own client: no Google access granted to the service |
| `GET /v1/google/channels` | | `200 {channels: [{id, email, calendarId, resourceId, status: pending\|live\|failed, expiresAt}]}` the device-made watches |
| `POST /v1/google/channels` | `{email, calendarId}` | `201 {id, token, address, ttlSeconds}`: what to open at Google |
| `PUT /v1/google/channels/:id` | `{resourceId, expiration}` Google's answer | `204`; the watch is live |
| `DELETE /v1/google/channels/:id` | | `204` |
| `PUT /v1/google/calendars` | `{email, ids}` | `202 {watching}` (build 56: the service's own watches, for links made with a code) |
| `DELETE /v1/google` | `{email}` | `204`: watches stopped, token revoked; the link stays as `unlinked` |
| `POST /v1/google/notify` | Google's headers | `200`, always |
| `POST /v1/usage` | the usage batch; signed in or not | `204` |
| `GET /v1/health` | | `200` |

`device` is `{id, platform: iphone|ipad|mac, push: hex|null, pushEnv: development|production,
bundle}`. `account` is `{id, google: [{email, status: ok|refused, watching, access}], devices}`.
`access` is whether the service holds working Google access of its own for that Google account
(a sealed refresh token from a sign-in with a code, not refused). `status` is `refused` only
when Google rejected the token the service held; a sign-in that brings no token leaves it `ok`.

## The service's own Google access (19 Oct 2026)

Joining by identity token gives the service no Google access, and for event alerts sent by the
service (docs/design/EVENT-ALERTS.md) it needs to read events itself. So every connected Google
account signs in once more, with a code: the app requires it. `BananaAccount` reads `access` from
each description of the account and hands `GoogleCalendarService` the connected accounts without
it (`accountsNeedingServiceSignIn`); they show "Sign in again" wherever a rejected account already
does (the Accounts & calendars status, the account's row, the diagnostics page), with no other
words. The tap is the existing reconnect: Google's sheet with the account preselected, and its
`serverAuthCode` goes to `POST /v1/google`. New sign-ins (first run, Add account) send their code
the same way, so nobody new takes the extra step.

Google leaves the refresh token out of an exchange when the person already granted this web
client offline access and the grant still stands. For the author's four accounts the web client has
never been granted (every link so far was made by identity token), so the first exchange brings
one. The cases that revoke the grant (Delete account, Disconnect, Google's invalid_grant) also
clear the way for the next sign-in. If an exchange ever brings none, the service logs `google:
code exchange brought no refresh token`, the app journals `signed in with a code, but the service
still lacks Google access`, and the row keeps asking: the fix then is to revoke the web client's
grant for that account before the sign-in.


## In the app

- `BANANA_SERVICE_HOST` (replaces `BANANA_TELEMETRY_HOST`) and `BANANA_GOOGLE_SERVER_CLIENT`
  (the web client) in the private config. Without both, nothing here runs: anyone's own build and
  the Beta stay as they are.
- `BananaAccount` (Banana/Model): the session, joining by identity token, this device's
  registration, the watches at Google (`BananaService.watchPlan`), deleting. `BananaService` is the
  pure part (calls, plans, the state rule), tested in `BananaServiceTests`.
- Silent pushes with `"b":{"k":"calendar"}` run `SmartScheduleStore.calendarChangedElsewhere()`:
  in front, one ask of Google and a recompute within a second; in the background on a phone,
  `CalendarWriteBackRefresh.look(reason: "push")`. The journal line is `☁️ push`.
- Settings › Accounts & calendars: "Calendar changes: Instant | Every 2 minutes" and Delete
  account, the same on iPhone, iPad and Mac. No other control.
- Usage batches carry the session when there is one.

## Where it stands (18 Oct 2026, evening)

Done: both web OAuth clients; both services deployed with their databases and secrets
(`api.bananatheapp.com`, `beta-api.bananatheapp.com`, Service/README.md); push on both App IDs and
`aps-environment` in every entitlements file; the privacy policy and terms wording, live on
bananatheapp.com; the Mac Beta shares the iPhone Beta's bundle id and Google client, and each Beta
build names its own service; joining by identity token and device-made watches (build 57); the
push record per device, the retry, the keep-alive and the state line (build 58).

Seen working on Stable: one account with four Google accounts, twelve live watches, four devices
with push tokens; Google's notices reach the service (`accounts.last_push_at`).

Still open: the Beta has made no account yet (not opened since its service went live); the
website sign-in; no health-derived counts in per-account usage.
