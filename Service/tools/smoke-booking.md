## `wrangler dev --local`: booking

wrangler 4.151.2, 2026-10-20T05:27Z

**Migrations on a fresh local D1**

```
 0009_spaces.sql ✅ 
 0010_booking.sql ✅ 
```

**Bindings**

```
env.DB (banana-service) D1 Database local
env.RL_SLOTS (120 requests/60s) Rate Limit local
env.RL_BOOK (10 requests/60s) Rate Limit local
env.RL_CODE (5 requests/60s) Rate Limit local
```

**GET /smoke (one type: the times, the whole horizon in the HTML), five times**

```
200 ttfb 0.033595s total 0.033844s
200 ttfb 0.006766s total 0.006888s
200 ttfb 0.005985s total 0.006103s
200 ttfb 0.005790s total 0.005923s
200 ttfb 0.006069s total 0.006256s
Cache-Control: private, no-cache
content-security-policy: default-src 'none'; script-src 'nonce-1y/jsUpPSyHNahnWHQuUnA' https://challenges.cloudflare.com; style-src 'unsafe-inline'; font-src 's
server-timing: render;dur=2, engine;dur=1, cache;desc=fresh
HTML 42907 bytes, 14045 gzipped
```

**GET /smoke/meeting/slots**

```
352 slots, first 2026-10-20T13:00:00.000Z, busy null
200 ttfb 0.006267s total 0.006493s
```

**POST without our Origin**

```
403
```

**POST /smoke/meeting/book (the reservation's answer)**

```
{"booking":{"start":"2026-10-20T14:30:00.000Z","end":"2026-10-20T15:00:00.000Z","place":{"id":"meet","kind":"meet","label":"Google Meet"},"placeDetail":null,"manageUrl":"/m/hAqC99ao5Vfi1nDdb4iFLg.gjV-HyculrIn66HCiQHMCQ",
200 ttfb 0.029703s
the same post again:
200 ttfb 0.006775s
```

**A time that isn't offered: refused, with the nearest three**

```
{"taken":true,"nearest":[{"start":"2026-10-20T14:00:00.000Z","end":"2026-10-20T14:30:00.000Z"},{"start":"2026-10-20T14:30:00.000Z","end":"2026-10-20T15:00:00.000Z"},{"start":"2026-10-20T15:00:00.000Z"
```

**The follow-up: the host's link has no token, so Google is refused and the booking fails**

```
{"status":"failed","invite":"held","nearest":3}
```

**A second booking and its Undo (it has already failed here, as above, so Undo is too late: 409)**

```
409 ttfb 0.004756s
```

**The calendar file, a forged manage link, and the code (404 here: no email provider under wrangler dev)**

```
UID:…24c1849167ec125b01e24ac4@google.com
DTSTART:20261020T153000Z
STATUS:CONFIRMED
forged: 404
404 ttfb 0.003328s
```

**What the Worker logged (booking lines)**

```
   2 booking: try 1 failed (GoogleRefused )
   2 email: failed kept (no provider here)
   2 push(booking): 0 device(s): none
   1 turnstile: no TURNSTILE_SECRET, skipped
```

**Errors in the wrangler dev log**

```
none
```
