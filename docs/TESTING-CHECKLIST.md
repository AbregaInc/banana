# Banana — On-Device Testing Checklist

Follow this when you're back at the Mac with the phone reachable (USB, or same
physical Wi-Fi — **not** Tailscale; see "Installing" below). Everything here is
either device-only or worth confirming on real data. Sim-verifiable items are
marked ✅ (already checked) so you can skip them unless something looks off.

---

## 0. Installing the staged build

A signed device build is already built at:

    build/device/Build/Products/Debug-iphoneos/Banana.app

**Tailscale can't install it** — Apple's install needs a live USB or local-network
(Bonjour/mDNS) tunnel, which Tailscale doesn't carry. So either:

- **USB:** plug the phone into the Mac, then run:

      xcrun devicectl device install app \
        --device F0E8AAC8-17D1-5853-A522-7B1F3EE65646 \
        build/device/Build/Products/Debug-iphoneos/Banana.app

  (or just tell me "phone's plugged in" and I'll fire it)

- **Same LAN:** if the Mac joins home Wi-Fi directly (not via Tailscale) and the
  device has "Connect via network" enabled, the same command works wirelessly.

If the build is stale by then, rebuild first:

    xcodegen generate
    xcodebuild -project Banana.xcodeproj -scheme Banana \
      -destination 'generic/platform=iOS' -configuration Debug \
      -allowProvisioningUpdates DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM \
      -derivedDataPath build/device build

---

## 1. Health — the missing-workouts fix (MOST IMPORTANT)

Root cause was **read authorization**, not code: HealthKit returns an app's own
written data even without read access, so with Workouts read OFF you only saw
Banana-logged workouts.

1. Settings › Health › **Data Access & Devices › Banana** → under **Allow … to
   Read**, turn **Workouts** ON (also confirm Sleep, Resting HR, HRV, Respiratory,
   VO2 max, Active Energy, Distance are ON).
2. Open Banana → Workouts → **All workouts & health**.
3. ✔️ Expect: workouts from Whoop / WorkoutDoors / Apple Watch now appear — not
   just Banana-recorded ones.
4. If still missing: tap the new **"Manage Apple Health access"** row at the
   bottom of that screen (opens Settings) and re-check the Workouts toggle.

## 2. Sleep — over-count + units

Was showing 15h+ because overlapping sleep samples (Watch + phone + apps) were
summed. Now merged into a union before summing.

1. Morning Briefing / Workouts → check **"Last night"** sleep.
2. ✔️ Expect: a realistic figure (e.g. 6–9h), never 12h+. Formatted "7h 12m".
3. Workouts sleep chart → ✔️ Y-axis now labelled in hours ("7h").
4. Cross-check against Apple Health's own "Time Asleep" for the same night — they
   should be within a few minutes.

## 3. Workouts — units + the Active stat

1. ✔️ "Active" card shows **total workout minutes** (universal — works for yoga).
2. ✔️ Its subtitle shows distance in **your unit** (miles), not km. Confirm
   Settings › distance unit = Miles is respected.
3. "Workouts" count now includes Health-imported workouts, not just Banana ones.

## 4. Trends — colors

1. Workouts → All workouts & health → "Past 30 days" metric cards.
2. ✔️ VO2 max / Resting HR: a metric with a real up/down trend should show
   green (improving) or red (worsening); a genuinely *steady* metric stays gray
   by design (that's "no meaningful change", not a bug).
3. Sanity: if RHR is clearly trending but shows gray, tell me — the threshold may
   need tuning for your data.

## 5. L4 — Re-plan on real data  (sim-verified ✅, confirm on device)

Sim proved the engine (places overdue tasks around meetings, sticky, idempotent).
On device, confirm it behaves with your real Reminders + Calendar:

1. Have a couple of overdue / unscheduled Reminders and a meeting or two today.
2. Today → **"Re-plan my day"** → review the preview.
3. ✔️ Expect: overdue tasks slotted into open time around meetings, ordered by
   priority then urgency, nothing dropped.
4. Long-press a task → **"Reserve N min"** → pick a duration → Re-plan again →
   ✔️ that task now reserves the chosen length.
5. Apply, then Re-plan again → ✔️ already-placed tasks don't move (sticky).

## 6. Write-back go-live  (STILL GATED — test deliberately)

Write-back is proven in the sim sandbox but **off** on device
(`CalendarWriteBack.goLive == false`). Do NOT enable casually — it writes real
calendar events. When you want to try it:

1. Tell me and I'll wire a Settings toggle + calendar picker (currently there's no
   UI to flip it — intentional).
2. First run against a throwaway calendar; confirm blocks appear **busy** (device
   iCloud supports busy; sim showed "free" only because the sim calendar is local).
3. Confirm no duplicate events and that deleting a task removes its block.

## 7. AlarmKit wake arming  (device-only)

1. With Smart Schedule on and a plan-wake day, check Today's debug line
   "wake armed: N" (N > 0 on wake days).
2. ✔️ Expect a real alarm to fire at the computed wake time. **Keep a backup
   alarm the first night.**

## 8. WeatherKit  (waiting on entitlement propagation)

1. If the Today weather stripe is still blank, the WeatherKit entitlement may not
   have propagated. Check the "wx:" debug line on Today.
2. ✔️ On success: a broadcast-style temperature gradient with °F callouts and
   diagonal rain hatch runs down the left of the timeline. Callouts name the
   current temp (on the now line), the day's high and low at the hours they
   occur, and the rain chance at the wettest hour when it clears 40%.
3. Apple Weather is the one source. If it won't answer, the stripe keeps the last forecast
   and the `wx:` line says why.
4. ✔️ Tap the stripe anywhere: it opens the weather page **at the hour beside
   your finger** — so tapping next to a 9:30 row lands on 09:30. Check the hour
   strip, the detail tiles, and the 7-day list.
5. ✔️ The Week tab has the same stripe on every day, each tappable.
6. The stripe shares the timeline's vertical scale (rows are measured), so the
   now tick lines up with the timeline's own "Now" divider. Hours with no rows
   beside them compress — that's expected, not a bug.

## 9. Cues, templates & one-off alarms  (couldn't verify in sim — taps don't land)

The sim wouldn't take synthetic taps on the tab bar / nav buttons, so these built-but-
unverified UI flows need an eyeball on device:

1. **Blue-tint fix:** Routines → tap "Smart wake schedule", back, repeat. ✔️ The rows
   should stay their normal color (no stuck blue tint).
2. **Templates:** Routines → **+** → a picker lists any missing built-in cues to "re-add"
   (Wake/Workout/Wind down/Sleep) plus **Custom**. ✔️ Delete your Wake cue, then **+** →
   Wake should reappear as a re-add option and recreate a fully-wired Wake.
3. **Type binding:** after re-adding Wake, confirm smart-wake still arms and the wake audio
   source still resolves (it now binds by `cueType`, not trigger kind).
4. **One-off alarm:** Today → **alarm button (top-left)** → pick a time + label → "Set alarm".
   ✔️ It appears under "Scheduled"; ✔️ it actually rings at that time (AlarmKit firing is
   device-only); ✔️ swipe/trash removes it. The 15-min manual-alarm grid is gone from Routines.

## 10. Onboarding + alarms on the timeline  (partly sim-verified)

- **Onboarding** (welcome card renders ✅ in sim; paging couldn't be automated):
  fresh launch shows a paged flow — Welcome → Alarms (required) → Calendar →
  Reminders → Health → Location → Notifications → Apple Music → Done. ✔️ Each
  "Allow" triggers the real system prompt and flips to a green "Allowed". ✔️ The
  final "Start Banana" is disabled until Alarms is granted. ✔️ Re-launch skips
  onboarding; revoking Alarms in Settings brings it back.
- **One-off alarm on the timeline:** after setting a one-off alarm (Today → alarm
  button), ✔️ it appears inline on the Today timeline as an alarm row (and on
  Tomorrow if set for tomorrow), with an "Up next · alarm" card and long-press
  delete. (AlarmKit scheduling is device-only, so this can't be seen in the sim.)

## 11. Workouts — week/month/quarter/year  (week view verified in sim)

The Week view renders correctly in the sim (granularity control, period header with
chevrons, re-scoped stats, sleep chart). On device, confirm the rest:

1. Tap **Month / Quarter / Year** — ✔️ the stat grid, hero copy, and sleep chart re-scope
   to that range; the sleep chart re-buckets (week→daily, month→weekly, quarter/year→monthly).
2. **Page back**: chevrons (or swipe the period header) walk to prior periods; the right
   chevron is disabled on the current period. ✔️ Data updates per period.
3. **Quarter/Year data**: these query HealthKit on demand (not the 30-day cache), so sleep/
   recovery should populate for the whole range — confirm the long-range charts aren't empty.
4. Sanity-check totals against Apple Health / Fitness for a past month.
5. **Fitness inherits the period** (verified in sim): tap "All workouts & health" from,
   say, a Month view → ✔️ Fitness opens on that same month ("Trends · <period>" +
   "Workouts · <period>"), with its own PeriodBar to page independently and a "Show all"
   button to see the full workout log. Confirm the trend cards populate for long ranges.

## 12. Power, crash recovery, and background playback

Run this with a **Release** build and a downloaded episode. Simulator results do not validate
screen-off audio, thermal state, WatchConnectivity, or daemon-backed transfers.

### Phone — local playback soak

1. Open Settings → Playback Log and note the last line/time. It should open promptly even if the
   file is large; the screen intentionally displays only the newest 250 lines. “Copy” must still
   include older lines.
2. Start a fully downloaded episode, lock the screen, and listen for two hours. Exercise pause,
   resume, AirPods removal/reinsertion, one Siri interruption, and one notification announcement.
3. ✔️ Audio never stops without a corresponding interruption/route/error line.
4. ✔️ `⚡ POWER` appears at most once per minute and playback checkpoints at their intended cadence;
   no `🌀 STORM`, repeated feed refresh, backup, transcription, weather, or CloudKit churn occurs
   with the screen off.
5. ✔️ Physical footprint stays broadly flat. Thermal state should return to nominal/fair after any
   unrelated charging/radio load ends. Record ambient state and whether the phone is charging.
6. Pause, force-terminate the process, and relaunch. ✔️ The episode remains paused at the committed
   position; the deployment/relaunch must not auto-play.
7. During playback, terminate without pausing and relaunch. ✔️ The interrupted-playback recovery
   identifies the exact podcast/episode and loses no more than the checkpoint interval.
8. The next day, inspect Playback Log for MetricKit. ✔️ CPU-limit exits, hangs, and crashes are zero.

### Watch — observation and checkpoint

1. Open a long podcast list and play an episode. ✔️ Only the small progress ring/time changes once
   per second; scrolling and episode ordering stay smooth.
2. Leave playback running for more than 60 seconds, terminate the Watch app, and reopen it.
   ✔️ The same episode resumes within 60 seconds of the prior position.
3. Pause via Siri or remove the active audio route. ✔️ The progress ticker stops and the audio
   session releases.
4. Start/stop a workout and inspect power logs. ✔️ Indoor workouts never start GPS; outdoor
   workouts stop GPS and 25 Hz motion delivery on normal stop, system stop, and failure.

### Background download relaunch

1. Start a large episode download on the Watch, leave the app, then terminate/relaunch it while the
   transfer is in progress.
2. ✔️ The transfer is adopted rather than restarted or duplicated.
3. ✔️ Progress moves in coarse five-percent steps; completion installs one file and the episode
   becomes playable.
4. Repeat on the phone with an automatic download. ✔️ It waits for Wi-Fi. Manually override once
   on cellular and verify the warning appears, the daemon transfer survives suspension, and resume
   data avoids restarting from byte zero.

When reporting a failure, copy the complete Playback Log immediately and include: device, build
configuration, charging state, network, audio route, Low Power Mode, thermal state, and exact wall
time. Do not diagnose a screen-off stop without those lines.

---

## Before any real release (reminders, not for this test pass)

- Remove DEBUG-only scaffolding: the Today "wx:"/"wake armed:" debug lines,
  `TimelineSeeder`, and the `--verify-*` harnesses are all `#if DEBUG` so they
  won't ship, but the seeder is sim-only noise.
- Decide the manual-alarms question (see the alarms design note).
