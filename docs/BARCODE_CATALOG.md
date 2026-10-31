# Barcode lookup: bundled catalog, then a merged online cascade

Barcode lookup starts with the bundled, read-only SQLite catalog at `Banana/Resources/BarcodeProducts.sqlite` — instant and fully offline. On a miss, Banana falls back to a live cascade across three online sources: Open Food Facts, NIH's Dietary Supplement Label Database (DSLD), and — only as a last resort — UPCitemdb. This is a deliberate, narrow exception to Banana's long-standing "no network request" design for barcode lookup — see why below.

A 42-product measurement across 14 real supplement brands is what drives every choice below: Open Food Facts alone matched 52.4% of real supplement barcodes (matching the owner's own reported experience), and its matches were often poor quality — about 36% had a bare generic name, others carried the brand twice, embedded the pack size, were in the wrong language, or had a missing/unparseable serving. The cascade documented here reaches 88–95% coverage on that same set and cleans up the records it returns.

## Bundled catalog (tier 1)

- Source: USDA FoodData Central Global Branded Food Products Database
- Release: April 30, 2026
- Source download: <https://fdc.nal.usda.gov/download-datasets/>
- Bundled fields: GTIN/UPC, description, brand owner, serving text, calories, protein, carbohydrate, and fat
- Catalog rows: 455,332 unique barcodes
- Bundled size: approximately 54 MB

The catalog is generated from USDA's branded-food JSON archive:

```sh
python3 -m pip install ijson
python3 tools/build_barcode_catalog.py FoodData_Central_branded_food_json_2026-04-30.zip Banana/Resources/BarcodeProducts.sqlite
```

This source is built from **Nutrition Facts** label submissions for retail groceries. Dietary supplements carry a **Supplement Facts** panel under a different FDA regime and are essentially absent from it — scanning a supplement bottle used to fail every time, with no signal beyond a generic "not found" caption. That is the bug the online cascade fixes.

## Online cascade (tiers 2–4): Open Food Facts + DSLD, then UPCitemdb

On a bundled-catalog miss (and a cache miss), Banana queries Open Food Facts and DSLD **concurrently** — both are free, unauthenticated, and effectively unlimited, so there's no cost to always trying both:

- **Open Food Facts** — `https://world.openfoodfacts.org/api/v2/product/<barcode>.json?fields=code,product_name,brands,quantity,product_quantity,serving_size,serving_quantity,nutriments`, with a descriptive User-Agent (an anonymous one gets rate-limited to a 503) and a ~10 second timeout.
- **DSLD** — barcode-queryable only in one specific, documented way: take the UPC-A digits, regroup them into the `1-5-5-1` pattern with spaces, wrap the whole thing in double quotes, and query `GET https://api.ods.od.nih.gov/dsld/v9/search-filter?q="0 31604 02678 3"&status=2`. Unquoted search text returns noise; unspaced digits return nothing. `BarcodeProductLookup.dsldSearchQuery(forBarcode:)` builds this exact string, and only attempts it when the barcode reduces cleanly to a 12-digit UPC-A (itself, or a 13-digit EAN with a single leading padding zero stripped) — a genuine European EAN-13 never matched under any grouping in the measurement, so DSLD is skipped for those rather than guessing. DSLD's search endpoint ranks by text relevance, not barcode equality, so its top hit is confirmed against the returned label's own `upcSku` field (`BarcodeProductLookup.matchesDSLDUpcSku(_:barcode:)`) before being accepted — never trusted on rank alone.

If both come back empty, Banana falls through to **UPCitemdb** (`https://api.upcitemdb.com/prod/trial/lookup?upc=<barcode>`) — the strongest single source in the measurement (85.7% on an unbiased subset) but the only rate-limited one: its trial tier allows roughly 100 requests a day with a burst bucket of 6 that refills within a minute. `UPCItemDBRateLimiter` paces requests to roughly one every 11 seconds and tracks the service's own `X-RateLimit-Remaining`/`X-RateLimit-Reset` response headers as the authoritative budget, persisted to disk so a relaunch mid-day doesn't forget how much is already spent. Because UPCitemdb is only ever queried after the two free sources have both missed, its scarce budget is spent purely on coverage gaps — in the measurement this tier only ever added a handful of barcodes beyond what Open Food Facts + DSLD already found.

A request being paced or throttled reports as `BarcodeLookupOutcome.rateLimited` — never `.notFound`, since "UPCitemdb is being conserved right now" and "this product doesn't exist" are different facts and must never look the same to the person scanning.

Every successful result — already merged and cleaned, see below — is cached on disk (`BarcodeNetworkCache`, next to the app's other data via `AppSupport.directory`, bounded to 200 entries with oldest-first eviction), so a repeat scan of the same bottle is instant and offline again, same as the bundled catalog.

`BarcodeProductLookup.lookup(_:)` returns a `BarcodeLookupOutcome`, not an optional, specifically so these five cases stay distinguishable end to end (down to the caption text in `WellnessView`): found in the bundled catalog, found online, genuinely not found in any source, a network/lookup failure, and UPCitemdb being rate-limited. Collapsing any of the last three into one "not found" was the original bug's proximate cause — it made a network hiccup (or a throttle) indistinguishable from "this product doesn't exist," so a person standing in their kitchen with no signal, or mid-scan-session on a busy day, saw the same unhelpful message as a product Banana had never heard of.

### Merging across sources, not first-wins

A later source can have a better name while an earlier one had the better serving size, so Open Food Facts and DSLD results are merged field-by-field (`BarcodeProductLookup.mergeFields(_:)`) rather than whichever answered first winning outright: DSLD's `fullName`/`brandName` are NIH-curated label transcriptions, consistently complete and clean in the measurement, so they win the `name`/`brand` tie when both sources have the barcode; Open Food Facts' `serving_size`, when present, is already a clean short phrase, so it wins the `serving` tie. UPCitemdb is not part of that merge — it only ever appears alone, since it's only queried when the free sources found nothing to merge with. Every `BarcodeProduct` records which source contributed its `name` and `serving` (`nameSource`/`servingSource`), so the UI can say where a value came from instead of one opaque "found online."

### Per 100 g is not per serving, and a package is not a serving

`BarcodeProduct.macros` is the nutrition in **one `serving`**, from every source. The bundled catalog stores it that way. Open Food Facts gives nutrition **per 100 g** (`energy-kcal_100g` and friends), so it is scaled to the serving once, when the product is finished (`BarcodeProductLookup.servingAndMacros`): by the weight in the serving's own text ("1 egg (50 g)"), else Open Food Facts' `serving_quantity`. The per-100 g numbers ride along as `BarcodeProduct.per100g`, so a scanned food (`MyFoods.food(product:)`) takes them as given instead of working them back out.

Until 5 Oct 2026 the per-100 g numbers were stored as a serving's, unscaled. Everything Open Food Facts found was off by 100 ÷ its serving's grams — a 50 g egg at 140 kcal, 100 g of potatoes at 368 — unless its serving happened to be 100 g. The online cache moved to a new file (`BarcodeNetworkCache-2.json`) so nothing mis-scaled is served again, and what was already stored is put right by one rule: **a scanned food's numbers are what scanning its barcode gives now.** `ScannedNumbersRepair` looks each barcode food up again and brings it into line (`MyFoods.reconciled`), then the meals and waiting estimates logged from it, at the weight they were logged at. It compares with the source and never multiplies, so it gives the same answer however often it runs. The first version multiplied wherever a synced `numbers` revision read "not yet" — and a device still on the older build saved corrected foods back without that field, which would have had the next build correct them twice. What has been checked is remembered per device, by the numbers it was checked at, so a stale copy arriving by sync is checked again.

Only `serving_size` is a serving. A product with nutrition and no serving used to fall back on `quantity`, the package's size: a 72 g pack of seaweed became "one serving", 72 g of it. Now its serving is "100 g" — the one amount its numbers are true of — with `servingStated == false` and the pack kept as `packageGrams`. Nothing is counted in servings of such a food (`MyFood.servingStated`): its amount comes from your usual, else the estimate it replaced, else it is asked for — it starts at 0 g and the meal can't be saved until it's said. A product with no nutrition (a supplement) still falls back on its package text, as before.

### Cleaning up what comes back

The merged record's `name`/`brand`/`serving` are passed through `ProductRecordCleaner` before ever reaching the person — the "poor names" half of the original bug. It tries Apple's on-device model first (same call shape as `CreditsExtractor`/`FoodTextExtractor`): strip a brand mention repeated inside the name, strip pack size and unit counts (never a dose amount like "5000 IU"), fix a field stored as all-caps, and leave a genuinely generic name (e.g. "Fish oil") alone rather than inventing detail. It never touches a nutrition number — only text. When the model is unavailable, `ProductRecordCleaner.deterministicClean` implements the same three mechanical rules on its own (regex/rule-based, no model), so cleanup still happens, just less nuanced; `BarcodeProduct.nameCleanedByModel` records which path ran so a fallback is never presented silently as if the model had reviewed it.

### Why the network exception is scoped the way it is

Banana's design principle — no network request for barcode lookup — exists so the feature never has a spinner-forever failure mode and never has a privacy surface. Both are preserved here: a catalog hit (the common case, most packaged food) still never touches the network at all; a network attempt that fails for any reason (offline, timeout, server error) resolves promptly to a clean, clearly-labeled outcome instead of hanging; and only the barcode itself — not any other nutrition history — ever leaves the device. The trade only activates on a local miss, which is exactly the situation the offline design principle was already failing for every supplement scan.

## Photographing the label — the guaranteed fallback

No barcode database will ever cover every bottle. The supplement editor's "Photograph label" button (next to "Scan barcode", reusing the same `CameraPicker` used for meal photos — a still photo lets a curved bottle be framed, unlike the live barcode scanner) runs `SupplementLabelExtractor`: Vision's `VNRecognizeTextRequest` at `.accurate` recognition with `automaticallyDetectsLanguage` on (European packaging routinely repeats the panel in two or three languages on one label), then Apple's on-device model turns the recognized lines into a structured name + serving/dose, explicitly told the panel may be multilingual so it doesn't splice two languages into one field. The same 4096-token context-window hazard `CreditsExtractor` guards against applies here (a long ingredients panel plus OCR noise can overflow it), handled the same way: a length cap on the OCR text and a distinct "permanently unavailable for this photo" outcome rather than a retry that would fail identically.

Every field the label reader fills carries its own OCR recognition confidence, traced back to the specific recognized line it came from (`SupplementLabelExtractor.confidence(forValue:in:)`) — never a value the pipeline can't back up with an actual photographed line. The confirm-before-save form gives a value under 90% confidence the same amber-vs-plain treatment (and the same 90% cutoff) the natural-language food entry review screen already uses for its own AI-estimated rows, per-row rather than one blanket warning for the whole panel — since a photo routinely has some perfectly legible lines next to some genuinely hard ones, and a misread number off a photo looks exactly as authoritative as a correct one.

`SupplementSchedule` only has a `name` and a free-text `dose` field, so that's all this pass fills. A fuller structured record would need at minimum: a separate brand field, a structured active-ingredient list (name, amount, unit, %DV), servings per container, physical form (capsule/tablet/liquid/powder/gummy), and any allergen/warning statements — none of which fit the current model, and none of which this pass invents to compensate.

## Supplements are not food

A vitamin D capsule or a magnesium tablet legitimately has no calories, protein, carbohydrate, or fat — there is no Nutrition Facts panel to source it from, whichever online source (or the bundled catalog) it came from. `BarcodeProduct.macros` is `NutritionMacros?`, and `nil` is a normal, successful outcome (name, brand, and serving still populate) — never a failure, and never coerced to a confident "0 kcal." Only Open Food Facts ever supplies macros — neither DSLD nor UPCitemdb carry a Nutrition Facts panel at all.

Product data may be incomplete or outdated regardless of source. Banana keeps every populated field editable and requires review before a nutrition or supplement entry is saved. Banana never guesses an active ingredient or dose, and an unknown barcode — checked against every source — falls back to a photographed label or manual entry.
