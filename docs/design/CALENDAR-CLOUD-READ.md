# Calendar cloud read contract

The web agenda and the gated native read endpoint share `Service/src/calendar-window.js`.
This increment introduces no provider writes and does not switch native sync ownership.
Calendar write-back remains on its existing path until a separate fenced migration is tested.

`GET /v1/calendar/window?from=<milliseconds>&to=<milliseconds>` accepts an authenticated
Banana session and requires the current `calendarCloud` eligibility grant. A client's cached
policy is not authorization. No account selector is accepted: the session selects the account.
The response is not cacheable by intermediaries.

The window must be positive, increasing, no longer than eight days, and start within one year
of service time. `filter=1` preserves the web agenda's expanded declined/all-day behavior.
The version-1 response adds `version`, `from` and `to` to the existing web agenda shape:
`events`, `weekStartWeekday` and `unavailable`. Events retain provider calendar/event identities
and the web projection's recurrence/occurrence details. This is an agenda view, not a raw
Google delta feed or a durable mailbox/event sync log.

Both clients use the same linked service grants, cloud calendar preferences, visibility rules,
agenda normalization and Google pagination. Missing/revoked grants produce explicit reconnect
entries; transient per-calendar failures produce retry entries while other accounts can render.
Shared calendar visibility does not imply blocking or authority to write into another calendar.

No native app calls this endpoint automatically yet. The next integration step must compare this
projection with native cache semantics, retain offline state, and account for partial failures.
It must not treat eligibility as permission to activate a second event/write-back writer.

Validation covers unauthenticated requests, default deny, expiration, linked-account failures,
account isolation, invalid windows, no-store responses, provider-write absence and parity with
the shared reader. Existing web calendar behavior remains covered by its integration tests.

## Native cache contract

`GET /v1/calendar/snapshot?from=<milliseconds>&to=<milliseconds>` uses the same authentication,
current `calendarCloud` grant and eight-day bounds. It shares the provider reader with the web
agenda, but returns `{version, from, to, sources, unavailable}`. Each source has the linked
account email, calendar metadata and provider events. It preserves etags, reminders, recurrence
identities and successful empty calendars. Hidden/deleted calendars are excluded; native
visibility/blocking preferences are applied by the existing native normalizer, not by the web
projection. No provider refresh, access or sync tokens are returned.

A failed calendar is absent from `sources` and appears in `unavailable` with its raw calendar ID.
An account-level failure has no calendar ID. Neither is evidence of deletion. A complete response
with zero sources is different from a failed read. Duplicate calendar IDs across linked accounts
still require the existing native ownership/deduplication policy before cache application.

`BananaAccount.calendarSnapshot` implements the authenticated native call on all three native
platforms. It validates request bounds, decodes off the main actor and rejects stale responses
after session/account changes or eligibility expiry. The decoder checks version/window and
retains the original provider models. This is a transport integration only: no automatic call,
cache replacement, read cutover or write ownership change is enabled yet. Durable cache
reconciliation and failure/offline acceptance are prerequisites for enabling native cloud reads.
