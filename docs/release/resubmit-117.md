# Resubmitting 1.0 as the calendar-only app (build 117)

Prepared 9 Nov 2026. Nothing here has been sent to Apple: no upload, no App Store Connect write,
no reply, no submission. The owner runs every write. The reviewer's Google account stays only in
App Store Connect's private Sign-In Information; it is never written here or in a tool.

## Where things stand (read-only check, 9 Nov 2026)

| | iOS 1.0 | Mac 1.0 |
|---|---|---|
| Version state | Prepare for Submission, manual release | Prepare for Submission, manual release |
| Build selected | 116 (full app) | 116 (full app) |
| Review submission | Unresolved Issues, item Rejected (submitted 31 Oct) | Unresolved Issues, item Rejected (submitted 31 Oct) |
| Rejected for | 4.8, 2.5.4 audio, 2.5.4 location, 5.2.5, 2.5.1 | 2.4.5 (network.server entitlement) |
| Sign-in required / demo account | Yes, name and password set | Yes, name and password set |
| Notes | Full app's "REVIEW ITEMS" text (3990 chars) | Full app's text (3737 chars) |
| Description, keywords, promo | Full app's (3087 / 100 / 150 chars) | Same |
| What's New | Empty (first version: not editable) | Empty |
| Screenshots | iPhone 6.9" 9 (Workouts, Food, Podcasts…), iPad 13" 6, Watch 3, product page header 1, search result 1 | Mac 5 (Nutrition, Sleep, Library…) |
| Name / subtitle | Banana: Daily Planner / Many calendars. One you. | (app-wide) |
| Categories | Productivity, secondary Health & Fitness | (app-wide) |
| Age rating | 12+ (Health or Wellness Topics: yes; Medical Information: infrequent) | (app-wide) |

Every listing field still describes the full app. The calendar-only text is in
`tools/app-store/metadata/calendar-only/en-US/`, the images in `AppStore/Generated/calendar-only/`.

## Order of work

Each write tool is dry by default and writes its plan to `--out`. Run the dry form, read the
diff, then the same command with `--apply`.

1. **Upload 117.** After Stable 118 is done, from a checkout that holds this branch's commits
   (the App Store privacy manifest and the calendar-only text fixes are on
   `release/resubmit-117`; merge or cherry-pick them into the release branch first):
   ```
   tools/testflight.sh ios 117 prepare appstore
   tools/testflight.sh mac 117 prepare appstore
   tools/testflight.sh ios 117 upload appstore
   tools/testflight.sh mac 117 upload appstore
   python3 tools/asc-builds.py          # wait for both 1.0 (117) to be VALID
   ```
   The archive step runs `tools/check-release.sh`, which now also refuses an App Store archive
   whose privacy manifest declares Health, Fitness, Photos, Audio or Search History.
2. **Select 117 on both drafts.**
   ```
   python3 tools/asc-submit.py 117 --attach
   python3 tools/asc-submit.py 117 --attach --apply
   ```
3. **Text and Notes** (description, keywords, promotional text, URLs, copyright, subtitle, App
   Review Notes; never the sign-in fields):
   ```
   python3 tools/app-store/update-draft.py --flavour calendar-only --review-notes --out <new folder>
   python3 tools/app-store/update-draft.py --flavour calendar-only --review-notes --out <another new folder> --apply
   ```
4. **Screenshots**: replaces iPhone, iPad and Mac sets and the header and search images, and
   clears the Watch set:
   ```
   python3 tools/app-store/upload-assets.py --flavour calendar-only --creative --out <folder>
   python3 tools/app-store/upload-assets.py --flavour calendar-only --creative --out <folder> --apply --place
   ```
5. **The owner's web steps** below (App Privacy, category, age rating, replies).
6. **Resubmit**: marks each rejected item resolved and submits the same submission again:
   ```
   python3 tools/asc-submit.py 117
   python3 tools/asc-submit.py 117 --apply
   ```
   If Apple refuses the API resubmission, use App Review › the submission › **Resubmit to App
   Review** in the web, which does the same.

## App Review Notes (the version's Notes field)

The text is `tools/app-store/metadata/calendar-only/en-US/review_notes.txt` (about 3,000 of the
4,000 characters); step 3 sends it to both versions.

## Resolution Center replies

A reply alone does not re-queue a submission; post it, then resubmit (step 6).

### iOS

> Thank you for the review. We have changed the app rather than argue the points. Build 117 is
> the calendar alone: Google Calendar, Apple Reminders, routines, alarms, weather and travel time.
>
> - 2.5.4 (audio, location): the podcast player and every background location use are gone. The
>   app declares no audio or location background mode, and asks for location only while in use.
> - 2.5.1 (HealthKit): there is no HealthKit in this build: no entitlement, usage strings or
>   Health features.
> - 5.2.5 (WeatherKit): in Plan, tap the temperature beside the date. The forecast ends with the
>   Apple Weather mark and the "Other data sources" link to Apple's legal attribution.
> - 4.8 (Login Services): Banana is a Google Calendar client, and Google's own sign-in is the
>   only one it has. It gives Banana access to the person's own Google calendars, which it shows
>   and edits through the Google Calendar API. Booking works the same way: the booking page offers
>   only the times free on that Google Calendar and writes each booking into it, so it cannot
>   work without Google. Banana has no account, username or password of its own, so we ask that
>   the exception for clients of a specific third-party service apply. Google can be skipped with
>   "Not now".
>
> The Notes also have a sample workspace that needs no sign-in.

### Mac

> Thank you for the review. Build 117 removes the com.apple.security.network.server entitlement,
> along with the podcast feature that used it, and the Bonjour and local network keys. The Mac
> app now only makes outgoing connections. This build is the calendar alone; the App Review Notes
> explain how to try it, with or without signing in.

## The owner's web steps (App Store Connect)

The API can't do App Privacy or Resolution Center replies. It can do categories and age rating
(`appInfos` and `ageRatingDeclarations`), but these are one-time edits, so the web is quicker.

1. **App Privacy.** Apps › Banana › App Privacy › Data Types › **Edit**, then follow
   `tools/app-store/metadata/calendar-only/app-privacy-changes.md`:
   - Untick **Health**, **Fitness**, **Photos or Videos**, **Audio Data** and **Search History**,
     then Save.
   - **Product Interaction** › Edit › untick **App Functionality**; keep Analytics. Save.
   - Leave every other type as it is. Tracking stays No.
   - Click **Publish** at the top right. Until it is published, the label still shows the old
     answers.
2. **Secondary category.** App Information › Category › Secondary: change **Health & Fitness** to
   **None** (or Business). Save.
3. **Age rating.** App Information › Age Rating › Edit:
   - **Health or Wellness Topics**: No.
   - **Medical or Treatment Information**: None.
   - Leave the rest. The rating should drop from 12+; check the result and Save.
4. **Sign-In Information.** On each version, check that the review Google account still signs in
   from a new device without a phone prompt. Google's "verify it's you" challenge is a common
   reason a reviewer cannot get in. Leave the fields as they are.
5. **Agreements.** Business › Agreements: the Free Apps agreement is active. The API answered
   today and build 118 uploaded, so nothing is pending. Look only if an upload is refused.
6. **Replies.** App Review › Unresolved Issues › each platform's submission › reply with the text
   above.
7. **Resubmit.** Use step 6 of the order of work, or **Resubmit to App Review** on each
   submission. iOS and Mac are separate submissions.

## Before resubmitting: checks against build 117 itself

- Install 117 from TestFlight on a phone. Walk the welcome screen and the "Not now" path. Open the
  forecast and check the  Weather mark and link. Open Settings and confirm it shows nothing of
  Health, Workouts, Food, Podcasts or the Watch.
- Unzip the uploaded archive's app and run `python3 tools/modules/modules.py check <app>`. It
  reports any key, entitlement or privacy type of a left-out module.

## Risks

Fixed on this branch:

- **Privacy manifest declared the full app** (Health, Fitness, Photos or Videos, Audio Data,
  Search History, Product Interaction for App Functionality). Now `modules.py` derives the App
  Store manifest from `Config/Modules.json` "privacy". The AppStore build bundles it, and
  `check-release.sh` refuses an archive that declares a left-out module's data
  (`tools/tests/test_modules_privacy.py`).
- **Health showed in Settings** (2.5.1 again, or 2.3). The "Sync Health" switch (Settings ›
  Accounts & calendars, signed in) and the iCloud Sync rows "Workouts & Health", "Meals &
  supplements", "Listening progress" and "Meals to log" showed in a build with none of those
  modules. Now they show only when the build carries a module that has that data, and the Health
  consent is never asked for without one (`ModuleSyncScopeTests`).
- **Wording for missing features**: the notification primer said "A supplement or reminder
  that's due", and the demo menu mentioned Apple Health. Both now follow the modules.
- **"Connecting only reads your calendars."** on the calendar step was untrue: Banana asks for
  `calendar.events` and edits events. Google's consent screen beside it says so. The line is gone.

Not fixed in code (for the owner to decide):

- **4.8 is still the main risk.** The exception covers a client that needs the third-party
  sign-in "to access their content". Banana's Google sign-in also creates a Banana account that
  hosts Booking pages, relays push and syncs between devices, and the app offers "Delete
  account". That is a primary account set up through a third-party login, which is what 4.8
  requires an equivalent option for. Booking weakens the exemption the most: it is a Banana-hosted
  service, not Google content. The Notes say this openly rather than have the reviewer find it.
  If 4.8 comes back, the fix is Sign in with Apple as an equal first option (Service verifies
  Apple identity tokens, an account can exist without Google, and Google becomes "connect a
  calendar"). Sign in with Apple isn't in the code at all. A cheaper fallback: ship 1.0 without
  Booking and without the Banana account, so the app is a pure Google Calendar client. That is a
  module-style switch plus a build.
- **5.2.5, the temperature chip.** The chip (symbol and temperature) in Plan and the Mac toolbar,
  and the leave-by notification's rain line, show WeatherKit data without the mark. The mark and
  link are one tap away, at the end of the forecast, and in Credits. Apple's rule is to "clearly
  display" them, not on every view, but this rejection was 5.2.5. Recording the tap path for the
  reply lowers the risk. A small " Weather" in the chip's context menu or under the chip would
  remove it; that is a design call.
- **2.1 (completeness) and the review account.** The live path depends on the reviewer's Google
  account signing in from Apple's device. A Google security challenge reads as "can't sign in".
  The sample workspace and "Not now" give a full path without it, and the Notes lead with both.
- **4.2 (minimum functionality).** Low risk: native Day/Week, quick add, routines, AlarmKit
  alarms, weather and travel time, booking, widgets, and iPhone, iPad and Mac versions.
- **5.1.1(v) account deletion.** Present: Settings › Accounts & calendars › Delete account,
  confirmed with a fresh Google sign-in, and shown while signed in even with no calendar
  connected. The Notes name the path.
- **Location purpose string.** "Banana uses your location for forecasts and travel estimates."
  (iOS) and "…for your local forecast." (Mac). When In Use only, and specific enough. Trip
  learning (Always and Motion) and the podcast route recorder are compiled out of this build,
  not merely left unasked.
- **Entitlements.** AlarmKit (`NSAlarmKitUsageDescription`), Live Activities, time-sensitive
  notifications and WeatherKit are all used by Plan. There is no App Group. The iOS entitlements
  file says `aps-environment: development`; the App Store export re-signs it as production.
  Check this in the exported IPA (`codesign -d --entitlements -`).
- **Leftovers that don't block review.** Settings › About › Credits still lists the food and
  medication databases (Open Food Facts, DSLD, RxNorm), and Settings search keywords mention
  food and podcasts (hidden). Neither is a feature claim.
- **"Search or ask" with nothing to ask.** The App Store build has no assistant
  (`BANANA_LOCAL_AI` is NO, so `ShellAssistant.isAvailable` is false). The field still says
  "Search or ask", as Stable's does, and the header image shows it. This is low risk (2.3
  accuracy at most). Saying "Search" when there is no assistant would be a one-line change in
  `ShellField` and `WideShell`, but it touches the approved bottom bar, so it is left as it is.
