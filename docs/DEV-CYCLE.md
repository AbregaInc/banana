# Dev cycle — how to change this app without breaking the one the owner uses

Written after a session that cost a day: a debug build was uninstalled from the production
iPhone to clear a stale Shortcuts registration. That single command deleted the app's data
container, revoked **every** permission grant, and removed the paired Watch app. Reinstalling
restored none of it. The rest of the day was spent discovering the consequences one at a time —
missing reminders, a dead Watch app, permissions that could not be re-requested — each found by
the owner before it was found here.

None of that was necessary. The Mac already had the answer and it wasn't used.

## The rule

**The build you test is never the build you use.**

| | Production | Beta (test here) |
|---|---|---|
| iPhone and iPad | `com.boris.banana` | `com.boris.banana.beta` — "Banana Beta" |
| Mac | `com.boris.banana` | `com.boris.banana.beta` — "Banana Beta" (was `.mac.beta` until 18 Oct 2026) |

Separate bundle ids mean separate data containers, separate TCC permission grants, and separate
Home Screen icons. Nothing beta does can reach production. This is why the Mac beta's calendar
kept working all day while production's was broken.

```sh
tools/ios-install.sh beta      # default; safe
tools/mac-install.sh beta

tools/ios-install.sh prod      # prompts for confirmation
tools/mac-install.sh prod
```

**Where each comes from (the owner, 10 Oct 2026).** Beta is installed by hand from this Mac, with
the two scripts above, on every device. TestFlight carries Stable only: nothing with the Beta
bundle id is ever uploaded. (One script covers iPhone and iPad; with both attached, pass the
device id.)

**Beta changes nothing Stable can see unless it was marked as Beta's** (`AppVariant` in
`Banana/Model/AppSupport.swift`, held by `AppVariantTests`). Both apps are on the same devices
and read the same real calendar, reminders and Health, so what Beta may *change* is fenced:

| Outside the app | Stable | Beta |
|---|---|---|
| Google Calendar | every connected account | reads every account; changes only one marked **Test account** in Settings › Google Calendar (busy blocks included) |
| Google sign-ins (keychain) | `com.boris.banana.google-accounts` | `com.boris.banana.beta.google-accounts`: signing in or out of one never touches the other |
| Apple Reminders | every list | reads every list; changes only its own list, "Banana Beta", made when first needed |
| Apple Health | reads and saves | reads; saves nothing |
| Nearby devices | `_banana-audio._tcp` | `_banana-beta._tcp` |

A new thing that writes outside the app gets a rule on `AppVariant` and a line in that test,
before it ships.

**Beta uses a separate staging iCloud namespace.** iPhone Beta and Mac Beta share
`iCloud.com.boris.banana.beta` and the matching KVS identity, so settings, progress, backups, voice
notes, and transcripts sync between them exactly as they do in production. Neither Beta App ID is
entitled for `iCloud.com.boris.banana`, and Beta code has no legacy-container fallback, so it cannot
read or write production sync data. Beta embeds no Watch app or widget — those are singletons keyed
by bundle id and a second copy would fight production for the same slot.

## Never do these

- **`devicectl device uninstall`.** Deletes the data container, revokes every TCC grant, removes
  the paired Watch app. Install-over preserves all three. There is no problem this solves that
  a beta install doesn't solve better.
- **Install to a production device without being asked.** Build, commit, say what's ready. The
  decision to put something on a device belongs to the person whose device it is.
- **`screencapture` of the whole screen.** It captures whatever else is on the desktop. Use the
  Simulator, or a window-scoped capture.
- **`git --no-optional-locks`.** It suppresses the index refresh, so `git status` reports a clean
  tree over real uncommitted changes. Work committed today nearly went missing this way. If git
  is slow or hanging, the cause is usually a wedged `fsmonitor--daemon`:
  `git config core.fsmonitor false`.


## The Watch, and why the pair drifts

A Watch app can arrive three different ways, and they do not stay in step:

| Route | Installs the Watch app? | Notes |
|---|---|---|
| `devicectl device install` to the iPhone | **No** | Install-over of the phone app only. The Watch keeps whatever it had. |
| TestFlight | Yes, via Watch app on iPhone → Available Apps | The only route that reliably pairs both sides at the same build. |
| Xcode, BananaWatch scheme | Yes, that build only | Leaves the Watch ahead of or behind the phone. |

Development builds **cannot** be installed from the Watch app on iPhone — that route is for
App Store and TestFlight builds. It fails with no useful error, which reads as the Watch being
broken rather than the build being ineligible.

**So: ship a TestFlight build when the Watch matters.** Bump `CURRENT_PROJECT_VERSION`, upload
both platforms, install on the phone, then Watch app → Available Apps → Banana. Anything else
leaves you comparing two different programs and blaming the feature.

### Telling what is actually on each

**Settings › Versions** shows this iPhone's build and, once the Watch app has connected, the
Watch's — with a warning when they differ. The Watch reports its version alongside its episode
inventory on activation, so opening the Watch app is enough to refresh it.

Check that row **before** debugging anything that spans both devices. A session was lost to a
Watch running older code while every symptom pointed somewhere else.

## Verify in this order

1. **Simulator.** Most UI is fully verifiable here — onboarding, empty states, pickers, list
   rows, map routes. Costs nothing and touches no real data.
2. **Beta on device.** Anything needing real hardware: Apple Intelligence, live calendar and
   reminder data, notifications, background behaviour.
3. **Production.** Only what genuinely cannot be tested elsewhere — chiefly the Watch app — and
   only with explicit agreement first.

## Permissions are expensive; treat them that way

A granted permission is slow to rebuild and, in some states, impossible to re-request: iOS does
not list an app under Settings › Privacy for a permission still in `notDetermined`, so there is
nothing for the user to toggle. The app has to be able to ask.

Every permission now has a request path in **Settings › Permissions** that does not depend on
onboarding. Onboarding runs once and never again — `onboardingCompleted` survives an iCloud
restore — so it must never be the only place a permission can be requested. When adding a
permission, add it there too.

Two failure modes to check for by hand, because both have shipped here more than once:

- **A request that returns the request's own value instead of the recorded status.** `try?`
  turns a throw into `false` even when the grant landed, and macOS can report a request granted
  while recording something less. Always re-read `authorizationStatus` and return that.
- **A cached authorization flag nothing refreshes.** EventKit and MusicKit authorization are not
  observable, so a computed property never tells SwiftUI anything changed and the "not connected"
  card stays on screen after a successful grant. Mirror it in a stored `@Published`, and re-read
  it on foreground.
