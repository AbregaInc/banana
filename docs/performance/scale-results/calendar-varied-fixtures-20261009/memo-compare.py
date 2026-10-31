import sys,json,subprocess,hashlib
from pathlib import Path
sys.path.insert(0,str(Path('tools').resolve()))
from performance_host import HostMonitor
out=Path('.build/calendar-varied-fix/memo-cost');out.mkdir(exist_ok=False)
binary=Path('.build/calendar-varied-fix/memo-async');rows=[]
with HostMonitor(out/'host.json') as host:
 for trial in range(3):
  for fixture in ['uniform-v1','varied-v1']:
   for density in [100,300]:
    for workers in [1,2]:
     for memo in ([False,True] if trial%2==0 else [True,False]):
      name=f'{trial}-{fixture}-{density}-workers{workers}-memo{int(memo)}'
      cmd=[str(binary),'--fixture',fixture,'--mode','week','--density',str(density),'--workers',str(workers),'--memory-probe','--output',str(out/(name+'.json'))]
      if memo:cmd+=['--memo-raster-text']
      r=subprocess.run(cmd,capture_output=True,text=True)
      (out/(name+'.log')).write_text(r.stdout+r.stderr)
      rows.append({'name':name,'exit':r.returncode,'command':cmd,'sha256':hashlib.sha256(binary.read_bytes()).hexdigest()})
      (out/'status.json').write_text(json.dumps(rows,indent=2));print(name,r.returncode,flush=True)
(out/'host-verdict.json').write_text(json.dumps(host.report(),indent=2))
