#!/usr/bin/env python3
"""Same-stage direct/recorded/zero-budget pixel oracle on unchanged calendar workloads."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary',type=Path,required=True)
    parser.add_argument('--out',type=Path,required=True)
    args=parser.parse_args(); args.out.mkdir(parents=True,exist_ok=False)
    root=Path(__file__).resolve().parent
    spec=importlib.util.spec_from_file_location('raster',root/'run-skia-raster.py')
    raster=importlib.util.module_from_spec(spec); spec.loader.exec_module(raster)
    (args.out/'identity.json').write_text(json.dumps({'binarySHA256':hashlib.sha256(args.binary.read_bytes()).hexdigest(),
        'sources':{str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in root.glob('SkiaTests/*') if p.is_file()},
        'scope':'Pixel/lifecycle correctness only, no timing claims'},indent=2)+'\n')
    runs=[]; pairs=[]
    for seed in [20261009,20261010]:
        for density in [1,100,300]:
            for variant,flags in [('direct',[]),('pictures',['--reuse-pictures']),('zero-budget',['--reuse-pictures','--picture-cache-bytes','0'])]:
                name=f'{seed}-{density}-{variant}'; out=args.out/name
                command=[str(args.binary.resolve()),'--fixture','varied-v1','--mode','week','--days','365',
                    '--seed',str(seed),'--density',str(density),'--cg-paths','--all-phase-images','--out',str(out),*flags]
                with (args.out/(name+'.log')).open('w') as log:
                    try: code=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,timeout=180).returncode
                    except subprocess.TimeoutExpired: code=124
                valid=False
                if code==0 and (out/'report.json').exists():
                    data=json.loads((out/'report.json').read_text())
                    valid=raster.validate(data,seed,density,False,True,True,variant!='direct')!='invalid'
                    if variant=='zero-budget': valid &= data['pictureLimit']==0
                runs.append({'name':name,'command':command,'exitCode':code,'validCoverage':valid})
            direct=args.out/f'{seed}-{density}-direct'
            for variant in ['pictures','zero-budget']:
                for width in [393,1366]:
                    for state in ['', 'warm-reraster-', 'eviction-reraster-']:
                        for tile in range(4):
                            file=f'{state}skia-{width}-{tile}.png'
                            a=direct/file; b=args.out/f'{seed}-{density}-{variant}'/file
                            pairs.append({'control':str(a),'candidate':str(b),'identicalPNG':a.exists() and b.exists()
                                and hashlib.sha256(a.read_bytes()).digest()==hashlib.sha256(b.read_bytes()).digest()})
            result={'runs':runs,'pairs':pairs,'passed':len(runs)==18 and all(r['validCoverage'] for r in runs)
                and len(pairs)==288 and all(p['identicalPNG'] for p in pairs),
                'scope':'Same-stage Skia recording/cache correctness only; native parity and UI acceptance remain unmeasured'}
            (args.out/'summary.json').write_text(json.dumps(result,indent=2)+'\n')
            print(seed,density,'identical',sum(p['identicalPNG'] for p in pairs),'/',len(pairs),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__': raise SystemExit(main())
