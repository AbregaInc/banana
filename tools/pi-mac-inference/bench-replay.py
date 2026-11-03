#!/usr/bin/env python3
"""Replay two observed slow inputs against current local inference; no app effects."""
import argparse,json,pathlib,sqlite3,time,urllib.request
p=argparse.ArgumentParser();p.add_argument('--output',required=True,type=pathlib.Path);a=p.parse_args()
support=pathlib.Path.home()/'Library/Application Support/Banana Pi'
config=json.loads((support/'LocalInference/configuration.json').read_text())
connection=sqlite3.connect('file:'+str(support/'PiAssistant/agent.sqlite')+'?mode=ro',uri=True)
entries=[json.loads(row[0]) for row in connection.execute('select record from entries order by commit_seq')]
tools=json.loads((pathlib.Path(__file__).resolve().parents[1]/'pi-model-bench/requests.json').read_text())['cases'][0]['request']['tools']
rows=[]
for prompt in ['What is your name','Can you add the salmon dinner again']:
 candidates=[e for e in entries if e.get('kind')=='pi.user' and any(m.get('content')==prompt for m in e.get('model',[]))]
 for user in reversed(candidates):
  answer=next((e for e in entries if e.get('kind')=='pi.assistant' and e['conversationId']==user['conversationId'] and e['id']>user['id']),None)
  if answer and answer['model'][0].get('model')=='qwen3.8-27b-4bit':break
 else:raise SystemExit('Original 27B exchange was not found; no comparison was made.')
 prior=[e for e in entries if e.get('conversationId')==user['conversationId'] and e['id']<answer['id']]
 system=next(m for e in reversed(prior) for m in e.get('model',[]) if m['role']=='system' and 'instructions' in m.get('sections',{}))
 sections={}
 for e in prior:
  for m in e.get('model',[]):
   if m['role']=='system':sections.update(m.get('sections',{}))
 old=answer['model'][0]
 # Mirror the extension's current repeat policy when replaying the older captured view.
 sections['nutrition-view']=sections['nutrition-view'].replace('</nutrition-view>','For repeat/add-again meal requests, use prepare_meal_copy directly with the most recent matching visible meal ID; do not search again when matching IDs are already listed. Default to today unless another date is requested. </nutrition-view>')
 # Full registered schema and active native context, including existing name exchange.
 messages=[{'role':'system','content':'\n'.join(sections.values())}]
 if prompt!='What is your name':
  messages.extend([{'role':'user','content':'What is your name'},{'role':'assistant','content':"I'm Banana! I'm your personal assistant running on this device. How can I help you today?"}])
 messages.append({'role':'user','content':prompt})
 for repeat in range(2):
  payload={'model':config['serverModel'],'messages':messages,'tools':[{'type':'function','function':t} for t in tools],
   'tool_choice':'auto','parallel_tool_calls':False,'stream':False,'max_tokens':config['maxTokens'],'temperature':.6,'top_p':.95,'top_k':20,
   'reasoning_effort':'none','chat_template_kwargs':{'enable_thinking':False,'preserve_thinking':True}}
  request=urllib.request.Request('http://127.0.0.1:41789/v1/chat/completions',data=json.dumps(payload,sort_keys=True).encode(),headers={'Content-Type':'application/json'})
  start=time.perf_counter()
  with urllib.request.urlopen(request,timeout=120) as response:raw=json.load(response)
  row={'prompt':prompt,'repeat':repeat,'model':config['modelId'],'milliseconds':round((time.perf_counter()-start)*1000),'old27BObservedMilliseconds':old['durationMs'],'raw':raw}
  m=raw['choices'][0]['message'];calls=m.get('tool_calls') or []
  if prompt=='What is your name':row['contractPass']=not calls and 'banana' in (m.get('content') or '').lower()
  else:
   expected=[meal for meal in json.loads(sections['nutrition-view'].split('Current native nutrition view: ',1)[1].split('. nutrition_view',1)[0])['summary']['meals'] if 'Salmon dinner' in meal['name']]
   row['contractPass']=len(calls)==1 and calls[0]['function']['name']=='prepare_meal_copy' and json.loads(calls[0]['function']['arguments']).get('mealID') in [meal['id'] for meal in expected] and json.loads(calls[0]['function']['arguments']).get('day')=='today'
  rows.append(row);a.output.write_text(json.dumps({'model':config['modelId'],'scope':'Exact user wording, captured native view and current registered tool schemas; inference replay only, not a completed app action. No native tools execute.','results':rows},indent=2)+'\n')
  print(json.dumps({k:v for k,v in row.items() if k!='raw'}),flush=True)
if not all(row['contractPass'] for row in rows):raise SystemExit(1)
