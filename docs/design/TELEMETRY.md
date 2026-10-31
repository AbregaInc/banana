# Usage counts

October 2026. The measure is daily active users, with a connected calendar as the least that counts
as activated (DESIGN-SYSTEM.md, onboarding). Until now nothing counted it.

## What's counted

On the device, as words from a fixed list (`Telemetry.Signal`), counted up and sent now and then as
one batch to the Banana service (`Service/`, docs/design/ACCOUNTS.md):

- **active**: the app came forward today (once a day).
- **onboarding**: each first-run step shown, continued or skipped, and done.
- **feature**: calendar connected; meal logged (photo, describe, scan, by hand); label read (parser,
  model); groceries scanned; event created or edited; routine started; podcast played.
- **failure**: Google sign-in, meal estimate, label read.
- **setup**, once a day with the first opening (`TelemetryState`): Google accounts and calendars
  connected, busy blocks on, Reminders / notifications / location granted, a Watch paired, Apple
  Intelligence available, routines on, podcasts followed, notes, OS major version, region,
  language, text size, light or dark. Health/food inventory counts are excluded; current clients
  also filter legacy queued counts and the collector drops them from older clients.
  Numbers go as ranges (0, 1, 2, 3–5, 6–10, 11–20, 21+). Each fact is its own count: the totals say
  how many copies have two calendars and how many have a Watch, never which have both.

A batch also says: iPhone, iPad or Mac; App Store, TestFlight or a developer's install; the version;
whether a calendar is connected; the ISO week the copy was first opened and the days since.

Never sent: any name, email, account, device or install id, what was logged, calendar, health,
meal, place or note content. The collector keeps no IP address and no row per device, only daily
totals per kind (`Service/migrations/0001_init.sql`), and drops anything not on its allow-list (`Service/src/usage.js`; a test
on each side keeps the two lists the same).

## Retention without an id

Each copy is active at most once a day and says how many days since it was first opened. The
copies first opened in a week are that week's day-0 count; its day-1, day-7 and day-30 counts are
who came back. Nothing joins one copy's days together.

## Signed in

Since 15 Oct 2026 a copy signed in to a Banana account (docs/design/ACCOUNTS.md) sends the same
batch with its session, and the service also adds it to that account's own daily counts
(`account_usage`). The anonymous totals below are kept as they were. The privacy policy has to say
so before this is live.

## Who sends

Only the official app: the service's host comes from the private config
(`BANANA_SERVICE_HOST`), so builds without a configured service send nothing. Main and separate
Beta use their respective configured services. Not the Simulator,
tests or `--ui-audit` launches. Developer installs are marked `dev` and left out of the report.

## Consent

Usage counts and diagnostic uploads require an affirmative Share usage setting. An absent
choice is off, in both the collector and Settings. Agreeing to onboarding terms does not enable
analytics. Settings › About › Share usage withdraws consent and throws away anything waiting
(App Store Review Guideline 5.1.1).

## Reading it

`tools/telemetry/report.py`: daily active copies (with a calendar, by device), the first run step
by step, coming back by week first opened, what's used, what fails.
