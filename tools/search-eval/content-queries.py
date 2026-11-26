"""Content searches written by a local model, one per sampled email.

The model reads only an email's body (no subject, sender or recipients) and writes what a person who
remembered what the email said would type into a mail search box. It runs on this Mac (MLX), so no mail
leaves the machine. Each conversation contributes its newest message with prepared body text; 70 per age
band. A query is labelled `bodyOnly` when none of its words appear in the subject, sender or recipients,
so the gain from indexing bodies can be read separately from queries headers could also answer.
Writes private `tasks.json` entries `{family:"content", query, targets, ageBand, bodyOnly}`.
"""
import argparse, datetime, json, random, re, sqlite3, sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from mail_field_index import decode_prepared
from mlx_lm import batch_generate, load
from mlx_lm.sample_utils import make_sampler

p = argparse.ArgumentParser(description=__doc__)
p.add_argument("--fixture", type=Path, required=True)
p.add_argument("--model", type=Path, required=True)
p.add_argument("--out", type=Path, required=True)
p.add_argument("--per-band", type=int, default=70)
p.add_argument("--as-of", default="2026-11-26")
p.add_argument("--seed", type=int, default=91127)
a = p.parse_args()
rng = random.Random(a.seed)
db = sqlite3.connect(a.fixture / "Cache/index.sqlite")
db.execute(f"ATTACH '{a.fixture / 'Cache/blobs.sqlite'}' AS blobs")
word = re.compile(r"[^\W_]+")
newest = {}
for msg, thread, gid, last, subject, name, addr, recipients, blob in db.execute("""
    SELECT m.msg_pk, m.thread_pk, t.gmail_id, t.last_date, coalesce(m.subject,''), coalesce(m.from_name,''),
           coalesce(m.from_addr,''), coalesce(m.recipients,''), p.text
    FROM message m JOIN thread t ON t.thread_pk=m.thread_pk JOIN account a ON a.account_pk=m.account_pk
    JOIN blobs.prepared p ON p.account=a.email AND p.gmail_id=m.gmail_id
    WHERE m.fts_state=2 AND t.last_date>0"""):
    if thread not in newest or msg > newest[thread][0]:
        newest[thread] = (msg, gid, last, " ".join([subject, name, addr, recipients]), blob)
now = datetime.datetime.fromisoformat(a.as_of).timestamp() * 1000
day = 86_400_000
bands = {"last30d": (now - 30 * day, now + day), "31to180d": (now - 180 * day, now - 30 * day), "older": (0, now - 180 * day)}
picked = []
for band, (lo, hi) in bands.items():
    pool = sorted(t for t, v in newest.items() if lo <= v[2] < hi)
    rng.shuffle(pool)
    n = 0
    for thread in pool:
        if n == a.per_band:
            break
        msg, gid, last, header, blob = newest[thread]
        try:
            body = " ".join(decode_prepared(blob).split())
        except Exception:
            continue
        if len(body) < 80:
            continue
        picked.append((band, gid, header, body[:1800]))
        n += 1

PROMPT = """Below is the text of an email you received some time ago. You no longer remember its subject line or exactly who sent it, but you remember what it said.
Write the search you would type into your email app's search box to find it again. Write it the way people really search email: 1 to 4 lowercase words, about the thing you remember (a product, place, event, topic, request, amount or name mentioned in the text). Do not copy long codes or tracking numbers. Reply with the search words only.

Email text:
{body}"""
model, tokenizer = load(str(a.model))
prompts = [tokenizer.apply_chat_template([{"role": "user", "content": PROMPT.format(body=b)}], add_generation_prompt=True,
                                         enable_thinking=False) for _, _, _, b in picked]
out = batch_generate(model, tokenizer, prompts, max_tokens=16, sampler=make_sampler(temp=0.0), verbose=False)
tasks = []
for (band, gid, header, body), text in zip(picked, out.texts):
    query = " ".join(word.findall(text.strip().splitlines()[0].casefold()))[:80] if text.strip() else ""
    words = query.split()
    if not words or len(words) > 6:
        continue
    head = set(word.findall(header.casefold()))
    tasks.append({"family": "content", "query": query, "targets": [gid], "ageBand": band,
                  "bodyOnly": not any(w in head for w in words)})
a.out.write_text(json.dumps(tasks))
print(f"{len(tasks)} content searches from {len(picked)} emails; {sum(t['bodyOnly'] for t in tasks)} use no header words")
