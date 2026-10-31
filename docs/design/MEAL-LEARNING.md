# Meal estimates that learn

October 2026. Builds on MEAL-BACKLOG.md and My foods. The research behind it (open-source and
commercial trackers, photo-estimation studies) found Banana's approach already matches the best
apps: the model names foods and amounts, the numbers come from a measured database, your scanned
packages come first. What it lacked is what the calendar has: it never looked at how far off it
was. Trip learning keeps actual ÷ predicted and plans with the median; meals now do the same.

One rule runs through all of it: **learn from what you changed, never from what you accepted.**
An estimate you left alone may be right, or you may not have looked; an amount you moved, a
package you scanned, a portion you picked when asked, says what it really was.

## 1. The first estimate is kept (`MealEstimate`)

`MealProposal.estimate` is written once, when Banana estimates a meal, and never changed by an
edit. When the meal is logged it moves to `MealEntry.estimate`, and editing a logged meal later
keeps it. A meal typed in "Describe what you ate" keeps one too, from the rows as first parsed.

Each `EstimatedFood` is one item as first proposed: the item's id (ids survive editing, and a scan
that replaces an item keeps its id), name, grams, calories, database food, and **where its amount
came from** (`EstimatedFood.Amount`): your words, your usual (a food of yours, or a corrected
food), a learned factor, the model's guess, a depth measurement, or a meal copied from before.

There is no ledger store. `EstimateLedger.rows(meals)` pairs each estimate with what was logged,
by item id, whenever it's needed — like My foods' uses, read off the meal log, so it syncs with
the meals and can't drift from them. Outcomes: accepted, edited, scanned, removed (it named a food
that wasn't there), added (it missed one).

## 2. Learned portions (`LearnedPortions`)

For an amount the model guessed, logged grams ÷ estimated grams, from edited and scanned rows
only. Ratios outside 0.4–2.5 are left out (that's a different food or portion, not a habit).
The median of the newest 20, per food (by database food, then by name), once there are 3; else
per database category once there are 5. Applied in `GroundedFoodEstimate.resolve` only to a
guessed amount — never to one you said, or your usual — and shown in review:
"Rice ×1.3 — you usually have more than it guesses".

A name correction (`FoodCorrection`) now remembers the grams it was made at, so it works like a
food of yours: its numbers per gram are yours, and its amount is your usual unless your words say
otherwise. Before, a learned "rice" was a fixed number however much rice the photo showed.

Proven by replay before it's trusted (`LearnedPortions.backtest`): each edited row is estimated
with only the factors learned from rows before it; the factors stay on only if that's closer.

## 3. Your usual foods around now (`UsualFoods`)

From every logged meal, not just scanned packages: foods scored by how often you had them within
90 minutes of this time of day, newer counting more (45-day half-life, as My foods). The top 12
go to the model ("Foods they often have…"), and "Usually around now" chips in Describe what you
ate add one at your usual amount.

Groceries (15 Oct 2026): + › Groceries, or My foods › Scan what you bought, keeps the camera open
after shopping; each package joins your foods as its barcode is read, and every scan is a purchase
(`MyFood.bought`, once a day, synced). Bought within 21 days and not had since is "just bought"
(`MyFoods.justBought`): offered in Describe and an empty search ("Suggested") at a whole serving,
and named to the model, before it has ever been logged. Ranking adds purchases to uses, a purchase
counting half a use and fading with a 10-day half-life, so what you just bought sits above what
you stopped eating months ago and below what you have every day.

## 4. A meal you've had before, from its photo (`RepeatPhotoMeal`)

Each meal photo gets a Vision feature print, made on the device and kept there (never synced; any
device can remake it from the photo). A new photo close enough to a logged meal's proposes that
meal — "Looks like your Tuesday breakfast" — with Not the same, which estimates it fresh. The
threshold is set from a replay over the photos already logged, starting strict.

Built (3 Oct 2026): `MealPhotoPrints` (Vision revision 2, pinned; one file per photo and revision
under Application Support/MealPhotoPrints, out of backups), `RepeatPhotoMeal` (pure). Two meals'
distance is the farthest any photo of either is from its nearest in the other — every photo needs
a counterpart, since a meal's photos can show other foods eaten alongside. A match is under 0.60,
under 0.80 × the nearest *different* meal (other name, words and foods), from the last 120 days,
newest on a tie. The replay (the Mac's 7 meal photos): the one real repeat, a stew at lunch and
again at dinner, 0.574; 20 pairs of different foods 0.696–1.035. `--photo-repeat-probe` logs each
of the last 40 logged meals' nearest neighbour on a device ("🔬 repeat"), to move it on more.

The phone's own photos (5 Oct 2026: 19 logged meals, 26 photos, no repeats among them): nearest
neighbours 0.579–0.893, median 0.721, all different meals. The closest — two chicken-and-broccoli
plates the same day, potatoes at lunch and gnocchi at dinner — were 0.579, as near as the real
repeat, so the distance can't tell them apart. The second test can: that pair was 0.84 of the way
to its next different meal and was proposed at the old 0.85; the real repeat was 0.76. Hence
0.80. One of each is thin: run the probe again once a meal has really been photographed twice.

Words filled in (14 Oct 2026): a photo still waiting for "What was this?" — in To log, or in Add
photos & notes before it's added — that looks like a logged meal comes with that meal's words
already in the field (what was said for it, else its name): Add, or change them first. The test is
the one above with two differences, because the words are seen before they go: meals *said* alike
are one meal (`sameKind`: half the words of the shorter description in common, from the name and
what was said — not the foods' names, whose brands make everything alike), and the ratio is 0.82.
Replayed on the Mac's 31 photographed meals: his yogurt-and-granola breakfast, logged four times
under four names, was 0.53–0.60 from itself and 0.71+ from anything else; by name alone the other
breakfasts were its rivals and none was offered. With `sameKind` and 0.82 all three repeats were,
and nothing else (0.85 put a salad's words on tacos). Copying numbers keeps `sameMeal` and 0.80:
chicken, broccoli and gnocchi is said like chicken, broccoli and rice. Photo metadata isn't used:
time of day as a filter dropped the rivals that keep look-alikes apart (falafel went to gnocchi), a
stew was eaten at lunch and again at dinner, and the kept copies carry no location.

## 5. One question when it matters (`PortionQuestion`)

In a day's review, at most two items get "Rice: 1 cup · 1½ · 2" — the biggest whose amount was
only a guess (no words, no usual, no learned factor, no measurement), at least a quarter of the
meal's calories, with a database measure to ask in. An answer is an edit, so it teaches §2.
Something that comes whole is asked in whole ones ("1 miniature" cucumber, "1 medium" apple)
before cups; "Other…" opens the editor on that item, where any amount goes.

### One amount control, everywhere (`FoodAmountControl`)

A food found by name, an item of a meal, something scanned: all the same control — − a number +
and a row of chips for what it's counted in. The number takes any value (tap it and type; it's
selected, so what you type replaces it). The chips are "g" and "oz", fixed on the left because
they're always there, then the food's own measures scrolling beside them (USDA's "regular",
"cup", a scanned package's serving and the package itself); what one of the chosen measure
weighs is written beside the number. One tap changes the measure and keeps the weight — a menu
took two and hid the choices (MacroFactor's unit row is the reference). Grams step by 1 under 20 g, 5 under 100, 10 above. Numbers and the serving text follow.
Something with no weight and no food behind it (a typed "large 0.0 beer") is any number of what
was logged. A scanned food whose package states no serving has no amount until it's said
(docs/BARCODE_CATALOG.md).

### The Food tab, top to bottom

The day's card leads with the day: its date, the week, and "So far today" — calories and the
three macros on one line — as every food diary reference does (Lifesum, Yazio, MyFitnessPal). It
was a card of its own below "To log", a screen or two down on a day with photos waiting. Then
"Log food": four tiles on one row (Describe, Search, Scan, Photos; "Enter by hand" in the
header), where five full-width rows sat below "To log". Then what's waiting ("To log"), then
the day's meals. A failed estimate's actions sit on one wrapping line at footnote size — three
links stacked under a two-line error made one failed meal half a screen.

## 6. Your logs against your weight (`EnergyBalance`)

Report only, never applied. Over at least three weeks: the trend of your Health weight, the
Watch's active and resting energy, and what you logged on fully logged days. Intake the weight
implies = energy burned + weight change × 7,700 kcal/kg. "Your logs cover about 85% of what your
weight says you eat." Hidden until there's enough to say it.

## 7. Bench (`--estimator-bench`)

On a device (the model runs there): Nutrition5k dishes copied into the app's Documents/bench, and
your own scanned or edited meals with photos, estimated again; calorie and weight error per
estimator version, to the playback log. Run before raising `GroundedFoodEstimate.version`, which
re-estimates meals waiting for review. Nutrition5k is a Google cafeteria (CC BY 4.0): a regression
check, not a claim of accuracy.

## 8. Depth from Portrait photos (`MealPhotoDepth`)

A Portrait photo carries a depth map; so does a photo taken with Banana's camera on a phone with
LiDAR. When a meal photo is imported (library scan, picker, camera) its depth is read from the
original file and measured: the plate's size, and the food's volume and height above it.
`MealPhotoRef.depth` keeps the measurement (a few numbers, synced). The estimate is told it
("Measured from the photo: the plate is about 26 cm across; the food on it is about 540 ml"), and
`MealEstimate.measured` records that it was, so the ledger can show whether measured meals come
out closer. Bowls are only measured across: a camera can't see a bowl's depth from above.

Built (Oct 2026), `MealPhotoDepth.attempt`: the table is the plane the points sit on most closely
(RANSAC scored by squared distance, so a plane tilted to catch the table and a plate's floor loses;
a parallel plane just below wins in a close-up). What stands on it nearest the middle is laid on a
grid over the table — heights from straight above, not pixels — and its outline fitted with a
circle (else its longest extent). A plate is a rim above a lower floor, or a broad flat floor; its
surface runs inwards from the rim's crest and never rises, and the food is what stands above it.
What the food hides is filled half way between nothing and the line of sight. Ray-cast tests: food
within 13%, size within 1.5 cm, straight down to 45°. Relative depth is not measured. Import:
library scan (the original when the edited version lost the depth), picker (`.current`, then the
library original), drops, and Banana's camera (`MealDepthCamera`: LiDAR, else the dual cameras).
On a device, `--depth-probe` logs "🔬 depth" lines for the newest 20 photos with depth.

## 9. Search by name (`FoodSearch`)

"Trader Joe's cut and peeled carrots" with no photo, barcode or model: Log food › Search foods,
the meal editor's Add item, and a row's Search for it (the right food in place of a guess, at its
weight). Results, best first:

- **Yours:** items you've logged whose name — or the food behind it — has the words (a brand needn't
  be in it), at your usual weight (the middle of the last five); your scanned foods by name or
  `standsFor`; and whatever was picked for these words before (`FoodSearchPicks`, iCloud KVS:
  words → reference id → times). An empty search shows `UsualFoods` around now.
- **A brand's products, when one is named:** the brand is the search's first or last one to three
  words matching a bundled brand's first two or three words (one word only when FoodDatabase's
  `brand_words` says it's only ever a brand; "tj" is Trader Joe's) — and never words that name a
  USDA food, so "baby carrots raw" stays carrots. Its products: the bundled USDA ones, and Open Food
  Facts online (`<head word> AND brands:"<brand>"`; its search can't OR words), those whose name
  ends in the head word first ("Organic Whole Carrots" before "Carrot Ginger Soup").
- **Foods:** USDA, offline, searched without the brand (Trader Joe's carrots are carrots), from
  40 candidates down to 15 with the head word whole — "Scallops, fried", not "Potato, scalloped" —
  named-for-it first, each name once. The head word is the last food word before any "with".
- **Products** without a brand: bundled ones, and Open Food Facts' with every word in the name.

Picking opens the amount: the food's own measures ("1 cup · 120 g", "1 baby carrot · 10 g"),
grams or ounces, ± by a quarter or half measure, 10 g or 1 oz; switching measure keeps the weight.
The item keeps the food as its `FoodReference` ("off:<barcode>" for Open Food Facts), so its
numbers follow the weight and the learning above sees it like any other. A searched meal needs no
"I reviewed this": its numbers are the database's and its amount was chosen.

## Shared shapes

- `GroundedFoodEstimate.Context`: what's known besides the photos and words — `usualNames`,
  `measurements`, `portionFactor`. The processor builds it; the prompts carry it.
- `MealProposal.estimate`, `MealEntry.estimate`: §1.
- `MealProposal.repeatOf`, `MealInboxItem.notTheSame`: §4.
- `MealPhotoRef.depth`: §8.

Every new field decodes tolerantly: an older build reading a newer record keeps the record.
