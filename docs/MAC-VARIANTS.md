# Prod and Beta on one Mac

Two Mac apps build from the same code and coexist in /Applications:

| | Prod | Beta |
|---|---|---|
| Target / scheme | `BananaMac` | `BananaMacBeta` |
| Bundle id | `com.boris.banana` (was `.mac`) | `com.boris.banana.beta` (was `.mac.beta` until 18 Oct 2026) |
| App | `Banana.app` | `Banana Beta.app` (badged icon) |
| Local data | `~/Library/Application Support/` (unchanged legacy layout) | `~/Library/Application Support/Banana Beta/` |
| iCloud | Production sync | **Staging sync** with iOS Beta only |
| UserDefaults / caches | per-bundle-id automatically | per-bundle-id automatically |

Install either with:

```sh
tools/mac-install.sh beta   # the build you're testing
tools/mac-install.sh prod   # the stable daily driver
```

`prod` typically gets built from a known-good commit; `beta` from whatever you're
working on. Run the script from the corresponding checkout/worktree.

## How isolation works

- All local persistence goes through `AppSupport.directory`
  (`Banana/Model/AppSupport.swift`). The `BANANA_BETA` compile flag (set only on the
  beta target) diverts it into the `Banana Beta` subfolder. Prod paths are
  byte-identical to what the app has always used — no migration happened.
- Beta has iCloud/KVS entitlements only for `iCloud.com.boris.banana.beta` and its matching
  staging KVS identity. Mac Beta and iOS Beta sync with each other but cannot see or write
  production backups, progress, settings, voice notes, or transcripts.
- A Google Calendar connection syncs only its non-secret account email as a sign-in hint. Each
  device still receives and keeps its own OAuth credentials after the user approves Google once.

## What both apps still share

Both read the real system: **calendars, reminders, Health, contacts**. Beta changes none of it
unless it was marked as Beta's: a Google account marked "Test account", the "Banana Beta"
reminders list. It saves nothing to Health, keeps its Google sign-ins in its own keychain item
and announces its own nearby-devices service. Notifications
come from each app under its own name.

## Bundle identity and TestFlight

As of 2026-07-24 the Mac app uses the SAME bundle id as iOS: `com.boris.banana`.
That shares the App Store record (universal purchase; add the macOS platform on the
existing "Banana" app in App Store Connect) and — decisively — the App ID that
already has `iCloud.com.boris.banana` associated, so distribution signing works
without the container dance. The historical `com.boris.banana.mac` identity is
retired (its API-registered App ID `USF57Y65FF` and "Banana Mac Development"
profile are orphaned; harmless). Consequences of the switch: macOS asks for
Calendar/Reminders access once more under the new identity, and per-bundle-id
defaults migrate automatically on first launch (`BananaApp.init`).

TestFlight/App Store builds are sandboxed (`BananaMacAppStore.entitlements`:
sandbox + network client/server + calendars + location + microphone + iCloud) via
`tools/mac-testflight.sh`. A sandboxed build stores data in its container, NOT in
the legacy `~/Library/Application Support` layout — a data migration is needed
before a sandboxed build can replace the daily driver.

Local prod installs (`tools/mac-install.sh prod`) stay non-sandboxed. Full local
iCloud still needs a Mac development profile, which the ASC API key cannot mint
("Authentication failed" — dev profiles only; distribution cloud-signing works);
until a one-time Xcode GUI signing pass, use `NO_ICLOUD=1`.

## iOS beta

The iPhone beta follows the same pattern: the `BananaBeta` target uses the
`com.boris.banana.beta` bundle id, the `BANANA_BETA` flag, isolated storage, and a
badged Home Screen icon. It deliberately embeds neither the production Watch app
nor the widget extension.
