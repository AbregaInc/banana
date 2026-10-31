# Banana App Store generator

This tool builds deterministic Debug screenshot routes, captures real UI from Apple simulators,
composes screenshots matching bananatheapp.com, copies App Store metadata, and validates the
result against Apple’s current dimensions and field limits.

## Generate everything

```sh
python3 tools/app-store/generate.py
```

Output is written to `AppStore/Generated/`:

- `raw/` — untouched simulator/window captures used as evidence.
- `screenshots/iphone-6.9/` — 1320 × 2868 composed screenshots.
- `screenshots/ipad-13/` — 2752 × 2064 landscape composed screenshots.
- `screenshots/watch/` — 416 × 496 real Watch UI.
- `screenshots/mac/` — 2880 × 1800 composed screenshots.
- `metadata/en-US/` — Fastlane-compatible text files.
- `checksums.json` — SHA-256 inventory of the generated package.

Each run also refreshes `LandingPage/assets/screenshots/` from the exact raw and composed output
and rebuilds the iPhone, iPad, Mac, and Watch contact sheets. This keeps the website and App Store
artwork on the same source captures.

## Useful options

```sh
# Run one platform while iterating.
python3 tools/app-store/generate.py --platform iphone
python3 tools/app-store/generate.py --platform ipad --keep-output
python3 tools/app-store/generate.py --platform watch --keep-output
python3 tools/app-store/generate.py --platform mac --keep-output

# Reuse existing Debug products.
python3 tools/app-store/generate.py --platform iphone --skip-build
python3 tools/app-store/generate.py --platform ipad --keep-output \
    --ios-app .build/sim/Build/Products/Debug-iphonesimulator/Banana.app
python3 tools/app-store/generate.py --platform mac --keep-output \
    --mac-app ".build/mac-check/Build/Products/Debug/Banana Beta.app"

# Validate an existing package.
python3 tools/app-store/validate.py AppStore/Generated
```

Edit `manifest.json` to change screenshot order, captions, feature crops, simulator devices, or
brand accents. Feature crops use normalized `[x, y, width, height]` coordinates and always crop a
real raw capture.

## Requirements

- Xcode with the simulator runtimes named in `manifest.json`.
- Python 3 and Pillow.
- Mac captures use the visible WindowServer window so sidebar and toolbar materials composite
  correctly. The login session must be unlocked and `screencapture` needs Screen Recording access.
  Five windows open and close on the desktop, so run it when the screen is free.
- The Mac capture runs the **Beta** variant (`BananaMacBeta`, signed), never the daily app's
  target: Beta has its own bundle id and its own data folder, so a capture cannot read or change
  the data of the Banana installed on the Mac. Signing may need the developer portal; pass the
  App Store Connect key through `AUTH_ARGS`, as for `tools/mac-install.sh`.
- `--ios-udid` names the simulator for a single `--platform iphone` or `--platform ipad` run.
  By name there can be one per installed iOS version, and the one found may never have been
  booted: on a busy Mac a first boot has taken longer than the run. An iPhone 17 Pro has the
  Pro Max's shape, so its captures compose into the same 1320 × 2868 images.
- iPad captures use the actual landscape layout. The generator attaches Orca’s background
  emulator helper and rotates the explicitly selected existing simulator to `landscape_left`;
  it does not open Simulator.app. Coordinate ownership with other agents before the run.
  `ORCA_CLI_COMMAND` can select the session’s Orca executable. Stop the helper and shut down
  the simulator when done. Portrait raw images are rejected rather than stretched or rotated
  into a landscape composition.
- No App Store Connect credentials are required for the iPhone, iPad, and Watch sets or to
  validate the package. Building the Mac capture's signed Beta may need them (above).

## Website brand exports

`python3 tools/app-store/brand.py` exports the owner-supplied mascot SVG as vector masters,
main/Beta iPhone and Mac icons, the Watch icon and the submission brand package. Main uses the
supplied yellow face; Beta adds a small BETA badge above the left eye. librsvg and Pillow are
required for deterministic exports. The site remains the visual reference. Screenshots use the
same IBM Plex Mono (bundled under its OFL license), cream/ink/yellow and pastel accents.

`generate.py` reuses `.build/sim`; pass the repository's existing phone/iPad UDIDs as shown in
AGENTS.md. Shut down each simulator after capture. Mac captures open visible windows: wait for an
idle desktop. Never substitute old raw captures for fresh capture evidence without labeling them.

The validator rejects alpha channels and PNG transparency, including otherwise opaque RGBA Watch
captures. Raw evidence stays untouched; Watch upload copies are flattened against black.

## Capture evidence and unpublished Connect drafts

Each completed platform capture records its executable SHA-256 and raw-image hashes in
`capture-status.json`. A provided `--ios-app`/`--mac-app` product may predate the current checkout;
the hash identifies the product actually captured. This record never marks a submission ready.
After replacing Mac captures, recompose the phone continuity scene and regenerate creative
artwork before placing those assets. Inspect the contact sheets and Apple's placement preview.

The Connect helpers use Apple's App Asset Library and live specification catalogue. They do
not submit for review or select a build. Use a Python environment with PyJWT and Pillow.

```sh
# Preview proposed English draft text changes; --apply writes and verifies them.
python3 tools/app-store/update-draft.py --out /tmp/banana-store-text-plan

# Validate against Apple's live catalogue; --apply uploads, --place updates draft placements.
python3 tools/app-store/upload-assets.py --platform ipad --out /tmp/banana-ipad-media
python3 tools/app-store/upload-assets.py --platform ipad --out /tmp/banana-ipad-media --apply --place
```

Reuse the same media `--out` directory to resume interrupted uploads. Its private state retains
asset IDs, previous draft placements and restoration information. Uploads require matching fresh
raw-capture evidence; phone continuity and optional creative artwork also require fresh Mac
captures. Media validation alone does not prove freshness or production acceptance.
