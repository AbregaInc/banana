"""Local replay of released retrieval models. Model inputs and result IDs stay in the disposable fixture."""

import argparse
import datetime
import importlib
import json
import random
import sqlite3
import statistics
import time
from pathlib import Path

import numpy as np
import onnxruntime as ort
import tantivy
from beta_tasks import sample_tasks
from mail_field_index import (
    decode_prepared,
    personal_documents,
    public_documents,
    tokenize,
)
from model2vec import StaticModel
from tokenizers import Tokenizer
from usearch.index import Index

replay = importlib.import_module("fielded-mail")
first = importlib.import_module("mail-first-query")
# Evaluation questions only. Retrieval receives the first column verbatim.
PURPOSE = [
    (
        "delta receipt",
        "An actual Delta Air Lines purchase, ticket charge or payment record; a promotion or itinerary without evidence of a charge is insufficient.",
    ),
    (
        "hotel confirmation",
        "A confirmed stay with a hotel or lodging provider, with booking-specific details.",
    ),
    (
        "proof I paid",
        "A completed payment or purchase documented by the sender; an unpaid invoice is insufficient.",
    ),
    (
        "where is my package",
        "A shipment update for an actual order, with carrier, tracking or delivery status.",
    ),
    ("what do I owe", "An outstanding amount payable by the recipient, with an amount or bill details."),
    (
        "boarding pass",
        "A pass or instructions/link for accessing the recipient's boarding pass; a flight offer or mere itinerary is insufficient.",
    ),
    ("dinner reservation", "A confirmed restaurant table booking; a promotion is insufficient."),
    ("rental car booking", "An actual vehicle rental reservation with booking-specific details."),
    (
        "concert tickets",
        "An actual concert ticket, ticket purchase confirmation, or direct access to purchased concert tickets.",
    ),
    ("flight confirmation number", "A flight booking with a reservation locator or ticket number."),
    (
        "refund for my order",
        "A refund or reversal for a particular purchase, including a confirmed refund in progress.",
    ),
    (
        "invoice for my subscription",
        "Billing document for a particular subscription period or renewal charge.",
    ),
    ("when does my free trial end", "The end or billing-start date for the recipient's actual trial."),
    (
        "password reset link",
        "A message initiated for resetting a password or containing a password reset link, rather than a generic help footer.",
    ),
    ("my train ticket", "A specific rail journey booking or ticket, rather than a promotion."),
    ("return shipping label", "A label or direct access to a return label for an actual return."),
    ("payment didn't go through", "A particular failed, rejected or declined payment."),
    (
        "time of my appointment",
        "A confirmed appointment or reminder stating its time or direct scheduling details.",
    ),
    ("when will my order arrive", "An estimated or actual delivery date for a particular shipment or order."),
    ("room check-in details", "Arrival, check-in time or access instructions for an actual lodging stay."),
]


def put_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False) + "\n")


def beta_docs(db, body, blobs):
    indexed = {pk for (pk,) in body.execute("SELECT msg_pk FROM body_doc")}
    for pk, subject, snippet, mpk, name, addr, state, account, key in db.execute("""
        SELECT t.thread_pk,t.subject,t.snippet,m.msg_pk,m.from_name,m.from_addr,m.fts_state,a.email,m.gmail_id
        FROM thread t JOIN message m ON m.msg_pk=(SELECT msg_pk FROM message WHERE thread_pk=t.thread_pk
        ORDER BY internal_date DESC,msg_pk DESC LIMIT 1) JOIN account a ON a.account_pk=m.account_pk
        WHERE t.last_date>0 ORDER BY t.thread_pk
    """):
        text = ""
        if state == 2 and mpk in indexed:
            row = blobs.execute(
                "SELECT text FROM prepared WHERE account=? AND gmail_id=?", (account, key)
            ).fetchone()
            if row and row[0]:
                text = decode_prepared(row[0])
        yield pk, subject or "", (name or "") + " " + (addr or ""), snippet or "", text


def prepare(root, collection, blobfile):
    db, body = replay.open_readers(root / "Cache")
    tasks = []
    if collection:
        docs = ((pk, f[0], f[1], f[3], f[4]) for pk, _, f in public_documents(db, collection))
        for task in json.loads((root / "tasks.json").read_text()):
            pk = db.execute("SELECT thread_pk FROM thread WHERE gmail_id=?", (task["target"],)).fetchone()[0]
            tasks.append({"id": task["id"], "query": task["query"], "split": task["split"], "pk": pk})
        for task in replay.ds_tasks(collection, db):
            tasks.append(
                {"id": task["id"], "query": task["query"], "split": "discussion", "grades": task["grades"]}
            )
    else:
        blobs = replay.readonly(blobfile)
        blobs.execute("BEGIN")
        docs = beta_docs(db, body, blobs)
        for t in sample_tasks(db, datetime.date(2026, 11, 25), 73129):
            if t["step"] == 1:
                tasks.append({"id": t["id"], "query": t["query"], "pk": t["pk"], "split": "known"})
        tasks.extend(
            {"id": f"purpose-{i}", "query": q, "split": "purpose"} for i, (q, _) in enumerate(PURPOSE)
        )
    passages = sqlite3.connect(root / "passages.sqlite")
    passages.execute("CREATE TABLE passage(pk INTEGER PRIMARY KEY,text TEXT NOT NULL)")
    with (root / "documents.jsonl").open("x") as out:
        for pk, subject, sender, snippet, text in docs:
            # Shared evidence budget. Keep mail headers and the opening of the newest retained message.
            doc = {
                "id": pk,
                "subject": subject[:300],
                "sender": sender[:200],
                "snippet": snippet[:320],
                "body": text[:1800],
            }
            out.write(json.dumps(doc, ensure_ascii=False) + "\n")
            passage = "\n".join(doc[key] for key in ("subject", "sender", "snippet", "body") if doc[key])
            passages.execute("INSERT INTO passage VALUES (?,?)", (pk, passage))
    passages.commit()
    passages.close()
    put_json(root / "queries.json", tasks)


def export_messages(root, collection, blobfile):
    db, body = replay.open_readers(root / "Cache")
    if collection:
        docs = public_documents(db, collection)
    else:
        blobs = replay.readonly(blobfile)
        blobs.execute("BEGIN")
        docs = personal_documents(db, body, blobs)
    names = ["subject", "sender", "recipients", "snippet", "body"]
    with (root / "messages.jsonl").open("x") as output:
        for pk, _, fields in docs:
            record = {name: value or "" for name, value in zip(names, fields, strict=True)}
            output.write(json.dumps({"id": pk, **record}, ensure_ascii=False) + "\n")


def dense_build(root, modeldir):
    start = time.perf_counter()
    model = StaticModel.from_pretrained(modeldir, force_download=False)
    idx = Index(ndim=512, metric="cos", dtype="i8", connectivity=16, expansion_add=64, expansion_search=64)
    rows = sqlite3.connect(root / "passages.sqlite").execute("SELECT pk,text FROM passage ORDER BY pk")
    while batch := rows.fetchmany(512):
        keys, texts = zip(*batch)
        vec = model.encode(list(texts), max_length=192, use_multiprocessing=False)
        idx.add(np.asarray(keys, dtype=np.uint64), vec, threads=2)
    path = root / "dense.usearch"
    idx.save(str(path))
    put_json(
        root / "dense-build.json",
        {"documents": len(idx), "seconds": time.perf_counter() - start, "bytes": path.stat().st_size},
    )


def fusion(a, b):
    scores = {}
    for stream in (a, b):
        for rank, pk in enumerate(stream, 1):
            scores[pk] = scores.get(pk, 0) + 1 / (60 + rank)
    return sorted(scores, key=lambda pk: -scores[pk])[:50]


class Reranker:
    def __init__(self, modeldir):
        self.tokenizer = Tokenizer.from_file(str(modeldir / "tokenizer.json"))
        self.tokenizer.enable_truncation(max_length=128)
        self.tokenizer.enable_padding(pad_id=0, pad_token="[PAD]")
        opts = ort.SessionOptions()
        opts.intra_op_num_threads = 2
        opts.inter_op_num_threads = 1
        self.session = ort.InferenceSession(
            str(modeldir / "model_qint8_arm64.onnx"), sess_options=opts, providers=["CPUExecutionProvider"]
        )

    def apply(self, query, keys, db, depth):
        candidates = keys[:depth]
        if not candidates:
            return keys
        texts = dict(
            db.execute(
                "SELECT pk,text FROM passage WHERE pk IN (" + ",".join("?" for _ in candidates) + ")",
                candidates,
            )
        )
        pairs = self.tokenizer.encode_batch([(query, texts[k]) for k in candidates])
        inputs = {
            n: np.asarray([getattr(p, a) for p in pairs], dtype=np.int64)
            for n, a in [
                ("input_ids", "ids"),
                ("attention_mask", "attention_mask"),
                ("token_type_ids", "type_ids"),
            ]
        }
        scores = self.session.run(None, inputs)[0].ravel()
        return [candidates[i] for i in sorted(range(len(scores)), key=lambda i: -scores[i])] + keys[depth:]


def retrieve(root, models):
    tasks = json.loads((root / "queries.json").read_text())
    model = StaticModel.from_pretrained(models / "potion", force_download=False)
    idx = Index.restore(str(root / "dense.usearch"), view=True)
    idx.expansion_search = 64
    reranker = Reranker(models / "reranker")
    texts = sqlite3.connect(root / "passages.sqlite")
    lexical = tantivy.Index.open(str(root / "fielded"))
    reader = lexical.searcher()
    previous_files = root / "filenames.sqlite"
    filenames = replay.readonly(previous_files, frozen=True) if previous_files.exists() else None
    if filenames:
        filenames.create_function("folded", 1, str.casefold, deterministic=True)
    results = {}
    order = list(tasks)
    random.Random(144).shuffle(order)
    for t in order:
        q = t["query"]
        start = time.perf_counter()
        old = first.first_query(lexical, reader, q, filenames, infer_topic=False)
        old_ms = (time.perf_counter() - start) * 1000
        start = time.perf_counter()
        vec = model.encode([q], max_length=192, use_multiprocessing=False)[0]
        dense = list(map(int, idx.search(vec, 50, threads=1).keys))
        dense_ms = (time.perf_counter() - start) * 1000
        hybrid = fusion(old, dense)
        row = {"previous": old, "dense": dense, "hybrid": hybrid, "oldMS": old_ms, "denseMS": dense_ms}
        for name, candidates in (("lexicalCE", old), ("hybridCE", hybrid)):
            start = time.perf_counter()
            row[name] = reranker.apply(q, candidates, texts, 20)
            row[name + "MS"] = (time.perf_counter() - start) * 1000
        results[t["id"]] = row
    put_json(root / "model-results.json", results)


def scored_results(root):
    results = json.loads((root / "model-results.json").read_text())
    short = root / "shortlist.json"
    if short.exists():
        for key, extras in json.loads(short.read_text()).items():
            results[key].update(extras)
    recent = root / "recent-results.json"
    if recent.exists():
        for key, row in json.loads(recent.read_text()).items():
            results[key].update(row)
    full = root / "full-results.json"
    if full.exists():
        for entry in json.loads(full.read_text()):
            row = results[entry["id"]]
            row["swiftFull"] = entry["keys"]
            row["swiftFullMS"] = statistics.median(entry["ms"])
    return results


def recent_comparison(root):
    # Apply the earlier 90-day recency preference to the Swift result order.
    # The ID-only replay has ranks rather than raw BM25 scores at this boundary.
    db, _ = replay.open_readers(root / "Cache")
    native = {v["id"]: v for v in json.loads((root / "full-results.json").read_text())}
    output = {}
    for task in json.loads((root / "queries.json").read_text()):
        key = task["id"]
        keys = native[key]["keys"]
        start = time.perf_counter()
        if keys and len(tokenize(task["query"])) <= 2:
            sql = (
                "SELECT thread_pk,last_date FROM thread WHERE thread_pk IN ("
                + ",".join("?" for _ in keys)
                + ")"
            )
            dates = dict(db.execute(sql, keys))
            newest = max(dates.values())
            scores = [
                (1 + 0.5 / (1 + (newest - dates[pk]) / (90 * 86400000))) / (10 + rank)
                for rank, pk in enumerate(keys, 1)
            ]
            keys = [keys[i] for i in sorted(range(len(keys)), key=lambda i: -scores[i])]
        output[key] = {"swiftRecent": keys, "recentMS": (time.perf_counter() - start) * 1000}
        start = time.perf_counter()
        terms = tokenize(task["query"])
        merged = native[key]["keys"]
        if len(terms) == 1:
            senders = db.execute(
                """
                SELECT t.thread_pk FROM mail_header_search h
                JOIN message m ON m.msg_pk=h.rowid JOIN thread t ON t.thread_pk=m.thread_pk
                WHERE mail_header_search MATCH ? AND t.last_date>0
                GROUP BY t.thread_pk ORDER BY t.last_date DESC,t.thread_pk LIMIT 2
            """,
                [f'sender : "{terms[0]}"'],
            )
            merged = list(dict.fromkeys(merged[:1] + [pk for (pk,) in senders] + merged[1:]))[:50]
        output[key].update(swiftSender=merged, senderMS=(time.perf_counter() - start) * 1000)
    put_json(root / "recent-results.json", output)


def shortlist_comparison(root, models):
    tasks = json.loads((root / "queries.json").read_text())
    results = json.loads((root / "model-results.json").read_text())
    db, body = replay.open_readers(root / "Cache")
    passages = sqlite3.connect(root / "passages.sqlite")
    fast = Reranker(models / "fast")
    additions = {}
    for task in tasks:
        key, q = task["id"], task["query"]
        row = additions[key] = {}
        start = time.perf_counter()
        row["chronological"] = replay.chronological(db, body, q)
        row["chronologicalMS"] = (time.perf_counter() - start) * 1000
        for name, source in [("lexFast", "previous"), ("hybridFast", "hybrid")]:
            start = time.perf_counter()
            row[name] = fast.apply(q, results[key][source], passages, 8)
            row[name + "MS"] = (time.perf_counter() - start) * 1000
    put_json(root / "shortlist.json", additions)


def native_comparison(root, models):
    tasks = json.loads((root / "queries.json").read_text())
    results = scored_results(root)
    native = {v["id"]: v for v in json.loads((root / "swift-results.json").read_text())}
    coverage = {v["id"]: v for v in json.loads((root / "coverage-results.json").read_text())}
    shortlist_path = root / "shortlist.json"
    if not shortlist_path.exists():
        shortlist_comparison(root, models)
    shortlist = json.loads(shortlist_path.read_text())
    passages = sqlite3.connect(root / "passages.sqlite")
    reranker = Reranker(models / "reranker")
    fast = Reranker(models / "fast")
    for task in tasks:
        key = task["id"]
        r = results[key]
        q = task["query"]
        r.update(shortlist[key])
        r["swift"] = native[key]["keys"]
        r["swiftMS"] = statistics.median(native[key]["ms"])
        r["swiftCoverage"] = coverage[key]["keys"]
        r["swiftCoverageMS"] = statistics.median(coverage[key]["ms"])
        r["swiftHybrid"] = fusion(r["swift"], r["dense"])
        for name, source in [
            ("swiftCE", "swift"),
            ("swiftHybridCE", "swiftHybrid"),
            ("swiftFullCE", "swiftFull"),
        ]:
            start = time.perf_counter()
            r[name] = reranker.apply(q, r[source], passages, 20)
            r[name + "MS"] = (time.perf_counter() - start) * 1000
        for name, source in [("swiftFast", "swift"), ("swiftFullFast", "swiftFull")]:
            start = time.perf_counter()
            r[name] = fast.apply(q, r[source], passages, 8)
            r[name + "MS"] = (time.perf_counter() - start) * 1000
        r["guardedCE"] = fusion(r["previous"], r["lexicalCE"])
        r["guardedHybridCE"] = fusion(r["previous"], r["hybridCE"])
    put_json(root / "model-results.json", results)


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument(
        "command", choices=["prepare", "messages", "dense", "retrieve", "shortlist", "recent", "compare"]
    )
    p.add_argument("--fixture", required=True, type=Path)
    p.add_argument("--models", type=Path)
    p.add_argument("--collection", type=Path)
    p.add_argument("--blobs", type=Path)
    a = p.parse_args()
    if a.command == "messages":
        export_messages(a.fixture, a.collection, a.blobs)
    if a.command == "prepare":
        prepare(a.fixture, a.collection, a.blobs)
    if a.command == "dense":
        dense_build(a.fixture, a.models / "potion")
    if a.command == "retrieve":
        retrieve(a.fixture, a.models)
    if a.command == "recent":
        recent_comparison(a.fixture)
    if a.command == "shortlist":
        shortlist_comparison(a.fixture, a.models)
    if a.command == "compare":
        native_comparison(a.fixture, a.models)
