# Release scripts

One script per job, tracked, with every private value read from configuration outside the tree.
They replace the per-build scripts that were copied with `sed` from the previous build's.

| Command | What it does |
|---|---|
| `tools/preflight.sh [--channel beta\|stable] [--build N --version V] [Class …]` | Everything a rollout can fail on, with the rollout's own builds; the rollout adopts its archives. Must pass first. |
| `tools/release/ship-beta.sh N --notes-file F [--install-mac]` | iOS Beta on the iPhone and iPad; Mac Beta build, tag, draft, notarize, publish; site feed; site commit. |
| `tools/release/ship-stable.sh N --notes-file F [--public-beta --what-to-test F --review-notes F]` | TestFlight iOS and Mac (upload; the public beta group, What to Test and Beta App Review only with `--public-beta`); Mac direct; site; Stable on the iPhone and iPad. |
| `tools/release/deploy-service.sh beta\|prod [--yes-prod]` | Service tests, additive migrations, deploy with the source offer, smoke test. |
| `tools/release/install-mac.sh beta\|stable DMG` | Verify a released DMG, back up the installed app, install it, relaunch. |
| `tools/release/devices.py list\|find\|run` | The owner's iPhone and iPad by kind, waiting out locked or unreachable devices. |
| `python3 tools/mac-release-tests.py build` | Build only the Mac release UI runner, in the background; no app target or launch. |
| `python3 tools/mac-release-tests.py run ARCHIVE --out NEW_FOLDER --interactive` | Visible tests of the exact archived Mac App Store app, in a dedicated test account. |
| `python3 tools/mac-release-tests.py verify ARCHIVE [--evidence FOLDER]` | Read-only upload gate: checks exact candidate, symbols, test cases and macOS/SDK coverage. |

The shipping shell scripts take `--dry-run`: it prints each step and command, and runs only what changes
nothing (the plan into a temporary file, device discovery, the migration check). Output of a real
run goes to `private/releases/<channel>-<build>/` (ignored), one log per step.

## Mac App Store launch gate

`tools/preflight.sh --channel appstore` now includes `mac-appstore-launch`.
`tools/testflight.sh mac N upload appstore` independently requires passing launch evidence before
the upload export, including when preflight was skipped. Building and inspecting the archive
alone cannot pass this gate. Preparing a local export remains possible without launching an app.
`tools/asc-submit.py --apply` also enforces it for Mac submission/resubmission, so an older upload
does not bypass the gate. Draft attachment and read-only submission planning remain available.
Submitting through Apple's website bypasses local scripts; run `verify` first in that case.

The native XCTest suite uses `XCUIApplication(url:)` to open the app **inside the archive**, with
no preview flags, fixtures, injected app environment or Debug rebuild. It checks the normal first
screen, deferred-startup survival, onboarding without Google sign-in, Day/Week selection, next
period/Today, saved onboarding on relaunch and another startup interval. A second test checks
the Foundation `Date >=` / `<=` operators imported by that candidate against numeric timestamps
on the actual runtime, including equal dates, infinities and NaN (36 pairs per imported operator).
A candidate that removes the imports is not blocked by the probe's own Date operators.
Native XCTest is used instead of a custom GUI driver:
it can select the exact Mac app URL, fail launch errors, wait on accessibility state and retain
screenshots/crashes in an xcresult. These are correctness checks, not UI latency measurements.

Visible runs require an **idle, unlocked dedicated macOS test account**, signed out of iCloud
and Google, with no personal calendars or Banana data. Use a disposable test machine/VM or reset
that account's test state between runs. The suite deliberately fails if it finds completed
onboarding; it does not erase preferences, containers, keychain items or installed applications.
It refuses to launch an identity that is already running. Never create the marker in the owner's
everyday account. In the dedicated account only, allow XCTest to activate Automation Mode
without an authentication prompt and create:

```sh
mkdir -p ~/.config/banana
touch ~/.config/banana/mac-release-test-account
sudo automationmodetool enable-automationmode-without-authentication
```

`automationmodetool` may still report "Automation Mode is disabled" outside a test session.
That is normal: the prerequisite is "DOES NOT REQUIRE user authentication"; XCTest activates
the mode when its session starts.

For a local macOS VM, reuse its persistent machine identity and a signed-out guest account.
Register its **provisioning UDID** (from `system_profiler SPHardwareDataType`) with the development
team before preparing the archive. The archive's development profile must authorize that VM;
otherwise macOS refuses the process before app code runs, even when `codesign --verify` passes.
Keep that failure as failed launch evidence. Do not strip entitlements or re-sign the tested app
to bypass it: prepare a new candidate with the appropriate profile and test that exact archive.
Run the VM without host graphics, clipboard or home-directory sharing; share only the test kit
and an evidence directory. Stop the VM after the run and keep it for the next release.

Build the runner without touching the screen, then, on the dedicated idle desktop:

```sh
python3 tools/mac-release-tests.py build
# Prepare the signed calendar-only archive/export on the build machine (no upload):
tools/testflight.sh mac <build> prepare appstore
# Make the same archive available to the dedicated account; never rebuild or re-sign it there.
python3 tools/mac-release-tests.py run <archive-path> \
  --out private/releases/mac-launch/<build>-<unique-run> --interactive
python3 tools/mac-release-tests.py verify <archive-path>
```

When testing on another account/machine, copy the complete result folder (including xcresult)
back into `private/releases/mac-launch/`, or set `BANANA_MAC_LAUNCH_EVIDENCE` to its parent.
Each attempt needs a new directory; failed/unfinished attempts stay on disk and cannot pass.
The gate rereads the raw xcresult, requires both exact test identifiers with zero failures/skips,
and checks XCTest's runtime against the receipt. It binds evidence to all app bundle contents,
the clean source commit, build, channel, SDK, executable UUIDs, matching dSYM and test harness.
Changing any of these invalidates that evidence. The candidate's signature, sandbox and absence
of get-task-allow are checked before testing and again before upload. The app must also be
unchanged after the tests. App Store export/Apple may subsequently re-sign the archive's code;
this gate does not claim to test Apple's delivered package or Google sign-in.

Required runtime coverage includes **macOS 27.2 beta 2, build 26B5091g** (the launch-crash
regression) and the archive's SDK major/minor version. A different 27.2 build or 27.2.1 cannot
replace the review build. XCTest's OS build metadata must match the receipt. If a later SDK is
used, retain runs on both boundaries. This is a targeted compatibility gate,
not a claim of coverage of every supported macOS version; the minimum supported OS and a real
review Google-account walkthrough remain release acceptance checks.

The first preflight can build the candidate and report missing launch coverage. Prepare adopts
that archive; run the suite on it and then upload. Rechecking an already prepared archive reuses
it, so signing timestamps do not silently replace the tested candidate. App Store archives and
preflight archives are now retained by `clean-builds.sh`; compilation uses the existing
`.build/mac-check` folder. Keep evidence under `private/`, outside disposable `.build`, and keep
the original archive/dSYM for every submitted build.

## Typical Beta rollout

```sh
git switch release/banana-ready && git pull
tools/preflight.sh --build 116 --version 1.0.4        # optional: ship-beta runs it first
$EDITOR private/releases/notes-116.md                  # what changed, for GitHub and the feed
tools/release/ship-beta.sh 116 --notes-file private/releases/notes-116.md --dry-run
tools/release/ship-beta.sh 116 --notes-file private/releases/notes-116.md --install-mac
```

The feed shows one line: `--feed-notes TEXT`, or the notes file's first line of text.

## Configuration (names only; the values never enter the tree)

`tools/config.sh` reads `Config/Local.xcconfig` (linked from `~/.config/banana/Local.xcconfig`)
and `~/.config/banana/release.env`; `tools/release/lib.sh` adds
`~/.config/banana/distribution.env` (or `$BANANA_DISTRIBUTION_ENV`).

| Name | Used for |
|---|---|
| `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_PATH` (release.env) | signing without an Xcode login, TestFlight upload, notarization, App Store Connect |
| `BANANA_UPDATE_PUBLIC_KEY_BETA`, `BANANA_DEVELOPER_ID_PROFILE_BETA` (release.env) | the Beta direct app's Sparkle key and Developer ID profile |
| `BANANA_DEVELOPER_ID_IDENTITY_BETA` | the Beta direct app's signing identity |
| `BANANA_UPDATE_PUBLIC_KEY_STABLE`, `BANANA_DEVELOPER_ID_PROFILE_STABLE`, `BANANA_DEVELOPER_ID_IDENTITY_STABLE` | the same for Stable |
| `BANANA_SPARKLE_BIN` | the folder with Sparkle's `sign_update` and `generate_appcast` |
| `BANANA_SPARKLE_KEY_ACCOUNT_BETA` | keychain account of Beta's Sparkle private key |
| `BANANA_SPARKLE_KEY_FILE_STABLE` | Stable's Sparkle private key file |
| `BANANA_RELEASE_PHONE_MODEL`, `BANANA_RELEASE_PAD_MODEL` | which iPhone / iPad (productType) gets installs when more than one is paired |
| `BANANA_COMMIT_TRAILER` (optional) | a trailer line for the site commit |
| `WRANGLER_VERSION` (optional) | the wrangler release deploy-service.sh runs (default pinned in the script) |

A missing name stops the script with the name, never a value.
