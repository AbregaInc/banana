#!/usr/bin/env python3
"""Serve a private native mail replay and save review flags on loopback."""
import argparse
from contextlib import closing
from datetime import datetime
from email.utils import parseaddr
from hashlib import sha256
import html
from http.server import ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import runpy
import sqlite3
import zlib
from urllib.parse import urlparse

from serve import Handler, HERE, ROOT

FRAME_POLICY = "default-src 'none'; style-src 'unsafe-inline'; form-action 'none'; base-uri 'none'; frame-ancestors 'self'"
PAGE_POLICY = "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; frame-src 'self'; form-action 'none'; base-uri 'none'; frame-ancestors 'none'"
BODY_STYLE = """
body{margin:0;padding:16px;font:16px/1.5 system-ui,sans-serif;color:#21262b;background:white;overflow-wrap:anywhere}
p,blockquote,pre,ul,ol{margin:0 0 .7em}blockquote{border-inline-start:2px solid #b8c2ca;padding-inline-start:.75em}
h2,h3{font-size:1em;margin:0 0 .35em}pre{white-space:pre-wrap}
li{margin-block:.35em}.action{color:#175380;text-decoration:underline}
.data{overflow-x:auto;margin-block:.65em}td,th{text-align:start;padding:.25em .55em}
small{color:#55616a}code{font-family:monospace}
"""
DATE_IN_SUBJECT = re.compile(
    r"\b(?:(?:Mon(?:day)?|Tue(?:sday)?|Wed(?:nesday)?|Thu(?:rsday)?|Fri(?:day)?|Sat(?:urday)?|Sun(?:day)?)[,.]?\s+)?"
    r"\d{1,4}[-/]\d{1,2}(?:[-/]\d{1,4})?\b", re.I
)


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def local_metadata(database, keys):
    if not database.is_file():
        return {}
    codec = runpy.run_path(str(HERE / "screen-archive.py"))
    results = {}
    with closing(sqlite3.connect(database.resolve().as_uri() + "?mode=ro", uri=True, timeout=3)) as db:
        db.execute("PRAGMA query_only=ON")
        for account, message, internal_date in db.execute("SELECT account,gmail_id,internal_date FROM content"):
            key = codec["identify"](account, message)
            if key not in keys:
                continue
            row = db.execute("SELECT headers FROM content WHERE account=? AND gmail_id=?", (account, message)).fetchone()
            subject = ""
            sender = ""
            if row:
                try:
                    headers = json.loads(codec["unzip"](row[0], codec["BLOB_LIMIT"]))
                    values = {}
                    for header in headers:
                        values.setdefault(header["name"].lower(), header["value"])
                    subject = values.get("subject", "")
                    subject = " ".join(subject.split())[:150]
                    sender = parseaddr(values.get("from", ""))[1].casefold()
                except (KeyError, TypeError, ValueError, OverflowError, zlib.error):
                    pass
            results[key] = {
                "subject": subject, "sender": sender,
                "date": datetime.fromtimestamp(internal_date / 1000).date().isoformat(),
            }
            if len(results) == len(keys):
                break
    return results


def template_for(key, meta, before, after, plain):
    subject = meta.get("subject", "")
    # Drop calendar stamps, such as "for Tue, 11/24". Keep the subject's other
    # words, the sender identity, and the actual before/after modes.
    label = DATE_IN_SUBJECT.sub(" [date] ", subject)
    label = re.sub(r"\b(?:for|on)\s+\[date\]", "", label, flags=re.I).replace("[date]", "")
    label = " ".join(label.split()).strip(" ,–-")
    sender = meta.get("sender", "")
    if not sender or len(re.findall(r"[^\W\d_]+", label)) < 2:
        return f"email-{key}", subject
    signature = json.dumps([sender, label.casefold(), before, after, plain])
    return "template-" + sha256(signature.encode()).hexdigest()[:24], label


def runs(items):
    out = []
    for item in items:
        value = html.escape(item["text"]).replace("\n", "<br>")
        style = item.get("style", 0)
        for bit, tag in ((1, "strong"), (2, "em"), (4, "u"), (8, "s"), (16, "code")):
            if style & bit:
                value = f"<{tag}>{value}</{tag}>"
        if item.get("link"):
            value = f'<span class="action">{value}</span>'
        out.append(value)
    return "".join(out)


def native_body(prepared):
    parts = []
    list_tag = None
    for block in prepared["text"]["blocks"]:
        kind, details = next(iter(block["kind"].items()))
        next_list = ("ol" if details.get("ordered") else "ul") if kind == "item" else None
        if list_tag != next_list:
            if list_tag:
                parts.append(f"</{list_tag}>")
            if next_list:
                parts.append(f"<{next_list}>")
            list_tag = next_list
        text = runs(block["runs"])
        if kind == "item":
            number = details.get("number")
            value = f' value="{number}"' if list_tag == "ol" and isinstance(number, int) else ""
            parts.append(f"<li{value}>{text}</li>")
        elif kind == "table":
            rows = []
            for row in details["_0"]["rows"]:
                cells = []
                for cell in row:
                    tag = "th" if cell.get("header") else "td"
                    cells.append(f"<{tag}>{runs(cell['runs'])}</{tag}>")
                rows.append("<tr>" + "".join(cells) + "</tr>")
            parts.append('<div class="data"><table>' + "".join(rows) + "</table></div>")
        elif kind == "picture":
            label = details["_0"].get("alt", "")
            if label:
                parts.append("<p><small>" + html.escape(label) + "</small></p>")
        elif kind == "rule":
            parts.append("<hr>")
        else:
            tag = {"heading": "h2", "quote": "blockquote", "preformatted": "pre", "fineprint": "small"}.get(kind, "p")
            parts.append(f"<{tag}>{text}</{tag}>")
    if list_tag:
        parts.append(f"</{list_tag}>")
    return "".join(parts)


def formatted_body(path):
    content = path.read_text(encoding="utf-8")
    # This export comes from MailOriginalDocument. Keep authored styles but disable navigation.
    return re.sub(r'(<a\b[^>]*?)\bhref="[^"]*"', r'\1href="#review-link"', content, flags=re.I)


def document(content):
    return f'<!doctype html><html lang="en"><meta charset="utf-8"><style>{BODY_STYLE}</style><body>{content}</body></html>'


class Flags:
    def __init__(self, path):
        path.parent.mkdir(parents=True, exist_ok=True)
        os.close(os.open(path, os.O_WRONLY | os.O_CREAT, 0o600))
        self.path = path
        with closing(sqlite3.connect(self.path)) as db, db:
            db.execute("""
                CREATE TABLE IF NOT EXISTS issue (
                    replay TEXT NOT NULL, email_id TEXT NOT NULL,
                    side TEXT NOT NULL, note TEXT NOT NULL,
                    PRIMARY KEY (replay, email_id)
                )
            """)

    def read(self, replay):
        with closing(sqlite3.connect(self.path)) as db:
            return {key: {"side": side, "note": note} for key, side, note in db.execute(
                "SELECT email_id, side, note FROM issue WHERE replay = ?", (replay,)
            )}

    def save(self, replay, key, flag):
        with closing(sqlite3.connect(self.path)) as db, db:
            if flag is None:
                db.execute("DELETE FROM issue WHERE replay = ? AND email_id = ?", (replay, key))
            else:
                db.execute("""
                    INSERT INTO issue (replay, email_id, side, note) VALUES (?, ?, ?, ?)
                    ON CONFLICT (replay, email_id) DO UPDATE SET side = excluded.side, note = excluded.note
                """, (replay, key, flag["side"], flag["note"]))


class ArchiveServer(ThreadingHTTPServer):
    def __init__(self, port, before, after, inputs, database, flags, tailscale_host=None, tailscale_login=None,
                 *, previous_after=None, flagged_only=False):
        left = {row["name"]: row for row in read_json(before / "observations.json")}
        right = {row["name"]: row for row in read_json(after / "observations.json")}
        reported = {row["name"]: row for row in read_json(previous_after / "observations.json")} if previous_after else right
        self.replay = json.dumps([sorted({row["version"] for row in side.values()}) for side in (left, reported)])
        self.previous_after = previous_after
        self.flagged_only = flagged_only
        self.flags = Flags(flags)
        if flagged_only:
            keys = self.flags.read(self.replay).keys()
            if any(not keys <= replay.keys() for replay in (left, right, reported)):
                raise ValueError("A flagged email is missing from the replay results.")
        else:
            if not left or not left.keys() == right.keys() == reported.keys():
                raise ValueError("Replay results must contain the same email IDs.")
            keys = left.keys()
        self.cases = {}
        metadata = local_metadata(database, keys) if keys else {}
        ordered = sorted(keys, key=lambda key: (metadata.get(key, {}).get("date", ""), key), reverse=True)
        for number, key in enumerate(ordered, start=1):
            if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", key):
                raise ValueError("Invalid replay ID.")
            old = read_json(before / f"{key}-native.json")
            new = read_json(after / f"{key}-native.json")
            if old["version"] != left[key]["version"] or new["version"] != right[key]["version"]:
                raise ValueError("Replay observation disagrees with the prepared version.")
            meta = metadata.get(key, {})
            before_formatted, after_formatted = left[key]["formatted"], right[key]["formatted"]
            plain = (inputs / key / "input.txt").is_file()
            group, group_title = template_for(key, meta, before_formatted, after_formatted, plain)
            self.cases[key] = {
                "id": key, "number": number, "before": before_formatted, "after": after_formatted,
                "reported": reported[key]["formatted"],
                "plain": plain, "subject": meta.get("subject", ""), "date": meta.get("date", ""),
                "group": group, "groupTitle": group_title,
            }
        self.before, self.after, self.inputs = before, after, inputs
        self.quiet = True
        super().__init__(("127.0.0.1", port), ArchiveHandler)
        self.host = tailscale_host or f"127.0.0.1:{self.server_port}"
        self.tailscale_login = tailscale_login

    def body(self, key, side):
        if side == "plain":
            file = self.inputs / key / "input.txt"
            if not file.is_file():
                return document("<p>The sender didn’t include a plain-text part.</p>")
            return document("<pre>" + html.escape(file.read_text(encoding="utf-8", errors="replace")) + "</pre>")
        folder = {"before": self.before, "after": self.after, "reported": self.previous_after}[side]
        if self.cases[key][side]:
            return formatted_body(folder / f"{key}-formatted.html")
        return document(native_body(read_json(folder / f"{key}-native.json")))


class ArchiveHandler(Handler):
    def allowed(self):
        if self.headers.get("Host") != self.server.host:
            self.json(403, {"error": "Open the configured review address."})
            return False
        if self.server.tailscale_login is not None and self.headers.get("Tailscale-User-Login") != self.server.tailscale_login:
            self.json(403, {"error": "Connect with the Tailscale account that owns this archive."})
            return False
        return True

    def do_GET(self):
        if not self.allowed():
            return
        path = urlparse(self.path).path
        if path == "/":
            return self.respond(200, (HERE / "archive-view.html").read_bytes(), "text/html", PAGE_POLICY)
        if path == "/api/archive":
            try:
                flags = self.server.flags.read(self.server.replay)
            except sqlite3.Error:
                return self.json(503, {"error": "Couldn’t load issue flags. Reload to try again."})
            return self.json(200, {
                "flaggedOnly": self.server.flagged_only,
                "hasReported": self.server.previous_after is not None,
                "cases": [{**case, "issue": flags.get(key)} for key, case in self.server.cases.items()
                          if not self.server.flagged_only or key in flags],
            })
        matched = re.fullmatch(r"/body/([a-z0-9-]+)/(before|after|plain|reported)", path)
        if matched and matched[1] in self.server.cases:
            if matched[2] == "reported" and self.server.previous_after is None:
                return self.json(404, {"error": "Preview unavailable."})
            if self.server.flagged_only and matched[1] not in self.server.flags.read(self.server.replay):
                return self.json(404, {"error": "Preview unavailable."})
            body = self.server.body(*matched.groups())
            return self.respond(200, body.encode(), "text/html", FRAME_POLICY)
        self.json(404, {"error": "Preview unavailable."})

    def do_POST(self):
        if not self.allowed():
            return
        if self.path != "/api/archive/flag":
            return self.json(404, {"error": "Preview unavailable."})
        if self.headers.get("Origin") != f"http://{self.server.host}" or self.headers.get_content_type() != "application/json":
            return self.json(403, {"error": "Save flags from the review viewer."})
        try:
            length = int(self.headers.get("Content-Length", 0))
            if not 0 < length <= 16384:
                raise ValueError("Invalid issue size.")
            request = json.loads(self.rfile.read(length))
            if not isinstance(request, dict) or not isinstance(request.get("id"), str) or "issue" not in request:
                raise ValueError("Invalid issue.")
            key, issue = request["id"], request["issue"]
            case = self.server.cases.get(key)
            if not case:
                raise ValueError("Email unavailable.")
            if issue is not None:
                if not isinstance(issue, dict) or issue.get("side") not in ("before", "after", "plain"):
                    raise ValueError("Choose the preview that has the issue.")
                if issue["side"] == "plain" and not case["plain"]:
                    raise ValueError("This email has no plain-text part.")
                if not isinstance(issue.get("note"), str) or len(issue["note"]) > 2000:
                    raise ValueError("Keep the note under 2,000 characters.")
                issue = {"side": issue["side"], "note": issue["note"].strip()}
            self.server.flags.save(self.server.replay, key, issue)
        except (ValueError, UnicodeError) as error:
            return self.json(400, {"error": str(error)})
        except sqlite3.Error:
            return self.json(503, {"error": "Couldn’t save the flag. Try again."})
        self.json(200, {"issue": issue})


def main():
    root = ROOT / "private/mail-review"
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8769)
    parser.add_argument("--before", type=Path, default=root / "archive-replay-cohort-before/snapshots")
    parser.add_argument("--after", type=Path, default=root / "archive-replay-cohort-after/snapshots")
    parser.add_argument("--previous-after", type=Path, help="Earlier replay that the saved flags refer to")
    parser.add_argument("--flagged-only", action="store_true", help="Serve only emails with saved feedback")
    parser.add_argument("--inputs", type=Path, default=root / "archive-panel-cohort")
    parser.add_argument("--flags", type=Path, default=root / "archive-flags.sqlite")
    parser.add_argument("--database", type=Path,
                        default=Path.home() / "Library/Application Support/Banana Beta/BananaMail/Cache/blobs.sqlite",
                        help="Optional local cache for subjects and dates")
    parser.add_argument("--tailscale-host", help="Public-facing host and port of the private Tailscale Serve proxy")
    parser.add_argument("--tailscale-login-file", type=Path, help="File containing the one authorized Tailscale login")
    args = parser.parse_args()
    if bool(args.tailscale_host) != bool(args.tailscale_login_file):
        parser.error("Set both Tailscale proxy options, or neither for loopback access.")
    login = None
    if args.tailscale_login_file:
        login = args.tailscale_login_file.read_text(encoding="utf-8").strip()
        if not login:
            parser.error("The allowed login file is empty.")
    with ArchiveServer(args.port, args.before, args.after, args.inputs, args.database, args.flags,
                       args.tailscale_host, login, previous_after=args.previous_after, flagged_only=args.flagged_only) as server:
        print(f"Listening on 127.0.0.1:{server.server_port}", flush=True)
        server.serve_forever()


if __name__ == "__main__":
    main()
