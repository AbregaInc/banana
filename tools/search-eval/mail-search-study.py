"""Run the Mail proximity and refinement research replays on disposable fielded-mail fixtures."""

import argparse
import calendar
import datetime
import importlib
import itertools
import json
import math
import random
import re
import sqlite3
import time
import zlib
from collections import Counter, defaultdict
from contextlib import closing
from pathlib import Path

import tantivy
from beta_tasks import sample_tasks, words
from mail_field_index import (
    build_index,
    decode_prepared,
    personal_documents,
    public_documents,
    rank_completed_query,
    recipient_addresses,
)

replay = importlib.import_module("fielded-mail")
WORD = re.compile(r"[^\W_]+")
KINDS = ("sender", "participant", "month", "topic")


def prepare(root, collection, blobs_path, positions=False):
    index, body = replay.open_readers(root / "Cache")
    if positions:
        if collection:
            docs = public_documents(index, collection)
        else:
            blobs = replay.readonly(blobs_path)
            blobs.execute("BEGIN")
            docs = personal_documents(index, body, blobs)
        _, stats = build_index(root / "positions", docs, positions=True)
        (root / "position-stats.json").write_text(json.dumps(stats))
    elif collection:
        with sqlite3.connect(root / "study-body.sqlite") as texts:
            texts.execute("CREATE TABLE body(thread_pk INTEGER PRIMARY KEY, packed BLOB)")
            texts.executemany(
                "INSERT INTO body VALUES (?,?)",
                (
                    (pk, zlib.compress(fields[4].encode()))
                    for pk, _, fields in public_documents(index, collection)
                    if fields[4]
                ),
            )
    else:
        blobs = replay.readonly(blobs_path)
        blobs.execute("BEGIN")
        _, stats = build_index(
            root / "people", personal_documents(index, body, blobs, people=True), people=True
        )
        (root / "people-stats.json").write_text(json.dumps(stats))
        blobs.close()


def snapshot_beta(root, cache):
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    (root / "Cache").mkdir(mode=0o700)
    for name in ("index.sqlite", "search.sqlite", "blobs.sqlite"):
        destination = root / name if name == "blobs.sqlite" else root / "Cache" / name
        with (
            closing(replay.readonly(cache / name)) as source,
            closing(sqlite3.connect(destination)) as writer,
        ):
            source.backup(writer)
    db, body = replay.open_readers(root / "Cache")
    with closing(replay.readonly(root / "blobs.sqlite", frozen=True)) as blobs:
        for name, people, positions, stats_file in (
            ("fielded", False, False, "field-stats.json"),
            ("people", True, False, "people-stats.json"),
            ("positions", False, True, "position-stats.json"),
        ):
            documents = personal_documents(db, body, blobs, people=people)
            _, stats = build_index(root / name, documents, people=people, positions=positions)
            (root / stats_file).write_text(json.dumps(stats))


def placeholder(ids):
    return ",".join("?" for _ in ids)


def summaries(db, ids):
    return {
        pk: (subject or "", snippet or "")
        for pk, subject, snippet in db.execute(
            f"SELECT thread_pk,subject,snippet FROM thread WHERE thread_pk IN ({placeholder(ids)})", ids
        )
    }


def body_texts(db, blobs, ids, personal):
    if not personal:
        return {
            pk: zlib.decompress(packed).decode()
            for pk, packed in blobs.execute(
                f"SELECT thread_pk,packed FROM body WHERE thread_pk IN ({placeholder(ids)})", ids
            )
        }
    # Use the newest indexed message in each candidate conversation. Prepared text may be absent.
    rows = db.execute(
        f"""
        SELECT t.thread_pk,a.email,m.gmail_id FROM thread t
        JOIN message m ON m.msg_pk=(
            SELECT msg_pk FROM message WHERE thread_pk=t.thread_pk AND fts_state=2
            AND EXISTS (SELECT 1 FROM search.body_doc d WHERE d.msg_pk=message.msg_pk)
            ORDER BY internal_date DESC,msg_pk DESC LIMIT 1)
        JOIN account a ON a.account_pk=m.account_pk WHERE t.thread_pk IN ({placeholder(ids)})
    """,
        ids,
    )
    result = {}
    for pk, account, key in rows:
        row = blobs.execute(
            "SELECT text FROM prepared WHERE account=? AND gmail_id=?", (account, key)
        ).fetchone()
        if row and row[0]:
            result[pk] = decode_prepared(row[0])
    return result


def pair_evidence(text, pairs, wanted):
    positions = defaultdict(list)
    for i, token in enumerate(WORD.finditer(text.casefold())):
        word = token[0]
        if word in wanted:
            positions[word].append(i)
    weights = []
    for a, b in pairs:
        first, second = positions[a], positions[b]
        i = j = 0
        best = 0
        while i < len(first) and j < len(second):
            distance = second[j] - first[i]
            if distance == 1:
                best = 1
                break
            if 0 < abs(distance) < 8:
                best = 0.5
            if distance > 0:
                i += 1
            else:
                j += 1
        weights.append(best)
    return weights


def positional_features(db, blobs, text, ids, mode, personal):
    tokens = WORD.findall(text.casefold())
    pairs = [(a, b) for a, b in itertools.pairwise(tokens) if a != b]
    if not pairs or not ids:
        return [0.0] * len(ids)
    fields = summaries(db, ids)
    bodies = body_texts(db, blobs, ids, personal) if mode == "body" else {}
    wanted = set(tokens)
    features = []
    for pk in ids:
        evidence = [
            pair_evidence(field, pairs, wanted) for field in (*fields[pk], bodies.get(pk, "")) if field
        ]
        features.append(sum(map(max, zip(*evidence))) / len(pairs) if evidence else 0)
    return features


def rerank(ids, evidence, strength):
    return [
        pk
        for _, _, pk in sorted(
            (math.log2(pos) - strength * boost, pos, pk)
            for pos, (pk, boost) in enumerate(zip(ids, evidence), 1)
        )
    ]


def saved_tasks(db, root, split, collection, seed):
    if split == "personal":
        return [
            t
            for t in sample_tasks(db, datetime.date(2026, 11, 25), seed)
            if t["family"] != "refinement" or t["step"] == 2
        ]
    if split == "discussion":
        return replay.ds_tasks(collection, db)
    tasks = [t for t in json.loads((root / "tasks.json").read_text()) if t["split"] == split]
    for task in tasks:
        task["pk"] = db.execute("SELECT thread_pk FROM thread WHERE gmail_id=?", [task["target"]]).fetchone()[
            0
        ]
    return tasks


def month_start(stamp):
    date = datetime.datetime.fromtimestamp(stamp / 1000, datetime.UTC)
    return (date.year, date.month)


def metadata(db, ids, self_addresses):
    rows = db.execute(
        f"""
        SELECT t.thread_pk,t.last_date,m.from_addr,m.recipients,m.subject,m.from_name FROM thread t
        LEFT JOIN message m ON m.msg_pk=(
            SELECT msg_pk FROM message WHERE thread_pk=t.thread_pk AND fetch_state>0
            ORDER BY internal_date DESC,msg_pk DESC LIMIT 1)
        WHERE t.thread_pk IN ({placeholder(ids)})
    """,
        ids,
    )
    result = {}
    for pk, stamp, sender, encoded, subject, display in rows:
        sender = (sender or "").strip().casefold()
        recipients = set(recipient_addresses(encoded)) - self_addresses - {sender}
        result[pk] = {
            "sender": [sender] if sender and sender not in self_addresses else [],
            "senderKeys": [sender, sender.split("@")[-1], *WORD.findall((display or "").lower())],
            "participant": sorted(recipients),
            "month": [month_start(stamp)],
            "topic": [w for w in words(subject) if w.isalpha()],
        }
    return result


def suggest(query, ids, meta):
    if len(ids) < 10:
        return {}
    existing = set(WORD.findall(query.casefold()))
    result = {}
    for kind in KINDS:
        counts = Counter(v for pk in ids for v in meta[pk][kind] if kind != "topic" or v not in existing)
        eligible = [v for v, c in counts.items() if 2 <= c <= 0.8 * len(ids)]
        if eligible:
            # Split the visible set; insertion order breaks ties by the first result carrying the value.
            result[kind] = min(eligible, key=lambda v: abs(counts[v] - len(ids) / 2))
    return result


def date_bounds(kind, value):
    year, month = value
    if kind == "quarter":
        month = 1 + 3 * ((month - 1) // 3)
    low = calendar.timegm((year, month, 1, 0, 0, 0)) * 1000
    days = sum(calendar.monthrange(year, m)[1] for m in range(month, month + (3 if kind == "quarter" else 1)))
    return low, low + days * 86_400_000


def verify_scope(db, kind, value, ids):
    if not ids or kind == "topic":
        return
    if kind in ("month", "quarter"):
        low, high = date_bounds(kind, value)
        count = db.execute(
            f"SELECT count(*) FROM thread WHERE thread_pk IN ({placeholder(ids)}) "
            "AND last_date>=? AND last_date<?",
            [*ids, low, high],
        ).fetchone()[0]
        valid = count == len(ids)
    else:
        rows = db.execute(
            f"SELECT thread_pk,from_addr,recipients FROM message WHERE thread_pk IN ({placeholder(ids)})", ids
        )
        found = {
            pk
            for pk, sender, recipients in rows
            if (sender or "").strip().casefold() == value
            or (kind == "participant" and value in recipient_addresses(recipients))
        }
        valid = found == set(ids)
    if not valid:
        raise RuntimeError("A result violated the selected scope")


def sender_choices(db, prefix, mine):
    # The existing composer's indexed prefix range, 400-row cap and ranking formula.
    seen = set()
    scored = []
    now_ms = datetime.datetime(2026, 11, 25, tzinfo=datetime.UTC).timestamp() * 1000
    for addr, sent, received, date in db.execute(
        """
        SELECT c.addr,c.sent,c.received,c.last_date FROM correspondent_key k
        CROSS JOIN correspondent c ON c.addr=k.addr WHERE k.key>=? AND k.key<? LIMIT 400
    """,
        (prefix, prefix + "\uffff"),
    ):
        if addr in mine or addr in seen:
            continue
        seen.add(addr)
        days = max(0, (now_ms - date) / 86_400_000)
        scored.append((sent == 0, -(sent * 3 + received + 1) / (1 + days / 30), addr))
    return [addr for _, _, addr in sorted(scored)[:3]]


def apply_refinement(engine, searcher, query, kind, value):
    if kind == "topic":
        return rank_completed_query(engine, searcher, query + " " + value)
    if kind in ("month", "quarter"):
        low, high = date_bounds(kind, value)
        scope = tantivy.Query.range_query(
            engine.schema, "date", tantivy.FieldType.Unsigned, low, high, include_upper=False
        )
    else:
        sender = tantivy.Query.term_query(engine.schema, "from_address", value, "basic")
        scope = sender
        if kind == "participant":
            recipient = tantivy.Query.term_query(engine.schema, "recipient_address", value, "basic")
            scope = tantivy.Query.boolean_query(
                [(tantivy.Occur.Should, sender), (tantivy.Occur.Should, recipient)]
            )
    return rank_completed_query(engine, searcher, query, scope=scope)


def rank_at(ids, target):
    return ids.index(target) + 1 if target in ids else 0


def facets(db, engine, searcher, tasks, seed):
    self_addresses = {r[0].strip().casefold() for r in db.execute("SELECT email FROM account")}
    rng = random.Random(seed)
    rows = []
    for task in tasks:
        query, pk = task["query"], task["pk"]
        ids = rank_completed_query(engine, searcher, query)
        start = time.perf_counter_ns()
        meta = metadata(db, ids, self_addresses)
        options = suggest(query, ids, meta)
        generation = (time.perf_counter_ns() - start) / 1e6
        # Target data first enters here, after all displayable choices are fixed.
        target = metadata(db, [pk], self_addresses)[pk]
        row = {
            "id": task["id"],
            "family": task["family"],
            "baseline": rank_at(ids, pk),
            "generationMS": round(generation, 4),
            "suggested": {},
            "applicable": [],
            "remembered": {},
            "applyMS": [],
        }
        existing = set(WORD.findall(query.casefold()))
        for kind in KINDS:
            answer = [v for v in target[kind] if kind != "topic" or v not in existing]
            trials = {}
            if answer:
                trials["remembered"] = rng.choice(answer)
            if kind in options:
                if options[kind] in answer:
                    row["applicable"].append(kind)
                trials["suggested"] = options[kind]
            for origin, value in trials.items():
                start = time.perf_counter_ns()
                ranked = apply_refinement(engine, searcher, query, kind, value)
                ms = (time.perf_counter_ns() - start) / 1e6
                verify_scope(db, kind, value, ranked)
                row[origin][kind] = rank_at(ranked, pk)
                if origin == "suggested":
                    row["applyMS"].append(round(ms, 4))
        month = target["month"][0]
        quarter = apply_refinement(engine, searcher, query, "quarter", month)
        verify_scope(db, "quarter", month, quarter)
        row["quarter"] = rank_at(quarter, pk)
        if target["sender"]:
            sender = target["sender"][0]
            name = db.execute(
                "SELECT from_name FROM message WHERE thread_pk=? AND fetch_state>0 "
                "ORDER BY internal_date DESC,msg_pk DESC LIMIT 1",
                (pk,),
            ).fetchone()[0]
            token = next((w for w in WORD.findall((name or "").lower()) if len(w) >= 3), sender.split("@")[0])
            if len(token) >= 3:
                start = time.perf_counter_ns()
                choices = sender_choices(db, token[:3], self_addresses)
                row["senderPrefixMS"] = round((time.perf_counter_ns() - start) / 1e6, 4)
                row["senderChoiceRank"] = rank_at(choices, sender)
                counts = Counter(
                    addr
                    for key in ids
                    if any(w.startswith(token[:3]) for w in meta[key]["senderKeys"])
                    for addr in meta[key]["sender"]
                )
                contextual = list(dict.fromkeys([addr for addr, count in counts.most_common()] + choices))[:3]
                row["contextSenderChoiceRank"] = rank_at(contextual, sender)
        rows.append(row)
    return rows


def positional(db, blobs, engine, tasks, personal):
    searcher = engine.searcher()
    rows = [{"id": task["id"]} for task in tasks]
    for trial in range(3):
        order = list(range(len(tasks)))
        rng = random.Random(506 + trial)
        rng.shuffle(order)
        for i in order:
            task, row = tasks[i], rows[i]
            ids = rank_completed_query(engine, searcher, task["query"])
            row["baseline"] = replay.score(task, ids)
            modes = ["header", "body"]
            rng.shuffle(modes)
            for mode in modes:
                start = time.perf_counter_ns()
                evidence = positional_features(db, blobs, task["query"], ids, mode, personal)
                feature_ms = (time.perf_counter_ns() - start) / 1e6
                for strength in (1, 2, 4):
                    sort_start = time.perf_counter_ns()
                    reordered = rerank(ids, evidence, strength)
                    if strength == 1:
                        row.setdefault(mode + "MS", []).append(
                            round(feature_ms + (time.perf_counter_ns() - sort_start) / 1e6, 4)
                        )
                    if set(reordered) != set(ids):
                        raise RuntimeError("Candidate set changed")
                    metrics = replay.score(task, reordered)
                    key = mode + str(strength)
                    if row.setdefault(key, metrics) != metrics:
                        raise RuntimeError("Reranking changed within replay")
    return rows


def postings_features(index, searcher, text, ids):
    tokens = WORD.findall(text.casefold())
    pairs = [(a, b) for a, b in itertools.pairwise(tokens) if a != b]
    if not pairs or not ids:
        return [0.0] * len(ids), False
    fields = ["subject", "snippet", "body"]
    # Each pair contributes half a point for a window and the other half for exact order.
    clauses = []
    for a, b in pairs:
        exact = index.parse_query(f'"{a} {b}"', fields)
        nearby = index.parse_query(f'"{a} {b}"~6 OR "{b} {a}"~6', fields)
        for match in [exact, nearby]:
            clauses.append((tantivy.Occur.Should, tantivy.Query.const_score_query(match, 0.5)))
    selected = tantivy.Query.term_set_query(index.schema, "thread", ids)
    query = tantivy.Query.boolean_query(
        [
            (tantivy.Occur.Must, tantivy.Query.const_score_query(selected, 0)),
            (tantivy.Occur.Must, tantivy.Query.boolean_query(clauses)),
        ]
    )
    hits = searcher.search(query, limit=1000, count=False).hits
    threads = searcher.fast_field_values("thread", [address for _, address in hits])
    scores = {}
    for pk, (score, _) in zip(threads, hits):
        scores.setdefault(pk, score / len(pairs))
    return [scores.get(pk, 0) for pk in ids], len(hits) == 1000


def postings_replay(root, engine, tasks):
    index = tantivy.Index.open(str(root / "positions"))
    searcher = index.searcher()
    first = engine.searcher()
    rows = []
    for task in tasks:
        ids = rank_completed_query(engine, first, task["query"])
        row = {"id": task["id"], "baseline": replay.score(task, ids), "ms": []}
        for _ in range(3):
            start = time.perf_counter_ns()
            values, capped = postings_features(index, searcher, task["query"], ids)
            keys = rerank(ids, values, 1)
            row["ms"].append(round((time.perf_counter_ns() - start) / 1e6, 4))
            for strength in (1, 2, 4):
                row[str(strength)] = replay.score(
                    task, keys if strength == 1 else rerank(ids, values, strength)
                )
            row["capped"] = capped
        rows.append(row)
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", required=True, type=Path)
    parser.add_argument("--collection", type=Path)
    parser.add_argument("--blobs", type=Path)
    parser.add_argument(
        "--snapshot-beta",
        type=Path,
        help="Prepare all three research indexes from one disposable set of Beta backups",
    )
    parser.add_argument("--prepare", action="store_true")
    parser.add_argument(
        "--positions", action="store_true", help="Prepare or evaluate the positional postings alternative"
    )
    parser.add_argument("--split", choices=("development", "test", "discussion", "personal"))
    parser.add_argument("--seed", type=int, default=73125)
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()
    if args.snapshot_beta:
        snapshot_beta(args.fixture, args.snapshot_beta)
        return
    if args.prepare:
        if bool(args.collection) == bool(args.blobs):
            parser.error("pass exactly one of --collection and --blobs for preparation")
        prepare(args.fixture, args.collection, args.blobs, args.positions)
        return
    if not args.split or not args.out or args.out.exists():
        parser.error("pass --split and a fresh --out path")
    root = args.fixture
    db, _ = replay.open_readers(root / "Cache")
    personal = args.split == "personal"
    if args.split == "discussion" and not args.collection:
        parser.error("discussion replay requires --collection")
    engine = tantivy.Index.open(str(root / "fielded"))
    tasks = saved_tasks(db, root, args.split, args.collection, args.seed)
    result = {"split": args.split}
    if personal:
        result["seed"] = args.seed
    if args.positions:
        result["postings"] = postings_replay(root, engine, tasks)
        result["index"] = json.loads((root / "position-stats.json").read_text())
        result["baseIndex"] = json.loads((root / "field-stats.json").read_text())
    else:
        if personal:
            db.execute(
                "ATTACH DATABASE ? AS search",
                [(root / "Cache/search.sqlite").resolve().as_uri() + "?mode=ro&immutable=1"],
            )
        source = (args.blobs or root / "blobs.sqlite") if personal else root / "study-body.sqlite"
        with closing(replay.readonly(source)) as blobs:
            blobs.execute("BEGIN")
            result["proximity"] = positional(db, blobs, engine, tasks, personal)
    if personal and not args.positions:
        scoped = tantivy.Index.open(str(root / "people"))
        result["facetedIndex"] = json.loads((root / "people-stats.json").read_text())
        result["baseIndex"] = json.loads((root / "field-stats.json").read_text())
        result["refinements"] = facets(db, scoped, scoped.searcher(), tasks, args.seed)
        for task, row in zip(tasks, result["refinements"]):
            # Check all ranks, including non-target ranks, before comparing a scope to the baseline.
            if rank_completed_query(engine, engine.searcher(), task["query"]) != rank_completed_query(
                scoped, scoped.searcher(), task["query"]
            ):
                row["unscopedOrderDiffers"] = True
    with args.out.open("x") as f:
        json.dump(result, f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main()
