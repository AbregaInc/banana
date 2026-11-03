#!/usr/bin/env python3
"""Compare backend responsiveness after a closed non-streaming client. No tools execute."""
import argparse,hashlib,http.client,importlib.metadata,json,pathlib,socket,subprocess,time,urllib.request
p=argparse.ArgumentParser();p.add_argument('--engine',choices=['locals','mlx','mlx-server'],required=True);p.add_argument('--model',type=pathlib.Path,required=True);p.add_argument('--python',type=pathlib.Path,required=True);p.add_argument('--manifest',type=pathlib.Path,required=True);p.add_argument('--output',type=pathlib.Path,required=True);p.add_argument('--port',type=int,default=41790);a=p.parse_args()
def listening(port):
 with socket.socket() as s:s.settimeout(.2);return s.connect_ex(('127.0.0.1',port))==0
def sha(path):
 h=hashlib.sha256()
 with path.open('rb') as f:
  while chunk:=f.read(8*1024*1024):h.update(chunk)
 return h.hexdigest()
if listening(a.port) or listening(41789):raise SystemExit('Another inference service is active; nothing was stopped')
m=json.loads(a.manifest.read_text());model=a.model.resolve()
for name,entry in m['files'].items():
 f=model/name
 if not f.is_file() or f.stat().st_size!=entry['bytes'] or sha(f)!=entry['sha256']:raise SystemExit('Checkpoint hash mismatch: '+name)
def api(path,payload=None):
 r=urllib.request.Request(f'http://127.0.0.1:{a.port}'+path,data=json.dumps(payload).encode() if payload is not None else None,headers={'Content-Type':'application/json'})
 with urllib.request.urlopen(r,timeout=120) as out:return json.load(out)
args=[str(a.python),'-m','mlx_lm.server','--model',str(model),'--host','127.0.0.1','--port',str(a.port),'--max-tokens','2048','--decode-concurrency','1','--prompt-concurrency','1','--prompt-cache-size','1','--prompt-cache-bytes','2GB'] if a.engine=='mlx-server' else [str(a.python),'-m','locals.server','--model',str(model),'--engines',a.engine,'--preload',a.engine,'--host','127.0.0.1','--port',str(a.port),'--slots','1','--cache-gb','2','--max-tokens','2048','--max-context','32768','--seed','0']
report={'complete':False,'scope':'Synthetic nonstreaming client cancellation and next-request responsiveness, not Pi/app acceptance or production p95. No tools or user data.','engine':a.engine,'checkpoint':m,'command':args,'runnerSha256':sha(pathlib.Path(__file__))};proc=None;connection=None;response=None
a.output.parent.mkdir(parents=True,exist_ok=True)
try:
 with a.output.with_suffix('.server.log').open('w') as log:
  proc=subprocess.Popen(args,stdout=log,stderr=subprocess.STDOUT);deadline=time.monotonic()+120
  while True:
   if proc.poll() is not None:raise RuntimeError('Backend exited during startup')
   try:
    rows=api('/v1/models')['data'];name='default_model' if a.engine=='mlx-server' else next(x['id'] for x in rows if x['id'].startswith(a.engine+'/') and not x['id'].endswith('-thinking'));break
   except (OSError,ValueError,StopIteration):
    if time.monotonic()>deadline:raise TimeoutError('Backend startup timeout')
    time.sleep(.1)
  def payload(text,budget):return {'model':name,'messages':[{'role':'system','content':'Follow the user instruction. Be concise unless asked for a long sequence.'},{'role':'user','content':text}],'stream':False,'max_tokens':budget,'temperature':0,'top_p':1,'top_k':0,'seed':0,'chat_template_kwargs':{'enable_thinking':False}}
  ready=payload('Reply with exactly the word ready.',32);begin=time.perf_counter();report['warmup']=api('/v1/chat/completions',ready);report['warmupMilliseconds']=round((time.perf_counter()-begin)*1000,1)
  long_text='Output a JSON array of every integer from 1 to 20000 in order. Output only the array. Do not abbreviate or explain.'
  begin=time.perf_counter();report['baseline']=api('/v1/chat/completions',payload(long_text,512));report['baselineMilliseconds']=round((time.perf_counter()-begin)*1000,1)
  report['longWorkloadEstablished']=report['baseline'].get('usage',{}).get('completion_tokens',0)>=400
  if not report['longWorkloadEstablished']:raise RuntimeError('Model did not establish a long generation; cancellation probe inconclusive')
  progress_offset=a.output.with_suffix('.server.log').stat().st_size
  report['stage']='request_sent'
  connection=http.client.HTTPConnection('127.0.0.1',a.port,timeout=120);connection.request('POST','/v1/chat/completions',body=json.dumps(payload(long_text,2048)),headers={'Content-Type':'application/json'})
  if a.engine=='mlx-server':
   deadline=time.monotonic()+15
   while True:
    with a.output.with_suffix('.server.log').open('rb') as progress:
     progress.seek(progress_offset);active=b'Prompt processing progress:' in progress.read()
    if active:break
    if proc.poll() is not None:raise RuntimeError('Backend exited before processing the request')
    if time.monotonic()>deadline:raise TimeoutError('No generation-progress marker; cancellation trigger not reached')
    time.sleep(.02)
   report['cancellationTrigger']='New backend generation-progress log marker before closing the client; buffered headers are not used'
  else:
   deadline=time.monotonic()+15
   while not api('/stats').get('active'):
    if time.monotonic()>deadline:raise TimeoutError('Request did not enter server active state')
    time.sleep(.02)
   report['cancellationTrigger']='Server reports active request before buffered headers/body'
  if connection.sock is not None:connection.sock.shutdown(socket.SHUT_RDWR)
  if response is not None:response.close()
  connection.close();connection=None
  report['stage']='client_closed_waiting_next_response'
  begin=time.perf_counter();report['nextResponse']=api('/v1/chat/completions',ready);report['nextResponseMilliseconds']=round((time.perf_counter()-begin)*1000,1)
  report['stage']='next_response_received';report['complete']=True
except Exception as error:report['error']=str(error)
finally:
 if connection is not None:connection.close()
 if proc is not None:
  proc.terminate()
  try:proc.wait(timeout=10)
  except subprocess.TimeoutExpired:proc.kill();proc.wait(timeout=5)
 report['ownedWorkerReleased']=not listening(a.port);a.output.write_text(json.dumps(report,indent=2)+'\n')
 print(json.dumps({k:v for k,v in report.items() if k in ['complete','error','baselineMilliseconds','nextResponseMilliseconds','ownedWorkerReleased','longWorkloadEstablished']}))
if not report['complete']:raise SystemExit(1)
