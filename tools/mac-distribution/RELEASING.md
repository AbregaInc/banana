# Mac releases

Keep one current public installer. Keep lightweight Git tags, release notes, source
commits and checksums as history. Do not overwrite an asset at an existing versioned
URL: a cached Sparkle feed binds that URL to a specific signature and byte length.

## Identity

- User version: `1.0.1` (major/minor/patch).
- Update ordering: a monotonically increasing integer, for example `87`.
- Source: full Git commit embedded in `BananaSourceCommit` and release metadata.
- Tag: `mac-v1.0.1-87`, pointing to that exact source commit.
- Release notes: display the date and short commit alongside the user version.

Commit hashes identify code but cannot order updates. Commit counts can go backwards
between branches. The planner chooses a build greater than project.yml and all Mac
release numbers it can see, including drafts and local tags. Run one release at a
time; a plan is not a server-side reservation. Fetch tags before planning, and check
for a competing release before creating the draft. Never reuse a shipped build.

## Prepare, test, promote

1. Commit the intended changes and checks. Use a clean checkout; preserve unfinished
   work in its existing workspace. The currently installed rehearsal build came from
   a dirty tree, so the first public release must be rebuilt from committed source.
2. Prepare a plan (read-only GitHub access; this creates no remote release):

   ```sh
   git fetch origin --tags
   python3 tools/mac-distribution/release-plan.py --version 1.0.1 \
     --out private/mac-distribution/next-release.json
   export BANANA_RELEASE_PLAN="$PWD/private/mac-distribution/next-release.json"
   tools/mac-distribution/build.sh release
   ```

   Supply the existing signing/profile/feed settings described in
   `LandingPage/MAC-DOWNLOAD.md`. The builder uses the plan's version/build/commit and
   checks the clean checkout again after export. It never installs or publishes.
3. Package using `package.py` and the plan's `baseURL`. Notarization, Gatekeeper and
   update signing must pass. Retain dSYMs for installed builds before build cleanup.
   Test the candidate, including an actual upgrade from the previous direct build
   and data/account retention. A fixture test is not live acceptance.
4. Push the reviewed source through the private-text pre-push guard, create an
   annotated tag at `sourceCommit`, and push that tag through the same guard.
   Create a GitHub **draft** with `gh release create --verify-tag --draft`, attaching
   `Banana.dmg` and its checksum. Use a notes file; include version, build, source
   commit and user-facing changes. The immutable tag must match the embedded commit.
5. After candidate acceptance, publish the draft, verify the public DMG checksum,
   stage its appcast/redirect with `stage-site.py`, review and deploy the website.
   The feed contains only the current full installer. Verify the deployed feed and
   `/download/mac` resolve to the new signed artifact before retiring any old one.

## Retention

Ordinary upgrades download the full app; they do not need intermediate installers.
Older installed apps can jump directly to the latest compatible build. No deltas
or mandatory intermediate migrations are currently part of this release pipeline.

- Website: only the current release is offered.
- GitHub: retain the previous DMG for 24 hours after the new feed is live to allow
  cached update checks and in-flight downloads to finish. Then remove only its DMG
  asset, retaining the tag, notes and checksum. Never prune the current release,
  unaccepted drafts, another platform's assets, or an installer still in a live feed.
- If a future release raises the minimum OS/architecture or requires an intermediate
  migration, retain the last compatible/required installer and its matching feed item.
- Local build/export/rehearsal binaries can be cleaned after acceptance. Keep symbols
  for installed builds and signing keys. User-data migration backups and workspaces
  are separate from downloadable release retention and must not be swept by it.

If a public build is bad, release a correction with a **higher build number**, even
when reverting to earlier source. Do not move a tag, replace signed asset bytes, or
expect Sparkle to downgrade an already updated installation.

References: [Sparkle publishing and build numbering](https://sparkle-project.org/documentation/publishing/).

## Installer appearance

Production packaging uses `dmgbuild==1.6.7` (MIT; build-time dependency) to write
Finder metadata without controlling Finder. `dmg-settings.py` positions the real
app and Applications link over the branded background, hides toolbars, and badges
this volume with the existing app icon. Test-rehearsal packages keep their plain layout.

Edit `artwork/background.html`, then run
`uv run tools/mac-distribution/render-background.py`. Commit both generated PNGs:
`dmgbuild` combines the standard and `@2x` images into a Retina TIFF. Typography
and colors come from the landing page; the app icon is never repainted into the
background. Native Finder continues to supply the interactive icons and labels.

A packaging-only design change still produces different signed DMG bytes. Never
replace the current public asset in place: include the design in the next numbered
release, notarize the new DMG, and promote its new signature and checksum together.

## Beta direct downloads

`BananaMacBetaDirect` shares the existing Beta sources and identity. It includes
feature-gated Email, excludes local AI and test fixtures, and uses the staging
service. It preserves Beta's unsandboxed local storage; no stable data is imported.
Developer ID requires production push and the Production database of the separate
Beta CloudKit container. Local development builds can use a different CloudKit
environment; this installer does not migrate between those databases.

Prepare with `release-plan.py --channel beta --version VERSION --out PLAN` and
build with `BANANA_DISTRIBUTION_CHANNEL=beta`, the Beta Developer ID profile and
`BANANA_UPDATE_FEED_URL=https://bananatheapp.com/updates/mac-beta/appcast.xml`.
The update signing key must match the embedded public key. The same notarization,
profile coverage and signature checks apply. Publish as a GitHub prerelease with
`--latest=false`, tagged `mac-beta-vVERSION-BUILD`. Stage with `stage-site.py`;
it writes only `/download/mac-beta` and `/updates/mac-beta/`. Stable stays on its
own feed. Retention is one current full installer **per channel**, with the same
24-hour grace for superseded downloads.

The first Beta installer adds Sparkle to existing local Beta builds. It cannot
update those older builds automatically because they have no updater; install the
DMG once. Subsequent direct Beta releases use this feed. A first release cannot
prove a future live upgrade; report that acceptance separately from signing and
feed validation.
