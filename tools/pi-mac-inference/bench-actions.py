#!/usr/bin/env python3
"""Capture native local-server decisions; never execute app tools."""
import argparse,json,pathlib,time,urllib.request
p=argparse.ArgumentParser();p.add_argument('--output',required=True,type=pathlib.Path);p.add_argument('--cases',default='');p.add_argument('--repeats',type=int,default=2);p.add_argument('--reasoning',default='off');a=p.parse_args()
root=pathlib.Path(__file__).resolve().parents[2]
fixture=json.loads((root/'tools/pi-model-bench/requests.json').read_text())
config=json.loads((pathlib.Path.home()/'Library/Application Support/Banana Pi/LocalInference/configuration.json').read_text())
rows=[]
for repeat in range(a.repeats):
 for c in fixture['cases']:
  if a.cases and c['id'] not in a.cases.split(','):continue
  r=c['request']
  payload={'model':config['serverModel'],'messages':[{'role':'system','content':r['instructions']}]+[{'role':'user','content':m['text']} for m in r['messages']],
   'tools':[{'type':'function','function':t} for t in r['tools']],'tool_choice':'auto','parallel_tool_calls':False,'stream':False,'max_tokens':config['maxTokens'],'temperature':0.6,'top_p':0.95,'top_k':20,
   'reasoning_effort':'none' if a.reasoning=='off' else a.reasoning,'chat_template_kwargs':{'enable_thinking':a.reasoning!='off','preserve_thinking':True}}
  request=urllib.request.Request('http://127.0.0.1:41789/v1/chat/completions',data=json.dumps(payload,sort_keys=True).encode(),headers={'Content-Type':'application/json'})
  start=time.perf_counter();row={'case':c['id'],'repeat':repeat}
  try:
   with urllib.request.urlopen(request,timeout=600) as response:raw=json.load(response)
   row['raw']=raw;choice=raw['choices'][0];m=choice['message'];parts=[]
   if choice['finish_reason'] not in ['stop','tool_calls']:raise ValueError('Incomplete model answer: '+str(choice['finish_reason']))
   if m.get('content'):parts.append({'type':'text','text':m['content']})
   for call in m.get('tool_calls') or []:parts.append({'type':'toolCall','id':call['id'],'name':call['function']['name'],'arguments':json.loads(call['function']['arguments'])})
   row['response']={'content':parts}
  except Exception as e:row['error']=str(e)
  row['milliseconds']=round((time.perf_counter()-start)*1000,1);rows.append(row)
  report={'backend':config['modelId'],'reasoning':a.reasoning,'complete':False,'results':rows}
  a.output.write_text(json.dumps(report,indent=2)+'\n')
  print(json.dumps({k:v for k,v in row.items() if k!='raw'}),flush=True)
report['complete']=True;a.output.write_text(json.dumps(report,indent=2)+'\n')
