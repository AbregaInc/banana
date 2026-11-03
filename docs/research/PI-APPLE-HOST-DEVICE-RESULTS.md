# Pi Durable Apple host results

Current 25 October status: [broader app integration](PI-APP-INTEGRATION.md), [engine/model selection and reproducible evaluation](PI-INFERENCE-SELECTION.md). The dated results below retain their original scope.

Date: 23 October 2026. Upstream: `earendil-works/pi`, commit `ede2c9b468d8e061c557d16957513715e6d49cd6`. Xcode 27.1. Separate `Pi Host Proof` app, Release, iOS deployment target 26.1.

| Target | Contract checks | Real local model + extension tool | Completed fresh-process reopen | Interrupted unsafe-tool recovery |
|---|---|---|---|---|
| Mac; macOS 27.0.1 | PASS: 57 | PASS: 2 model generations, 1 native tool execution | PASS: 0 model/tool calls | PASS: interrupted result, 1 model generation, 0 tool executions |
| Physical iPad Pro 12.9-inch, 5th generation; iPadOS 27.0.1 | PASS: 57 | PASS: 2 model generations, 1 native tool execution | PASS: 0 model/tool calls | PASS: interrupted result, 1 model generation, 0 tool executions |
| Physical iPhone 15 Pro Max; iOS 27.0.1 | PASS: 52 | PASS: 2 model generations, 1 native tool execution | PASS: 0 model/tool calls | PASS: interrupted result, 1 model generation, 0 tool executions |

Each target ran actual JavaScriptCore, native SQLite and Apple's on-device `SystemLanguageModel.default`. The model selected `banana_probe(value: 21)` and consumed its returned result to answer 42. Reopening a completed submission did not run inference or repeat the capability. Request deduplication held. These are focused smoke runs, not a model-quality benchmark or an assertion that every Pi feature works.

## Evidence

| Target | Host/storage checks | Provider checks | Real tool loop | Completed reopen | Interrupted recovery |
|---|---|---|---|---|---|
| Mac | [41 checks](pi-apple-host-results/mac-host-conformance.json) | [11 checks](pi-apple-host-results/mac-provider-conformance.json) | [result](pi-apple-host-results/mac-foundation-tool.json) | [result](pi-apple-host-results/mac-foundation-reopen.json) | [result](pi-apple-host-results/mac-foundation-crash-reopen.json) |
| iPad | [41 checks](pi-apple-host-results/ipad-host-conformance.json) | [11 checks](pi-apple-host-results/ipad-provider-conformance.json) | [result](pi-apple-host-results/ipad-foundation-tool.json) | [result](pi-apple-host-results/ipad-foundation-reopen.json) | [result](pi-apple-host-results/ipad-foundation-crash-reopen.json) |
| iPhone | [41 checks](pi-apple-host-results/iphone-host-conformance.json) | [11 checks](pi-apple-host-results/iphone-provider-conformance.json) | [result](pi-apple-host-results/iphone-foundation-tool.json) | [result](pi-apple-host-results/iphone-foundation-reopen.json) | [result](pi-apple-host-results/iphone-foundation-crash-reopen.json) |

The 41 host/storage checks cover UTF-8 streaming and malformed input, structured cloning, URLs, cancellation, timer ordering, monotonic time, microtask error reporting, secure random validation and typed SQLite binding/rollback/isolation. All 26 cases from upstream `createStorageConformance` run unchanged against real file-backed SQLite. The 11 provider checks cover public registration/event ordering, tool execution through Pi, system/tool updates, unsupported inputs/options, toolChoice none, cancellation, failures and native schema conversion. Provider contract tests use a scripted transport; the separate real-tool rows above use actual Apple inference.

## Lifecycle and controlled device handoff

Mac and physical iPad also pass five lifecycle contracts, bringing their total to 57. A separate fresh-process pair persists a sleeping task, closes, advances an explicitly controlled epoch clock and reopens at its delivery checkpoint. The physical iPad's real UIKit test backgrounds the proof by opening Settings, verifies zero Pi-owned databases/timers/model requests and zero delivery calls, crosses the real deadline while backgrounded, then foregrounds and delivers exactly once. It changes no Settings values.

Evidence: [Mac lifecycle contracts](pi-apple-host-results/mac-lifecycle-conformance.json), [Mac fresh-process reopen](pi-apple-host-results/mac-lifecycle-reopen.json), [iPad lifecycle contracts](pi-apple-host-results/ipad-lifecycle-conformance.json), [iPad fresh-process reopen](pi-apple-host-results/ipad-lifecycle-reopen.json), [iPad paused resources](pi-apple-host-results/ipad-lifecycle-paused.json), [iPad real UIKit result](pi-apple-host-results/ipad-lifecycle-live.json). Phone live transitions and lifecycle contracts were collected before the user redirected all further device work to iPad; its corrected fresh-process sequence has not been rerun. Details and limitations are in the [lifecycle report](PI-APPLE-LIFECYCLE.md).

A controlled iPad → Mac → iPad transfer also passes: the source closes before export, a Mac read-only view preserves the database hash and rejects writes/scheduling, Mac becomes the sole writer and delivers the original task once, and iPad reads the returned completed store with no phase reruns and an unchanged completed-store hash. [Handoff evidence](pi-apple-host-results/ipad-mac-handoff.json) and the [handoff report](PI-APPLE-HANDOFF.md) distinguish this orchestrated closed-store transfer from automatic ownership or synchronization.

## Interruption method

The [device runner](../../tools/pi-host-proof/run-device.py) launches fresh processes and checks result JSON copied from the app's Documents directory. Each invocation uses a fresh database identity. For interruption, the native tool writes an effect marker and calls `exit(42)` after Pi commits tool intent but before the result commits. Recovery must expose Pi's interrupted-tool result and execute the native capability zero times. The real model then reports the interruption rather than inventing a successful result.

Recorded boundaries and effects: [Mac console](pi-apple-host-results/mac-foundation-crash-first.console.txt), [Mac effect](pi-apple-host-results/mac-foundation-effect.txt), [iPad console](pi-apple-host-results/ipad-foundation-crash-first.console.txt), [iPad effect](pi-apple-host-results/ipad-foundation-effect.txt), [phone console](pi-apple-host-results/iphone-foundation-crash-first.console.txt), [phone effect](pi-apple-host-results/iphone-foundation-effect.txt).

CoreDevice has reported both exit 0 and exit 42 for this native exit path. The runner accepts those launcher return codes only when the exact boundary log and process-termination message are present, then verifies the saved effect and recovery. This is a controlled abrupt process exit, not SIGKILL or power loss. WAL uses synchronous NORMAL; power-loss durability is not established.

## Scope

No tracked upstream implementation files in `packages/durable`, `packages/ai`, `packages/chord` or `packages/telemetry` were changed. The bundler checks the reviewed commit and a clean diff before building. Banana tools use public `defineExtension` / `defineTool`; the Apple provider and SQLite backend use public contracts. Pi still owns execution, persistence, deduplication and recovery. The [provider report](PI-APPLE-FOUNDATION-PROVIDER.md) explains the capture-only native tools that preserve this boundary.

The universal iOS device build passed. An earlier simulator compile passed; no simulator execution is claimed. No simulator is reserved by this work. Earlier faux-provider baseline results remain in the evidence folder as historical checks, distinct from the current Foundation Models runs linked above.

The proof app is separate from Banana and does not load its user stores. The subsequent [app integration](PI-APPLE-APP-INTEGRATION.md) adds production UI, real Notes/day-plan capabilities and iPad simulator checks. Automatic cross-device ownership/synchronization, OS-scheduled background delivery, forced-expiration coverage, full Web API compatibility and OS 26 runtime coverage remain work. No Apple submission was performed. Reproduction commands and supported adapter behavior are in the [host README](../../tools/pi-host-proof/README.md).
