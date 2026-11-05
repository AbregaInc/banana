# Feature access

Implementation status: production and staging run `699153d7` with schema through 0014
(5 November 2026). Production has zero eligibility grants. Primary iOS/iPad and Mac build 94
exports are verified but not uploaded; live-provider and device acceptance remain open.
Deploy service/schema support before the clients. This does not implement cloud Mail or
Calendar provider migration; those remain in [the rollout plan](CLOUD-AND-RELEASE-PLAN.md).

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
each operation. A client's cached policy is never a server authorization credential. There
are no cloud Mail endpoints in this increment.

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
credentials. Check `accounts_updated` is 1. Zero means the ID does not exist in that environment;
the command never creates an account. Revoke with `--access revoke --apply` and omit expiry.
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
Google writes still use Beta's test-account safeguards. Signed coexistence remains a required
acceptance check before distributing Dev builds.

Stable and TestFlight share the existing app record, account and data. A TestFlight install
replaces Stable; groups choose builds, not feature eligibility. The Beta service is staging.
Production policy/schema support is deployed; explicit grants and provider validation remain.

Archive checks inspect the primary app identity: Email requires the `testflight` channel and
a bundle identifier equal to `BananaPrimaryBundleIdentifier`. A nested app cannot authorize
a Stable archive. Build `Release` for public submission; do not promote experimental archives. AI resources
and native markers remain forbidden. These checks do not constitute Apple/Google approval.
