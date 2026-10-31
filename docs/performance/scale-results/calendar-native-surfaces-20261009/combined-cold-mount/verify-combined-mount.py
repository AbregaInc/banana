import subprocess,json,hashlib,sys
from pathlib import Path
sys.path.insert(0,str(Path('tools').resolve()))
from performance_host import HostMonitor
root=Path('.build/calendar-async-preparation');out=root/'combined-cold-mount';out.mkdir(exist_ok=False)
binary=root/'MacTextCompositionBenchmark';rows=[]
(out/'environment.json').write_text(json.dumps({'binarySHA256':hashlib.sha256(binary.read_bytes()).hexdigest(),'scope':'Paired fresh-process native mount components; not launch-to-visible or display timing'},indent=2)+'\n')
for trial in range(3):
 for density in [100,300]:
  for combined in ([False,True] if trial%2==0 else [True,False]):
   name=f'{trial}-{density}-'+('combined' if combined else 'control');target=out/(name+'.json')
   cmd=[str(binary),'--mode','week','--days','365','--density',str(density),'--renderer','tiles','--ablation','tile-prefetch-async-surface','--check','mount','--mount-workers','2','--output',str(target)]
   if combined:cmd+=['--foreground-dispatch','--raster-native-text']
   with HostMonitor(out/(name+'-host.json')) as host,(out/(name+'.log')).open('w') as f:code=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT,timeout=60).returncode
   data=json.loads(target.read_text())
   valid=code==0 and data.get('phase')=='processColdMount' and data.get('eventsPerDay')==density and data.get('workers')==2 and all(data.get(k) is True for k in ['completed','visibleIDsMatch','drawCoverageMatches','requestedDateMatches']) and data.get('unexpectedSyncTileBuilds')==0
   row={'name':name,'command':cmd,'exitCode':code,'valid':valid,'hostClean':host.report()['clean'],'responseMS':data['responseMS'],'mainSectionMS':data['maxMainSectionMS'],'setupMS':data['setupMS']};rows.append(row)
   (out/'summary.json').write_text(json.dumps(rows,indent=2)+'\n');print(name,valid,row['hostClean'],round(row['responseMS'],2),round(row['mainSectionMS'],2),flush=True)
   if not valid:raise SystemExit(1)
