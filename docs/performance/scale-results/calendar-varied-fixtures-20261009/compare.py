import sys,json,subprocess,hashlib,time
from pathlib import Path
sys.path.insert(0,str(Path('tools').resolve()))
from performance_host import HostMonitor
out=Path('.build/calendar-varied-fix/cost');out.mkdir(exist_ok=False)
binaries={'before':Path('.build/calendar-ipad-20261009/varied-tile-checks-diagnostic'),'after':Path('.build/calendar-varied-fix/locked')}
rows=[]
with HostMonitor(out/'host.json') as host:
 for trial in range(3):
  for fixture in ['uniform-v1','varied-v1']:
   for density in [100,300]:
    for label in (['before','after'] if trial%2==0 else ['after','before']):
     name=f'{trial}-{fixture}-{density}-{label}'
     cmd=[str(binaries[label]),'--fixture',fixture,'--mode','week','--density',str(density),'--workers','2','--memory-probe','--output',str(out/(name+'.json'))]
     r=subprocess.run(cmd,capture_output=True,text=True)
     (out/(name+'.log')).write_text(r.stdout+r.stderr)
     rows.append({'name':name,'exit':r.returncode,'sha256':hashlib.sha256(binaries[label].read_bytes()).hexdigest()})
     (out/'status.json').write_text(json.dumps(rows,indent=2))
     print(name,r.returncode,flush=True)
(out/'host-verdict.json').write_text(json.dumps(host.report(),indent=2))
