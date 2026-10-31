#!/usr/bin/env python3
"""Persistent Simulator component gate. See docs/performance/regression-testing.md."""
import argparse
import datetime
import json
import math
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from performance_host import HostMonitor

ROOT = Path(__file__).resolve().parents[1]
POLICY = ROOT / 'docs/performance/regression-baseline.json'


def number(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
        raise ValueError('measurement must be finite and nonnegative')
    return value


def compare_case(base, new, policy, redraw=False):
    failures = []
    for key in ('schemaVersion', 'platform', 'days', 'emails', 'events', 'notes', 'podcasts', 'episodes'):
        if key not in new or new[key] != base[key]:
            raise ValueError(f'incomparable workload: {key}')
    def metrics(report):
        items = report['metrics']
        result = {m['name']: m for m in items}
        if len(result) != len(items) or not result:
            raise ValueError('missing or duplicate metrics')
        return result
    before, after = metrics(base), metrics(new)
    if before.keys() != after.keys():
        raise ValueError('metric coverage changed; review the baseline explicitly')
    for name, old in before.items():
        current = after[name]
        if 'samplesMS' in current:
            samples = sorted(number(value) for value in current['samplesMS'])
            if len(samples) != 7 or not math.isclose(samples[3], current['medianMS'], abs_tol=1e-9) or not math.isclose(samples[6], current['p95MS'], abs_tol=1e-9):
                raise ValueError(f'{name}: raw samples do not match the seven-sample summary')
        if current['checksum'] != old['checksum'] or current['budgetMS'] != old['budgetMS']:
            raise ValueError(f'{name}: changed correctness checksum or budget')
        for field, tolerance in policy['latencyTolerance'].items():
            b, n = number(old[field]), number(current[field])
            margin = max(tolerance['floorMS'], b * tolerance['fraction'])
            if n > b + margin:
                failures.append(f'{name}.{field}: {n:.3f} > {b:.3f} + {margin:.3f} ms')
        if number(current['medianMS']) > number(current['p95MS']):
            raise ValueError(f'{name}: median exceeds p95')
        # The current collector takes seven samples: nearest-rank p95 is their maximum.
        if number(current['p95MS']) > min(100, number(old['budgetMS'])):
            failures.append(f'{name}: absolute component latency budget exceeded')
    memory = number(new['residentMB'])
    old_memory = number(base['residentMB'])
    margin = max(policy['memoryTolerance']['floorMB'], old_memory * policy['memoryTolerance']['fraction'])
    if memory > policy['memoryCeilingMB'] or memory > old_memory + margin:
        failures.append(f'peak RSS regression or ceiling exceeded: {memory:.2f} MB')
    if new.get('passed') is not True:
        failures.append('collector reported failure')
    if redraw:
        idle = new['idle']
        if idle.get('observedRoot') is not True or idle['clockTicks'] != 100 or number(idle['seconds']) < 10:
            raise ValueError('incomplete redraw probe')
        old_rates, rates = base['idle']['rendersPerSecond'], idle['rendersPerSecond']
        if rates.keys() != old_rates.keys():
            raise ValueError('redraw root coverage changed')
        for name, rate in rates.items():
            if number(rate) > number(old_rates[name]):
                failures.append(f'{name}: redraw rate increased from {old_rates[name]} to {rate}')
        if idle.get('passed') is not True:
            failures.append('redraw collector reported failure')
    return failures


def evaluate(policy, bundle):
    if bundle['environment'] != policy['environment']:
        raise ValueError('runner environment differs from the reference; needs a separately reviewed baseline')
    expected = {case['name'] for case in policy['cases']}
    if set(bundle['cases']) != expected:
        raise ValueError('missing or extra cases; partial runs cannot pass the suite')
    failures = {}
    binaries = set()
    for case in policy['cases']:
        base = json.loads((ROOT / case['reference']).read_text())
        new = bundle['cases'][case['name']]
        binary = new.get('binarySHA256', '')
        if len(binary) != 64 or any(c not in '0123456789abcdef' for c in binary):
            raise ValueError('missing binary provenance')
        binaries.add(binary)
        errors = compare_case(base, new, policy, case['redraw'])
        if 'hostMonitor' in new:
            monitor = new['hostMonitor']
            if not isinstance(monitor, dict):
                raise ValueError('invalid host monitoring metadata')
            if (monitor.get('clean') is not True or number(monitor.get('samples', 0)) < 2
                    or monitor.get('overlappingDeveloperProcesses') != [] or monitor.get('errors') != []):
                errors.append('Competing developer workload or incomplete host monitoring; samples retained, clean comparison required')
        if errors:
            failures[case['name']] = errors
    if len(binaries) != 1:
        raise ValueError('suite mixed different app binaries')
    return {'status': 'fail' if failures else 'pass', 'scope': 'Simulator components, not UI acceptance',
            'baselineVersion': policy['version'], 'failures': failures}


def command(args, log=None):
    return subprocess.run(args, cwd=ROOT, text=True, stdout=log or subprocess.PIPE,
                          stderr=subprocess.STDOUT, check=True, timeout=2400)


def collect(args, policy):
    devices = json.loads(command(['xcrun', 'simctl', 'list', 'devices', 'available', '-j']).stdout)['devices']
    selected = [(runtime, d) for runtime, group in devices.items() for d in group if d['udid'] == args.device]
    if len(selected) != 1:
        raise ValueError('select an available Simulator UUID')
    runtime, device = selected[0]
    environment = dict(hostModel=command(['sysctl', '-n', 'hw.model']).stdout.strip(),
                       architecture=command(['uname', '-m']).stdout.strip(), runtime=runtime,
                       deviceType=device['deviceTypeIdentifier'],
                       xcode=command(['xcodebuild', '-version']).stdout.strip(),
                       configuration='Release + DEBUG audit fixtures; arm64')
    if environment != policy['environment']:
        raise ValueError('environment does not match the checked-in reference')
    dd = (args.derived_data or args.out / 'derived-data').resolve()
    with (args.out / 'build.log').open('w') as log:
        command(['xcodegen', 'generate'], log)
        command(['xcodebuild', '-project', 'Banana.xcodeproj', '-scheme', 'Banana', '-configuration', 'Release',
                 '-destination', f'platform=iOS Simulator,id={args.device},arch=arm64', 'ARCHS=arm64',
                 'ONLY_ACTIVE_ARCH=YES', 'BANANA_UNRELEASED=YES', 'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG',
                 '-derivedDataPath', str(dd), 'CODE_SIGNING_ALLOWED=NO', '-quiet', 'build-for-testing'], log)
    if subprocess.run(['pgrep', '-x', 'xcodebuild'], stdout=subprocess.DEVNULL).returncode == 0:
        raise ValueError('another Xcode build/test is running; retain this run and retry on an idle host')
    app = dd / 'Build/Products/Release-iphonesimulator/Banana.app'
    bundle = {'environment': environment, 'cases': {}}
    for case in policy['cases']:
        print(f'Measuring {case["name"]}', flush=True)
        # Every case is retained even when its absolute gate fails. The aggregate gate still fails.
        with HostMonitor(args.out / f'{case["name"]}-host.json') as host, (args.out / f'{case["name"]}.log').open('w') as log:
            command([sys.executable, 'tools/scale-stress.py', '--device', args.device, '--app', str(app),
                     '--days', str(case['days']), '--route', case['route'], '--idle-seconds',
                     '10' if case['redraw'] else '0', '--out', str(args.out), '--label', case['name'],
                     '--max-memory-mb', str(policy['memoryCeilingMB']), '--allow-failures'], log)
        bundle['cases'][case['name']] = json.loads((args.out / f'{case["name"]}-{case["days"]}d.json').read_text())
        bundle['cases'][case['name']]['hostMonitor'] = host.report()
        (args.out / 'measurements.json').write_text(json.dumps(bundle, indent=2) + '\n')
    return bundle


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['run', 'compare'])
    parser.add_argument('--results', type=Path, help='Retained measurements.json (compare mode)')
    parser.add_argument('--derived-data', type=Path, help='Reuse build products; build is still mandatory')
    parser.add_argument('--device', default='E5232BE0-8F82-4E85-A03B-5CA7160571E2')
    parser.add_argument('--out', type=Path, help='New artifact directory; never overwritten')
    args = parser.parse_args()
    args.out = (args.out or ROOT / '.build/performance-regression' / datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')).resolve()
    args.out.mkdir(parents=True, exist_ok=False)
    policy = json.loads(POLICY.read_text())
    (args.out / 'baseline-policy.json').write_text(json.dumps(policy, indent=2) + '\n')
    try:
        references = {case['name']: json.loads((ROOT / case['reference']).read_text()) for case in policy['cases']}
        (args.out / 'baseline-measurements.json').write_text(json.dumps(references, indent=2) + '\n')
        if args.mode == 'compare':
            if not args.results:
                raise ValueError('--results is required for compare')
            bundle = json.loads(args.results.read_text())
        else:
            bundle = collect(args, policy)
        result = evaluate(policy, bundle)
    except (ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        result = {'status': 'unmeasured', 'error': str(error)}
    (args.out / 'gate.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
    print(f'Artifacts: {args.out}')
    return {'pass': 0, 'fail': 1, 'unmeasured': 2}[result['status']]


if __name__ == '__main__':
    raise SystemExit(main())
