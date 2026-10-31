# Recent meals

Food offers Recent meals directly, in its Add menu, and from an empty Describe sheet.
The same picker serves iPhone, iPad and Mac. Search matches meal names and foods live;
identical meals/portions appear once, newest first. Portions with different nutrition
remain distinct. Native List provides lazy row rendering. Search/sort/deduplication
runs off the main actor and obsolete searches are canceled.

The selected date/time starts at now for today, or noon for a past day. Selecting a
meal logs immediately, with new meal/item IDs and the checked amounts and nutrition.
Confidence stays with each food. Photos, the original dated description and the
original AI estimate are not presented as evidence of the new meal. The logged row
uses the existing editor for portion changes. The saved-meal editor also exposes a native
“Ate at” date/time picker. Its correction updates the same record ID, preserves photos
and nutrition, regroups the meal on the corrected day, and uses existing meal sync.
Cancel leaves the original timestamp unchanged.

Encoding and large writes are staged off the UI thread. A revision and restore-generation
check rebuilds the snapshot when another mutation lands meanwhile; one atomic rename
commits it before the success toast. Failures retain the selection and ID for retry.
Undo uses the same durable commit path. Both actions use existing wellness sync hooks,
so the record/deletion reaches other native apps and the cloud view under the person's
existing consent. There is no new server schema. Meal load/merge/save no longer silently
caps retained history at 1,500 records. Previously discarded records are not recovered
by this change.

`python3 tools/recent-meals-tests/run.py` exercises production search/copy and filesystem
code with real snapshots, failures, retries, Undo and more than 1,500 records. Temporary
binaries are deleted within the run. RecentMealsUITest covers selecting/searching,
relaunch persistence and Undo on the narrow Food page. Native UI checks and rollout
are separate from those pure checks; physical frame/input timing remains unmeasured.

HealthFoodAdapterTests and WellnessCloudSyncTests also cover the actual sync adapter and
cloud merge beyond the former cap, retaining the oldest meal on both devices. The 94-case
meal/sync/model/add-menu unit run passes after removing the remaining cloud-merge cap.

Saved-meal timestamp validation: `MealEditorUITest/testSavedMealTimeCanBeCorrectedAndSurvivesRelaunch`
passes on iPhone alongside both RecentMealsUITest cases. WellnessModelsTests passes,
including a fixed-date correction across days, preserved identity/photos/nutrition,
serialization round trip and a missing-record no-op. The first UI attempt exposed test
issues (future-time clamping before choosing AM, fixture reseeding, and lazy offscreen
rows); the corrected targeted run passes 3/3. No additional full suite was run.
