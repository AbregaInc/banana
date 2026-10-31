# Future features, and what they decide now

None of this is being built yet. It is written down so the current design pass leaves room for
it: each section lists the feature, where it came from, and **what the design reserves for it
today**. Those reservations are rules in `DESIGN-SYSTEM.md`; where they needed code, it exists
already (marked ✓), so the feature can be added without changing how anything around it looks.

Sources: the Mobbin research from 26–27 Sep 2026 (Today & Settings, Onboarding, Podcasts,
Nutrition, Workouts), the travel-time investigation of 27 Sep, and the Cron/Notion Calendar
research.

## Decided now, used by many features

| Future need | Reserved now | Where |
|---|---|---|
| Undo instead of "Are you sure?" in Nutrition, Notes, Library, Settings | One app-wide toast with at most one action; deferred removal hides the item until the window closes | ✓ `ToastCenter`, hosted on every tab and the Mac content pane |
| Comparisons on numbers (vs goal, vs average, vs last month) | Every figure is a `StatValue`; its `footnote` is the comparison slot | ✓ `StatValue` |
| Account, sync and permission status | An 8-pt dot plus a word ("Live", "Syncing", "Sign in again") | ✓ `StatusDot`, `ConnectionStatus` |
| Settings rebuild and settings search | Row anatomy (tile, title, trailing value, chevron); stable id per setting | ✓ `IconTile`, `DS.Row`; rule in "Rows" |
| Coming back to where you were | Tab and each tab's stack live outside the view tree | ✓ `ShellNavigation`; rule in "Navigation and state" |
| Data that arrives late (HealthKit, Google, weather) | "—" placeholders of fixed size; skeletons with the result's geometry | ✓ `DS.placeholder`; rule in "Loading and empty" |
| More modules on Today | Section headers outside cards, sentence case; card = `Radius.card`, at most 3 rows and a footer link | Rule in "Sections and casing" |

## Travel time

**Built 27 Sep 2026** (fixes 1–3 and 5 below, approved that day):
- Confirmed places, synced in settings (`SavedPlace`).
- A guessed place shows "Chelsea?" on the band, the Today card, the inspector and the event
  sheet.
- The place picker asks Apple Intelligence what kind of place the event is at, as search
  phrases: "Lap Swim" gives "swimming pool, recreation center".
  - It uses the iOS 27 cloud model when available, otherwise the on-device one.
  - The question is asked in the background as soon as a guessed place appears, and answers are
    remembered.
  - Keyword results show at once and the model's merge in when they arrive.
  - The old keyword table is the fallback.
  - The on-device model took about 7 s per answer on a Mac and misread "Masters practice" as
    tennis. A wrong answer only adds extra results.
- Mode per trip, and walking for anything under 1.3 km.
- The trip home is timed from when you leave.
- Every estimate is logged under the travel log category and in the diagnostic journal.

Rules: see "Travel" in DESIGN-SYSTEM.md.

**Learning from real trips, built 27 Sep 2026** (approved):
- Off until "Learn from my trips" is turned on in Settings › Travel. That's when iOS asks for
  "Always" location and Motion & Fitness.
- The phone pairs visits into trips, finds the mode from motion, and compares each trip with
  Apple Maps' estimate for the same leg.
- It learns your pace per mode and your usual time from home to each place.
- Only that summary (`LearnedTravel`) syncs; the visits stay on the phone for 60 days.
- Estimates use your usual time once there are 2 or more trips to a place, and your pace once
  there are 3 or more trips by that mode. Getting there says which ("Usually 22 min, from 4
  trips").

**Still future:**
- Start trips from where you actually are rather than from home. The Mac doesn't know where
  you are, so both devices would need to agree on it first.

## Today

- The header is the date in small secondary text plus one computed headline ("Leave by 8:40 ·
  Standup 9:00").
- Modules in a fixed order: Now/Next → Morning / Afternoon / Evening → Health → Briefing →
  everything else collapsed. Edit mode reorders or hides them.
- Meetings, alarms, routines and reminders share the day-part sections. The source is shown by a
  16-pt leading glyph in its role colour.
- **Gap rows** ("45 min free") in secondary text; overlaps in `danger`.
- Now/Next as a countdown in words ("leave in 12 min"), updated every minute.
- Weather becomes a header pill that expands into the stripe.
- Health shows at most 3 metrics, each with a label, a status word and a value.
- The briefing collapses once it has been read. At most one alert card at a time; others wait
  in a queue.

**Reserved now:**
- `StatValue` for health metrics; the status word goes in `footnote`.
- Section-header and card rules.
- Tabular digits for every time and duration.
- `DS.placeholder` while HealthKit loads.

## Settings

**Built 27 Sep 2026.** The root is:
1. The account card: who you're signed in as, and a status dot.
2. Features: Calendar, Travel, Wake & bedtime, Podcasts, Workouts. Each row shows its current
   value and opens its own page.
3. General: Apple Watch, iCloud, and Permissions ("3 off").
4. About.

Search results name the page and open it. Permission rows use a dot and a word ("Allowed").

Still future:
- Mac settings as a sidebar window.
- Footnotes under every non-obvious toggle.
- Suggestions shown before typing in search.
- A danger-zone group.

The original research:

- The root, in order:
  1. Account card (Google accounts, sync status)
  2. General
  3. Features: one row each for Calendar, Alarms & Routines, Podcasts, Workouts, Nutrition,
     Weather, Voice notes
  4. Devices (Watch, Mac)
  5. About
  6. Danger zone
- Every row has an icon tile, a title and a trailing **current value** ("Transit", "Off", "3
  accounts"). A chevron marks rows that open a screen; ↗ marks external links.
- **Search over every setting.** Results show where the setting lives ("Calendar › Busy
  blocks"), and suggestions appear before typing.
- Toggles save immediately with a quiet toast. Forms with several fields use Cancel/Done.
- A footnote under every toggle that isn't obvious. Permission rows show "Allowed" or "Off –
  Fix".
- Mac: the same groups in a sidebar. Each row is icon, title, a one-line description and a
  trailing control.

**Reserved now:**
- `IconTile` (solid) and `DS.Row`.
- Each setting gets a stable identifier and a breadcrumb path, so a search index can be
  generated rather than hand-kept.
- Settings nest at most two levels.

## Alarms and routines editing

- The time is the largest element, and the title states the consequence ("Rings in 7h 12m").
- Days as 7 inline circles (44-pt targets) plus preset chips. The parent row reads back a
  summary ("Weekdays").
- A live "Next: Tomorrow 6:00" caption, with a "Next wake only" override.
- The sound picker is grouped into sections; tapping a row previews it, and the preview stops
  when the sheet closes.
- List rows read back as one line: "06:00 · Weekdays · Morning routine (4 steps)".

**Reserved now:** Cancel/Done in the toolbar for every edit sheet, never a floating Save button.

## Onboarding and accounts

**Built 27 Sep 2026, rebuilt 9 Oct 2026** (after the tap-by-tap review; DESIGN-SYSTEM.md, "First
run" and "Permissions"):
- The first run is one path: a welcome, two questions that build a day (wake, wind down),
  then Google Calendar over that day, then the app. The same on a phone, an iPad and a Mac,
  and nothing is required on any of them.
- Not built: an alarm ask on the wake question ("Ring an alarm then?"). A wake alarm today
  rings only from a calendar-driven wake plan, so a truthful ask there needs alarm work of its
  own. Alarms stay on the setup list.
- Not built: a marked sample day for someone who skips Google. They land on their own wake and
  wind-down times and the starter routines.
- Nothing counts activation. Daily active users and connected calendars can't be seen from
  the app; TestFlight gives sessions per tester over 7, 30 and 90 days, not days.
- Everything else is on the setup list: a line above the plan (with or without a calendar), all
  seven rows, each with a page of explanation before the system is asked. A refusal's button is
  "Open Settings"; Apple Health once asked reads "Asked".
- Location is never asked for by a forecast loading: only from its row, or a button.
- The calendar choice uses each calendar's colour as its checkbox, grouped by account, with
  "Shared" tags.
- The onboarding surfaces now adapt to dark mode.

Still future:
- A dedicated "Do you have more accounts?" step. Today the calendar sheet has "Add another
  Google account".
- The full priming template with a real preview.
- A Connected Accounts screen of cards with per-service toggles.
- The Mac setup window.

The original research:

- **Google sign-in, then "Do you have more accounts?"**:
  - the account as a card, with an avatar, the email and a "Main account" tag
  - "+ Connect Google Account"
  - Next
- **Calendar picker:**
  - grouped by account
  - the calendar's colour fills the check circle, so the colour is the checkbox
  - rows tagged "Shared" or "Read-only"
  - owned calendars start on; shared ones and holidays start off
  - a separate "New events go to" picker
- **One permission-priming template**, asked in context:
  - notifications after the first alarm is set
  - Health on first opening Workouts
  - location when travel or weather is turned on (with an approximate option)
  - the microphone on the first voice note
- Skipping records **deferred**, not **denied**. If the system already says denied, the main
  button becomes "Open Settings".
- Unfinished setup becomes a dismissible "Finish setup · 2 of 5" card on Today.
- A Connected Accounts screen:
  - one card per account, with a status dot and toggles for Calendar and busy blocks
  - Resync and Remove in a ••• menu
  - removal last, in red, with a caption saying what it removes
- Mac: one centred setup window of connection cards.

**Reserved now:**
- `StatusDot` and `ConnectionStatus` for account and sync state.
- The permission template in "Permissions".
- The deferred-versus-denied rule: `OnboardingStore` will need a *deferred* state per
  permission when this is built.

## Podcasts

**Built 27 Sep 2026.** The episode row is: date line ("Yesterday") · semibold title · a play
capsule carrying the state, with progress inline and the time left ("▶ ━━ 20m left", "Played").
It's accent when loaded and quiet otherwise.

Still future: the three-zone player, the menus, the queue and transcript, and the rest below.


- **Three-zone player; the transport never moves.** From top to bottom:
  1. Artwork, about 45% of the height, on a wash of the artwork's colour.
  2. Date line, title, and the show name in the artwork's tint.
  3. Scrubber: elapsed on the left, −remaining on the right.
  4. Transport: speed, −15, a 64-pt play, +30, sleep.
  5. Three glyphs: transcript, output device, queue.
- The queue, transcript and chapters open **inside the artwork zone**; the art shrinks to a
  56-pt header row.
- Speed and sleep are small menus anchored to their buttons. "When episode ends" comes first,
  and an active timer counts down on the moon.
- **One episode row everywhere**, from top to bottom:
  1. Date line
  2. Title (2 lines)
  3. Description (2 lines)
  4. Footer: the **progress capsule** (▶ with an inline bar and the time left), a quiet
     download glyph, and ⋯
- The download button has three states in place: arrow → progress ring → done.
- Ads and chapters appear on the scrubber. Chapters are gaps between segments; ads are
  `danger` at `Tint.fill`. Ads are also listed as rows.
- Transcript: the current paragraph at full opacity and the rest at about 40%, plus a "Back to
  current" capsule and a Search capsule.
- **Mini player:** a capsule with 40-pt art, the title, play/pause, +30 and a thin progress line.
  It has a real "Not Playing" state.
- **Show page:** a single "Play Latest" button that turns into Pause, and episodes grouped
  under date headers with muted counts.
- Mac: sidebar, content, and a full-width player bar along the bottom. Episode pages have
  Description | Transcript tabs.

**Reserved now:**
- Artwork radii follow size tiers with a hairline ✓ (`DS.artworkRadius`).
- Orange is only for the primary action and the current item.
- The artwork-derived tint is used only for the player background and the show name.
- The progress-capsule pattern in "Rows".
- Tabular digits for every time.

## Nutrition

- Macro hues on every surface ✓: protein pink, carbs teal, fat purple. Calories have no hue of their own: primary as a number, accent when drawn as a ring.
- The hero number in heavy tabular digits, and the goal as "/ 2,041" in tertiary.
- An Eaten / Left toggle that is remembered.
- **The day as a timeline:** a time gutter set in the calendar's gutter type, a subtotal per
  meal, and compact rows reading "kcal · P · C · F · serving".
- **Portion editor:**
  - a keypad and unit chips
  - the gram equivalent always shown
  - live "impact on targets" rings
  - a warning for an implausible portion (over 3× typical, or over 2,000 kcal)
- **Goals have a direction** (minimum, maximum or range). A band at `Tint.subtle` marks the
  target. `danger` appears only when a limit is exceeded, never for beating a target you want
  to exceed.
- AI results:
  - itemised ingredients with an "AI" badge
  - Fix next to Done, and a thumbs rating
  - analysis runs in the background as a feed card
- Every save shows a toast with Undo. Barcode scans have a "not found" path.
- Re-log from Recent / Frequent / Saved; multi-select copies to now, today or tomorrow.
- Supplements are a dose checklist grouped by time, with Taken / Skipped, "Took all" and an
  As-needed section.

**Built 27 Sep 2026 — Nutrition on the Mac:**
- Meals, supplements and doses sync phone↔Mac through iCloud (`CloudWellnessSync`, zone
  "Wellness"): one record per meal, per supplement, and per supplement per day; the newest edit
  wins; only an explicit delete removes anything.
- The Mac page: the day's calories and macros, the last seven days as a strip with each day's
  total, a one-line "What did you eat?" that opens the phone's review sheet, meals by part of the
  day (click to edit, right-click to delete with Undo), and the day's doses to tick off.
- Photo and barcode logging, and editing supplement schedules, stay on the phone. Supplement
  reminders ring on the phone and Watch only.
- Shared pieces: `MacroTile`, `MealRowLabel`, `NutritionText.mealTitle`.

**Reserved now:**
- `StatValue` with the goal in `footnote` ✓.
- `ToastCenter` ✓.
- The goal-direction rule.
- The Nutrition timeline reuses `DS.Typeface.gutter`, so its time column matches the planner's.

## Sleep

**Built 29 Sep 2026:**
- Nights and wake-ups from the Watch's sleep stages and steps (`SleepNights`): each stretch awake
  in the night, how long, how many steps. The phone works them out from Health; they sync to the
  Mac inside the health snapshot (`HealthTrends.nights`).
- What each wake-up was is decided where it's shown (`SleepNights.classified`): your labels first
  (synced in settings, 60 days), then what they teach (nearest labelled kind by length and steps),
  then defaults — few steps: awake in bed; short and few steps: bathroom; longer: baby when
  "Baby duty at night" is on, else up for a while.
- Kinds are data (`NightWakeKind`, unknown values decode as "up for a while"), so Feeding versus
  Settling is a new case, not a redesign.
- Where it shows: Sleep page (phone: Workouts tab row, Today's morning card, the morning summary;
  Mac: Sleep in the sidebar), with last night's wake-ups (tap to relabel), the week, two-week
  averages and earlier nights.

**Next:** feeding versus settling once the baby is here; evening drinks from Nutrition beside
bathroom trips; a HomeKit bathroom motion sensor as certainty where there is one.

## Workouts

- **One stat style** ✓ `StatValue`; `WorkoutMetricTile` migrates to it.
- Sticky week or month headers: range on the left, totals on the right.
- Row: a 40-pt glyph tile ✓, a title, the meta "Tue 07:50 · Place", and one hero metric.
- A week dot strip at the top of history.
- **Detail order:**
  1. Map, or an icon header when indoors
  2. Title and meta
  3. Highlight card
  4. Stat grid (2×3)
  5. Heart rate and zones
  6. Pace
  7. Splits
  8. Elevation
  9. Notes and device
  10. Trim and Share
- **Map:** a muted style, a 4-pt route coloured by pace or zone, start and finish markers, and
  km pills.
- **Charts:** no vertical grid, 2–3 hairlines at `Tint.subtle`, min and max labelled on the right
  only, a dashed average line, and a scrubber pill. The pace axis is inverted, so faster is
  higher.
- **Zones:** one 5-stop ramp shared by charts, the route and the bars, running blue → cyan →
  green → yellow → red. Red, not orange, at the top: the accent never judges effort.
- Splits as proportional capsule bars, with the fastest in `success`.
- Swim header: "25 yd pool · 40 lengths".
- A delta chip under each stat, comparing against the 30-day average for the same type.
- Post-workout story pages (summary → laps → personal records), then a one-tap effort rating.
- Share cards, and a trim modal that leaves a "Trimmed · Restore" banner.
- Trends: metric tiles drive one chart. Mac: list plus a two-column detail with a sticky map.

**Settled 27 Sep 2026:**
- `WorkoutMetricTile` is drawn by `StatValue`. The unit is split off the formatted value and drawn
  smaller, and the label sits above.
- The card radius is `Radius.card`.
- `bad` is `danger` and `good` is `success`.
- Section labels are sentence case.
- The placeholder is "—".

## Workout data follow-ups

- Settings › Apple Health › Workout cleanup: run on the phone on 27 Sep. Check the result
  when the phone is next reachable.
- Correct the pool length for a single workout from its detail screen, not only in bulk.
- Show merged sources on the detail meta line ("Watch + Strava").
- Show a "Trimmed · Restore" banner on trimmed workouts.

## Navigation and state

Already restored after a trip to the background:
- the tab
- the open note
- the open podcast
- Food / Taken
- the Workouts stack: a workout, Guided plans, a plan, and a guided workout in progress (its
  timers run on the wall clock and survive the phone being locked)

Not yet restored:
- open sheets (Now Playing, editors)
- the Mac section after the app is quit and reopened

**Reserved now:** the rule in "Navigation and state". Every new push is value-based, and its
path lives in `ShellNavigation`.
