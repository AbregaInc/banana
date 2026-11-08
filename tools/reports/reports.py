#!/usr/bin/env python3
"""Problem reports: from the service to a case on this Mac (docs/design/PROBLEM-REPORTS.md).

    tools/reports/reports.py list                 new reports (not pulled yet), newest first
    tools/reports/reports.py list --all --limit 50
    tools/reports/reports.py pull [ID ...]        every new report, or these, into private/reports/<id>/
    tools/reports/reports.py spikes [--days 14]   automatic reports grouped by detector and signature
    tools/reports/reports.py mail-case ID [NAME]  a pulled mail report -> private/mail-render-corpus/NAME/
    tools/reports/reports.py anonymise CASE NAME  a private mail case -> tools/reports/mail-cases/NAME/
    tools/reports/reports.py ai-case ID           a pulled 👎 -> private/ai-evals/<id>.json

Reads the service through wrangler with your own Cloudflare login (`npx wrangler login`): D1 for
the rows, R2 for the files. `--env beta` (the default) or `--env production`. Nothing pulled ever
enters the tree: private/ is ignored and the pre-push guard refuses a tracked file under it. Only
`anonymise` writes into the tree, after replacing every word, address and link, and it runs
tools/private-text-check.sh on what it wrote.
"""
import argparse
import hashlib
import html
import html.parser
import json
import re
import subprocess
import sys
import time
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SERVICE = ROOT / "Service"
PRIVATE = ROOT / "private"
PULLED = PRIVATE / "reports"
CORPUS = PRIVATE / "mail-render-corpus"
EVALS = PRIVATE / "ai-evals"
PUBLIC_CASES = ROOT / "tools/reports/mail-cases"
ENVS = {"beta": ("banana-service-beta", "banana-blobs-beta", ["--env", "beta"]),
        "production": ("banana-service", "banana-blobs", [])}
FILES = {"screenshot": "screenshot.jpg", "log": "log.txt", "stack": "stack.txt", "mail-html": "mail.html",
         "mail-prepared": "mail-prepared.json", "mail-plain": "mail.txt", "ai": "ai.json", "metrickit": "metrickit.json"}
ID = re.compile(r"^[A-Za-z0-9-]{8,64}$")


def wrangler(env, *args, capture=True):
    _, _, flags = ENVS[env]
    command = ["npx", "--yes", "wrangler", *args, *flags]
    result = subprocess.run(command, cwd=SERVICE, capture_output=capture, text=True)
    if result.returncode != 0:
        sys.exit(f"wrangler failed: {' '.join(args[:3])}\n{result.stderr[-2000:] if capture else ''}")
    return result.stdout


def query(env, sql):
    database, _, _ = ENVS[env]
    out = wrangler(env, "d1", "execute", database, "--remote", "--json", "--command", sql)
    data = json.loads(out[out.index("["):])
    return data[0].get("results", []) if data else []


def when(ms):
    return datetime.fromtimestamp(int(ms) / 1000, timezone.utc).strftime("%Y-%m-%d %H:%M")


def quote(value):
    return "'" + str(value).replace("'", "''") + "'"


# ---- list / pull ----

def cmd_list(a):
    where = "" if a.all else "WHERE pulled_at IS NULL"
    rows = query(a.env, f"""SELECT id, received_at, kind, detector, signature, rating, platform, variant, version, page,
                                   substr(COALESCE(note, ''), 1, 60) AS note FROM problem_reports {where}
                            ORDER BY received_at DESC LIMIT {int(a.limit)}""")
    for r in rows:
        what = r["detector"] or r["rating"] or "report"
        print(f"{r['id']}  {when(r['received_at'])}  {r['kind']:<7} {what:<15} {r['platform']}/{r['variant']} {r['version']:<10} "
              f"{r['page']:<9} {(r['signature'] or r['note'] or '')[:60]}")
    if not rows:
        print("Nothing new." if not a.all else "No reports.")


def cmd_pull(a):
    _, bucket, _ = ENVS[a.env]
    ids = a.ids or [r["id"] for r in query(a.env, "SELECT id FROM problem_reports WHERE pulled_at IS NULL ORDER BY received_at")]
    for report in ids:
        if not ID.match(report):
            sys.exit(f"not a report id: {report}")
        rows = query(a.env, f"SELECT * FROM problem_reports WHERE id = {quote(report)}")
        if not rows:
            print(f"{report}: not on the service")
            continue
        row = rows[0]
        for key in ("numbers", "context", "attachments"):
            row[key] = json.loads(row[key] or "{}")
        folder = PULLED / report
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "report.json").write_text(json.dumps(row, indent=2, ensure_ascii=False) + "\n")
        for attachment in row["attachments"]:
            name = attachment["name"]
            target = folder / FILES.get(name, name)
            wrangler(a.env, "r2", "object", "get", f"{bucket}/reports/{report}/{name}", "--remote", "--file", str(target))
        query(a.env, f"UPDATE problem_reports SET pulled_at = {int(time.time() * 1000)} WHERE id = {quote(report)}")
        print(f"{report}: {row['kind']} {row.get('detector') or ''} -> {folder.relative_to(ROOT)}")


# ---- spikes ----

def cmd_spikes(a):
    since = int((time.time() - a.days * 86400) * 1000)
    rows = query(a.env, f"""SELECT detector, COALESCE(signature, '') AS signature, COUNT(*) AS n,
                                   MIN(received_at) AS first, MAX(received_at) AS last,
                                   GROUP_CONCAT(DISTINCT version) AS versions, GROUP_CONCAT(DISTINCT platform) AS platforms,
                                   MAX(id) AS example
                            FROM problem_reports WHERE kind = 'spike' AND received_at >= {since}
                            GROUP BY detector, signature ORDER BY n DESC LIMIT 100""")
    if not rows:
        return print(f"No spikes in {a.days} days.")
    by = defaultdict(list)
    for r in rows:
        by[r["detector"]].append(r)
    for detector, group in sorted(by.items(), key=lambda kv: -sum(r["n"] for r in kv[1])):
        print(f"\n{detector}  ({sum(r['n'] for r in group)})")
        for r in group:
            print(f"  {r['n']:>4}  {r['signature'][:70]:<70}  {when(r['first'])} … {when(r['last'])}  "
                  f"{r['versions']}  {r['platforms']}  e.g. {r['example']}")


# ---- mail ----

def pulled(report):
    folder = PULLED / report
    if not (folder / "report.json").exists():
        sys.exit(f"{report} isn't pulled: tools/reports/reports.py pull {report}")
    return folder, json.loads((folder / "report.json").read_text())


def cmd_mail_case(a):
    folder, row = pulled(a.id)
    if not (folder / "mail.html").exists():
        sys.exit(f"{a.id} carries no message HTML (Email was off, or the message had none).")
    name = a.name or f"report-{a.id[:8].lower()}"
    case = CORPUS / name
    case.mkdir(parents=True, exist_ok=True)
    (case / "input.html").write_bytes((folder / "mail.html").read_bytes())
    if (folder / "mail.txt").exists():
        (case / "input.txt").write_bytes((folder / "mail.txt").read_bytes())
    if (folder / "mail-prepared.json").exists():
        (case / "reported-prepared.json").write_bytes((folder / "mail-prepared.json").read_bytes())
    if (folder / "screenshot.jpg").exists():
        (case / "reported-screenshot.jpg").write_bytes((folder / "screenshot.jpg").read_bytes())
    expect = case / "expect.json"
    if not expect.exists():
        expect.write_text(json.dumps({
            "source": f"report {a.id}", "version": row["version"], "note": row.get("note") or "",
            "preparerVersion": row["context"].get("preparerVersion"),
            "contains": [], "absent": [],
        }, indent=2, ensure_ascii=False) + "\n")
    print(f"{case.relative_to(ROOT)}: write what should and shouldn't show in expect.json, fix, then run "
          "MailRenderCorpusTests (it reads private/ when it is there).")


WORD = re.compile(r"[^\W\d_]+|\d+", re.UNICODE)
FILLER = ("plan week note day time list item place team book open move send read meet call walk lunch "
          "garden river stone paper window table chair music light green blue small large early later").split()


def stand_in(word):
    """The same word always becomes the same stand-in of a similar length and case."""
    if word.isdigit():
        digest = int(hashlib.sha256(word.encode()).hexdigest(), 16)
        return str(digest)[: len(word)].rjust(len(word), "4")
    digest = int(hashlib.sha256(word.lower().encode()).hexdigest(), 16)
    choices = [w for w in FILLER if abs(len(w) - len(word)) <= 1] or FILLER
    out = choices[digest % len(choices)]
    if word.isupper() and len(word) > 1:
        return out.upper()
    if word[:1].isupper():
        return out.capitalize()
    return out


def anonymise_text(text):
    text = re.sub(r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}", "noor@plan.example", text)
    text = re.sub(r"https?://\S+", "https://plan.example/link", text)
    return WORD.sub(lambda m: m.group(0) if m.group(0) in ("noor", "plan", "example", "https", "link") else stand_in(m.group(0)), text)


class Anonymiser(html.parser.HTMLParser):
    """Keeps the markup (tags, structure, style, class) and replaces what is the sender's: text,
    links, picture sources, alt and title text, comments."""
    KEEP = {"style", "class", "width", "height", "align", "valign", "bgcolor", "color", "border", "cellpadding",
            "cellspacing", "role", "dir", "colspan", "rowspan", "type", "face", "size", "lang"}

    def __init__(self):
        super().__init__(convert_charrefs=False)
        self.out = []
        self.links = 0
        self.raw = None

    def attrs(self, attrs):
        parts = []
        for key, value in attrs:
            if value is None:
                parts.append(key)
                continue
            if key in ("href",):
                if value.startswith("mailto:"):
                    value = "mailto:noor@plan.example"
                else:
                    self.links += 1
                    value = f"https://plan.example/link-{self.links}"
            elif key in ("src", "background"):
                value = "cid:picture" if value.startswith("cid:") else "https://plan.example/picture.png"
            elif key in ("alt", "title", "aria-label"):
                value = anonymise_text(value)
            elif key not in self.KEEP:
                continue
            parts.append(f'{key}="{html.escape(value, quote=True)}"')
        return (" " + " ".join(parts)) if parts else ""

    def handle_starttag(self, tag, attrs):
        self.out.append(f"<{tag}{self.attrs(attrs)}>")
        if tag in ("style", "script"):
            self.raw = tag

    def handle_startendtag(self, tag, attrs):
        self.out.append(f"<{tag}{self.attrs(attrs)} />")

    def handle_endtag(self, tag):
        self.raw = None if tag == self.raw else self.raw
        self.out.append(f"</{tag}>")

    def handle_data(self, data):
        # Style sheets stay (layout is the point), with any URL in them replaced; scripts go.
        if self.raw == "style":
            self.out.append(re.sub(r"url\([^)]*\)", "url(https://plan.example/picture.png)", data))
        elif self.raw == "script":
            pass
        else:
            self.out.append(anonymise_text(data))

    def handle_entityref(self, name):
        self.out.append(f"&{name};")

    def handle_charref(self, name):
        self.out.append(f"&#{name};")

    def handle_comment(self, data):
        pass

    def handle_decl(self, decl):
        self.out.append(f"<!{decl}>")


def cmd_anonymise(a):
    case = Path(a.case) if Path(a.case).exists() else CORPUS / a.case
    if not (case / "input.html").exists():
        sys.exit(f"no input.html in {case}")
    if not re.match(r"^[a-z0-9-]{3,60}$", a.name):
        sys.exit("name: lowercase words and dashes")
    target = PUBLIC_CASES / a.name
    if target.exists():
        sys.exit(f"{target.relative_to(ROOT)} already exists")
    parser = Anonymiser()
    parser.feed(case.joinpath("input.html").read_text(errors="replace"))
    parser.close()
    target.mkdir(parents=True)
    (target / "input.html").write_text("".join(parser.out))
    expect = json.loads((case / "expect.json").read_text()) if (case / "expect.json").exists() else {}
    public = {"source": "synthetic, anonymised from a report", "note": anonymise_text(expect.get("note", "")),
              "contains": [anonymise_text(t) for t in expect.get("contains", [])],
              "absent": [anonymise_text(t) for t in expect.get("absent", [])]}
    if "blocksAtMost" in expect:
        public["blocksAtMost"] = expect["blocksAtMost"]
    (target / "expect.json").write_text(json.dumps(public, indent=2, ensure_ascii=False) + "\n")
    check = subprocess.run([str(ROOT / "tools/private-text-check.sh"), str(target)], capture_output=True, text=True)
    if check.returncode != 0:
        print(check.stdout + check.stderr)
        sys.exit(f"{target.relative_to(ROOT)} still holds private text (or the deny list is missing): "
                 "edit it or delete it; don't commit it as it is.")
    print(f"{target.relative_to(ROOT)}: read it through before committing; MailRenderCorpusTests runs it.")


# ---- AI ----

def cmd_ai_case(a):
    folder, row = pulled(a.id)
    if not (folder / "ai.json").exists():
        sys.exit(f"{a.id} carries no answer.")
    answer = json.loads((folder / "ai.json").read_text())
    EVALS.mkdir(parents=True, exist_ok=True)
    case = EVALS / f"{a.id}.json"
    case.write_text(json.dumps({
        "id": f"report-{a.id[:8].lower()}",
        "source": f"report {a.id}", "version": row["version"], "model": answer.get("model"),
        "note": row.get("note") or "",
        "prompt": answer.get("prompt"),
        "history": answer.get("messages", [])[:-1],
        "reportedAnswer": answer.get("answer"),
        "reportedTools": [{"request": json.loads(t["request"]) if t["request"].startswith("{") else t["request"],
                           "result": t["result"][:2000]} for t in answer.get("tools", [])],
        # What a right answer does: fill in before it gates anything.
        "expected": {"tool": None, "arguments": {}, "textIncludes": "", "textExcludes": []},
    }, indent=2, ensure_ascii=False) + "\n")
    print(f"{case.relative_to(ROOT)}: fill in `expected`, then add it to the eval run "
          "(tools/pi-evaluation; real data stays in private/).")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--env", choices=ENVS, default="beta")
    sub = p.add_subparsers(dest="command", required=True)
    s = sub.add_parser("list"); s.add_argument("--all", action="store_true"); s.add_argument("--limit", type=int, default=30)
    s.set_defaults(run=cmd_list)
    s = sub.add_parser("pull"); s.add_argument("ids", nargs="*"); s.set_defaults(run=cmd_pull)
    s = sub.add_parser("spikes"); s.add_argument("--days", type=int, default=14); s.set_defaults(run=cmd_spikes)
    s = sub.add_parser("mail-case"); s.add_argument("id"); s.add_argument("name", nargs="?"); s.set_defaults(run=cmd_mail_case)
    s = sub.add_parser("anonymise"); s.add_argument("case"); s.add_argument("name"); s.set_defaults(run=cmd_anonymise)
    s = sub.add_parser("ai-case"); s.add_argument("id"); s.set_defaults(run=cmd_ai_case)
    a = p.parse_args()
    a.run(a)


if __name__ == "__main__":
    main()
