#!/usr/bin/env python3
"""Serial, inference-only Apple-Silicon engine comparison. Never executes Banana tools."""
import argparse,datetime,hashlib,importlib.metadata,json,math,os,pathlib,platform,re,socket,statistics,subprocess,time,urllib.request,urllib.error
from jsonschema import Draft7Validator

HERE=pathlib.Path(__file__).resolve().parent
p=argparse.ArgumentParser()
p.add_argument('--engine',choices=['locals','mlx','mlx-server'],required=True)
p.add_argument('--model',type=pathlib.Path,required=True)
p.add_argument('--python',type=pathlib.Path,required=True)
p.add_argument('--manifest',type=pathlib.Path,required=True)
p.add_argument('--output',type=pathlib.Path,required=True)
p.add_argument('--fixture',type=pathlib.Path,default=HERE/'cases.json')
p.add_argument('--capability-routing',action='store_true',help='Run the production Mac capability routing pipeline')
p.add_argument('--cases',default='');p.add_argument('--repeats',type=int,default=2)
p.add_argument('--port',type=int,default=41790);p.add_argument('--context',type=int,default=32768)
p.add_argument('--max-tokens',type=int,default=2048);p.add_argument('--memory-budget-gb',type=float,default=6)
p.add_argument('--thinking',choices=['off','on'],default='off')
p.add_argument('--temperature',type=float,default=.6);p.add_argument('--top-p',type=float,default=.95);p.add_argument('--top-k',type=int,default=20)
p.add_argument('--repetition-penalty',type=float,default=1.0)
p.add_argument('--mlx-matmul',action='store_true',help='Use documented LOCALS_KERNELS=0 with the Locals compute engine')
p.add_argument('--template-tools-key',choices=['tools','xml_tools'],default='tools')
p.add_argument('--recipe-note',default='Controlled Qwen nonthinking baseline')
a=p.parse_args()
if a.mlx_matmul and a.engine!='locals':p.error('--mlx-matmul only applies to the Locals compute engine')
if a.template_tools_key!='tools' and a.engine!='mlx-server':p.error('Explicit list-valued template-tool mapping requires the native MLX frontend')
if not math.isfinite(a.repetition_penalty) or a.repetition_penalty<=0:p.error('Invalid repetition penalty')
if a.engine!='mlx-server' and a.repetition_penalty!=1:p.error('Pinned Locals frontend does not implement repetition_penalty; use mlx-server or explicitly label its omission')
if not 1024<=a.port<=65535 or a.context<2 or a.max_tokens<1 or a.repeats<1 or a.max_tokens>=a.context or a.memory_budget_gb<=0 or not math.isfinite(a.temperature) or a.temperature<0 or not 0<a.top_p<=1 or a.top_k<0:p.error('Invalid limits')

def command(args):
 r=subprocess.run(args,capture_output=True,text=True,timeout=15)
 return r.stdout.strip() if r.returncode==0 else 'unavailable'
def listening(port):
 with socket.socket() as s:s.settimeout(.2);return s.connect_ex(('127.0.0.1',port))==0
def sha(path):
 h=hashlib.sha256()
 with path.open('rb') as f:
  while chunk:=f.read(8*1024*1024):h.update(chunk)
 return h.hexdigest()
def host():
 vm=command(['vm_stat']);swap=command(['sysctl','vm.swapusage'])
 counters={k:int(v) for k,v in re.findall(r'^(Swapins|Swapouts|Pageouts):\s+(\d+)',vm,re.M)}
 return {'utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'chip':command(['sysctl','-n','machdep.cpu.brand_string']),
  'ramBytes':command(['sysctl','-n','hw.memsize']),'os':platform.mac_ver()[0],'swap':swap,'paging':counters}
def http(path,payload=None,timeout=120):
 request=urllib.request.Request(f'http://127.0.0.1:{a.port}'+path,data=json.dumps(payload,sort_keys=True).encode() if payload is not None else None,headers={'Content-Type':'application/json'})
 with urllib.request.urlopen(request,timeout=timeout) as r:return json.load(r)

def resolved_day(args,default='2026-10-25'):
 value=args.get('day','today')
 if value=='date':value=args.get('date')
 return {'today':'2026-10-25','tomorrow':'2026-10-26','yesterday':'2026-10-24'}.get(value,value or default)
def score(case,raw):
 if case.get("contractVersion") == 1:
  from common_contracts import score_common
  return score_common(case,raw)
 choices=raw.get('choices',[])
 if len(choices)!=1 or choices[0].get('finish_reason') not in ['stop','tool_calls']:return False,'incomplete'
 m=choices[0]['message'];calls=m.get('tool_calls') or [];expect=case['expected']
 if expect['tool'] is None:
  text=m.get('content') or ''
  return (not calls and bool(text.strip()) and expect.get('textIncludes','').casefold() in text.casefold()),'reply_contract'
 if len(calls)!=1 or calls[0].get('function',{}).get('name')!=expect['tool']:return False,'wrong_tool'
 try:args=json.loads(calls[0]['function']['arguments'])
 except Exception:return False,'invalid_json'
 schema=next(t['parameters'] for t in case['request']['tools'] if t['name']==expect['tool'])
 if list(Draft7Validator(schema).iter_errors(args)):return False,'schema'
 if expect['tool']=='nutrition_view':
  wanted=expect['arguments']
  if args.get('metric','protein')!=wanted.get('metric','protein'):return False,'wrong_metric'
  if args.get('foodName','').casefold()!=wanted.get('foodName','').casefold():return False,'wrong_food_search'
  if 'period' in wanted:
   periods={'this_month':('2026-10-01','2026-10-25'),'last_7_days':('2026-10-19','2026-10-25')}
   actual=periods.get(args.get('period'),(args.get('start','2026-10-01'),args.get('end','2026-10-25')))
   if actual!=periods[wanted['period']]:return False,'wrong_range'
 for key,value in expect['arguments'].items():
  if key=='day' or (expect['tool']=='nutrition_view' and key in ['metric','period','foodName']):continue
  actual=args.get(key)
  if isinstance(value,str):
   if value.casefold() not in str(actual or '').casefold():return False,'argument_'+key
  elif actual!=value:return False,'argument_'+key
 target=expect.get('day') or expect['arguments'].get('day')
 if target and resolved_day(args)!=resolved_day({'day':target}):return False,'wrong_day'
 if expect.get('foods'):
  foods=args.get('foods',[])
  if len(foods)!=len(expect['foods']):return False,'food_count'
  for name,amount in [('egg',2),('banana',1)]:
   matches=[f for f in foods if name in f['name'].casefold()]
   if len(matches)!=1:return False,'food_identity'
   quantity=matches[0]['quantity'].casefold();numbers=re.findall(r'\d+(?:\.\d+)?',quantity)
   actual=float(numbers[0]) if numbers else {'one':1,'two':2}.get(quantity)
   if actual!=amount:return False,'food_amount'
 if expect['tool']=='day_plan' and args.get('date','2026-10-25')!='2026-10-25':return False,'plan_day'
 return True,'contract_pass'

if listening(a.port) or listening(41789):raise SystemExit('Close Banana Pi/other inference first; no existing process was stopped')
manifest=json.loads(a.manifest.read_text());model=a.model.resolve()
for name,entry in manifest['files'].items():
 path=model/name
 if not path.is_file() or path.stat().st_size!=entry['bytes'] or sha(path)!=entry['sha256']:raise SystemExit('Checkpoint verification failed: '+name)
weight_bytes=sum(v['bytes'] for k,v in manifest['files'].items() if k.endswith('.safetensors'))
if weight_bytes>a.memory_budget_gb*1e9:raise SystemExit('Checkpoint alone exceeds the explicit memory budget; not loaded')
fixture_path=a.fixture;fixture=json.loads(fixture_path.read_text())
cases=[c for c in fixture['cases'] if not a.cases or c['id'] in a.cases.split(',')]
if not cases:p.error('No matching cases')
report={'complete':False,'scope':fixture.get('scope','Synthetic inference/tool contract cases; not real-app latency or production p95.'),
 'engine':a.engine,'runnerSha256':sha(pathlib.Path(__file__)),'checkpoint':manifest,'fixtureSha256':sha(fixture_path),'fixtureVersion':fixture['version'],
 'recipeNote':a.recipe_note,'capabilityRouting':a.capability_routing,
 'routingDriverSha256':sha(HERE/'routed-request.mjs') if a.capability_routing else None,
 'commandContractsSha256':sha(HERE.parent/'pi-host-proof/runtime/command-contracts.js') if a.capability_routing else None,
 'clockContextSha256':sha(HERE.parent/'pi-host-proof/runtime/clock-context.js') if a.capability_routing else None,
 'requestLanguageSha256':sha(HERE.parent/'pi-host-proof/runtime/request-language.js') if a.capability_routing else None,
 'routingSha256':sha(HERE.parent/'pi-host-proof/runtime/capability-routing.js') if a.capability_routing else None,
 'settings':{'thinking':a.thinking=='on','context':a.context,'maxTokens':a.max_tokens,'temperature':a.temperature,'topP':a.top_p,'topK':a.top_k,'repetitionPenalty':a.repetition_penalty,'templateToolsKey':a.template_tools_key,'slots':1,'cacheGB':2,'repeats':a.repeats,'memoryBudgetGB':a.memory_budget_gb,'budgetMeaning':'Checkpoint preflight only; working memory is observed, not hard-limited by this option'},
 'runtimeEnvironment':{k:os.environ.get(k) for k in ['LOCALS_KERNELS','LOCALS_TUNE','LOCALS_DTYPE','LOCALS_FUSE']},'environmentOverrides':{'LOCALS_KERNELS':'0'} if a.mlx_matmul else {},
 'hostBefore':host(),'results':[]}
report['versions']=json.loads(command([str(a.python),'-c','import importlib.metadata,json;print(json.dumps({n:importlib.metadata.version(n) for n in ["mlx","mlx-lm","locals"]}))']))
source=HERE.parents[2]/'pi-inference-upstream/locals'
report['engineSourceCommit']=command(['git','-C',str(source),'rev-parse','HEAD'])
report['engineSourceDirty']=command(['git','-C',str(source),'status','--porcelain'])
report['servingImplementation']='mlx_lm.server' if a.engine=='mlx-server' else 'locals.server'
if a.engine=='mlx-server':
 report['unusedLocalsReference']={'commit':report.pop('engineSourceCommit'),'dirty':report.pop('engineSourceDirty')}
 report['engineSourceCommit']=None
 report['engineSourceDirty']=None
 report['engineSourceNote']='Installed mlx-lm wheel version is recorded; no claim that the unused Locals source is this frontend'

a.output.parent.mkdir(parents=True,exist_ok=True)
def save():
 temporary=a.output.with_suffix('.tmp');temporary.write_text(json.dumps(report,indent=2)+'\n');temporary.replace(a.output)
args=[str(a.python),'-m','locals.server','--model',str(model),'--engines',a.engine,'--preload',a.engine,'--host','127.0.0.1','--port',str(a.port),'--slots','1','--cache-gb','2','--max-context',str(a.context),'--max-tokens',str(a.max_tokens),'--temp',str(a.temperature),'--top-p',str(a.top_p),'--top-k',str(a.top_k),'--seed','0']
if a.engine=='mlx-server':
 args=[str(a.python),'-m','mlx_lm.server','--model',str(model),'--host','127.0.0.1','--port',str(a.port),'--temp',str(a.temperature),'--top-p',str(a.top_p),'--top-k',str(a.top_k),'--max-tokens',str(a.max_tokens),'--decode-concurrency','1','--prompt-concurrency','1','--prompt-cache-size','1','--prompt-cache-bytes','2GB']
 report['settings']['contextEnforcement']='Fixture inputs/output bound; standalone server has no matching max-context flag'
 report['settings']['cachePolicy']='One retained prompt cache, 2GB cap; different implementation from Locals slots'
 report['settings']['serverSeed']='Per-request seed=0; standalone API rather than Locals server-global RNG'
report['command']=args
start=time.perf_counter();proc=None
try:
 with a.output.with_suffix('.server.log').open('w') as log:
  proc=subprocess.Popen(args,stdout=log,stderr=subprocess.STDOUT,env={**os.environ,'HF_HUB_OFFLINE':'1','HF_HUB_DISABLE_TELEMETRY':'1','DO_NOT_TRACK':'1',**report['environmentOverrides']})
  deadline=time.monotonic()+120
  while True:
   if proc.poll() is not None:raise RuntimeError('Inference engine exited during load; inspect server log')
   try:
    models=http('/v1/models',timeout=1)['data']
    server_model='default_model' if a.engine=='mlx-server' else next(m['id'] for m in models if m['id'].startswith(a.engine+'/') and m['id'].endswith('-thinking')==(a.thinking=='on'))
    break
   except (OSError,ValueError,StopIteration):
    if time.monotonic()>deadline:raise TimeoutError('Engine readiness exceeded 120 seconds')
    time.sleep(.1)
  report['serverReadySeconds']=round(time.perf_counter()-start,3)
  report['loadSeconds']=report['serverReadySeconds'] if a.engine!='mlx-server' else None
  if a.engine=='mlx-server':report['readinessNote']='HTTP readiness is not a separate completed-model-load measurement; loading may overlap readiness/first response'
  report['serverModel']=server_model;save()
  for repeat in range(a.repeats):
   for case in cases:
    request=case['request'];payload={'model':server_model,'messages':[{'role':'system','content':request['instructions']}]+[{'role':m['role'],'content':m['text']} for m in request['messages']],
     'tools':[{'type':'function','function':t} for t in request['tools']],'tool_choice':'auto','parallel_tool_calls':False,'stream':False,
     'max_tokens':a.max_tokens,'temperature':a.temperature,'top_p':a.top_p,'top_k':a.top_k,'chat_template_kwargs':{'enable_thinking':a.thinking=='on','preserve_thinking':True}}
    if a.template_tools_key=='xml_tools':payload['chat_template_kwargs']['xml_tools']=request['tools']
    if a.thinking=='off':payload['reasoning_effort']='none'
    if a.engine=='mlx-server':payload.update(seed=0,repetition_penalty=a.repetition_penalty)
    row={'case':case['id'],'repeat':repeat};began=time.perf_counter();request_error=None
    try:
     if a.capability_routing:
      routed=subprocess.run(['node',str(HERE/'routed-request.mjs')],input=json.dumps({'request':request,'payload':payload,'url':f'http://127.0.0.1:{a.port}/v1/chat/completions'}),capture_output=True,text=True,timeout=250)
      if routed.returncode:raise RuntimeError(routed.stderr[-3000:])
      raw=json.loads(routed.stdout)
     else:raw=http('/v1/chat/completions',payload)
     row['milliseconds']=round((time.perf_counter()-began)*1000,1)
     row['raw']=raw;row['passed'],row['reason']=score(case,raw)
    except Exception as error:
     row.update(milliseconds=round((time.perf_counter()-began)*1000,1),passed=False,error=str(error));request_error=error
     if isinstance(error,urllib.error.HTTPError):row['errorBody']=error.read().decode(errors='replace')[:2000]
    if a.engine=='mlx-server':
     rss=command(['ps','-o','rss=','-p',str(proc.pid)])
     row['engineStats']={'memory':{'rss_mb':int(rss)*1024/1e6 if rss.isdigit() else None},'note':'Observed process RSS; standalone server exposes no Locals /stats GPU counters'}
    else:row['engineStats']=http('/stats')
    report['results'].append(row);save()
    print(json.dumps({k:v for k,v in row.items() if k not in ['raw','engineStats']}),flush=True)
    if request_error is not None:raise RuntimeError('Transport/backend failure; halted rather than repeating failed requests: '+str(request_error))
  report['complete']=True
except Exception as error:report['fatalError']=str(error)
finally:
 if proc is not None:
  proc.terminate()
  try:proc.wait(timeout=10)
  except subprocess.TimeoutExpired:proc.kill();proc.wait(timeout=5)
 report['hostAfter']=host();report['ownedWorkerReleased']=not listening(a.port)
 paging={k:report['hostAfter']['paging'].get(k,0)-v for k,v in report['hostBefore']['paging'].items()}
 report['pagingDelta']=paging
 report['cleanPerformanceRun']=not any(paging.values())
 warm=[r['milliseconds'] for r in report['results'] if r['repeat']>0]
 report['summary']={'passes':sum(r['passed'] for r in report['results']),'total':len(report['results']),
  'warmMedianMilliseconds':statistics.median(warm) if warm else None,
  'firstRequestMilliseconds':report['results'][0]['milliseconds'] if report['results'] else None,
  'gpuPeakMB':max((r['engineStats']['memory'].get('gpu_peak_mb') for r in report['results'] if r['engineStats']['memory'].get('gpu_peak_mb') is not None),default=None),
  'rssMaxObservedMB':max((r['engineStats']['memory']['rss_mb'] for r in report['results'] if r['engineStats']['memory'].get('rss_mb') is not None),default=None)}
 save();print(json.dumps(report['summary'],indent=2))
if not report['complete']:raise SystemExit(1)
