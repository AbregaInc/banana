# Local assistant and email builds

Current cross-platform consolidation and rollout plan: [Banana Cloud, feature access and release channels](CLOUD-AND-RELEASE-PLAN.md) (4 November 2026). Implementation status and acceptance criteria are tracked there.

Main can contain experimental code without putting it into TestFlight. The build switches are
compile-time settings, not preferences or remote flags:

| Build setting | Enabled | Disabled |
| --- | --- | --- |
| `BANANA_LOCAL_AI` | `BANANA_AI`: assistant UI, engine, capabilities and runtime resources | No assistant engine/UI or runtime resources |
| `BANANA_LOCAL_EMAIL` | Existing `BANANA_UNRELEASED` email compilation gate | `BANANA_PUBLIC`: email implementation excluded |

Both inherit `BANANA_UNRELEASED` for compatibility with local install scripts. Release defaults
to `NO` on production and ordinary Beta Release targets. The explicit `TestFlight`
configuration includes gated Email and excludes AI; see [feature access](FEATURE-ACCESS.md).
Debug and PiDevelopment opt in locally. Either switch
can be overridden independently on ordinary targets; PiDevelopment requires AI enabled.
Standalone unit-test bundles explicitly enable both implementations, including in Release;
they are not embedded in the distributed app.
The native editor validation/receipt types shared with ordinary event and food flows remain
available without the assistant. Existing transcription and food capture are separate features.

Local examples:

```sh
# Existing local install scripts explicitly opt into unreleased functionality.
# Individual flags can also be supplied to xcodebuild:
xcodebuild -project Banana.xcodeproj -scheme BananaMacBeta -configuration Debug \
  -derivedDataPath .build/mac-check BANANA_LOCAL_AI=YES BANANA_LOCAL_EMAIL=NO build
```

Public builds use `BANANA_LOCAL_AI=NO BANANA_LOCAL_EMAIL=NO`. Saved module choices cannot expose
email or the assistant when their build gate is off. `tools/local-feature-resources.sh` copies
AI resources only when enabled and removes stale runtime resources when switching a build
folder back to public. Local builds carry a resource marker naming their enabled features.

Every application target rejects Archive (`ACTION=install`) with local AI enabled. Email is
allowed only for the primary app identity with `BananaReleaseChannel=testflight`;
Stable and Dev archives reject it. Archives run `tools/check-release.sh` against the built
application. The Mac TestFlight script uses this configuration; public Release excludes both.
The checker rejects Pi runtime/entry points and assistant binary markers in every channel;
Gmail scopes/endpoints and Email markers also fail outside TestFlight. It checks the primary app,
so a nested TestFlight bundle cannot authorize a Stable archive. A saved preference cannot bypass
compile-time exclusion or the authenticated runtime eligibility gate.

Run `tools/tests/local-feature-gates.sh` to test resource inclusion, stale cleanup, archive
rejection and binary-marker checks. Also build the production Release and local PiDevelopment
configurations after changing these gates. A passing simulator build is not a signed App Store
archive or a TestFlight upload.

## Validation, 3 November 2026

- Production `BananaMac / Release` and `Banana / Release` (iOS Simulator) builds passed.
  Their application bundles passed the release scan, including four executables in the iOS bundle.
- `BananaMacPi / PiDevelopment` and `BananaPi / PiDevelopment` builds passed with both features on.
  Their copied resources matched the sources, and the release checker rejected both local apps.
  It also rejected the local Mac native binaries without their resource markers.
- Resolved Xcode build settings confirmed both features off for all four Release app targets,
  and on for the two Pi schemes. This is a settings check for the Beta Release targets, not a
  separate Beta Release compilation.
- Resource/invalid-flag/stale-cleanup/archive/binary guard tests passed; 24 native assistant
  query, fixture, calendar-identity and inference-transport tests passed.
- No signed distribution archive or TestFlight upload was made. Local Mac installation was updated.

Local verification logs: `.build/feature-public-mac-check.log`,
`.build/feature-public-ios-check.log`, `.build/feature-local-mac.log`,
`.build/feature-local-ios.log`, `.build/feature-native-tests.log`, `.build/feature-settings.json`.
The public compile-check products were removed after scanning; installed local-build symbols remain.
