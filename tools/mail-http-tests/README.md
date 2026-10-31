# Gmail transport checks

Run `python3 tools/mail-http-tests/run.py --out NEW_DIRECTORY` on macOS.
Compiles the actual Gmail wire types, HTTP adapter and tests in Release mode.
URLProtocol supplies controlled responses; no account, credentials or external
requests are used. Retains source snapshots, hashes, logs and a test-count gate.
The `mail-http` CI job runs these checks persistently.

Covers search and continuation escaping, malformed pages, response bounds,
network gating, structured provider failures, cancellation, metadata headers and
invalid paging. Does not establish live OAuth, redirect behavior, sync durability,
integrated search or physical UI performance. Those remain separate acceptance
work. Keep failed runs; do not substitute these checks for the full component
regression suite.
