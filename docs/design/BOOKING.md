# Booking: your link, live times, guests who connect

Asked for 19 Oct 2026:

- The author: "now that we have the online service lets make the scheduling functionality actually work
  live like calendaly does. also allow guests to connect their accounts to make it easier."
- He confirmed this reading ("yes"), and asked for it to be on brand with the landing page, with new
  images where needed, and working on mobile, "the most important surface".
- He then added: "appointment reminders, call locations (Google Meet, Zoom, etc?) … ideally minimal
  implementation and maintenance work for us. Timezones are the one area you should not fuck around,
  take a look at how we did it in elevate."

A Fable agent reviewed the first draft. Its defects are fixed below, listed in §11. Elevate is
`~/repo/abrega/coaching_platform`; its newer slot engine `src/lib/consultation/slots.ts` is the
model for time zones (§3).

## 1. What it is

| Piece | What |
|---|---|
| **Your link** | `book.bananatheapp.com/noor`, with a page per booking type (`/noor/intro`). Live free times from your Google calendars, worked out by the service when the page opens. Your devices can be off. |
| **A guest books** | They pick a day and a time in their own time zone, and give a name, an email and an optional note, plus a phone number when the type is a phone call. The event goes on your calendar with them invited, and Google's invite is the confirmation (with its .ics). You get a push. |
| **Where you meet** | Each type offers one or more of: Google Meet (made with the event); your Zoom link (your own personal meeting link, pasted once — no Zoom app to run); a phone call (you call them, or they call you); in person (an address); or any other link. If a type offers several, the guest picks one. |
| **Reminders** | An email to the guest 24 hours and 1 hour before, in their time zone, with the time, the place and the change or cancel link. You get Google Calendar's own reminders on the event, and Banana's event alerts. |
| **Change or cancel** | A private link, in the reminder emails, the event's description and the confirmation page. Rescheduling moves the same event; cancelling deletes it. Google tells everyone. |
| **A guest connects their calendar** | "Connect your calendar" reads their Google free/busy once, and the page then offers only times you're both free. Nothing of theirs is kept. |
| **On brand, phone first** | The landing page's look (IBM Plex Mono, the cream palette, the logo). Designed at 390 px first, then 768 and 1280. Images are generated where the page wants one. |

**Not built, on purpose** (minimal upkeep):
- our own confirmation email (Google's invite is the confirmation);
- SMS;
- Zoom's API;
- payments;
- round-robin, teams;
- custom questions beyond the note;
- other calendar providers;
- embeds.

## 2. Where availability comes from

Free time is the type's weekly hours, minus busy time, minus notice and buffers.

- **Busy time.** Every event on the account's included calendars that is opaque, not declined and not
  cancelled.
  - All-day events count only when marked Busy, as in the app.
  - The included calendars are every Google link's calendars from `calendarList.list`, minus
    `core.smartSettings.excludedCalendarIDs` (read from the space with one small `read(type, id)`
    on the space port) and minus hidden ones.
- **Banana's plan is already in Google.** Tasks, travel and mirrored meetings are Busy blocks the
  devices write (CalendarWriteBack), so the service sees them as events. Nothing is ported.
  The limit: a block is as fresh as its last write-back.
- **Scopes.** A link is read only if `google_links.scopes` holds both `calendar.events` and
  `calendar.calendarlist.readonly` and it has a server token. Otherwise its calendars are unknown,
  and **unknown is never free**: the page offers nothing until that link reconnects.
- **No shared cache.** An isolate's memory can't be invalidated across isolates, so there is none.
  - The slots route reads the window, at most `horizonDays`.
  - The book route re-reads only the slot's day.
  - The slots answer may carry a 60 s HTTP cache with no invalidation.
- **A booking makes the event.** Device write-back then mirrors it as a private Busy block onto your
  other writable calendars, which is what the Calendly case wanted. Write-back never edits or deletes
  the booking itself (it only touches events with its own `bananaVariant` marker, and legacy adoption
  skips events with attendees).

## 3. Time zones (the rule, from Elevate, with its gaps closed)

- **Storage.** Weekly hours are wall-clock minutes from 00:00 (0–1440) per weekday, with one IANA
  zone per booking type. The zone defaults to `accounts.time_zone`, which the devices already report;
  if that is unset, the iPhone's zone as reported in the type. The host's zone wins over anything
  stored on a rule (Elevate `service.ts:115`).
- **Zone names.**
  - Validated with `Intl.DateTimeFormat(…, {timeZone})`.
  - Legacy aliases are mapped to canonical names.
  - Abbreviations (EST, PST…) are refused, since they are ambiguous.
- **Expansion, day by day, in the host's zone.**
  - Start from "today" in the host's zone.
  - For each day and each wall minute on the grid, build the string `YYYY-MM-DDTHH:mm` and convert it
    to an instant with a standard library (`@date-fns/tz`/`date-fns-tz`, as Elevate does).
  - Never `new Date(y, m, d, h, mi)`: it depends on the server's zone. Elevate's own trap, tested
    there with `TZ=America/New_York`.
  - The end is start plus the duration in elapsed time.
  - `endMinutes = 1440` means 00:00 of the next day.
- **Spring forward** (a wall time that doesn't exist): **no slot**. After converting, the instant is
  converted back. A slot whose wall time doesn't round-trip is dropped. (Elevate silently moves
  02:30 to 01:30 and offers a time before the host's hours.)
- **Fall back** (a wall time that happens twice): the slot is offered **once**, at the first
  occurrence, and a duration crossing the change is measured in elapsed time.
- **Grid.** On the host's wall clock (`:00/:15/:30/:45` there). That is right for half-hour and
  45-minute zones, unlike Elevate's older engine, which used UTC minutes.
- **Notice and horizon** are counted in elapsed time from now (notice) and in host days (horizon).
- **On the wire.** Slots are UTC ISO strings with `Z`. A booking posts the exact string; the service
  regenerates the slots and requires an exact match (Elevate `service.ts:637`).
- **The guest's view.**
  - The browser's zone (`Intl.DateTimeFormat().resolvedOptions().timeZone`) by default, with a zone
    picker and the caption "Times in New York time (change)".
  - Days are grouped on the page in the guest's zone.
  - A picked date is a local date, never `new Date("YYYY-MM-DD")` (Elevate's UTC-midnight bug,
    `4126d189b`).
- **Stored with the booking:** the guest's zone, used for their reminder emails (Elevate uses the
  company zone for guest emails; we don't).
- **Emails** print the time in the guest's zone with its short name ("Tue 21 Oct, 3:00 pm EDT"). The
  Google event is created with UTC instants plus `timeZone` set to the type's zone, so each person's
  calendar shows it in their own zone.
- **Tests:**
  - America/New_York spring-forward and fall-back days, including hours starting at 02:00;
  - Europe/London;
  - Australia/Lord_Howe (half-hour DST);
  - Asia/Kolkata (+05:30) and Asia/Kathmandu (+05:45);
  - Pacific/Chatham;
  - a southern-hemisphere change;
  - `endMinutes = 1440`;
  - a horizon crossing a DST change;
  - a guest 13 hours away whose "today" is the host's tomorrow;
  - every test run under `TZ=UTC` and again under `TZ=America/New_York` (the server zone must not
    matter).

## 4. Booking types

A record in the person's space, `plan.bookingType` (T1, writers any), edited in the app:

| Field | Default |
|---|---|
| `title`, `slug` | "Meeting", `meeting` |
| `minutes` | 30 |
| `hours` | Mon–Fri 09:00–17:00 (wall minutes, several spans a day allowed) |
| `timeZone` | `accounts.time_zone` |
| `step` | the duration if it divides 60, else 15 (Elevate) |
| `bufferBefore` / `bufferAfter` | 0 / 0 |
| `notice` | 4 h |
| `horizonDays` | 30 |
| `perDay` | none |
| `locations` | [Google Meet] |
| `calendar` | the primary calendar of the oldest Google link (a picker in the app) |
| `active` | on |

The service reads types from the space, so they work with every device off.

**The handle** is one per account. It is `[a-z0-9-]{3,30}`, never one of the reserved words (`m`,
`b`, `v1`, `v2`, `assets`, `privacy`, `support`, `api`, `book`…), and kept in D1
(`booking_handles`, migration 0010). Changing it later keeps the old one as a redirect for 90 days.

## 5. Booking

1. `GET /<handle>/<slug>/slots?from&to` gives the type, its locations and the slots (UTC). It needs no
   auth, is rate-limited per IP (the Workers rate-limiting binding), and is cacheable for 60 s.
2. The guest picks a slot, the place if there is a choice, and fills the form. Turnstile checks the
   form. **Inputs:**
   - name ≤ 80 characters;
   - email ≤ 254 characters and syntactically valid;
   - phone (when asked) ≤ 32 characters;
   - note ≤ 1000 characters.

   All are HTML-escaped where Google renders the description, with control characters stripped.
3. `POST /<handle>/<slug>/book` carries a client-made booking id, so a retried post returns the same
   booking.
   1. **Reserve.** One conditional insert into D1 `bookings`:
      `INSERT … SELECT … WHERE NOT EXISTS (an overlapping pending or confirmed booking for the account)`.
      It is atomic, and it is the lock. Locks held across awaits don't work in a Durable Object.
      Pending rows older than 2 minutes are released by the minute cron.
   2. **Check.** Re-read the slot's day from each included calendar and regenerate. If the slot is gone,
      release the reservation and answer "taken".
   3. **Make the event.** The event `id` is derived from the booking id, so a retry answers 409 rather
      than making a second event.
      - `sendUpdates=all` and `conferenceDataVersion=1`.
      - Meet: `conferenceData.createRequest {requestId: booking id, conferenceSolutionKey: hangoutsMeet}`.
        If the answer is `pending`, one `events.get` reads the link. If Meet is disabled, the event
        stays confirmed without one.
      - Zoom, phone, in person or link: `location` and description.
      - `reminders.useDefault: true` and default visibility (unlike busy blocks).
      - `extendedProperties.private.bananaBooking: <id>`.
   4. **Confirm** the row, then push the host's devices: "Sam booked Meeting, Tue 3:00 pm".
4. **Limits:**
   - bookings per IP per hour;
   - per handle per day;
   - one future booking per guest email per type ("You already have a time" with the manage link);
   - the type's `perDay`.
5. **The manage page** `/m/<id>.<sig>`.
   - The id is 128 random bits. The signature is HMAC-SHA256 with a key derived from `TOKEN_KEY` (as
     the analytics key is), compared in constant time.
   - It is valid until the event ends plus an hour. Every failure is a plain 404, never logged.
   - It reads the event live (`events.get`) and shows the truth: moved, cancelled or gone.
   - Reschedule patches the same event. Cancel deletes it with `sendUpdates=all`.
   - The link also sits in the event's description, so anyone who can read the host's calendar can use
     it. That is accepted, as in Calendly.
6. **Reminder emails.**
   - The minute cron sends the 24 h and 1 h emails for confirmed bookings whose event still exists. It
     makes one `events.get` before sending, and skips if the event moved or is gone.
   - Sent through **Amazon SES** (Elevate's provider, an account Abrega already runs), signed with
     `aws4fetch` (a small standard SigV4 signer).
   - Plain HTML in the landing page's look, from `Banana <book@bananatheapp.com>`.
   - Rows mark what was sent, so each email goes once.
7. **Retention.** `bookings` keeps the guest's name, email, phone, zone and note only until 30 days
   after the event, then the row is deleted. Nothing about the guest goes into the host's space
   history. The Google event keeps what the host's calendar keeps.

## 6. Guests connecting their calendar

- **"Connect your calendar"** opens Google sign-in on the Banana web client with
  `https://www.googleapis.com/auth/calendar.events.freebusy`, `access_type=online`,
  `prompt=select_account`, and a `state` tied to a short-lived cookie.
- **At the callback** (`/b/connect/callback`, its own code exchange with its own redirect URI), one
  `freeBusy.query` covers the type's whole horizon.
  - The busy intervals go back to the page in a one-time signed blob and are intersected on the page.
  - The access token is dropped. Nothing is stored.
  - Reopening the page needs another connect.
- **A guest who uses Banana** gets "Use my Banana calendars" instead: sign in, and the service
  intersects with all their included calendars. Neither side ever sees the other's events.
- **Google's side:**
  - The consent screen must be **In production**. Otherwise only listed test users can connect.
  - The free/busy scope is believed non-sensitive (no review); the author checks the label in the Console's
    scope picker when he adds it.
  - The redirect URIs (`book.` and `beta-book.`) must be registered on the web client.

## 7. In the app

- **Settings › Booking:**
  - the link (Copy, Share);
  - the handle;
  - the booking types: add, edit, turn off. Each type sets hours per weekday, length, locations, notice
    and buffers, and its zone (the device's by default).
- **Booking type editor:**
  - pasting your Zoom link once offers Zoom as a location;
  - a phone number for "you call them" or "they call you".
- **The Share availability sheet** gets "Copy booking link" first.
- **New, moved and cancelled bookings** push the host. The events themselves are ordinary calendar
  events.
- **Devices:** iPhone, iPad and Mac together. System controls. Fewest words, with no "X, never Y"
  tails.

## 8. Web

- **Hosts.** `book.bananatheapp.com` (stable) and `beta-book.bananatheapp.com` (beta) are custom
  domains on the service Worker.
  - The Hono app routes by host: booking pages only on `book.`, the API only on `api.`.
  - Static assets come from Workers assets: CSS, Plex Mono copied from `LandingPage/site/assets/fonts`,
    the logo, generated images.
- **Pages:** profile, type, slots, form, confirmation, manage, connect.
  - Server-rendered HTML with a small script, no framework.
  - Accessible: labels, focus, 44 pt targets.
  - Light, as the landing page is.
  - Security headers: CSP, `Referrer-Policy: no-referrer`, `frame-ancestors 'none'`.
- **Done when:**
  - screenshots at 390, 768 and 1280 px;
  - Lighthouse mobile ≥ 95;
  - a page-weight budget like `check_site.py`'s.

## 9. Privacy

- **The policy.** A "Booking with someone who uses Banana" section must be **live before the first
  booking**. It covers:
  - what a guest gives;
  - that it goes to the host's Google calendar and Banana's service on the host's behalf, kept 30
    days after the meeting;
  - reminder emails;
  - that free/busy is read once, never stored;
  - SES as processor;
  - that the guest's rights go through the host or `support@`.
- **Pages:** no tracking, and no cookies beyond the connect state.

## 10. Stages, and what needs the author

| Stage | What | Done when |
|---|---|---|
| **A. Engine** | the slot engine (§3) with its tests; calendarList; the busy read; the space `read`; the slots route | tests incl. every zone case, under two `TZ`s |
| **B. Booking** | migration 0010 (`booking_handles`, `bookings`); reserve, check, event, confirm; manage (reschedule, cancel); limits; reminder emails via SES; the retention sweep; push | tests with a fake Google and a fake SES: races, retries, stale slot, Meet pending/disabled, reschedule, cancel, host-side delete, reminders once and skipped when moved |
| **C. Pages** | everything in §8, mobile first, on brand, images | screenshots reviewed, Lighthouse, budget |
| **D. Guest connect** | §6 | a fake Google; a Beta run with a test account |
| **E. App** | `plan.bookingType` in the catalog and adapter; Settings › Booking and the editor on iPhone, iPad, Mac; the share link; pushes | unit tests, simulator screenshots, no real accounts |
| **F. Policy** | §9 | `check_site.py` |

**Needs the author** (asked when each stage is ready, not now):
1. Turnstile site key and secret (Cloudflare dashboard).
2. SES: the region and an IAM key with `ses:SendEmail` only, and `bananatheapp.com` verified in SES
   (DKIM records in Cloudflare DNS, which wrangler or the API can add).
3. Google Console: the redirect URIs, the free/busy scope added, the consent screen In production
   (it is, for the prod project).
4. The deploys, and publishing the policy.

## 12. Second review and the owner's UX rules (20 Oct 2026, these override the sections above)

Owner, 19–20 Oct:
- "Keep guests details, we want them to be auto authed when they come back and try and schedule with
  someone else."
- "Optimize for the best possible end user UX above all else."
- "fewest clicks to success."
- "not just booking, everything."
- "Everything should feel instant … Our competition is Superhuman, so we need to be even better."

### Tap counts (the target)

| Flow | Taps |
|---|---|
| First-time guest, phone | time → name (AutoFill) → email (AutoFill) → Book = **4, no typing** when AutoFill offers |
| Returning recognised guest | **1** (the time), with Undo for 5 s |
| First-time Google connect | 3 once, then **1** |
| Reschedule | the link → a time = **1** |
| Host sharing the link | Share → person → Send = **3**, from the calendar toolbar's share menu |

### The flow

1. **Landing.** `/<handle>` with one active type lands on the times: the host's name over the type's
   title (Calendly's and Cal.com's order; a host the service has no name for gets no line, never the
   handle), a month grid one month at a time with arrows, the picked day's times in the guest's zone
   (two to a row on a phone), and "New York time · Change" as the only chrome. On a phone a tapped
   day brings its times up under the top. With several types, one row each with "Next: Tue 3:00 pm".
   (Owner, 30 Oct 2026: lay the page out as Calendly, Cal.com and Chili Piper do, mobile first; the
   one-row day strip of 20 Oct is gone.)
   - The whole horizon is rendered into the first HTML, with no second request.
   - Plex Mono is preloaded.
   - No images and no dark mode: the brand is light, and images cost the phone more than they give.
   - Turnstile (managed) loads with the page, so it is solved before Book.
2. **First time.** A time opens a sheet with:
   - name, email and phone (phone only for phone types), each with `autocomplete`;
   - the place, only if there is a choice;
   - "Add a note", collapsed;
   - Book.
3. **Recognised guest.** A time books at once.
   - The service reserves the slot and makes the event without the attendee, then shows "Booked" with
     Undo (5 s) and Edit.
   - Once the window passes (`waitUntil`, with the minute cron as the safety net), the attendee is
     added with `sendUpdates=all`. An Undo therefore never sends an invite followed by a cancel.
   - A new browser shows the sheet once.
4. **Slot taken.** The page shows the three nearest times, each one tap. With the host's link refused:
   "Noor isn't taking bookings right now", and the host gets a push.
5. **Confirmation.** One screen:
   - a check mark;
   - "Tue 21 Oct, 3:00–3:30 pm, New York time (9:00 pm for Noor)";
   - the place (the Meet link ready, the phone number, or the address with a Maps link);
   - "Invite sent to sam@…";
   - Add to calendar (.ics);
   - Change and Cancel.
6. **Our own email** confirms (time in the guest's zone, place, Change, Cancel, .ics), and Google's
   invite also goes out. The reminders are at 24 h and 1 h; the 24 h one is skipped when the booking is
   made inside 24 h.
7. **Upcoming times.** A verified guest sees "Your next time: Tue 3:00 pm with Noor · Change" on any
   booking page.
8. **Host.**
   - "Share booking link" sits in the calendar's share menu on iPhone, iPad and Mac (`ShareLink`).
   - The handle is suggested from the Google name, accepted with one tap.
   - Event titles read "Meeting: Sam Lee".
   - Cancelling from Banana notifies the guest (`sendUpdates=all` is already there; a test is added).

### Speed

- The page answers fast, with real times in the HTML. Targets on a mid-range phone on 4G:
  - TTFB under 300 ms;
  - LCP under 1.2 s;
  - INP under 100 ms;
  - CLS 0.
- A tapped time reacts at once, shown optimistically.
- The next week is already in the page.
- Lighthouse mobile scores 98 or more.

### How the speed is reached (Fable, 20 Oct)

**Targets**, measured at p75 on a mid-range phone over Lighthouse's 4G:

| Measure | Target |
|---|---|
| TTFB | 200 ms or less (100 ms or less from cache) |
| FCP | 0.8 s or less |
| LCP | 1.2 s or less |
| CLS | 0 |
| INP | 100 ms or less |
| Tap to "Booked" on screen | 50 ms or less |
| Reservation acknowledged | 300 ms or less |
| Invite on its way | 2 s or less |
| First load | HTML 12 KB, JS 8 KB, CSS 6 KB, fonts 50 KB (all gzipped); 4 requests or fewer; no images |

**How each is met:**

1. **A busy snapshot per account.** `busy_snapshot (account_id, horizon_json, computed_at)` holds the
   next 31 days of busy intervals: times only, no titles.
   - It is rebuilt in `waitUntil` whenever a watch reports a change, and by the 15-minute job as a
     safety net. Snapshots older than 10 minutes are served while rebuilding.
   - The slots read is then one D1 read plus the pure engine. Only booking re-reads Google, for the
     slot's day.
2. **Rendered in the guest's zone at the edge.** The zone comes from `request.cf.timezone`.
   - Pages are cached in `caches.default` per handle, type and zone for 30 s, with
     `stale-while-revalidate=300`.
   - An inline script re-labels only when the browser's zone differs (a VPN).
   - Slots travel compactly: start minutes per day.
3. **Optimistic two-phase booking.**
   - On tap: "Booked · Undo" shows at once. The POST (`keepalive`) only reserves in D1.
   - Then `waitUntil` inserts the event and marks the booking confirmed. One follow-up fetch fills in
     "Invite sent" and the Meet link.
   - If the reservation fails, the card reverts and the nearest three times appear.
   - If the Google insert fails, the cron retries three times. Then the booking is marked failed, the
     guest is emailed and the host pushed.
4. **No shift.**
   - Rows are 44 pt.
   - The grid's height is reserved from the slot count.
   - The sheet is a `<dialog>` overlay.
   - Fonts are preloaded, with a metric-matched fallback face.
   - Turnstile is `interaction-only` and loaded after LCP.
   - The logo is inline SVG, and the CSS is inline.
5. **Every tap repaints within a frame.** One delegated listener, CSS transforms,
   `touch-action: manipulation`.
6. **D1 read replication** (Sessions API, `first-unconstrained`) serves the slots read. `Server-Timing`
   is sent on every page.
7. **Layout.** "Soonest: today 3:00 pm" comes first, so a recognised guest needs one tap. Below it the
   day strip and a two-column times grid that fits a 9–5 day at 390 px. The confirmation reuses the
   same card.
8. **Measurement.** Lighthouse mobile in CI against `beta-book.`, a budget check (`check_book.py`), and
   a run on a real phone before each deploy. The build fails if a target slips. There is no RUM: these
   pages have no tracking.

**The host:**
- `ShareLink` in the calendar's share menu (iPhone, iPad);
- Calendar › Copy Booking Link, ⌘⇧L, the status-item menu and the toolbar (Mac);
- an AppIntent "Copy my booking link", for Siri, Spotlight and Shortcuts.

### Stage E, as built (20 Oct, with Fable's review)

- **Taps.** Share: the Plan's share button → person → Send = 3 (iPhone, iPad: the system share
  sheet anchored to the bar button; the Mac toolbar's share menu the same). Copy: ⇧⌘L, the Calendar
  menu, ⌘K, the menu bar panel, "…" on the phone, the availability sheet = 1; each is there only with
  a link. A first link: "Use" = 1, or share the service's suggestion. The link shared is the one
  shown, and the suggestion is taken once the share completed (or the copy happened).
- **The link** is the service-confirmed handle. A handle on its way shows in the field; Copy and
  Share wait for it. A 400 `zone` sends the claim again without a zone. Only the service's
  suggestion is ever shared; one made on the device from the Google email only prefills the field.
  A sign-in asks `GET /v1/booking` only until the service has answered once; then Booking and
  sharing ask.
- **Types** are `BookingTypeStore` (`booking-types.json`) synced as `plan.bookingType` by
  `BookingTypeAdapter`, seeded as the adapter joins (no legacy channel ever carried it).
- **The default type** appears when Booking is first opened, under the id `default`, and is not sent
  while unchanged: the service offers the same type to an account with none. A change to it waits
  until this device has pulled the type once (`RecordAdapter.pullCompleted`); if the account's own
  `default` arrives first, only the fields changed here are laid over it and go up, so the first
  edit on a new device never overwrites another device's.
- **A slug** is made from the title when the type is made, and then stays: a guest's link keeps
  working when the title changes.
- **Pushes** (`pushHost` in book.js: `b: {k: "booking", cal?, event?, start? (ms), cancelled?}`) show
  over the app on iPhone, iPad and Mac. A tap opens the event on the Plan (read again once if it
  isn't there yet); a cancelled booking opens the Plan on its day; a push naming neither opens the
  Plan. Both notification delegates follow one rule, `NotificationRoute` (Taken reminders, event
  alerts, bookings, meal photos).
- **Larger text:** at the accessibility sizes the site sits above the name, Copy over Share, the
  lengths become a menu and a day's hours stack.

### Guests are accounts

- **The tables:** `accounts.kind` (`person` | `guest`) and `sessions.kind`.
  - `signedIn` refuses guest sessions, so a guest cookie never reaches `/v1` or `/v2`.
  - `guests` holds `(account_id, email unique, name, phone, zone, verified_at, last_seen_at)`.
  - `guest_grants` holds `(sub, account_id, email, refresh_token encrypted, scopes, status)`, a
    separate table so a host's `google_links` token is never overwritten.
- **Recognised** (a `__Host-` cookie on `book.`, HttpOnly, Secure, SameSite=Lax, a year, stored hashed
  in `sessions`, POSTs checked for `Origin`): the form is prefilled, with "not you?". Nothing is shown
  from their history.
- **Verified** (Google, or a 6-digit emailed code asked only when they want their history): upcoming
  times, change from the list, Forget me, and automatic free/busy.
- **Google connect.**
  - Scope `calendar.events.freebusy`: primary calendar only, and the page says "your Google calendar".
  - `access_type=offline&prompt=consent` only when no grant is held. Otherwise identity alone.
  - Free/busy is read only while they are on a booking page, never by a job.
- **A guest who is also a Banana person** uses their own calendars through their existing token
  (events.list), so all of their calendars count. When a guest later signs in to the app, the
  `guest_grants` account becomes theirs.
- **Forget me** is one confirmation line: "Your 2 upcoming times stay on the hosts' calendars.
  Reminders stop." It revokes the grant and anonymises their booking rows until the events end.
- **Retention:** until they forget, or 2 years with no use (a sweep in the 15-minute job). Export goes
  through support@.
- **Policy:** Banana is the controller for guest accounts, and the processor for bookings on the host's
  behalf. The basis is contract, plus consent for the Google grant.

### Engine corrections

- **Busy time** = Google events ∪ D1 bookings (pending and confirmed, future), each padded by the
  type's buffers. The D1 overlap check pads by buffers too.
- **All-day Busy events:** `[start.date 00:00, end.date 00:00)` in the calendar's own zone
  (`calendarList[].timeZone`). `workingLocation` events are skipped.
- **Days** step by calendar-date arithmetic on the host zone's date parts (Intl parts, then
  `Date.UTC(y, m, d + n)`), never `startOfDay`/`addDays` in the server's zone.
- **Library:** `@date-fns/tz`. `new TZDate(y, m, d, h, mi, zone)` turns a wall time into an instant,
  and Intl with `hourCycle: "h23"` turns it back. A spring-forward slot is dropped when the round trip
  differs. Both libraries move a missing time silently, and in opposite directions; the test file has
  the probe's five rows.
- **Zone names** must contain a `/` or be `UTC`, and are canonicalised with
  `resolvedOptions().timeZone`. The picker lists `Intl.supportedValuesOf("timeZone")`.
- **Times are shown** as "3:00 pm, New York time", with the city taken from the IANA id. The
  abbreviation is used only where Intl has one, and every time is formatted at the meeting's instant.
- **Rules:**
  - `perDay` counts in the host's zone;
  - spans can't cross midnight;
  - the horizon's last day is today + horizonDays − 1;
  - the slots answer is the whole horizon (no `from`/`to`/`tz`).
- **The type's zone is fixed** once set. `accounts.time_zone` only seeds it, and it doesn't follow the
  host's travel.
- **Event ids** are 128 bits in lowercase hex (fits `[a-v0-9]`). The client id is only an idempotency
  key, scoped to (email, slot). The manage id is made by the server. On a Google 409, `events.get`
  and carry on.
- **Rebooking with an email that already has a time:** "We've emailed your existing time", and the
  link goes only to the email.
- **Reminders** are sent from the D1 row when the host's token is refused or Google is down. They are
  skipped only on a definite moved or gone; a time already past at booking is skipped. When the cron
  finds the event moved or cancelled, the guest gets one email.

### Email

- Cloudflare Email Service (`[[send_email]]`), behind a `deps.email` port. SES through `aws4fetch` is
  the alternative adapter. `replyTo` is the host's email.
- It needs Workers Paid and the one-click domain onboarding (The author). Check first for any SPF or DMARC
  records to merge.

### Cut from v1

- generated images and dark mode;
- the 90-day handle redirect: a changed handle's old links 404;
- SMS;
- the Zoom API: the personal link is enough, and the guidance tells hosts to set a waiting room or
  passcode;
- passkeys;
- "Use my Banana calendars" as its own feature: it comes free with guest accounts.

## 11. Fixed after Fable's review (19 Oct)

1. **The lock:** a conditional insert in D1, not a Durable Object held across awaits.
2. **Idempotency:** a client-made booking id, and the event id derived from it.
3. **Guest connect:** one free/busy read for the whole horizon, handed to the page; nothing kept.
4. **Scopes:** the exact scope name, a per-link scope check, the consent screen's status, a separate
   code exchange and redirect URI.
5. **Abuse:** input caps and escaping, the rate-limiting binding, per-email limits; Turnstile is one
   defence, not the only one.
6. **Retention:** guest data in D1 for 30 days after the event, never in the space history.
7. **No cross-isolate cache;** narrow re-reads.
8. **The manage page reads the event live,** rather than trusting a reader that may not run.
9. **Meet:** `conferenceDataVersion`, `requestId`, the pending status, Meet disabled; reminders on
   the event.
10. **Time zones** stated as rules, from Elevate, with its spring-forward and older-engine bugs closed
    (§3).
11. **The manage link:** what it is, how long it lives, 404s.
12. **Web:** routing by host, assets, reserved handles, the beta host, security headers.
13. **Write-back:** the booking is mirrored as Busy (wanted), and never touched.
14. **The policy** is live before the first booking.
15. **Calendly basics** written down: the invite is the confirmation; the zone picker; Meet shown on
    confirmation; the default calendar defined.
