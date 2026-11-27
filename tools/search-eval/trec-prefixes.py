"""Ablate an FTS5 one-character prefix index on the fixed human-written W3C tasks."""

import argparse
import json
import random
import re
import sqlite3
import tempfile
import time
from pathlib import Path

from mail_metrics import summarize
from mail_sql import environment, lexical_threads, merge, projection, query, query_words
from trec_corpus import build_fixture

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--collection", type=Path, required=True)
parser.add_argument("--out", type=Path, required=True)
parser.add_argument(
    "--ranked", action="store_true", help="Also compare chronological and ranked results on the two schemas"
)
args = parser.parse_args()
if args.out.exists():
    parser.error("Choose a fresh output path")

titles = dict(
    re.findall(
        r"<num>\s*Number:\s*(KI\d+)\s*</num>\s*<title>\s*(.*?)\s*</title>",
        (args.collection / "topics").read_text(),
        re.S,
    )
)
tasks = []
for split, filename in [("development", "training-qrels"), ("test", "qrels")]:
    for line in (args.collection / filename).read_text().splitlines():
        topic, _, key, _ = line.split()
        tokens = re.findall(r"[^\W_]+", titles[topic])
        tasks.append(
            dict(
                id=topic,
                split=split,
                target=key,
                singleCharacter=any(len(t) == 1 for t in tokens),
                baseMS=[],
                candidateMS=[],
            )
        )
report = dict(
    environment=environment(),
    schemas=[],
    note="Both arms use the page-bounded cursor and unchanged prefix-AND results.",
)


def ranked_trials(tasks, readers):
    records = [
        dict(
            id=t["id"],
            split=t["split"],
            targetPresent=t["targetPresent"],
            chronologicalMS=[],
            originalIndexMS=[],
            prefixIndexMS=[],
        )
        for t in tasks
    ]
    for trial in range(3):
        order = list(range(len(tasks)))
        random.Random(541 + trial).shuffle(order)
        for j in order:
            t, record = tasks[j], records[j]
            words = query_words(titles[t["id"]])
            ranked = {}
            for turn in range(3):
                arm = (j + trial + turn) % 3
                index, body = readers[int(arm == 2)]
                start = time.monotonic_ns()
                if arm == 0:
                    headers, _ = query(index, True, words, 50)
                    rows, _ = merge(index, body, headers, words, 50, True)
                else:
                    ids = lexical_threads(index, body, words)
                    rows = []
                    if ids:
                        params = ",".join("?" for _ in ids)
                        raw = index.execute(projection + "IN (" + params + ")", ids)
                        by_pk = {r[0]: r for r in raw}
                        rows = [by_pk[pk] for pk in ids]
                    ranked[arm] = rows
                key = ("chronologicalMS", "originalIndexMS", "prefixIndexMS")[arm]
                record[key].append((time.monotonic_ns() - start) / 1e6)
                docnos = [r[2] for r in rows]
                rank = docnos.index(t["target"]) + 1 if t["target"] in docnos else 0
                if arm == 0:
                    assert rank == t["rankAt50"]
                else:
                    record["rankAt50"] = rank
            if ranked[1] != ranked[2]:
                raise RuntimeError("Schema changed the ranked page for " + t["id"])

    def comparison(split, base_key):
        return summarize(
            [
                dict(r, baseMS=r[base_key], candidateMS=r["prefixIndexMS"])
                for r in records
                if r["split"] == split
            ]
        )

    return dict(
        queries=records,
        chronologicalToRanked={s: comparison(s, "chronologicalMS") for s in ("development", "test")},
        sameRankingBySchema={s: comparison(s, "originalIndexMS") for s in ("development", "test")},
    )


with tempfile.TemporaryDirectory() as temp:
    readers = []
    for prefix in (False, True):
        directory = Path(temp) / str(int(prefix))
        directory.mkdir()
        index = sqlite3.connect(directory / "index.sqlite")
        body = sqlite3.connect(directory / "body.sqlite")
        start = time.monotonic()
        counts = build_fixture(args.collection, index, body, single_character_index=prefix)
        records = {
            "additionalOneCharacterIndex": prefix,
            "buildSeconds": time.monotonic() - start,
            "collection": counts,
        }
        for db, fts in ((index, "mail_header_search"), (body, "msg_fts")):
            records[fts + "Bytes"] = db.execute(
                "SELECT sum(pgsize) FROM dbstat WHERE name GLOB ?", (fts + "_*",)
            ).fetchone()[0]
        report["schemas"].append(records)
        index.close()
        body.close()
        index = sqlite3.connect(directory / "index.sqlite")
        body = sqlite3.connect(directory / "body.sqlite")
        body.execute("ATTACH DATABASE ? AS idx", [str(directory / "index.sqlite")])
        index.execute("PRAGMA cache_size=-4096")
        body.execute("PRAGMA cache_size=-8192")
        readers.append((index, body))
    for task in tasks:
        task["targetPresent"] = bool(
            readers[0][0].execute("SELECT 1 FROM thread WHERE gmail_id=?", [task["target"]]).fetchone()
        )
    for trial in range(5):
        order = list(range(len(tasks)))
        random.Random(2005 + trial).shuffle(order)
        for j in order:
            t = tasks[j]
            words = query_words(titles[t["id"]])
            pair = []
            for arm in [0, 1] if (j + trial) % 2 == 0 else [1, 0]:
                index, body = readers[arm]
                start = time.monotonic_ns()
                headers, _ = query(index, True, words, 50)
                rows, more = merge(index, body, headers, words, 50, True)
                t["candidateMS" if arm else "baseMS"].append((time.monotonic_ns() - start) / 1e6)
                pair.append((rows, more))
            if pair[0] != pair[1]:
                raise RuntimeError("Index changed results for " + t["id"])
            ids = [r[2] for r in rows]
            t["rankAt50"] = ids.index(t["target"]) + 1 if t["target"] in ids else 0
        print("Completed prefix-index round", trial + 1, flush=True)
    if args.ranked:
        report["ranked"] = ranked_trials(tasks, readers)
    for index, body in readers:
        index.close()
        body.close()
for task in tasks:
    del task["target"]
report["splits"] = {s: summarize([t for t in tasks if t["split"] == s]) for s in ("development", "test")}
report["queries"] = tasks
with args.out.open("x") as handle:
    json.dump(report, handle, indent=2)
    handle.write("\n")
print(json.dumps(report["splits"], indent=2))
