# Alarms, podcasts, and fitness

These are the original developer notes from when Banana was an alarm clock with a
podcast player, before Plan, Nutrition, and the rest were built on top of it. They
moved out of the top-level README so that file can describe the whole app instead of
just this corner of it. The build steps in the main README still apply to all of this.

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
