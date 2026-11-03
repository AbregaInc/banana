#!/usr/bin/env python3
"""Check the integrated app's production lifecycle with a waiting diagnostic model."""
import argparse
import json
import pathlib
import subprocess
import time
import uuid

parser = argparse.ArgumentParser()
parser.add_argument('device')
parser.add_argument('label')
parser.add_argument('--bundle', default='com.boris.banana.pi-development')
args = parser.parse_args()
if not args.label.replace('-', '').isalnum() or not args.bundle.endswith('.pi-development'):
    parser.error('Use an alphanumeric label and the isolated PiDevelopment bundle')
reports = pathlib.Path(__file__).resolve().parents[2] / 'docs/research/pi-apple-host-results'
run = uuid.uuid4().hex
console = []

def command(parts, required=True):
    result = subprocess.run(['xcrun', 'devicectl', *parts[:3], '--timeout', '30', *parts[3:]], capture_output=True, text=True, timeout=40)
    console.append(result.stdout + result.stderr)
    if required and result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return result

def wait_file(name, predicate, destination):
    deadline = time.monotonic() + 40
    last = None
    while time.monotonic() < deadline:
        result = command(['device', 'copy', 'from', '--device', args.device, '--domain-type', 'appDataContainer',
                          '--domain-identifier', args.bundle, '--source', 'Documents/' + name,
                          '--destination', str(destination)], required=False)
        if result.returncode == 0:
            last = json.loads(destination.read_text())
            if last.get('run') == run and predicate(last):
                return last
        time.sleep(0.2)
    raise RuntimeError(f'App did not reach expected lifecycle state: {last}')

try:
    command(['device', 'process', 'launch', '--device', args.device, '--terminate-existing', args.bundle, '--',
             '--assistant-test', '--assistant-reset', '--assistant-lifecycle-verify', '--assistant-headless',
             '--assistant-verification-id', run, '--disable-icloud', '--ui-preview', '-onboardingCompleted', 'YES'])
    state = 'pi-app-lifecycle-state.json'
    running = wait_file(state, lambda s: s['active'] and s['busy'] and s['fixtureNotes'] == 1,
                        reports / f'{args.label}-app-lifecycle-running.json')
    # A real UIKit background transition; no system setting is changed.
    command(['device', 'process', 'launch', '--device', args.device, 'com.apple.Preferences'])
    paused = wait_file(state, lambda s: not s['active'] and s['backgrounds'] > 0,
                       reports / f'{args.label}-app-lifecycle-paused.json')
    assert paused['resources'] == {'databases': 0, 'timers': 0, 'modelRequests': 0}, paused
    command(['device', 'process', 'launch', '--device', args.device, args.bundle])
    completed = wait_file('pi-app-lifecycle.json', lambda s: True, reports / f'{args.label}-app-lifecycle.json')
    assert completed['passed'], completed
    print(f'{args.label}: PASS integrated app background/foreground, resources closed, effect once, cancellation, next input')
finally:
    (reports / f'{args.label}-app-lifecycle.console.txt').write_text('\n'.join(console))
