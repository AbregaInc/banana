"""Searches for attachment content, written by a local model from extracted text (see docs/performance/mail-attachment-search.md). Args: work dir, MLX model dir."""
import json,sys,re,sqlite3
sys.path.insert(0, __import__('os').path.dirname(__file__))
from mail_field_index import decode_prepared
from mlx_lm import batch_generate, load
from mlx_lm.sample_utils import make_sampler
S=sys.argv[1]; M=sys.argv[2]
meta=json.load(open(f'{S}/att-meta.json'))
db=sqlite3.connect(f'{S}/beta/Cache/index.sqlite'); db.execute(f"ATTACH '{S}/beta/Cache/blobs.sqlite' AS b")
PROMPT="""Below is the text of a document that was attached to an email you received. You don't remember the email's subject or exactly who sent it, but you remember this attachment's content.
Write the search you would type into your email app's search box to find it again. Write it the way people really search email: 1 to 4 lowercase words about something specific in the document (a company, product, place, event, topic, amount or name). Do not copy long codes or numbers. Reply with the search words only.

Attachment text:
{t}"""
word=re.compile(r"[^\W_]+")
picked=[]
for i,x in enumerate(meta):
    if x.get('chars',0)<=50: continue
    text=' '.join(open(f'{S}/att-text/{i:03d}.txt').read().split())[:1800]
    picked.append((i,x,text))
model,tok=load(M)
prompts=[tok.apply_chat_template([{"role":"user","content":PROMPT.format(t=t)}],add_generation_prompt=True,enable_thinking=False) for _,_,t in picked]
out=batch_generate(model,tok,prompts,max_tokens=16,sampler=make_sampler(temp=0.0),verbose=False)
tasks=[]
for (i,x,_),text in zip(picked,out.texts):
    q=' '.join(word.findall(text.strip().splitlines()[0].casefold()))[:80] if text.strip() else ''
    if not q or len(q.split())>6: continue
    row=db.execute("""SELECT coalesce(m.subject,'')||' '||coalesce(m.from_name,'')||' '||coalesce(m.from_addr,'')||' '||coalesce(m.recipients,''), p.text
      FROM message m JOIN account a ON a.account_pk=m.account_pk JOIN b.prepared p ON p.account=a.email AND p.gmail_id=m.gmail_id
      WHERE a.email=? AND m.gmail_id=?""",(x['account'],x['message'])).fetchone()
    elsewhere=set(word.findall((row[0]+' '+decode_prepared(row[1])+' '+x['name']).casefold()))
    tasks.append({"family":"attachment","query":q,"targets":[x['thread']],"kind":x['kind'],"att":i,
                  "attachmentOnly": not any(w in elsewhere for w in q.split())})
json.dump(tasks,open(f'{S}/att-tasks.json','w'))
print(len(tasks),'searches;',sum(t['attachmentOnly'] for t in tasks),'only answerable from the attachment')
