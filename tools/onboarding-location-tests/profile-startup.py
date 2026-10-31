#!/usr/bin/env python3
"""Compare app startup with an available or deliberately stalled Simulator location service.

Measures launch-to-fixture-report only. It does not certify frame or input latency.
Only explicitly selected, already booted Simulators are accepted.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import time


def run(*args, check=True):
    return subprocess.run(args, check=check, text=True, capture_output=True, timeout=60)


def verdict(rows):
    if [row.get('policy') for row in rows] != ['before', 'after', 'after', 'before']:
        return 2
    if any(row.get('ready') and not row.get('workloadMatches') for row in rows):
        return 2
    # Baseline failures are retained comparison outcomes. Candidate failure is never a pass.
    return 0 if all(row.get('ready') for row in rows if row['policy'] == 'after') else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True)
    parser.add_argument('--before', required=True, type=Path)
    parser.add_argument('--after', required=True, type=Path)
    parser.add_argument('--out', required=True, type=Path)
    parser.add_argument('--pause-location-service', action='store_true')
    args = parser.parse_args()
    inventory = json.loads(run('xcrun', 'simctl', 'list', 'devices', 'available', '-j').stdout)
    devices = [dict(runtime=runtime, **device) for runtime, group in inventory['devices'].items()
               for device in group if device['udid'] == args.device]
    if len(devices) != 1 or devices[0]['state'] != 'Booted':
        parser.error('Select an already booted, available fixture Simulator UUID')
    apps = {}
    for policy, path in [('before', args.before), ('after', args.after)]:
        info = plistlib.load((path / 'Info.plist').open('rb'))
        apps[policy] = dict(path=path.resolve(), bundle=info['CFBundleIdentifier'],
            sha=hashlib.sha256((path / info['CFBundleExecutable']).read_bytes()).hexdigest())
    if apps['before']['bundle'] != apps['after']['bundle']:
        parser.error('The two builds must have the same bundle identifier')
    args.out.mkdir(parents=True, exist_ok=False)
    location_pid = None
    if args.pause_location_service:
        services = run('xcrun', 'simctl', 'spawn', args.device, 'launchctl', 'list').stdout.splitlines()
        location_pid = int(next(line.split()[0] for line in services
                                if line.split()[-1] == 'com.apple.locationd'))
        if location_pid <= 1:
            raise RuntimeError('No running location daemon in selected Simulator')
    identity = dict(device=devices[0], locationPID=location_pid,
        pausedLocationService=args.pause_location_service,
        collectorSHA256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        xcode=run('xcodebuild', '-version').stdout,
        scope='Process launch to 30-day component report, not first visible frame or input latency')
    (args.out / 'identity.json').write_text(json.dumps(identity, indent=2))
    rows = []
    bundle = apps['after']['bundle']
    def interrupted(*_):
        raise SystemExit('Interrupted; restoring Simulator location service')
    signal.signal(signal.SIGTERM, interrupted)
    try:
        if location_pid is not None:
            os.kill(location_pid, signal.SIGSTOP)
        for index, policy in enumerate(['before', 'after', 'after', 'before']):
            app = apps[policy]
            case = args.out / f'{index}-{policy}'
            case.mkdir()
            run('xcrun', 'simctl', 'terminate', args.device, bundle, check=False)
            run('xcrun', 'simctl', 'install', args.device, str(app['path']))
            container = Path(run('xcrun', 'simctl', 'get_app_container', args.device, bundle, 'data').stdout.strip())
            report = container / 'Documents/scale-stress.json'
            report.unlink(missing_ok=True)  # Only the fixture collector's prior result.
            command = ['xcrun', 'simctl', 'launch', args.device, bundle, '--plan', '--stress-days', '30',
                '--stress-measure', '--disable-icloud', '--mail-fresh', '-onboardingCompleted', 'YES',
                '-planMode', 'week', '-mobileWeekLayout', 'calendar']
            (case / 'command.json').write_text(json.dumps(command, indent=2))
            started = time.monotonic()
            launch = run(*command)
            pid = launch.stdout.strip().rsplit(': ', 1)[-1]
            (case / 'launch.txt').write_text(launch.stdout + launch.stderr)
            while not report.exists() and time.monotonic() - started < 30:
                time.sleep(.25)
            elapsed = time.monotonic() - started
            ready = report.exists()
            row = dict(policy=policy, binarySHA256=app['sha'], ready=ready,
                       elapsedSeconds=elapsed, timeoutSeconds=30)
            if ready:
                model = json.loads(report.read_bytes())
                expected = dict(days=30, emails=60000, events=3000, notes=30000,
                                podcasts=300, episodes=300000)
                row['workloadMatches'] = all(model.get(k) == v for k, v in expected.items())
                (case / 'model.json').write_bytes(report.read_bytes())
            else:
                run('sample', pid, '2', '-file', str(case / 'blocked-sample.txt'), check=False)
            run('xcrun', 'simctl', 'io', args.device, 'screenshot', str(case / 'screen.png'))
            rows.append(row)
            (args.out / 'results.json').write_text(json.dumps(rows, indent=2))
            print(row, flush=True)
    finally:
        if location_pid is not None:
            os.kill(location_pid, signal.SIGCONT)
        run('xcrun', 'simctl', 'terminate', args.device, bundle, check=False)
    return verdict(rows)


if __name__ == '__main__':
    raise SystemExit(main())
