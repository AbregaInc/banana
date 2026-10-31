#!/usr/bin/env python3
"""Paired native cache-recovery components, including cold eviction and memory.

This deliberately never returns a UI acceptance pass. Real interaction traces are
separate; API flush completion is not display delivery.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import subprocess
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from performance_host import HostMonitor


def distribution(values):
    ordered = sorted(values)
    return {"count": len(values), "p50MS": ordered[math.ceil(len(values)*.5)-1],
            "p95MS": ordered[math.ceil(len(values)*.95)-1],
            "p99MS": ordered[math.ceil(len(values)*.99)-1], "maxMS": max(values)}


def evaluate(data, density, asynchronous, dispatch=False, native_text=False):
    if not isinstance(data, dict):
        return {'status': 'invalid-or-unmeasured'}
    samples = data.get('samples', [])
    if not isinstance(samples, list) or not all(isinstance(s, dict) for s in samples):
        return {'status': 'invalid-or-unmeasured'}
    valid = (data.get('eventsPerDay') == density and
             data.get('asyncRecoveryRequested') is asynchronous and
             data.get('foregroundDispatchRequested', False) is dispatch and
             data.get('nativeTextRequested', False) is native_text and len(samples) == 21)
    for index, sample in enumerate(samples):
        valid &= sample.get('index') == index and all(sample.get(key) is True for key in
            ['completed', 'visibleIDsMatch', 'drawCoverageMatches', 'asyncSamplePresent'])
        valid &= sample.get('unexpectedSyncTileBuilds') == 0
        for key in ['responseMS', 'actionMS', 'flushMS', 'peakResidentBytes', 'physicalFootprintBytes']:
            value = sample.get(key)
            valid &= isinstance(value, (int, float)) and math.isfinite(value) and value >= 0
        sections = sample.get('mainSectionsMS', [])
        if not isinstance(sections, list):
            return {'status': 'invalid-or-unmeasured'}
        valid &= len(sections) == (5 if asynchronous else 2)
        valid &= all(isinstance(v, (int, float)) and math.isfinite(v) and v >= 0 for v in sections)
    if not valid:
        return {'status': 'invalid-or-unmeasured'}
    response = distribution([s['responseMS'] for s in samples])
    sections = distribution([v for s in samples for v in s['mainSectionsMS']])
    return dict(status='measured', response=response,
        action=distribution([s['actionMS'] for s in samples]), mainSections=sections,
        peakResidentBytes=max(s['peakResidentBytes'] for s in samples),
        maxSampledPhysicalFootprintBytes=max(s['physicalFootprintBytes'] for s in samples),
        componentBudget='fail' if response['maxMS'] > 100 or sections['maxMS'] > 8.3
                        else 'within-measured-limits-only')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--comparison', choices=['recovery', 'executor', 'native-text', 'combined'], default='recovery')
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=False)
    environment = dict(binarySHA256=hashlib.sha256(args.binary.read_bytes()).hexdigest(),
        command=sys.argv, os=subprocess.check_output(['sw_vers'], text=True),
        git=subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
        scope='Cache eviction through API flush; no UI acceptance claim')
    (args.out/'environment.json').write_text(json.dumps(environment, indent=2)+'\n')
    rows = []
    for trial in range(3):
        for density in [100, 300]:
            for enabled in ([False, True] if trial % 2 == 0 else [True, False]):
                asynchronous = args.comparison != 'recovery' or enabled
                dispatch = args.comparison in ('executor', 'combined') and enabled
                native_text = args.comparison in ('native-text', 'combined') and enabled
                label = ('dispatch' if dispatch else 'cooperative') if args.comparison == 'executor' else ('async' if asynchronous else 'sync')
                if args.comparison == 'native-text':
                    label = 'native-text' if native_text else 'prepared-text'
                if args.comparison == 'combined':
                    label = 'dispatch-native-text' if enabled else 'cooperative-prepared-text'
                name = f'{trial}-{density}-' + label
                output = args.out/(name+'.json')
                command = [str(args.binary.resolve()), '--candidate', 'native', '--renderer', 'tiles',
                    '--mode', 'week', '--days', '365', '--density', str(density),
                    '--ablation', 'tile-prefetch-async-surface', '--check', 'recovery-benchmark',
                    '--output', str(output.resolve())]
                if asynchronous:
                    command += ['--async-cache-recovery']
                if dispatch:
                    command += ['--foreground-dispatch']
                if native_text:
                    command += ['--raster-native-text']
                with HostMonitor(args.out/(name+'-host.json')) as host, (args.out/(name+'.log')).open('w') as log:
                    try:
                        code = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=120).returncode
                    except subprocess.TimeoutExpired:
                        code = 124
                row = dict(name=name, command=command, exitCode=code, hostMonitor=host.report(), status='unmeasured')
                if code == 0 and output.exists():
                    row.update(evaluate(json.loads(output.read_text()), density, asynchronous, dispatch, native_text))
                if not row['hostMonitor']['clean']:
                    row['status'] = 'invalid-or-contended'
                rows.append(row)
                (args.out/'summary.json').write_text(json.dumps(rows, indent=2)+'\n')
                print(name, row['status'], row.get('response'), flush=True)
    if any(row['status'] != 'measured' for row in rows):
        return 2
    return 1 if any(row.get('componentBudget') == 'fail' for row in rows) else 2


if __name__ == '__main__':
    raise SystemExit(main())
