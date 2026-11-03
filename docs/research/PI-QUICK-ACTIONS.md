# Quick actions across Banana

24 October 2026. Architecture proposal and code audit; this is not implemented in the installed Pi build. The current user request expands the earlier Apple-only model constraint to consider downloaded local models and inference on a paired Mac.

## Product behavior

One entry field, reachable throughout the app, returns an editable action preview. The main page supplies hints, not a forced interpretation. “I ate two eggs and toast” proposes a meal; “Lunch with Sam tomorrow at 1” proposes a calendar event; “Save a note: …” proposes a note. Ambiguous text offers a short choice or one clarification. Compound commands produce separate previews rather than silently dropping an action.

The UI should acknowledge input immediately and show a useful draft before optional enrichment completes. A meal may have pending nutrition; a calendar write may be pending provider confirmation. Neither is presented as completed merely because a model said so.

## Existing code to reuse

- `EventPhrase.parse` already provides a deterministic title/date/location/recurrence draft. `EventPhrase.read` optionally refines it with guided generation, verifies extracted words against the input, and keeps date arithmetic in Swift.
- `NewCalendarEventSheet` already renders a deterministic phrase preview and has the actual event authoring flow.
- `FoodTextExtractor` separates item identification from nutrition lookup/estimation. It already prefers learned corrections and the food catalogue over generated nutrition. Its current split stage still invokes a model; a fast path for known single-item inputs would be new work.
- `FoodTextCaptureView` is the existing editable meal review and save flow. `MealInboxStore` / `MealBacklogProcessor` and the continued-estimation support provide the pending-enrichment pattern.
- `MacCommandCenter` / `MacCommandMenu` provide keyboard entry and deterministic command/date matching, currently Mac-only.
- `BananaIntents.swift` provides an existing typed Siri/Shortcuts surface for tasks and routines, with confirmation and actual-store result messages. A shared capability service should sit beneath UI, App Intents and Pi wrappers; invoking an AppIntent directly is not assumed to reproduce its system confirmation context.
- `AssistantCapabilities` currently exposes only notes and day-plan tools. Meal/event creation is not yet wired into Pi.
- Nearby-device transfer exists inside `DownloadManager` using MultipeerConnectivity and pairing/group checks. This is not an inference API. Reuse the pairing concept deliberately; do not couple inference scheduling to the private podcast-transfer implementation.

## Execution boundary

Input -> interpretation -> typed draft -> existing editor/preview -> explicit Apply -> Pi durable command task -> shared native capability -> actual result.

Common commands do not need a chat-model/tool/model round trip. A Pi extension may register a typed command task that executes the confirmed draft without asking another model what to do. The public registry/task/provider APIs remain the extension boundary. Pi keeps admission, checkpoints, recovery and effect replay; its core remains unchanged.

Normal UI actions and assistant actions share domain services and validation. This does not require putting every existing human gesture through an LLM. AI-originated command commits receive stable IDs, preserve external-write uncertainty and do not blindly retry a calendar mutation whose result is unknown.

## Interpreting quickly

1. Reuse deterministic parsing and catalogue matches for inputs they can actually account for. Do not grow a collection of guessed regex intent rules that silently accepts uncertain cases.
2. For ambiguous phrasing, request a compact typed draft in one constrained generation. Do not add a full generative “decide what to do” request before another general agent request.
3. Consider a small trained classifier only for intent selection, with an unknown/abstain outcome and confidence calibrated on held-out inputs. Classification alone does not extract quantities, event fields or references to existing objects.
4. Keep calendar arithmetic, entity lookup, nutrition grounding, permissions and validation in native domain code. A small model's generated confidence is not a calibrated probability.
5. Show the editable draft while optional nutrition/search work continues. Cancel outdated interpretations and reject results for an old input revision.

## Current latency evidence and missing measurements

The current Apple Pi adapter creates a native session from committed Pi history for each request and buffers a native generation before returning content. A tool action normally needs both an intent generation and a following answer. Reconstructing history preserves Pi's authority; an independent hidden native conversation must not replace it merely to retain a cache.

A read of the Mac verification journal found 9 tool-intent generations (median 2,076 ms; range 1,489–3,041 ms) and 18 text replies (median 2,767 ms; range 1,166–5,182 ms). This is a small, uncontrolled acceptance sample with different prompt lengths, not a mobile benchmark or a distribution for one command. The sum of the two medians is not an observed end-to-end action latency.

The older `CHAT-ASSISTANT-PLAN.md` also contains historical measurements and explicitly retracts a Mac-derived latency conclusion after measuring real phones. Its architecture notes are useful; its old SDK statements and timings must not be treated as current guarantees.

Measure cold and warm **time to usable draft**, full structured output, commit acknowledgement, memory and thermal behavior on the actual iPad/phone. Compare the same input set and schema across the deterministic path, direct Apple guided generation, one small quantized local model and a paired-Mac backend. Include ambiguity, missing fields, date boundaries and failures. Streaming improves visibility, but is not proof that inference completed faster.

Proposed product goals, not measured results: a deterministic draft within roughly 200 ms; warm model-assisted common drafts around 1 second if a backend can meet the quality bar. Missed goals must remain visible rather than being hidden by invented values or a premature “saved” message.

## Backend options

- Apple Foundation Models remains the baseline. Measure direct small-schema requests, prewarming and streaming before replacing it. Use short task context rather than the whole chat. Warm reusable model assets/prefixes without carrying unrelated command history between requests.
- A Create ML/Core ML intent classifier is a candidate for cheap routing after collecting representative labels. It cannot replace extraction, validation or unknown-input handling.
- MLX Swift LM supports downloaded/quantized local models, constrained generation, and an OS 27 FoundationModels adapter. This is a plausible way to benchmark an alternative through the existing native provider boundary. A small supported candidate such as the documented Qwen 0.6B configuration is a benchmark candidate, not a selected or trained production model. Weight size alone does not establish mobile latency, RAM use or accuracy.
- A paired Mac may serve inference through a dedicated authenticated protocol. MLX or llama.cpp can supply the model; llama.cpp already has server and schema-constrained response support. Do not expose an unauthenticated LAN endpoint or assume a reachable Mac is faster.

The origin device retains the Pi ledger, previews and app writes. A Mac receives only the required inference payload and returns a draft or model response. This does not transfer task/database ownership. Send request ID, input revision, schema version, origin time zone/reference date and a deadline. Pair/authenticate the peer and protect transport; discard late responses. Compare predicted end-to-end cost including Mac queue, wake/load time and network. When the Mac sleeps/disconnects, pure inference can fall back locally; completed or uncertain writes are reconciled by the origin's Pi task rather than replayed remotely.

## Delivery order

First build the shared draft/capability contract and a meal/event/note entry surface using existing editors and Apple/deterministic paths. Instrument the actual path. Then benchmark a local specialist and paired-Mac inference behind the same contract. Select or train a decision model only if measured routing errors/latency justify it. No new model dependency or inference server has been added by this research.

## Primary references

- Apple, prewarming and streaming: https://developer.apple.com/videos/play/wwdc2025/259/
- Apple, Create ML text classification: https://developer.apple.com/documentation/createml/creating-a-text-classifier-model
- MLX Swift LM: https://github.com/ml-explore/mlx-swift-lm
- MLX FoundationModels integration: https://github.com/ml-explore/mlx-swift-lm/tree/main/Libraries/MLXFoundationModels
- llama.cpp server: https://github.com/ggml-org/llama.cpp/tree/master/tools/server
