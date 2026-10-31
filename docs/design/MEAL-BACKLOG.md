# Meal backlog, backfilling and grounded estimates

Status: building (30 Sep 2026). Owner decisions: picking photos is the default; scanning the
photo library only once approved, then ongoing; every new photo asks for words before it is
estimated, with "use the photo alone" as an option; Apple Private Cloud Compute only (no Claude).

## What the person gets

- **Log on any day.** Every capture path on the Nutrition page (iPhone, iPad, Mac) files the meal
  on the day being viewed. A meal with no time of its own goes at its part of the day's usual time
  (`MealLogTime`), or noon on a past day; on today never later than now.
- **Add photos & notes.** Pick many photos and/or type a day's worth of words. Photos are placed
  by when they were taken (`MealPhotoImage.captureDate`), grouped into meals when taken within 45
  minutes of each other (`MealPhotoGrouping`). Words are split into meals by the meals they name
  (`MealTextSplitter`: "oatmeal for breakfast, caesar at lunch" → two). Each photo meal asks
  "What was this?"; left blank, it waits in the backlog.
- **The backlog ("To log").** Meals waiting for words, being estimated, estimated and waiting for
  review, or failed. Answer, "Use photo only", "Not a meal", retry.
- **Review a day.** A day's estimated meals are reviewed together and logged together. Each item
  shows where its numbers come from and its portion in grams; changing the grams rescales it.
- **Find meal photos automatically** (opt-in, iPhone only, full Photos access). Checks the library
  for new food photos when the app opens, while it's open, and in the background; each new meal
  photo becomes a backlog item and — from the background — a notification asking what it was, with
  a text reply, "Use photo only" and "Not a meal".

## Data

`MealInboxItem` (Banana/Model/MealBacklog.swift): `eatenAt`, `photos: [MealPhotoRef]`, `note`,
`state` (`awaitingNote` → `ready` → `proposed`, or `failed`), `origin` (`picked`/`scanned`/
`typed`), `proposal: MealProposal?`, `readiedBy`/`readiedAt`. "Processing" is never stored — it's
in-memory on the device doing it. Logging turns a proposal into a `MealEntry` (its own time, note,
`photoIDs`) and removes the item; "Not a meal" removes it and its photos.

`MealItem` gains `grams` and `reference: FoodReference` (database id, name, per-100 g macros);
`withGrams` rescales. `MealEntry` gains `photoIDs`. All additive, decoded with defaults.

Stores: `MealInboxStore` (meal-inbox.json) and `MealPhotoStore` (MealPhotos/<id>.jpg, ≤1280 px).
Both sync through `CloudControlsSync` as `ControlKind.mealInbox` / `.mealPhoto` — one record per
item / photo, last edit wins, deletions as tombstones. Photos stay with logged meals; orphans older
than a day are pruned (`pruneOrphans`).

## Which device estimates (`MealBacklogRouting`)

Reading photos needs a model with vision: Private Cloud Compute on iOS/iPadOS 27 (the Mac is on
macOS 26 — it can't). Words alone can be estimated anywhere with Apple Intelligence. The device that
readied an item estimates it; after 90 s the iPhone picks it up (a note typed on the Mac); after 10
minutes anyone capable does.

## Keeping devices in step, cheaply

The goal: take a photo of lunch and, a minute or two later, the iPhone asks what it was — with the
iPhone having done almost nothing. Everything below serves that, and never costs battery for
work another device can do.

**The work, and who does it**

| Work | Who | Why |
|---|---|---|
| Finding meal photos | The Mac, on mains power, every 15 min and ~20 s after new photos arrive | Compute and power; iCloud Photos brings the iPhone's photos to it |
| Finding recent photos | The iPhone/iPad, only while no Mac keeps up, or while the app is open | So nothing waits on a Mac that's asleep, unplugged or closed |
| Asking "What did you eat?" | The iPhone only | It's the one with you |
| Estimating | The device that got the answer; the iPhone after 90 s; anyone after 10 min | Whoever is awake with the words in hand |

A Mac "keeps up" while its report (iCloud key-value storage, `MealPhotoScanReports`) says it has
Photos access, is on mains power, and checked within the last 45 minutes (`MealPhotoScanShare`).
On battery it looks only when photos arrive (2 min after), in Low Power Mode or hot not at all
(`MealPhotoScanPace`) — and stops counting as keeping up, so the iPhone takes over by itself.

**Moving it between devices**

1. *Its own zone.* The backlog, its photos and the found-photos list sync through a zone of their own
   (`ControlChannel.meals`, "Meals"), whose stores need no window: it starts at launch, so a
   background launch can fetch it alone (`MealBacklogWake`).
2. *Push for that zone only.* A `CKRecordZoneSubscription` with a silent push: when the Mac saves a
   meal, iCloud wakes the iPhone for a few seconds; it fetches the zone (a meal record and a ~200 KB
   photo) and asks. Changes anywhere else — listening progress, workouts — never wake it. Needs the
   `aps-environment` entitlement (Push Notifications on the App ID); without it registration fails
   quietly and step 4 carries it.
3. *One check per minute while open* (`CloudSyncPoll` + `CloudChangeCheck`): a single database-changes
   request says which zones changed; only those are fetched. An idle minute is one near-empty round
   trip, not one per zone. A zone still on its first history read keeps going regardless.
4. *The iPhone's background task* (`MealPhotoScanner`, hourly; every 4 h while push works and a Mac
   keeps up): catch up on the Meals zone first, ask about anything new, and only then — if no Mac
   keeps up, and not in Low Power Mode — look at recent photos itself.

**Never twice, never overwritten**

- The same library photo is the same meal on every device (`MealPhotoIdentity`: ids from the
  iCloud Photos cloud identifier), and photos any device made into meals are listed
  (`MealPhotoLedger`) and skipped everywhere.
- A device that finds a photo *offers* the meal (`ControlChangeReporter.offered`): it goes up as
  unedited, so an answer, a dismissal or a logged meal from any device always wins over a
  rediscovery.
- The iPhone asks about each meal once, whoever found it, and never about one already seen in the
  app (`MealPhotoNotificationPolicy.toAsk`); answering anywhere removes the notification.

## Estimating (`MealEstimator`, `MealBacklogProcessor`)

The model identifies and portions; the database supplies the numbers.

1. Same words as a meal already logged (`RepeatMeal`) → that meal's items, no model call.
2. Otherwise one session on `Intelligence.session(for: photos ? .vision : .knowledge, tools:
   [FoodSearchTool])` with the photos attached and the person's words. The model calls
   `searchFoods(query)` for each thing it sees or was told, picks a result id, and gives grams as
   eaten (using the portions the search lists). It may also give its own numbers for a food with
   no good match.
3. Resolution per item: a learned correction for that name (`FoodCorrectionBook`) → the chosen
   database food × grams (`FoodReference.macros(grams:)`) → the model's own numbers, flagged.
4. `NutritionSanity` warnings (calories vs 4/4/9 macros, impossible density, huge portions) go
   with the proposal.
5. The typed "Describe what you ate" flow uses the same grounded estimate for items the bundled
   catalog and corrections don't know.

## Food database (`FoodDatabase`, Banana/Resources/Foods.sqlite)

Built by `tools/build_food_database.py` from USDA FoodData Central downloads (public domain):
FNDDS survey foods (2024-10-31; foods as eaten, incl. mixed dishes, with portion weights), SR
Legacy (2018-04) and Foundation Foods (2026-04-30). Per food: id (`fndds:`/`sr:`/`foundation:`
+ FDC id), description, category, kcal/protein/carbs/fat per 100 g, portions (description →
grams). Full-text search (FTS5). Branded products (`BarcodeProducts.sqlite`, 455k) become
searchable by name through an FTS index over name + brand.

Swift API (contract):

```swift
struct FoodPortion: Codable, Hashable, Sendable { var label: String; var grams: Double }
struct FoodMatch: Hashable, Sendable {
    var reference: FoodReference      // id, name, per100g
    var category: String
    var portions: [FoodPortion]       // "1 cup" → 240 g, most common first
}
enum FoodDatabase {
    static func search(_ query: String, limit: Int = 8) -> [FoodMatch]   // thread-safe, any thread
    static func food(id: String) -> FoodMatch?
    static func toolText(_ matches: [FoodMatch]) -> String   // what searchFoods returns to the model
}
```

## Scanner (`MealPhotoScanner`, every device with Photos access; the Mac does most)

- Setting (synced): "Find meal photos automatically", with how far back to start (default 14
  days); "Ask about new meal photos" (notifications, default on). Turning it on anywhere makes
  each device ask for full Photos access the next time it's open.
- **Who looks** (changed 30 Sep 2026, owner: "the Mac is the best place to do it — the most
  compute, on power"): the Mac looks every 15 minutes while it runs and on library changes, in
  front or not. The iPhone and iPad keep the triggers below, and while a Mac keeps up (a complete
  pass in the last 6 h, `MealPhotoScanShare`) they look only at the last 36 hours — enough for
  the "What did you eat?" questions — leaving the backfill to the Mac. Without a Mac keeping up
  they look at everything, as before. Only the iPhone posts notifications.
- **The same photo on two devices** (`MealPhotoIdentity`): a photo's iCloud Photos cloud identifier
  is the same everywhere; its SHA-256 key names the photo (`MealPhotoRef.cloudKey`, and its id)
  and the meal (id from its earliest photo's key), so two devices finding it at once make the same
  meal. Photos any device made into meals are listed by key in `MealPhotoLedger`
  (`ControlKind.mealPhotoFound`) and skipped everywhere — after the meal is logged or dismissed
  too. Each device's progress is in iCloud key-value storage (`MealPhotoScanReports`), for the
  setting's "Also looking: Mac, 2 min ago".
- A pass: images since the last pass (first pass: since the start date), not screenshots, not
  already known (`MealInboxStore.knownAssetIDs` + a seen set); classify a small copy with
  `VNClassifyImageRequest` against food labels; group food photos with `MealPhotoGrouping`,
  joining an `awaitingNote` scanned meal within 45 minutes; save each via `MealPhotoImage.prepare`
  → `MealPhotoStore.save`; add `MealInboxItem(state: .awaitingNote, origin: .scanned)`.
- When: app active (on foreground, throttled; on library changes while active), and a
  `BGAppRefreshTask` `com.boris.banana.meals.scan` (~hourly floor). Never on the main thread's hot
  path; never in background audio time outside the BG task.
- Notification per new meal (category `MEAL_PHOTO`): text-input action "What was it?", "Use photo
  only", "Not a meal". Responses go to `MealInboxStore.answer / usePhotoOnly / dismiss`, then the
  processor runs.

Built (30 Sep 2026): `MealPhotoScan.swift` (pure, tested), `MealPhotoScanner.swift`,
`MealPhotoNotifications.swift`, `MealPhotoScanSettingsSection.swift`.

- **Is it food** (`MealPhotoClassifier`, Vision revision 2): any food label ≥ 0.30 (`food` itself
  carries nearly every photo; dishes, desserts, baked goods, fruit, vegetables back it up) or a drink
  label ≥ 0.25 (coffee, tea, juice, smoothie, beer, wine, cocktails, spirits). Measured on ~95
  photos: plated meals scored `food` 0.31–1.0, non-meals ≤ 0.18 (fridge, deli counter, market);
  drinks ≥ 0.26 on their own label, non-drinks ≤ 0.05. `table`, `plate`, `restaurant`, bare `drink`
  never count. The Simulator can't run the classifier (no labels at all): judge it on a device.
- **Memory** (`MealPhotoScanState`, meal-photo-scan.json, per device): a pass looks from a day before
  the last complete one (or the start date); photos already classified are skipped and forgotten
  once no window reaches them; photos that became meals are kept as long as the start date covers
  them, so a logged or dismissed meal is never found again. At most 300 photos a pass in front (it
  carries on in batches), 120 and 20 s in the background.
- Turning it on sets "Starting from" to 14 days back — each time, so switching it on again months
  later doesn't backfill the whole gap. The phone reports access, last check and meals found in
  `HubStatus.mealPhotoScan` for the iPad/Mac line.
- Questions only from background passes, only for meals from the last two days, at most four a
  pass. A meal answered anywhere loses its notification (identifier = item id).

## Tests

Pure: grouping, splitting, log times, routing, repeat matching, sanity, capture date, item
decoding, `withGrams`, database search ranking and tool text (fixture DB), scanner selection.
