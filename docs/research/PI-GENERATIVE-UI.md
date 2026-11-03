# Conversational interfaces that evolve into interactive views

Research date: 24 October 2026. Proposal only; no new UI framework, model, or app behavior installed by this research.

## Finding

The useful pattern for Banana is a conversational workspace with persistent, interactive views. Language chooses what to show; native components render it; later language and direct manipulation update the same state. This can replace navigation through many fixed screens while retaining charts, lists, calendars, and editors when they are useful.

“Feedback” has three distinct meanings here: a follow-up instruction changes a view; a tap or edit changes the same view directly; an explicit preference may affect future views. None requires retraining model weights on every interaction. Long-term preferences should not be inferred from every temporary filter.

## What people are building

| System | Mechanism and feedback loop | Relevance to Banana |
| --- | --- | --- |
| Claude interactive visuals | Inline charts and diagrams can change as the conversation develops. | Useful product precedent for a conversation becoming visual. The announcement does not establish the internal implementation. |
| Tambo | Registered React components have typed props. Interactable components expose current props and update tools, allowing clicks and language to modify the same instance. | Strong reference for bidirectional interaction; its React SDK is not a SwiftUI dependency. |
| A2UI | Declarative component structure and separately bound data; incremental updates and user actions. | Closest protocol candidate for native rendering with an agent-independent boundary. |
| Vercel json-render | An application-defined catalog constrains generated JSON specs, components, and actions; streaming and state bindings update the rendered interface. | Useful catalog and patching design. Its documented renderers include React Native, not a maintained SwiftUI renderer. |
| MCP Apps | Tools supply HTML UI resources rendered by the host in sandboxed iframes, with a bridge for tool calls and context updates. | Useful for interoperable embedded applications; it does not itself supply native SwiftUI rendering. |
| AG-UI | An event protocol carries agent lifecycle, messages, and state snapshots/deltas. | A transport/state layer, rather than a component layout language or replacement for Pi's durable execution. |

Primary references: [Claude announcement](https://claude.com/resources/articles/claude-builds-visuals), [Tambo interactables](https://docs.tambo.co/concepts/generative-interfaces/interactable-components), [A2UI binding](https://a2ui.org/concepts/data-binding/), [json-render source README](https://github.com/vercel-labs/json-render), [MCP Apps overview](https://apps.extensions.modelcontextprotocol.io/api/documents/overview.html), [AG-UI event specification](https://github.com/ag-ui-protocol/ag-ui/blob/main/docs/concepts/events.mdx).

These approaches can coexist: an agent may use an event transport to deliver a declarative view, or open an embedded application. Adopting all those layers would add complexity without establishing a product benefit for our local Pi host.

## Native Apple support: the important qualification

A2UI's maintained renderer table currently lists React, Lit, Angular, and Flutter as stable for v0.9.1. SwiftUI is still planned. The v1.0 documentation is a candidate; do not accidentally combine its messages with a v0.9.1 implementation. [Maintained renderer status](https://github.com/a2ui-project/a2ui/blob/main/docs/public/reference/renderers.md).

There is a community [A2UI-Swift implementation](https://github.com/BBC6BAE9/a2ui-swift). It advertises v0.9/v0.9.1 handling, SwiftUI/UIKit/AppKit renderers, two-way binding, and custom catalogs. Its documented built-ins cover layout and inputs; Banana charts would be custom components. This is a candidate to inspect and test, not a verified production dependency. This research inspected its public documentation, not a complete source/security audit or an on-device integration.

Before adopting it, pin a commit and verify protocol conformance, incremental updates, custom Charts support, accessibility, focus/keyboard preservation, lifecycle cleanup, and test coverage against our actual requirements. Prefer contributing adapter fixes upstream over maintaining a private protocol fork.

Many older generative-UI examples use AI SDK React Server Components. Vercel currently calls that package experimental and recommends AI SDK UI for production. Those old demos are not a sound default implementation reference. [Official migration guidance](https://ai-sdk.dev/docs/ai-sdk-rsc/migrating-to-ui).

## How the interaction should work

An illustrative Banana flow:

1. “Show my protein last month.” A chart appears with the date interval, units, and data coverage visible.
2. “Only weekdays.” The same chart changes its filter.
3. “Compare with the month before.” It gains a comparison series.
4. Tap a day. Its meals appear alongside or below it immediately.
5. “Use that breakfast tomorrow.” A meal draft opens using the selected meal as the reference.
6. Save. The normal validated domain action runs through Pi; the view shows its committed result.

The composer remains available throughout. On iPad the active view can occupy most of the workspace, with history available when needed. On phone it can expand to the foreground while keeping the composer reachable. Each follow-up should not append another full copy of the chart and force the user to scroll past obsolete versions. Preserve an understandable history and a way back when the active view changes substantially.

## Proposed Banana boundary

This section is a design recommendation, not a claim about every framework above.

**A small component catalog.** Start with semantic components such as a nutrition trend, meal list, calendar interval, event draft, comparison table, and record detail. Reuse existing SwiftUI rendering and domain calculations. A model can choose a representation and query parameters without producing executable Swift or an entire screen's styling.

**A durable view descriptor.** A view needs a stable surface ID, schema version, revision, component type, query reference, filters, selection, and allowed actions. Store the committed descriptor separately from temporary hover/scrub state. Natural-language changes propose validated patches to a known revision. Reject stale patches and preserve direct edits and keyboard focus.

**Real data bindings.** The native query layer computes series, totals, date boundaries, and units from actual stores. Model output must not become fabricated chart data. Preserve missing-data distinctions. On restoration, distinguish a saved snapshot from a live query that will refresh.

**Two interaction paths.** Taps, scrubbing, and ordinary filters update local state and native queries immediately; they do not need an LLM round trip. Language can modify the same state through typed tools. Give the model a compact description of the active view and selection so that “that day” or “the first meal” has an explicit referent. Do not send every data point or every UI node back on every turn.

**Separate view changes from app writes.** Changing a chart filter does not create a meal. Saving a draft goes through the existing domain validation and Pi execution path. Stable action IDs and version checks are needed so restoring a view or retrying a button does not duplicate a completed action. Persisted UI state alone is not an exactly-once guarantee.

**Pi remains the execution owner.** The current assistant bridge projects entries into text-only `AssistantMessage` values (`Banana/Pi/AssistantStore.swift` and `displayMessages` in `tools/pi-host-proof/runtime/app.js`). Rich UI requires a structured surface projection alongside text. Pi publicly exports document and entry definitions in `packages/durable/src/index.ts`; extension-owned surface documents and actions can use that boundary. The detailed document/action transaction design still needs implementation validation. No Pi scheduler or core model changes are justified by rendering charts.

Existing native starting points include `Banana/Views/TrendViews.swift` and `Banana/Views/Workouts/WorkoutChartsSection.swift`, including shared chart selections. Those are reusable rendering patterns, not evidence that all required nutrition queries are already exposed to Pi.

## Performance and model implications

A constrained descriptor or small patch should require less generated output than a complete HTML application. This is a reasonable hypothesis to measure, not proof that Apple Foundation Models will meet a particular latency target. Native rendering and local interaction do not require moving inference to a Mac. A local or paired-Mac model can later implement the same typed inference contract without moving the device's data writes or Pi ledger.

Show indexed search results as soon as local retrieval is ready. Model-assisted interpretation can refine the query or presentation afterward. Measure time to first useful result and time to usable updated view separately from final prose completion. Avoid an obligatory second answer generation before displaying a valid chart result.

A separate decision model is optional. First measure how reliably the current model selects a small catalog and extracts query parameters. More model stages can add latency; a classifier does not solve date extraction, entity references, or chart correctness by itself.

## Recommended first experiment

Build one complete slice: nutrition search → chart → conversational filtering → tap-to-drill-down → meal draft. Compare a pinned community A2UI-Swift renderer with a thin native catalog adapter before choosing a dependency. Keep the initial catalog and query contract identical so the comparison tests the renderer rather than two different products.

Acceptance should include language and touch producing equivalent state; useful offline results; correct units/date ranges and missing-data handling; relaunch restoring the view; stale inference not overwriting a newer edit; accessibility and keyboard behavior; and a save action occurring once across retries/restoration. Benchmark cold/warm behavior on the real iPad before expanding across the app.

This experiment should establish whether one composer plus changing views can replace everyday navigation. It should not be reduced to decorating an otherwise unchanged chat transcript with static cards.
