# Banana Cloud, feature access and release channels

Status: agreed direction; implementation work remains. Recorded 4 November 2026.

Banana Cloud will coordinate shared state and provider operations across iPhone, iPad, Mac
and the web. Finish and extend the existing account system, sync engine, Google integration
and release tooling. Preserve local caches, offline work and device-specific permissions.

This document records the overall plan and its acceptance criteria. Checkboxes describe
unfinished work, not functionality already shipped. Distribution/configuration findings below
are a dated audit snapshot and must be refreshed before a release.

## Decisions

- The original plan uses Google sign-in as the Banana identity. Apple’s 5 November 4.8 rejection
  now requires an equivalent qualifying login or an accepted explanation of an applicable exception.
  This remains an unresolved release requirement. Use the existing Banana account; introduce no
  separate signup or invite-based identity merely to enable testing access.
- Banana Cloud is the shared sync authority. Google remains the upstream record for its calendar
  and mail data. Devices keep durable caches and pending actions, with explicit reconciliation.
- Provider grants and provider operations move under service ownership. Consolidating native
  credential stores alone does not meet this goal.
- One connected-account experience does not mean requesting every scope up front. Request
  Calendar and Email together if both are selected; request Gmail later if Email is enabled later.
  Additional or revoked permissions can still require consent.
- Tester eligibility, enabled modules and provider permissions are separate decisions.
- Stable and TestFlight use the same app identity, Banana account and production service.
  TestFlight replaces Stable on a device. Groups select builds; account grants select features.
  Dev is a separate, isolated local install. Existing local Beta remains a developer tool.
- Calendar consolidation ships incrementally. Email does not hold up Calendar fixes or Stable releases.

## Verified starting point

The audit inspected source, seven effective Xcode configurations, live Apple and Cloudflare
records, device app inventories where reachable, the public Mac installer and relevant tests.
Private operational evidence stays outside the public tree. Source baseline: `22ab218f`.

| Area | Current behavior / gap |
|---|---|
| Identity | Connected Google identities map to an existing Banana account through the service. No separate signup. Stable and Beta have separate account databases. |
| App-data sync | The catalog, GRDB mirror/outbox, space databases and blob storage already exist. Both deployed environments have device-reported migration completions across all three native device families. These reports alone do not prove convergence. |
| Native Calendar | Native apps read and write Google directly, including event creation and busy blocks. |
| Web Calendar | The browser calls `/app/api/calendar`; the service uses its own Google grant to fetch events. The browser combines them with plan records from Banana Cloud. |
| Notifications | Google webhooks trigger service reads and APNs alerts. Devices retain local alerts and report held IDs to avoid duplicate pushes. Booking also already uses server Google access. |
| Mail | Local engine/database with a separate, device-local Gmail credential. The cloud mailbox path remains to be implemented. |
| Feature access | Compile switches and cloud-synced module preferences exist. Generic per-user tester eligibility does not. |
| Build gates | Normal Stable and Beta Release builds exclude Email/AI. Local Beta install scripts opt in. Archive gates reject those experimental modules even if enabled by a build switch. |
| Dev | Pi has distinct development settings but explicitly disables Banana Cloud. Complete signed-build isolation and a cloud-connected Dev path are not established. |
| Cloud deployment | Both environments are live and have distinct database/blob/space bindings. Beta lacks migration `0013_booking_hardening.sql` and has no stored server Google refresh token. Neither inspected deployment advertises its source revision. |
| Distribution | Main-identity TestFlight has build 85 for iOS and Mac. Separate Beta bundle registration exists, but no separate Beta App Store Connect app was found. Mac direct build 88 is public; its downloaded checksum, notarization and Gatekeeper checks passed. Mac Beta has no updater feed. |
| Installed versions | Reachable devices and this Mac have differing versions. Not every device's installed build could be inspected. |
| Apple readiness | iOS App Store version is waiting for review; Mac version is rejected. Returned App Store profiles are invalid; direct-Mac profile is active. Reasons and fresh signing readiness require follow-up. |
| OAuth configuration | Local client settings and credential paths were inspected. Actual Google consent-screen status, approved scopes, client registrations and redirects still require console verification. Do not infer those from source settings. |

Calendar therefore has **parallel native and server paths**, not a missing backend integration.
Reuse the web, notification and booking implementations when establishing a common provider layer.

## Current checkpoint — 6 November

- Production and staging run `83e7e0f6`, schema 0020. Source provenance, unauthenticated
  operation refusal and web entry-point smoke checks pass. Production has no enabled feature
  grants. The production recovery bookmark and previous deployment IDs are retained privately.
- Calendar maintenance now continues if temporary Mail upload cleanup fails. The failed upload
  stays available for a later cleanup retry. The service suite passes 405 tests in each of UTC
  and America/New_York with serial test execution and no competing builds. The earlier parallel
  run's booking-horizon timing failure remains retained; its limit was not changed.
- Dev `11692682` is installed on both phones, iPad and Mac. Legacy Beta `83e7e0f6` is installed
  in place on all three mobile devices and Mac. After the phone became available, staging
  confirmed protocol-1 registrations for all three registered device families. Installing
  Dev beside Beta does not migrate Beta's registration. No device row is removed to bypass this gate.
- Staging still has no Calendar or Mail provider grant. Fresh interactive consent and live
  cross-device acceptance remain outstanding. Installation and automated fixture tests do not
  establish that acceptance.
- The existing owner account in staging has Calendar Cloud and Email testing eligibility until
  13 November. The account was identified from the upgraded Mac's actual device registration;
  no account was created and production eligibility remains off. The administration tool uses
  D1 query mode so its update receipt is returned; remote file-import mode did not return it.
  Five administration tests pass, and both live staging grants returned confirmed receipts.
- The full phone UI suite is in progress. TestFlight 95 remains the latest valid uploaded build
  for iOS and Mac. The native draft/attachment increment is not yet in that build. Stable Mac 96
  remains a draft release. The seven relative-RSS component failures and missing physical-device
  performance evidence remain open; no baseline or budget has changed.
- `52c4030b` corrects direct-Mac push routing: a Developer ID app can have an embedded profile
  and a production APNs entitlement. Registration now uses that signed entitlement instead of
  inferring the push environment from the telemetry channel. Three focused tests pass. A new
  signed artifact and live notification delivery still require verification.

The dated checkpoints below preserve earlier stages. This checkpoint supersedes their deployment
and installation inventories; unchecked acceptance items still require their stated evidence.

## Implementation checkpoint — 5 November

- Production runs `879e2709` through schema 0017. Staging now runs `b40a95ac` through schema
  0019, with busy-block identity fencing and gated Gmail-owned draft operations. Exact public source
  offers were verified, health/source return 200, and unsigned Calendar/Mail operation and Mail
  read requests return 401. Production still has zero eligibility grants; the new provider
  routes are not activated for users. The terminal-receipt correction is deployed to both environments; its native reconnect change passes the focused 42-test suite.
- Account eligibility, actual stored-grant capabilities, expiring native policy caches and
  Email presentation/transport gates are implemented. See [feature access](FEATURE-ACCESS.md).
  Stored scopes/status are not a fresh live-token validation.
- Primary iOS/iPad and Mac TestFlight build 95 was archived, exported and uploaded from
  `55d675e6`. Archive identities, channel, production host, versions, signatures and source
  provenance passed verification. Apple accepted both platform builds as VALID / IN_BETA_TESTING
  for internal testers. Existing internal access includes all builds. Both platform builds are
  also IN_BETA_TESTING externally and verified members of the existing public beta group.
  No separate Beta app is needed.
- Stable Mac 1.0.3 (96), source `a6cbf7c8`, is archived, exported, notarized and packaged.
  Its Stable exclusions, primary identity, source, Sparkle signature, checksum and Tailscale
  download pass verification. Symbols are retained. The GitHub release remains a draft; the
  public installer/update feed still points to the accepted release. Live upgrade acceptance
  and the existing performance failures remain open.
- `tools/testflight.sh ios|mac BUILD_NUMBER [prepare|upload]` prepares by default and records
  provenance. Stable Release excludes experimental modules. TestFlight shares production identity.
- Native incremental Calendar reads are implemented in `894364f8`, behind `calendarCloud`.
  The transport preserves the existing cache/window behavior and uses encrypted account/grant
  bound cursors. It passed 337 service tests per timezone, 79 focused native tests and the full
  Mac TestFlight compile. The service read support is deployed to both environments; native support is included in build 95.
  See [the read contract](CALENDAR-CLOUD-READ.md). Released clients still use their existing write path.
- Google console verification completed on 5 November. Production is External/In production;
  branding and Calendar data access are verified. Its web origin and callback match production,
  and both native/web client IDs match local configuration. No Gmail scope is configured there.
  Staging is External/Testing with four test users, separate web/iOS/Mac clients, a staging
  callback and `gmail.modify`. The authorized native Dev client has been created and added to staging without replacing existing audiences. Private local Dev configuration uses it and the staging web client. Fresh device sign-in remains unverified. Calendar API is enabled in both;
  Gmail API is enabled only in staging. No consent or scope settings were changed.
- Apple's Mac rejection is for the incoming-network entitlement on build 83. The existing owner
  reply explains same-network podcast transfer. Source contains the matching Multipeer advertiser;
  the same explanation is already in App Review notes. iOS build 83 was rejected on 5 November
  for login services (4.8), background audio/location evidence (2.5.4), WeatherKit attribution
  evidence (5.2.5), and HealthKit disclosure (2.5.1). Apple specifically requests recordings on
  physical devices. Resubmission and approval remain outstanding; TestFlight is a separate gate.
- The owner selected an appeal before adding another login provider. The [appeal draft](../release/login-appeal-draft-20261105.md) is prepared but not submitted; no Sign in with Apple change was made.
- The persistent component run remains failed: RSS exceeded budgets and some scenarios lacked
  complete host monitoring. Evidence is retained privately; no baseline or budget was changed.
  Full UI, live-provider, physical-device performance and signed upgrade/coexistence acceptance
  remain open. Unit tests, signed exports and health checks do not close those gates.
- New ordinary event drafts now persist a client operation identity before their first write,
  using the same lost-acknowledgement reconciliation as Meet/Pi events. Legacy drafts are not
  assigned a new identity after an unknown provider outcome. All 13 focused draft/Meet/read
  tests passed; evidence: `private/cloud-rollout/pending-event-identity.xcresult`.
- Signed cloud Dev builds now verify on iOS and Mac with explicit Dev profiles, staging host and
  isolated identity. Mac Dev is installed alongside the primary app. The phone disconnected before
  install; iPad hardware is unavailable. Fresh OAuth consent remains unverified. The install tools
  now use the configured Apple signing key; 78 tooling tests pass.
- Cloud-owned durable Calendar writes and busy-block identity fencing are implemented behind
  eligibility. Staging owns each logical busy-block provider identity; native `cb122791` preserves
  observed event versions through write-back and invalidates stale ledger skips. Service tests pass
  381 cases in each timezone, focused native tests pass 16 cases, and the full Mac target compiles.
  See [busy-block ownership](BUSY-BLOCK-CLOUD.md). Live cross-device acceptance remains unfinished.
- The new encrypted [Mail draft and send handoff](MAIL-CLOUD-DRAFTS.md) increment passes 399
  service tests in each timezone, local Worker MIME execution and a full Worker bundle check.
  Staging health, exact deployed source and unsigned draft refusal are verified. Fresh staging
  inventory still has no Calendar/Mail provider grants and no feature eligibility. The increment is not yet
  connected to the native composer. Attachments and visible conflict/unknown-send resolution remain
  unfinished; this is not a complete Email rollout.
- A fresh persistent component run completed all host monitoring and reported no latency failures.
  Six scenarios still exceed relative RSS budgets (363–502 MiB versus their retained references).
  Evidence: `private/cloud-rollout/busy-components/gate.json`. Budgets and baselines are unchanged. The audit table above is the starting snapshot,
  not a description of the current increment.

## Provider implementation follow-up — 5 November

The working increment adds service-owned Calendar mutations with encrypted intent/receipt storage,
conditional writes, and lost-acknowledgement reconciliation. Native clients persist an operation
identity before dispatch and retain cloud ownership after revocation. Native Calendar credentials
are retired only after a successful service read. Watch-list updates use the existing service
watch reconciler. A registered-device protocol guard prevents eligibility while known older clients
remain; it does not remotely revoke credentials held by old installations.

Mail reads and the currently implemented label/trash actions now have a cloud transport. Incremental
Mail consent has its own encrypted grant, actual scopes and OAuth-client provenance, preserving
Calendar access if Mail consent fails. Unknown Mail mutations remain unresolved rather than being
blindly replayed. Draft creation/sending and a user-visible resolution flow are still outstanding.

Validation: 364 service tests pass in each of UTC and America/New_York. New cases cover conditional
Calendar retry, preservation of external edits, and recovery of a uniquely identified moved event.
Earlier focused native runs passed 56 and 31 tests; the receipt/module follow-up passes 42 tests. The full iPhone UI run recorded 246 passes, 19 failures and 31 skips. Its original runner interrupted result finalization; the raw log remains. The runner is fixed and focused reruns preserve result bundles. All 19 original failures now have passing focused reruns; these are not a new full-suite run. The three affected iPad checks pass (meal keyboard, image paste and top-bar picker). The service
increment is deployed to staging with exact public source provenance; native changes from `ae40b8f2` and follow-up fixes are included in uploaded TestFlight build 95. Busy-block ownership across devices and live-provider
acceptance remain open, so these transport changes do not establish completed Calendar cutover.

## Draft ownership correction

Gmail stores editable drafts. Banana Cloud coordinates their reads and durable create/update/delete/
send operations across devices, preserving pending local edits and reconciling unknown outcomes.
The schema-0019 Banana-owned editable store and timed send queue were an overextension; the corrected
implementation no longer uses them or runs their cron dispatcher. Successful draft content is
removed from the operation journal, leaving compact receipts. See [the corrected contract](MAIL-CLOUD-DRAFTS.md).
Native durable draft operations, Gmail draft imports, conflict choices and unknown-send retries
are committed. The gated live composer supports durable attachment upload, forwarding and explicit
text conversion of imported rich drafts while preserving their attachments. Scheduled send and
cross-account From switching are unavailable in live Mail. Fresh provider and cross-device
acceptance remain unfinished; see the Mail contract for retained failures and evidence.

## Native and distribution follow-up — 5 November

- Signed Dev commit `11692682` is installed over the existing Dev app on the spare physical
  iPhone and the primary phone. The primary app still coexists on both. Mac Dev is also installed
  with its signature and source stamp verified. This is
  installation evidence, not fresh OAuth or cross-device convergence evidence. The iPad remains unreachable. Identifiers stay in `private/cloud-rollout/`.
- Install tooling checks CoreDevice's structured physical/simulated field, including for explicit
  destinations. Local iOS/Mac installs stamp their source commit and mark dirty trees.
  All 81 tooling checks pass.
- Native draft/live-source checks pass 35 tests, HTTP transport passes 19, composer/cloud request
  checks pass 70, and the final Mac compile passes. The current component run retains seven RSS
  failures and no latency failures (`native-attachment-components/gate.json`). No baseline or budget changed.
- Service commit `0d53d787` is deployed to staging with schema 0020 after 404 tests passed in each
  timezone. The source endpoint matches and unauthenticated uploads are refused. A fresh staging
  inventory still shows zero Calendar grants, Mail grants and enabled feature rows.
- App Store Connect still reports iOS/Mac TestFlight 95 as valid and unexpired. This does not mean
  the new native draft commit is in TestFlight. Stable 96 remains a draft release.

## Target channel matrix

| App | Intended use | Service/data environment | Distribution |
|---|---|---|---|
| Banana | Dependable daily use | Production | App Store on iPhone/iPad; signed/notarized direct Mac release with stable updates; Mac App Store route tracked separately |
| Banana (TestFlight) | Upcoming releases and selected experiments | Production, same account and data | Existing app record on iPhone/iPad/Mac; tester groups select builds |
| Banana Dev | Development, fixtures and integration tests | Explicit fixtures or development cloud | Local development installs with distinct identities |

Stable and TestFlight share credentials, local roots, caches and push topics. Dev isolates these
namespaces. The existing Beta service is staging, not the TestFlight backend. Also constrain external writes: separate app
storage does not isolate two apps connected to the same real Google calendar or mailbox.

## Workstreams and acceptance criteria

### 1. Establish a dependable baseline

- [x] Reconcile the failing native configuration/module/migration assertions against intended behavior.
- [x] Review and apply Beta's missing schema migration before the compatible service update.
- [ ] Establish Beta's server Google grant and verify the required scopes and token refresh.
- [x] Record the exact deployed source revision and schema version for production and staging.
- [x] Verify Google OAuth clients, redirects, publishing status and approved scopes; inspect Apple's
  rejection details and signing/profile readiness before planning distribution changes.

Done when the environment inventory is reproducible, relevant correctness checks pass, and every
remaining unknown has a named verification step. Do not weaken tests or infer readiness from health endpoints.

### 2. Make development and testing representative

- [ ] Consolidate the existing schemes/install scripts into explicit, documented presets.
- [ ] Provide both fixture-based Dev and cloud-connected Dev with an explicitly selected isolated backend.
- [ ] Audit signed-build credential/storage isolation, including Pi's Mail namespace and keychain groups.
- [ ] Expose effective environment, channel, version, commit, feature decisions and account capability
  status in developer diagnostics. Never expose tokens or secrets.
- [ ] Preserve Beta/Dev safeguards for Google writes, Reminders and Health ingestion/output.

Done when the developer can exercise the real cloud workflow without replacing Stable or touching
its data/credentials. Fixture results and live integration results must be distinguishable.

### 3. Consolidate Google authorization

- [ ] Define the service-owned account/grant model using the existing Banana identity and linked Google identities.
- [ ] Record grant provenance, actual scopes and reconnect state; validate tokens with the correct client.
- [ ] Design migration from native Calendar, device-local Mail and existing service credentials.
  Account identity alone is not proof that the service has a usable provider grant.
- [ ] Use incremental consent; preserve working Calendar access when Mail access is declined or fails.
- [ ] Test multiple linked accounts, scope upgrades, revocation, expiry, account mismatch and reconnects.
- [ ] Keep provider credentials in the service's encrypted credential store, not ordinary synced records.
  Devices retain appropriate Banana sessions and platform permission state.

Done when a connected account has consistent capabilities across clients, with additional consent
only where required. Do not promise a migration can reuse every old token or eliminate all future consent.

### 4. Consolidate Calendar through Banana Cloud

- [ ] Reuse the existing server Calendar reads, web semantics, alerts and booking integration.
- [ ] Establish a common service-owned Calendar read/sync contract for native and web clients.
- [ ] Route native edits, replies, recurrence operations and Google Meet creation through durable service operations.
- [ ] Move busy-block/write-back ownership with explicit cutover and duplicate prevention.
- [ ] Unify visibility, blocking, ownership and calendar-selection semantics. Other people's calendars
  remain visible but nonblocking by default; existing explicit user choices must be preserved.
- [ ] Preserve local caching, optimistic feedback, durable pending actions and recoverable failures.
- [ ] Verify notification scheduling, rescheduling, cancellation, cross-device clearing and local fallback.

Done when native apps, web and notifications agree on events/settings and converge after offline edits.
Lost acknowledgements and retries must not duplicate events, Meet requests or busy blocks.

### 5. Add controlled feature access

- [x] Extend the existing authenticated account response with feature eligibility and explicit policy versioning (local implementation).
- [ ] Define per-environment tester access; do not assume Stable and Beta account IDs are interchangeable.
- [ ] Evaluate build support, tester eligibility, user module choice, account scopes and operation policy separately.
- [ ] Apply gates to background jobs and service endpoints as well as visible controls.
- [ ] Define cached/offline eligibility, expiry and revocation behavior. Missing policy must not grant new
  experimental access; disabling a feature must preserve user data and resolve pending actions explicitly.
- [x] Revise archive/resource gates for primary-identity TestFlight Email, preserving Stable exclusions.

Done when selected testers can enable Email across their devices without enabling it globally or
requesting Gmail permissions before they choose Email. No new signup flow is required.

### 6. Bring Email into the cloud architecture

- [ ] Extend the established Mail design with service-owned Gmail sync, mailbox state and durable operations.
- [ ] Retain device caches and search behavior while synchronizing shared mailbox state consistently.
- [ ] Specify metadata/body/attachment storage, retention, access controls and deletion using existing
  Mail/data-platform designs; do not assume generic app-record sync already implements a mailbox.
- [ ] Resolve the applicable Google approval and data-handling requirements before broader distribution.
- [ ] Test read/unread, labels, drafts, sending, ambiguous send acknowledgements, reconnects and offline replay.

Done when enabling an account's Email access once supports all clients through the service, and
mailbox actions reconcile without lost changes or automatic duplicate sends. Roll out behind tester eligibility.

### 7. Establish repeatable distribution

- [x] Use an optimized TestFlight configuration on the existing primary iOS/Mac schemes.
- [x] Remove the separate Beta distribution targets, installer and update feed tooling.
- [x] Verify signed TestFlight exports and the existing tester groups on the primary app record.
- [ ] Extend existing release tooling to cover the channel/platform matrix and artifact verification.
- [ ] Record version, monotonic build number, source commit, environment and capabilities for each artifact.
- [ ] Verify install-over upgrades, coexistence, data/permission retention and compatible cloud schemas.
- [ ] Address the Mac App Store rejection separately from the already working direct-download route.

Done when Stable/TestFlight upgrades preserve data across iPhone, iPad and Mac and isolated Dev coexists,
with traceable artifacts and retained symbols. Reuse the existing Mac release planner, immutable
assets, signatures, staged promotion and retention rules; do not replace them with commit counts.

## Execution order and promotion

The workstream numbers group work; they are not a requirement to finish Email before distribution.

1. Baseline verification and representative Dev/Beta environments.
2. Existing-app TestFlight distribution, alongside auth/provider design. Keep staging tests in Dev.
3. Calendar migration in Beta, with service and client compatibility established before cutover.
4. Real-device acceptance and promotion of Calendar changes to Stable.
5. Email cloud work behind tester access, promoted independently when ready.

Ship validated fixes between milestones. A release uses the intended source commit plus recorded
channel configuration; signing and channel identities mean the binaries need not be byte-identical.
Experimental TestFlight artifacts are not public release candidates: build Release and run its
exclusion checks before App Store submission or a public DMG. Deploy compatible service/schema
support before clients that require it. Older clients must remain
supported or receive an explicit upgrade requirement; they must not silently become competing writers.

## Migration invariants

- Assign one writer for each provider operation. Fence device/service ownership during cutover.
- Give durable operations stable identities. After a lost response, reconcile before retrying a write.
- Preserve queued work across crashes, reconnects, account changes and upgrades. Never erase a failed draft.
- Prevent another account's data from seeding into a newly connected account's space.
- Maintain health/data-sharing consent and device-only platform permissions.
- Define rollback per migration. Stop unsafe writes while retaining queues; do not blindly re-enable
  the old writer after the service may already have completed an operation.
- A local fallback alert and a server alert need shared identity and deduplication. Silent pushes alone
  are not a guaranteed background delivery mechanism.
- Follow the existing performance contract: asynchronous network work must not block input or UI rendering.

## Acceptance evidence

Audit baseline: 315 service tests pass in each of two time zones; 53 Mail credential tests and
20 distribution tests pass. The native audit ran 151 tests with six assertion failures across
three methods (module visibility, literal build-configuration expectations and migration drain mode).
These baseline failures were resolved against current inherited configuration, compiled module
availability and the existing consent-preserving read-only migration mode. The focused native
rerun passed 166 tests. The expanded service suite passes 320 tests in each time zone; archive
and distribution checks pass 24 tests, plus resource-gate and account-administration checks.
These checks do not establish signed-build or provider-migration acceptance.

For each promoted increment, retain:

- [ ] Relevant account, capability, isolation, sync and migration correctness results.
- [ ] Signed-build checks on iPhone, iPad and Mac; web parity where applicable.
- [ ] Fresh-install and install-over retention/coexistence evidence.
- [ ] Offline replay, concurrent edits, lost responses, reconnects and old-client compatibility evidence.
- [ ] Calendar/Email provider effects checked against expected operation counts and identities.
- [ ] Notification timing, duplication and cancellation checks, including an inactive native app.
- [ ] Required component and real-device performance evidence, with failures and missing evidence explicit.
- [ ] Artifact provenance, signing, applicable review/notarization, update-feed and post-deployment checks.

Unit tests, migration reports and a successful download each prove a different part of readiness.
None alone establishes end-to-end reliability across devices.

## Related implementation and design

- [Accounts and existing identity](ACCOUNTS.md)
- [Data platform and migration](DATA-PLATFORM.md), [data inventory](DATA-INVENTORY.md)
- [Event alerts](EVENT-ALERTS.md), [booking](BOOKING.md)
- [Mail engine](MAIL-ENGINE.md), [Mail plan](MAIL-PLAN.md)
- [Local feature switches and current archive gates](LOCAL-FEATURES.md)
- [Developer cycle](../DEV-CYCLE.md)
- [Mac release process](../../tools/mac-distribution/RELEASING.md)
- [UI performance contract](../performance/ui-performance-contract.md),
  [regression testing](../performance/regression-testing.md)

Earlier documents describe their own implementation stages. This plan expands the earlier deferred
cloud-Mail scope and records the intended provider consolidation; it does not claim those stages
are finished or silently change today's build gates.
