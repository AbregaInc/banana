#!/usr/bin/env python3
"""Run the isolated Simulator scale workload and retain machine-readable results."""
import argparse
import hashlib
import os
import json
import pathlib
import subprocess
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--device', default='E5232BE0-8F82-4E85-A03B-5CA7160571E2')
p.add_argument('--app', type=pathlib.Path, default=ROOT / '.build/stress-dd/Build/Products/Release-iphonesimulator/Banana.app')
p.add_argument('--days', type=int, nargs='+', default=[1, 7, 30])
p.add_argument('--out', type=pathlib.Path, required=True)
p.add_argument('--label', default='candidate')
p.add_argument('--baseline', type=pathlib.Path, help='Directory containing baseline-<days>d.json for regression comparison.')
p.add_argument('--max-memory-mb', type=float, default=900, help='Peak Simulator process RSS ceiling, including fixtures (default 900 MB).')
p.add_argument('--allow-failures', action='store_true', help='Capture a failing baseline without a nonzero exit.')
p.add_argument('--diagnostics', action='store_true', help='Record per-sample CPU, faults and scheduling counters; timings remain subject to instrumentation overhead.')
p.add_argument('--calendar-reference-neighbors', action='store_true', help='DEBUG ablation: use the original mobile calendar neighbor scans.')
p.add_argument('--route', choices=['notes', 'library', 'plan', 'mail'], default='notes')
p.add_argument('--idle-seconds', type=int, default=0, help='After loading, probe redraws while the playhead ticks at 10 Hz (1–60 seconds).')
a = p.parse_args()
if not all(1 <= days <= 365 for days in a.days):
    p.error('days must be in 1...365')
if a.max_memory_mb <= 0:
    p.error('max-memory-mb must be positive')
if not 0 <= a.idle_seconds <= 60:
    p.error('idle-seconds must be in 0...60')

def run(*args, check=True):
    return subprocess.run(args, check=check, text=True, capture_output=True, timeout=300)

# simctl only: never install on a physical device or launch the Mac production app.
devices = json.loads(run('xcrun', 'simctl', 'list', 'devices', 'available', '-j').stdout)['devices']
if not any(d['udid'] == a.device for group in devices.values() for d in group):
    p.error('device must be an available Simulator UUID')
if not a.app.exists():
    p.error(f'build the stress app first: {a.app}')
run('xcrun', 'simctl', 'boot', a.device, check=False)
run('xcrun', 'simctl', 'bootstatus', a.device, '-b')
bundle = run('/usr/libexec/PlistBuddy', '-c', 'Print CFBundleIdentifier', str(a.app / 'Info.plist')).stdout.strip()
executable = run('/usr/libexec/PlistBuddy', '-c', 'Print CFBundleExecutable', str(a.app / 'Info.plist')).stdout.strip()
binary_hash = hashlib.sha256((a.app / executable).read_bytes()).hexdigest()
run('xcrun', 'simctl', 'install', a.device, str(a.app))
container = pathlib.Path(run('xcrun', 'simctl', 'get_app_container', a.device, bundle, 'data').stdout.strip())
report_path = container / 'Documents/scale-stress.json'
idle_path = container / 'Documents/scale-idle.json'
a.out.mkdir(parents=True, exist_ok=True)
commit = run('git', '-C', str(ROOT), 'rev-parse', 'HEAD').stdout.strip()
failed = False
for days in a.days:
    run('xcrun', 'simctl', 'terminate', a.device, bundle, check=False)
    report_path.unlink(missing_ok=True)  # Only this harness's prior result, never user data.
    idle_path.unlink(missing_ok=True)
    host_load = os.getloadavg()
    started = time.monotonic()
    run('xcrun', 'simctl', 'launch', a.device, bundle, '--' + a.route, '--stress-days', str(days),
        '--stress-measure', '--disable-icloud', '--mail-fresh', '-onboardingCompleted', 'YES',
        '-planMode', 'week', '-mobileWeekLayout', 'calendar', '--stress-idle-seconds', str(a.idle_seconds),
        *(['--stress-diagnostics'] if a.diagnostics else []),
        *(['--calendar-reference-neighbors'] if a.calendar_reference_neighbors else []))
    deadline = started + 300
    while not report_path.exists() and time.monotonic() < deadline:
        time.sleep(1)
    if not report_path.exists():
        raise SystemExit(f'{days} days: no report within 300s (crash/hang or fixture preparation failure)')
    report = json.loads(report_path.read_text())
    if a.idle_seconds:
        while not idle_path.exists() and time.monotonic() < deadline:
            time.sleep(1)
        if not idle_path.exists():
            raise SystemExit('No redraw report (crash, hang or uncompleted probe)')
        report['idle'] = json.loads(idle_path.read_text())
        report['passed'] &= report['idle']['passed']
        failed |= not report['idle']['passed']
        print(f'  redraw probe ({a.route}): {report["idle"]}', flush=True)
    expected = dict(days=days, emails=days * 2000, events=days * 100,
                    notes=days * 1000, podcasts=days * 10, episodes=days * 10000)
    if any(report.get(key) != value for key, value in expected.items()):
        raise SystemExit(f'{days} days: report workload does not match requested tier')
    report.update(label=a.label, commit=commit, device=a.device, binarySHA256=binary_hash, hostLoad=host_load,
                  dirty=bool(run('git', '-C', str(ROOT), 'status', '--porcelain').stdout.strip()),
                  readySeconds=round(time.monotonic() - started, 3))
    report['requestedCalendarNeighborPolicy'] = 'reference' if a.calendar_reference_neighbors else 'prepared'
    report['memoryBudgetMB'] = a.max_memory_mb
    report['memoryPassed'] = report['residentMB'] <= a.max_memory_mb
    failed |= not report['memoryPassed']
    if a.baseline:
        baseline = json.loads((a.baseline / f'baseline-{days}d.json').read_text())
        if any(baseline.get(key) != value for key, value in expected.items()):
            raise SystemExit(f'{days} days: baseline workload does not match requested tier')
        old = {m['name']: m for m in baseline['metrics']}
        regressions = []
        for metric in report['metrics']:
            before = old[metric['name']]['medianMS']
            # Both an absolute floor and a relative margin: don't fail on sub-ms timer noise.
            if metric['medianMS'] - before > max(5, before * .25):
                regressions.append(metric['name'])
        if report['residentMB'] - baseline['residentMB'] > max(64, baseline['residentMB'] * .20):
            regressions.append('peakRSS')
        report['regressions'] = regressions
        failed |= bool(regressions)
    report['passed'] = report['passed'] and report['memoryPassed'] and not report.get('regressions')
    dest = a.out / f'{a.label}-{days}d.json'
    dest.write_text(json.dumps(report, indent=2) + '\n')
    print(f'{days}d: {report["emails"]} mail, {report["events"]} events, '
          f'{report["episodes"]} episodes, {report["notes"]} notes; peak RSS {report["residentMB"]:.1f} MB', flush=True)
    print(f'  memory: {"PASS" if report["memoryPassed"] else "FAIL"} (budget {a.max_memory_mb:g} MB)', flush=True)
    if report.get('regressions'):
        print(f'  baseline regressions: {", ".join(report["regressions"])}', flush=True)
    for metric in report['metrics']:
        ok = metric['p95MS'] <= metric['budgetMS']
        print(f'  {metric["name"]}: median={metric["medianMS"]:.2f}ms '
              f'p95={metric["p95MS"]:.2f}ms budget={metric["budgetMS"]:g}ms {"PASS" if ok else "FAIL"}', flush=True)
        failed |= not ok
    run('xcrun', 'simctl', 'terminate', a.device, bundle, check=False)
raise SystemExit(1 if failed and not a.allow_failures else 0)
