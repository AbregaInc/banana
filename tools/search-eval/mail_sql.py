"""Unscoped production Mail SQL for offline paired replays."""
import hashlib
import platform
import re
import sqlite3
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parents[2]
path = "Banana/Model/Mail/MailLocalSearch.swift"
source = (root / path).read_text()
base = subprocess.check_output(["git", "show", "f987bd34:" + path], cwd=root, text=True)


def block(text, anchor):
    return text.split(anchor, 1)[1].split('"""', 2)[1]


def expand(sql, **parts):
    for key, value in parts.items():
        sql = sql.replace("\\(" + key + ")", value)
    if "\\(" in sql:
        raise ValueError("Unexpected Swift SQL interpolation")
    return sql


old_from = "mail_header_search JOIN message m ON m.msg_pk=mail_header_search.rowid JOIN thread t ON t.thread_pk=m.thread_pk JOIN account a ON a.account_pk=t.account_pk"
before = expand(block(base, 'return try Row.fetchAll(db, sql:'), **{
    "from": old_from, 'predicates.joined(separator: " AND ")': "t.last_date > 0 AND mail_header_search MATCH ?"})
after = expand(block(source, 'return try Row.fetchAll(db, sql:'), **{
    "from": old_from, 'predicates.joined(separator: " AND ")': "t.last_date > 0 AND mail_header_search MATCH ?"})


def query(db, candidate, words, limit):
    return db.execute(after if candidate else before, [words, limit]).fetchall(), "full"


body_source = (root / "Banana/Model/Mail/MailBodySearch.swift").read_text()
body_scan = int(re.search(r"static let bodyScan = (\d+)", body_source)[1])
body_sql = expand(block(body_source, "let rows = try Int64.fetchCursor"), **{
    "MailStores.attachedIndexName": "idx", 'predicates.joined(separator: " AND ")': "msg_fts MATCH ? AND t.last_date > 0"})
projection = block(body_source.split("if !missing.isEmpty {")[1], "try Row.fetchAll").split("IN (")[0]


def merge(index, body, headers, words, limit, candidate):
    cursor = body.execute(body_sql, (words, body_scan))
    if candidate:
        seen = {}
        scanned = 0
        for (pk,) in cursor:
            scanned += 1
            seen[pk] = None
            if len(seen) > limit:
                break
        ids = list(seen)
    else:
        matches = cursor.fetchall()
        scanned = len(matches)
        ids = list(dict.fromkeys(row[0] for row in matches))
    cursor.close()
    known = {row[0] for row in headers}
    missing = [pk for pk in ids[:limit] if pk not in known]
    rows = list(headers)
    if missing:
        sql = projection + "IN (" + ",".join("?" for _ in missing) + ")"
        rows.extend(index.execute(sql, missing).fetchall())
    rows.sort(key=lambda row: (row[3], row[4]), reverse=True)
    more = len(headers) == limit or scanned == body_scan or len(ids) > limit or len(rows) > limit
    return rows[:limit], more


def query_words(text):
    # The public task titles are plain free text. Banana quotes each alphanumeric token
    # and joins their prefixes with AND. Structured filter tasks use the native test suite.
    return " AND ".join(f'"{token}"*' for token in re.findall(r"[^\W_]+", text, re.UNICODE))


def lexical_threads(index, body, words):
    """Offline experiment using the first 50 message hits from each existing FTS index."""
    headers = index.execute("""
        SELECT m.thread_pk FROM mail_header_search
        JOIN message m ON m.msg_pk=mail_header_search.rowid
        JOIN thread t ON t.thread_pk=m.thread_pk
        WHERE mail_header_search MATCH ? AND t.last_date>0 ORDER BY rank LIMIT 50
    """, (words,))
    bodies = body.execute("""
        SELECT m.thread_pk FROM msg_fts f JOIN body_doc d ON d.rowid=f.rowid
        JOIN idx.message m ON m.msg_pk=d.msg_pk AND m.fts_state=2
        JOIN idx.thread t ON t.thread_pk=m.thread_pk
        WHERE msg_fts MATCH ? AND t.last_date>0 ORDER BY rank LIMIT 50
    """, (words,))
    scores = {}
    for stream in (headers, bodies):
        conversations = dict.fromkeys(pk for (pk,) in stream)
        for position, pk in enumerate(conversations, 1):
            scores[pk] = scores.get(pk, 0) + 1 / (60 + position)
    return sorted(scores, key=lambda pk: (-scores[pk], pk))[:50]

def environment():
    files = [path, "Banana/Model/Mail/MailBodySearch.swift", "tools/search-eval/mail_sql.py"]
    return dict(referenceRevision="f987bd34", sqlite=sqlite3.sqlite_version,
                python=platform.python_version(), system=platform.system(), machine=platform.machine(),
                sourceSHA256={name:hashlib.sha256((root/name).read_bytes()).hexdigest() for name in files})
