#!/usr/bin/env python3
"""Compare stock/slim simulator footprint and unchanged component workloads with one app binary.
Run under tools/agents/xcode-lock.sh -l sim-phone -d .build/sim; no app build or baseline updates.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'tools'))
from performance_host import HostMonitor


def run(args, **kwargs):
    return subprocess.run(args, cwd=ROOT, text=True, check=True, timeout=1200, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--order', choices=['stock,slim', 'slim,stock'], default='stock,slim')
    args = parser.parse_args()
    args.app = args.app.resolve()
    args.out = args.out.resolve()
    args.out.mkdir(parents=True, exist_ok=False)
    spec = importlib.util.spec_from_file_location('gate', ROOT/'tools/performance-regression.py')
    gate = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(gate)
    policy = json.loads(gate.POLICY.read_text())
    env = dict(os.environ, SIMULATOR_UDID=args.device)
    (args.out/'baseline-policy.json').write_text(json.dumps(policy, indent=2)+'\n')
    summaries = {}
    for mode in args.order.split(','):
        folder = args.out/mode
        folder.mkdir()
        # Both phases start a new boot with the same installed app/data. No app
        # process may inflate one idle footprint while the other's reboot killed it.
        subprocess.run(['xcrun', 'simctl', 'shutdown', args.device], cwd=ROOT, capture_output=True, timeout=120)
        prepared = time.monotonic()
        run(['tools/simulator-run.sh', 'phone', mode, str(folder/'simulator')], env=env)
        preparation_seconds = time.monotonic()-prepared
        # Footprint is measured after the same timed idle period on both boots.
        time.sleep(30)
        footprint = []
        for sample in range(3):
            footprint.append(json.loads(run(['simslim', 'measure', args.device, '--json'], capture_output=True).stdout))
            if sample < 2:
                time.sleep(5)
        (folder/'footprint.json').write_text(json.dumps(footprint, indent=2)+'\n')
        cases = {}
        for case in policy['cases']:
            print(f'{mode}: {case["name"]}', flush=True)
            started = time.monotonic()
            with HostMonitor(folder/f'{case["name"]}-host.json') as host, (folder/f'{case["name"]}.log').open('w') as log:
                run([sys.executable, 'tools/scale-stress.py', '--device', args.device, '--app', str(args.app),
                     '--days', str(case['days']), '--route', case['route'], '--idle-seconds', '10' if case['redraw'] else '0',
                     '--out', str(folder), '--label', case['name'], '--max-memory-mb', str(policy['memoryCeilingMB']), '--allow-failures'], stdout=log, stderr=log)
            report = json.loads((folder/f'{case["name"]}-{case["days"]}d.json').read_text())
            report.update(hostMonitor=host.report(), wallSeconds=time.monotonic()-started)
            cases[case['name']] = report
            (folder/'cases.json').write_text(json.dumps(cases, indent=2)+'\n')
        summaries[mode] = dict(preparationSeconds=preparation_seconds, footprint=footprint, cases=cases)
    stock, slim = summaries['stock']['cases'], summaries['slim']['cases']
    comparisons = {}
    for name in stock:
        if stock[name]['binarySHA256'] != slim[name]['binarySHA256']:
            raise ValueError('comparison changed app binaries')
        comparisons[name] = gate.compare_case(stock[name], slim[name], policy, next(c['redraw'] for c in policy['cases'] if c['name']==name))
    failed = any(comparisons.values()) or any(not case['passed'] or not case['hostMonitor']['clean'] for cases in [stock, slim] for case in cases.values())
    result = dict(scope='Simulator comparison only; not baseline or physical UI acceptance', failed=failed, order=args.order, runs=summaries, regressions=comparisons)
    (args.out/'comparison.json').write_text(json.dumps(result, indent=2)+'\n')
    print(f'Complete: {args.out}/comparison.json (comparison only; failures={failed})')
    return 1 if failed else 0


if __name__ == '__main__':
    raise SystemExit(main())
