# Booking: what the routes hand the pages

Two builders work on booking at once:
- **Routes** owns `Service/src/booking/*.js`, except `pages/`.
- **Pages** owns `Service/src/booking/pages/` and `Service/public/book/`.

They meet here. Both read docs/design/BOOKING.md §12 first; it overrides earlier sections. Each
render function returns `{ status, headers, html }` and takes a plain view object.

## Shared types

```js
// A slot: UTC instants as ISO strings with Z.
{ start: "2026-10-21T19:00:00.000Z", end: "2026-10-21T19:30:00.000Z" }

// A place a type offers. `kind`: meet | zoom | phone_host_calls | phone_guest_calls | in_person | link
{ id: "meet", kind: "meet", label: "Google Meet" }
{ id: "zoom", kind: "zoom", label: "Zoom" }                      // url given only after booking
{ id: "phone", kind: "phone_host_calls", label: "Phone call" }   // the form asks for their number
{ id: "addr", kind: "in_person", label: "In person", address: "1 Main St, Brooklyn" }

// A booking type, as the page needs it.
{ slug, title, minutes, places: [Place], hostZone: "America/New_York", nextSlot: Slot|null }

// The host, as shown.
{ handle, name: "Noor Haddad", photoUrl: string|null }

// The guest, when the browser is recognised.
{ state: "none" | "remembered" | "verified", name, email, phone, zone,
  upcoming: [{ manageUrl, hostName, title, start, end }] }   // upcoming only when verified

// A booking (the answer to a booking, a move and the follow-up; confirmed.view.booking).
{ start, end, place: Place|null, placeDetail: string|null,     // Meet/Zoom link, phone or address; the
                                                              // links and the host's number once confirmed
  manageUrl: "/m/<id>.<sig>", icsUrl: "/b/<id>.ics?sig=<sig>",
  statusUrl: "/m/<id>.<sig>/state",                           // the follow-up: invite and Meet link
  guestEmail, undoUntil: ISO string|null,                     // every booking has 5 s of Undo
  undoMs: number,                                             // what's left of it, by the service's clock (0 when closed):
                                                              // the page counts down from this, not from undoUntil
  undoes: "booking" | "move" | null,                          // what POST /b/undo would undo now (a move's answer: "move")
  status: "pending" | "confirmed" | "cancelled" | "taken" | "failed",
  invite: "held" | "sending" | "sent" | "failed",             // held: Undo is open, nobody invited yet; failed: Google
                                                              // wouldn't add the guest (our own email still went)
  meet: "pending" | "ready" | "disabled" | null,              // for a Meet place
  nearest?: [Slot] }                                          // only with status taken or failed
```

Every page view also carries `zone` (the zone the server renders in: a verified guest's, else
`request.cf.timezone`, else the type's) and `locale` (the first Accept-Language tag). The page
re-labels when the browser's own zone differs. `times`, `profile` and `manage` also carry `canEmail`:
false when no email provider is set up, and then nothing on the page offers a code or says "we
emailed you" (the code routes answer 404).

## Pages (render functions in `pages/`)

| Function | View | Used by |
|---|---|---|
| `profile(view)` | `{host, types: [Type], guest}` | `GET /<handle>` when it has several active types |
| `times(view)` | `{host, type, slots: [Slot] (the whole horizon), guest, turnstileSiteKey, connect: {url}\|null, busy: [Slot]\|null (a connected guest's busy, already merged), csrf}` | `GET /<handle>/<slug>`, and `GET /<handle>` when it has one type |
| `confirmed(view)` | `{host, type, booking: {start, end, place, placeDetail (Meet URL, phone number or address), manageUrl, icsUrl, guestEmail, undoUntil\|null, undoMs}, guest, csrf, canEmail}` (`csrf` for its Undo) | after a booking |
| `manage(view)` | `{host, type, booking, slots, guest, csrf}`: change (pick a time, "Keep this time" marked) and cancel | `GET /m/<id>.<sig>` |
| `cancelled(view)` | `{host, type, booking}` | after a cancel |
| `notTaking(view)` | `{host}` | type off, host link refused |
| `notFound()` | | any bad handle, slug or manage link |
| `code(view)` | `{email, csrf, returnTo}`: the 6-digit code entry | `GET /b/code?email=&return=`, and `GET /b/forget` for a guest not yet verified |
| `forget(view)` | `{guest, upcomingCount, csrf}` | `GET /b/forget` (verified guests) |

The script in the page posts JSON to the routes below and renders their answers without reloading.
On a phone the sheet slides up. A recognised guest's tap books at once. The answers:

| Route | Body | Answer |
|---|---|---|
| `POST /<handle>/<slug>/book` | `{key (idempotency), start, place, name, email, phone?, note?, zone, turnstile}` | `200 {booking}` with status `pending` (reserved; the event is made after the answer), or `409 {taken: true, nearest: [Slot, Slot, Slot]}`, or `409 {already: true, emailed}` (this email has a time of this type: it is emailed, never shown; `emailed` is false without an email provider), or `409 {error: "not_taking"}`, or `429`, or `400 {field, error}` (`field` may be `turnstile`) |
| `GET /m/<id>.<sig>/state` | | `200 {booking}`: the follow-up after a booking (invite sent, the Meet link; `taken` or `failed` with `nearest`) |
| `POST /b/undo` | `{manage: "<id>.<sig>"}` | Undoes whatever `undoes` names. `204`: undone (a booking is off; a move is back at its old time, and Google and the host never heard of it). `409 {error: "taken", kept: true, booking}`: a move's old time went meanwhile, so the new time stands (say so). `409 {error: "too_late"}` once the window has passed |
| `POST /m/<id>.<sig>/move` | `{start, zone}` | `200 {booking}` with `undoMs` 5000 and `undoes: "move"`: the move stands at once; Google and the host hear of it when the window ends (retried if Google is down). Or `409 {taken, nearest}`, or `503 {error: "try_again"}` (Google couldn't be asked to check the day; nothing changed) |
| `POST /m/<id>.<sig>/cancel` | `{reason?}` | `204` |
| `GET /b/connect?return=<path>` | | redirect to Google |
| `GET /b/connect/callback` | | redirect back to `return`; the guest is verified and their busy is in the page from then on. When Google kept the refresh token back, the redirect carries `?fb=<sealed>` once: the page passes it on to `/slots?fb=` |
| `POST /b/code` | `{email}` | `204` (always, whether the email is known or not); `404` without an email provider |
| `POST /b/code/verify` | `{email, code}` | `204` and a verified cookie, or `400` |
| `POST /b/forget` | | `204` |
| `POST /b/not-me` | | `204`: this browser forgets who it was (its cookie and session go; the guest's account and times stay). For "not you?" |
| `GET /<handle>/<slug>/slots` | | `{slots, busy}` (and `taking: false` when the host can't take bookings), for a page left open (revalidated when a time is tapped) |
| `GET /b/<id>.ics?sig=` | | `text/calendar` |

## What the pages do with the answers (Pages, 20 Oct)

- **Static files** are only the fonts, `/book/fonts/IBMPlexMono-{400,700}.woff2` (Workers assets,
  `run_worker_first` for every path but `/book/*`; a year's cache from `public/_headers`). The CSS,
  the script and the logo are inline, so a page is the document, two fonts and Turnstile.
- **Turnstile** is sent only by a browser the page doesn't recognise. A recognised guest's tap posts
  at once with `turnstile: ""`: the book route skips the check only when the email posted is the one
  this browser booked with (or verified). Any other email answers `400 {field: "turnstile"}`, so the
  page solves Turnstile for it.
- **The follow-up** (`statusUrl`) is fetched 2 s after the `200`, again just after `undoUntil`, then
  every 3 s, five times at most. Anything but `200 {booking}` (such as `409 not_yet`) is asked again.
  The card reads `invite` (`sent` → "Invite sent to …"; `failed` → "Invite didn't go out", plus
  "Details emailed to …" when `canEmail`) and `placeDetail` (the Meet link); `taken` or `failed` with
  `nearest` turns the card into the nearest three times.
- **Undo** shows from the tap, on a card that says "Booking…" until the `200`; its countdown starts
  then, from `undoMs`. A move's Undo counts down from the move answer's `undoMs` too, and is sent
  as `POST /b/undo` (Routes, 20 Oct: not as a move back, which would tell Google and the host twice);
  `409 {kept: true}` means the page stays on the moved time and says the old one went. A `cancelled` status from the follow-up shows the
  card as Cancelled. An Undo whose booking answers after the window gets "Too late to undo".
- **Undo** posts `{manage}` as the last path segment of `manageUrl` (`<id>.<sig>`). `409 too_late`
  puts the card back as booked.
- **`?fb=`** on a times page is passed once to `GET …/slots?fb=`, then dropped from the address bar.
- **"not you?"** posts `POST /b/not-me` (Routes, 20 Oct: the cookie goes), and the form asks again.
  **Forget me** is linked from the footer as `/b/forget` for a recognised guest.
- **`confirmed(view)`** is the card as a page, for a direct load; the times page draws the same card
  itself (`kit.card`), so the two always match.
- **A cached times page** is kept with a placeholder for its nonce, and every answer from the cache gets
  a fresh one in both the page and its CSP header (Routes, 20 Oct). The cache key carries the host's
  version (snapshot, types, latest booking change), so a booking or an edit is never served stale.

## Rules both sides keep

- **POSTs** come from the booking host's own pages: the `Origin` header must be its origin. With a
  guest cookie (`__Host-bk`) a POST also carries the view's `csrf` as the `x-csrf-token` header.
  A failure is `403 {error: "origin" | "csrf"}`.
- **Undo** is 5 s on every booking and every move: the guest is put on the event (Google's invite),
  Google moves the event, our own confirmation email goes and the host is pushed only after it.

- **Times on the wire are UTC.** The page renders them in the guest's zone with `Intl` (`hourCycle`
  from locale, `timeZone: zone`) and groups by the guest's local date. It never parses
  `"YYYY-MM-DD"` with `new Date(...)`. A zone change re-renders on the page; the server isn't asked
  again.
- **Fewest taps, instant:** there is no loading state before times show, the tap shows the change at
  once, and errors don't lose what was typed.
- **Copy:** fewest words, no "X, never Y" tails, the landing page's voice.
