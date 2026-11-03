#!/usr/bin/env python3
"""Run an isolated, local-only iOS action-capture benchmark and preserve correlated output."""
import argparse,hashlib,json,pathlib,plistlib,subprocess,tempfile,time,uuid
p=argparse.ArgumentParser()
p.add_argument('device');p.add_argument('app',type=pathlib.Path);p.add_argument('backend')
p.add_argument('--model',type=pathlib.Path);p.add_argument('--output',type=pathlib.Path,required=True)
p.add_argument('--manifest',type=pathlib.Path)
p.add_argument('--cases',default='');p.add_argument('--repeats',type=int,default=2)
a=p.parse_args()
bundle=plistlib.loads((a.app/'Info.plist').read_bytes())['CFBundleIdentifier']
if not bundle.endswith('.pi-model-bench'):p.error('Only the separate PiModelBench app may be installed')
if a.backend!='apple' and not a.model:p.error('A local model directory is required')
if a.model and not a.manifest:p.error('A pinned model manifest is required')
if not a.backend.isalnum():p.error('Use an alphanumeric backend name')
manifest=None
if a.model:
 manifest=json.loads(a.manifest.read_text())
 for name,expected in manifest['files'].items():
  if pathlib.PurePosixPath(name).name!=name:p.error('Manifest paths must be flat file names')
  local=a.model/name
  if hashlib.sha256(local.read_bytes()).hexdigest()!=expected['sha256']:p.error('Model digest mismatch: '+name)
run=str(uuid.uuid4())
def command(parts,check=True,timeout=60):
 r=subprocess.run(['xcrun','devicectl',*parts],capture_output=True,text=True,timeout=timeout)
 if check and r.returncode:raise RuntimeError(r.stdout+r.stderr)
 return r
command(['device','install','app','--device',a.device,str(a.app)],timeout=120)
if a.model:
 command(['device','copy','to','--device',a.device,'--source',str(a.model),'--destination','Documents/models/'+a.backend,'--domain-type','appDataContainer','--domain-identifier',bundle],timeout=150)
command(['device','process','launch','--device',a.device,'--terminate-existing',bundle,'--','--run','--backend',a.backend,'--run-id',run,'--cases',a.cases,'--repeats',str(a.repeats)])
with tempfile.TemporaryDirectory(prefix='pi-model-bench-') as tmp:
 dest=pathlib.Path(tmp)/'results.json';deadline=time.monotonic()+360;last=-1
 while time.monotonic()<deadline:
  copied=command(['device','copy','from','--device',a.device,'--source','Documents/results.json','--destination',str(dest),'--domain-type','appDataContainer','--domain-identifier',bundle],check=False)
  if copied.returncode==0:
   try:r=json.loads(dest.read_text())
   except (ValueError,OSError):r={}
   if r.get('run')==run:
    count=len(r.get('results',[]))
    if count!=last:print(f'{a.backend}: {count} cases complete',flush=True);last=count
    if r.get('complete'):
     r['physicalDeviceUDID']=a.device
     if manifest:r['modelManifest']=manifest
     a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(r,indent=2)+'\n')
     print(json.dumps({k:v for k,v in r.items() if k!='results'},indent=2),flush=True)
     if r.get('error'):raise SystemExit(1)
     break
  time.sleep(2)
 else:raise TimeoutError('No completed report for this run within 360 seconds')
