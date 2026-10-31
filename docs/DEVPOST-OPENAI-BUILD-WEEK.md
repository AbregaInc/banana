# OpenAI Build Week — Devpost submission handoff

Prepared July 18, 2026 for the July 21, 2026, 8:00 PM EDT deadline.

This is copy-ready submission material for Banana. Replace every bracketed `TODO`
before submitting.

## Build Week positioning

The submitted version of Banana was built during OpenAI Build Week with Codex and
GPT-5.6. The repository contains more than 100 dated commits from the Submission
Period documenting the implementation.

## Basic Devpost fields

### Project name

Banana

### Category

Apps for Your Life

### Elevator pitch — 162 characters

Banana unifies calendars, reminders, routines, weather, travel, podcasts, workouts, and recovery into one adaptive daily plan across iPhone, Apple Watch, and Mac.

### Optional shorter pitch — 112 characters

Banana brings your whole day together—planning, routines, podcasts, movement, and recovery across Apple devices.

### Built with tags

Devpost permits up to 25. Use the available matches from this list:

```text
Codex
GPT-5.6
Swift
SwiftUI
Xcode
iOS
watchOS
macOS
AlarmKit
HealthKit
WeatherKit
MusicKit
CloudKit
iCloud
EventKit
WatchConnectivity
AVFoundation
MapKit
CoreLocation
CoreMotion
Speech
RSS
XCTest
MetricKit
```

### Try it out links

Add these when available:

```text
TestFlight: https://testflight.apple.com/join/47yxmU8U
Website: [TODO: landing-page URL]
Repository: [TODO: public repository URL or private judging URL]
Demo video: [TODO: public YouTube URL]
```

No Git remote is currently configured in this working copy, so the repository URL
must be created or added before submission.

## Copy into “About the project”

<!-- COPY START: ABOUT THE PROJECT -->

## Inspiration

My calendar knew about meetings. Reminders knew what was due. Health knew whether I
worked out or slept. My podcast player knew what I was listening to. Weather, maps,
alarms, and music each knew one more piece.

I still had to assemble the day in my head.

Banana began with a simple question: **what if the tools that shape a day shared one
calm surface instead of behaving like unrelated apps?**

The goal is not to replace Apple Calendar, Reminders, Health, Music, or Maps. It is
to bring their useful context together so a person can see what is happening, what
needs attention, where time remains, and what should happen next.

## What Banana does

Banana is a native personal planning system for iPhone, Apple Watch, and Mac.

On iPhone, it combines calendar events, reminders, routines, alarms, weather, travel
context, workouts, recovery signals, and podcast listening into one daily plan. A
re-planning engine can place flexible tasks around fixed commitments. Routines such
as wake, workout, commute, focus, wind-down, and sleep can follow the real shape of
the day instead of living in a separate checklist.

Banana also includes a complete podcast workflow: discovery through public RSS
feeds, background playback, downloads, per-show ordering and speed, listening
history, word-timed transcripts, and contextual voice notes. A voice note can pause
the episode, record a thought, transcribe it on device, and preserve the episode and
timestamp that inspired it.

The Apple Watch app records workouts with live heart rate, energy, distance, route,
and motion data. It can also play selected downloaded podcast episodes offline and
capture a voice note without reaching for the phone.

The Mac app turns the same system into a native desktop workspace for planning,
routines, workouts, podcast library management, and playback.

## How I built it

Banana is one Swift codebase with platform-specific shells:

- **SwiftUI** for the iPhone, Apple Watch, and Mac interfaces
- **EventKit** for Apple Calendar and Reminders
- **AlarmKit** for system-owned alarms
- **HealthKit, CoreMotion, and CoreLocation** for workouts and health context
- **WeatherKit** with a fallback forecast path
- **MusicKit** for user-selected Apple Music routine audio
- **AVFoundation** for podcast playback, downloads, and voice capture
- **Speech** for on-device word-timed transcription
- **WatchConnectivity** for workout, audio, progress, and voice-note transfer
- **CloudKit, iCloud Documents, and key-value storage** for backup and continuity
- **MapKit** for travel, workout routes, and listening history
- **MetricKit, signposts, and XCTest/XCUITest** for energy diagnosis and regression
  testing

The interfaces are deliberately native rather than one responsive layout stretched
across three devices. The phone is the daily control surface, the Watch is for
glanceable action and capture, and the Mac is for review and adjustment at desktop
scale.

## How I used Codex and GPT-5.6

I built the submitted version of Banana during OpenAI Build Week, using Codex with
GPT-5.6 as an engineering and product collaborator throughout the Submission Period.

Codex accelerated the work in several different modes:

1. **Architecture and implementation.** It helped turn an iPhone-only application
   into a shared codebase with native Mac and Watch experiences, cross-device data
   paths, and platform-specific interaction patterns.
2. **Diagnosis from evidence.** When downloaded podcast playback caused severe power
   use, Codex added MetricKit reporting, signposts, playback journals, render-rate
   instrumentation, and verification harnesses. We traced the failure to UI work
   continuing while the screen was off, then changed the background render lifecycle
   and playback/save cadence.
3. **Cross-platform quality.** Codex inspected screenshots, added deterministic
   screenshot routes, iterated on dense layouts, fixed the live Watch complication,
   and verified iPhone, Watch, and Mac surfaces rather than stopping at compilation.
4. **Migration and release engineering.** It implemented safe iCloud migration from
   the predecessor app identity, protected populated backups from empty-device
   overwrites, regenerated signing profiles, produced signed archives, and automated
   TestFlight and App Store asset preparation.
5. **Testing.** It created simulator and on-device regression paths for scheduling,
   background behavior, onboarding permissions, timeline assumptions, and the
   returning-user migration.

I made the core product decisions: Banana should integrate Apple-native sources
instead of replacing them; each platform should have a native role; permission pages
should explain value and appear only when access is missing; restored data should
never be overwritten by an empty install; and battery behavior had to be measured on
real hardware rather than guessed from the simulator.

Codex made it possible to test those decisions quickly, inspect failures, change the
implementation, and verify the result across a much larger surface area than I could
have covered manually in the same week.

## What I built during Build Week

During Build Week I built:

- A native macOS application and desktop-scale planning, workouts, routines, library,
  and playback experiences
- Major Apple Watch workout, offline listening, voice-note, and complication work
- Contextual voice notes that coordinate playback across phone and Watch
- Travel-aware weather and flight-ground-leg planning across Day and Week
- A full background power investigation and energy-focused architecture changes
- Safer podcast persistence, background downloads, playback recovery, and progress
  syncing
- Cross-device iCloud backup, operational sync foundations, and predecessor-app data
  migration
- A complete Banana rebrand across iPhone, Watch, Mac, widgets, signing, and App Store
  Connect
- Permission-aware onboarding that explains each integration and never repeats
  permissions already granted
- Automated App Store screenshots, marketing metadata, ASO research, and submission
  validation
- Local, signed-device, Watch, Mac, and TestFlight release verification

The Git history and primary Codex thread document this implementation throughout the
Submission Period.

## Challenges I faced

### Making background audio genuinely efficient

The most important issue was severe power usage while a downloaded podcast played
with the screen off. The audio itself was not the main problem. Parts of the SwiftUI
tree continued updating while nobody could see them, progress changes caused
unnecessary persistence work, and sync paths could wake radios too often.

The fix was not one guessed optimization. I added observability first, reproduced the
behavior on hardware, gated the complete visual tree while backgrounded, reduced
progress and backup cadence, moved expensive work off the main actor, and built
regression instrumentation around the failure class.

### One product across three very different devices

An iPhone tab bar is wrong on a Mac, and a desktop information layout is unusable on
a Watch. Sharing the model while giving each platform a native shell required clear
ownership of state, careful conditional compilation, and repeated visual validation.

### Moving a real user’s data through a rebrand

The product changed identity during the week. A new bundle and iCloud container could
have stranded the predecessor app’s podcast subscriptions, play positions, history,
and routines. The migration now reads both containers, validates the snapshots,
prefers the richest valid recovery point instead of the newest empty one, asks before
restoring, and immediately establishes a new Banana backup.

### Permissions without a hostile onboarding experience

Banana can use several Apple frameworks, but showing a wall of unexplained system
prompts would undermine trust. The onboarding flow now explains how each permission
is used and what value it provides, does not allow swiping past explanations, and
constructs its route from only the permissions that are actually missing.

## Accomplishments I am proud of

- Banana is a working product on a physical iPhone, Apple Watch, and Mac—not a static
  prototype.
- The same core occurrence model drives planning and routines across platforms while
  each platform retains a native interface.
- Podcast playback, downloads, transcripts, voice notes, workouts, routes, and
  planning are demonstrated end to end.
- The project has real power, performance, migration, and UI regression tooling.
- A signed TestFlight build has been produced, and the current development build can
  be installed directly on hardware.
- More than 100 dated commits during the Submission Period document the scale and
  progression of the Build Week extension.

## What I learned

The biggest lesson was that integration is not the same as aggregation. Putting
calendar, fitness, podcasts, and routines into adjacent tabs would still leave the
user doing the mental work. The useful product emerges when those sources share time,
place, current activity, and a common occurrence model.

I also learned to treat energy behavior as a product feature. An app that organizes
the day but drains the phone in a pocket has failed, regardless of how good the
interface looks. Instrumentation and real-device evidence changed several
architectural decisions.

Finally, I learned that Codex is most effective when it can participate in the whole
loop: inspect the code, form a falsifiable diagnosis, edit the implementation, build
it, run tests, install it on the device, inspect the result, and keep iterating.

## What’s next

Next I want to complete the public App Store launch, finish the new Banana visual
identity, deepen the re-planning experience, expand real-device energy testing, and
make cross-device continuity feel increasingly immediate without sacrificing battery
life or user control.

The long-term goal remains simple: give a person one calm place to understand the
day—without asking them to abandon the Apple apps and services they already trust.

<!-- COPY END: ABOUT THE PROJECT -->

## Judge testing instructions

Copy this into the private testing-instructions field after replacing placeholders:

<!-- COPY START: TESTING INSTRUCTIONS -->

Banana is a native Apple-platform application.

Recommended test path:

1. Install the final Banana TestFlight build from `https://testflight.apple.com/join/47yxmU8U` on an
   iPhone running iOS 26.1 or later.
2. On first launch, grant only the permissions you want to exercise. Banana explains
   each permission and skips access already granted. Alarm access is required for the
   full planning surface; the other integrations are optional.
3. Open **Plan** to view the unified day and use **Re-plan my day** with sample or
   personal Calendar/Reminder data.
4. Open **Routines** to inspect wake, workout, commute, focus, wind-down, and sleep
   cues.
5. Open **Library**, subscribe to a public podcast, download an episode, play it,
   change speed, and open its transcript.
6. If an Apple Watch is paired, install the companion app to view the workout picker,
   active metrics, offline listening, and voice-note controls.
7. The Mac target can be built from the repository to inspect the native desktop Plan,
   Workouts, Routines, and Library surfaces.

No account credentials are required. Apple Music playback requires the tester’s own
Apple Music access. Health, Calendar, Reminders, location, weather, and Watch features
depend on the related Apple permissions and available device data.

Repository setup and sample-data instructions are in the README.

<!-- COPY END: TESTING INSTRUCTIONS -->

## Demo video plan — maximum 2:50

The video must be public on YouTube, include narration, demonstrate the working
project, and explain both Codex and GPT-5.6 usage. Do not use copyrighted music or
unlicensed podcast audio.

### 0:00–0:15 — The problem

**Visual:** Rapid view of Calendar, Reminders, Health, podcast, and weather concepts,
then Banana’s unified plan.

**Narration:** “The apps that shape my day each know one piece. I still have to put
the day together in my head. Banana brings those pieces into one calm daily plan.”

### 0:15–0:45 — Unified Plan

**Visual:** iPhone Plan with meetings, reminder, cue, travel, and weather; switch
Day/Week; show Re-plan preview.

**Narration:** “Calendar events, reminders, routines, alarms, weather, and travel
share one timeline. Re-plan fits flexible work around what cannot move.”

### 0:45–1:10 — Routines

**Visual:** Routines list and one editor; show smart wake or a workout trigger.

**Narration:** “Routines can follow the day—before the first meeting, when a workout
starts, or at a time I choose—instead of living in another checklist.”

### 1:10–1:40 — Podcasts, transcripts, and notes

**Visual:** Downloaded episode playing with the phone locked/backgrounded; open
transcript; record a short voice note; show its episode/timestamp context.

**Narration:** “Banana downloads and plays podcasts, follows every word on device,
and turns a thought into a contextual note without losing where it came from.”

### 1:40–2:05 — Apple Watch

**Visual:** Workout picker, active metrics, podcast transport, and note button.

**Narration:** “On Apple Watch, Banana records workouts, plays selected downloads
offline, and captures a note from the wrist.”

### 2:05–2:20 — Mac

**Visual:** Mac Plan, Routines, Workouts, and Library navigation.

**Narration:** “At the desk, the same system becomes a native Mac workspace rather
than a stretched phone interface.”

### 2:20–2:43 — Codex and GPT-5.6

**Visual:** Brief, readable montage of the Codex thread, power diagnostics, UI test,
device build/install, and dated Git history.

**Narration:** “During Build Week I used Codex with GPT-5.6 to build this submitted
product: create the Mac experience, deepen the Watch app, diagnose a real
background power failure, implement safe iCloud migration, automate screenshots and
release work, and verify the result on real hardware.”

### 2:43–2:50 — Close

**Visual:** Cross-device Banana lockup.

**Narration:** “Banana: everything you need, in one happy place.”

## Project media plan

Devpost accepts up to 15 JPG, PNG, or GIF files, each no larger than 5 MB, and
recommends 3:2.

Recommended gallery order:

1. 3:2 cross-device hero: iPhone Plan + Watch Now Playing + Mac Plan
2. iPhone unified Plan
3. iPhone Routines
4. iPhone Re-plan preview
5. iPhone listening map
6. iPhone transcript
7. iPhone workout detail
8. Watch active workout
9. Watch podcast transport
10. Mac Plan
11. Mac Routines
12. Mac Workouts
13. Codex/power-diagnostics engineering proof
14. Automated UI-test/screenshot proof
15. Build Week extension timeline

Source screenshots are in:

```text
LandingPage/assets/screenshots/
```

Before uploading, create 3:2 gallery compositions and apply the new Banana character
brand direction. Do not upload the current workout capture that says “Connect Apple
Health,” the three-second Watch workout, or the repetitive transcript demo.

## Repository README additions required

Update the current README before submission with:

1. Current Banana overview and screenshots
2. Supported platforms and minimum OS versions
3. Architecture and Apple frameworks
4. Build/setup instructions for iPhone, Watch, and Mac
5. Sample/demo data instructions
6. Judge testing path
7. Privacy and permissions
8. **OpenAI Build Week implementation**
9. **How Codex and GPT-5.6 were used**
10. Known limitations
11. License and third-party dependency/license notices

Suggested Build Week disclosure:

```markdown
## OpenAI Build Week

The submitted version of Banana was built during OpenAI Build Week with Codex and
GPT-5.6. I built the native Mac app, major Watch and cross-device functionality,
contextual voice notes, travel-aware weather, energy/performance instrumentation and
fixes, iCloud migration, permission-aware onboarding, the Banana rebrand, automated
App Store assets, and release/testing infrastructure.

The Git history and submitted Codex /feedback session provide the dated
implementation record.
```

## Required `/feedback` field

Run `/feedback` in the Codex thread where the majority of the core Build Week
extension was completed. Paste the returned letters-and-numbers Session ID here and
into Devpost:

```text
[TODO: /feedback SESSION ID]
```

Do not use an ordinary browser URL, conversation title, or Git commit hash in this
field.

## Final compliance checklist

- [ ] Entrant is eligible in their country/territory and is above the applicable age
  of majority.
- [ ] Include the dated Build Week implementation history.
- [ ] Commit the current Build Week work before submission.
- [ ] Add a repository remote and obtain the final URL.
- [ ] If public, add an appropriate license and verify all bundled assets/data may be
  published.
- [ ] If private, share repository access with `testing@devpost.com` and
  `build-week-event@openai.com`.
- [ ] Update the README using the section above.
- [ ] Upload a final working build and keep it available free of charge through the
  judging period ending August 5.
- [ ] Confirm the final TestFlight link/testing instructions work for a fresh judge.
- [ ] Upload a public, narrated YouTube demo shorter than three minutes.
- [ ] Remove copyrighted music and any podcast audio/artwork that is not cleared for
  public promotional use.
- [ ] Upload no more than 15 images, each under 5 MB; prefer 3:2 compositions.
- [ ] Paste the `/feedback` Session ID.
- [ ] Confirm project ownership and third-party SDK/API/license compliance.
- [ ] Complete every required Devpost field before July 21 at 8:00 PM EDT.
- [ ] Review the live Official Rules and Devpost page once more immediately before
  submitting; they control if anything differs from this handoff.
