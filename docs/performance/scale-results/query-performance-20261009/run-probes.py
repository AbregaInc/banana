from pathlib import Path
import subprocess,sys,json
sys.path.insert(0,str(Path('tools').resolve()))
from performance_host import HostMonitor
root=Path.cwd();out=root/'.build/query-performance-20261009';target=out/'statement-pairs';target.mkdir(exist_ok=False)
rows=[]
with HostMonitor(target/'host.json') as host:
 for trial in range(3):
  for policy in (['uncached','cached'] if trial%2==0 else ['cached','uncached']):
   name=f'{trial}-{policy}'
   cmd=['xcrun','simctl','spawn','5829A24D-81B4-49D9-A31A-C7553C32D527',str(out/'statement-cache'),str(out/'podcast-catalog.sqlite'),policy,str(target/(name+'.json')),'7']
   r=subprocess.run(cmd,capture_output=True,text=True);(target/(name+'.log')).write_text(r.stdout+r.stderr);rows.append(dict(command=cmd,exit=r.returncode));(target/'status.json').write_text(json.dumps(rows,indent=2));r.check_returncode();print(name,flush=True)
with HostMonitor(out/'notes-trigram-host.json'):
 subprocess.run(['python3','tools/performance/notes-trigram-probe.py','--database',str(out/'notes.sqlite'),'--out',str(out/'notes-trigram')],check=True)
print('notes probe complete',flush=True)
subprocess.run(['python3',str(out/'paired.py')],check=True)
