#!/usr/bin/env python3
"""Retained offscreen Metal/CG comparison; never certifies displayed UI latency."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import subprocess
import sys
from collections import Counter
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from performance_host import HostMonitor


def valid_report(data, seed, density, source):
    try:
        valid = (data['textureSource'] == source and data['fixture']['seed'] == str(seed)
            and data['fixture']['meanDailyEvents'] == density and data['fixture']['calendarCount'] == 12
            and data['fixture']['retainedEvents'] == 365 * density
            and {(c['widthPoints'], c['scale']) for c in data['results']} == {(393, 3), (1366, 2)}
            and len(data['results']) == 2)
        for case in data['results']:
            expected = Counter((trial, state, offset) for trial in range(3)
                        for state in ['cold-upload', 'warm', 'eviction-reupload'] for offset in [0, 128 * case['scale'], 256 * case['scale'], 0])
            samples = case['samples']
            valid &= len(samples) == 36 and Counter((s['trial'], s['state'], s['offsetPixels']) for s in samples) == expected
            for sample in samples:
                valid &= 0 <= sample['maxChannelDifference'] <= 1
                values = [sample['uploadMS'], sample['cpuCompositeMS'],
                    *[sample['metal'][key] for key in ['encodeSubmitMS', 'completionMS', 'gpuMS']]]
                valid &= all(isinstance(v, (int, float)) and math.isfinite(v) and v >= 0 for v in values)
        return valid
    except (KeyError, TypeError, ValueError):
        return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--comparison', choices=['original', 'surfaces'], default='original')
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=False)
    root = Path(__file__).resolve().parent
    metadata = {'binarySHA256': hashlib.sha256(args.binary.read_bytes()).hexdigest(),
        'sourceSHA256': {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted([*root.glob('Shared/*.swift'), root / 'MetalTests/main.swift'])},
        'os': subprocess.check_output(['sw_vers'], text=True),
        'scope': 'Offscreen component experiment, not CALayer-versus-Metal presentation or device acceptance'}
    (args.out / 'environment.json').write_text(json.dumps(metadata, indent=2) + '\n')
    rows = []
    cases = []
    for seed in [20261009, 20261010]:
        for density in [1, 100, 300]:
            if args.comparison == 'original':
                cases.append((seed, density, 0, 'cgimage-copy'))
            else:
                for trial in range(3):
                    sources = ['surface-copy', 'surface-shared'] if trial % 2 == 0 else ['surface-shared', 'surface-copy']
                    cases.extend((seed, density, trial, source) for source in sources)
    for seed, density, trial, source in cases:
        name = f'{seed}-{density}-{trial}-{source}'
        output = args.out / (name + '.json')
        command = ['/usr/bin/time', '-l', str(args.binary.resolve()), '--fixture', 'varied-v1',
            '--seed', str(seed), '--days', '365', '--density', str(density), '--mode', 'week',
            '--texture-source', source, '--out', str(output)]
        with HostMonitor(args.out / (name + '-host.json')) as host, (args.out / (name + '.log')).open('w') as log:
            try:
                code = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=180).returncode
            except subprocess.TimeoutExpired:
                code = 124
        row = {'name': name, 'command': command, 'exitCode': code, 'hostMonitor': host.report(), 'status': 'unmeasured'}
        if code == 0 and output.exists():
            data = json.loads(output.read_text())
            valid = valid_report(data, seed, density, source)
            row['status'] = 'measured-components' if valid and row['hostMonitor']['clean'] else 'invalid-or-contended'
        rows.append(row)
        (args.out / 'summary.json').write_text(json.dumps(rows, indent=2) + '\n')
        print(name, row['status'], flush=True)
    return 2


if __name__ == '__main__':
    raise SystemExit(main())
