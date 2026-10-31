# One data platform: every kind of Banana data in the person's own account

Decided 19 Oct 2026, replacing the PowerSync + Postgres draft of 18 Oct. This builds on ACCOUNTS.md
(the account, sessions, Google links, the service). DATA-INVENTORY.md lists what moves. A Fable
review of the first version of this plan (19 Oct) found 16 defects. All are fixed below; §13 lists
them.

**What the author decided (19 Oct 2026):**
- **Storage.** Each space gets its own SQLite database in a Cloudflare Durable Object. For now that
  means each person's own space; shared spaces come later.
- **Analytics across people.** These come from a change stream into Iceberg tables in R2, never from
  querying the live databases. This answers his 18 Oct objection to one database per person
  (reporting and sharing).
- **Blobs** go in R2: workout samples, photos, audio, the Health snapshot and transcripts.
- **Mail comes later and is not in this build.** When it comes:
  - each mailbox gets its own database, holding headers, threads, labels and the search index;
  - bodies and attachments go in R2;
  - Gmail stays the record;
  - devices keep as much as they have room for, which is what on-device search runs on.
- **Exit plan.** Per-space storage sits behind one small interface: Durable Objects on Workers,
  SQLite files on Node. The record format and the sync protocol are ours. **There are no nightly
  exports** ("that sounds like it would add up quickly"). Recovery comes from Cloudflare's 30-day
  point-in-time restore for Durable Objects and D1, plus a 30-day trash for R2 (§9).
- **Scope:** "Build out this system fully end to end for everything other than email."
- **Reviews:** a Fable agent reviews this plan and every finished stage.

These stand from 18 Oct:
- every version is kept;
- Google is the only account;
- the service holds the keys;
- one uniform model and one process cover every kind of data;
- no health data goes in iCloud, ever.

## 1. Why

1. **Apple 5.1.3(ii): no personal health information in iCloud.** Today all of these sit in
   CloudKit, the iCloud key-value store and the iCloud Drive backup. This blocks the App Store
   release.
   - the Health snapshot;
   - Banana workouts with their samples;
   - meals;
   - supplements, medication and doses;
   - workout plans;
   - food corrections;
   - removal requests.
2. **The web, and the service acting for the person,** both need the data on our side. Our server
   can't read anyone's private CloudKit data.
3. **Ten channels with ten conflict rules** (inventory, last section). Examples:
   - lost Fitness deletes;
   - Fitness comparing a device's clock with server time;
   - `appSettings` with no timestamp;
   - key-value dictionaries where one device's write erases another's entries.

## 2. The shape

| Piece | What |
|---|---|
| **Space database** | One SQLite per space: records, their full history, the change counter, the blob index and the space's consents. On Workers it is a Durable Object (the `Space` class, with SQLite storage). On Node it is one file per space (`adapters/spaces-sqlite.js`). Both run the same `src/space.js`, which is **synchronous** over a two-call port, `{exec(sql, ...args) → rows, transaction(fn)}`. That port maps to `ctx.storage.sql` and `transactionSync` on Workers, and to `node:sqlite` on Node. |
| **D1** (unchanged) | Accounts, sessions, devices and links, plus `spaces`, `space_members` and the account-level consent log (migration 0009). |
| **R2** | Blobs, content-addressed under `s/<space>/<sha256>`. Deleted blobs go to `trash/<space>/` and expire after 30 days (lifecycle rule). On Node this is a directory. |
| **Change stream** | Accepted changes go to a Cloudflare Pipeline, into R2 Data Catalog (Iceberg), for R2 SQL or DuckDB. The binding is optional and off until the pipeline exists. |
| **The catalog** | `Shared/DataCatalog.json` lists every type with its tier, merge kind, writers, blobs and seed rule. The service and the app both read it. |
| **The app's mirror** | One SQLite (GRDB) per signed-in device: every record of the space, its clocks, and what is waiting to go up. Features keep their own stores, and adapters connect them to the mirror. |

Location: Durable Objects are made without a jurisdiction, so Cloudflare places each near its first
use. The privacy policy names Cloudflare as processor, with data in the US and EU. An EU
jurisdiction can be added per space later; changing it means copying the space.

Nothing syncs without a Google sign-in. A device with no account keeps its data on the device and
syncs nothing, through iCloud or any other way: on this build every iCloud channel is read-only
without a bound account.

**The switch.** The system is on by default, in Stable and Beta (`SpaceSyncFlag.isOn`); the launch
argument `--no-space-sync` turns it off, for tests. Because a device with no bound account writes
no iCloud, a device on this build stops writing iCloud at its first launch, before its account is
bound. That is kept as a floor on the device: once a device has stopped writing iCloud it never
starts again, so `--no-space-sync` brings back today's behaviour only on a fresh install (the UI
tests and the screen atlas pass it). **The service must be deployed before any device gets this build**: until a device's engine
has started, it neither writes iCloud nor syncs with the service, so its edits wait on it.

**One account per install.** The mirror belongs to an account, but the stores (`wellness.json`,
`health.json`) belong to the device. Signing in with a different Google account on a device that
already seeded asks once whether to clear this device's data first, and it seeds nothing until the
person answers yes. A first sign-in on a device that already has data, after the update, is not a
"different account".

## 3. The record and the merge

A record is `(type, id)` plus:
- `fields`: a JSON object;
- `clocks`: one hybrid logical clock (HLC) per field;
- `deleted`: a clock, or null;
- `seq`: the space's change number when the record last changed.

### Fields, worked out generically

An adapter turns a store's item into a JSON object, and its top-level keys are the record's fields.
Nothing is written by hand per field.

- **Canonical encoding.** Every adapter encodes through one encoder:
  - keys are sorted;
  - a `Set` becomes a sorted array;
  - dictionaries have sorted keys;
  - dates are integer milliseconds.

  Diffs compare canonical bytes, so encoding the same value twice never looks like a change.
- **A local change.** The mirror compares the new encoding with the last one this app made of the
  same record.
  - Each key whose value changed gets a new clock.
  - A key that was in the last encoding and is missing now has been cleared (a `nil` optional). It is
    sent as `null`.
  - **`null` is a value with a clock.** It is kept, merged and returned like any other value. Stores
    decode it as `nil`.
  - A key this app has never written, such as one from a newer app, is never touched.
  - Nested values (arrays, objects) move as one value. A type whose parts must merge separately is
    split into records.
- **The merge, the same on device and service:**
  - For each field the higher clock wins.
  - Equal clocks happen only on duplicates, since the device id is part of the clock. They compare
    as canonical JSON text, with `null` lowest.
  - `deleted` is a register too. The record is gone while its delete clock is higher than every field
    clock, and a later edit brings it back.
- **No-op changes are not changes.** A change that leaves a record exactly as it was is not
  accepted: no new `seq`, no history and no push. That makes retries safe.

### The clock

`HLC = "<13-digit ms>.<4-hex counter>.<device id>"`, which compares correctly as text.

- **Issuing** (standard HLC): `ms = max(physical + offset, lastIssued.ms, maxSeen.ms)`. The counter
  goes up when `ms` doesn't move.
- **Offset:** set from every answer's `now`, less half the round trip, whenever it is more than 30 s
  off. It is not waiting for a clamp, so a device up to five minutes fast doesn't win every merge.
  - `maxSeen` rises with every clock the device seeds, pulls or gets back in an answer.
  - `lastIssued`, `maxSeen` and `offset` live in the mirror's meta row.
- **The service** answers with its own time (`now`). A change carrying any clock more than 5 minutes
  ahead of `now` is **rejected** for that record (`clock`), never clamped: a clamped copy would be a
  new value on every retry and would keep beating other devices' edits (Fable, Stage A review). The
  device then sets its offset from `now`, lowers its HLC state to what it has really seen, shifts
  that record's pending clocks by the offset (keeping each edit's real time) and sends again. The service's own HLC is advanced past every clock it
  accepts.

### Seeding: today's data enters the mirror without bringing anything back

The first time a store's items go into the mirror (§8.1), the rules are these.

1. **The legacy engines read to the end first.** From this build's first launch every legacy
   engine is **read-only** (§2: no account bound yet), so nothing more goes to iCloud; it still
   fetches and applies what other devices wrote. What the device does meanwhile is kept for the
   seed: edits are in the stores, and deletes are kept on the device (the legacy engines' dirty
   items and tombstones, the deletes they can no longer send, and the move's own record of every
   delete made before the flip). Then, once its adapters exist:
   - It runs one complete fetch of every zone and key (the drain), so deletes made elsewhere are
     applied locally.
   - Fetches only report a delete against an earlier change token. After the fetch, a Wellness or
     Fitness item that is not dirty, that iCloud once confirmed (it has system fields) and that is
     absent from the zone's current contents is dropped before seeding. An item made here while
     read-only was never confirmed, so it is never dropped.
   - Items still dirty in the legacy engine count as local edits and are seeded; deletes iCloud
     never got are deleted in the space after the seed's pull, again until the flip, so another
     device's seed doesn't bring them back.
   - The drain's result is kept before anything changes: a tier past its drain never drains again.
2. **The hub seeds first.** A spoke (iPad or Mac) waits until `/v1/account` reports
   `seeded: [types]` for the account's iPhone, read-only meanwhile like everyone; its edits stay
   in its stores and its deletes are kept, for its seed. With no iPhone row active in the last 30
   days, a spoke seeds on its own, and phone-set kinds then seed as `edited`.
3. **Clocks:** each field's clock is the item's own last-edited time (`editedAt`, `updatedAt`,
   `syncDate`) with this device's id. Seeding from several devices therefore converges by today's
   rule.
4. **Phone-set kinds** (routine, alarm, wake): a spoke seeds nothing. On its first pull, if the server
   holds any item of that kind, the spoke drops its local-only items. This is today's
   `ControlMerge.localOnly`, kept as it is.
5. **Settings-like singletons with no timestamp** (`core.appSettings`, `core.modules`): every device
   seeds **only the fields that differ from the compiled default**, the hub at clock `1`, spokes at
   clock `0`.
   - When both differ from the default, the hub wins.
   - A spoke's real value beats a hub still on the default.
   - Nothing ever seeds a default, and any real edit after the update beats every seed.
   - Whole-dictionary key-value data with no time per entry (`plan.reminderAnchor`, `.usual`,
     `core.guestPick`, `food.searchPick`, `plan.declinedSuggestion`, `plan.notNow`,
     `plan.missedRepeat`) follows the same rule, one record per key.
6. **Late arrivals from the drain are seeds too.** A flipped device keeps the legacy readers running
   **read-only** until every device row active in the last 30 days has flipped, or 30 days have
   passed. Then it stops them. Whatever they bring in enters the mirror with its seed clock (the
   item's own `editedAt`), never with a fresh clock, so an old-build iPad's edit doesn't outrank a
   later one made elsewhere.
7. **Podcast progress ties.** A completed copy seeds at `<updatedAt>.0001.<device>`, a position-only
   copy at `.0000`. That is today's `ProgressTie` rule, written into the clock.
8. **Seeding runs off the main actor.** The adapter hands over one snapshot of its items per type,
   taken on the main actor, made of `Sendable` values. Encoding, diffing and writing to the mirror
   happen off the main actor in batches of 500. Each type's first pull reaches its store as one batch
   with one publish, as `applyingCloudBatch` does today.

### Kinds of merge (catalog `merge`)

- `field` is the default.
- `whole`: one field `v` holds the whole item and moves as one, for things whose parts only make
  sense together.
  - `health.snapshot` (a blob reference);
  - `podcast.progress` (`{position, completed}`; seed ties as in §3, seeding rule 7);
  - `core.hubStatus`;
  - `core.wakePlan`.
- `append`: once written, the record never changes. A second write of the same id is ignored. Used
  only where nothing is ever updated: `podcast.listen` is not append, because a listen is edited as
  it grows.

`health.removalRequest` is `field` with disjoint keys. The requester writes `request`, and the hub
writes `outcome`.

### Deletes, cascades and caps

- **Pruning is not deleting.** Stores cap what they keep locally: 1,500 meals, 100 workout
  completions, listen history. A cap drops items from the store only. The mirror never prunes, so a
  later edit elsewhere is never mistaken for a re-creation. Only a person's explicit delete sends a
  tombstone.
- **Cascades are sent by the deleting device.** Deleting a supplement sends a tombstone for each of
  its doses in the same request. Receivers apply the tombstones; they don't infer them.

### Text, blobs, history

- **Text CRDTs are not used in this build.** No note is edited on several devices at once: voice
  notes are recorded on one device, and transcripts are derived. Field-level last writer wins, plus
  every version kept, covers them. A text type adds `merge: "text"` later.
- **Blobs.** A field holding a file has the value `{"$blob": "<sha256>", "size": n, "ext": "jpg"}`.
  - The file goes up with `PUT /v2/blobs/<sha256>` before the patch that names it. A listen's route
    goes up once, when the listen has ended, so a route that grows doesn't leave a blob per
    update. Ordering is per
    record: one stuck upload holds back only its own record's patch.
  - The Worker streams the body into R2 with `put(key, body, { sha256 })`, so R2 checks the hash and
    nothing is held in memory.
  - After a successful put, the Worker records `(sha, size)` in the space's blob index. A patch that
    names a blob missing from the index is rejected (`blob_missing`), and the device uploads and
    sends again.
  - A blob is never overwritten.
  - The catalog sets the download rule per type:
    - **eager:** Health snapshot, meal photos, routes;
    - **lazy**, meaning on first use: workout samples on spokes, transcripts, voice-note audio
      (fetched when played, as today it isn't moved on an expensive network).
- **History.** Every accepted change appends `(seq, type, id, device, at, before, after)` with the
  changed fields only. It is never trimmed except:
  - by deleting the account;
  - by withdrawing the Health consent (§7);
  - by deleting the space.
- **The Health snapshot** is published at most once an hour, plus at once when a workout is removed
  or hidden. It is the one type whose old blobs aren't kept (catalog `keep: "latest"`): it is a
  derived copy of Apple Health, which holds the real history, and a blob of 1 MB or more per
  publish, kept forever, would outweigh everything else (final Fable review, 19 Oct). Its history
  rows stay; their blobs are gone.

## 4. The sync protocol

`POST /v2/sync` (session required):

```json
{ "space": "<optional, default: the personal space>", "device": "<id>", "since": 1234,
  "changes": [{ "type": "food.meal", "id": "…", "set": {"title": "Oats"}, "clocks": {"title": "HLC"},
                "delete": null, "schema": 1 }] }
```

Answer:

```json
{ "now": 1760900000000, "head": 1301, "next": 1290, "more": false,
  "applied": [{ "type": "…", "id": "…", "clocks": {…} }],
  "changes": [{ "type": "…", "id": "…", "fields": {…}, "clocks": {…}, "deleted": null, "seq": 1290 }],
  "rejected": [{ "type": "…", "id": "…", "reason": "consent" }],
  "consents": { "health": true } }
```

- **One request is one transaction** inside the space (`transactionSync`). Each record is accepted or
  rejected on its own, and nothing is ever half-applied.
- **Cursor.**
  - `changes` holds the current state of the records changed after `since`, in `seq` order.
  - `next` is the `seq` of the last one returned, and the device advances its cursor only to `next`.
  - `more` says to ask again.
  - A page stops at 1,000 records or about 4 MB, whichever comes first.
  - The records the caller just sent come back with their merged state.
- **Acknowledging.** `applied` gives the clocks the space now holds for each record the caller sent.
  The mirror clears an outgoing field only when the clock that came back equals the pending one, so
  an edit made while the request was out stays pending. This is today's `sent()` rule at
  `CloudControlsSync.swift:514`.
- **Checks:**
  - the type is in the catalog;
  - T2 types need the space's Health consent, checked **inside the space**, in the same transaction
    (§7);
  - `hub` types are written only by the account's iPhone, judged by the device row's platform, not by
    the request;
    that platform is what the device said when it registered: a same-person guarantee, not a security boundary;
  - a record's fields are at most 256 KB in total; anything bigger goes in a blob;
  - at most 500 changes per request, and a body of at most 2 MB;
  - each named blob is in the space's index.
- **Unknown fields are kept.**
- **Silent push.** After a sync that changed anything, the account's other devices get a push; the
  device that sent the changes doesn't.
  - Payload: `{"aps":{"content-available":1},"b":{"k":"sync"}}`.
  - Collapse id `sync`.
  - At most once every 3 seconds per account.
- **Transport.**
  - The Worker calls the space over Durable Object RPC: `sync()`, `recordBlob()`, `consent()`,
    `wipe()`, `counts()`. All of these are small; `counts()` keeps its answer in `meta` against the
    head seq, so repeated reads (a share's guest, the owner's page) cost one row until the space
    changes.
  - Export streams through `stub.fetch()` as a `Response`, never as an RPC return value (32 MiB
    limit).

Blob routes:
- `PUT /v2/blobs/:sha256` takes up to 100 MB (the zone's request limit). It answers 204, including
  when the blob is already there, and **always** records it in the space's blob index (which is
  idempotent), so a Worker that died between the put and the index heals on the next try.
- `GET /v2/blobs/:sha256` streams the blob; `HEAD` works on the same path.

Other routes:
- `GET /v2/export` returns every record with its history, plus the blob list (GDPR Art. 20).
- `PUT /v2/consents/health` and `DELETE /v2/consents/health`.
- `PUT /v2/devices/:id/sync-state` `{seeded, seededAt, flippedAt}` (`seeded`: the types this device
  has seeded). A device reports `seededAt` only when
  every record of its seed came back in `applied` and none in `rejected`.

## 5. The catalog: one list that drives everything

`Shared/DataCatalog.json`, one entry per type:

```json
{ "type": "health.workout", "tier": "T2", "merge": "field", "writers": "any",
  "seed": "edited", "blobs": {"samples": "lazy"}, "day": "startDate", "analytics": [] }
```

`seed` is one of:
- `edited`: the item's own time;
- `phoneSet`;
- `default`: clock 1, and only fields that differ from the default.

The service reads the catalog to validate. The app reads it for adapters, the mirror and download
rules. Tests fail when:
- a type is in an adapter but not in the catalog, or the other way round;
- a T2 type isn't covered by the Health consent;
- the privacy manifest doesn't declare a category the catalog uses.

Types (DATA-INVENTORY.md gives the source of each):

| Module | Types |
|---|---|
| core | `core.appSettings` (one record, `default` seed), `core.modules` (`default`), `core.hubStatus` (hub, `whole`), `core.hubRequest`, `core.guestPick` (one per name), `core.smartSettings`, `core.wakePlan` (hub, `whole`, derived; T2, as it's worked out from sleep and recovery) |
| plan | `plan.routine`, `plan.alarm`, `plan.wake` (all `phoneSet`), `plan.override`, `plan.extra`, `plan.taskDuration`, `plan.reminderAnchor`, `plan.reminderAnchorUsual`, `plan.missedRepeat`, `plan.declinedSuggestion`, `plan.notNow` (each former key-value dictionary becomes one record per key) |
| podcast | `podcast.show`, `podcast.settings`, `podcast.progress` (`whole`, per episode), `podcast.listen` (its route as a blob field), `podcast.skipPlan`, `podcast.adSlots`, `podcast.skipCorrection`, `podcast.narratorReading`, `podcast.narratorGender`, `podcast.narratorOverride`, `podcast.transcript` (blob) |
| notes | `notes.voiceNote` (its audio as a blob field) |
| health (T2) | `health.snapshot` (hub, `whole`, blob), `health.workout` (samples blob), `health.removalRequest`, `health.workoutRevert`, `health.workoutPlan`, `health.workoutCompletion` |
| food (T2) | `food.meal`, `food.supplement`, `food.dose`, `food.correction`, `food.myFood`, `food.mealInbox`, `food.mealPhoto` (blob), `food.mealPhotoFound`, `food.searchPick`, `food.estimatorStatus` (one per device), `food.photoScanReport` (one per device) |

**Things that waited in the old stores until something else arrived** stay in the mirror and are
replayed. Two cases today:
- show settings held back until the show exists;
- progress parked in `cloudProgressParked` until the episode exists.

An adapter's `apply` returns `false` when it can't take the record yet. The mirror keeps it, and
`SpaceSync.replay(types:)` offers it again; for example, `onShowsArrivedFromCloud` calls it. Nothing
is parked in UserDefaults any more. `ControlChangeReporter.offered` becomes a write at clock 0 (it
offers without overriding).

**What stays in iCloud** has no personal data and is needed before sign-in or between one person's
devices:
- the key-value keys `googleCalendar.accountHint.v1` and `podcastPeerGroupToken.v1`;
- the synced keychain items: the Google credentials and the Banana session.

Everything else in the inventory leaves iCloud.

Tiers:

| Tier | Covers |
|---|---|
| T0 | the account |
| T1 | personal data |
| T2 | health (§7). Food falls under the Health consent, as the 18 Oct draft proposed. |

## 6. On the devices

- **`RecordMirror`** (GRDB, in `Banana/Model/Sync/`) has tables for records, outgoing fields, pending
  records and meta (cursor, HLC state, offset).
  - The file is `sync/<account>.sqlite` in Application Support, excluded from backup.
  - It never prunes.
- **`SpaceSync`** is the engine, an actor. It:
  - sends what's waiting, then pulls after the cursor until `more` is false;
  - hands merged records to adapters on the main actor, one batch per type;
  - uploads blobs before the patches that name them, record by record;
  - downloads blobs according to the catalog.
- **When it syncs:**
  - a local change, after 2 seconds of quiet;
  - coming to the foreground;
  - the `sync` push, also in the background under a background task;
  - every 60 seconds while open (`CloudSyncPoll` keeps running for the legacy readers until the retire
    release);
  - on the Mac, also when no window is open.
- **`RecordAdapter`**, one per area, wrapping today's seams (inventory, "Seams"):

  ```swift
  @MainActor protocol RecordAdapter: AnyObject {
      var types: [String] { get }
      /// Every local item of a type, taken once on the main actor; encoded and diffed off it.
      func snapshot(_ type: String) -> [String: any Encodable & Sendable]
      func seedClock(_ type: String, id: String) -> Date?          // nil: no own time (§3 seeding)
      /// false: can't take it yet (its parent isn't here); the mirror keeps it for replay.
      func apply(_ type: String, records: [(id: String, fields: [String: JSONValue])]) -> [String: Bool]
      func remove(_ type: String, ids: [String])
      func blobFile(_ type: String, id: String, field: String) -> URL?
      func storeBlob(_ type: String, id: String, field: String, file: URL)
  }
  ```

  Stores keep reporting changes the way they do now:
  - `ControlChangeReporter.changed`, `.deleted` and `.offered`;
  - `WellnessStore` → `saved` and `deleted`;
  - `FitnessStore` → `upsert` and `delete`;
  - `PodcastLibrary` → `enqueue`.

  These calls now go to `SpaceSync.changed(type:ids:)` and `.deleted(type:ids:)`.
- **Hub rules are unchanged.** Only the iPhone:
  - reads Health;
  - publishes `health.snapshot`, `core.hubStatus` and `core.wakePlan`;
  - carries out removal requests;
  - arms alarms.
- **The Watch** keeps getting everything from the iPhone over WatchConnectivity.
- **Returning person.** Today `CloudBackup.onReturningUserDetected` marks onboarding done for someone
  coming back. That now happens when the first pull of a new device finds a non-empty space.
- **The backup stops** once the device has moved (`CloudBackup.isRetired`): its Settings row
  disappears, and `HubRequest.backUpNow` does nothing. The service is the copy. The code itself
  (`AppSettings.backupEnabled`, `BackupRules`, `CloudBackup`) goes with the retire release (§8.3).

## 7. Health consent (GDPR Art. 9)

- **When it's asked.** One screen with a yes, on **whichever device is first about to send T2
  data**: after the update, or when Health or Nutrition is first used.
  - The question is per account, so once one device has the yes, every device has it.
  - Settings › Account has one switch to withdraw it.
- **Where it's kept:**
  - inside the space (a `consent` row, read by the T2 check in the same transaction);
  - in D1's consent log: account, kind `health`, words version, when, device.

  `PUT/DELETE /v2/consents/health` write the space first, then the D1 log, and both writes are safe
  to retry. The space's write and the T2 wipe are one transaction, so no sync in flight can slip T2
  data in after a withdrawal.
- **Devices learn it from every sync answer** (`consents.health`). A device that missed a withdrawal
  drops its outgoing T2 fields and its T2 mirror rows on the next answer.
- **Without it.** T2 types stay on each device and don't sync, and they don't go to iCloud either.
  The iPad and Mac show no Health, and Nutrition shows only what was logged on that device. The
  question is not asked again on its own. Using Health or Nutrition on a second device offers it once
  more.
- **Withdrawing:**
  - devices stop sending T2;
  - the space hard-deletes every T2 record and its history in one transaction, and its blobs go to
    the R2 trash (gone after 30 days). A Durable Object alarm moves them in batches of about 200,
    because one request can't make thousands of R2 calls. The withdrawal answers at once;
  - devices drop their T2 rows from the mirror but keep their stores. The data stays on the device
    and stops leaving it.
- **Words:** as few as possible (house rule). The privacy policy and App Privacy change in the same
  change (§10).

## 8. Moving off iCloud

Each area goes through four steps.

1. **Seed** (§3, "Seeding"):
   - the legacy readers are read-only from the first launch, and fetch to the end once (the drain);
   - the hub seeds first, then the spokes, under the per-kind rules.
2. **Flip.** After its seed is acknowledged, the device stops **writing** iCloud for good, except the
   two kept keys and the keychain. Its legacy readers stay on, read-only, under §3 seeding rule 6.
   Its device row records `seeded_at` and `flipped_at`.
   Deletes that old builds make after a device has flipped reach its read-only drain but aren't
   carried into the space: old builds are transitional.
3. **Retire.** The legacy code is removed in the **next** release, once every device row active in
   the last 30 days has flipped. That covers:
   - `CloudControlsSync`, `CloudWellnessSync`, `CloudProgressSync`/`CloudFitnessSync` and
     `CloudSettingsSync`;
   - `CloudZonePoller`, `CloudSyncPoll` and `CloudChangeCheck`;
   - `CloudBackup`;
   - the meals zone subscription;
   - the per-store key-value listeners.

   The read-only drain in this release is what makes the seed safe.
4. **Purge.** Everything Banana left in iCloud is deleted:
   - the six CloudKit zones;
   - the moved key-value keys;
   - `Documents/backup.plist`, `previous-backup.plist`, `Transcripts/` and `VoiceNotes/`;
   - the legacy container's records (`AppCloud.legacyContainerID`), which also hold old Health
     snapshots;
   - the bad Fitness records (`CloudFitnessZonePurgeTool`).

   **The gate.** `/v1/account` returns `"icloud": "purge"` only when every device row active in the
   last 30 days has both `seeded_at` and `flipped_at`. A seed counts only once every record in it was
   acknowledged.
   - Counts are not compared: deletes and local caps make them differ legitimately.
   - With the Health consent declined, T2 was never sent, and the devices keep their own copies.

   For the author's account the flag also waits for his yes (`icloud_purge_ok`), because a purge can't be
   undone. Any device that sees the flag purges. While the flag stands, every flipped device purges
   again once a week, because an old-build device coming back after 30 days would otherwise recreate
   a zone.

The App Store build is the one that carries the purge. A store build is reviewed with the read-only
drain still in it. That's allowed: it reads what earlier builds wrote and deletes it, and writes
nothing health-related to iCloud.

## 9. Analytics, deletion, export

- **Analytics:**
  - Each accepted T1 change sends `{at, space: HMAC(space), type, op, day, fields}` to the
    `CHANGES` Pipeline binding, when the binding exists. `fields` holds only the catalog's
    `analytics` fields, and never free text.
  - T2 changes send only `{at, type, op}`, with no space and no day, so the stream counts health
    activity without describing anyone's.
  - The pipeline and its R2 bucket are created with the author's yes.
  - The usage counts (TELEMETRY.md) stay as they are.
- **Account deletion** (`DELETE /v1/account`):
  - every space the account alone belongs to is wiped: the Durable Object's `deleteAll()`, and its R2
    blobs moved to the trash;
  - the D1 rows go, as today.

  Copies remain for up to 30 days: in the Durable Object's point-in-time recovery, in D1 Time Travel
  and in the R2 trash. The privacy policy says so.
- **Recovery:**
  - a bad change in a space is undone from its history, or from the Durable Object's point-in-time
    restore (`getBookmarkForTime`) within 30 days;
  - blobs are never overwritten, and deleted ones sit in the trash for 30 days.
- **Export:** `GET /v2/export`. There's no button yet; one comes with the web build.

## 10. Privacy declarations, in the same change

- **`PrivacyInfo.xcprivacy`** adds these categories, all linked and all for app functionality:
  - **Health:** the Health snapshot, meals, supplements, doses;
  - **Fitness:** workouts;
  - **Precise Location:** workout and listen routes;
  - **Photos or Videos:** meal photos;
  - **Audio Data:** voice notes;
  - **Contacts:** guest picks, which are names and addresses of other people.

  Other User Content stays.
- **App Store Connect App Privacy:** the same answers, kept in `tools/app-store/app-privacy.md`.
- **The privacy policy** (`LandingPage/site/privacy.html`):
  - Lines 30–32 today say data stays in iCloud, Health data is never sent to us, and places are kept
    in iCloud. They will say instead:
    - what Banana keeps on its service, and why;
    - Health data only with the person's yes, never in iCloud;
    - nothing of theirs left in iCloud except their Google sign-in in their own keychain.
  - A "What we keep for you" section is added, with health data under explicit consent.
  - It names Cloudflare as processor and where data is held.
  - It gives the 30-day recovery and trash windows.
  - It says nothing health-related is in iCloud.

## 11. Out of this build

- Mail.
- The web app, which will read the same spaces.
- A sharing UI. Spaces and membership exist, and the protocol carries `space`.
- An export button.
- Text CRDTs.
- The service working out the day.
- An EU jurisdiction.

## 12. Build plan

| Stage | What | Done when |
|---|---|---|
| **A. Service** | `space.js` (synchronous: schema, merge, history, pull with `next`, the blob index, the consent row, counts, wipe); the `Space` Durable Object and the Node adapter; `wrangler.toml` bindings (`durable_objects`, a `[[migrations]]` with `new_sqlite_classes`, `r2_buckets`, the optional pipeline), all repeated under `[env.beta]`; migration 0009; `/v2/sync`, blobs, consents, counts, export; account-delete wipe; the sync push; the change stream; the catalog import | `npm test` covers: **convergence** (many simulated devices, random offline edits, duplicates, reordering, retries after lost answers, skewed clocks, deletes racing edits → the same state everywhere); paging by count and bytes; no-op idempotency; consent racing a sync; hub-only writes; blob index; export streaming; delete; push skipping the sender. Also a `wrangler dev` smoke run with the Durable Object and R2. |
| **B. App engine** | GRDB (an xcodegen `packages:` entry, `exactVersion`); canonical encoder; HLC (issue, receive, offset); field diff; `RecordMirror`; `SpaceSync`; transport; blob queue per record; replay; the catalog loader; the `sync` push on iOS and Mac | Unit tests: HLC order, receive and offset; canonical encoding, including a `Set` and a dictionary; diff (cleared optionals, unknown keys kept); merge identical to the service's on the **same fixture file** run by both suites; engine against an in-memory transport (offline queue, `next`/`more` paging, ack only on equal clocks, rejected, blob order per record, replay) |
| **C. Health and food** | Adapters for every T2 type; the consent screen and switch; hub-only publishing; the snapshot debounce; removal and revert requests as records; dose cascades | The simulator, with fakes only, against the local Node service: a meal logged on the "phone" appears on the "Mac" run; a workout with samples round-trips; withdrawing clears T2; a delete made before the update is not brought back |
| **D. Everything else** | Adapters for the plan, podcast, notes and core types; the key-value stores rewired; the read-only drain and seed order; the returning-person check; the backup row removed | The same simulator check per area; podcast progress survives, including the parked case; phone-set kinds don't multiply |
| **E. Flip, purge** | Flip; the purge behind the flag and gate, repeated weekly; the legacy container | The purge tested against a fake CloudKit seam; a grep check: no CloudKit or key-value **writes** remain except the two kept keys |
| **F. Declarations** | The manifest, the App Privacy doc, the privacy policy | The catalog check passes; `check_site.py` passes |
| **G. Fable review** of everything, then the author's yes for each of these | The service deploy and migration (Beta, then stable); the Pipeline; the Beta install on his devices (this uploads his real Health to the Beta service); then stable; then the purge on his account | |

A Fable agent reviews each stage's diff against this document before the next stage starts.

Performance (house rule): the mirror's cost at launch and on the first seed is measured on the
simulator with about 2,000 meals, 3,000 listens and 300 workouts, then again on a device.

## 13. Fixed after the Fable review (19 Oct)

1. Seeding no longer brings back deletes or multiplies phone-set kinds: there's a read-only drain
   first, the hub goes first, and the phone-set rule is kept (§3).
2. Clocks follow the standard HLC receive rule and learn the server's offset (§3).
3. Consent lives inside the space, in the same transaction as the wipe. The purge no longer waits
   forever when consent is declined, and consent is asked on whichever device is first (§7, §8).
4. A removal request is `field` with disjoint keys, not `append`.
5. Settings with no timestamp are seeded by the hub, and spokes seed only non-default values (§3).
6. Podcast progress is `whole` with today's tie rule, and parked or held-back items are replayed
   (§3, §5).
7. Cursor `next`, paging by bytes, no-op idempotency, acknowledging only on equal clocks, one
   transaction per request, export over `fetch` (§4).
8. Blobs stream into R2 with its hash check, have their own index, and wait per record (§3, §4).
9. `space.js` is synchronous over a two-call port; the wrangler bindings are spelled out (§2, §12).
10. R2 trash with 30-day expiry, since R2 has no point-in-time restore (§2, §9).
11. Contacts declared, policy lines 30–32, and no space or day on T2 analytics (§9, §10).
12. Canonical encoding, so sets and dictionaries don't produce false changes (§3).
13. Returning-person check, the backup's removal listed, the purge gate covers every recent device
    and the legacy container, one account per install (§2, §6, §8).
14. Cascades are sent by the deleting device; the mirror never prunes (§3).
15. Seeding off the main actor through snapshots (§3, §6).
16. `null` as a value, the snapshot debounce, the push skips the sender (§3, §4).

Second pass (19 Oct):

1. Devices keep the legacy engines read-write until seeded. Flipped devices drain read-only until
   all have flipped, and drained items enter as seeds.
2. Once-synced items absent from their zone are dropped before seeding.
3. The purge gate is "every seed acknowledged", not counts.
4. `PUT` blob always indexes; wipes move blobs by Durable Object alarm in batches.
5. `default` seeds: only non-default fields, hub at clock 1, spokes at clock 0.
6. The offset is learned on every answer.
7. Progress ties are written into the seed counter.
8. Consent write order, `consents` in every answer, a weekly re-purge.
9. Routes upload once ended; the policy's target text; stale iPhone rows; Mac-only testers.
