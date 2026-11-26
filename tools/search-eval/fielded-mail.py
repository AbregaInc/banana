"""Compare unscoped completed Mail queries. Only aggregate values and anonymous case ranks leave the replay."""

import argparse
import datetime
import importlib.metadata
import json
import math
import multiprocessing
import random
import re
import resource
import sqlite3
import statistics
import sys
import time
from contextlib import closing
from pathlib import Path

import tantivy
from beta_tasks import sample_tasks, words
from mail_field_index import (
    build_index,
    personal_documents,
    public_documents,
    rank,
    rank_completed_query,
    tokenize,
)
from mail_metrics import p95
from mail_sql import lexical_threads, merge, projection, query, query_words

FROZEN = (1, 1, 1, 1, 1)


def readonly(path, frozen=False):
    return sqlite3.connect(
        path.resolve().as_uri() + ("?mode=ro&immutable=1" if frozen else "?mode=ro"), uri=True
    )


def open_readers(cache):
    index, body = (readonly(cache / name, frozen=True) for name in ("index.sqlite", "search.sqlite"))
    body.execute(
        "ATTACH DATABASE ? AS idx", [(cache / "index.sqlite").resolve().as_uri() + "?mode=ro&immutable=1"]
    )
    return index, body


def ds_tasks(collection, index):
    titles = dict(
        re.findall(
            r"<num>\s*DS(\d+)\s*</num>\s*<query>\s*([^<]+)", (collection / "discussion.topics").read_text()
        )
    )
    by_topic = {}
    for row in (collection / "discussion.qrels").read_text().splitlines():
        topic, _, key, grade = row.split()
        pk = index.execute("SELECT thread_pk FROM thread WHERE gmail_id=?", [key]).fetchone()
        # Absent judged documents must still count toward the ideal.
        by_topic.setdefault(topic, {})[pk[0] if pk else key] = int(grade)
    return [
        {"id": "DS" + topic, "query": titles[topic], "grades": grades} for topic, grades in by_topic.items()
    ]


def snapshot_counts(index, body):
    return {
        "retainedMessages": index.execute("SELECT count(*) FROM message").fetchone()[0],
        "retainedThreads": index.execute("SELECT count(*) FROM thread").fetchone()[0],
        "bodyIndexRows": body.execute("SELECT count(*) FROM body_doc").fetchone()[0],
        "eligibleIndexedBodies": body.execute("""
            SELECT count(DISTINCT m.msg_pk) FROM body_doc d JOIN idx.message m ON m.msg_pk=d.msg_pk
            JOIN idx.thread t ON t.thread_pk=m.thread_pk WHERE m.fts_state=2 AND t.last_date>0
        """).fetchone()[0],
    }


def dcg(grades):
    return sum((2**g - 1) / math.log2(i + 2) for i, g in enumerate(grades[:5]))


def score(task, keys):
    if "grades" in task:
        grades = task["grades"]
        return {
            "ndcg5": dcg([grades.get(k, 0) for k in keys[:5]]) / dcg(sorted(grades.values(), reverse=True)),
            "judged5": sum(k in grades for k in keys[:5]),
        }
    return {"rank": keys.index(task["pk"]) + 1 if task["pk"] in keys else 0}


def evaluate(tasks, methods, trials):
    result = [{k: t[k] for k in ("id", "age", "family") if k in t} for t in tasks]
    for trial in range(trials):
        order = list(range(len(tasks)))
        rng = random.Random(73123 + trial)
        rng.shuffle(order)
        for i in order:
            task = tasks[i]
            arms = list(methods)
            rng.shuffle(arms)
            for name in arms:
                start = time.perf_counter_ns()
                keys = methods[name](task["query"])
                ms = (time.perf_counter_ns() - start) / 1e6
                grade = score(task, keys)
                entry = result[i].setdefault(name, dict(**grade, ms=[]))
                if any(entry[k] != v for k, v in grade.items()):
                    raise ValueError("Ranking changed within a frozen replay")
                entry["ms"].append(round(ms, 4))
    return result


def summarize(rows, arms):
    out = {}
    for arm in arms:
        values = [r[arm] for r in rows]
        ms = [statistics.median(v["ms"]) for v in values]
        info = {
            "medianMS": statistics.median(ms),
            "p95MS": p95(ms),
            "maxMS": max(max(v["ms"]) for v in values),
        }
        if "rank" in values[0]:
            ranks = [v["rank"] for v in values]
            for n in (1, 5, 10, 50):
                info["top" + str(n)] = sum(0 < r <= n for r in ranks)
            info["mrr10"] = statistics.mean(1 / r if 0 < r <= 10 else 0 for r in ranks)
            if "strict" in rows[0]:
                base = [0 < v["strict"]["rank"] <= 5 for v in rows]
                info["gained5"] = sum(0 < r <= 5 and not old for r, old in zip(ranks, base))
                info["lost5"] = sum(not (0 < r <= 5) and old for r, old in zip(ranks, base))
        else:
            info["ndcg5"] = statistics.mean(v["ndcg5"] for v in values)
            info["judged5"] = sum(v["judged5"] for v in values)
        out[arm] = info
    return out


def chronological(index, body, text):
    words = query_words(text)
    headers, _ = query(index, True, words, 50)
    rows, _ = merge(index, body, headers, words, 50, True)
    return [r[0] for r in rows]


def page_trials(index, body, engine, searcher, tasks):
    def ranked_page(text):
        ids = rank_completed_query(engine, searcher, text)
        if not ids:
            return []
        placeholders = ", ".join("?" for _ in ids)
        hydrated = {row[0]: row for row in index.execute(projection + f"IN ({placeholders})", ids)}
        rows = [hydrated[pk] for pk in ids]
        return [row[0] for row in rows]

    methods = {"chronological": lambda text: chronological(index, body, text), "ranked": ranked_page}
    cases = evaluate(tasks, methods, 3)
    return {"summary": summarize(cases, methods), "cases": cases}


def cue_competition(index, body, text):
    words = query_words(text)
    # Count distinct visible competitors using the current literal eligibility rule.
    header_ids = index.execute(
        """
        SELECT DISTINCT m.thread_pk FROM mail_header_search
        JOIN message m ON m.msg_pk=mail_header_search.rowid JOIN thread t ON t.thread_pk=m.thread_pk
        WHERE mail_header_search MATCH ? AND t.last_date>0
    """,
        (words,),
    )
    body_ids = body.execute(
        """
        SELECT DISTINCT m.thread_pk FROM msg_fts JOIN body_doc d ON d.rowid=msg_fts.rowid
        JOIN idx.message m ON m.msg_pk=d.msg_pk JOIN idx.thread t ON t.thread_pk=m.thread_pk
        WHERE msg_fts MATCH ? AND m.fts_state=2 AND t.last_date>0
    """,
        (words,),
    )
    return len(set(header_ids).union(body_ids))


def score_refinements(index, search, tasks, rows, seed):
    # Target-derived counterfactual: one random unseen subject word on the same target.
    # Never select a word by the rank or posting count it produces.
    rng = random.Random(seed)
    for task, row in zip(tasks, rows):
        subject = index.execute(
            "SELECT subject FROM message WHERE thread_pk=? AND fetch_state>0 "
            "ORDER BY internal_date DESC,msg_pk DESC LIMIT 1",
            (task["pk"],),
        ).fetchone()[0]
        existing = set(tokenize(task["query"]))
        choices = [word for word in words(subject) if word not in existing]
        if choices:
            refined = task["query"] + " " + rng.choice(choices)
            row["rankWithExtraSubjectWord"] = score(task, search(refined))["rank"]


def fresh_reader(args):
    path, text = args
    previous_peak = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    start = time.perf_counter_ns()
    index = tantivy.Index.open(str(path))
    rank_completed_query(index, index.searcher(), text)
    ms = (time.perf_counter_ns() - start) / 1e6
    peak = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss - previous_peak
    return {
        "openAndFirstQueryMS": round(ms, 4),
        "peakRSSIncreaseBytes": peak if sys.platform == "darwin" else 1024 * peak,
    }


def fresh_reader_trials(root, tasks):
    chosen = random.Random(73123).sample(tasks, min(len(tasks), 12))
    # Each child opens its first index. The host file cache stays warm.
    with multiprocessing.get_context("spawn").Pool(1, maxtasksperchild=1) as pool:
        return pool.map(fresh_reader, [(root / "fielded", t["query"]) for t in chosen], chunksize=1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--fixture", required=True, type=Path, help="Disposable working directory with Cache/"
    )
    parser.add_argument("--collection", type=Path, help="Public W3C archive and judgments")
    parser.add_argument("--beta-cache", type=Path, help="Installed Beta Cache, opened read-only")
    parser.add_argument("--seed", type=int, default=73123)
    parser.add_argument("--as-of", type=datetime.date.fromisoformat)
    parser.add_argument("--prepare", action="store_true")
    parser.add_argument("--split", choices=["development", "test", "discussion", "personal"])
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()
    if args.prepare:
        if bool(args.collection) == bool(args.beta_cache):
            parser.error("--prepare requires exactly one of --collection and --beta-cache")
    elif not args.split or not args.out:
        parser.error("evaluation requires --split and --out")
    elif args.out.exists():
        parser.error("choose a fresh output path")
    elif args.split == "personal" and not args.as_of:
        parser.error("personal tasks require --as-of")
    elif args.split == "discussion" and not args.collection:
        parser.error("discussion tasks require --collection")
    root, cache = args.fixture, args.fixture / "Cache"
    if args.prepare and args.beta_cache:
        cache.mkdir(parents=True, mode=0o700)
        for name in ["index.sqlite", "search.sqlite"]:
            src = readonly(args.beta_cache / name)
            dest = sqlite3.connect(cache / name)
            src.backup(dest)
            src.close()
            dest.close()
    index, body = open_readers(cache)
    if args.prepare:
        if args.beta_cache:
            with closing(readonly(args.beta_cache / "blobs.sqlite")) as blobs:
                blobs.execute("BEGIN")
                _, stats = build_index(root / "fielded", personal_documents(index, body, blobs))
        else:
            _, stats = build_index(root / "fielded", public_documents(index, args.collection))
        (root / "field-stats.json").write_text(json.dumps(stats))
        print(stats, flush=True)
        return
    engine = tantivy.Index.open(str(root / "fielded"))
    searcher = engine.searcher()
    arms = {"strict": lambda text: lexical_threads(index, body, query_words(text))}

    if args.split == "development":
        from mail_relevance import (
            anchored_streams,
            combine,
            prepare_vocabulary,
            ranked_streams,
        )

        prepare_vocabulary(index, body)
        arms["sqliteAny"] = lambda text: combine(ranked_streams(index, body, text), 0.25)
        arms["sqliteTwoAnchors"] = lambda text: combine(anchored_streams(index, body, text), 0.25)
        for weights in [(1, 1, 1, 1, 1), (2, 2, 1, 1, 1), (4, 2, 1, 1, 1), (2, 1, 1, 1, 2)]:
            arms["field" + "".join(map(str, weights))] = lambda text, w=weights: rank(
                engine, searcher, text, w
            )
    else:
        arms["chronological"] = lambda text: chronological(index, body, text)
    arms["fielded"] = lambda text: rank(engine, searcher, text, FROZEN)
    arms["overlap"] = lambda text: rank(engine, searcher, text, FROZEN, coverage=True)
    arms["withRecent"] = lambda text: rank(engine, searcher, text, FROZEN, recent_slots=1, coverage=True)
    arms["completed"] = lambda text: rank_completed_query(engine, searcher, text)
    if args.split == "personal":
        tasks = [
            t
            for t in sample_tasks(index, args.as_of, args.seed)
            if t["family"] != "refinement" or t["step"] == 2
        ]
    elif args.split == "discussion":
        tasks = ds_tasks(args.collection, index)
    else:
        tasks = [t for t in json.loads((root / "tasks.json").read_text()) if t["split"] == args.split]
        for t in tasks:
            t["pk"] = index.execute(
                "SELECT thread_pk FROM thread WHERE gmail_id=?", [t["target"]]
            ).fetchone()[0]
    rows = evaluate(tasks, arms, 1 if args.split == "development" else 3)
    report = {
        "split": args.split,
        "library": importlib.metadata.version("tantivy"),
        "corpus": json.loads((root / "field-stats.json").read_text()),
        "summary": summarize(rows, arms),
        "cases": rows,
    }
    report["corpus"].update(snapshot_counts(index, body))
    if args.split == "personal":
        score_refinements(index, arms["completed"], tasks, rows, args.seed)
        for task, row in zip(tasks, rows):
            row["matchingThreads"] = cue_competition(index, body, task["query"])
        report.update(asOf=str(args.as_of), seed=args.seed)
        report["byAge"] = {
            age: summarize([r for r in rows if r["age"] == age], arms)
            for age in sorted({r["age"] for r in rows})
        }
    if args.split in ("personal", "test"):
        report["pageLookup"] = page_trials(index, body, engine, searcher, tasks)
    report["freshReaders"] = fresh_reader_trials(root, tasks)
    with args.out.open("x") as f:
        json.dump(report, f, separators=(",", ":"))
        f.write("\n")
    print(json.dumps(report["summary"], indent=2))


if __name__ == "__main__":
    main()
