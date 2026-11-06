# Shared Gmail read pacing

The staging console showed 1,200,000 units/minute per project with only 0.44% peak usage,
and an active per-user limit of 6,000 units/minute. The legacy 15,000-unit limit was labeled
"Previous quota". Device logs continued receiving provider limit refusals during catch-up.
A generic `rateLimitExceeded` reason alone does not establish that project-wide quota is exhausted.

The [current Gmail cost schedule](https://developers.google.com/workspace/gmail/api/reference/quota)
charges full message reads 60 units and full thread reads 120 units. Metadata, profile,
history and listing requests have different costs. `mail-read-pacing.js` accounts for each
supported read resource and format, including Gmail's default full format.

The existing [Workers limiter](https://developers.cloudflare.com/workers/runtime-apis/bindings/rate-limit/)
counts requests per location; it does not provide a globally shared weighted schedule.
A single atomic D1 UPSERT reserves each read's slot per Google identity across all client
devices and Worker instances. This uses the existing database adapter and SQL transaction
semantics rather than adding a separate limiter service. Reads are paced at 75 units/second
(4,500/minute plus at most one request at a window boundary), leaving headroom for mutations.
This is a read budget, not a guarantee about requests made outside this endpoint.

The server waits at most ten seconds for a reserved slot. It rechecks eligibility and the grant
before forwarding a delayed read. A full queue returns 429 with Retry-After; refused requests
do not extend the queue. There are no automatic retries of Google mutations. Cached client UI
is unaffected; network catch-up is intentionally paced. No quota or billing setting was raised.

Validation includes weighted/default-format costs, concurrent shared reservations, independent
identities, bounded queues, idle recovery, revoked permission while waiting, and retry headers.
`Service/tools/mail-pacing-check` verifies the actual migration and atomic RETURNING operation
under local workerd/D1, using synthetic identities and no Google calls.

The full service suite passes 413 tests in each of UTC and America/New_York. The real
workerd/D1 check passed with the pinned Wrangler 4.158.0 runtime. The initial full run caught
an outdated migration-list assertion; both expected lists were updated and the run retained.

Migration 0021 and the pacing code are deployed to Beta and production. Both source endpoints
identify the tested source commit. A retained Beta observation captured 179 Mail reads over
203 seconds, all HTTP 200, with no quota refusals. A later device snapshot shows continued
reconciliation progress. Full mailbox catch-up remains unconfirmed; this observation is not a
claim of sustained capacity or native UI performance. Native code was unchanged in this fix.
Private evidence lives under `private/cloud-rollout/mail-pacing-*`.
