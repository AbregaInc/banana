# App Review reply for 1.0 (83): draft, not sent

The owner has to approve this before anything goes to Apple. Apple reviewed the iOS build on
5 Nov 2026 on an iPhone 17 Pro Max and found five issues. Four of them are features the reviewer
never reached. The welcome screen's module chooser starts on **Plan** alone, so a reviewer who
taps straight through never turns on Podcasts or Workouts and sleep. Without those, the app
shows no audio, no listening route and no Apple Health.

The plan is one reply in App Store Connect, one screen recording from a physical iPhone attached
to it and also put in **App Review Information › Notes**, then **Resubmit to App Review**. A reply
alone leaves the submission in Unresolved Issues.

## Reply (paste into App Store Connect)

> Thank you for the review. Several of the features below are in optional modules. The welcome
> screen asks "What should Banana look after?" and starts with Plan alone. To see everything,
> choose **Everything** there, or later turn modules on in **Settings › Modules**. The attached
> screen recording was made on a physical iPhone and shows each item below. The timestamps are
> in brackets.
>
> **Guideline 4.8 (Login Services).** Banana has no sign-in of its own. "Continue with Google"
> connects the person's Google Calendar. Banana is a Google Calendar client: the meetings,
> calendars and free time it shows and edits are the person's own Google Calendar content, read
> and written through the Google Calendar API under their Google sign-in. This is the exemption
> in 4.8 for "a client for a specific third-party service" where "users are required to sign in
> to their … third-party account directly to access their content." The step can be skipped with
> "Not now", and reminders, routines, workouts, food, notes and podcasts all work without signing
> in to anything. Banana stores a record keyed to the connected Google account only to forward
> Google Calendar change notifications to the person's devices. It can be deleted in
> Settings › Accounts & calendars. [0:00]
>
> **Guideline 2.5.4 (audio).** Banana includes a podcast player (Podcasts module). Episodes keep
> playing in the background and on the Lock Screen, with Now Playing controls. To try it, turn
> on Podcasts in Settings › Modules, open Podcasts, search for a show ("Search podcasts, or paste
> an RSS URL"), play an episode and go to the Home Screen. [1:40, Home Screen at 3:00]
>
> **Guideline 2.5.4 (location).** "Record where I listen" (Settings › Podcasts) is an opt-in
> that records a low-frequency route while an episode is playing, including after the person
> leaves Banana, and stops the moment playback pauses. The routes appear on the Listening map
> (Library › chart button › Listening › Open full map). iOS shows the location indicator in the
> Dynamic Island while it records. The recording's movement was simulated with Xcode's location
> simulation on the physical iPhone, so it could be filmed indoors. [4:26]
>
> **Guideline 5.2.5 (WeatherKit).** The forecast uses WeatherKit. It appears as the temperature
> beside the date in Plan. Tapping it opens the full forecast, which ends with the Apple Weather
> mark ( Weather) and the "Other data sources" link to Apple's legal attribution page. [3:48]
>
> **Guideline 2.5.1 (HealthKit).** Banana reads workouts, heart rate and sleep from Apple Health
> and saves Apple Watch workouts recorded in Banana to Apple Health. In the app it is named
> Apple Health everywhere it appears: the "Apple Health" setup page and its "Connect Apple
> Health" button on the first run, the Workouts tab's "Connect Apple Health" button,
> Settings › Apple Health (read and write access, workout cleanup), and the Apple Health status
> line in Settings. Turn on **Workouts and sleep** in Settings › Modules to see them. [0:38, workouts at 3:59]

Fill in the timestamps after the recording is made. Check the wording against the build being
resubmitted: if a new build changes a screen, the reply has to match it.

## The recording (owner, physical iPhone)

Use iOS Screen Recording from Control Center on a phone with Banana from the App Store build
(TestFlight 83, Release). Keep it under 4 minutes, with no sound needed. Use the review Google
account, not a personal one. Leave the status bar visible, because it shows the location
indicator and Now Playing. One take per item is fine. Apple asked for each item on a physical
device, so do not use the Simulator.

1. **Fresh install, welcome.** Show "What should Banana look after?", choose Everything, then
   go through the Google Calendar page to "Continue with Google". Sign in with the review
   account and show the calendar loading. Go back once to show "Not now" on that page.
2. **Apple Health.** On the "Apple Health" setup page, tap "Connect Apple Health" and show
   the system Health sheet. Open the Workouts tab with its workouts, then Settings › Apple
   Health.
3. **Weather.** In Plan, tap the temperature beside the date. Scroll the forecast to the end,
   show the  Weather mark, tap "Other data sources" and show Apple's page open.
4. **Podcasts in the background.** Settings › Modules (Podcasts on). Open Podcasts, search,
   play an episode, go to the Home Screen with the audio still playing, lock the phone and show
   the Lock Screen player.
Upload the file where App Review can open it (the reply accepts attachments; also add a link in
Notes for future submissions).

## Notes field (App Review Information), for this and later submissions

> Optional modules: on the welcome screen choose "Everything", or turn modules on later in
> Settings › Modules. Google sign-in only connects the person's Google Calendar (4.8 exemption
> for third-party service clients) and can be skipped. Background audio: the podcast player
> (Podcasts). Weather: tap the temperature in Plan; the mark and legal link are at the end of
> the forecast. Background location: "Record where I listen" (Settings › Podcasts), only while an
> episode plays. Apple Health: the Workouts and sleep module, Settings › Apple Health. A screen
> recording of each: <link>.

## If 4.8 comes back again

Then the exemption was not accepted, and Banana needs Sign in with Apple as an equal first-run
option: the Service has to verify Apple identity tokens, an account must be able to exist
without Google, and Google becomes "connect a calendar" after sign-in. That is a new build plus a
Service deploy, so it waits for the owner's decision.
