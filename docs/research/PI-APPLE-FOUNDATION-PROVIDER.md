# Pi provider for local Apple inference

The standalone Apple host now includes an actual on-device Foundation Models provider. It is registered through public Pi `createProvider` / `createModels().setProvider()` APIs. No tracked upstream core files changed, and no production Banana code changed. Upstream remains pinned to `ede2c9b468d8e061c557d16957513715e6d49cd6`.

## Verified on Mac, iPhone and iPad

On macOS 27.0.1, iPhone 15 Pro Max with iOS 27.0.1 and iPad Pro 12.9-inch (5th generation) with iPadOS 27.0.1, in actual JavaScriptCore and native Foundation Models:

- A separate real local generation on Mac completed through Pi Durable and returned a greeting.
- The real model selected `banana_probe(value: 21)`; Pi executed the registered extension tool once; the model consumed the returned result and answered 42. Two model generations, one native capability execution.
- A new process reopened the same SQLite database and submission, with zero model generations and zero native tool executions. Request deduplication held.
- A separate real-model run exited 42 inside the native capability after recording an effect marker. A fresh process recovered Pi's unsafe-tool interruption, ran the native tool zero times and used one real model generation to report that the tool may have partially run. It did not invent a successful tool result.
- All 11 new provider contract checks passed, as did the existing 15 host checks and 26 unchanged upstream storage conformance cases.

Evidence: [local generation](pi-apple-host-results/mac-foundation-text.json), [real tool loop](pi-apple-host-results/mac-foundation-tool.json), [fresh-process reopen](pi-apple-host-results/mac-foundation-reopen.json), [abrupt exit](pi-apple-host-results/mac-foundation-crash-first.console.txt), [native effect](pi-apple-host-results/mac-foundation-effect.txt), [interrupted recovery](pi-apple-host-results/mac-foundation-crash-reopen.json), [provider contracts](pi-apple-host-results/mac-provider-conformance.json), [host/storage contracts](pi-apple-host-results/mac-host-conformance.json). These are individual smoke runs and focused contract checks, not statistical model-quality evaluations.

The [device results table](PI-APPLE-HOST-DEVICE-RESULTS.md) links each of these checks for the physical iPhone and iPad too. Both passed the real tool loop, completed reopen, interrupted recovery and all 52 contract cases.

## How tool execution stays durable

Apple's standard session can execute tools and continue generation internally. Putting Banana capabilities directly into that loop would let them run before Pi records its tool-execution intent. This adapter instead supplies schema-only native tools whose `call` throws a private sentinel before doing any work. The documented tool-error escape stops Apple's loop. The adapter extracts the generated calls and IDs from the native transcript and emits ordinary Pi tool-call events. Pi then records intent, invokes the `defineExtension` / `defineTool` capability and commits its result using its existing machinery.

On OS 27, the temporary native session uses `.preserveTranscript` on errors. If tool intent is missing after the capture error, the adapter fails closed. Non-capture errors propagate as provider errors. The adapter reconstructs each native session from Pi's current history; it does not maintain a second durable conversation or its own recovery loop. Pi's public transcript helpers apply system sections and tool additions/removals.

Apple references: [tool calling and escaping tool errors](https://developer.apple.com/documentation/foundationmodels/expanding-generation-with-tool-calling), [native transcript](https://developer.apple.com/documentation/foundationmodels/transcript). Exact API signatures were also checked against the installed Xcode 27.1 Swift interfaces and compiled for iOS 26.1.

## Boundaries still to verify

The iOS universal device build and physical-device execution pass. The app still compiles with an iOS 26.1 target. The integrated Assistant explicitly requires OS 27, where the public model executor permits correct continuation without an extra user turn. See the [app integration](PI-APPLE-APP-INTEGRATION.md) for the subsequent real-app finding and fix.

This first provider supports text and a restricted JSON Schema subset. Unsupported schemas/modalities fail explicitly. Native generation is buffered, token usage is unreported, and model reasoning controls are unavailable. There is no Private Cloud Compute fallback. Long contexts surface native model errors rather than silently dropping history. Multi-tool batches and OS 26 error-transcript retention need focused live checks before broader support is claimed.

The subsequent [lifecycle work](PI-APPLE-LIFECYCLE.md) verifies graceful background/foreground transitions and checkpoint reopening, and the [handoff work](PI-APPLE-HANDOFF.md) verifies a controlled closed-store iPad → Mac → iPad transfer. Automatic cross-device ownership/synchronization, OS-scheduled background delivery, remain separate work. Asynchronous native application capabilities and production Banana UI integration are now implemented; see the [app integration report](PI-APPLE-APP-INTEGRATION.md). The proof capability doubles a number and does not access Banana user data. No Apple submission is part of this work.

Reproduction commands and the exact compatibility boundaries are in the [host README](../../tools/pi-host-proof/README.md).
