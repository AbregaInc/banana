#!/usr/bin/env python3
"""Build Banana/Resources/TakenVocabulary.json: the names of things people take, for telling which
repeating reminders belong in Taken (ReminderToTaken, docs/design/ANCHORED-TIMING.md).

Two free US-government sources, both public domain:
  * RxNorm Current Prescribable Content (NLM): every prescribable drug's ingredient and brand
    names — levothyroxine, Synthroid, sertraline, Zoloft. These are medications.
  * NIH's Dietary Supplement Label Database (DSLD, CC0): the ingredient groups of a sample of its
    labels (creatine, ashwagandha, L-theanine…) and the brands that make many of them. These are
    supplements.

Brand names that are one ordinary English word are left out (a dictionary check): a brand called
"Now" mustn't make a reminder look like a pill. Ingredients aren't — creatine and aspirin are
dictionary words and exactly what's wanted — but foods and generic words are ("water", "apple",
"sugar"): "Water the plants" is a chore.

    tools/build_taken_vocabulary.py [--labels 30000] [--cache build/taken-vocabulary]
"""
import argparse
import io
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request
import zipfile

RXNORM = "https://download.nlm.nih.gov/rxnorm/RxNorm_full_prescribe_current.zip"
DSLD = "https://api.ods.od.nih.gov/dsld/v9/search-filter?q={q}&size={size}&from={start}&status=1"
# The API pages no further than 10,000 labels a query: several queries reach more of them.
DSLD_QUERIES = ["*", "vitamin", "mineral", "botanical", "amino", "protein", "probiotic", "omega",
                "creatine", "electrolyte", "greens", "magnesium", "collagen", "sleep", "fiber"]
# Foods and generic words that DSLD lists as ingredients and a chore can be named after.
GENERIC = set("""water salt sugar oil oils honey rice milk coffee tea alcohol oxygen air glycerin gelatin
cellulose starch flavor flavors color colors sodium chloride carbon nitrogen sucrose fructose glucose
dextrose lactose corn wheat soy egg eggs fish beef chicken pork apple apples orange oranges lemon lemons
lime banana bananas berry berries grape grapes coconut cocoa chocolate vanilla mint pepper garlic onion
tomato carrot carrots potato potatoes oats oat barley bean beans pea peas nut nuts almond almonds peanut
cherry cherries peach pear plum melon mango pineapple strawberry blueberry raspberry cranberry olive
olives cinnamon nutmeg clove cloves salt sea vinegar yeast flour bread butter cream cheese yogurt juice
blend proprietary other natural organic plant leaf root seed seeds fruit flower bark extract powder
gold silver fat bone bones heart brain liver eye eyes kidney lung skin hair blood muscle joint""".split())
# Supplement brands too new or too small for the label sample, named as people name them.
BRANDS = ["ag1", "athletic greens", "lmnt", "momentous", "liquid iv", "liquid i v", "nuun", "transparent labs",
          "thorne", "nutricost", "garden of life", "nature made", "now foods", "pure encapsulations", "life extension",
          "optimum nutrition", "vital proteins", "sports research", "doctor's best", "jarrow", "solgar"]
# Ingredient categories that are what a label is for, not what holds it together.
ACTIVE = {"vitamin", "mineral", "botanical", "amino acid", "fatty acid", "protein", "enzyme",
          "probiotic", "prebiotic", "non-nutrient/non-botanical", "fiber", "blend",
          # Melatonin is a "hormone", probiotics "bacteria", fish oil and MCT a "fat", collagen an
          # "animal part or source".
          "hormone", "bacteria", "fat", "animal part or source"}
DICTIONARY = "/usr/share/dict/words"


def get(url, attempts=4):
    for attempt in range(attempts):
        try:
            with urllib.request.urlopen(url, timeout=120) as response:
                return response.read()
        except Exception as error:  # flaky public APIs: back off and retry
            if attempt == attempts - 1:
                raise
            time.sleep(2 ** attempt)
            print(f"  retrying ({error})", file=sys.stderr)


def cached(path, url):
    if not os.path.exists(path):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        data = get(url)
        with open(path, "wb") as f:
            f.write(data)
    with open(path, "rb") as f:
        return f.read()


def tidy(name):
    name = name.lower().replace("®", "").replace("™", "")
    name = re.sub(r"\s*\([^)]*\)", "", name)          # "magnesium (as glycinate)" → "magnesium"
    name = re.sub(r"[^a-z0-9+\- ]", " ", name)
    return re.sub(r"\s+", " ", name).strip(" -")


def rxnorm(cache):
    """(ingredients, brands): generic names, and brand names, kept apart — only brands get the
    dictionary check."""
    data = cached(os.path.join(cache, "rxnorm.zip"), RXNORM)
    ingredients, brands = set(), set()
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        conso = next(n for n in z.namelist() if n.endswith("RXNCONSO.RRF"))
        for line in io.TextIOWrapper(z.open(conso), encoding="utf-8"):
            f = line.split("|")
            # Ingredients, precise ingredients and brand names, in RxNorm's own vocabulary.
            if f[11] == "RXNORM" and f[12] in ("IN", "PIN", "BN"):
                name = tidy(f[14])
                if 3 <= len(name) <= 40:
                    (brands if f[12] == "BN" else ingredients).add(name)
    return ingredients, brands


def dsld(cache, labels):
    groups, brands = {}, {}
    page = 1000
    seen = set()
    for q in DSLD_QUERIES:
      for start in range(0, min(labels, 10000), page):
        try:
            raw = cached(os.path.join(cache, f"dsld-{q}-{start}.json"),
                         DSLD.format(q=urllib.parse.quote(q), size=page, start=start))
            hits = json.loads(raw).get("hits", [])
        except Exception as error:
            print(f"  {q} {start}: {error}", file=sys.stderr)
            break
        if not hits:
            break
        for hit in hits:
            if hit.get("_id") in seen:
                continue
            seen.add(hit.get("_id"))
            source = hit.get("_source", hit)
            brand = tidy(source.get("brandName") or "")
            if brand:
                brands[brand] = brands.get(brand, 0) + 1
            for ingredient in source.get("allIngredients") or []:
                if (ingredient.get("category") or "").lower() not in ACTIVE:
                    continue
                group = tidy(ingredient.get("ingredientGroup") or "")
                if 3 <= len(group) <= 40:
                    groups[group] = groups.get(group, 0) + 1
        print(f"  DSLD {q}: {start + len(hits)} (labels so far {len(seen)})", file=sys.stderr)
    # Ingredients seen on a few labels at least; brands that make a fair number.
    return {g for g, n in groups.items() if n >= 3}, {b for b, n in brands.items() if n >= 15}


def ordinary(words):
    try:
        with open(DICTIONARY) as f:
            words.update(w.strip().lower() for w in f if w.strip())
    except OSError:
        pass
    return words


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--labels", type=int, default=30000)
    parser.add_argument("--cache", default="build/taken-vocabulary")
    parser.add_argument("--out", default="Banana/Resources/TakenVocabulary.json")
    args = parser.parse_args()

    common = ordinary(set())
    def brand(name):
        # A brand that's one ordinary word ("now", "alert") says nothing; two or more words, or a
        # word no dictionary has, does.
        return " " in name or name not in common
    def ingredient(name):
        return name not in GENERIC and not all(word in GENERIC for word in name.split())

    drug_names, drug_brands = rxnorm(args.cache)
    groups, brands = dsld(args.cache, args.labels)
    # What supplement labels call an ingredient is a supplement, even when RxNorm also lists it
    # (creatine, melatonin, magnesium, vitamin D): only what's left there is a medication.
    supplements = {n for n in groups if ingredient(n)} | {n for n in brands if brand(n) and ingredient(n)}
    supplements |= {tidy(b) for b in BRANDS}
    medications = ({n for n in drug_names if ingredient(n)} | {n for n in drug_brands if brand(n) and ingredient(n)}) - supplements
    out = {
        "sources": "RxNorm Current Prescribable Content (NLM, public domain); "
                   "NIH Dietary Supplement Label Database (CC0)",
        "built": time.strftime("%Y-%m-%d"),
        "medications": sorted(medications),
        "supplements": sorted(supplements),
    }
    with open(args.out, "w") as f:
        json.dump(out, f, separators=(",", ":"))
    print(f"{len(medications)} medications, {len(supplements)} supplements → {args.out} "
          f"({os.path.getsize(args.out) // 1024} KB)")


if __name__ == "__main__":
    main()
