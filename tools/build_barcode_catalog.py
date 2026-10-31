#!/usr/bin/env python3
"""Build Banana's compact, read-only barcode catalog from a USDA branded-food JSON archive."""

import argparse
import datetime as dt
import sqlite3
import sys
import zipfile

import ijson


NUTRIENT_IDS = {1008: "calories", 1003: "protein", 1005: "carbs", 1004: "fat"}


def number(value):
    try:
        return max(0.0, float(value))
    except (TypeError, ValueError):
        return None


def label_value(product, key):
    value = product.get("labelNutrients", {}).get(key, {}).get("value")
    return number(value)


def derived_values(product):
    serving_size = number(product.get("servingSize"))
    serving_unit = str(product.get("servingSizeUnit") or "").lower()
    scale = serving_size / 100 if serving_size is not None and serving_unit in {"g", "ml"} else None
    values = {}
    for item in product.get("foodNutrients", []):
        nutrient_id = item.get("nutrient", {}).get("id")
        field = NUTRIENT_IDS.get(nutrient_id)
        amount = number(item.get("amount"))
        if field and amount is not None and scale is not None:
            values[field] = amount * scale
    return values


def serving_text(product):
    household = str(product.get("householdServingFullText") or "").strip()
    amount = product.get("servingSize")
    unit = str(product.get("servingSizeUnit") or "").strip()
    metric = f"{amount:g} {unit}" if isinstance(amount, (int, float)) else ""
    if household and metric and metric.lower() not in household.lower():
        return f"{household} ({metric})"
    return household or metric or "1 serving"


def published_sort_key(value):
    try:
        return dt.datetime.strptime(value, "%m/%d/%Y").strftime("%Y-%m-%d")
    except (TypeError, ValueError):
        return "0000-00-00"


def build(archive_path, output_path):
    connection = sqlite3.connect(output_path)
    connection.executescript("""
        PRAGMA journal_mode = OFF;
        PRAGMA synchronous = OFF;
        PRAGMA temp_store = MEMORY;
        CREATE TABLE metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
        CREATE TABLE products(
            barcode TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            brand TEXT NOT NULL,
            serving TEXT NOT NULL,
            calories REAL NOT NULL,
            protein REAL NOT NULL,
            carbs REAL NOT NULL,
            fat REAL NOT NULL,
            published TEXT NOT NULL
        ) WITHOUT ROWID;
    """)
    connection.executemany(
        "INSERT INTO metadata VALUES (?, ?)",
        [
            ("source", "USDA FoodData Central Global Branded Food Products Database"),
            ("release", "2026-04-30"),
            ("source_url", "https://fdc.nal.usda.gov/download-datasets/"),
        ],
    )

    inserted = 0
    supplement_count = 0
    with zipfile.ZipFile(archive_path) as archive:
        json_name = next(name for name in archive.namelist() if name.endswith(".json"))
        with archive.open(json_name) as source:
            products = ijson.items(source, "BrandedFoods.item")
            for product in products:
                barcode = str(product.get("gtinUpc") or "").strip()
                name = str(product.get("description") or "").strip()
                if not barcode.isdigit() or not 8 <= len(barcode) <= 14 or not name:
                    continue

                derived = derived_values(product)
                calories = label_value(product, "calories")
                protein = label_value(product, "protein")
                carbs = label_value(product, "carbohydrates")
                fat = label_value(product, "fat")
                values = (
                    calories if calories is not None else derived.get("calories", 0),
                    protein if protein is not None else derived.get("protein", 0),
                    carbs if carbs is not None else derived.get("carbs", 0),
                    fat if fat is not None else derived.get("fat", 0),
                )
                category = str(product.get("brandedFoodCategory") or "")
                if "supplement" in category.lower():
                    supplement_count += 1

                connection.execute(
                    """
                    INSERT INTO products VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(barcode) DO UPDATE SET
                        name=excluded.name, brand=excluded.brand, serving=excluded.serving,
                        calories=excluded.calories, protein=excluded.protein,
                        carbs=excluded.carbs, fat=excluded.fat, published=excluded.published
                    WHERE excluded.published >= products.published
                    """,
                    (
                        barcode,
                        name[:160],
                        str(product.get("brandOwner") or "").strip()[:120],
                        serving_text(product)[:120],
                        *values,
                        published_sort_key(product.get("publicationDate")),
                    ),
                )
                inserted += 1
                if inserted % 25_000 == 0:
                    connection.commit()
                    print(f"processed {inserted:,}", file=sys.stderr)

    connection.commit()
    connection.execute("VACUUM")
    count = connection.execute("SELECT count(*) FROM products").fetchone()[0]
    connection.close()
    print(f"catalog rows: {count:,}; supplement-category rows seen: {supplement_count:,}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("archive")
    parser.add_argument("output")
    args = parser.parse_args()
    build(args.archive, args.output)


if __name__ == "__main__":
    main()
