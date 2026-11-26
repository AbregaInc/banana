"""Offline ranking experiment for complete, unscoped Mail queries."""

import re

HEADER = """
    SELECT m.thread_pk, -rank, t.last_date FROM mail_header_search
    JOIN message m ON m.msg_pk=mail_header_search.rowid
    JOIN thread t ON t.thread_pk=m.thread_pk
    WHERE mail_header_search MATCH ? AND rank MATCH 'bm25(4,1,2,1)' AND t.last_date>0
    ORDER BY rank LIMIT 100
"""
BODY = """
    SELECT m.thread_pk, -rank, t.last_date FROM msg_fts
    JOIN body_doc d ON d.rowid=msg_fts.rowid
    JOIN idx.message m ON m.msg_pk=d.msg_pk AND m.fts_state=2
    JOIN idx.thread t ON t.thread_pk=m.thread_pk
    WHERE msg_fts MATCH ? AND t.last_date>0 ORDER BY rank LIMIT 100
"""


def ranked_streams(index, body, text):
    terms = list(dict.fromkeys(re.findall(r"[^\W_]+", text.casefold())))
    if not terms:
        return [], []
    expression = " OR ".join(f'"{word}"' for word in terms)
    return list(index.execute(HEADER, (expression,))), list(body.execute(BODY, (expression,)))


def combine(streams, body_weight):
    # Repeated matches in a long conversation must not accumulate unbounded evidence.
    scores, dates = {}, {}
    for rows, weight in zip(streams, (1, body_weight)):
        best = {}
        for pk, score, date in rows:
            best[pk] = max(best.get(pk, 0), score)
            dates[pk] = date
        for pk, score in best.items():
            scores[pk] = scores.get(pk, 0) + score * weight
    return sorted(scores, key=lambda pk: (-scores[pk], -dates[pk], pk))[:50]


def prepare_vocabulary(index, body):
    for db, table in ((index, "mail_header_search"), (body, "msg_fts")):
        db.execute(f"CREATE VIRTUAL TABLE temp.frequency USING fts5vocab(main,{table},row)")


def anchored_streams(index, body, text, anchor_limit=2):
    terms = list(dict.fromkeys(re.findall(r"[^\W_]+", text.casefold())))
    if not terms:
        return [], []
    streams = []
    for db, sql in ((index, HEADER), (body, BODY)):
        if len(terms) <= 1:
            expression = f'"{terms[0]}"'
        else:
            placeholders = ",".join("?" for _ in terms)
            hits = db.execute(f"SELECT term,doc FROM frequency WHERE term IN ({placeholders})", terms)
            ordered = sorted(hits, key=lambda row: (row[1], row[0]))
            if not ordered:
                streams.append([])
                continue
            # Only a rare term admits a candidate; all present terms still score it.
            words = [f'"{word}"' for word, _ in ordered]
            anchors = words[:anchor_limit]
            expression = " OR ".join(words)
            if len(anchors) < len(words):
                expression = "(" + " OR ".join(anchors) + ") AND (" + expression + ")"
        streams.append(list(db.execute(sql, (expression,))))
    return streams
