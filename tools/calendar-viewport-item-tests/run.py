#!/usr/bin/env python3
"""Compile the real viewport descriptor helpers on Mac, without UIKit or the service graph."""
from pathlib import Path
import argparse,subprocess,json
root=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--out',required=True,type=Path);a=p.parse_args();a.out.mkdir(parents=True,exist_ok=False)
s=(root/'Banana/Views/CalendarDayCollectionView.swift').read_text()
body=s.split('struct CalendarViewportItem {',1)[1].split('private final class CalendarFixedFrameCell:',1)[0]
source='import SwiftUI\nimport Foundation\nstruct CalendarViewportItem {'+body+(Path(__file__).parent/'main.swift').read_text()
(a.out/'main.swift').write_text(source)
cmd=['swiftc','-O',str(a.out/'main.swift'),'-o',str(a.out/'checks')]
with (a.out/'build.log').open('w') as f:r=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT)
result={'command':cmd,'buildExit':r.returncode}
if not r.returncode:
 with (a.out/'run.log').open('w') as f:r=subprocess.run([str((a.out/'checks').resolve()),str((a.out/'report.json').resolve())],stdout=f,stderr=subprocess.STDOUT)
 result['runExit']=r.returncode
(a.out/'command.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result));raise SystemExit(r.returncode)
