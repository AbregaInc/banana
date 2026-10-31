import subprocess,json,sys
from pathlib import Path
sys.path.insert(0,str(Path('tools').resolve()))
from performance_host import HostMonitor
out=Path('.build/query-performance-20261009/paired');out.mkdir(exist_ok=False)
apps={'control':'.build/query-performance-20261009/control.app','cached':'.build/calendar-varied-fix/app-regression/derived-data/Build/Products/Release-iphonesimulator/Banana.app'}
rows=[]
for trial in range(3):
 for variant in (['control','cached'] if trial%2==0 else ['cached','control']):
  name=f'{trial}-{variant}';dest=out/name
  with HostMonitor(out/(name+'-host.json')) as host:
   r=subprocess.run(['python3','tools/scale-stress.py','--device','5829A24D-81B4-49D9-A31A-C7553C32D527','--app',apps[variant],'--days','90','--out',str(dest),'--label',variant],capture_output=True,text=True)
  (out/(name+'.log')).write_text(r.stdout+r.stderr)
  rows.append(dict(trial=trial,variant=variant,exit=r.returncode,host=host.report()))
  (out/'status.json').write_text(json.dumps(rows,indent=2));print(name,r.returncode,flush=True)
  if not list(dest.glob('*90d.json')):raise SystemExit('Missing measurement: retain and stop')
