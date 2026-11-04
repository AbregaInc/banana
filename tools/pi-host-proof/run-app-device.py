#!/usr/bin/env python3
"""Install isolated Pi, verify real local inference, preserve normal data, reopen normal UI."""
import argparse
import hashlib
import json
import pathlib
import plistlib
import subprocess
import tempfile
import time
import uuid

parser = argparse.ArgumentParser()
parser.add_argument('device')
parser.add_argument('label')
parser.add_argument('app', type=pathlib.Path)
mode = parser.add_mutually_exclusive_group()
mode.add_argument('--nutrition', action='store_true')
mode.add_argument('--samples', action='store_true')
mode.add_argument('--workspace', action='store_true')
args = parser.parse_args()
if not args.label.replace('-', '').isalnum():
    parser.error('Use an alphanumeric label')
bundle = plistlib.loads((args.app / 'Info.plist').read_bytes())['CFBundleIdentifier']
if not bundle.endswith('.pi-development'):
    parser.error('Only the isolated PiDevelopment app may be installed')
reports = pathlib.Path(__file__).resolve().parents[2] / 'docs/research/pi-apple-host-results'
report_name = args.label + ('-workspace' if args.workspace else '-nutrition' if args.nutrition else '-samples' if args.samples else '-app-integration')
run_id = str(uuid.uuid4())

def command(parts, required=True):
    result = subprocess.run(['xcrun', 'devicectl', *parts], capture_output=True, text=True, timeout=40)
    if required and result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return result

def copy(source, destination, required=True):
    return command(['device', 'copy', 'from', '--device', args.device, '--domain-type', 'appDataContainer',
                    '--domain-identifier', bundle, '--source', source, '--destination', str(destination)], required)

with tempfile.TemporaryDirectory(prefix='banana-pi-acceptance-') as temporary:
    temporary = pathlib.Path(temporary)
    def normal_state():
        digests = {}
        for name in ['agent.sqlite', 'agent.sqlite-wal', 'agent.sqlite.wake.json', 'pending-input.json']:
            local = temporary / name
            result = copy('Library/Application Support/Banana Pi/PiAssistant/' + name, local, required=False)
            digests[name] = hashlib.sha256(local.read_bytes()).hexdigest() if result.returncode == 0 else None
        prefs = temporary / 'preferences.plist'
        copy('Library/Preferences/' + bundle + '.plist', prefs)
        values = plistlib.loads(prefs.read_bytes())
        return digests, {key: values.get(key) for key in ['assistant.selection', 'assistant.draft']}

    # Installing stops the old app before capturing its normal store. No verification
    # process or normal conversation is running while the baseline is captured.
    command(['device', 'install', 'app', '--device', args.device, str(args.app)])
    try:
        before = normal_state()
        if before[0]['agent.sqlite'] is None:
            raise RuntimeError('Could not snapshot normal history; open a normal Assistant conversation before this check')
        with (reports / (report_name + '.console.txt')).open('w') as log:
            launch = ['xcrun', 'devicectl', 'device', 'process', 'launch', '--device', args.device,
                                     '--terminate-existing', '--console', '--timeout', '300', bundle, '--',
                                     '--assistant-real-test', '--assistant-verify', '--assistant-headless',
                                     '--disable-icloud', '--ui-preview', '-onboardingCompleted', 'YES',
                                     '--assistant-verification-id', run_id,
                                     *(['--assistant-workspace-verify'] if args.workspace else ['--assistant-nutrition-verify'] if args.nutrition else ['--assistant-sample-verify'] if args.samples else [])]
            process = subprocess.Popen(launch, stdout=log, stderr=subprocess.STDOUT)
            captured = False
            deadline = time.monotonic() + 320
            try:
                while process.poll() is None:
                    if time.monotonic() > deadline:
                        raise TimeoutError('The device verification exceeded 320 seconds')
                    if args.nutrition and not captured:
                        ready = temporary / 'view-ready.json'
                        copied = copy('Documents/pi-nutrition-view-ready.json', ready, required=False)
                        if copied.returncode == 0 and json.loads(ready.read_text()).get('run') == run_id:
                            captured = command(['device', 'capture', 'screenshot', '--device', args.device,
                                '--destination', str(reports / (report_name + '.png'))], required=False).returncode == 0
                    time.sleep(0.5)
            finally:
                if process.poll() is None:
                    process.terminate()
                process.wait(timeout=15)
        report = temporary / 'integration.json'
        copy('Documents/pi-app-integration.json', report)
        data = json.loads(report.read_text())
        after = normal_state()
        data['normalHistoryUnchanged'] = before[0] == after[0]
        data['normalSelectionAndDraftUnchanged'] = before[1] == after[1]
        if args.nutrition:
            data['nativeScreenshotCaptured'] = captured
            if data.get('run') != run_id:
                data['passed'] = False
                data['error'] = 'The nutrition report did not belong to this verification run'
        if process.returncode or not all([data.get('passed'), data['normalHistoryUnchanged'], data['normalSelectionAndDraftUnchanged']]):
            data['passed'] = False
        (reports / (report_name + '.json')).write_text(json.dumps(data, indent=2) + '\n')
        print(json.dumps({key: value for key, value in data.items() if key != 'messages'}, indent=2), flush=True)
        if not data['passed']:
            raise SystemExit(1)
    finally:
        command(['device', 'process', 'launch', '--device', args.device, '--terminate-existing', bundle])
        print('Returned to normal Banana Pi with no verification launch flags', flush=True)
