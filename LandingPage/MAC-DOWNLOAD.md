# Direct Mac downloads

Status: Mac 1.0.2 (88), tag `mac-v1.0.2-88`, is published on GitHub Releases.
The production website offers `/download/mac` and the matching signed update feed.
The hosted DMG checksum, live feed and homepage have been verified. Production
signing, notarization, Gatekeeper, release guards and tooling tests passed. Live
service coverage is not implied by these checks; the installed local build's data
migration was verified separately before publication.

## Landing page

Keep the existing design, artwork and product explanation. In the hero, replace the
single beta button with two explicit choices:

- **Download for Mac** — primary button, linking to `/download/mac`.
- **iPhone & iPad beta** — secondary button, linking to the current TestFlight invite.

Show one compatibility line: **Apple silicon · macOS 26+**. Put version, size,
release notes and SHA-256 on the release page, rather than crowding the hero.
On narrow screens, stack the buttons at full width. Both choices remain available
on every device; avoid user-agent redirects. Keep GitHub as a logo-and-text header link.
The header's beta button becomes **Download for Mac** when the DMG launches.

Update the final CTA, platform FAQ, beta fine print, About and Support to explain
that Mac can install directly while iPhone, iPad and Watch use TestFlight. Update
SoftwareApplication.downloadUrl alongside the visible link. Do not claim automatic
updates until the updater is integrated and tested.

## Release pipeline

1. Archive the native `BananaMacDirect` Release scheme for Apple silicon, with
   `BANANA_UNRELEASED=NO`, hardened runtime and Developer ID distribution.
   Run `tools/check-release.sh` on the archive.
2. Use a dedicated distribution entitlement configuration derived from the
   sandboxed TestFlight configuration, with production CloudKit and push settings.
   Obtain a Developer ID provisioning profile covering the actual restricted
   entitlements. Validate WeatherKit, iCloud, push and keychain access on the
   exported app; a signing certificate alone does not prove profile coverage.
3. Export using Developer ID signing. Package Banana.app and an Applications
   shortcut into a read-only DMG. Sign the DMG, submit with `notarytool`, require
   acceptance, staple and validate its ticket, and verify Gatekeeper acceptance
   of the app and disk image on a clean Mac.
4. Publish a versioned DMG, release notes and SHA-256 checksum on GitHub Releases.
   Use a stable asset filename such as `Banana.dmg` within each versioned release.
   Add a 302 `/download/mac` redirect to the chosen release asset only after it
   is downloadable. An explicit version target allows intentional promotion and
   rollback without accidentally selecting a mobile-only or prerelease tag.
5. Integrate Sparkle 2 for signed in-app updates in the direct-download build
   only. Store the EdDSA private signing key outside the repository; publish the
   public key in the app and an HTTPS appcast. Keep Sparkle out of TestFlight
   builds. Test upgrade, interrupted download, invalid signature, and retention
   of user data before advertising automatic updates.

Reuse one `.build/mac-distribution` directory for this pipeline and clean scratch
outputs according to AGENTS.md. Keep credentials and device evidence private.

## Migration is a release gate

The current local Mac install is unsandboxed; TestFlight is sandboxed. Shipping
an arbitrary local `.app` risks making users' existing data appear missing.
Prefer the sandboxed layout for the direct release and explicitly test:

- Fresh installation, permissions and Google sign-in.
- Replacing a TestFlight installation without losing local state or credentials.
- Moving from the existing local unsandboxed installation, with an explicit,
  tested data migration if required; no silent reset or overwrite.
- CloudKit production sync, meal-photo scanning, notifications and WeatherKit.
- Updating one direct release to the next, including app relaunch.

The repo now has a separate direct Mac target, Sparkle integration and local
DMG/notarization tooling. Developer ID identities are present in the local keychain;
a G2 Developer ID certificate was available, and the production distribution profile
has now been created and validated. Production provisioning and notarization passed;
installation and live service acceptance remain open.

## References

- [Apple: Developer ID and supported capabilities](https://developer.apple.com/developer-id/)
- [Apple: notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Sparkle documentation](https://sparkle-project.org/documentation/)
- [Sparkle sandbox integration](https://sparkle-project.github.io/documentation/sandboxing/)

## Implemented local release tools

`BananaMacDirect` shares the native Mac target template and adds Sparkle 2.10.1.
Only that target links Sparkle. It uses the sandboxed production entitlement set
plus Sparkle's installer service exceptions. `Check for Updates…` appears in the
app menu. Sparkle handles update consent, download, Ed25519 validation and installation;
automatic checks and installation are on by default, with saved opt-outs preserved. TestFlight and local daily-driver targets
keep their existing settings.

### Local rehearsal

`tools/mac-distribution/build.sh test` builds **Banana Installer Test**, a separate
bundle and sandbox with no production cloud/service configuration or URL handlers.
It requires `BANANA_UPDATE_FEED_URL` and `BANANA_UPDATE_PUBLIC_KEY` in the environment.
Use a separate test signing seed, stored outside the repository with mode 0600.
The test app is ad-hoc signed, not notarized, and is not a public release.

`tools/mac-distribution/package.py APP --test --test-version 1|2 --out DIRECTORY
--base-url URL --sparkle-bin SPARKLE_BIN --key-file TEST_SEED` creates the DMG,
checksum, appcast and release metadata. Two rehearsal packages deliberately use the
same executable with increasing bundle versions, testing delivery rather than a
code change. Keep the feed pointing to build 2 while installing build 1.

Open the build-1 DMG, drag **Banana Installer Test** to Applications, open it, then
choose **Check for Updates…**. The name and sandbox keep it separate from Banana.
Verify download/install/relaunch, build 2 in About, and retained test data. Also test
cancel/retry and interrupted downloads. Do not connect real accounts during this
packaging rehearsal. Ad-hoc artifacts may require an explicit macOS local-test
security override; do not disable Gatekeeper globally.

Native interactive installation checks are manual while the owner is using the Mac.
A generated DMG and valid signature alone do not prove installation or migration.

### Production build and hosting

1. Provision the existing app identifier for **Developer ID Application**, covering
   iCloud, WeatherKit and production push. Set `BANANA_DEVELOPER_ID_PROFILE` and
   `BANANA_DEVELOPER_ID_IDENTITY`; keep values in private configuration.
2. Generate the production Sparkle key with `generate_keys --account banana-direct`.
   Back up its private key securely. Use its public key as `BANANA_UPDATE_PUBLIC_KEY`
   and `https://bananatheapp.com/updates/mac/appcast.xml` as `BANANA_UPDATE_FEED_URL`.
3. Run `tools/mac-distribution/build.sh release`. This archives and exports using
   Developer ID. Credentials and logs stay private. It does not install or publish.
4. Run `package.py` without `--test`, with `--notary-profile` and `--identity` (or
   their `BANANA_NOTARY_PROFILE` / `BANANA_DEVELOPER_ID_IDENTITY` environment settings).
   `--base-url` must name the exact versioned GitHub release asset directory. The
   command notarizes/staples the app and DMG, checks Gatekeeper, signs the update,
   and writes the feed and checksum. A failure stops packaging; never publish a
   partial output directory. Use an empty output directory for each release.
5. After local acceptance and release approval, upload `Banana.dmg` and its checksum
   to a versioned GitHub Release. Keep the same filename within every release.
   Do not point to `latest`, which might select a mobile release or prerelease.
6. Run `stage-site.py --release RELEASE_DIR --out PRIVATE_REVIEW_DIR`. It downloads
   and hashes the public asset before writing `/download/mac` (302) and the update
   feed into a copy of the site. It rejects local-test packages. Review the landing
   page download CTAs alongside that staged site; this command never deploys.

GitHub hosts the large versioned binaries; Cloudflare continues hosting the small
landing page, redirect and appcast. Promotion is an explicit feed/redirect update.
An older redirect can be restored, but an installed newer app is not downgraded by
Sparkle: ship a corrected build with a higher version to fix a bad update.

Checks: `python3 -m unittest discover -s tools/mac-distribution -p 'test_*.py'`.
Production migration and clean-Mac Gatekeeper acceptance remain release gates.

For a repeatable local run, set `SPARKLE_BIN` to the downloaded Sparkle 2.10.1 tools
and `BANANA_TEST_BASE_URL` to the Tailscale preview URL ending in `/updates/test`,
then run `tools/mac-distribution/rehearse.sh`. The script creates a separate test
Ed25519 seed once (outside the repository), builds, packages versions 1 and 2, and
points the feed at version 2. It refuses to overwrite existing installer artifacts;
choose a fresh `BANANA_TEST_OUTPUT` and matching base URL for a new rehearsal.

### Gatekeeper-compatible local rehearsal

Use `package.py --test --notarize-test --identity IDENTITY` to sign and notarize
the isolated test app and its DMG. This re-signs Sparkle's helper services and
framework from the inside out, enables hardened runtime, and removes the test-only
library-validation exception. A Developer ID provisioning profile is not required
for this isolated app because it carries no restricted cloud/push entitlements.
Production still requires a capability-covering profile.

Authenticate notarization with `--notary-profile`, or with `ASC_KEY_PATH`,
`ASC_KEY_ID` and `ASC_ISSUER_ID` from private configuration. The latter avoids
storing new Keychain credentials in a noninteractive session. Gatekeeper acceptance
of both the app and disk image is required before the signed update feed is written.
Do not advertise an ad-hoc local test as a normal downloadable installer.

`rehearse.sh` now defaults to Developer ID signing and notarization. Set the
identity and notarization credentials above before running it. Only use
`BANANA_ADHOC_TEST=1` for deliberate development tests that cannot pass Gatekeeper.


### Automatic updates

Direct Mac builds now default to automatic checks and automatic download/installation.
Sparkle checks on launch (if enabled) and every six hours, prepares updates in the
background, and installs on normal app termination. The app never forces a quit to
apply an update. Sparkle may request authorization if the install location requires it.
Settings → About → Updates exposes separate check/install toggles and a manual check.
Existing saved choices override the defaults, including an opt-out from earlier tests.

The automated `AutomaticUpdateSettingsCheck.swift` uses the pinned Sparkle settings
implementation with a disposable bundle/defaults domain to verify defaults, interval,
opt-out persistence and re-enabling. It never launches the app or contacts a feed.
For the local end-to-end rehearsal, the original feed offers build 3; build 3 uses
an automatic-test feed offering build 4. This requires one manual update from the
older manual-only builds, then tests background download and installation on quit.
Builds 3 and 4 use the same executable with different build numbers. Verify the
installed build after reopening; feed/signature checks alone do not prove auto-install.


## Production preparation evidence

The current production archive exports with the same bundle identifier, team,
primary keychain access group, CloudKit container, and production push environment.
`verify-release.py` validates profile grants and update configuration before packaging.
The app and DMG passed notarization, stapling, and Gatekeeper assessment.

The native container migration manifest is included only in `BananaMacDirect`.
Its explicit file list is mirrored by `app-support-roots.json`; it never imports the
whole shared Application Support directory. The background-only native fixture proves
first-container migration, no repeat import, and no migration into an existing container.
It also verifies importing preferences into an existing sandbox domain without
restarting the preference daemon or opening a window.

When both a local and a TestFlight store exist, choosing the source is required.
`migration.py --bundle-id BUNDLE --source local|sandbox --out PRIVATE_DIRECTORY`
prepares both verified snapshots and preference exports, with backup exclusion and
private permissions. It requires Banana to be stopped, refuses source changes and
symlinks, and validates staged SQLite databases including WAL contents. It does not
change live stores. Preserve both snapshots before any actual migration; never merge
unrelated SQLite files or overwrite an existing store merely because it is older.

The website now contains the approved screenshot/lightbox layout, direct Mac CTA,
versioned redirect and appcast. `publish.sh` verifies the hosted DMG checksum before
deploying download links. This intentionally fails while the GitHub release is a draft.
Publication still requires the final source commit, migration acceptance, and live
Google sign-in, CloudKit, push, Photos and WeatherKit checks in the installed real app.
