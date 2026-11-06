# Feature access

Implementation status: production and staging run `20a230c3` with schema 0020.
Production has no eligibility grants. On 6 November, the existing owner account in staging
received Calendar Cloud and Email testing access until 13 November, after every registered
device reported protocol 1. The existing Beta account was reconnected on 6 November: staging
now has a Calendar server token with list/event scopes and status `ok`. Live Beta Calendar reads now succeed after the Workers transport fix. Gmail consent and
remaining cross-device acceptance remain outstanding; eligibility alone does not grant Google permissions.
Primary iOS/iPad and Mac TestFlight build 97 uses `11ec3140`; distribution evidence is recorded in
[the rollout plan](CLOUD-AND-RELEASE-PLAN.md). Live-provider and device acceptance remain open.
Deploy service/schema support before the clients. Guarded Calendar reads/writes and Mail
reads/label operations exist; complete provider migration and cloud Mail remain unfinished.

Eligibility belongs to the existing authenticated Banana account. The `feature_access` table
is environment-local and defaults to no grants. A connected Google identity is sufficient to
identify the Banana account; Gmail consent is not required to decide tester eligibility.
Never copy an account ID from one deployment into another expecting the same person.

`GET /v1/account` returns a versioned `featureAccess` policy and each linked Google's actual
server-side capabilities. Eligibility, the saved module choice, compiled support, provider
scopes and Beta write restrictions remain separate checks. Missing/unknown policy denies
experimental access. Provider capability is false without a usable server token even if the
identity is linked. Native Calendar tokens do not prove that the server has Calendar access.

The client caches policy for at most 15 minutes, bound to a hash of the service host and
Banana session. The expiry can be shorter for a timed grant. It refreshes account state while
running and on foreground entry. A failed refresh does not extend eligibility. Changing the
session invalidates cached access; a late account response from an earlier session is ignored.
Hiding Email preserves its saved module selection and local data. Live Gmail requests and
new consent are denied when eligibility expires; queued work remains for later recovery.
An already dispatched request can finish. Fixture visibility does not enable live transport.

Future cloud feature endpoints must call `featureAllowed` against current server state for
each operation. A client's cached policy is never a server authorization credential. Calendar
and Mail endpoints enforce those gates against current account policy. The registered-device
protocol guard rejects provider migration while a known older client remains; it does
not revoke Google credentials held by an old installation.

## Administration

Use the account ID from the selected deployment's authenticated account/administrative
inventory. Keep real account IDs and operational output outside the public repository.
The tool validates without changing anything unless `--apply` is supplied:

```sh
python3 Service/tools/feature-access.py --environment beta \
  --account '<existing-account-id>' --feature email --access grant \
  --expires '2026-12-01T00:00:00Z'
```

Run the same command with `--apply` to execute using the operator's existing Wrangler
credentials through the pinned Wrangler 4.158.0 CLI (`npx`). The tool requires an explicit receipt
confirming exactly one updated account. Missing accounts, incompatible registered devices and
ambiguous responses return a nonzero exit status. It never creates an account or removes an old
device to bypass the migration guard. Installing Dev beside legacy Beta does not upgrade Beta’s
registration: the existing app must run a compatible build. Revoke with `--access revoke --apply` and omit expiry.
Grants are not deployed as seeds, inferred from email addresses, or enabled for every Beta user.

## Build presets

| Scheme | Configuration | Purpose |
|---|---|---|
| Banana / BananaMac | Release | Stable; no Email or local AI |
| Banana / BananaMac | TestFlight | Primary identity and production service; gated Email, no local AI or Mail fixtures |
| BananaDev / BananaMacDev | DevelopmentCloud | Separate `.dev` identity, explicit Dev OAuth/service settings, no legacy iCloud |
| Existing local Beta/Pi presets | Existing local configuration | Fixtures and local experiments; not distribution archives |

Dev settings are blank by default. Populate the `*_DEV` keys in ignored `Config/Local.xcconfig`
only after provisioning an isolated development backend, Google clients and signing profiles.
These schemes do not provision those resources or silently fall back to Beta/production.
The Dev credential services, local root, Bonjour service and Reminders list are separate.
Google writes still use Beta's test-account safeguards. Signed Mac Dev is installed alongside the
primary app. Signed Dev `11692682` is installed on both phones, iPad and Mac, with coexistence
verified. Staging Calendar consent is stored; Gmail consent and live-provider acceptance remain open.

Stable and TestFlight share the existing app record, account and data. A TestFlight install
replaces Stable; groups choose builds, not feature eligibility. The Beta service is staging.
Production policy/schema support is deployed; explicit grants and provider validation remain.

Archive checks inspect the primary app identity: Email requires the `testflight` channel and
a bundle identifier equal to `BananaPrimaryBundleIdentifier`. A nested app cannot authorize
a Stable archive. Build `Release` for public submission; do not promote experimental archives. AI resources
and native markers remain forbidden. These checks do not constitute Apple/Google approval.
