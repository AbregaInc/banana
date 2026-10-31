import subprocess,sys,json
from pathlib import Path
sys.path.insert(0,str(Path('tools').resolve()))
from performance_host import HostMonitor
out=Path('.build/calendar-ipad-20261009');statuses=[]
for matrix in ['foreground-surface','foreground-accessibility']:
 command=[sys.executable,'tools/calendar-library-benchmark/run-device.py','--device','<device-udid>','--app','.build/calendar-library-touch-dd/Build/Products/Release-iphoneos/CalendarLibraryBenchmark.app','--out',str(out/matrix),'--matrix',matrix,'--foreground-navigation','--navigation-stress']
 with HostMonitor(out/(matrix+'-host.json')) as host,(out/(matrix+'-run.log')).open('w') as log:
  result=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,timeout=1800)
 statuses.append({'matrix':matrix,'exitCode':result.returncode,'command':command,'hostMonitor':host.report()})
 (out/'matrix-status.json').write_text(json.dumps(statuses,indent=2)+'\n')
 print(matrix,'exit',result.returncode,'hostClean',host.report()['clean'],flush=True)
