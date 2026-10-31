#!/usr/bin/env python3
"""Test the actual native Week header delivery policy without UIKit or the app graph."""
from pathlib import Path
import argparse,subprocess,json
root=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--out',type=Path,required=True);a=p.parse_args();a.out.mkdir(parents=True,exist_ok=False)
s=(root/'Banana/Views/WeekView.swift').read_text().split('// MARK: Header offset delivery',1)[1].split('// MARK: Selected column geometry',1)[0]
s=s.replace('private func sendHorizontalOffset','func sendHorizontalOffset')
source='import Foundation\nstruct Week { let onHorizontalOffset: (CGFloat) -> Void }\nfinal class Harness { var week: Week?\n'+s+'\n}\n'+(Path(__file__).parent/'main.swift').read_text()
(a.out/'main.swift').write_text(source)
cmd=['swiftc','-O',str(a.out/'main.swift'),'-o',str(a.out/'checks')]
with (a.out/'build.log').open('w') as f:r=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT)
result={'command':cmd,'buildExit':r.returncode}
if not r.returncode:
 with (a.out/'run.log').open('w') as f:r=subprocess.run([str((a.out/'checks').resolve()),str((a.out/'report.json').resolve())],stdout=f,stderr=subprocess.STDOUT)
 result['runExit']=r.returncode
(a.out/'command.json').write_text(json.dumps(result,indent=2));print(json.dumps(result));raise SystemExit(r.returncode)
