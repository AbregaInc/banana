# `wrangler dev` smoke: the data platform on workerd

Evidence that the service runs on the Workers runtime with its Durable Object, D1 and R2, for both
wrangler configs, before anything is deployed. Made by `tools/smoke-wrangler-dev.sh` (default) and
`tools/smoke-wrangler-dev.sh beta`: a fresh local state each time (`--persist-to` a temporary
folder, never `.wrangler`), migrations 0001–0009, one seeded account, session and iPhone row, then
the calls below. Nothing remote is touched. Answers are trimmed (long ids shortened). Pushes fail
locally (no APNs key under `wrangler dev`; README, "APNs from a Worker") and are left out.

## `wrangler dev --local` default

wrangler 4.151.2, 2026-10-19T23:12Z, D1 `banana-service`, R2 `banana-blobs`

**Migrations 0001–0009 on a fresh local D1**

```
$ wrangler d1 migrations apply banana-service --local --persist-to <tmp> --env=
 0001_init.sql ✅ 
 0002_link_lifecycle.sql ✅ 
 0003_device_channels.sql ✅ 
 0004_push_record.sql ✅ 
 0005_event_alerts.sql ✅ 
 0006_alert_devices.sql ✅ 
 0007_plan_ahead.sql ✅ 
 0008_diagnostics.sql ✅ 
 0009_spaces.sql ✅ 
```

**Bindings wrangler dev reports**

```
env.SPACES (Space) Durable Object local
env.DB (banana-service) D1 Database local
env.BLOBS (banana-blobs) R2 Bucket local
```

**A build-61 device registration (the body before 0009) still works**

```
$ PUT /v1/devices/mac-smoke001 {platform, push, pushEnv, bundle}
204
```

**A sync**

```
$ POST /v2/sync plan.extra e1
{"head":1,"next":1,"more":false,"applied":[{"type":"plan.extra","id":"e1","clocks":{"title":"1792451570000.0000.phone","day":"1792451570000.0000.phone"},"deleted":null}],"rejected":[],"consents":{"health":false}}
```

**T2 refused without the Health consent; a clock an hour ahead refused**

```
$ POST /v2/sync food.meal m1; plan.extra e2 at now + 1 h
{"head":1,"rejected":[{"type":"food.meal","id":"m1","reason":"consent"},{"type":"plan.extra","id":"e2","reason":"clock"}],"consents":{"health":false}}
```

**Blob PUT: wrong sha, right sha, 20 MB, and the 20 MB back**

```
$ PUT /v2/blobs/<zeros> (notes.voiceNote)
400 0.014171s
$ PUT /v2/blobs/<sha> (notes.voiceNote)
204 0.009345s
$ PUT /v2/blobs/<sha of 20 MB> (podcast.listen)
204 0.292960s
$ GET /v2/blobs/<sha of 20 MB>
200 20971520 bytes 0.034256s
byte for byte the same
```

**Consent, a T2 photo, then the withdrawal: the alarm moves the photo to trash/**

```
$ PUT /v2/consents/health
204
$ PUT /v2/blobs/<photo> (food.mealPhoto)
204 0.010657s
$ POST /v2/sync food.mealPhoto p1 naming it
{"head":2,"rejected":[],"consents":{"health":true}}
$ DELETE /v2/consents/health
204
HEAD /v2/blobs/<photo>: 404 after 1 look(s)
R2 keys now (space id shortened):
s/sp_…/51ba5d0c…|20971520
s/sp_…/db4a1f67…|16
trash/sp_…/a5595c80…|16
```

**Export (NDJSON): what kinds of lines**

```
$ GET /v2/export
{"record plan.extra":1,"history plan.extra":1,"blob podcast.listen":1,"blob notes.voiceNote":1}
```

**/v1/account**

```
$ GET /v1/account
{"id":"acc-smoke","google":[],"devices":2,"seeded":[],"flipped":false,"icloud":"keep"}
```

**Errors in the wrangler dev log**

```
none
```


## `wrangler dev --local` beta

wrangler 4.151.2, 2026-10-19T23:12Z, D1 `banana-service-beta`, R2 `banana-blobs-beta`

**Migrations 0001–0009 on a fresh local D1**

```
$ wrangler d1 migrations apply banana-service-beta --local --persist-to <tmp> --env beta
 0001_init.sql ✅ 
 0002_link_lifecycle.sql ✅ 
 0003_device_channels.sql ✅ 
 0004_push_record.sql ✅ 
 0005_event_alerts.sql ✅ 
 0006_alert_devices.sql ✅ 
 0007_plan_ahead.sql ✅ 
 0008_diagnostics.sql ✅ 
 0009_spaces.sql ✅ 
```

**Bindings wrangler dev reports**

```
env.SPACES (Space) Durable Object local
env.DB (banana-service-beta) D1 Database local
env.BLOBS (banana-blobs-beta) R2 Bucket local
```

**A build-61 device registration (the body before 0009) still works**

```
$ PUT /v1/devices/mac-smoke001 {platform, push, pushEnv, bundle}
204
```

**A sync**

```
$ POST /v2/sync plan.extra e1
{"head":1,"next":1,"more":false,"applied":[{"type":"plan.extra","id":"e1","clocks":{"title":"1792451579000.0000.phone","day":"1792451579000.0000.phone"},"deleted":null}],"rejected":[],"consents":{"health":false}}
```

**T2 refused without the Health consent; a clock an hour ahead refused**

```
$ POST /v2/sync food.meal m1; plan.extra e2 at now + 1 h
{"head":1,"rejected":[{"type":"food.meal","id":"m1","reason":"consent"},{"type":"plan.extra","id":"e2","reason":"clock"}],"consents":{"health":false}}
```

**Blob PUT: wrong sha, right sha, 20 MB, and the 20 MB back**

```
$ PUT /v2/blobs/<zeros> (notes.voiceNote)
400 0.014855s
$ PUT /v2/blobs/<sha> (notes.voiceNote)
204 0.010345s
$ PUT /v2/blobs/<sha of 20 MB> (podcast.listen)
204 0.290528s
$ GET /v2/blobs/<sha of 20 MB>
200 20971520 bytes 0.037301s
byte for byte the same
```

**Consent, a T2 photo, then the withdrawal: the alarm moves the photo to trash/**

```
$ PUT /v2/consents/health
204
$ PUT /v2/blobs/<photo> (food.mealPhoto)
204 0.008619s
$ POST /v2/sync food.mealPhoto p1 naming it
{"head":2,"rejected":[],"consents":{"health":true}}
$ DELETE /v2/consents/health
204
HEAD /v2/blobs/<photo>: 404 after 1 look(s)
R2 keys now (space id shortened):
s/sp_…/d6c943a4…|20971520
s/sp_…/db4a1f67…|16
trash/sp_…/a5595c80…|16
```

**Export (NDJSON): what kinds of lines**

```
$ GET /v2/export
{"record plan.extra":1,"history plan.extra":1,"blob podcast.listen":1,"blob notes.voiceNote":1}
```

**/v1/account**

```
$ GET /v1/account
{"id":"acc-smoke","google":[],"devices":2,"seeded":[],"flipped":false,"icloud":"keep"}
```

**Errors in the wrangler dev log**

```
none
```
