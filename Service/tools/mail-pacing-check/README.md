Run with `wrangler dev --config tools/mail-pacing-check/wrangler.jsonc --port 8896` from Service,
then GET the local endpoint. This uses isolated local D1 and the production migration, database
adapter and reservation function. Twelve concurrent full-thread reads must receive seven distinct
slots and five queue refusals. No provider credentials or real messages are used. Do not deploy it.
