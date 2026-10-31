# Preparing a source release

These tools never change repository visibility, deploy, submit to Apple, rewrite
history or modify the original performance baselines.

## Private review

`review.py --output /new/private/directory --include-untracked` makes a private
snapshot and redacted current/history secret-scan reports. It requires Gitleaks.
Privacy candidates need inspection; a scanner exit code is not publication approval.

`prepare.py --output /new/private/candidate` prepares the complete application and
service source, with dependency pins, build tools, fixtures and licence notices.
Original history and raw evidence remain in the private working repository.
Generated Apple submission material, unapproved blog drafts and internal raw
captures/logs are omitted. Run narratives, including failures, remain; the matched
article comparison retains every timing sample. Only display metadata is normalized.
`PUBLICATION-PROVENANCE.json` records inclusion/omission reasons and hashes.

Use `--refresh` only on the recognized private candidate. It reuses that source
directory and leaves unchanged files/builds alone. Omitted derived copies are
removed from the candidate while their originals remain in the private source.
Nothing becomes public merely because a candidate has been prepared.

## Reproducible checks

Generate the native project and restore `Config/Package.resolved` as described in
the root README. Use placeholder configuration, without `Config/Local.xcconfig`.
For helper scripts, use `BANANA_NO_LOCAL_CONFIG=1` to prevent discovery of the
owner’s home-directory developer/release configuration. It refuses an existing
local config; use an unconfigured checkout rather than deleting someone’s file.
Build native Mac apps for arm64 only. Use `.build/mac-check` for Mac checks and
`.build/sim` for Simulator builds/tests, reusing them between attempts.

For an unsigned Mac compile (no install or app launch):

```sh
xcodebuild -project Banana.xcodeproj -scheme BananaMac -configuration Debug \
  -destination 'generic/platform=macOS' -derivedDataPath .build/mac-check \
  -jobs 1 ARCHS=arm64 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

For the native demo checks, select an existing **test** Simulator first; the
wrapper resets that selected Simulator. It never installs on a physical device:

```sh
xcrun simctl list devices available
BANANA_NO_LOCAL_CONFIG=1 SIMULATOR_UDID='<existing-test-simulator-uuid>' WORKERS=1 BUILD_JOBS=1 \
  tools/ui-tests.sh phone DemoModeUITest
```

Run `npm ci` and `npm test` in `Service/` using the pinned Node release. Its tests
use synthetic principals and fake Google/APNs ports. Do not regenerate protocol
fixtures, benchmark references or budgets to obtain a passing result.

`calendar-evidence.py` reproduces the article's preparation-work calculation from
the retained comparison. It does not run a benchmark or establish FPS/latency.

## Source offer and final release

Freeze the exact candidate in a private review commit and verify it is clean.
Publication/deployment still requires the owner's approval of that candidate.
`source-offer-env.py --repository https://github.com/OWNER/PUBLIC-REPO` prints the
service's revision-pinned source settings. It refuses an uncommitted source tree.
Make that archive publicly accessible before using the settings for an AGPL
deployment. Verify `/source` and `/v1/source` without credentials after deployment.

Do not change the existing private repository's visibility merely because a
sanitized branch exists: other refs, old media and Actions history would also
need review. A fresh public repository can receive the reviewed whole-source
snapshot while the original development history remains private.
