"""Evaluate the first text entered into Mail. The rankers see only the query string."""

import argparse
import datetime
import importlib
import json
import math
import random
import re
import sqlite3
import statistics
import time
from collections import defaultdict
from pathlib import Path

import tantivy
from beta_tasks import sample_tasks, words
from mail_field_index import decode_blob, rank_completed_query, tokenize
from mail_metrics import p95

replay = importlib.import_module("fielded-mail")
arms = ("chronological", "previous", "people", "peopleAndFiles", "senderAndFiles")


def files_snapshot(index, blobs_path, path):
    # The blob store retains filename metadata even when the attachment bytes were never downloaded.
    keys = {
        (a, key): (pk, date)
        for a, key, pk, date in index.execute("""
        SELECT a.email,m.gmail_id,m.thread_pk,t.last_date FROM message m JOIN account a USING(account_pk)
        JOIN thread t ON t.thread_pk=m.thread_pk WHERE t.last_date>0
    """)
    }
    if path.exists():
        raise FileExistsError(path)
    db = sqlite3.connect(path)
    db.execute("CREATE VIRTUAL TABLE files USING fts5(name,thread UNINDEXED,activity UNINDEXED)")
    blobs = replay.readonly(blobs_path)
    start = time.perf_counter()
    structures = named = 0
    for account, key, raw in blobs.execute("SELECT account,gmail_id,structure FROM content"):
        match = keys.get((account, key))
        if not match or not raw:
            continue
        structures += 1
        for file in json.loads(decode_blob(raw)).get("attachments", []):
            name = file.get("name", "").strip()
            if not name or name == "attachment" or file.get("isInline"):
                continue
            db.execute("INSERT INTO files VALUES (?,?,?)", (name, *match))
            named += 1
    db.commit()
    db.close()
    blobs.close()
    return {
        "eligibleStructures": structures,
        "namedParts": named,
        "bytes": path.stat().st_size,
        "scanAndIndexSeconds": time.perf_counter() - start,
    }


def sender_topic(index, terms):
    # User-supplied words may span fields in either order. An interpretation can earn a boost only.
    if not 2 <= len(terms) <= 4:
        return None
    choices = []
    for i, word in enumerate(terms):
        rest = " ".join(f'"{w}"' for j, w in enumerate(terms) if i != j)
        sender = index.parse_query(f'"{word}"', ["sender"])
        topic = index.parse_query(rest, ["subject", "snippet", "body"], conjunction_by_default=True)
        choices.append(
            tantivy.Query.boolean_query([(tantivy.Occur.Must, sender), (tantivy.Occur.Must, topic)])
        )
    return tantivy.Query.disjunction_max_query(choices)


def first_query(index, searcher, text, files=None, infer_topic=True):
    terms = tokenize(text)
    ranked = rank_completed_query(
        index, searcher, text, bonus=sender_topic(index, terms) if infer_topic else None
    )
    added = []
    exact = []
    if len(terms) == 1:
        matches = searcher.search(
            index.parse_query(f'"{terms[0]}"', ["sender"]), limit=40, count=False, order_by_field="date"
        ).hits
        added = list(
            dict.fromkeys(searcher.fast_field_values("thread", [address for _, address in matches]))
        )[:2]
    elif terms and files is not None:
        expression = " AND ".join(f'"{w}"' for w in terms)
        # An explicit file type warrants more space for filename matches.
        slots = (
            3
            if terms[-1]
            in {"pdf", "doc", "docx", "xls", "xlsx", "csv", "ppt", "pptx", "ics", "zip", "txt", "png", "jpg"}
            else 1
        )
        suffix = Path(text.strip()).suffix
        if suffix and re.fullmatch(r"\.[^\W_]{2,5}", suffix):
            exact = [
                row[0]
                for row in files.execute(
                    """
                SELECT thread FROM files WHERE files MATCH ? AND folded(name)=?
                ORDER BY activity DESC,rowid LIMIT 1
            """,
                    (expression, text.strip().casefold()),
                )
            ]
        added = list(
            dict.fromkeys(
                row[0]
                for row in files.execute(
                    "SELECT thread FROM files WHERE files MATCH ? ORDER BY rank,activity DESC,rowid LIMIT 50",
                    (expression,),
                )
            )
        )[:slots]
    return list(dict.fromkeys(exact + ranked[:1] + added + ranked[1:]))[:50]


def navigation_tasks(index, seed):
    # Pick repeat senders before retrieval. For this intent, any of their three latest conversations suffices.
    db = index.execute("""
        SELECT lower(trim(m.from_addr)),m.from_name,m.thread_pk,max(m.internal_date)
        FROM message m JOIN thread t ON t.thread_pk=m.thread_pk
        WHERE t.last_date>0 AND m.from_addr IS NOT NULL AND m.internal_date>0
        GROUP BY lower(trim(m.from_addr)),m.thread_pk
        ORDER BY 1,4 DESC,m.thread_pk DESC
    """)
    own = {r[0].lower() for r in index.execute("SELECT email FROM account")}
    senders = defaultdict(list)
    for addr, name, thread, stamp in db:
        if addr and addr not in own:
            senders[addr].append((thread, name))
    rng = random.Random(seed)
    tasks = []
    for band, low, high in [("10to29", 10, 30), ("30to99", 30, 100), ("100plus", 100, math.inf)]:
        eligible = [records for records in senders.values() if low <= len(records) < high]
        rng.shuffle(eligible)
        count = 0
        for records in eligible:
            tokens = words(records[0][1])
            if not tokens:
                continue
            tasks.append(
                {
                    "family": "recent-sender",
                    "band": band,
                    "query": tokens[-1],
                    "targets": {pk for pk, _ in records[:3]},
                }
            )
            count += 1
            if count == 40:
                break
    return tasks


def filename_tasks(files, seed):
    rows = list(files.execute("SELECT name,thread FROM files ORDER BY rowid"))
    by_name = defaultdict(set)
    for name, thread in rows:
        by_name[name.casefold()].add(thread)
    rng = random.Random(seed)
    rng.shuffle(rows)
    tasks = []
    used = set()
    for name, pk in rows:
        stem = Path(name).stem
        terms = [t for t in tokenize(stem) if len(t) >= 3 and not t.isdecimal()]
        extension = Path(name).suffix.lower().lstrip(".")
        if not terms or pk in used or not re.fullmatch(r"[a-z0-9]{2,5}", extension):
            continue
        used.add(pk)
        cue = " ".join([rng.choice(terms), extension])
        tasks.append({"family": "filename", "query": cue, "targets": {pk}})
        if len(terms) > 1 and len(tokenize(name)) <= 12:
            tasks.append(
                {
                    "family": "complete-filename",
                    "query": name,
                    "targets": {pk},
                    "sameName": by_name[name.casefold()],
                }
            )
        if len(used) == 100:
            break
    return tasks


def evaluate(index, body, engine, tasks, files=None):
    searcher = engine.searcher()
    methods = {
        "chronological": lambda q: replay.chronological(index, body, q),
        "previous": lambda q: rank_completed_query(engine, searcher, q),
        "people": lambda q: first_query(engine, searcher, q),
    }
    methods["senderAndFiles"] = lambda q: first_query(engine, searcher, q, files, infer_topic=False)
    if files is not None:
        methods["peopleAndFiles"] = lambda q: first_query(engine, searcher, q, files)
    out = [{"family": t["family"], **({"band": t["band"]} if "band" in t else {})} for t in tasks]
    # Same unassisted query and same judgments for each policy. No target data enters retrieval.
    for trial in range(3):
        rng = random.Random(9310 + trial)
        order = list(range(len(tasks)))
        rng.shuffle(order)
        for i in order:
            task = tasks[i]
            names = list(methods)
            rng.shuffle(names)
            for name in names:
                start = time.perf_counter_ns()
                keys = methods[name](task["query"])
                ms = (time.perf_counter_ns() - start) / 1e6
                rank = next((j for j, pk in enumerate(keys, 1) if pk in task["targets"]), 0)
                result = out[i].setdefault(name, {"rank": rank, "ms": []})
                if "sameName" in task:
                    result["sameNameRank"] = next(
                        (j for j, pk in enumerate(keys, 1) if pk in task["sameName"]), 0
                    )
                if result["rank"] != rank:
                    raise ValueError("Unstable ranking")
                result["ms"].append(round(ms, 4))
    return out


def summary(rows):
    stats = {}
    for name in arms:
        if name not in rows[0]:
            continue
        rs = [r[name]["rank"] for r in rows]
        prev = [r["previous"]["rank"] for r in rows]
        ms = [statistics.median(r[name]["ms"]) for r in rows]
        stats[name] = {
            "first": rs.count(1),
            "top5": sum(0 < v <= 5 for v in rs),
            "tasks": len(rs),
            "gained5": sum(0 < v <= 5 and not 0 < p <= 5 for p, v in zip(prev, rs)),
            "lost5": sum(0 < p <= 5 and not 0 < v <= 5 for p, v in zip(prev, rs)),
            "mrr10": round(statistics.mean(1 / r if 0 < r <= 10 else 0 for r in rs), 4),
            "p50MS": round(statistics.median(ms), 3),
            "p95MS": round(p95(ms), 3),
        }
        if "sameNameRank" in rows[0][name]:
            stats[name]["sameNameFirst"] = sum(r[name]["sameNameRank"] == 1 for r in rows)
    return stats


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", required=True, type=Path)
    parser.add_argument("--prepare-files", type=Path)
    parser.add_argument("--public", action="store_true")
    parser.add_argument("--seed", type=int, default=73127)
    parser.add_argument("--as-of", type=datetime.date.fromisoformat, default=datetime.date(2026, 11, 25))
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    if args.out.exists():
        parser.error("use a fresh result path")
    db, body = replay.open_readers(args.fixture / "Cache")
    path = args.fixture / "filenames.sqlite"
    if args.prepare_files:
        report = files_snapshot(db, args.prepare_files, path)
    else:
        engine = tantivy.Index.open(str(args.fixture / "fielded"))
        files = None
        if args.public:
            tasks = []
            for t in json.loads((args.fixture / "tasks.json").read_text()):
                if t["split"] == "test":
                    pk = db.execute(
                        "SELECT thread_pk FROM thread WHERE gmail_id=?", (t["target"],)
                    ).fetchone()[0]
                    tasks.append({"family": "public", "query": t["query"], "targets": {pk}})
        else:
            files = replay.readonly(path, frozen=True)
            files.create_function("folded", 1, str.casefold, deterministic=True)
            tasks = [
                {"family": t["family"], "query": t["query"], "targets": {t["pk"]}}
                for t in sample_tasks(db, args.as_of, args.seed)
                if t["step"] == 1
            ]
            tasks += navigation_tasks(db, args.seed) + filename_tasks(files, args.seed)
        rows = evaluate(db, body, engine, tasks, files)
        group = {
            k: summary([r for r in rows if r["family"] == k]) for k in sorted({r["family"] for r in rows})
        }
        if not args.public:
            group["specific-conversation"] = summary(
                [r for r in rows if r["family"] not in ("recent-sender", "filename", "complete-filename")]
            )
        report = {"seed": args.seed, "summary": group, "cases": rows}
    args.out.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
