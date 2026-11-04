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
