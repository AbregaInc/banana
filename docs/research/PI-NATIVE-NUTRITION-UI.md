# Native conversational nutrition workspace

Implementation and acceptance notes, 24 October 2026. This is the first native component slice from `PI-GENERATIVE-UI.md`, in the isolated Banana Pi app.

## Behavior

The Assistant can open a native nutrition chart and logged-meal results. Follow-up requests change that same view. Supported operations include nutrient selection, calendar periods/custom date ranges, food-name search, weekday filtering, comparison with the preceding equal-length interval, day selection, and preparing a logged meal for review on another day.

The chart has native metric, filter and day controls. Touch changes do not invoke a model. A new conversation also offers a direct monthly-protein shortcut that performs a native query without inference. The composer remains available; conversation history folds beneath the active workspace. The first chart scrolls into view, while later updates preserve the current scroll position.

Meal copies use the existing food/portion review editor. No meal is written when a model prepares a draft or a view is restored. The person must review and save it. Pi commits a stable draft/save ID before review. That ID becomes the new meal ID: the native save writes atomically before publishing success, returns an existing identical saved meal on retry, and rejects a reused ID with different contents. A restored view recognizes a saved draft rather than offering to save it again. This is native idempotence backed by the persisted Pi draft; it is not a claim that UI restoration alone provides exactly-once external effects.

## Ownership and extension boundaries

- `tools/pi-host-proof/runtime/nutrition.js` defines a conversation-scoped, latest-state Pi document, prompt section, public generation hooks, and three extension tools: `nutrition_view`, `filter_nutrition`, and `prepare_meal_copy`.
- `AssistantNutrition.swift` defines the typed native descriptor, calendar arithmetic, validation, filtering and aggregation. `AssistantNutritionCapabilities.swift` supplies bounded model-facing facts from the actual Wellness store.
- `AssistantStore` projects the Pi document to SwiftUI alongside chat messages. Direct controls call the same document-update path with a base revision.
- `AssistantNutritionView` uses native Swift Charts and the shared meal editor. It does not execute generated UI code.
- `WellnessStore.addAssistantMeal` handles the reviewed copy's atomic, idempotent native save. The ordinary manual meal-entry path retains its existing behavior.

Pi core remains at the reviewed commit. No scheduler, compaction, provider core, or upstream persistence code was modified. No A2UI/AG-UI runtime was added, and this adapter does not claim protocol conformance. It is deliberately one native catalog component rather than a generic layout engine.

Successful native-view tools return Pi's public `control.terminate`. Pi ends the turn after committing the tool results, without a second model generation that repeats the chart in prose. Failed tools retain the ordinary explanation/recovery path; mixed tool rounds retain Pi's rule that every result must request termination. Ordinary conversational replies still render beside the active workspace.

## Why the tools are separated

Real-device testing exposed mistakes that mocked replies could not reveal. An initial broad tool let the model put “protein” into a generic food-search field, supply an old revision, and modify chart filters while claiming to prepare a meal. The final contract separates opening/searching, filter changes, and draft preparation. Food-name parameters are distinct from nutrient selection. Relative periods and draft days are resolved with native calendar arithmetic.

Revisions are host metadata. A public Pi generation hook captures the rendered view's revision in a task memo and binds it to tool calls before Pi records their intent. The native validation and Pi commit both respect that basis. A touch during inference makes the older result stale; it cannot overwrite the newer view. Tests exercise this through actual Pi generation hooks as well as direct document updates.

## Data semantics and limits

Charts use meals logged in the current app's Wellness store, including its existing 1,500-meal retention limit. They do not imply complete dietary intake. Unlogged days are missing, never measured zeroes. The UI states logged-day coverage and identifies a comparison period with no logged meals. Native summaries also distinguish absent prior data from zero or equal intake.

Ranges are inclusive Gregorian local dates, bounded to 93 days. Comparison aligns a preceding equal-length calendar interval by day offset. Weekday filtering follows the local calendar; custom ranges, invalid dates and out-of-range selections are validated natively. Results use whole matching meals: a food-name match selects a meal, and its displayed nutrient value is the meal's total, not just the matched ingredient. Model-facing meal lists are capped at 12 with truncated names; the UI shows 30 and asks for a narrower selection when needed.

Pi UI tests use `Banana Pi UI Tests`; real inference acceptance uses `Banana Pi Verification`. Both are separate from normal `Banana Pi` data. Verification drivers compare normal conversation files and preferences before/after, clean their synthetic meals, and return to the normal app.

## Verification and performance

Reproducible commands:

```sh
python3 tools/pi-host-proof/generate.py ../pi-upstream
python3 tools/pi-host-proof/run-nutrition-unit.py
python3 tools/pi-host-proof/run-mac.py --mode nutrition-conformance
WORKERS=1 SCHEME=BananaPi UI_CONFIG=PiDevelopment UI_TEST_TARGET=BananaAgentUITests \
  tools/ui-tests.sh pad AssistantUITest/testNutritionWorkspaceUpdatesAndRestores \
  AssistantUITest/testNutritionMealCopyOpensExistingReviewEditor \
  AssistantUITest/testNutritionShortcutOpensWithoutAnInferenceTurn
python3 tools/pi-host-proof/run-app-device.py <device-udid> ipad \
  '.build/sim/Build/Products/PiDevelopment-iphoneos/Banana Pi.app' --nutrition
```

Native query tests cover missing-day handling, meal totals, food/name matching, metric selection, DST-safe comparison, relative calendar periods, invalid ranges/selections, and draft validation. JavaScriptCore/SQLite checks cover restoration, isolation, validation failure, stale results, acknowledgement retry, public hook binding, real inference/touch races, native schema compatibility, and stable draft identity.

The real iPad model acceptance checks natural queries, language filters/comparison, touch selection, contextual drafting, food search, restoration, and native save persistence/deduplication/conflict rejection. UI checks cover touch/language restoration, the inference-free shortcut, cancel/review/save, and persistence after app termination. Machine-readable reports live in `pi-apple-host-results`.

A completed real-iPad run before the final save-identity and terminate-control changes measured 5,660 ms to the published chart state and 11,267 ms for the completed first answer. This is one acceptance sample, not a latency distribution or a frame-presentation benchmark. The terminate control removes the second generation; final measurements are in the current machine report. The language path remains too slow for a universal fast command field; the direct native shortcut avoids inference, while faster routing/model work remains a separate next step. Do not present the current language path as subsecond.

Simulator startup intermittently failed in CoreSimulator's launch bridge. The failed runs and sampled runner stack were inspected before retrying; an existing simulator was reset rather than creating new devices. A launch failure is not counted as app acceptance.

This slice does not replace the whole app's navigation, add calendar/event components, install another inference backend, or add device-to-device task synchronization. Main/Beta apps and Apple submissions remain outside this worktree's changes.

## Final acceptance

The final installed iPad build passed the complete real Apple-model flow, including stable-ID native save persistence, duplicate retries and conflicting retry rejection. Its normal conversations and selection/draft preferences were unchanged. A readiness-correlated physical screenshot was captured and visually inspected. The measured first view/turn completed in 6,431 ms with one generation; a native day-selection commit took 93 ms. These are single-run state-publication measurements.

Eight native query tests, fifteen JavaScriptCore/Pi/SQLite checks, and five focused iPad UI tests passed. The UI run includes conversation restoration and completed-note deduplication regressions, the native shortcut, language/touch view restoration, and meal review/cancel/save persistence. The Mac Pi target also compiled successfully; its temporary build output was removed. Simulator testing ended with the simulator shut down. The authoritative combined result is [nutrition-ui-acceptance.json](pi-apple-host-results/nutrition-ui-acceptance.json).

## Fictional meal history for Pi testing

The isolated PiDevelopment flavor now seeds an empty normal store once with 249 clearly marked sample meals across 83 logged days in a 90-day window. Repeated menu loads merge stable IDs without overwriting existing rows. The menu can remove only marked sample originals; personal meals and saved copies remain. Removing samples suppresses automatic re-seeding. Samples use atomic local persistence and do not write to external health/calendar/cloud services.

Six sample-data unit tests plus the eight nutrition tests pass. A focused iPad UI test covers load, repeat load and removal. Physical iPad checks verify persisted removal, deduplication and preservation of personal meals/copies; normal conversation files and selection/draft preferences remain unchanged. The normal iPad Pi store was separately populated and verified to contain 249 sample meals. Evidence: `ipad-samples.json` and `ipad-normal-sample-data.json` in `pi-apple-host-results`.
