#!/usr/bin/env python3
"""Fetch a sample of Nutrition5k dishes for Banana's estimator bench (`--estimator-bench`).

Nutrition5k (Google Research, CC BY 4.0) photographed real cafeteria plates from above and weighed
every ingredient. Each dish here is its overhead photo plus the weighed truth: total calories, total
grams, and the ingredients. It's a Google cafeteria, not home plates — a check that a change to
the estimator doesn't make it worse, not a claim of how accurate it is.

    tools/bench/fetch_nutrition5k.py [--count 60] [--seed 7] [--out build/bench/nutrition5k]

Writes manifest.json and one PNG per dish. Copy the folder to a device with tools/bench/push.sh.
"""
import argparse
import csv
import io
import json
import os
import random
import urllib.request

BUCKET = "https://storage.googleapis.com/nutrition5k_dataset/nutrition5k_dataset"
LISTING = ("https://storage.googleapis.com/storage/v1/b/nutrition5k_dataset/o"
           "?prefix=nutrition5k_dataset/imagery/realsense_overhead/&delimiter=/&maxResults=1000")


def get(url):
    with urllib.request.urlopen(url, timeout=60) as response:
        return response.read()


def overhead_dishes():
    """Every dish with an overhead photo (not all dishes have one)."""
    dishes, token = [], None
    while True:
        page = json.loads(get(LISTING + (f"&pageToken={token}" if token else "")))
        dishes += [p.rstrip("/").split("/")[-1] for p in page.get("prefixes", [])]
        token = page.get("nextPageToken")
        if not token:
            return dishes


def truths():
    """dish id → calories, grams and ingredient names, from both cafeterias' metadata."""
    out = {}
    for cafe in ("cafe1", "cafe2"):
        text = get(f"{BUCKET}/metadata/dish_metadata_{cafe}.csv").decode()
        for row in csv.reader(io.StringIO(text)):
            if len(row) < 6:
                continue
            ingredients = [row[i + 1] for i in range(6, len(row) - 6, 7)]
            out[row[0]] = {"calories": float(row[1]), "grams": float(row[2]),
                           "fat": float(row[3]), "carbs": float(row[4]), "protein": float(row[5]),
                           "ingredients": ingredients}
    return out


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--count", type=int, default=60)
    parser.add_argument("--seed", type=int, default=7)
    parser.add_argument("--out", default="build/bench/nutrition5k")
    args = parser.parse_args()

    known = truths()
    # Plates with real food on them: an empty tray or a single condiment says nothing.
    candidates = sorted(d for d in overhead_dishes()
                        if d in known and 80 <= known[d]["calories"] <= 1500 and known[d]["grams"] >= 80)
    chosen = random.Random(args.seed).sample(candidates, min(args.count, len(candidates)))
    os.makedirs(args.out, exist_ok=True)
    manifest = []
    for dish in chosen:
        path = os.path.join(args.out, dish + ".png")
        if not os.path.exists(path):
            with open(path, "wb") as f:
                f.write(get(f"{BUCKET}/imagery/realsense_overhead/{dish}/rgb.png"))
        manifest.append({"id": dish, "image": dish + ".png", **known[dish]})
    with open(os.path.join(args.out, "manifest.json"), "w") as f:
        json.dump({"source": "Nutrition5k (Google Research, CC BY 4.0)", "seed": args.seed, "dishes": manifest}, f, indent=1)
    print(f"{len(manifest)} dishes in {args.out} (of {len(candidates)} with an overhead photo)")


if __name__ == "__main__":
    main()
