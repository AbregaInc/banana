# Dimensional brand rollout — build 82

Owner approved the dimensional Default mascot on 27 October 2026. The approved
raster is canonical; the prior flat masters are retained under `Brand/Legacy`.
`python3 tools/app-store/brand.py` exports native, store, website and cloud assets.

## Deployed

- Website: `ee6390fc-5f82-4d60-b948-878ebf209eec`.
- Production cloud: `42cc3e39-34f4-47a8-a210-74463440c401`.
- Beta cloud: `26dc3469-a7a1-49ba-9a58-4289aff5ae39`.
- Mac main and Beta: signed build 82 installed; both verified arm64 only.

Live website/cloud asset downloads matched local exports. Header logos use compact
192px exports and `dimensional82` cache URLs. Before cloud deployment, both remote
worker bundles matched the clean baseline; worker changes are limited to two
branding cache keys and the public booking footer/favicon artwork. Unrelated
pending service changes were excluded.

Booking pages had a separate old pixel logo. Their generated 48px inline raster
serves a 16px footer and favicon without another request. Existing booking-page
and booking-flow tests pass 61/61 in UTC and 61/61 in America/New_York, including
the unchanged first-load budget. A controlled `notFound()` render changes from
13,675 to 23,760 HTML bytes and from 4,277 to 8,655 gzip bytes; this is an explicit
artwork cost, not a performance improvement. Both live booking environments were
checked for the exact generated image data.

## Watch tinted rendering

Full-color complications use the circular 100px RGBA icon. Accented/vibrant modes
use a feature-shaped alpha template with transparent background and pupils,
raised eyebrow and simplified smile. SwiftUI explicitly renders it as a template;
the watch face chooses the accent. This avoids an opaque disc in red/black mode.

`AppStore/Generated/brand/WatchRedBlackPreview.svg` is a controlled tint preview,
not an actual Watch capture. Physical Night Mode validation is outstanding. The
owner's devices were initially unavailable. The iPhone and Watch later appeared
paired, but CoreDevice rejected secure service assertions with error 4016. The
iPhone installation did not start, and the Watch status request failed. Neither
is claimed updated; the iPad remained unavailable. The unrelated reachable spare
phone was left untouched.

## Distribution gates

Signed iOS/embedded-Watch and sandboxed arm64 Mac archives and local exports
succeeded. Public-release executable gates passed. The separate iOS Beta build 82
also compiled and passed signature verification. Development profiles include the
owner's iPhone, iPad and Watch. The public archives' native source is `09f55521`;
subsequent booking artwork and test-harness changes do not alter production Swift
or native assets.

The full ordinary phone UI run completed in 75m50s: **248 passed, 3 failed,
23 skipped**. The failures were test setup/assertion defects:

- Demo return expected Food to be off despite a previous class's personal module
  choice. It now compares the actual selection before and after sample mode.
- The width test's landscape event search oscillated around its target before any
  width measurement. It now uses actual native viewport bounds and a bounded pan
  ending at rest when an hour anchor is supplied. The intermediate bounds-only
  attempt still failed (5 passed, 1 failed); that run is retained.
- The native Week scroll benchmark failed its required starting-hour admission
  before measurement. Its setup now uses bounded positioning; fixtures, measurement
  gestures, iterations, assertions and budgets are unchanged.

The second focused run passed **7/7**, including all three originally failed cases.
The shared-caller run passed **25/26** and exposed a regression in unanchored cue
search after the slow-pan change. Exploratory searches without a supplied hour
retain their original scrolling gesture; all five affected tests then passed
**5/5**. No scenario or failed result was discarded. `functional-release-gate.json`
checks exact caller coverage, passing repairs for every failure, unchanged native
source since the archives and unchanged test limits/baselines. This is a combined
functional gate, not a claim that the initial full run was clean.

The persistent component gate returned **unmeasured** because Xcode 27.1 differs
from its Xcode 27.0 reference; Xcode is the only environment mismatch. No baseline
was changed and no rendering/input latency or 120 Hz acceptance is claimed.

Both App Store Connect uploads completed and both builds are **VALID**. The iOS
and Mac unpublished drafts now select build 82, remain `PREPARE_FOR_SUBMISSION`,
and retain `MANUAL` release. Tester notes were saved and both builds assigned to
the existing Banana Public Beta group with `--no-submit`. Read-back reports
`IN_BETA_TESTING` internally and `READY_FOR_BETA_SUBMISSION` externally on both
platforms. Internal testers have access; external distribution still needs its
separate Apple beta review submission. Draft review access instructions now explain
the tested native sample-data entry, disclose the limits of simulated integrations,
and require no Google demo credentials. Tester notes and checked-in TestFlight
materials are synchronized. No review submission was created under the owner's
review hold. Direct device installation and physical Watch appearance
remain pending because of the connection failure described above.

Public Apple submission remains on owner review hold. Neither a public review
submission nor a new beta review submission is authorized by this rollout.

Private build logs, deployed bundle comparisons, installed architecture checks and
exports are recorded under `~/Library/Logs/Banana/BrandRollout-20261027/`.
