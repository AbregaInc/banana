"""Disposable fielded BM25 index for offline evaluation. Requires tantivy==0.27.0."""

import json
import math
import re
import tarfile
import time
import zlib
from pathlib import Path

import tantivy
from trec_corpus import read_message

FIELDS = ["subject", "sender", "recipients", "snippet", "body"]


def public_documents(index, collection):
    # Use exactly the same public document IDs, headers and body truncation as the SQLite replay.
    lookup = {
        k: (pk, date) for k, pk, date in index.execute("SELECT gmail_id,thread_pk,last_date FROM thread")
    }
    for number in range(1, 4):
        with tarfile.open(collection / f"part{number}.tar.gz", "r|gz") as archive:
            for member in archive:
                if not member.isfile():
                    continue
                key = Path(member.name).stem
                entry = lookup.pop(key, None)
                if not entry or entry[1] <= 0:
                    continue
                fields, _, recipients, body = read_message(archive.extractfile(member).read())
                header = [
                    fields.get("subject", ""),
                    fields.get("name", "") + " " + fields.get("email", ""),
                    recipients,
                    " ".join(body[:256].split())[:160],
                ]
                yield *entry, header + [body[:16000]]


def decode_blob(blob):
    if blob[:4] != b"MBZ1" or len(blob) < 8:
        raise ValueError("Unknown prepared-text envelope")
    length = int.from_bytes(blob[4:8], "big")
    if length > 16 * 1024**2:
        raise ValueError("Oversize prepared text")
    text = zlib.decompressobj(-15).decompress(blob[8:], length + 1) if length else b""
    if len(text) != length:
        raise ValueError("Invalid prepared-text length")
    return text


def decode_prepared(blob):
    return decode_blob(blob).decode("utf-8")[:16000]


def recipient_addresses(encoded):
    recipients = json.loads(encoded or "{}")
    return sorted(
        {
            address.strip().casefold()
            for field in ("to", "cc", "bcc")
            for address in recipients.get(field, [])
            if address.strip()
        }
    )


def personal_documents(index, body, blobs, people=False):
    searchable = {pk for (pk,) in body.execute("SELECT msg_pk FROM body_doc")}
    for pk, thread, date, account, key, state, sender, recipients, *header in index.execute("""
        SELECT m.msg_pk,m.thread_pk,t.last_date,a.email,m.gmail_id,m.fts_state,m.from_addr,m.recipients,
               h.subject,h.sender,h.recipients,h.snippet
        FROM message m JOIN thread t ON t.thread_pk=m.thread_pk
        JOIN account a ON a.account_pk=m.account_pk JOIN mail_header_search h ON h.rowid=m.msg_pk
        WHERE t.last_date>0 ORDER BY m.msg_pk
    """):
        text = ""
        if state == 2 and pk in searchable:
            row = blobs.execute(
                "SELECT text FROM prepared WHERE account=? AND gmail_id=?", (account, key)
            ).fetchone()
            if row and row[0]:
                text = decode_prepared(row[0])
        fields = header + [text]
        if people:
            fields.extend([(sender or "").strip().casefold(), recipient_addresses(recipients)])
        yield thread, date, fields


def build_index(path, documents, people=False, positions=False):
    schema = tantivy.SchemaBuilder()
    for field in FIELDS:
        analyzer = "default" if field in ("sender", "recipients") else "en_stem"
        schema.add_text_field(
            field, tokenizer_name=analyzer, index_option="position" if positions else "freq"
        )
    field_names = FIELDS.copy()
    if people:
        for field in ("from_address", "recipient_address"):
            schema.add_text_field(field, tokenizer_name="raw", index_option="basic")
            field_names.append(field)
    schema.add_unsigned_field("thread", fast=True, indexed=positions)
    schema.add_unsigned_field("date", fast=True)
    schema = schema.build()
    path.mkdir(mode=0o700)
    start = time.perf_counter()
    index = tantivy.Index(schema, path=str(path))
    writer = index.writer(heap_size=64_000_000, num_threads=1)
    messages = bodies = 0
    for pk, date, fields in documents:
        data = {k: v for k, v in zip(field_names, fields) if v}
        data.update(thread=pk, date=date)
        writer.add_document(tantivy.Document.from_dict(data, schema))
        messages += 1
        bodies += bool(fields[4])
    writer.commit()
    writer.wait_merging_threads()
    index.reload()
    return index, {
        "messages": messages,
        "bodies": bodies,
        "buildSeconds": time.perf_counter() - start,
        "bytes": sum(p.stat().st_size for p in path.rglob("*") if p.is_file()),
    }


def tokenize(text):
    return list(dict.fromkeys(re.findall(r"[^\W_]+", text.casefold())))


def scoped(query, scope):
    if scope is None:
        return query
    return tantivy.Query.boolean_query(
        [
            (tantivy.Occur.Must, query),
            (tantivy.Occur.Must, tantivy.Query.const_score_query(scope, 0.0)),
        ]
    )


def rank(
    index,
    searcher,
    text,
    boosts,
    recent_slots=0,
    coverage=False,
    same_field=False,
    recency=0,
    scope=None,
    bonus=None,
):
    tokens = tokenize(text)
    if not tokens:
        return []
    expression = " ".join(f'"{t}"' for t in tokens)
    query = index.parse_query(expression, FIELDS, dict(zip(FIELDS, boosts)))
    if coverage and len(tokens) > 1:
        terms = [
            (tantivy.Occur.Should, index.parse_query(f'"{token}"', FIELDS, dict(zip(FIELDS, boosts))))
            for token in tokens
        ]
        overlap = tantivy.Query.boolean_query(terms, minimum_number_should_match=math.ceil(0.75 * len(terms)))
        query = tantivy.Query.boolean_query([(tantivy.Occur.Should, query), (tantivy.Occur.Should, overlap)])
    if same_field and len(tokens) > 1:
        clauses = [(tantivy.Occur.Should, query)]
        # A remembered subject or snippet is stronger than the same words scattered through a message.
        for field in ("subject", "snippet", "sender"):
            together = index.parse_query(expression, [field], conjunction_by_default=True)
            clauses.append((tantivy.Occur.Should, together))
        query = tantivy.Query.boolean_query(clauses)
    if bonus is not None:
        query = tantivy.Query.boolean_query([(tantivy.Occur.Must, query), (tantivy.Occur.Should, bonus)])
    hits = searcher.search(scoped(query, scope), limit=200, count=False).hits
    addresses = [address for _, address in hits]
    threads = searcher.fast_field_values("thread", addresses)
    dates = searcher.fast_field_values("date", addresses)
    newest = max(dates, default=0)
    scored = []
    for (score, _), date, pk in zip(hits, dates, threads):
        if recency:
            days = (newest - date) / 86_400_000
            score *= 1 + recency / (1 + days / 90)
        scored.append((-score, -date, pk))
    ranked = list(dict.fromkeys(pk for _, _, pk in sorted(scored)))
    if recent_slots:
        strict = index.parse_query(expression, FIELDS, conjunction_by_default=True)
        recent = searcher.search(scoped(strict, scope), limit=50, count=False, order_by_field="date").hits
        recent_ids = searcher.fast_field_values("thread", [address for _, address in recent])
        newest = list(dict.fromkeys(recent_ids))[:recent_slots]
        ranked = list(dict.fromkeys(ranked[:1] + newest + ranked[1:]))
    return ranked[:50]


def rank_completed_query(index, searcher, text, scope=None, bonus=None):
    if len(tokenize(text)) <= 2:
        return rank(
            index,
            searcher,
            text,
            (2, 1, 1, 1, 1),
            coverage=True,
            same_field=True,
            recency=0.5,
            scope=scope,
            bonus=bonus,
        )
    return rank(index, searcher, text, (1, 1, 1, 1, 1), coverage=True, scope=scope, bonus=bonus)
