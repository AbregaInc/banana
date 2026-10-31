from pathlib import Path
import subprocess,json,hashlib,shutil,sys
sys.path.insert(0,'tools')
from performance_host import HostMonitor
out=Path('.build/notes-first-use-20261010').resolve();device='7531F6E1-402A-43B8-8418-EFB258F8598D';source=Path('.build/calendar-neighbors-20261010/failed-notes.sqlite').resolve()
subprocess.run(['xcrun','simctl','boot',device],check=True,capture_output=True)
subprocess.run(['xcrun','simctl','bootstatus',device,'-b'],check=True,capture_output=True)
cases=[]
with HostMonitor(out/'host.json'):
 for i,policy in enumerate(['original','instrumented','prewarm','prewarm','instrumented','original']):
  db=out/f'{i}-notes.sqlite';shutil.copy2(source,db)
  output=out/f'{i}-{policy}.json';cmd=['xcrun','simctl','spawn',device,str(out/'probe'),str(db),str(output),policy]
  r=subprocess.run(cmd,capture_output=True,text=True,timeout=120);(out/f'{i}-{policy}.log').write_text(r.stdout+r.stderr)
  cases.append({'policy':policy,'command':cmd,'exit':r.returncode});(out/'commands.json').write_text(json.dumps(cases,indent=2)+'\n')
  print(i,policy,r.returncode,flush=True);r.check_returncode()
reports=[json.loads((out/f'{i}-{p}.json').read_text()) for i,p in enumerate(['original','instrumented','prewarm','prewarm','instrumented','original'])]
expected=reports[0]['snapshots'][0]
for r in reports:
 for s in r['snapshots']:assert s['total']==expected['total'] and s['ids']==expected['ids']
(out/'parity.json').write_text(json.dumps({'checks':42,'total':expected['total'],'rows':len(expected['ids']),'passed':True},indent=2)+'\n')
subprocess.run(['xcrun','simctl','shutdown',device],check=True,capture_output=True)
print('42 exact count/order checks passed; Simulator shut down.',flush=True)
