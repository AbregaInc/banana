#!/usr/bin/env python3
"""Exercise real UIKit background/foreground callbacks in the isolated Pi proof app."""
import argparse
import json
import pathlib
import subprocess
import time
import uuid

parser = argparse.ArgumentParser()
parser.add_argument('device')
parser.add_argument('label')
parser.add_argument('--bundle', default='com.boris.banana.pi-host-proof')
args = parser.parse_args()
if not args.label.replace('-', '').isalnum():
    parser.error('label must contain only letters, digits and hyphens')
repo = pathlib.Path(__file__).resolve().parents[2]
reports = repo / 'docs/research/pi-apple-host-results'
reports.mkdir(parents=True, exist_ok=True)
group = 'lifecycle-' + uuid.uuid4().hex[:12]
console = []

def command(parts, required=True):
    result = subprocess.run(['xcrun', 'devicectl', *parts[:3], '--timeout', '30', *parts[3:]], capture_output=True, text=True, timeout=40)
    console.append(result.stdout + result.stderr)
    if required and result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return result

def copy(source, destination, required=True):
    return command(['device', 'copy', 'from', '--device', args.device, '--domain-type', 'appDataContainer',
                    '--domain-identifier', args.bundle, '--source', source, '--destination', str(destination)], required)

def wait_snapshot(phase):
    destination = reports / f'{args.label}-lifecycle-{phase}.json'
    deadline = time.monotonic() + 35
    last = None
    while time.monotonic() < deadline:
        result = copy(f'Documents/{group}-persist.sqlite.lifecycle.json', destination, required=False)
        if result.returncode == 0:
            last = json.loads(destination.read_text())
            if last['phase'] == phase:
                return last
        # Poll a saved lifecycle predicate, rather than guessing when UIKit is ready.
        time.sleep(0.15)
    raise RuntimeError(f'Did not reach {phase}: {last}')

try:
    command(['device', 'process', 'launch', '--device', args.device, '--terminate-existing', args.bundle,
             '--mode', 'lifecycle-live', '--case', group, '--headless'])
    sleeping = wait_snapshot('sleeping')
    assert sleeping['task']['state']['status'] == 'sleeping'
    # Opening Settings causes a real scene background transition. No settings are changed.
    command(['device', 'process', 'launch', '--device', args.device, 'com.apple.Preferences'])
    paused = wait_snapshot('paused')
    assert paused['nativeDatabases'] == paused['nativeTimers'] == paused['nativeModelRequests'] == 0, paused
    assert paused['armCalls'] == 1 and paused['deliverCalls'] == 0, paused
    hint_file = reports / f'{args.label}-lifecycle-wake.json'
    copy(f'Documents/{group}-persist.sqlite.wake.json', hint_file)
    hint = json.loads(hint_file.read_text())
    due = sleeping['task']['input']['until']
    assert hint['at'] == due, hint
    # Use two device timestamps, so host/device clock skew cannot extend this wait.
    # The subject is real time: keep the app backgrounded across the stored deadline.
    remaining = (due - paused['recordedAt']) / 1000
    assert 0 < remaining <= 15, paused
    deadline = time.monotonic() + remaining
    while time.monotonic() <= deadline:
        time.sleep(min(0.2, max(0.001, deadline - time.monotonic())))
    command(['device', 'process', 'launch', '--device', args.device, args.bundle])
    completed = wait_snapshot('completed')
    assert completed['armCalls'] == completed['deliverCalls'] == 1, completed
    assert completed['task']['state']['outcome']['result']['wokeAt'] >= due
    destination = reports / f'{args.label}-lifecycle-live.json'
    deadline = time.monotonic() + 15
    while True:
        result = copy(f'Documents/{group}-lifecycle-live.json', destination, required=False)
        if result.returncode == 0:
            break
        if time.monotonic() >= deadline:
            raise RuntimeError('Completed lifecycle result was not saved')
        time.sleep(0.15)
    report = json.loads(destination.read_text())
    detail = json.loads(report['result'])
    assert report['passed'] and detail['passed'] and not detail['errors'], report
    print(f'{args.label}: PASS real UIKit background/foreground, closed resources, restored wake, one delivery')
finally:
    (reports / f'{args.label}-lifecycle-live.console.txt').write_text('\n'.join(console))
