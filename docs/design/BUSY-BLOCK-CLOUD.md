# Busy-block provider ownership

Cloud Calendar uses the existing durable provider-operation journal. Migration 0018 adds one
encrypted provider identity per Banana account, destination calendar, app variant and logical
item. Two device operation UUIDs for the same block share one service writer claim.

The identity is reserved before Google receives an insert. Reservation checks the current
operation lease inside the SQL write, so a late preparer cannot replace its successor's identity.
A complete ownership read adopts a legacy block without creating another. Incomplete ownership
reads stop the operation. Existing duplicate cleanup retains its native ownership/removal guards.

A lost insert reply is reconciled against its reserved ID and operation marker. An empty Google
read does not authorize another insertion. A confirmed deletion or Google tombstone permits a
new provider ID; old receipts cannot retire that new generation. Titles and provider IDs are not
stored in index columns. Account deletion removes the encrypted identity with the account.

Updates and removals use the provider version observed by the native ownership read. Service-owned
blocks reject missing versions and changed ownership markers. A newer version yields a conflict
instead of overwriting another device's change. Native ledger reuse must also compare the remote
version; a locally unchanged plan alone is not evidence that the remote block is unchanged.

The service owns provider identity and dispatch, while the existing native planner still computes
desired blocks. This does not establish authoritative server-side planning or prove that an old
installation has discarded its Google credential. Feature eligibility remains off during cutover
acceptance. Known legacy-device checks are not remote credential revocation.

Validation covers distinct/concurrent device operations, missing and lost acknowledgements,
expired preparers, legacy adoption, deletion/recreation, stale versions, ownership stripping and
account deletion. The full service suite passes 381 tests in each of UTC and America/New_York.
Live Google effects, native integration and performance acceptance must be recorded separately.

Google provides [private-property queries](https://developers.google.com/workspace/calendar/api/guides/extended-properties)
and [conditional modification](https://developers.google.com/workspace/calendar/api/guides/version-resources).
Its [insert API](https://developers.google.com/workspace/calendar/api/v3/reference/events/insert)
does not guarantee collision detection at creation time. The implementation therefore reuses
SQLite/D1 claims and the existing journal rather than relying on matching event IDs alone.
