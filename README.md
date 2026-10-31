# Banana

Banana brings your calendar, reminders, routines, meals, workouts, sleep, weather,
podcasts, and music into one calm daily plan across iPhone, iPad, Apple Watch, and Mac.

- **Plan:** Google Calendar, Apple Reminders, routines, weather and travel time on one
  timeline, by day or by week. Alarms use Apple's **AlarmKit**, so they ring through
  silent mode and Focus, even when the app is closed.
- **Nutrition:** meals from a photo, a barcode, a sentence or a search of the bundled
  USDA food database, with supplements and medication ticked off beside them.
- **Listen:** a podcast player with downloads, on-device transcripts and voice notes,
  and Apple Music as a wake source.
- **Move and sleep:** workouts recorded on Apple Watch, Apple Health trends, and each
  night's sleep.

The public beta is on TestFlight: https://testflight.apple.com/join/47yxmU8U

## Building it yourself

Banana's native clients and shared code are licensed under **GPL-3.0-only** ([LICENSE](LICENSE)).
The cloud service and browser app are licensed under **AGPL-3.0-only**
([Service/LICENSE](Service/LICENSE)). See [LICENSING.md](LICENSING.md) for the path-level
scope, third-party exceptions, and the separate treatment of the name and artwork.
Dependencies and data retain their own terms, recorded in [NOTICE.md](NOTICE.md).

Official App Store and TestFlight distribution permissions are a separate publication
review item; the public source licenses alone do not establish those permissions.
See [the publication checklist](docs/publication/readiness.md).

Pull requests aren't being taken for now.

```sh
brew install xcodegen
xcodegen generate        # writes Banana.xcodeproj from project.yml
mkdir -p Banana.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
cp Config/Package.resolved Banana.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
open Banana.xcodeproj    # scheme Banana, any iPhone simulator
```

`Config/Package.resolved` preserves the reviewed direct and transitive package
revisions outside the generated project. Copy it again after regenerating the project;
review dependency upgrades and refresh notices together.

That is enough for a simulator. The build uses the stand-in names in `Config/Base.xcconfig`:
it runs on sample or local data, with iCloud sync and Google sign-in switched off, because
both belong to whoever signs the app.

Use **Try with sample data** on the welcome screen to explore the native demo
without Google credentials or personal data. The cloud service has its own
[setup and test instructions](Service/README.md).

For your own devices, copy `Config/Local.example.xcconfig` to `Config/Local.xcconfig`
(not tracked) and give it:

- **Your Apple developer team and a bundle id prefix you own.** The app uses iCloud,
  HealthKit, WeatherKit, time-sensitive notifications and push, so it needs a paid developer
  account; a free one cannot sign those.
- **An iCloud container**, `iCloud.<your bundle id>` unless you name another, created under
  your team. Devices signed by you sync with each other through it, and with nobody else.
- **A Google OAuth client id** of type iOS for your bundle id, if you want Google Calendar.
  Without one the app has no Google sign-in.

`tools/ios-install.sh` and `tools/mac-install.sh` build Release and install over the app on
a device; they stop when there is no `Config/Local.xcconfig`. `tools/ui-tests.sh` runs the
UI tests in a simulator with or without one.

The sections below are the original developer notes, from when Banana was an alarm clock
with a podcast player. The build steps still apply; the feature notes cover only that part
of today's app.

## Requirements

- Xcode 27.1 (validated for this source snapshot) and an Apple silicon Mac. Native Mac builds target arm64 only.
- An iPhone or iPad running **iOS 26.1 or later**.
- **The watchOS platform installed in Xcode** (Settings → Components → watchOS). The app
  embeds a Watch app, so the whole project won't build without it.
- An **Apple Watch** to record/test fitness data (HealthKit workouts, motion, GPS don't
  work in the Simulator).
- A physical iPhone to test ringing (alarms don't fire in the Simulator).
- Optional: an **Apple Music subscription** for the Apple Music wake source, with
  **MusicKit enabled** for the App ID (see Apple Music section).

## Build & run on your iPhone

1. Regenerate the Xcode project (only needed if you change `project.yml`):
   ```sh
   xcodegen generate
   ```
2. Open it:
   ```sh
   open Banana.xcodeproj
   ```
3. Set signing: select the **Banana** target → *Signing & Capabilities* → pick your
   Apple ID team. Do the same for the **BananaWidgetExtension** target. The full app capabilities require a paid
   Apple developer account; see the configuration steps above.
4. Plug in your iPhone, select it as the run destination, and press ▶.
5. First launch: tap **"Allow alarms to wake you"** and grant the permission.
6. Toggle on a few times and lock the phone to test.

## The alarm tone

The alarm always rings the **default AlarmKit tone** — the reliable, system-owned
wake sound. There's no tone menu: Apple's built-in ringtones aren't available to
third-party apps, and personalization is handled by the **wake source** (below)
instead.

## Wake source — what plays after the alarm

Tap the orange **"Wakes you with"** row at the top of the Alarms tab to choose what
plays *after* the tone wakes you and you open the app:

- **None** — just the alarm tone.
- **A podcast** — the next episode of a subscribed show (see Podcasts).
- **Apple Music** — a playlist, album, or song from your library.

**Why "after you open the app":** AlarmKit rings the tone to wake you reliably
(system-owned, works through silent mode with the app closed). iOS does not allow a
third-party app to auto-start streaming audio from a fully-closed state, so the tone
is the wake and the podcast/music is the follow-on that starts when the app becomes
active. No keep-alive hacks, no battery drain.

## Podcasts

- **Podcasts tab** → **+** → **search any show by name** (powered by the iTunes
  podcast directory — no feed URL required). Pasting a raw RSS URL still works as a fallback.
- Open a show to configure:
  - **Play order** — *Newest first* (news/daily shows) or *Oldest first* (serialized seasons).
  - **Speed** — 0.8×–3×, with pitch correction (`AVAudioTimePitchAlgorithm.timeDomain`)
    so it doesn't sound distorted. Set per feed; also adjustable live from the mini-player.
  - **Wake-up podcast** — make this show the wake source.
  - **Auto-download** — Off / Latest 1 / 3 / 5. Downloaded episodes play offline and
    start instantly. Swipe any episode to download/delete manually.
  - **Sync to Apple Watch** — pushes this feed's downloaded episodes to the Watch.
- Episodes stream via `AVPlayer` (or play from the local download) with background audio
  + Lock Screen controls; resume positions and "played" state are tracked per episode.

Podcast audio is open RSS/MP3, so this is all first-party and license-clean —
unlike Spotify or Apple Podcasts, which expose no playback API.

## Apple Music (wake source)

Choose a playlist, album, or song from your Apple Music **library** as the wake
source. This uses **MusicKit** and has extra requirements:

- **An active Apple Music subscription** (needed to play).
- **Device only** — MusicKit doesn't work in the Simulator.
- **MusicKit must be enabled for the App ID.** In the Apple Developer portal, under
  your app identifier → *App Services*, enable **MusicKit** (Xcode's automatic signing
  usually handles this once you run on device). Without it, authorization/playback fail.

Apple Music **cannot** be the alarm ring itself (that's a first-party Clock privilege) —
it plays as wake content when the app opens after the alarm, exactly like podcasts.

## Fitness (Apple Watch)

The **Watch app** is a fitness data recorder. Start a workout on the watch and it
collects, via a real `HKWorkoutSession`:

- **Heart rate, active energy, distance** (HealthKit live workout builder)
- **Raw accelerometer + gyroscope** at 25 Hz (CoreMotion)
- **GPS** location + speed (CoreLocation)

Everything is saved to **Apple Health** *and* buffered into a local `FitnessSession`
(raw samples). When the session ends, it's transferred to the iPhone over
**WatchConnectivity**, where the **Fitness tab** lists each workout with a summary and
a heart-rate chart, plus per-signal sample counts.

The Watch app has two screens (swipe up/down): **Workout** (record/data) and
**Podcasts** (episodes synced from the phone, played offline via `AVAudioPlayer` to
Bluetooth headphones). Episodes get there by enabling "Sync to Apple Watch" on a feed
and downloading them on the phone; WatchConnectivity transfers the files.

Setup / caveats:
- Grant **Health**, **Motion**, and **Location** permissions on the watch on first run.
- The Watch app needs the **HealthKit** capability (already in `BananaWatch.entitlements`)
  and the `workout-processing` background mode (in its Info.plist).
- **Device-only** — none of this runs in the Simulator.
- WatchConnectivity transfers are opportunistic (they complete in the background), so a
  finished workout may take a moment to appear on the phone.

## Good to know

- **Alarm limit.** iOS caps how many alarms can be scheduled at once (the built-in
  Clock has limits too). If you turn on more than the system allows, the toggle
  reverts and you'll see *"iOS won't allow any more scheduled alarms."* Turn some off.
  In practice you'll have a handful on, not all 96.
- **Each alarm's label is its time** (e.g. "6:15 AM"), shown on the Lock Screen banner.
- Toggles persist across relaunches; the alarms themselves are stored by the system.

## Project layout

```
project.yml                       xcodegen project definition (2 targets)
Shared/AlarmShared.swift          AlarmMetadata + shared AlarmAttributes type
Banana/
  BananaApp.swift               app entry — injects the stores
  Info.plist                      usage strings, background audio, ATS
  Model/TimeSlot.swift            the 96-slot grid + time formatting
  Model/AlarmStore.swift          schedules/cancels AlarmKit alarms, auth, alerting state
  Model/Podcast.swift             Podcast/Episode/PlayDirection + ordering & next-episode logic
  Model/FeedParser.swift          XMLParser-based RSS reader
  Model/PodcastSearch.swift       iTunes directory search → RSS feed URLs
  Model/PodcastLibrary.swift      subscriptions, refresh, progress, persistence
  Model/PlayerController.swift    AVPlayer: background audio, lock screen, speed, next-episode
  Model/WakeStore.swift           the unified wake source (podcast OR Apple Music item)
  Model/MusicController.swift     MusicKit: auth, library browse, wake playback
  Views/RootView.swift            gate + tab shell + mini-player + alarm→wake hook
  Views/ContentView.swift         the scrollable 24h list + wake-source row
  Views/SlotRow.swift             one time row + toggle
  Views/PodcastsView.swift        podcast list + search-to-subscribe sheet
  Views/PodcastDetailView.swift   direction, speed, wake toggle, episode list
  Views/WakeSourceView.swift      choose None / podcast / Apple Music item
  Views/NowPlayingBar.swift       mini-player with speed + transport
BananaWidget/                   Live Activity for the ringing-alarm presentation
```

## UI performance requirements

The [UI performance contract](docs/performance/ui-performance-contract.md) defines the required
8.3 ms frame budget, direct-manipulation latency, 32–50 ms UI response goals, and strict 100 ms
ceiling, including caching, preloading, and durable optimistic-action requirements.

Performance changes must follow the [persistent regression testing protocol](docs/performance/regression-testing.md).
