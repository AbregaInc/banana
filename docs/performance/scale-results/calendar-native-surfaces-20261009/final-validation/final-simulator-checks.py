import subprocess,json,time,hashlib
from pathlib import Path
out=Path('.build/calendar-async-preparation/final-simulator-checks');out.mkdir(exist_ok=False)
app=Path('.build/calendar-library-dd/Build/Products/Release-iphonesimulator/CalendarLibraryBenchmark.app')
bundle='com.boris.banana.calendar-library-benchmark'
results=[]
def run(args):
 p=subprocess.run(args,capture_output=True,text=True,timeout=60)
 with (out/'commands.log').open('a') as f:f.write(json.dumps(args)+'\n'+p.stdout+p.stderr+'\n')
 p.check_returncode();return p.stdout.strip()
meta={'binarySHA256':hashlib.sha256((app/'CalendarLibraryBenchmark').read_bytes()).hexdigest(),'scope':'Simulator correctness only, no performance acceptance','cases':results}
try:
 for name,device in [('iphone','5829A24D-81B4-49D9-A31A-C7553C32D527'),('ipad','7CE990BF-066D-4E79-BA7F-B5F285E6A66C')]:
  run(['xcrun','simctl','install',device,str(app)])
  data=Path(run(['xcrun','simctl','get_app_container',device,bundle,'data']))/'Documents'
  for density in [100,300]:
   for policy,flags in [('control',[]),('dispatch',['--foreground-dispatch']),('text',['--raster-native-text']),('combined',['--foreground-dispatch','--raster-native-text'])]:
    label=f'{name}-{density}-{policy}';filename=f'final-{label}.json';dest=data/filename
    args=['xcrun','simctl','launch','--terminate-running-process',device,bundle,'--candidate','native','--mode','week','--days','365','--density',str(density),'--renderer','tiles','--ablation','tile-prefetch-async-surface','--async-workers','2','--check','navigation','--output',filename,*flags]
    run(args);deadline=time.monotonic()+75
    while not dest.exists() and time.monotonic()<deadline:time.sleep(.5)
    r=json.loads(dest.read_text());(out/(label+'.json')).write_text(json.dumps(r,indent=2)+'\n')
    results.append({'name':label,'device':device,'flags':flags,'status':r.get('status'),'checks':r.get('checks')})
    (out/'status.json').write_text(json.dumps(meta,indent=2)+'\n')
    print(label,r.get('status'),r.get('checks'),flush=True)
    if r.get('status')!='passed' or r.get('checks')!=44:raise RuntimeError(label+' failed')
  run(['xcrun','simctl','terminate',device,bundle])
 meta['status']='passed'
except Exception as e:
 meta['status']='failed-or-incomplete';meta['error']=str(e);raise
finally:(out/'status.json').write_text(json.dumps(meta,indent=2)+'\n')
