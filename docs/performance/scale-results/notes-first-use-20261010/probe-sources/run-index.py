from pathlib import Path
import shutil,subprocess,sys,json
sys.path.insert(0,'tools')
from performance_host import HostMonitor
out=Path('.build/notes-first-use-20261010').resolve();dev='7531F6E1-402A-43B8-8418-EFB258F8598D'
for name in ['index-reference.sqlite','index-candidate.sqlite']:
 p=out/name;assert not p.exists();shutil.copy2('.build/calendar-neighbors-20261010/failed-notes.sqlite',p)
subprocess.run(['xcrun','simctl','boot',dev],check=True,capture_output=True)
subprocess.run(['xcrun','simctl','bootstatus',dev,'-b'],check=True,capture_output=True)
cmd=['xcrun','simctl','spawn',dev,str(out/'index-probe'),str(out/'index-reference.sqlite'),str(out/'index-candidate.sqlite'),str(out/'index-report.json')]
with HostMonitor(out/'index-host.json'):
 with (out/'index-run.log').open('w') as f:r=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT,timeout=180)
(out/'index-exit.json').write_text(json.dumps({'command':cmd,'exit':r.returncode,'databaseBytes':{n:(out/n).stat().st_size for n in ['index-reference.sqlite','index-candidate.sqlite']}},indent=2)+'\n')
subprocess.run(['xcrun','simctl','shutdown',dev],check=True,capture_output=True)
print('index probe',r.returncode,flush=True)
raise SystemExit(r.returncode)
