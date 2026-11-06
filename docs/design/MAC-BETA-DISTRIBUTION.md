# Direct Mac Beta distribution

Banana Beta 1.0.4 (99) is published as the GitHub prerelease
`mac-beta-v1.0.4-99`, from source `ed50020821a5892b6e8b3a132da8152733ed85d3`.

- Download: https://bananatheapp.com/download/mac-beta
- Signed update feed: https://bananatheapp.com/updates/mac-beta/appcast.xml
- Requires Apple silicon and macOS 26 or later.
- Uses the existing Beta identity, local data directory and staging service.
- Includes feature-gated Email, excludes local AI, and coexists with stable Banana.
- Existing local Beta builds need this installer once; they have no updater.

The app and DMG passed notarization, ticket stapling, Gatekeeper assessment and
Ed25519 update signature validation. The hosted asset checksum and live feed,
metadata and versioned redirect were checked. Stable still points to 1.0.3 (98)
and remains GitHub's latest stable release. The Beta feed also returned the expected
bytes with a Sparkle-style user agent. The site's protection rejected Python's
default user agent; curl and the Sparkle-style request succeeded.

The new Inbox ordering and early verification are described in
[Mail backfill and history ordering](MAIL-BACKFILL-HISTORY-ORDER.md), including
retained test and performance failures. This is an experimental distribution;
physical UI acceptance, fresh-machine account/capability checks and an actual
upgrade to a later direct Beta version are still to be performed. This release
does not introduce a shared cloud mailbox cache or backfill checkpoint.

See [release instructions](../../tools/mac-distribution/RELEASING.md) for identity,
notarization, channel isolation, CloudKit environment and retention rules.
