"""Read the UMD W3C collection into the Mail fields used by the public replay."""

import datetime as dt
import email.utils
import html
import re
import tarfile
from pathlib import Path


def read_message(raw):
    text = raw.decode("utf-8", errors="replace").splitlines()
    fields = {}
    recipients = []
    pos = 0
    while pos < len(text):
        line = text[pos].strip()
        m = re.fullmatch(r'([\w-]+)="(.*)"', line)
        if m:
            fields[m[1].lower()] = html.unescape(m[2])
        elif line.lower().startswith(("to:", "cc:")):
            recipients.append(line.split(":", 1)[1])
        elif line:
            break
        pos += 1
    stamp = 0
    for field in ("isosent", "isoreceived", "sent", "received"):
        try:
            date = (
                dt.datetime.strptime(fields[field], "%Y%m%d%H%M%S").replace(tzinfo=dt.UTC)
                if field.startswith("iso")
                else email.utils.parsedate_to_datetime(fields[field])
            )
            if date.tzinfo is None:
                date = date.replace(tzinfo=dt.UTC)
            stamp = int(date.timestamp() * 1000)
            if 0 < stamp < (1 << 43):
                break
            stamp = 0
        except (ValueError, TypeError, KeyError, OverflowError, OSError):
            continue
    return fields, stamp, " ".join(recipients), "\n".join(text[pos:])


def build_fixture(collection, index, body, single_character_index=False, ranked_blobs=None):
    # One discussion message per result gives the same unit of relevance as the official qrels.
    # The public archive has no Gmail conversation IDs or provider snippets.
    header_option = ",prefix='1'" if single_character_index else ""
    body_prefixes = "1 2 3" if single_character_index else "2 3"
    index.executescript(f"""
      CREATE TABLE account(account_pk INTEGER PRIMARY KEY,email TEXT);
      INSERT INTO account VALUES(1,'archive@plan.example');
      CREATE TABLE thread(thread_pk INTEGER PRIMARY KEY, account_pk INTEGER, gmail_id TEXT UNIQUE,
        last_date INTEGER, tie INTEGER, unread_count DEFAULT 0, message_count DEFAULT 1, flags DEFAULT 0,
        subject TEXT, snippet TEXT, people DEFAULT '[]', people_total DEFAULT 0, labels DEFAULT '',
        wake_at, returned_at, waiting_until, pending DEFAULT 0, recipients DEFAULT '[]', recipients_total DEFAULT 0, arrival_seq DEFAULT 0);
      CREATE TABLE message(msg_pk INTEGER PRIMARY KEY,thread_pk INTEGER,fts_state INTEGER);
      CREATE INDEX message_by_thread ON message(thread_pk);
      CREATE VIRTUAL TABLE mail_header_search USING fts5(subject,snippet,sender,recipients,tokenize='unicode61 remove_diacritics 2'{header_option});
    """)
    body.executescript(f"""
      CREATE TABLE body_doc(rowid INTEGER PRIMARY KEY,msg_pk INTEGER);
      CREATE INDEX body_doc_by_message ON body_doc(msg_pk);
      CREATE VIRTUAL TABLE msg_fts USING fts5(body,content='',tokenize='unicode61 remove_diacritics 2',prefix='{body_prefixes}');
    """)
    if ranked_blobs is not None:
        import zlib

        ranked_blobs.executescript("""
            CREATE TABLE prepared(account TEXT,gmail_id TEXT,text BLOB, PRIMARY KEY(account,gmail_id)) WITHOUT ROWID;
            CREATE TABLE content(account TEXT,gmail_id TEXT,structure BLOB,PRIMARY KEY(account,gmail_id));
            CREATE TABLE attachment(account TEXT,gmail_id TEXT,part_id TEXT,filename TEXT,inline INTEGER);
            CREATE INDEX by_message ON attachment(account,gmail_id);
        """)
        for column in [
            "account_pk INTEGER DEFAULT 1",
            "gmail_id TEXT",
            "internal_date INTEGER",
            "subject TEXT",
            "snippet TEXT",
            "from_name TEXT",
            "from_addr TEXT",
            "recipients TEXT",
        ]:
            index.execute("ALTER TABLE message ADD COLUMN " + column)
    counts = dict(documents=0, missingDate=0, duplicateDocumentID=0, bodyDocuments=0)
    for number in range(1, 4):
        with tarfile.open(collection / f"part{number}.tar.gz", "r|gz") as archive:
            for member in archive:
                if not member.isfile() or not re.fullmatch(r"lists-\d+-\d+\.txt", Path(member.name).name):
                    continue
                fields, stamp, recipients, text = read_message(archive.extractfile(member).read())
                key = counts["documents"] + 1
                docno = Path(member.name).stem
                subject = fields.get("subject", "")
                snippet = " ".join(text[:256].split())[:160]
                inserted = index.execute(
                    "INSERT OR IGNORE INTO thread(thread_pk,account_pk,gmail_id,last_date,tie,subject,snippet) VALUES (?,1,?,?,?,?,?)",
                    [key, docno, stamp, key, subject, snippet],
                ).rowcount
                if not inserted:
                    counts["duplicateDocumentID"] += 1
                    continue
                counts["documents"] += 1
                counts["missingDate"] += int(stamp <= 0)
                sender = fields.get("name", "") + " " + fields.get("email", "")
                index.execute("INSERT INTO message(msg_pk,thread_pk,fts_state) VALUES (?,?,2)", [key, key])
                index.execute(
                    "INSERT INTO mail_header_search(rowid,subject,snippet,sender,recipients) VALUES(?,?,?,?,?)",
                    [key, subject, snippet, sender, recipients],
                )
                if ranked_blobs is not None:
                    index.execute(
                        "UPDATE message SET gmail_id=?,internal_date=? WHERE msg_pk=?", [docno, stamp, key]
                    )
                    plain = text[:16000].encode()
                    if plain:
                        compressor = zlib.compressobj(level=1, wbits=-15)
                        packed = (
                            b"MBZ1"
                            + len(plain).to_bytes(4, "big")
                            + compressor.compress(plain)
                            + compressor.flush()
                        )
                        ranked_blobs.execute(
                            "INSERT INTO prepared VALUES('archive@plan.example',?,?)", [docno, packed]
                        )
                if text:
                    rowid = max(0, stamp) << 20 | key
                    body.execute("INSERT INTO body_doc VALUES(?,?)", [rowid, key])
                    body.execute("INSERT INTO msg_fts(rowid,body) VALUES(?,?)", [rowid, text[:16000]])
                    counts["bodyDocuments"] += 1
        print("Loaded archive", number, counts["documents"], flush=True)
    index.commit()
    body.commit()
    if ranked_blobs is not None:
        ranked_blobs.commit()
    return counts


if __name__ == "__main__":
    import argparse
    import json
    import sqlite3
    from contextlib import closing

    parser = argparse.ArgumentParser(
        description="Prepare a disposable W3C fixture for the native Mail replay."
    )
    parser.add_argument("--collection", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument(
        "--ranked", action="store_true", help="Also retain normalized body passages for the integrated ranker"
    )
    args = parser.parse_args()
    args.out.mkdir(exist_ok=False)
    cache = args.out / "Cache"
    cache.mkdir()
    with (
        closing(sqlite3.connect(cache / "index.sqlite")) as writer,
        closing(sqlite3.connect(cache / "search.sqlite")) as bodies,
    ):
        if args.ranked:
            with closing(sqlite3.connect(cache / "blobs.sqlite")) as blobs:
                build_fixture(args.collection, writer, bodies, ranked_blobs=blobs)
        else:
            build_fixture(args.collection, writer, bodies)
    topics = dict(
        re.findall(
            r"<num>\s*Number:\s*(KI\d+)\s*</num>\s*<title>\s*(.*?)\s*</title>",
            (args.collection / "topics").read_text(),
            re.DOTALL,
        )
    )
    tasks = []
    for split, filename in [("development", "training-qrels"), ("test", "qrels")]:
        for line in (args.collection / filename).read_text().splitlines():
            topic, _, key, _ = line.split()
            tasks.append(dict(id=topic, split=split, query=topics[topic], target=key))
    if args.ranked:
        (args.out / "public-replay").touch()
        tasks = [dict(family=t["split"], query=t["query"], targets=[t["target"]]) for t in tasks]
    (args.out / "tasks.json").write_text(json.dumps(tasks))
