# Banana Cloud, feature access and release channels

Status: agreed direction; implementation work remains. Recorded 4 November 2026.

Banana Cloud will coordinate shared state and provider operations across iPhone, iPad, Mac
and the web. Finish and extend the existing account system, sync engine, Google integration
and release tooling. Preserve local caches, offline work and device-specific permissions.

This document records the overall plan and its acceptance criteria. Checkboxes describe
unfinished work, not functionality already shipped. Distribution/configuration findings below
are a dated audit snapshot and must be refreshed before a release.

## Decisions

- Google sign-in remains the Banana identity. Use the existing Banana account; introduce no
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

## Implementation checkpoint

The first local increment adds versioned account eligibility, actual server-grant capabilities,
short-lived native policy caching, Email presentation/transport gates, explicit TestFlight/Dev build
presets and account-scoped administration. See [feature access](FEATURE-ACCESS.md).
The service foundation and gated Calendar read endpoint are deployed to Beta at `d199ef76`, with migrations 0013–0014 applied
and the public source offer verified. Clients are not distributed. Native provider consolidation,
cloud Mail, isolated Dev infrastructure,
signed distribution and end-to-end acceptance remain unfinished. The audit table above is the
starting snapshot, not a claim about these new source changes.

The renewed Google CLI login confirms both configured projects are active. Calendar API is
enabled in both; Gmail API is enabled only in Beta. OAuth clients, redirects, audience and
verification status still need console inspection. No separate Beta App Store Connect record
is needed. TestFlight uses the existing main app record. Production service/schema support
and primary-account grants must be deployed before testing Email there; until then it is denied.

The component regression run was retained as a failure: RSS limits were exceeded in five
scenarios, and four scenarios had incomplete host monitoring (process enumeration timeouts;
one monitor also failed to stop promptly). No baseline or budget was changed. Native UI,
physical-device performance and signed coexistence acceptance remain outstanding. Passing
unit tests or an unsigned optimized compile does not clear these release gates.

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
- [ ] Record the exact deployed source revision and schema version for every service environment.
- [ ] Verify Google OAuth clients, redirects, publishing status and approved scopes; inspect Apple's
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
- [ ] Verify signed TestFlight exports and configure tester groups on the existing app record.
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
