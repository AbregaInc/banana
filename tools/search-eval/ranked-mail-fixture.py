"""Take disposable local SQLite backups and sample the existing fixed-seed first-query tasks."""

import argparse
import datetime
import importlib
import json
import sqlite3
from pathlib import Path

from beta_tasks import sample_tasks

first = importlib.import_module("mail-first-query")
fielded = importlib.import_module("fielded-mail")
p = argparse.ArgumentParser(description=__doc__)
p.add_argument("--cache", type=Path, required=True)
p.add_argument("--out", type=Path, required=True)
a = p.parse_args()
a.out.mkdir(mode=0o700)
cache = a.out / "Cache"
cache.mkdir(mode=0o700)
migrations = {}
for name in ("index.sqlite", "blobs.sqlite", "search.sqlite"):
    source = fielded.readonly(a.cache / name)
    dest = sqlite3.connect(cache / name)
    source.backup(dest)
    migrations[name] = [
        r[0]
        for r in dest.execute("SELECT identifier FROM grdb_migrations ORDER BY rowid")
    ]
    source.close()
    dest.close()
(a.out / "fixture-migrations.json").write_text(json.dumps(migrations))
index = sqlite3.connect(cache / "index.sqlite")
seed = 73129
tasks = [
    {"family": "known", "query": t["query"], "targets": {t["pk"]}}
    for t in sample_tasks(index, datetime.date(2026, 11, 25), seed)
    if t["step"] == 1
]
tasks.extend(first.navigation_tasks(index, seed))
first.files_snapshot(index, cache / "blobs.sqlite", a.out / "files.sqlite")
tasks.extend(first.filename_tasks(sqlite3.connect(a.out / "files.sqlite"), seed))
for task in tasks:
    for key in ["targets", "sameName"]:
        if key in task:
            task[key] = [
                index.execute(
                    "SELECT gmail_id FROM thread WHERE thread_pk=?", [pk]
                ).fetchone()[0]
                for pk in task[key]
            ]
(a.out / "tasks.json").write_text(json.dumps(tasks))
