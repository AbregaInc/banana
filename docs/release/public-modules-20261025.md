# Public module presentation — 25 October 2026

Owner approved item 1 of the review follow-up. Main iPhone/iPad/Mac settings and onboarding
list only available modules, without Beta/Coming soon badges. Email stays compiled out of the
public app and is no longer listed. Separate Banana Beta retains all five modules and Beta
labels. Saved choice names, module data, sync and enablement semantics are unchanged.

Candidate 80; private evidence: `~/Library/Logs/Banana/ReleaseModules80-20261025/`.
Source commit `ec80d3d2`. Focused Settings/onboarding UI checks pass **4/4** and existing
module model contracts pass **10/10**, with no failures or skips. The model checks cover public
and Beta availability/labels and retention of saved choices. Both signed archives pass strict
signing and Email-exclusion checks. Both uploaded, processed VALID, and are selected in the
iOS and Mac drafts. Final API readback confirms **80 / VALID / MANUAL /
PREPARE_FOR_SUBMISSION**, with nonexempt encryption false on both. No review endpoint was
called. Reviewer Gmail and explicit owner approval to submit remain outstanding.
Both draft descriptions and matching review-note policy were updated/read back. Generated
metadata is synchronized and the asset/metadata validator passes; five asset-contract tests pass.
No public or new TestFlight review submission is authorized. No new reviewer walkthrough or
video is in this scope. Existing performance limitations and deferred physical iPad checks
remain recorded in the earlier launch-preparation report.

Normal 80 is installed and read back on the primary iPhone and iPad after their initial
connections reset; the reconnected installs were performed over the existing apps. Mac normal
80 is installed with its existing non-sandboxed entitlements/data path, passes strict signing
and was not auto-launched. Separate Beta remains 79, with its unchanged Email/Beta-label policy.
Watch remains 79: its developer connection is unavailable, so no replacement was forced.
No physical iPad XCTest was resumed. The Settings screenshot was inspected and added to the
Tailscale review gallery; existing marketing captures keep their actual original provenance.

All simulators are shut down. Main's exclusive resource window was released early for Pi
lightweight/one-job work, without extending the 09:17:55 EDT inference hold. A final notice
released the entire window after the universal Mac archive finished. Source/model workspaces
were preserved. `tools/clean-builds.sh` removed simulator and Mac-check intermediates after
retaining results privately; signed archives and installed-product symbols are preserved.
