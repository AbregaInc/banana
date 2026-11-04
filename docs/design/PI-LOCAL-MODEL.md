# Banana Pi's model on the Mac, kept by the app

1 November 2026. <redacted>: "We need everything managed in app."

## What it is

Banana Pi on the Mac runs Qwen3.5 4B (4-bit, `mlx-community/Qwen3.5-4B-4bit` pinned at revision
`0e7ffd5c629e…`) on Locals, and every piece of it is the app's own:

- **The runtime ships inside the app** (`Contents/Resources/PiRuntime`, ~490 MB): a relocatable
  CPython, Locals at its reviewed commit and the pinned packages, built by
  `tools/pi-mac-inference/build-runtime.sh` and embedded by the PiDevelopment build.
- **The model is fetched by the app** (`LocalModel`, `PinnedModelFiles`): the pin
  (`Banana/Pi/Resources/pi-local-model.json`: every file's size and SHA-256, plus the serving
  profile) is downloaded into `~/Library/Application Support/Banana Pi/Models/<name>@<revision>/`,
  each file checked, the folder stamped so later launches don't re-hash 3 GB.
- **The worker is started by the app** (`MacLocalInference`) when Pi activates, on loopback, with
  the bundled Python in isolated mode; it stops when the app quits (and on a crash, via the
  worker's parent watch).
- Until the files are ready, Pi uses Apple's on-device model. When they finish while the app is
  open, Pi switches at its next activation. Nothing to press: Settings › Assistant shows one line
  ("Getting Qwen3.5 4B · 1.2 of 3.0 GB", then "Qwen3.5 4B · on this Mac").
- Never in fixture or UI-test runs (no 3 GB download in tests).

## Why Locals and not Apple's MLX Swift adapter

Measured 1 November on Banana's evaluation (tools/pi-evaluation/RESULTS-SWIFT-MLX-2026-11-01.md):
same files, same 22 cases × 2. Locals 42/44 at a 0.77 s warm median; Swift MLX through Pi's
Foundation Models bridge 43/44 at 6.57 s, slower on every case. Pi starts a fresh session per turn,
so the adapter's in-session prefix reuse never applies; Locals keeps the unchanged prefix cached.
Locals from the app's own runtime measured the same as the developer setup (42/44, 0.78 s).

## iPhone and iPad

Apple's on-device model, as before. `PinnedModelFiles` is platform-neutral should they get a
model of their own.

## Open

- Another Mac: a development-signed copy runs on a Mac that trusts it; for any Mac, the app
  (and every runtime binary, which the embed step already signs with the hardened runtime) needs
  Developer ID signing and notarization, which waits for <redacted>'s yes.
- Download resumes per file, not mid-file.
- Port 41789 is fixed; another program on it makes Pi say so rather than share.
