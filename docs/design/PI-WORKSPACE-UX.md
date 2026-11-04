# Pi workspace UX: reduce task transitions

## Direction — 31 October 2026: a fixed interface; the agent is an input method

<redacted>: "the chat first ui here isnt the way we want to go, we want a fixed interface like in
main where the agent is a method of inputing or extracting data." This supersedes the
"workspace is the home" passes below.

- **Home is the fixed app**, the same shell as Main (Plan, Body, Notes, Library). There is no
  assistant home, no Browse detour and no "Back to workspace".
- **In: the +.** Every page's + opens one sheet (`AgentAddSheet`, `Banana/Views/AgentInput.swift`):
  a line for words first, then every kind of thing by hand. On iPad the + menu's first item,
  "Type it…", opens the same sheet. Pi turns the words into the app's own editor (meal, event)
  in the sheet. "Approve and save" is the person's one explicit approval; the sheet closes
  onto the page that owns the item, whose toast offers Undo. Discard keeps the sheet open.
- **Out: Review.** Review (chart button, top left) is for looking back; its first row takes a
  question (`AgentAskRow`). The answer opens as a page (`AgentAnswerPage`) with the app's own
  view: the nutrition chart, search results, or Pi's line.
- Each add or question starts a fresh conversation, so drafts never stack. The full
  conversation history stays where Main has it: … › Assistant.
- The workspace objects built for the old home remain the building blocks: one header
  (`WorkspaceObjectHeader`: title, Draft/Saved/blocked, Discard or Close), the saved-meal
  record, grouped search results, the nutrition view.
- Checks: `PiLaunchUITest` (home is the fixed app), `AgentInputUITest` (words become a meal on
  its page; discarding keeps the sheet; a question in Review opens its answer), and the
  design walk `PiDesignTourUITest` (tools/design-climb).


26 October 2026. Applies to the isolated Pi app. Main/Beta and Apple submissions are outside this work.

The design goal is one input for creating, finding and asking, followed by an evolving native workspace. Measure completion of a task, not the presence of a chat box. Keep direct manipulation fast: editing a quantity or picking a date should not require another agent turn.

## Simplification pass — 28 October 2026

Pi now opens directly into the shared workspace on phone and iPad, with no category tab bar or sidebar on that home surface. Browse opens the existing application pages, with a persistent Back to workspace control; the category navigation remains available there. Search links and native tool navigation still reach the same pages and selected records. This consolidates the default entry surface rather than deleting the underlying features. The normal Main/Beta shell is unchanged. Browse is a visible text button, and the keyboard dismisses after an accepted message so the resulting workspace has the screen.

The Mac sidebar starts with Workspace and a collapsed Browse group instead of eight permanent category rows. Selecting a category via native routing or a menu shortcut expands Browse so the selection stays discoverable. Conversations moves under Assistant options; New conversation stays directly available.

Meal-copy review now shares the same inline native food editor as new meals, removing its Review meal draft tap and separate review sheet. Dismiss draft cancels without saving; native confirmation remains required. Its persisted Pi draft operation ID still controls save deduplication. The saved-date message reads the stored meal date, including human corrections.

Search results expand in place. Meals show current saved foods, portions and totals, with the existing estimate qualification. Notes show the current non-archived transcript (up to 10,000 characters with an explicit continuation link). Deleted records are reported unavailable. Expanding/closing results performs no inference or writes; opening the complete application page is optional. Other categories retain their returned detail and direct page links, without an extra expansion tap. Selection of an expanded result is view-local.

Playback controls, undo/toast feedback and the voice-capture presenter remain available on the new mobile home. Browsing uses the existing media and native page presenters. This pass does not change the model, Pi core, tool schemas, search scope, save validation or calendars.

The remaining durability gap is unchanged: unsaved manual food/event corrections are view-local. Do not promise restoration of those corrections across conversation switches or process death. Original Pi action descriptors and copied-meal draft identity remain durable. No physical mobile installation is claimed until a connected-device check has completed.

The 26 October sections below describe the preceding implementation and its retained evidence; their meal-copy-sheet and persistent-home-navigation boundaries are superseded by this pass.

## First implementation: new meals and events

Before: request → draft summary → Review button → separate editor sheet → edit/save → sheet closes → result.

After: request → editable workspace → save → result in the same workspace.

This removes one required review tap and one editor presentation transition from each new-meal/new-event journey. It removes the two workspace Review buttons and their sheet presenter. It does not remove the reusable editors or any top-level app destination. Existing meal-copy review still uses its sheet.

The existing food editor supplies catalog/correction matches, live totals, item corrections, amount validation, explicit review and stable-ID saving. Its embedded presentation also exposes the meal date and explicit row deletion, since a workspace is not a swipe-to-delete list. Successful save leaves the assistant open and shows the saved result.

The existing calendar editor supplies title/date/time, calendar selection and the optimistic calendar save path. Advanced location, guest, scheduling and notes controls sit under More details. Calendar selection stays visible. No writable calendar means Save is unavailable, with an explanation. A queued event is described as added to Plan with sync status there, not as a confirmed remote write.

Both presentations share their actual editor sections and save methods. The inline container uses SwiftUI's public [section composition API](https://developer.apple.com/documentation/swiftui/sectionconfiguration) to render those sections inside the assistant's scroll surface. It adds no second nested scrolling form or navigation stack. Legacy sheet entry points retain their own presentation. Pi's core, document revisions, native validation, save identities and effects are unchanged. An action's identity keys its editor, so a new proposal cannot inherit the previous proposal's local controls.

## Boundaries that remain

Pi-prepared action descriptors survive reopen. Unsaved manual field corrections still have the shared editors' existing view-local lifetime; this change does not implement autosaved human edits. Persisting native editor state through the public Pi document API is a subsequent design/implementation task, before promising lossless editing across conversation switches or process death.

Search currently returns a bounded local result list and opens existing pages. Nutrition has its own in-place graph/filter/day-selection workspace, and meal-copy review remains a sheet. Sidebar/tab destinations remain. This first change must not be presented as retirement of the whole app UI.

## Next deletion targets

1. Show a selected search result's useful content in place, with editing where supported. Opening its full app section becomes optional.
2. Move meal-copy review into the same shared inline editor, retaining source-meal identity and copy deduplication.
3. Persist human edits to the active native draft without inference, scoped to its conversation/action identity and revision.
4. Promote the shared input on phone/iPad and consolidate redundant creation/search entry points after replacement flows pass their acceptance checks.
5. Reduce persistent category navigation to a compact browse/index surface when common journeys no longer depend on it.

Keep fast direct controls and a discoverable browse route. Judge deletion by fewer screen transitions and taps, time to a verified result, correction cost and restoration behavior. Do not hide an unfinished replacement behind a removed navigation item.

## Acceptance

Require iPad simulator checks for direct editor availability without a Review tap or sheet, original Pi-draft restoration, editable fields, meal review/save into the existing store, assistant remaining open after save, event save blocked without a destination, the retained meal-copy sheet and normal search navigation. Retain screenshots and failure reasons. Mac and iOS must compile; the Mac remains arm64 only. No external calendar write is part of these fixture tests.

Final run results and installed-build scope are recorded after verification, rather than inferred from compilation alone.


## Retained results — 26 October

The final scoped iPad simulator run passed five tests: new meal availability/restoration inline, edited meal save into the existing nutrition store while keeping Assistant open, event editing/restoration with no writable-calendar save, retained meal-copy sheet review/save, and global search navigation. A strengthened meal-name replacement assertion then passed its own scoped rerun. The fixture provider drives these UI checks; they are not model-accuracy measurements. Twenty-four native tests pass. The installed arm64 Mac app passed the real Qwen4B workspace regression, including meal persistence/deduplication, event clarification/continuation and local search/navigation. Strict signing and main/debug binary architecture checks pass.

The first UI run exposed parent accessibility identifiers overriding control identifiers; the parent tags were removed. A later copy-flow swipe stalled with the main thread repeatedly placing lazy subviews. The sample is retained; the bounded interactive canvas now uses an eager stack on iOS, with plain conversation history remaining lazy. All five scoped checks passed after that change. A new draft scrolls to its top, and inline event-title submission uses native focus handling instead of a second phrase-inference flow. The legacy event sheet keeps its existing phrase entry.

[iPad meal](../research/pi-apple-host-results/ipad-inline-meal-2026-10-26.png) and [iPad event](../research/pi-apple-host-results/ipad-inline-event-2026-10-26.png) screenshots show actual tested controls with fictional data. [Acceptance metadata](../research/pi-apple-host-results/pi-inline-acceptance-2026-10-26.json) links run counts, failures, retained console evidence and installed binary digests. Xcode pruned the two oldest xcresults; their runner summaries and full console logs were retained, rather than claiming the bundles still exist.

Mac visual automation returned `cgWindowNotFound`; no new visible Mac interaction acceptance is claimed. One automatic probe launch ran normal Pi startup before the corrected diagnostic launch. Only `routines.json` changed its byte fingerprint; existing routine startup persists decoded/default state. No semantic before-image was retained, so this is not certified as formatting-only. Other checked normal data/preferences/configuration retained their fingerprints. The corrected diagnostic launch preserved every checked normal fingerprint; the subsequent real-model verification also preserved its normal-state checks. No user commands were issued in the normal probe. This test caveat is separate from the passing iPad UI and Mac functional checks.

No live calendar write, physical-device run or Apple submission occurred. The canonical simulators are shut down and owned inference workers are unloaded. The updated full Mac Pi app is installed; main/Beta installations remain untouched.

For future visual probes, keep the diagnostic process alive and verify its launch flags before binding the native automation target. Binding an app that is no longer running may auto-launch it without the diagnostic flags. Export each result summary promptly: Xcode can prune earlier xcresult bundles during later runs.

## Retained results — 28 October

Seven focused cases pass on each canonical simulator: normal cold launch/relaunch without cloud setup, Browse/return through the full shell, conversation restoration/selection, inline meal-copy dismissal/save/reopen, inline meal search plus optional native navigation/return, corrected new-meal save, and event editing/restoration with unavailable-calendar save blocked. A final iPad search rerun also passes after the last search presentation refinement. Earlier staged iPad runs passed four and five cases. The first phone run passed five and failed one assertion: it looked for wider-layout Nutrition controls. The retained AX dump shows the actual Nutrition navigation bar and matching meal; the assertion now also recognizes the phone's native meal list. No idle/query timeout or product navigation failure was inferred from that assertion.

The installed arm64 Mac Pi app passes the real Qwen4B workspace regression, including native meal persistence/deduplication, event clarification/continuation and local search/navigation. Normal history, meals, preferences and model configuration retain their fingerprints; the owned model worker is released. Model timing in that report is a functional observation under a shared host, not evidence of a speed improvement. Mac main/debug binaries and the signed mobile product are arm64; strict signing checks pass. The signed mobile build is ready, but AyePad and the primary iPhone are unavailable, so no physical installation or new hardware UI acceptance is claimed. Main/Beta installs and submissions remain untouched.

Mac visible automation still returns `cgWindowNotFound`, including a Launch Services diagnostic launch. Both diagnostic probes preserve all checked normal fingerprints. This pass establishes compilation/signing and real-model functional acceptance on Mac, not visible sidebar/editor interaction acceptance. The historical 26 October routine-file caveat remains historical; this pass makes no new normal-startup launch. Frame-dimension warnings remain in XCTest's retained summaries. Note expansion and active-audio playback were not separate fixture UI cases in this pass; the tested inline search detail is a meal.

[Acceptance metadata](../research/pi-apple-host-results/pi-simple-acceptance-2026-10-28.json), [Mac regression](../research/pi-apple-host-results/mac-simple-installed-workspace.json), [iPad home](../research/pi-apple-host-results/ipad-workspace-home-2026-10-28.png), [iPhone home](../research/pi-apple-host-results/iphone-workspace-home-2026-10-28.png), [iPhone inline copy](../research/pi-apple-host-results/iphone-inline-meal-copy-2026-10-28.png), and [iPhone inline search](../research/pi-apple-host-results/iphone-inline-search-details-2026-10-28.png) retain the results. Screenshots are unchanged native XCTest attachments with fictional data. Logs preserve their content with terminal blank lines normalized. Export summaries/attachments before later Xcode runs can prune result bundles.

To reproduce the focused UI checks, coordinate the canonical devices first, check memory, and run this once for `pad` and once for `phone`:

```sh
SCHEME=BananaPi UI_CONFIG=PiDevelopment UI_TEST_TARGET=BananaAgentUITests \
WORKERS=1 BUILD_JOBS=1 tools/ui-tests.sh pad \
  PiLaunchUITest/testNormalColdLaunchReachesAssistantWithoutCloudSetup \
  AssistantUITest/testAssistantOpensThroughTheAppShell \
  AssistantUITest/testConversationSurvivesRelaunchAndSelection \
  AssistantUITest/testNutritionMealCopyOpensExistingReviewEditor \
  AssistantUITest/testGlobalMealSearchLinksThroughNormalAppShell \
  AssistantUITest/testNewMealDraftSaveAppearsInExistingNutritionStore \
  AssistantUITest/testNewEventDraftIsInlineAndRestores
```

The real-model installed-Mac regression uses the existing isolated driver after building, signing and installing only Banana Pi:

```sh
python3 tools/pi-mac-inference/run-app.py "$HOME/Applications/Banana Pi.app" \
  --workspace --report-prefix mac-simple-installed
```

It must pass its normal-state preservation and owned-worker-release gates. The simulator checks are functional fixture checks, not inference benchmarks. Pi's upstream durable/AI/chord/telemetry sources remain unchanged.
