# Mail credential regression

Run `python3 tools/mail-auth-tests/run.py --out NEW_DIRECTORY` on macOS.
The runner copies actual app sources and their XCTest cases into a standalone
optimized package, preserving hashes and logs. It uses Swift 5 language mode,
matching `project.yml`. It requires at least 52 tests, explicit race/durability
cases, zero failures and no skips. The performance-contract workflow runs it on
every PR/push and retains evidence on failure.

No real keychain item, OAuth consent window, token or Gmail request is used.
The injected URLSession uses URLProtocol responses. Storage is an actor-backed
fixture with deliberate write failures. Cases cover refresh form encoding,
expiry/scope parsing, error classification, single-flight renewal, generation
changes, consent mismatch, storage failure, reload and deletion races.
Google's presenter and actual keychain entitlements still require signed app
and physical-device checks; this suite cannot establish live account readiness.
