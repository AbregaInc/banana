# Banana Assistant integration

Current 25 October status: [broader app integration](PI-APP-INTEGRATION.md), [engine/model selection and reproducible evaluation](PI-INFERENCE-SELECTION.md). The dated results below retain their original scope.

24 October 2026. Pi is now embedded in Banana’s iOS, iPadOS and Mac app targets. The app runs the pinned upstream JavaScript engine in JavaScriptCore, uses native SQLite for Pi state, and invokes Apple’s on-device model through a registered Pi provider. No upstream core source was modified.

## User flow and capabilities

On iPad or Mac, choose Assistant in the sidebar. On iPhone, choose More → Assistant from a main page. The five phone tabs stay intact. Assistant has persistent conversations, conversation switching, cancellation, history pagination, context summarization and a confirmed delete-all action that retains created Notes. Message drafts and an unacknowledged input outbox survive relaunch. Drafts and selected conversation IDs are excluded from Banana’s portable settings backup because that backup does not include the local Pi database; a restore preserves the receiving device’s own Assistant state. Pi admits retried input with a stable request ID.

The `banana` extension registers `list_notes`, `read_note`, `create_note` and `day_plan` through public `defineExtension` / `defineTool`. It reads Banana’s actual stores, not a second assistant copy. Written notes appear in the normal Notes store. The day-plan tool reports its calculation timestamp and timezone; it rejects unloaded or out-of-horizon data. It never claims an unloaded plan is empty. Read outputs are bounded, with truncation/has-more metadata.

Note creation atomically persists the normal notes.json file before publishing the note or starting cloud upload. A Pi-memoized operation UUID deduplicates the same native operation while that note still exists. Pi’s mutation replay policy remains `unsafe`: a crash between native execution and result commit produces Pi’s interrupted result instead of blindly repeating a write. This is not a claim of exactly-once behavior after arbitrary user edits/deletions or power loss.

## Runtime and model boundaries

`Banana/Pi/AppleRuntimeHost.swift` and `AppleFoundationModel.swift` are shared with the proof app. Production includes no exit/crash test hook. `tools/pi-host-proof/runtime/app.js` is the application extension and command entry point. `ApplePiSession` owns only host lifetime; upstream Harness owns execution, history, submissions, checkpoints, tool replay and recovery.

The registered provider returns one model generation to Pi. Native capture-only tools throw a private sentinel before any application capability executes; Pi then validates, journals and executes its registered tool. Native model tasks and native capability tasks are canceled when their Pi invocation is canceled. SwiftUI renders committed Pi records instead of keeping another chat history.

The real iPad app test exposed a continuation bug hidden by the single-tool proof: a new empty native user turn after a committed tool result induced repeated note reads. The fix uses Apple’s public `LanguageModel` / `LanguageModelExecutor` boundary: remove only that appended empty continuation turn, preserve request options/metadata/tool definitions and pass the channel directly to Apple’s `SystemLanguageModel.Executor`. This leaves Pi unchanged and lets Apple continue directly from the original tool result. An attempted explicit continuation prompt also failed and was discarded. No arbitrary turn limit or special termination after a note write was added.

Apple documents the public [LanguageModelExecutor](https://developer.apple.com/documentation/foundationmodels/languagemodelexecutor) and [SystemLanguageModel.Executor](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/executor) boundaries used here. The exact signatures were checked in Xcode’s installed Swift interfaces and compiled on both platforms.

The Assistant therefore requires iOS/iPadOS/macOS 27, although the rest of Banana retains its existing deployment targets. Older systems show an explicit availability message. There is no cloud inference fallback. Responses are buffered per native generation; token usage is unreported. Additional inference engines can register Pi providers at this same boundary. The host sets a 1,024-token response budget (bounded by the reported model context size), reserves that budget in Pi’s public compaction settings, and divides the remaining context between recent messages and a summary. Background compaction is disabled so summary and answer generation do not compete for the same local model. Pi still selects the range, persists the summary, handles overflow and resumes generation; no compaction implementation was replaced. Apple context-size errors map to the standard provider overflow marker understood by Pi.

## Lifecycle and device data

UIKit backgrounding closes the harness under a short background assertion, joins/cancels native work and closes SQLite. Foregrounding reopens the same database and lets Pi recover. Background assertion expiration stops native resources; forced-expiration coverage remains outstanding. Durable work resumes when the OS lets the process run; this does not promise continuous inference while iOS suspends the app or scheduled background delivery.

Each device currently has its own local Pi database. Automatic conversation synchronization and writer ownership transfer are not implemented. The separate controlled iPad → Mac → iPad proof demonstrates closed-store transport and read-only views; it is not an automatic product handoff. Live SQLite files must not be put into a generic file-sync mechanism.

## Isolated iPad installation

Scheme `BananaPi`, configuration `PiDevelopment`, builds the full BananaBeta target with its own `com.boris.banana.pi-development` bundle identity and display name **Banana Pi**. It uses `Application Support/Banana Pi`, disables cloud services and calendar write-back, and does not replace main/Beta. Its normal launch opens the app shell; diagnostic launch arguments select the Assistant directly. Production main/Beta use the same Assistant UI/runtime with their normal app stores and services. Scheme `BananaMacPi` applies the same isolated configuration to BananaMacBeta, with its own `.mac.pi-development` bundle ID and local data directory. It does not migrate the production Mac defaults. Headless Mac verification starts from App initialization, so a hidden/locked desktop cannot prevent its checks from starting; normal launches still enter Assistant through the UI.

The bundled runtime resources, notices and upstream SHA manifest are checked in under `Banana/Pi/Resources`. Xcode app builds need neither Node nor the upstream checkout. Regeneration checks the exact reviewed upstream SHA and a clean diff in the bundled upstream packages; the manifest hashes both generated bundles. Third-party licence text includes the packages actually bundled.

## Verification

The iPad simulator suite covers the app shell entry, conversation restoration and selection, note effects across relaunch, stop after background/foreground, history deletion retaining notes, in-flight process recovery and context summarization. The summary test requires a committed summary marker, rather than accepting a no-op. These use the upstream faux provider to make lifecycle assertions deterministic; they do not claim simulator Apple inference.

The isolated physical iPad app check uses real local Apple inference and the actual native Notes store. It verifies a single saved note, final model reply, native read/list visibility, persisted note identity, native operation deduplication and cold runtime reopening with identical committed history and no repeated effect. The extended check also grows a real-model conversation past the configured threshold and checks that automatic Pi compaction preserves a secret word from the first turn. It deletes only its uniquely identified synthetic test note afterward.

A separate integrated-app device check uses real UIKit transitions (opens Settings without changing any value), checks that all Pi-owned database/timer/model resources close in the background, and resumes the same conversation. Its deterministic waiting model permits checking one committed native note effect, foreground cancellation and the next input without relying on inference timing.

Physical XCTest itself failed before executing tests with “Timed out while enabling automation mode”; it is not recorded as a pass. Direct app verification and UIKit transitions use devicectl and do run on the actual iPad. The phone was not touched after the user requested iPad focus.

Current results:

| Check | Result |
|---|---|
| Real Mac app, Apple local model: create/read, persistence, deduplication, cold reopen, automatic compaction and recall | [PASS](pi-apple-host-results/mac-app-integration.json) |
| Real iPad app, same real-model checks | [PASS](pi-apple-host-results/ipad-app-integration.json) |
| Real iPad integrated UIKit lifecycle, closed resources, effect once, stop and next input | [PASS](pi-apple-host-results/ipad-app-lifecycle.json) |
| Native JavaScriptCore host/storage, provider and lifecycle contracts | 57 PASS on Mac; earlier physical-device results are in the host report |
| Native abrupt-effect interruption/recovery | PASS; zero unsafe tool re-executions |
| iPad simulator Assistant scenarios | All seven scenarios pass across the runs; the later run had one system event-synthesis timeout during typing, and the focused rerun passed that scenario plus the strengthened summary case |
| Phone simulator More → Assistant | 1 PASS |
| Credits, chrome rules, shell navigation, cloud eligibility unit checks | 34 PASS |
| Backup rules, including Assistant state staying with its local database | 6 PASS |

The failed simulator attempt reached the input field and then timed out inside XCTest event synthesis before sending the message. It is retained as a failure, not folded into a claim of one clean final suite run. The serial UI runner now also enforces a hard per-case/startup deadline because XCTest’s own allowance did not stop that hung operation. Targeted reruns use a process-scoped idle-sleep assertion; no persistent power setting is changed.

Machine-readable results are retained in [the evidence folder](pi-apple-host-results/). The earlier [host](PI-APPLE-HOST-DEVICE-RESULTS.md), [lifecycle](PI-APPLE-LIFECYCLE.md) and [controlled handoff](PI-APPLE-HANDOFF.md) reports describe the lower-level checks separately.

Reproduction after `. tools/config.sh require` and `xcodegen generate`:

```sh
python3 tools/pi-host-proof/generate.py ../pi-upstream
xcodebuild -project Banana.xcodeproj -scheme BananaPi -configuration PiDevelopment \
  -destination 'generic/platform=iOS' -derivedDataPath .build/sim -allowProvisioningUpdates build
SCHEME=BananaBeta UI_TEST_TARGET=BananaAgentUITests WORKERS=1 tools/ui-tests.sh pad AssistantUITest
python3 tools/pi-host-proof/run-app-lifecycle-device.py IPAD_UDID ipad
caffeinate -i python3 tools/pi-host-proof/run-app-mac.py
```

No App Store/TestFlight upload or Apple review submission is part of this work.

## Normal iPad launch regression, 24 October

A normal launch of the installed Pi build exposed a missed path: RootView waited on `initialRestoreCheckFinished`, while the local Pi configuration intentionally never starts the production restore service. The previous Assistant checks used preview/onboarding overrides and therefore did not cover this gate.

PiDevelopment now enters the local app shell without production first-run onboarding or cloud restore. Its root scene lifecycle updates visibility without starting production account/cloud services. Main and Beta startup policies are unchanged.

`PiLaunchUITest` runs only in the PiDevelopment test configuration, with no launch arguments, preview mode, fake model or onboarding overrides. It verifies a fresh launch, navigation into Assistant and a second normal launch. The fixed build was installed on the physical iPad and launched with no arguments; the [device screenshot](pi-apple-host-results/ipad-normal-launch.png) confirms the app shell and Assistant sidebar are visible without “Checking iCloud…”.

## Verification-data and response-quality regression, 24 October

User testing exposed that the normal app reopened the long compaction-test conversation. That thread repeatedly instructed the model to reply only “OK” and supplied the secret word Blueberry; it was unsuitable for judging ordinary assistant behavior. Existing conversations are preserved because the user has added real messages to them.

Real-model acceptance runs now select `Application Support/Banana Pi Verification` before any app store initializes. They use separate Assistant selection/draft keys, and the view is labelled “Assistant verification”. Normal launches continue using `Banana Pi`. The Mac and device runners compare normal Assistant database files, selection and draft before/after acceptance. Both checks pass without modifying normal data.

An additional fresh-chat check also caught unnecessary day-plan/notes lookups for “Hello”. The Banana extension instructions and tool descriptions now distinguish greetings/general conversation from requests for app data, require useful retrieval answers rather than an “OK” acknowledgement, and distinguish remembering chat context from an explicit note-save request. No Pi core code or scheduler behavior changed.

The strengthened real-model acceptance passes on Mac and physical iPad: a fresh “Hello” produces a greeting with zero tools, and “Show my latest notes” invokes the notes capability and describes the actual saved test note. The failing pre-fix example is retained in `pi-apple-host-results/mac-app-quality-before-instructions.json`. Existing chat history is not rewritten; a new conversation provides a clean test of the new behavior. These focused checks are not a general guarantee of model quality across arbitrary requests.
