#!/usr/bin/env python3
"""Retain all timing tails, coverage, color/edge mismatches and cached/direct comparisons."""
import argparse
from collections import Counter
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import statistics


def module(name, file):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(file))
    result = importlib.util.module_from_spec(spec); spec.loader.exec_module(result); return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('matrix', type=Path)
    parser.add_argument('--out', required=True, type=Path)
    args = parser.parse_args()
    runner = module('ablation', 'run-skia-ablation.py')
    stats = module('stats', 'report-skia-raster.py').distribution
    rows = json.loads((args.matrix/'summary.json').read_text())
    expected = {f'{seed}-{density}-{trial}-{variant}' for seed in [20261009,20261010]
        for density in [1,100,300] for trial in range(3) for variant in runner.VARIANTS}
    records, invalid, mismatches, contention, rss = [], [], [], [], []
    for row in rows:
        seed, density, trial = map(int, row['name'].split('-')[:3]); variant = row['variant']
        report = args.matrix/row['name']/'report.json'
        if row['exitCode'] != 0 or not report.exists(): invalid.append(row['name']); continue
        data = json.loads(report.read_text())
        status = runner.raster.validate(data, seed, density, (seed+trial)%2 == 1, *runner.VARIANTS[variant][:3])
        if status == 'invalid': invalid.append(row['name']); continue
        if status == 'pixel-mismatch': mismatches.append(row['name'])
        if not row['hostMonitor']['clean']: contention.append(row['name'])
        match = re.search(r'(\d+)\s+maximum resident set size', (args.matrix/(row['name']+'.log')).read_text())
        if match: rss.append({'variant': variant, 'bytes': int(match[1])})
        for result in data['results']:
            for sample in result['samples']:
                records.append(dict(sample, width=result['widthPoints'], density=density, variant=variant, name=row['name']))
    groups = []
    for variant in runner.VARIANTS:
        for width in [393,1366]:
            for density in [1,100,300]:
                for state in ['cold-raster','warm-reraster','eviction-reraster']:
                    selected = [s for s in records if (s['variant'],s['width'],s['density'],s['state']) == (variant,width,density,state)]
                    if not selected: continue
                    pixels = [p for s in selected for p in s['pixels']]
                    groups.append({'variant':variant,'width':width,'density':density,'state':state,
                        **{key:stats([s[key] for s in selected]) for key in ['skiaCompletionMS','skiaEncodeMS','coreGraphicsRasterMS','pictureBytes','skiaCacheBytes']},
                        'nativeMAE':stats([p['meanAbsoluteChannelDifference'] for p in pixels]),
                        'nativeMaxChannelDifference':max(p['maxChannelDifference'] for p in pixels),
                        'phaseMaxChannelDifference':max(p['skiaPhaseMaxDifference'] for p in pixels)})
    pairs = []
    for pictures in sorted(args.matrix.glob('*-pictures')):
        direct = Path(str(pictures).removesuffix('-pictures')+'-paths')
        for image in sorted(pictures.glob('skia-*.png')):
            control = direct/image.name
            pairs.append({'picture':str(image),'control':str(control),'identicalPNG':control.exists()
                and hashlib.sha256(image.read_bytes()).digest() == hashlib.sha256(control.read_bytes()).digest()})
    output = {'coverageComplete':len(rows)==72 and {r['name'] for r in rows}==expected and not invalid,
        'invalidRuns':invalid,'pixelMismatchRuns':mismatches,'contendedRuns':contention,
        'groups':groups,'coldPicturePairs':pairs,'rss':rss,'acceptance':'unmeasured',
        'scope':'Diagnostic component ablations. Native pixel mismatch remains an adoption failure.'}
    with args.out.open('x') as f: json.dump(output,f,indent=2); f.write('\n')
    return 1 if mismatches else 2


if __name__ == '__main__': raise SystemExit(main())
