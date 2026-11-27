"""Private, stratified known-conversation probes on a temporary copy of the Beta header index."""

import argparse
import datetime
import json
import random
import sqlite3
import tempfile
import time
from pathlib import Path

from beta_tasks import families, sample_tasks
from mail_metrics import lexical_summary, summarize
from mail_sql import environment, lexical_threads, merge, query, query_words

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--index", required=True, type=Path)
parser.add_argument("--body", required=True, type=Path)
parser.add_argument("--as-of", required=True, type=datetime.date.fromisoformat)
parser.add_argument("--out", required=True, type=Path)
args = parser.parse_args()
if args.out.exists():
    parser.error("Choose a fresh output path")
with tempfile.TemporaryDirectory() as tmp:
    index_path = Path(tmp) / "index.sqlite"
    writer = sqlite3.connect(index_path)
    src = sqlite3.connect(args.index.resolve().as_uri() + "?mode=ro", uri=True)
    src.backup(writer)
    src.close()
    writer.commit()
    tasks = sample_tasks(writer, args.as_of)
    candidate_index = sqlite3.connect(index_path)
    for handle in [writer, candidate_index]:
        handle.execute("PRAGMA cache_size=-4096")
    body = sqlite3.connect(args.body.resolve().as_uri() + "?mode=ro", uri=True)
    body.execute("PRAGMA query_only=ON")
    body.execute("ATTACH DATABASE ? AS idx", [index_path.as_uri() + "?mode=ro"])
    body.execute("BEGIN")
    report = {
        "messages": writer.execute("SELECT count(*) FROM message").fetchone()[0],
        "threads": writer.execute("SELECT count(*) FROM thread").fetchone()[0],
        "bodyDocuments": body.execute("SELECT count(*) FROM body_doc").fetchone()[0],
        "asOf": str(args.as_of),
        "seed": 73123,
        "subjects": "Newest locally fetched message per eligible sampled conversation",
        "scope": "Cue-derived proxy tasks, no query logs. Merged header/body SQL, no UI, live provider or app decoding.",
    }
    for trial in range(5):
        order = list(range(len(tasks)))
        random.Random(73123 + trial).shuffle(order)
        for j in order:
            t = tasks[j]
            expression = query_words(t["query"])
            parity = []
            for i in [0, 1] if (trial + j) % 2 == 0 else [1, 0]:
                db = candidate_index if i else writer
                start = time.monotonic_ns()
                headers, route = query(db, bool(i), expression, 50)
                rows, more = merge(db, body, headers, expression, 50, bool(i))
                t["candidateMS" if i else "baseMS"].append((time.monotonic_ns() - start) / 1e6)
                parity.append((rows, more))
                if i:
                    t["route"] = route
            if parity[0] != parity[1]:
                raise RuntimeError("Unequal ordered results for " + t["id"])
            keys = [r[0] for r in rows]
            rank = keys.index(t["pk"]) + 1 if t["pk"] in keys else 0
            assert t.get("rankAt50", rank) == rank
            t.update(rankAt50=rank, rows=len(rows))
    for task in tasks:
        start = time.monotonic_ns()
        ranked = lexical_threads(candidate_index, body, query_words(task["query"]))
        task["lexicalLookupMS"] = (time.monotonic_ns() - start) / 1e6
        task["lexicalRankAt50"] = ranked.index(task["pk"]) + 1 if task["pk"] in ranked else 0
    body.close()
    candidate_index.close()
    writer.close()
for task in tasks:
    del task["query"], task["pk"]
# Each independent task has one vote; first attempts for refinements are reported separately.
final = [t for t in tasks if t["family"] != "refinement" or t["step"] == 2]
report["all"] = summarize(final)
report["offlineBM25Fusion"] = lexical_summary(final)
report["lexicalByAge"] = {
    k: lexical_summary([t for t in final if t["age"] == k]) for k in sorted({t["age"] for t in final})
}
report["age"] = {k: summarize([t for t in final if t["age"] == k]) for k in sorted({t["age"] for t in final})}
report["families"] = {k: summarize([t for t in final if t["family"] == k]) for k in families}
report["firstRefinementAttempt"] = summarize(
    [t for t in tasks if t["family"] == "refinement" and t["step"] == 1]
)
report["replays"] = tasks
report["environment"] = environment()
with args.out.open("x") as f:
    json.dump(report, f, indent=2)
    f.write("\n")
print(json.dumps(report["all"], indent=2))
