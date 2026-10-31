import subprocess,json
from pathlib import Path
root=Path('.build/calendar-async-preparation');out=root/'combined-correctness';out.mkdir(exist_ok=False)
rows=[]
for density in [100,300]:
 for check in ['interactive-recovery','navigation','pixels']:
  name=f'{density}-{check}'
  binary=root/('AsyncTileTextCompositionChecks' if check=='pixels' else 'MacTextCompositionBenchmark')
  cmd=[str(binary),'--mode','week','--days','365','--density',str(density),'--renderer','tiles','--ablation','tile-prefetch-async-surface','--foreground-dispatch','--raster-native-text','--output',str(out/(name+'.json'))]
  if check!='pixels':cmd+=['--check',check,'--async-cache-recovery']
  with (out/(name+'.log')).open('w') as f:code=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT,timeout=90).returncode
  data=json.loads((out/(name+'.json')).read_text())
  row={'name':name,'command':cmd,'exitCode':code,'status':data.get('status'),'checks':data.get('checks')};rows.append(row)
  (out/'status.json').write_text(json.dumps(rows,indent=2)+'\n');print(row['name'],row['status'],row['checks'],flush=True)
  if code or data.get('status')!='passed':raise SystemExit(1)
