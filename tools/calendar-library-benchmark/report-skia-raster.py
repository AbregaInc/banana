#!/usr/bin/env python3
"""Summarize every retained raster report, including mismatches and contended runs."""
import argparse
import importlib.util
import json
import math
from pathlib import Path
import statistics


def distribution(values):
    values = sorted(values)
    return {'count': len(values), 'median': statistics.median(values),
        'p95': values[math.ceil(len(values)*.95)-1], 'p99': values[math.ceil(len(values)*.99)-1],
        'max': max(values), 'over100': sum(v > 100 for v in values)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('matrix', type=Path)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    spec = importlib.util.spec_from_file_location('runner', Path(__file__).with_name('run-skia-raster.py'))
    runner = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(runner)
    rows = json.loads((args.matrix/'summary.json').read_text())
    samples, invalid, mismatches, contended = [], [], [], []
    for row in rows:
        seed, density, trial = map(int, row['name'].split('-'))
        path = args.matrix/row['name']/'report.json'
        if row['exitCode'] != 0 or not path.exists():
            invalid.append(row['name']); continue
        data = json.loads(path.read_text())
        status = runner.validate(data, seed, density, (trial+seed)%2 == 1)
        if status == 'invalid':
            invalid.append(row['name']); continue
        if status == 'pixel-mismatch': mismatches.append(row['name'])
        if not row['hostMonitor']['clean']: contended.append(row['name'])
        for result in data['results']:
            for sample in result['samples']:
                samples.append(dict(sample, width=result['widthPoints'], density=density, run=row['name']))
    groups = []
    for width in [393, 1366]:
        for density in [1, 100, 300]:
            for state in ['cold-raster', 'warm-reraster', 'eviction-reraster']:
                selected = [s for s in samples if (s['width'], s['density'], s['state']) == (width, density, state)]
                if not selected: continue
                groups.append({'width': width, 'density': density, 'state': state,
                    **{key: distribution([s[key] for s in selected]) for key in
                        ['coreGraphicsRasterMS', 'skiaCompletionMS', 'skiaEncodeMS', 'skiaCacheBytes', 'coreGraphicsTileBytes']}})
    expected = {f'{seed}-{density}-{trial}' for seed in [20261009, 20261010] for density in [1,100,300] for trial in range(3)}
    complete = len(rows) == 18 and {r['name'] for r in rows} == expected and not invalid
    output = {'coverageComplete': complete, 'invalidRuns': invalid, 'pixelMismatchRuns': mismatches,
        'contendedRuns': contended, 'groups': groups, 'acceptance': 'unmeasured',
        'scope': 'Component diagnostics, not integrated UI. Pixel mismatch disqualifies adoption.'}
    with args.out.open('x') as f: json.dump(output, f, indent=2); f.write('\n')
    return 1 if mismatches else 2


if __name__ == '__main__':
    raise SystemExit(main())
