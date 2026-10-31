import importlib.util,sys,json,hashlib
from pathlib import Path
sys.path.insert(0,str(Path('tools/calendar-library-benchmark').resolve()))
spec=importlib.util.spec_from_file_location('runner','tools/calendar-library-benchmark/run-device.py');r=importlib.util.module_from_spec(spec);spec.loader.exec_module(r)
out=Path('.build/calendar-varied-fix/iphone-memo-paired');out.mkdir(exist_ok=False)
results=[]
for trial in range(3):
 for memo in ([False,True] if trial%2==0 else [True,False]):
  r.cases=lambda matrix:[(f'dense-300-trial{trial}',300,'tile-prefetch-async-two')]
  dest=out/f'{trial}-memo{int(memo)}'
  sys.argv=['run-device.py','--device','<device-udid>','--app','.build/calendar-library-touch-dd/Build/Products/Release-iphoneos/CalendarLibraryBenchmark.app','--out',str(dest),'--fixture','varied-v1','--matrix','foreground','--foreground-navigation','--navigation-stress']+(['--memo-raster-text'] if memo else [])
  result=r.main();results.append(dict(trial=trial,memo=memo,exit=result));(out/'status.json').write_text(json.dumps(results,indent=2))
  row=json.loads((dest/'summary.json').read_text())[0]
  print(trial,memo,row['status'],flush=True)
  if row['status'] != 'measured':raise SystemExit('Incomplete/invalid collection; stop paired timing rather than repeat blindly')
