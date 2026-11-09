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

Every script takes `--dry-run`: it prints each step and command, and runs only what changes
nothing (the plan into a temporary file, device discovery, the migration check). Output of a real
run goes to `private/releases/<channel>-<build>/` (ignored), one log per step.

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
