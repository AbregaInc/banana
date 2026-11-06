# Google transport on Workers

Node accepts `redirect: "error"`; Workers throws before sending such a request.
Run this check in workerd as well as the Node service tests after transport changes:

```sh
cd Service
npx --yes wrangler@4.158.0 dev --config tools/google-worker-check/wrangler.jsonc --local --port 8897
```

From another terminal, `curl --fail http://127.0.0.1:8897/` must return `passed: true`
and six passing cases. Stop Wrangler after the check.

The fixture imports the production Google adapter and constructs real Workers requests.
It uses synthetic responses and credentials, makes no outbound requests, and has no service
bindings. Calendar reads, Mail reads and draft sending must work without following redirects.
The Node regression also checks 301, 302, 303, 307 and 308 refusal and a single upstream call.
