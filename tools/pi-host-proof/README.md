# Pi Durable Apple host

The integrated Banana Assistant and a standalone proof app run upstream Pi Durable inside native JavaScriptCore on Mac, iPhone and iPad. See [app integration](../../docs/research/PI-APPLE-APP-INTEGRATION.md) for the usable Assistant and its checks. The host supplies missing platform APIs and native SQLite. Banana capabilities use Pi's public extension API. The proof app does not load Banana services or user stores.

Upstream is pinned to `earendil-works/pi` commit `ede2c9b468d8e061c557d16957513715e6d49cd6`. `generate.py` refuses a different commit or tracked modifications in the four upstream packages it bundles. No Pi scheduler, recovery, registry, history or storage implementation is replaced.

## Integration boundaries

| Responsibility | Integration |
|---|---|
| Banana tools | Public `defineExtension` / `defineTool`, installed on `createRegistry()` |
| Local inference | Public Pi AI provider registration through `createModels().setProvider()`; native Apple Foundation Models and the upstream faux provider for deterministic recovery tests |
| Durable state | Upstream `SqliteStorage.open(database)` over the native `SqliteDatabase` facade |
| JavaScript runtime | Shared `AppleRuntimeHost.swift`, JavaScriptCore, platform bootstrap |
| Execution and recovery | Unchanged upstream `Harness` |
| Foreground/background lifetime | `ApplePiSession` using public `onWake`, `wake()`, `resume()` and `close()` |

A JavaScriptCore bootstrap supplies the execution environment; this cannot be a Pi extension because it must exist before Pi imports execute. The SQLite facade implements the existing public backend contract. Application tools and model support belong in extensions/providers, with no special cases added to the core. Lifecycle scheduling now uses Pi's wake hooks; the adapter controls runtime lifetime and foreground wake delivery.

`runtime/entry.js` demonstrates the extension boundary with one native `banana_probe` tool. Its synchronous `nativeDouble` function is a test capability. Model inference uses the asynchronous, cancellable `nativeModelStart`/`nativeModelCancel` bridge.

## Apple Foundation Models provider

`runtime/apple-provider.js` registers `apple-foundation/on-device` through Pi's public `createProvider` API. It uses upstream transcript replay helpers for system/tool updates, preserves message roles and tool-call IDs, maps text/tool events into the Pi event protocol, and rejects unsupported images, reasoning blocks and generation settings. The native backend always selects `SystemLanguageModel.default`; there is no cloud fallback.

`AppleFoundationModel.swift` constructs a fresh native session from each Pi request. Pi remains the source of conversation history. Native `IntentOnlyTool` declarations have schemas but no application implementations: their `call` throws a private sentinel. Apple's documented tool-error escape returns control to the adapter, which extracts generated tool intents from the native transcript and returns them as Pi tool calls. Only Pi's registered extension then executes the capability. On OS 27, the session explicitly preserves its transcript on errors; if the framework discards intent, the adapter fails instead of executing anything. Native text preceding a tool intent is preserved too. The next generation reconstructs the transcript with Pi's committed tool results; after a tool result, a public OS 27 `LanguageModelExecutor` adapter removes the extra empty user turn that `respond(to:)` would otherwise append, then forwards the unchanged request/channel to `SystemLanguageModel.Executor`. This preserves Pi’s tool-result continuation without an invented user request. Sending the empty turn to the model caused repeated read calls in the integrated iPad app; the real-model regression now covers this boundary.

Schema translation currently accepts objects with named required/optional properties, arrays, strings/string enums, numbers, integers and booleans. It rejects unions, references, patterns, numeric constraints and explicitly open additional-properties schemas. Unsupported keywords fail before inference. This deliberately limited subset avoids silently weakening schemas; Pi also validates actual arguments before tool execution.

Responses are buffered per native generation and emitted as complete Pi content blocks, not token-by-token native streaming. Token usage is unreported (zero), not estimated. On-device availability and context size are probed from the native model. Cancellation rejects the JS request, cancels its Swift task and ignores late completion; host shutdown cancels pending tasks. The upstream `Models` wrapper classifies a pre-aborted auth/setup operation as `error`; the provider classifies cancellation reaching generation as `aborted`. Core behavior is retained and covered by the contract tests.

The app deployment target remains iOS 26.1; the Assistant requires iOS/iPadOS/macOS 27 for correct tool continuation through the public executor API and preserved tool intent. Older systems show an explicit availability message. Runtime results cover the OS versions listed in the reports.

## Shims and contracts

- Pinned `core-js` supplies URL, URLSearchParams, DOMException, structuredClone and microtask scheduling.
- Pinned `@kayahr/text-encoding` supplies streaming TextDecoder; the TextEncoder wrapper fixes the encoding to UTF-8 as required by the Web API.
- Pinned `abort-controller` supplies event dispatch and abort idempotence. A small host adapter adds reason, throwIfAborted, any and timeout.
- Native timers, a monotonic clock, secure random bytes and error reporting come from Foundation, Dispatch and Security.
- `runtime/database.js` serializes operations around native SQLite transactions, revokes escaped transaction handles, rolls back failures and preserves typed values across the bridge. SQLite uses WAL, synchronous NORMAL and a busy timeout. This is process-interruption recovery evidence, not a power-loss guarantee.

The package lock pins build and runtime dependencies. These are focused compatibility adapters with tested contracts, not a claim of complete browser compatibility. In particular, very long abort timeouts inherit the timer clamp, and abandoned `AbortSignal.any` listeners are removed when a source aborts. Networking/fetch, the CLI, optional Codemode/WASM, forced expiration and OS-scheduled background delivery are outside this proof.

## Build and verify

Install dependencies once in both checkouts:

```sh
(cd ../pi-upstream && npm ci --ignore-scripts)
(cd tools/pi-host-proof/runtime && npm ci --ignore-scripts)
. tools/config.sh require
python3 tools/pi-host-proof/generate.py ../pi-upstream
python3 tools/pi-host-proof/run-mac.py
python3 tools/pi-host-proof/run-mac.py --mode provider-conformance
python3 tools/pi-host-proof/run-mac.py --mode foundation-text
python3 tools/pi-host-proof/run-mac.py --mode foundation-roundtrip
python3 tools/pi-host-proof/run-mac.py --mode foundation-interruption
python3 tools/pi-host-proof/run-mac.py --mode lifecycle-conformance
python3 tools/pi-host-proof/run-mac.py --mode lifecycle-roundtrip
xcodegen generate --spec tools/pi-host-proof/project.yml
xcodebuild -project tools/pi-host-proof/PiHostProof.xcodeproj \
  -scheme PiHostProof -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath .build/sim \
  -allowProvisioningUpdates build
```

This uses existing development signing, universal iOS device families and an iOS 26.1 deployment target. The configured bundle ID ends in `.pi-host-proof`. Generated resources/project and compiled products are disposable build output. The Mac runner deletes its temporary binary and databases when it finishes.

Connect and unlock an explicitly selected device, install, then run:

```sh
xcrun devicectl device install app --device DEVICE_UDID \
  .build/sim/Build/Products/Release-iphoneos/PiHostProof.app
python3 tools/pi-host-proof/run-device.py DEVICE_UDID iphone
python3 tools/pi-host-proof/run-device.py DEVICE_UDID iphone --modes provider-conformance foundation-tool foundation-reopen
python3 tools/pi-host-proof/run-device.py DEVICE_UDID iphone --modes foundation-crash-first foundation-crash-reopen
python3 tools/pi-host-proof/run-device.py DEVICE_UDID ipad --modes lifecycle-conformance lifecycle-first lifecycle-reopen
python3 tools/pi-host-proof/run-lifecycle-device.py DEVICE_UDID ipad
python3 tools/pi-host-proof/run-handoff.py DEVICE_UDID --label ipad
```

Use `ipad` as the tablet report label; `--bundle` accepts a different configured prefix. `--modes host-conformance` runs only the adapter checks. The process command has a 100-second timeout, the Python subprocess 110 seconds, file copies 45 seconds, and the app self-test 90 seconds. Each run uses fresh database identities and validates copied result JSON, not just launch success.

The six default launches cover memory tool execution and request deduplication; a SQLite first run; a fresh-process reopen with zero tool reruns; a native effect followed by abrupt exit 42; unsafe-tool recovery with zero reruns and an interrupted result; and 41 conformance checks. Those comprise 15 host checks and all 26 cases from upstream `createStorageConformance`, executed over real file-backed SQLite. The optional provider mode runs 11 more contract checks, including an actual Pi harness tool loop with a scripted native transport, cancellation and the Swift schema translator. `foundation-text` and `foundation-tool` use the real on-device model. `foundation-reopen` must follow `foundation-tool` in the same device-runner invocation and verifies zero inference/tool reruns. Mac `foundation-roundtrip` does both in separate processes with one temporary database. Mac `foundation-interruption` and the separate mobile `foundation-crash-first foundation-crash-reopen` invocation test abrupt interruption with real inference; use a separate invocation so its fresh database does not contain the already completed tool submission. Chai is bundled only to run this development validation.

Five additional lifecycle contracts cover shared activation, rapid close/open, cleanup after wake-write failure, native inference cancellation and foreground wake delivery. The lifecycle fresh-process pair advances a controlled epoch clock to test the stored sleep checkpoint. The separate device runner uses real UIKit callbacks and real device time, briefly opening Settings and returning to the proof; it changes no settings. The [lifecycle report](../../docs/research/PI-APPLE-LIFECYCLE.md) records the verified behavior and remaining OS scheduling/expiration coverage.

The handoff runner moves a closed SQLite store from iPad to Mac and back. It proves byte-preserving read-only views and one delivery on the destination with the original task ID. The runner supplies exclusive ownership by waiting for each writer to exit. It does not provide automatic synchronization or fencing; see the [handoff report](../../docs/research/PI-APPLE-HANDOFF.md).

Machine-readable results and console transcripts are retained in `docs/research/pi-apple-host-results`. See the accompanying results report for which device/build actually passed. Controlled exit is not SIGKILL or power loss. Automatic cross-device ownership/synchronization, OS-scheduled background delivery, forced-expiration coverage remain work. Production Notes/day-plan capabilities and the app UI are covered by the [app integration](../../docs/research/PI-APPLE-APP-INTEGRATION.md). The standalone proof app keeps this integration separate from Banana's production user stores.

Run `tools/clean-builds.sh` when finished. Sources and evidence stay; no simulator is required.
