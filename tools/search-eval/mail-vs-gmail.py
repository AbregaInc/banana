"""Compare Banana's ranked Mail search with Gmail's own search on the same first queries.

Inputs (all private, outside the repository): a fixture from ranked-mail-fixture.py (`--fixture`),
the top-50 lists from RankedMailReplayTests/testTopLists (`--local`), and Gmail's listings from the
Beta app's `--mail-gmail-search` probe (`--gmail`). Writes aggregate counts only (`--out`).
Gmail is searched in the account that holds the target, as someone would in Gmail itself.
"""
import argparse, collections, json, re, sqlite3, statistics, datetime

p = argparse.ArgumentParser(description=__doc__)
for name in ("fixture", "local", "gmail", "out"):
    p.add_argument("--" + name, required=True)
p.add_argument("--as-of", default="2026-11-26")
a = p.parse_args()
tasks = json.load(open(f"{a.fixture}/tasks.json"))
local = collections.defaultdict(dict)
for r in json.load(open(a.local)):
    local[r["topic"]][r["method"]] = r["threads"]
gm = {r["topic"]: r for r in json.load(open(a.gmail))}
db = sqlite3.connect(f"{a.fixture}/Cache/index.sqlite")
email = {pk: e.lower() for pk, e in db.execute("SELECT account_pk,email FROM account")}
thread = {g: (email[acc], d, pk) for g, acc, d, pk in db.execute("SELECT gmail_id,account_pk,last_date,thread_pk FROM thread")}
bodied = {pk for (pk,) in db.execute("SELECT DISTINCT thread_pk FROM message WHERE fts_state=2")}
now = datetime.datetime.fromisoformat(a.as_of).timestamp() * 1000

def rank(lst, targets):
    return next((i + 1 for i, t in enumerate(lst) if t in targets), 0)

def gmail_list(i):
    lists = [v["threads"] for v in gm[i]["gmail"].values()]
    out = []
    for k in range(50):
        for l in lists:
            if k < len(l) and l[k] not in out:
                out.append(l[k])
    return out

def mix(b, g, keep):
    top = b[:keep]
    for x in g + b[keep:]:
        if len(top) >= 5:
            break
        if x not in top:
            top.append(x)
    return top

def reorder(b, g, k):
    agree = set(g[:k])
    return [x for x in b if x in agree] + [x for x in b if x not in agree]

rows = []
for i in gm:
    t = tasks[i]
    T = set(t["targets"])
    b, g = local[i]["ranked"], gmail_list(i)
    tgt = [thread[x] for x in T if x in thread]
    age = min((now - d) / 864e5 for _, d, _ in tgt)
    listing = list(gm[i]["gmail"].values())
    rows.append(dict(
        family=t["family"], words=len(re.findall(r"\w+", t["query"])),
        age="<=30d" if age <= 30 else ("31-180d" if age <= 180 else ">180d"),
        body=any(pk in bodied for _, _, pk in tgt),
        ranks={"gmail": rank(g, T), "banana": rank(b, T), "chronological": rank(local[i]["chronological"], T),
               "banana4+gmail1": rank(mix(b, g, 4), T), "banana3+gmail2": rank(mix(b, g, 3), T),
               "bananaReorderedByGmail10": rank(reorder(b, g, 10), T), "bananaReorderedByGmail50": rank(reorder(b, g, 50), T)},
        gmailHits=sum(v["estimate"] or 0 for v in listing), gmailListed=max(len(v["threads"]) for v in listing),
        gmailMs=sum(v["ms"] for v in listing)))

def top5(rs, m):
    return sum(0 < r["ranks"][m] <= 5 for r in rs)

methods = list(rows[0]["ranks"])
groups = {"all": rows}
for key in ("family", "age", "body", "words"):
    for value in sorted({str(r[key] if key != "words" else min(r[key], 3)) for r in rows}):
        groups[f"{key}={value}"] = [r for r in rows if str(r[key] if key != "words" else min(r[key], 3)) == value]
summary = {name: {"tasks": len(rs), **{m: top5(rs, m) for m in methods},
                  "gmailOnly": sum(0 < r["ranks"]["gmail"] <= 5 and not 0 < r["ranks"]["banana"] <= 5 for r in rs),
                  "bananaOnly": sum(0 < r["ranks"]["banana"] <= 5 and not 0 < r["ranks"]["gmail"] <= 5 for r in rs)}
           for name, rs in groups.items()}
why_gmail = collections.Counter(
    "no results" if r["gmailHits"] == 0 else "matched, ranks 6-50" if r["ranks"]["gmail"]
    else "older target pushed past 50 by newer matches" if r["gmailListed"] >= 50 else "did not match target"
    for r in rows if not 0 < r["ranks"]["gmail"] <= 5)
why_banana = collections.Counter(
    ("ranks 6-50" if r["ranks"]["banana"] else "not in first 50") + (", body indexed" if r["body"] else ", headers only")
    for r in rows if not 0 < r["ranks"]["banana"] <= 5)
ms = sorted(r["gmailMs"] for r in rows)
json.dump({"tasks": len(rows), "metric": "intended conversation in the first five",
           "summary": summary, "gmailMisses": why_gmail, "bananaMisses": why_banana,
           "gmailViaServiceMS": {"median": statistics.median(ms), "p95": ms[int(0.95 * len(ms)) - 1]}},
          open(a.out, "w"), indent=1)
print(json.dumps(summary["all"]), dict(why_gmail), dict(why_banana))
