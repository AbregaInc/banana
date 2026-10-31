# Native sample-data mode

## Entry and data boundaries

On iPhone, iPad and Mac, choose **Try with sample data** on the welcome page or in Settings → About. No Google account is required. The visible Demo banner remains while the sample workspace is open. Exit demo returns to the existing personal workspace without completing onboarding or enabling personal modules.

The sample workspace persists its edits locally. **Demo options → Reset sample data** explicitly discards only these edits. A corrupt file is reported and preserved until that reset; a failed save retains the editor and can be retried. Calendar visibility, meal times, note archives, routines and reminders are sample values, independent of personal settings.

Storage is `Application Support/Banana Demo/SampleData-v1/workspace.json` (the separate Beta uses `Banana Beta Demo`). The directory is excluded from device backup and is outside the application's allowlisted cloud-backup and SpaceSync datasets. All demo commands go through a dedicated actor and an atomic file write before success is published. No demo command accepts a service URL, token, production store or native integration. The normal personal application's existing background services may continue while the demo is presented; demo actions do not modify their data or settings.

This is a disclosed sample workspace, not a fake Google session. It does not request Google, notification, Health, microphone or photo permissions. Invitations, notifications and Health/Watch recordings are never sent by the demo provider. Sample narration uses the system speech synthesizer and the app's own text, rather than downloading third-party media.

## Coverage

The same sample fixture and typed command model back the public demo, repository tests and replay scenarios. Shared production pieces include `MealEntry` and macro scaling, `VoiceNote`, `FitnessSession`, workout pause calculations, the live filter parser, calendar lane allocation and artwork, the native iOS/AppKit calendar viewport, and the note text editor.

The demo has its own navigation and editors. Calendar recurrence is limited to daily and weekly series; series edits affect every occurrence. It supports local event creation/editing/deletion and calendar visibility; iOS also uses the native event-movement surface. It includes reminder/routine completion, manual food logging and past-meal reuse, meal-time editing, notes/drafts/archives, workout and sleep charts, a clearly labeled simulated workout, and system-voice sample narration.

This does **not** exercise normal Google writes, invitations, sharing/deduplication, network sync, Health/Watch capture, photo or AI nutrition estimation, actual podcast streaming/seeking, or every normal-app editor and filter capability. These retain their own correctness and end-to-end tests. Simulated workout and narration must not be presented as evidence that their live counterparts passed.

## Reproducible checks

`tools/demo-tests.sh models` runs the deterministic repository/scenario tests. `tools/demo-tests.sh ui phone` runs the demo entry, editing, failed-save retry, read-only availability, reset and relaunch flows through `tools/ui-tests.sh`. `tools/demo-tests.sh ui pad` uses the canonical iPad simulator. Outputs default to a uniquely named run under `~/Library/Logs/Banana/DemoTests`; build products reuse `.build/sim`. Run these serially with other simulator work and do not take a simulator in use by another agent. The wrapper lists available simulators, records memory/swap and bounds the entire process; it does not change baselines or budgets.

The model scheme currently defaults to Release but has unrelated DEBUG-only fixture references in `PackagePhotoTests` and `ShellNavigationTests`. The wrapper explicitly uses Debug instead of changing public build flags. A separate Release compile still checks that public demo entry and code ship without test-only arguments.

`DemoScenario` is a versioned Codable record containing a fixed clock, IANA time zone, `review` or `empty` seed, and typed `DemoCommand` values. Construct it in a test, serialize with `JSONEncoder`, then replay with `DemoScenarioRunner.replay(_:in:io:)`. The caller owns an isolated `SampleData-v1` test directory. Use stable IDs in commands to make interrupted/repeated runs idempotent. The runner rejects unsupported versions/time zones, mismatched restored clocks, and oversized command lists. Tests cover serializing/replaying a plan-food-notes sequence twice without duplicate records.

For example, a test can persist the same command sequence for later replay:

```swift
let scenario = DemoScenario(
    name: "complete-reminder",
    clock: Date(timeIntervalSince1970: 1_792_929_600),
    timeZone: "America/New_York",
    commands: [.completeTask(DemoFixtures.id(10), true)]
)
let bytes = try JSONEncoder().encode(scenario)
let restored = try JSONDecoder().decode(DemoScenario.self, from: bytes)
let result = try await DemoScenarioRunner.replay(restored, in: isolatedSampleDirectory)
XCTAssertTrue(result.workspace.tasks[0].completed)
```

UI tests still tap the real public entry. Debug-only arguments `--demo-test-session <UUID>` and `--demo-test-clock <ISO8601>` select a fresh temporary profile and fixed New York clock. `--demo-empty` chooses the empty fixture when a test clock is provided; `--demo-save-failure` fails the first user write once after successful initial seeding. Arbitrary paths and service URLs cannot be supplied. None of these launch arguments is compiled into Release.

## Native-framework choice and performance

Foundation Codable/atomic writes and a dedicated actor provide persistence and injected failure behavior. SwiftUI presentation keeps the personal object graph intact, while the existing UIKit/AppKit calendar collection hosts retain native rendering/reuse. Point-Free's maintained MIT `swift-dependencies` library was considered; adding it alone would not isolate the existing singleton-based production services. Constructor injection of the demo repository is sufficient for this scope and avoids pretending that a global mode flag safely redirects those services.

References: [SwiftUI EnvironmentValues](https://developer.apple.com/documentation/swiftui/environmentvalues), [Foundation FileManager](https://developer.apple.com/documentation/foundation/filemanager), [swift-dependencies](https://github.com/pointfreeco/swift-dependencies).

No performance improvement is claimed. Component results, native input/frame evidence and functional demo checks are separate. The persistent component gate on 25 October returned **unmeasured** because installed Xcode 27.1 differs from the checked-in Xcode 27.0 reference; that failure is retained. No baseline, workload or budget was changed. Simulator functional passes cannot establish 120 Hz or physical-device input latency.

## Apple review hold

Public submission and beta review submission remain on the owner's review hold. A demo is not an automatic exemption from providing reviewer access. Before relying on it instead of credentials, obtain Apple's agreement and disclose the limits above. The review draft should identify **Try with sample data** on the welcome page, explain reset/exit, and separately explain how live integrations are available in the normal app. This implementation does not resolve Google's account-creation policies or establish that Apple will accept the alternative.
