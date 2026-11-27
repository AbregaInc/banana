"""Replay the previous fielded policy on exactly the fixture used by the Swift integration."""

import argparse
import importlib
import json
import sqlite3
import time
from pathlib import Path

from mail_field_index import build_index, personal_documents, public_documents

fielded = importlib.import_module("fielded-mail")
first = importlib.import_module("mail-first-query")
p = argparse.ArgumentParser(description=__doc__)
p.add_argument("--fixture", type=Path, required=True)
p.add_argument("--collection", type=Path)
p.add_argument("--out", type=Path, required=True)
a = p.parse_args()
root = a.fixture
db, body = fielded.open_readers(root / "Cache")
blobs = fielded.readonly(root / "Cache" / "blobs.sqlite")
files = sqlite3.connect(root / "files.sqlite") if not a.collection else None
if files:
    files.create_function("folded", 1, str.casefold, deterministic=True)
docs = (
    public_documents(db, a.collection)
    if a.collection
    else personal_documents(db, body, blobs)
)
index, stats = build_index(root / "fielded", docs)
searcher = index.searcher()
keys = dict(db.execute("SELECT thread_pk,gmail_id FROM thread"))
rows = []
for i, t in enumerate(json.loads((root / "tasks.json").read_text())):
    start = time.perf_counter()
    ranks = first.first_query(index, searcher, t["query"], files, infer_topic=False)
    ms = (time.perf_counter() - start) * 1000
    ids = [keys[k] for k in ranks]
    rank = next((n for n, x in enumerate(ids, 1) if x in t["targets"]), 0)
    rows.append(
        {
            "topic": i,
            "family": t["family"],
            "rank": rank,
            "ms": ms,
            "exactFilenameFirst": (bool(ids) and ids[0] in t["sameName"])
            if "sameName" in t
            else None,
        }
    )
a.out.write_text(json.dumps({"index": stats, "samples": rows}) + "\n")
