# Broader app integration — verification status

25 October 2026. Isolated Pi branch/worktree; main/Beta installs and Apple submissions untouched. Main explicitly released the shared build/inference window. Model files, upstream source checkouts and worktree are preserved.

Implemented: normal platform shell/sidebar, local shared app graph, public persistent workspace extension for meal/event drafts and local search/navigation, existing native editors, stable-ID meal commits and calendar operation/payload receipts. Pi core is unchanged. Google credentials, cloud behavior, files/preferences and peer namespace are isolated from Beta. See [implementation details](../../docs/research/PI-APP-INTEGRATION.md).

Verified:

- Mac builds and strict installed signature; 22 native tests; 11 JSC workspace durability/conformance checks; nutrition conformance.
- Real-model Mac workspace, nutrition and general agent regressions. The retained final workspace run includes a 99.54-second meal turn: functional success is not a speed acceptance claim.
- Physical iPad Apple-model workspace flow: persisted meal/event drafts, native meal save deduplication, local search/navigation descriptors and invalid-input rejection. No external calendar write attempted.
- Mac full sidebar and real Nutrition history visually observed through CUA.
- iPad simulator normal launch without cloud onboarding, shared meal review/cancel/restore, event editor/cancel/restore, global meal search into normal Nutrition passed.

A meal-save card status bug was found by UI tests: UUID strings differed in letter casing. Compare parsed UUID values instead; scoped rerun is recorded separately. Physical iPad XCTest failed before any test case while enabling automation, even after reconnect/unlock. Final manual Mac editor recheck is blocked by CUA native-pipe startup failure. Do not turn these into acceptance claims.

Current Mac incumbent is Qwen3.5-4B 4-bit through Locals with thinking off, not a proven best choice. No Kev/Von/d1 router is enabled. The [selection protocol](../pi-evaluation/README.md) and [dated research](../../docs/research/PI-INFERENCE-SELECTION.md) define exact comparisons and future discovery. Mobile third-party model deployment and Mac-hub inference routing remain unimplemented.


## Inline new-draft UX — 26 October

The updated full Mac Pi app is installed with shared meal/event editors in the active assistant workspace. New drafts no longer require a Review button and editor sheet. Native review/save validation and stable operation IDs remain; fields and dates can be corrected without another agent turn. Advanced event fields are collapsed. Legacy meal-copy review remains a sheet, search still opens existing destinations and manual unsaved field corrections remain view-local.

Five scoped iPad simulator UI tests pass, plus a strengthened meal-name case; 24 native tests and the installed real-model Mac workspace regression pass. The bounded interactive canvas uses eager layout after a sampled lazy-placement stall. Mac strict signature and arm64 checks pass. The [UX record and acceptance caveats](../../docs/design/PI-WORKSPACE-UX.md) retain screenshots/failures, the unavailable Mac window probe and its routine-startup file rewrite. No new physical or live-calendar acceptance is claimed.

## Workspace-first UX — 28 October

The Pi mobile home is the shared input/workspace, with the existing pages behind Browse and a direct return control. Mac categories are collapsed under Browse. Meal-copy review is now inline; meals and notes expand search details in the workspace. New conversation stays directly available; conversation selection is in Assistant options. Playback controls and toast/undo feedback remain available. These are changes to native presentation; Pi core, tools, model selection and save validation are unchanged.

See the [current UX scope and acceptance](../../docs/design/PI-WORKSPACE-UX.md). The preceding sections are dated evidence; they do not establish physical acceptance of this presentation. Unsaved manual editor corrections remain view-local.

Current pass: seven scoped cases pass on iPad and seven on phone, plus a final iPad search recheck. The installed Mac real-model workspace regression passes; strict arm64 signing checks and the signed mobile development build pass. Hardware installation is pending unavailable devices. Mac visible automation is blocked by `cgWindowNotFound`; both isolated diagnostic launches preserve checked normal state. The UX record retains the initial phone assertion failure, frame warnings and exact acceptance limits.
