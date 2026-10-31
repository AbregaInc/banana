# Whole-repository publication candidate

Status: **technical candidate prepared for owner review; repository remains private**.
Scope: complete native clients, service/browser app, website, shared code, build
inputs, tests and tooling. This does not authorize Apple submission or blog publication.

## What is prepared

- GPL-3.0-only native/shared code and AGPL-3.0-only service/browser code, with full
  licence texts, package metadata, path scopes and third-party notices.
- Exact observed Swift package pins outside the generated Xcode project; complete
  notices for all eleven Swift packages and the three service dependencies.
- The bundled converted voice model's upstream MIT notice, pinned licence-source
  URL and unchanged artifact hashes. The original conversion revision is not
  invented or inferred from that licence-source revision.
- Six original synthetic sample covers with editable SVG sources; previous real
  podcast cover files are kept privately, not in the source candidate.
- Owner-specific sample address domains replaced consistently with reserved example
  domains, including associated parser/security/reply fixtures and design examples.
- A public, unauthenticated `/source` page and `/v1/source` metadata endpoint on
  service, app and booking hosts. Browser/shared views and booking pages link to
  source; HTTP responses advertise the source page too. Configuration must name
  the exact deployed commit and an anonymous HTTPS archive, not a moving branch.
- Security/contact, contribution and trademark policies; a concrete proposed
  official-Apple-build distribution policy for owner review.
- Broader ignore rules for local environment files, signing material, agent state
  and test-result bundles; example environment templates remain eligible for Git.
- A private whole-source export that preserves original history and evidence.
  Generated Apple submission material, internal raw captures/logs and the
  unapproved blog draft are omitted. Run narratives, failures, performance
  baselines, fixtures and the article's full matched sample arrays remain.
  `PUBLICATION-PROVENANCE.json` records source/output hashes and omission reasons.

## Validation completed

| Check | Result |
| --- | --- |
| Mac client build, placeholder configuration, no personal local config | Passed, unsigned; executable and debug dylib are arm64-only; no app launch/install |
| iOS and embedded Watch Simulator build-for-testing | Passed with placeholder configuration and the retained dependency pins |
| Existing native tests after sample-domain cleanup | 385 affected cases: 384 passed initially; one stale search-title expectation was corrected and its 10-case class passed. An additional standalone parser run passed all 75 cases; no live mailbox access |
| Full service test files, synthetic principals, fake Google/APNs, external network denied | 292 passed in UTC and 292 passed in America/New_York, each file isolated in a fresh bounded process |
| Public demo on canonical test iPhone Simulator | 5 passed: entry/exit, calendar editing, notes/meals persistence, read-only/reset, failed-save retry |
| Source access and web/booking regression after final shell change | 36 focused cases passed |
| Source link layout in signed-in/signed-out shells | 375/768/1440 widths checked headlessly, no horizontal overflow; controls remain in their existing header |
| Image metadata inspection | All candidate image files decoded; EXIF contained dimensions/orientation/resolution and screenshot markers, no GPS/author/date tags found; historical raw mockup/marketing captures omitted |
| Data resources | Food database schemas are product/nutrition data; metadata queries found no user paths or email values; test data/Apple-compressed fixtures are synthetic |
| Evidence integrity | All four matched calendar timing arrays and summaries preserved; headline calculation remains 95.0509145→38.215936 ms, 59.794% reduction; no performance baseline or budget changed |
| Documentation/licence checks | Package/lock licence agreement, exact GNU AGPL text, eleven package revisions/notices, local documentation links, Python/shell syntax and whitespace checks passed |

Native/Simulator checks establish functional/build evidence, not physical-device
frame delivery, 120 Hz acceptance or every product workflow. No fresh calendar
optimization or benchmark result is claimed. The article retains its historical
scope and unfinished performance goals.

The affected native run exposed an existing stale search-title expectation from
the earlier email integration. History confirmed that the implementation had
deliberately changed to “Search results.” The test now checks that title and
separately checks the “Mail” fallback. Its ten-case class passed after correction;
the original failed result bundle remains available. No application behavior,
performance scenario or budget was changed for this correction.

The first combined in-process service run hit the 512 MiB memory watchdog; its
failure log is retained. Repeating the standard per-file isolation with one
bounded process at a time passed both time zones. Native build setup also exposed
an inherited Git fsmonitor pipe hold and a temporary build-database lock; those
failed attempts were retained, resolved serially, and followed by successful builds.

The first UI wrapper invocation auto-linked the owner's private local configuration
through the existing development helper, after placeholder binaries were built.
That ignored link stayed private. It was removed, and `BANANA_NO_LOCAL_CONFIG=1`
now skips both local-config discovery and release-environment loading, refusing
an existing local config rather than silently using it. Guard tests passed; built
Mac/iOS plists were checked for example bundle IDs and empty personal team,
Google client, service and legacy-cloud values. The strict clean-mode rerun passed all five cases; its result bundle is
retained separately. Stable public BGTask identifier strings are not personal config.

Private result bundles, raw logs, source manifests and scan/triage records remain
in the owner's `PublicationAcceptance-20261028` and `PublicationReview-20261028`
log directories. Build outputs may be cleaned under repository policy; sources,
original history, installed-build symbols and this evidence are preserved.

## Secret/privacy review

Gitleaks 8.30.1 scanned all locally reachable original history (1,145 nonempty
commits, about 638 MB) and the dirty working candidate (about 532 MB). The 13 historical
and 12 current generic-key findings were inspected as storage/SQL identifiers or
synthetic test markers. No credential was confirmed among those findings; no live
credential validation or production penetration test was performed. No broad
scanner suppression was added. This does not claim the absence of every secret.

The original inventory included 404 path-bearing files, 602 device-identifier
candidate files, 166 email-shaped candidate files and 329 binaries. These were
candidates, not counts of disclosures. The whole-source candidate omits internal
raw archives/captures, normalizes local display paths in documentation and physical
IDs there, and removes private device fields from the public matched comparison.
Code/fixture identities and metric values are not globally rewritten.

The frozen whole-source tree was scanned separately from build/cache directories.
Both its fresh Git history and working tree produced the same twelve inspected
storage-key/synthetic-marker findings; none introduced a confirmed credential.
The final privacy pass also removed two hard-coded physical-device IDs from the
profiling tool/example. The tool still requires an explicit physical-device UDID
and matching Instruments device identity; no trace or measurement was regenerated.
Existing whitespace in the imported source is recorded separately; this preparation
does not reformat the entire application. `tools/publication/review.py` and
`tools/publication/prepare.py` record exactly what was scanned/exported.

## Owner decisions before publication

1. Review the exact candidate and approve the source licences, brand scope and
   [official distribution policy](official-distribution-policy.md). Confirm the
   authority for grants over original material; upstream licences cannot be changed
   by this policy. External contributions remain closed until their rights
   arrangement supports official distribution. Legal review remains appropriate
   where ownership/distribution permissions are uncertain; none is claimed here.
2. Choose whether to publish a fresh whole-source repository or retain history.
   The prepared private candidate is history-free. The original repository/history
   remains intact and private. Do not simply change the old repository's visibility:
   old covers, raw captures, other refs and Actions history would also be exposed.
3. Approve the public repository identity and exact release commit. Only after
   source is anonymously downloadable should the service's source settings be
   generated with `tools/publication/source-offer-env.py` and deployed.
4. Keep GitHub performance workflows disabled/manual-only as requested; enable
   appropriate public-repository secret protection when creating the approved repo.
   Original private Actions logs/releases are not part of the exported source tree.
5. Review and approve blog publication and Apple submission separately. Neither
   happened during this preparation. No physical-device/Main/Beta install occurred.

## Repeating preparation

See [the tool guide](../../tools/publication/README.md). Use a new private scan
output directory outside the source checkout. A private export can be refreshed
in place with `prepare.py --refresh`; it never rewrites the original history.
Do not delete failed evidence, regenerate reference output, or loosen budgets to
obtain a pass. Public source must match the distributed/deployed revision.
