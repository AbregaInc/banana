import subprocess,json,time,hashlib,uuid
from pathlib import Path
out=Path('.build/calendar-async-preparation/final-physical-checks');out.mkdir(exist_ok=False)
app=Path('.build/calendar-library-touch-dd/Build/Products/Release-iphoneos/CalendarLibraryBenchmark.app')
bundle='com.boris.banana.calendar-library-benchmark';device='<device-udid>'
results=[]
def run(args,required=True):
 p=subprocess.run(args,capture_output=True,text=True,timeout=60)
 with (out/'commands.log').open('a') as f:f.write(json.dumps(args)+'\n'+p.stdout+p.stderr+'\n')
 if required:p.check_returncode()
 return p
meta={'binarySHA256':hashlib.sha256((app/'CalendarLibraryBenchmark').read_bytes()).hexdigest(),'device':device,'scope':'Physical device programmatic correctness only, no input/display performance acceptance','cases':results}
try:
 run(['xcrun','devicectl','device','install','app','--device',device,str(app.resolve())])
 for density in [100,300]:
  for policy,flags in [('control',[]),('dispatch',['--foreground-dispatch']),('text',['--raster-native-text']),('combined',['--foreground-dispatch','--raster-native-text'])]:
   label=f'iphone-{density}-{policy}';filename=f'final-{uuid.uuid4()}.json';dest=out/(label+'.json')
   args=['xcrun','devicectl','device','process','launch','--device',device,'--terminate-existing',bundle,'--candidate','native','--mode','week','--days','365','--density',str(density),'--renderer','tiles','--ablation','tile-prefetch-async-surface','--async-workers','2','--check','navigation','--output',filename,*flags]
   run(args);deadline=time.monotonic()+75
   while time.monotonic()<deadline:
    time.sleep(2)
    p=run(['xcrun','devicectl','device','copy','from','--device',device,'--source','Documents/'+filename,'--domain-type','appDataContainer','--domain-identifier',bundle,'--destination',str(dest.resolve())],False)
    if p.returncode==0 and dest.exists():break
   r=json.loads(dest.read_text())
   results.append({'name':label,'flags':flags,'status':r.get('status'),'checks':r.get('checks')})
   (out/'status.json').write_text(json.dumps(meta,indent=2)+'\n')
   print(label,r.get('status'),r.get('checks'),flush=True)
   if r.get('status')!='passed' or r.get('checks')!=44:raise RuntimeError(label+' failed')
 meta['status']='passed'
except Exception as e:
 meta['status']='failed-or-incomplete';meta['error']=str(e);raise
finally:(out/'status.json').write_text(json.dumps(meta,indent=2)+'\n')
