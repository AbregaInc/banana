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

Apple’s on-device model is the default. In an AI-enabled Beta, open **Assistant → … →
Desktop link** on both devices. Enable sharing on the Mac, then choose **Scan Mac QR code**
on the iPhone or iPad. You can copy and enter the pairing code manually as well. Keep Banana
Beta open on the Mac. The connection screen shows which
route is in use and whether the Mac’s model is ready.

Bonjour finds the paired Mac on Wi-Fi or Ethernet and model requests stay on that network.
Away from home, use the Mac’s Tailscale IPv4 address and opt in for that session. If the
paired Mac is discovered locally, failed authentication or inference does not try another
route. The app does not use a Banana Cloud relay. If the Mac is unavailable when Assistant
opens, the device uses its own model where supported. An interrupted desktop turn returns
an error and is never replayed.

The versioned desktop link uses TLS with a random pairing secret stored in each device’s
Keychain. Share the code only with your own devices. Turning sharing off from the Mac
revokes the code for all paired devices. The Mac serves model inference through this link
and keeps the model worker on loopback. Conversation storage and tool execution stay on
the requesting device.

For transport verification on the Mac:

```sh
test_dir=$(mktemp -d)
xcrun swiftc -DBANANA_AI -DBANANA_BETA Banana/Pi/DesktopPeerLink.swift \
  Banana/Pi/DesktopPairingQRCode.swift \
  tools/tests/desktop-peer-link.swift -o "$test_dir/desktop-peer-link"
"$test_dir/desktop-peer-link"
rm -rf "$test_dir"
```

On physical devices, pair over the same Wi-Fi with Tailscale disabled and check that the
connection reports **Local network**. Try the same prompt from an off-LAN connection, with
Tailscale enabled and the explicit away access switched on. Turn sharing off on the Mac
and verify that the previous code and outstanding requests stop working.

## Open

- Another Mac: a development-signed copy runs on a Mac that trusts it; for any Mac, the app
  (and every runtime binary, which the embed step already signs with the hardened runtime) needs
  Developer ID signing and notarization, which waits for <redacted>'s yes.
- Download resumes per file, not mid-file.
- Port 41789 is fixed; another program on it makes Pi say so rather than share.
