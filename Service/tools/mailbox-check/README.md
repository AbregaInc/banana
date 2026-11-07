Local workerd acceptance of the shared cloud mailbox (docs/design/MAIL-CLOUD-SYNC.md) on a real
Durable Object with SQLite storage and alarms, local D1 with the production migrations and local
R2. Gmail is the in-memory fake from the service tests: no Google request, credential or real
message. From Service, with a throwaway state folder:

    npx --yes wrangler@4.158.0 d1 migrations apply mailbox-fixture --local --config tools/mailbox-check/wrangler.jsonc --persist-to <dir>
    npx --yes wrangler@4.158.0 dev --config tools/mailbox-check/wrangler.jsonc --local --persist-to <dir> --port 8898
    curl -s http://127.0.0.1:8898/

It answers 200 with `"passed": true` when the handshake, the scan to completion, the feed (40
messages), content stored once and opened, a history change reaching the feed, and the content fill (every message stored, newest
first, flagged in the feed), the bulk content pull, and the wipe of R2 and the D1 row all hold. Do not deploy it.
