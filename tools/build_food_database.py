#!/usr/bin/env python3
"""Build Banana's read-only food database (Banana/Resources/Foods.sqlite) from USDA FoodData Central.

Inputs are the CSV downloads from https://fdc.nal.usda.gov/download-datasets/ (public domain):
FNDDS survey foods (foods as eaten, including mixed dishes, with portion weights), SR Legacy and
Foundation Foods. The branded-product name index is built from the bundled
Banana/Resources/BarcodeProducts.sqlite (see tools/build_barcode_catalog.py).

    tools/build_food_database.py SURVEY.zip SR.zip FOUNDATION.zip Banana/Resources/Foods.sqlite

`--fixture` writes the small test database instead: the same code over a fixed handful of foods
and products (FIXTURE_FOODS / FIXTURE_BARCODES below), plus the matching slice of the products
table, so the Swift tests read exactly what this script produces.

What the Swift side (Banana/Model/FoodDatabase.swift) relies on:
- `foods`: one row per food, numbers per 100 g. `num` is the full-text rowid.
- `portions`: household measures in grams, `seq` in the source's order (most common first).
- `foods_fts`: contentless FTS5 over name, the name's first comma segment ("head") and category.
- `brand_words`: words the generic names only use as brands (see `brand_words`).
- `branded_fts`: contentless FTS5 over product name + brand, detail=none to stay small. Its rowid
  packs the barcode and an ordering prior (see `branded_rowid`), because detail=none gives bm25
  nothing to rank with — rows come back in rowid order, so the prior decides which come first.
  Only the index lives here; names, servings and label values stay in BarcodeProducts.sqlite.
"""

import argparse
import csv
import datetime as dt
import io
import os
import re
import sqlite3
import sys
import unicodedata
import zipfile

ENERGY_KCAL = "1008"
ENERGY_ATWATER_SPECIFIC = "2048"
ENERGY_ATWATER_GENERAL = "2047"
PROTEIN = "1003"
FAT = "1004"
FAT_NLEA = "1085"
CARBS = "1005"
CARBS_BY_SUMMATION = "1050"
WANTED_NUTRIENTS = {ENERGY_KCAL, ENERGY_ATWATER_SPECIFIC, ENERGY_ATWATER_GENERAL, PROTEIN, FAT,
                    FAT_NLEA, CARBS, CARBS_BY_SUMMATION}

# Measure units whose "portion" is a lab yield factor, not something a person eats.
SKIPPED_UNITS = {"paired cooked w", "paired raw w", "dripping w", "orig ckd g", "orig rw g", "undetermined"}
UNIT_PLURALS = {"cup": "cups", "tablespoon": "tablespoons", "teaspoon": "teaspoons", "slice": "slices",
                "piece": "pieces", "link": "links", "wedge": "wedges", "fruit": "fruits", "egg": "eggs",
                "banana": "bananas", "onion": "onions", "patty": "patties", "strip": "strips"}
FRACTIONS = {0.125: "1/8", 0.2: "1/5", 0.25: "1/4", 0.33: "1/3", 0.333: "1/3", 0.5: "1/2",
             0.66: "2/3", 0.667: "2/3", 0.67: "2/3", 0.75: "3/4"}

# Branded products: the serving text's metric amount ("1 bar (52 g)", "2 cups (28g) (28 GRM)",
# "1 Bottle (207 MLT)"). mL is taken as grams: the per-100 g figure is derived from the same
# serving, so the labelled serving still gives exactly the labelled calories. FoodDatabase.swift
# parses servings with the same two patterns and must stay in step with them.
METRIC_SERVING = re.compile(r"(\d+(?:\.\d+)?)\s*(g|grm|gram|grams|ml|mlt)\b", re.IGNORECASE)
OUNCE_SERVING = re.compile(r"\b(\d+(?:\.\d+)?)\s*(oz|onz)\b", re.IGNORECASE)  # "8 fl oz" has no number before "oz"
GRAMS_PER_OUNCE = 28.35
ZERO_CALORIE_NAME = re.compile(r"\b(diet|zero|sugar[- ]free|calorie[- ]free|0 ?cal\w*|water|seltzer|club soda|"
                               r"unsweetened|black coffee|tea)\b", re.IGNORECASE)
BARCODE_BITS = 51          # int(barcode) * 16 + len(barcode) < 1.6e15 < 2**51
MAX_PRIOR = (1 << 12) - 1  # prior << 51 must stay below 2**63

# The fixture the Swift tests read (BananaTests/Fixtures/FoodsFixture.sqlite): enough look-alikes
# to exercise ranking — banana vs banana bread, FNDDS vs SR vs Foundation, dishes vs ingredients.
FIXTURE_FOODS = {
    "fndds": [
        "2709224",  # Banana, raw
        "2709225",  # Banana, baked
        "2705697",  # Banana pudding
        "2706437",  # Chicken curry
        "2706438",  # Chicken curry with rice
        "2708408",  # Rice, white, cooked, no added fat
        "2708403",  # Rice, white, cooked, NS as to fat
        "2708422",  # Rice, white, cooked, glutinous
        "2708404",  # Rice, white, cooked, made with oil
        "2708804",  # Pad Thai, NFS
        "2708806",  # Pad Thai with chicken
        "2706916",  # Big Mac (McDonalds)
        "2705421",  # Yogurt, Greek, NS as to type of milk, plain
        "2706285",  # Fish, salmon, NFS
        "2706850",  # Lomi salmon
        "2706826",  # Salmon salad
        "2710537",  # Soft drink, NFS, diet
    ],
    "sr": [
        "173944",   # Bananas, raw
        "174906",   # Bread, banana, prepared from recipe, made with margarine
        "170720",   # McDONALD'S, BIG MAC
        "171296",   # Yogurt, Greek, nonfat, vanilla, CHOBANI
        "170379",   # Broccoli, raw — dropped: Foundation has the same name
    ],
    "foundation": [
        "1105073",  # Bananas, overripe, raw
        "2512381",  # Rice, white, long grain, unenriched, raw
        "747447",   # Broccoli, raw (newer)
        "321900",   # Broccoli, raw (older, dropped)
    ],
}
FIXTURE_BARCODES = [
    "0818290012791",   # VANILLA BLENDED GREEK YOGURT, VANILLA (Chobani, Inc.) — 1 container (150 g)
    "00894700010021",  # Chobani Vanilla Blended Non- Fat Greek Yogurt — 150 g
    "00818290016997",  # Chobani Oatmilk Vanilla
    "00859162007255",  # RXBAR PROTEIN BAR, 1.83 OZ, 10 COUNT
    "193908002813",    # ORANGE PROTEIN BAR, ORANGE (RXBAR)
    "602652170065",    # KIND, FRUIT & NUT BAR
    "00049000006582",  # Diet Coke Can, 12 fl oz — all zeros, and really zero
    "0019622043487",   # seasoning, "1/4 tsp" — no grams, not indexed
    "00013562474066",  # cookie mix, all zeros — missing data, not indexed
]


# MARK: - Reading the downloads

class Archive:
    """One FDC CSV download. Files are found by name, whatever the release folder is called."""

    def __init__(self, path):
        self.zip = zipfile.ZipFile(path)
        names = self.zip.namelist()
        self.folder = names[0].split("/")[0]
        self.names = {name.rsplit("/", 1)[-1]: name for name in names}
        match = re.search(r"(\d{4}-\d{2}(?:-\d{2})?)", self.folder) or re.search(
            r"(\d{4}-\d{2}(?:-\d{2})?)", os.path.basename(path))
        self.release = match.group(1) if match else "unknown"

    def rows(self, filename):
        with self.zip.open(self.names[filename]) as raw:
            yield from csv.DictReader(io.TextIOWrapper(raw, encoding="utf-8"))

    def nutrient_id_map(self):
        """FNDDS food_nutrient.csv carries the legacy nutrient *numbers* (208 = energy) where the
        other downloads carry nutrient ids (1008). Map both onto ids; the two ranges don't overlap."""
        mapping = {}
        for row in self.rows("nutrient.csv"):
            mapping[row["id"]] = row["id"]
            if row["nutrient_nbr"]:
                mapping.setdefault(row["nutrient_nbr"].split(".")[0], row["id"])
        return mapping

    def nutrients(self, fdc_ids):
        mapping = self.nutrient_id_map()
        values = {}
        for row in self.rows("food_nutrient.csv"):
            if row["fdc_id"] not in fdc_ids:
                continue
            nutrient = mapping.get(row["nutrient_id"])
            if nutrient in WANTED_NUTRIENTS and row["amount"] != "":
                values.setdefault(row["fdc_id"], {})[nutrient] = float(row["amount"])
        return values


def macros(values):
    """kcal, protein, carbs, fat per 100 g, or None when there's no energy to be had.

    Foundation Foods often lack energy (1008); Atwater specific factors (2048) match 1008 where
    both exist, general factors (2047) come next, then 4/4/9 — but only from all three macros,
    since dried beans listing protein and fat alone would come out absurdly low.
    """
    protein = values.get(PROTEIN)
    fat = values.get(FAT, values.get(FAT_NLEA))
    carbs = values.get(CARBS, values.get(CARBS_BY_SUMMATION))
    kcal = values.get(ENERGY_KCAL, values.get(ENERGY_ATWATER_SPECIFIC, values.get(ENERGY_ATWATER_GENERAL)))
    if kcal is None and None not in (protein, fat, carbs):
        kcal = 4 * protein + 4 * carbs + 9 * fat
    if kcal is None or (protein is None and fat is None and carbs is None):
        return None
    result = tuple(max(0.0, value or 0.0) for value in (kcal, protein, carbs, fat))
    if result[0] > 1000 or sum(result[1:]) > 105:
        return None
    return result


def amount_text(raw):
    try:
        amount = float(raw)
    except (TypeError, ValueError):
        return "1"
    whole = int(amount)
    fraction = round(amount - whole, 3)
    fraction_text = FRACTIONS.get(fraction) or FRACTIONS.get(round(fraction, 2))
    if fraction == 0:
        return str(whole)
    if fraction_text:
        return f"{whole} {fraction_text}" if whole else fraction_text
    return f"{amount:g}"


def is_plural_amount(raw):
    try:
        return float(raw) > 1
    except (TypeError, ValueError):
        return False


def tidy_label(label):
    return re.sub(r"\s+", " ", label).strip().strip(",")


# MARK: - Sources

def fndds_foods(archive):
    categories = {row["wweia_food_category"]: row["wweia_food_category_description"]
                  for row in archive.rows("wweia_food_category.csv")}
    wweia = {row["fdc_id"]: row["wweia_category_number"] for row in archive.rows("survey_fndds_food.csv")}
    foods = {row["fdc_id"]: row for row in archive.rows("food.csv") if row["data_type"] == "survey_fndds_food"}
    portions = {}
    for row in archive.rows("food_portion.csv"):
        grams = float(row["gram_weight"] or 0)
        description = row["portion_description"].strip()
        if row["fdc_id"] not in foods or grams <= 0 or not description:
            continue
        # FNDDS's weight for "the person didn't say how much" — a representative helping.
        label = "typical portion" if description.lower() == "quantity not specified" else description
        portions.setdefault(row["fdc_id"], []).append((int(row["seq_num"] or 0), tidy_label(label), grams))
    nutrients = archive.nutrients(foods.keys())
    for fdc_id, food in foods.items():
        category = categories.get(wweia.get(fdc_id) or food["food_category_id"], "")
        yield f"fndds:{fdc_id}", food["description"], category, nutrients.get(fdc_id, {}), portions.get(fdc_id, [])


def sr_or_foundation_foods(archive, data_type, prefix):
    categories = {row["id"]: row["description"] for row in archive.rows("food_category.csv")}
    units = {row["id"]: row["name"] for row in archive.rows("measure_unit.csv")}
    foods = {row["fdc_id"]: row for row in archive.rows("food.csv") if row["data_type"] == data_type}
    portions = {}
    for row in archive.rows("food_portion.csv"):
        grams = float(row["gram_weight"] or 0)
        if row["fdc_id"] not in foods or grams <= 0:
            continue
        unit = units.get(row["measure_unit_id"], "").strip()
        modifier = row["modifier"].strip()
        description = row["portion_description"].strip()
        if unit.lower() in SKIPPED_UNITS:
            unit = ""
        if unit == "RACC":
            unit = "serving (reference amount)"
        if unit:
            unit = unit.lower()
            if is_plural_amount(row["amount"]):
                unit = UNIT_PLURALS.get(unit, unit)
        words = [part for part in (unit, modifier[:1].lower() + modifier[1:] if unit else modifier) if part]
        measure = ", ".join(words) if unit and modifier else " ".join(words)
        if not measure:
            measure = description
        if not measure or re.fullmatch(r"\d+\s*(g|grams?)", measure):
            continue
        label = f"{amount_text(row['amount'])} {measure}"
        order = int(row["seq_num"]) if row["seq_num"] else int(row["id"])
        portions.setdefault(row["fdc_id"], []).append((order, tidy_label(label), grams))
    nutrients = archive.nutrients(foods.keys())
    # Newest first: Foundation publishes a re-analysed food under the same name as a new entry,
    # and `build` keeps the first of each name.
    newest_first = sorted(foods.items(), key=lambda item: (item[1]["publication_date"], int(item[0])), reverse=True)
    for fdc_id, food in newest_first:
        category = categories.get(food["food_category_id"], "")
        if category == "Quality Control Materials":
            continue
        yield f"{prefix}:{fdc_id}", food["description"], category, nutrients.get(fdc_id, {}), portions.get(fdc_id, [])


# MARK: - Branded products

def serving_grams(serving):
    """Grams in one labelled serving, or None. Mirrors `FoodDatabase.servingGrams(_:)`."""
    metric = METRIC_SERVING.findall(serving)
    if metric:
        return float(metric[-1][0])
    ounces = OUNCE_SERVING.findall(serving)
    if ounces:
        return float(ounces[-1][0]) * GRAMS_PER_OUNCE
    return None


def branded_rowid(barcode, name):
    """Barcode (with its length, so leading zeros survive) in the low bits, and an ordering prior
    — the product name's length — above it. Shorter names are the plainer products ("KIND, FRUIT &
    NUT BAR" before a 120-character multipack listing), and detail=none returns rows by rowid."""
    prior = min(MAX_PRIOR, len(name))
    return (prior << BARCODE_BITS) | (int(barcode) * 16 + len(barcode))


def branded_rows(products_path, only=None):
    products = sqlite3.connect(f"file:{products_path}?mode=ro", uri=True)
    seen = set()
    dropped = {"serving without grams": 0, "no nutrition": 0, "calories missing": 0, "impossible": 0,
               "duplicate name": 0}
    query = "SELECT barcode, name, brand, serving, calories, protein, carbs, fat FROM products ORDER BY published DESC, barcode"
    for barcode, name, brand, serving, kcal, protein, carbs, fat in products.execute(query):
        if only is not None and barcode not in only:
            continue
        grams = serving_grams(serving)
        if not grams or grams <= 0:
            dropped["serving without grams"] += 1
            continue
        if kcal <= 0 and protein <= 0 and carbs <= 0 and fat <= 0 and not ZERO_CALORIE_NAME.search(name):
            # The catalog stores a missing label value as 0, so all zeros usually means "no data".
            # A diet soda or a bottle of water really is zero, and its name says so.
            dropped["no nutrition"] += 1
            continue
        if kcal <= 0 and 4 * protein + 4 * carbs + 9 * fat > 5:
            dropped["calories missing"] += 1
            continue
        if kcal / grams * 100 > 950 or (protein + carbs + fat) / grams * 100 > 105:
            dropped["impossible"] += 1
            continue
        key = (" ".join(name.lower().split()), " ".join(brand.lower().split()))
        if key in seen:
            dropped["duplicate name"] += 1
            continue
        seen.add(key)
        yield branded_rowid(barcode, name.strip()), f"{name} {brand}".strip()
    print(f"branded dropped: {dropped}", file=sys.stderr)


# MARK: - Brand words

# Capitalised or parenthesised in the generic names without being a brand.
BRAND_WORD_NOISE = {"usa", "usda", "dha", "ara", "bbq", "one", "best", "healthy", "life", "way", "always", "step",
                    "nature", "natures", "group", "living", "zone", "snackfood", "grains", "farms", "selects", "salty",
                    "sweetsalty", "beach", "south", "border", "barrel", "machine", "protect", "fusion", "graduates",
                    "able", "after", "avenue", "daily", "earth", "eight", "man", "open", "power", "magic", "mighty",
                    "combo", "essential", "goodness", "feast", "hungry", "munch", "superfood", "whip", "chosen",
                    "miracle", "sunny", "symphony", "dinosaur", "crystal", "amber", "tiger", "teddy"}


def folded_pieces(text):
    """Diacritics folded, split on anything but ASCII letters and digits — the same words
    `FoodDatabase.words(_:)` makes of a query, before lowercasing."""
    text = "".join(c for c in unicodedata.normalize("NFKD", text) if not unicodedata.combining(c))
    return [piece for piece in re.split(r"[^0-9A-Za-z]+", text) if piece]


def crude_stem(word):
    """Plural folding shared with `FoodDatabase.stem(_:)`; porter does the real stemming inside FTS."""
    if len(word) > 4 and word.endswith("ies"):
        return word[:-3] + "y"
    if len(word) > 4 and word.endswith(("oes", "ches", "shes")):
        return word[:-2]
    if len(word) > 3 and word.endswith("s") and not word.endswith("ss"):
        return word[:-1]
    return word


def brand_words(foods):
    """Words that only ever appear in the generic names as brand names: in capitals in SR Legacy
    ("Yogurt, Greek, nonfat, vanilla, CHOBANI") or capitalised inside FNDDS's parentheses
    ("Nutrition bar (Clif Bar)"). A query containing one plausibly names a product, so the search
    adds branded matches even when a generic food matches every word."""
    brand, plain = set(), set()
    for food_id, name in foods:
        source = food_id.split(":")[0]
        inside = " ".join(re.findall(r"\(([^)]*)\)", name)) if source == "fndds" else ""
        outside = re.sub(r"\([^)]*\)", " ", name) if source == "fndds" else name
        for piece in folded_pieces(outside):
            letters = re.sub(r"[^A-Za-z]", "", piece)
            is_brand = source == "sr" and len(letters) >= 3 and sum(c.islower() for c in letters) <= 1
            (brand if is_brand else plain).add(crude_stem(piece.lower()))
        for piece in folded_pieces(inside):
            (brand if piece[0].isupper() else plain).add(crude_stem(piece.lower()))
    return sorted(word for word in brand - plain - BRAND_WORD_NOISE if len(word) >= 3 and not word.isdigit())


# MARK: - Build

SCHEMA = """
    PRAGMA journal_mode = OFF;
    PRAGMA synchronous = OFF;
    CREATE TABLE metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
    CREATE TABLE foods(
        num INTEGER PRIMARY KEY,
        id TEXT NOT NULL UNIQUE,
        name TEXT NOT NULL,
        category TEXT NOT NULL,
        kcal REAL NOT NULL,
        protein REAL NOT NULL,
        carbs REAL NOT NULL,
        fat REAL NOT NULL
    );
    CREATE TABLE portions(
        food_id TEXT NOT NULL,
        seq INTEGER NOT NULL,
        label TEXT NOT NULL,
        grams REAL NOT NULL,
        PRIMARY KEY(food_id, seq)
    ) WITHOUT ROWID;
    CREATE TABLE brand_words(word TEXT PRIMARY KEY) WITHOUT ROWID;
    CREATE VIRTUAL TABLE foods_fts USING fts5(
        name, head, category, content='', tokenize='porter unicode61 remove_diacritics 2');
    CREATE VIRTUAL TABLE branded_fts USING fts5(
        text, content='', detail=none, columnsize=0, tokenize='porter unicode61 remove_diacritics 2');
"""


def build(survey_zip, sr_zip, foundation_zip, output, products_path, fixture=False, fixture_products=None):
    survey, sr, foundation = Archive(survey_zip), Archive(sr_zip), Archive(foundation_zip)
    wanted = None
    if fixture:
        wanted = {f"{prefix}:{fdc_id}" for prefix, ids in FIXTURE_FOODS.items() for fdc_id in ids}

    if os.path.exists(output):
        os.remove(output)
    db = sqlite3.connect(output)
    db.executescript(SCHEMA)

    counts = {"fndds": 0, "sr": 0, "foundation": 0}
    skipped = {"fndds": 0, "sr": 0, "foundation": 0}
    kept_foundation_names = set()
    sources = [
        ("foundation", sr_or_foundation_foods(foundation, "foundation_food", "foundation")),
        ("fndds", fndds_foods(survey)),
        ("sr", sr_or_foundation_foods(sr, "sr_legacy_food", "sr")),
    ]
    dropped_duplicates = {"older Foundation entry": 0, "SR Legacy entry named like a Foundation food": 0}
    num = 0
    for source, foods in sources:
        for food_id, name, category, nutrients, portions in foods:
            if wanted is not None and food_id not in wanted:
                continue
            values = macros(nutrients)
            if values is None:
                skipped[source] += 1
                continue
            folded = " ".join(name.lower().split())
            if source == "foundation":
                if folded in kept_foundation_names:
                    dropped_duplicates["older Foundation entry"] += 1
                    continue
                kept_foundation_names.add(folded)
            elif source == "sr" and folded in kept_foundation_names:
                # Foundation re-analysed this food under the same name; its numbers are newer.
                dropped_duplicates["SR Legacy entry named like a Foundation food"] += 1
                continue
            num += 1
            db.execute("INSERT INTO foods VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                       (num, food_id, name, category, *(round(value, 2) for value in values)))
            head = name.split(",", 1)[0]
            db.execute("INSERT INTO foods_fts(rowid, name, head, category) VALUES (?, ?, ?, ?)",
                       (num, name, head, category))
            labels = set()
            seq = 0
            for _, label, grams in sorted(portions, key=lambda portion: portion[0]):
                if label.lower() in labels:
                    continue
                labels.add(label.lower())
                seq += 1
                db.execute("INSERT INTO portions VALUES (?, ?, ?, ?)", (food_id, seq, label, round(grams, 1)))
            counts[source] += 1

    names = db.execute("SELECT id, name FROM foods").fetchall()
    brands = brand_words(names)
    db.executemany("INSERT INTO brand_words VALUES (?)", ((word,) for word in brands))

    only = set(FIXTURE_BARCODES) if fixture else None
    branded = 0
    for rowid, text in branded_rows(products_path, only):
        db.execute("INSERT INTO branded_fts(rowid, text) VALUES (?, ?)", (rowid, text))
        branded += 1

    products_meta = dict(sqlite3.connect(f"file:{products_path}?mode=ro", uri=True).execute(
        "SELECT key, value FROM metadata"))
    metadata = {
        "source": "USDA FoodData Central (public domain)",
        "source_url": "https://fdc.nal.usda.gov/download-datasets/",
        "fndds_release": survey.release,
        "sr_legacy_release": sr.release,
        "foundation_release": foundation.release,
        "branded_release": products_meta.get("release", "unknown"),
        "branded_source": "BarcodeProducts.sqlite (" + products_meta.get("source", "USDA branded foods") + ")",
        "build_date": dt.date.today().isoformat(),
        "fts": "fts5",
        "count_fndds": str(counts["fndds"]),
        "count_sr": str(counts["sr"]),
        "count_foundation": str(counts["foundation"]),
        "count_branded_indexed": str(branded),
        "count_brand_words": str(len(brands)),
    }
    db.executemany("INSERT INTO metadata VALUES (?, ?)", sorted(metadata.items()))
    db.commit()
    db.execute("INSERT INTO foods_fts(foods_fts) VALUES ('optimize')")
    db.execute("INSERT INTO branded_fts(branded_fts) VALUES ('optimize')")
    db.commit()
    db.execute("VACUUM")
    portions_count = db.execute("SELECT count(*) FROM portions").fetchone()[0]
    db.close()

    if fixture_products:
        write_fixture_products(products_path, fixture_products)

    size = os.path.getsize(output) / 1_000_000
    print(f"foods: {counts}; skipped (no energy/macros): {skipped}; duplicates dropped: {dropped_duplicates}; "
          f"portions: {portions_count:,}; branded indexed: {branded:,}; {output}: {size:.1f} MB")


def write_fixture_products(products_path, output):
    """The slice of BarcodeProducts.sqlite the fixture's branded index points into, same schema."""
    if os.path.exists(output):
        os.remove(output)
    source = sqlite3.connect(f"file:{products_path}?mode=ro", uri=True)
    schema = [sql for (sql,) in source.execute("SELECT sql FROM sqlite_master WHERE type = 'table'")]
    target = sqlite3.connect(output)
    for sql in schema:
        target.execute(sql)
    target.executemany("INSERT INTO metadata VALUES (?, ?)", source.execute("SELECT key, value FROM metadata"))
    marks = ",".join("?" * len(FIXTURE_BARCODES))
    target.executemany(f"INSERT INTO products VALUES ({','.join('?' * 9)})",
                       source.execute(f"SELECT * FROM products WHERE barcode IN ({marks})", FIXTURE_BARCODES))
    target.commit()
    target.execute("VACUUM")
    target.close()


def main():
    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("survey_zip", help="FoodData_Central_survey_food_csv_*.zip (FNDDS)")
    parser.add_argument("sr_zip", help="FoodData_Central_sr_legacy_food_csv_*.zip")
    parser.add_argument("foundation_zip", help="FoodData_Central_foundation_food_csv_*.zip")
    parser.add_argument("output", help="where to write Foods.sqlite")
    parser.add_argument("--products", default=os.path.join(repo, "Banana/Resources/BarcodeProducts.sqlite"),
                        help="BarcodeProducts.sqlite to index by name (default: the bundled one)")
    parser.add_argument("--fixture", action="store_true",
                        help="build the small test database from FIXTURE_FOODS / FIXTURE_BARCODES")
    parser.add_argument("--fixture-products", help="with --fixture: also write the matching products slice here")
    args = parser.parse_args()
    build(args.survey_zip, args.sr_zip, args.foundation_zip, args.output, args.products,
          fixture=args.fixture, fixture_products=args.fixture_products)


if __name__ == "__main__":
    main()
