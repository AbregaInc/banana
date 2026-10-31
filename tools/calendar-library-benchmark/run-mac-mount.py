#!/usr/bin/env python3
"""Fresh-process native mount ablation. API completion is not launch-to-visible latency."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import subprocess
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from performance_host import HostMonitor


def valid_timings(data):
    """Malformed timing evidence must not be reported within component limits."""
    if not isinstance(data, dict):
        return False
    values = [data.get(key) for key in ['responseMS', 'maxMainSectionMS', 'setupMS']]
    sections = data.get('mainSectionsMS')
    if not isinstance(sections, list) or not sections:
        return False
    finite = all(type(value) in (int, float) and math.isfinite(value) and value >= 0
                 for value in values + sections)
    return finite and math.isclose(data['maxMainSectionMS'], max(sections), rel_tol=1e-9,
                                   abs_tol=1e-9) and data['responseMS'] >= data['setupMS']


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary',type=Path,required=True)
    parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--ablation',default='tile-prefetch-async-surface',choices=['tile-prefetch-async-surface','tile-prefetch-async-surface-properties'])
    args=parser.parse_args(); args.out.mkdir(parents=True,exist_ok=False)
    environment=dict(binarySHA256=hashlib.sha256(args.binary.read_bytes()).hexdigest(),
        ablation=args.ablation, command=sys.argv, os=subprocess.check_output(['sw_vers'],text=True),
        git=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
        scope='Fresh-process controller mount; excludes fixture generation; not input/display acceptance')
    (args.out/'environment.json').write_text(json.dumps(environment,indent=2)+'\n')
    rows=[]
    for trial in range(3):
        for density in [100,300]:
            for workers in ([0,2] if trial%2==0 else [2,0]):
                name=f'{trial}-{density}-{workers}workers'; output=args.out/(name+'.json')
                command=[str(args.binary.resolve()),'--candidate','native','--renderer','tiles','--mode','week',
                    '--days','365','--density',str(density),'--ablation',args.ablation,'--check','mount',
                    '--mount-workers',str(workers),'--output',str(output.resolve())]
                with HostMonitor(args.out/(name+'-host.json')) as host:
                    with (args.out/(name+'.log')).open('w') as log:
                        try: code=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,timeout=60).returncode
                        except subprocess.TimeoutExpired: code=124
                row=dict(name=name,exitCode=code,command=command,hostMonitor=host.report(),status='unmeasured')
                if code==0 and output.exists():
                    data=json.loads(output.read_text())
                    valid=valid_timings(data) and data.get('phase')=='processColdMount' and data.get('eventsPerDay')==density and data.get('workers')==workers \
                        and data.get('ablation')==args.ablation and all(data.get(k) is True for k in ['completed','visibleIDsMatch','drawCoverageMatches','requestedDateMatches']) \
                        and (workers==0 or data.get('unexpectedSyncTileBuilds')==0)
                    row['status']='measured' if valid and row['hostMonitor']['clean'] else 'invalid-or-contended'
                    if valid_timings(data):
                        row['responseMS']=data['responseMS'];row['maxMainSectionMS']=data['maxMainSectionMS']
                        row['componentBudget']='fail' if data['responseMS']>100 or data['maxMainSectionMS']>8.3 else 'within-measured-limits-only'
                rows.append(row);(args.out/'summary.json').write_text(json.dumps(rows,indent=2)+'\n')
                print(name,row['status'],row.get('responseMS'),flush=True)
    return 1 if any(row['status']!='measured' or row.get('componentBudget')=='fail' for row in rows) else 2


if __name__=='__main__':raise SystemExit(main())
