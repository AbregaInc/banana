#!/usr/bin/env python3
"""Run real-model acceptance in the full isolated Mac app, preserving normal history."""
import argparse,hashlib,json,pathlib,plistlib,subprocess,time,uuid
p=argparse.ArgumentParser();p.add_argument('app',type=pathlib.Path);p.add_argument('--nutrition',action='store_true');p.add_argument('--workspace',action='store_true');p.add_argument('--report-prefix',default='mac-local');p.add_argument('--inference-configuration',type=pathlib.Path);a=p.parse_args()
info=plistlib.loads((a.app/'Contents/Info.plist').read_bytes());bundle=info['CFBundleIdentifier']
if not bundle.endswith('.mac.pi-development'):p.error('Only the isolated Mac Pi app may be tested')
root=pathlib.Path(__file__).resolve().parents[2];support=pathlib.Path.home()/'Library/Application Support'
reports=root/'docs/research/pi-apple-host-results';name=a.report_prefix+('-workspace' if a.workspace else '-nutrition' if a.nutrition else '-app')
# The app's own model: what MacLocalInference builds from the bundled pin, its PiRuntime and the
# folder LocalModel downloads into. A candidate profile is passed explicitly instead.
pin=json.loads((a.app/'Contents/Resources/pi-local-model.json').read_text());profile=pin['profile']
builtin={'python':str(a.app/'Contents/Resources/PiRuntime/bin/python3'),
 'modelDirectory':str(support/f"Banana Pi/Models/{pin['repo'].split('/')[-1]}@{pin['revision'][:12]}"),
 'revision':pin['revision'],**{k:profile[k] for k in ['modelId','serverModel','name','port','contextWindow','maxTokens','thinkingLevel']}}
config_path=a.inference_configuration.resolve() if a.inference_configuration else root/'.build/pi-builtin-verification.json'
if not a.inference_configuration:config_path.parent.mkdir(exist_ok=True);config_path.write_text(json.dumps(builtin,indent=2)+'\n')
config=json.loads(config_path.read_text())
if config['port']!=41789:p.error('App acceptance reserves port 41789')
trace=support/'Banana Pi Verification/model-turns.jsonl'
trace_offset=trace.stat().st_size if trace.exists() else 0
run=str(uuid.uuid4())
def host_state():
 return {name:subprocess.check_output(command,text=True).strip() for name,command in [('vm', ['vm_stat']),('swap',['sysctl','vm.swapusage'])]}
host_before=host_state()
def normal_state():
 result={}
 normal=support/'Banana Pi'
 for relative in ['PiAssistant/agent.sqlite','PiAssistant/agent.sqlite-wal','PiAssistant/agent.sqlite.wake.json','PiAssistant/pending-input.json','wellness.json','VoiceNotes/notes.json','VoiceNotes/notes.sqlite','VoiceNotes/notes.sqlite-wal','VoiceNotes/notes.sqlite-shm','routines.json','pending-calendar-writes.json']:
  path=normal/relative;result[relative]=hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() else None
 prefs=subprocess.run(['defaults','export',bundle,'-'],capture_output=True)
 values=plistlib.loads(prefs.stdout) if prefs.returncode==0 else {}
 return result,{key:values.get(key) for key in ['assistant.selection','assistant.draft','shellState']}
if subprocess.run(['lsof','-n','-iTCP:41789','-iTCP:41790','-sTCP:LISTEN'],capture_output=True).stdout:
 raise SystemExit('Release the existing Pi worker before this ownership check; it was not stopped automatically')
before=normal_state()
flags=['--assistant-real-test','--assistant-verify','--assistant-headless','--ui-preview','--disable-icloud','--assistant-verification-id',run]
if a.nutrition:flags+=['--assistant-nutrition-verify']
if a.workspace:flags+=['--assistant-workspace-verify']
flags+=['--assistant-inference-configuration',str(config_path)]
with (reports/(name+'.console.txt')).open('w') as log:
 started=time.monotonic();timed_out=False
 process=subprocess.Popen([str(a.app/'Contents/MacOS'/info['CFBundleExecutable']),*flags],stdout=log,stderr=subprocess.STDOUT)
 try:exit_code=process.wait(timeout=900)
 except subprocess.TimeoutExpired:
  timed_out=True
  process.terminate()
  try:process.wait(timeout=10)
  except subprocess.TimeoutExpired:process.kill();process.wait(timeout=5)
  exit_code=process.returncode
path=support/'Banana Pi Verification/PiVerification/pi-app-integration.json'
r=json.loads(path.read_text()) if path.exists() else {}
if r.get('run')!=run:r={'passed':False,'run':run,'error':'No report from this verification run'}
r['driverTimedOut']=timed_out
r['wholeProcessMilliseconds']=round((time.monotonic()-started)*1000,1)
r['hostBefore']=host_before
r['hostAfter']=host_state()
after=normal_state()
deadline=time.monotonic()+15
while time.monotonic()<deadline and subprocess.run(['lsof','-n','-iTCP:41789','-sTCP:LISTEN'],capture_output=True).stdout:time.sleep(.1)
r['ownedWorkerReleasedOnExit']=not bool(subprocess.run(['lsof','-n','-iTCP:41789','-sTCP:LISTEN'],capture_output=True).stdout)
r['normalStatePaths']=sorted(before[0])
r['runnerSha256']=hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest()
r['normalHistoryAndMealsUnchanged']=before[0]==after[0]
r['normalSelectionAndDraftUnchanged']=before[1]==after[1]
r['inferenceConfigurationSha256']=hashlib.sha256(config_path.read_bytes()).hexdigest()
if trace.exists():
 with trace.open('rb') as f:f.seek(trace_offset);new_trace=f.read()
 turns=[json.loads(line) for line in new_trace.splitlines() if line.strip()]
 # New builds correlate the trace with this verification run; reject mixed evidence.
 if turns and all(t.get('verificationRun')==run for t in turns):
  (reports/(name+'.model-turns.jsonl')).write_bytes(new_trace)
  r['inferenceTurns']=[{'transportMilliseconds':t.get('transportMilliseconds'),'requestBytes':t.get('requestBytes'),'usage':t['response'].get('usage'),'tools':[c['function']['name'] for c in t['response'].get('choices',[{}])[0].get('message',{}).get('tool_calls',[])]} for t in turns]
r['processExitCode']=exit_code
r['passed']=all([r.get('passed'),not timed_out,r.get('run')==run,r.get('model')=='mac-local/'+config['modelId'],r['normalHistoryAndMealsUnchanged'],r['normalSelectionAndDraftUnchanged'],exit_code==0,r['ownedWorkerReleasedOnExit']])
(reports/(name+'.json')).write_text(json.dumps(r,indent=2)+'\n')
print(json.dumps({k:v for k,v in r.items() if k!='messages'},indent=2),flush=True)
if not r['passed']:raise SystemExit(1)
