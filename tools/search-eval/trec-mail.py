"""Replay NIST's human-written known-item email queries against the corresponding W3C mail."""

import argparse
import hashlib
import json
import math
import statistics
import random
import re
import sqlite3
import tempfile
import time
from pathlib import Path

from trec_corpus import build_fixture
from mail_metrics import lexical_summary, summarize
from mail_sql import environment, lexical_threads, merge, query, query_words

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument(
    "--collection",
    type=Path,
    required=True,
    help="UMD archive parts plus NIST known-item and discussion topic/judgment files",
)
parser.add_argument("--out", type=Path, required=True)
args = parser.parse_args()
if args.out.exists():
    parser.error("Choose a fresh output path")


def lexical_documents(index, body, words):
    ordered = lexical_threads(index, body, words)
    if not ordered:
        return []
    params = ",".join("?" for _ in ordered)
    keys = dict(
        index.execute("SELECT thread_pk,gmail_id FROM thread WHERE thread_pk IN (" + params + ")", ordered)
    )
    return [keys[pk] for pk in ordered]


def target_coverage(index, body, task):
    record = index.execute(
        "SELECT thread_pk,last_date FROM thread WHERE gmail_id=?", (task["docno"],)
    ).fetchone()
    if not record or record[1] <= 0:
        return "absentOrUndated"
    pk = record[0]
    document = body.execute("SELECT rowid FROM body_doc WHERE msg_pk=?", (pk,)).fetchone()
    header_sql = "SELECT 1 FROM mail_header_search WHERE rowid=? AND mail_header_search MATCH ?"
    body_sql = "SELECT 1 FROM msg_fts WHERE rowid=? AND msg_fts MATCH ?"

    def covered(words):
        return bool(
            index.execute(header_sql, (pk, words)).fetchone()
            or (document and body.execute(body_sql, (document[0], words)).fetchone())
        )

    words = query_words(task["query"])
    if covered(words):
        return "eligible"
    if all(covered(term) for term in words.split(" AND ")):
        return "termsSplitAcrossIndexes"
    return "missingLiteralTerm"


def discussion_scores(readers):
    # Topic DS4 has no qrels. Report unjudged retrieved rows separately.
    titles = dict(
        re.findall(
            r"<num>\s*DS(\d+)\s*</num>\s*<query>\s*([^<]+)",
            (args.collection / "discussion.topics").read_text(),
            re.S,
        )
    )
    assert len(titles) == 60
    judgments = {}
    for line in (args.collection / "discussion.qrels").read_text().splitlines():
        topic, _, key, grade = line.split()
        judgments.setdefault(topic, {})[key] = int(grade)

    def dcg(grades):
        return sum((2**grade - 1) / math.log2(rank + 2) for rank, grade in enumerate(grades[:5]))

    results = []
    for topic, qrels in judgments.items():
        pair = []
        words = query_words(titles[topic])
        for i, (index, body) in enumerate(readers):
            headers, _ = query(index, bool(i), words, 50)
            rows, more = merge(index, body, headers, words, 50, bool(i))
            pair.append((rows, more))
        if pair[0] != pair[1]:
            raise RuntimeError("Unequal discovery results for DS" + topic)
        ids = [row[2] for row in rows[:5]]
        grades = [qrels.get(key, 0) for key in ids]
        lexical_ids = lexical_documents(index, body, words)[:5]
        lexical_grades = [qrels.get(key, 0) for key in lexical_ids]
        ideal = dcg(sorted(qrels.values(), reverse=True))
        results.append(
            dict(
                lexicalNDCGAt5=dcg(lexical_grades) / ideal,
                lexicalPrecisionAt5=sum(g > 0 for g in lexical_grades) / 5,
                lexicalJudgedAt5=sum(key in qrels for key in lexical_ids),
                lexicalRowsAt5=len(lexical_ids),
                topic="DS" + topic,
                rowsAt5=len(ids),
                judgedAt5=sum(key in qrels for key in ids),
                precisionAt5=sum(g > 0 for g in grades) / 5,
                ndcgAt5=dcg(grades) / ideal,
            )
        )
    return dict(
        topics=len(results),
        unjudgedTopics=sorted("DS" + q for q in set(titles) - judgments.keys()),
        meanNDCGAt5=statistics.mean(r["ndcgAt5"] for r in results),
        meanPrecisionAt5=statistics.mean(r["precisionAt5"] for r in results),
        judgedRetrievedAt5=sum(r["judgedAt5"] for r in results),
        retrievedAt5=sum(r["rowsAt5"] for r in results),
        lexicalNDCGAt5=statistics.mean(r["lexicalNDCGAt5"] for r in results),
        lexicalPrecisionAt5=statistics.mean(r["lexicalPrecisionAt5"] for r in results),
        queries=results,
    )


topic_file = (args.collection / "topics").read_text()
topics = dict(
    re.findall(r"<num>\s*Number:\s*(KI\d+)\s*</num>\s*<title>\s*(.*?)\s*</title>", topic_file, re.S)
)
tasks = []
for split, filename in [("development", "training-qrels"), ("test", "qrels")]:
    for line in (args.collection / filename).read_text().splitlines():
        id_, _, docno, relevant = line.split()
        assert relevant == "1" and id_ in topics
        tasks.append(dict(id=id_, split=split, docno=docno, query=topics[id_]))
assert len({t["id"] for t in tasks}) == len(tasks) == 150
report = {
    "source": "TREC 2005 Enterprise email known-item titles and official judgments; UMD parsed W3C mail",
    "scope": "Document-level merged local header/body SQL. All 125 test topics included. No Gmail or display timing.",
    "sqlite": sqlite3.sqlite_version,
    "timing": "Six rotating paired trials per topic; fresh reader connections, warm OS file cache.",
    "filesSHA256": {},
}
for name in ["topics", "training-qrels", "qrels", "discussion.topics", "discussion.qrels"] + [
    f"part{i}.tar.gz" for i in range(1, 4)
]:
    with (args.collection / name).open("rb") as handle:
        report["filesSHA256"][name] = hashlib.file_digest(handle, "sha256").hexdigest()
with tempfile.TemporaryDirectory() as tmp:
    path = Path(tmp) / "index.sqlite"
    body_path = Path(tmp) / "body.sqlite"
    with sqlite3.connect(path) as writer, sqlite3.connect(body_path) as bodies:
        report["collection"] = build_fixture(args.collection, writer, bodies)
    writer.close()
    bodies.close()
    readers = [(sqlite3.connect(path), sqlite3.connect(body_path)) for _ in range(2)]
    for index, body in readers:
        body.execute("ATTACH DATABASE ? AS idx", [str(path)])
        index.execute("PRAGMA cache_size=-4096")
        body.execute("PRAGMA cache_size=-8192")
    for task in tasks:
        task["targetPresent"] = bool(
            readers[0][0].execute("SELECT 1 FROM thread WHERE gmail_id=?", [task["docno"]]).fetchone()
        )
        task["baseMS"], task["candidateMS"] = [], []
        task["tokens"] = len(query_words(task["query"]).split(" AND "))
    for trial in range(6):
        work = list(tasks)
        random.Random(2005 + trial).shuffle(work)
        for task in work:
            words = query_words(task["query"])
            parity = []
            for i in [0, 1] if (trial + int(task["id"][2:])) % 2 == 0 else [1, 0]:
                index, body = readers[i]
                start = time.monotonic_ns()
                headers, route = query(index, bool(i), words, 50)
                rows, more = merge(index, body, headers, words, 50, bool(i))
                task["candidateMS" if i else "baseMS"].append((time.monotonic_ns() - start) / 1e6)
                parity.append((rows, more))
                if i:
                    task["route"] = route
            if parity[0] != parity[1]:
                raise RuntimeError("Ordered merged result mismatch for " + task["id"])
            ids = [row[2] for row in rows]
            rank = ids.index(task["docno"]) + 1 if task["docno"] in ids else 0
            assert task.get("rankAt50", rank) == rank
            task.update(rankAt50=rank, rows=len(ids))
        print("Completed paired round", trial + 1, flush=True)
    for task in tasks:
        start = time.monotonic_ns()
        ranked = lexical_documents(*readers[1], query_words(task["query"]))
        task["lexicalLookupMS"] = (time.monotonic_ns() - start) / 1e6
        task["lexicalRankAt50"] = ranked.index(task["docno"]) + 1 if task["docno"] in ranked else 0
        task["targetCoverage"] = target_coverage(*readers[1], task)
    report["offlineBM25Fusion"] = {
        split: lexical_summary([t for t in tasks if t["split"] == split]) for split in ("development", "test")
    }
    report["discussion"] = discussion_scores(readers)
    for index, body in readers:
        index.close()
        body.close()
for t in tasks:
    del t["query"], t["docno"]
report["splits"] = {
    split: summarize([t for t in tasks if t["split"] == split]) for split in ["development", "test"]
}
report["topics"] = tasks
report["environment"] = environment()
with args.out.open("x") as f:
    json.dump(report, f, indent=2)
    f.write("\n")
print(json.dumps(report["splits"], indent=2))
