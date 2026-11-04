#!/usr/bin/env python3
"""Build and verify the isolated real Mac app; remove question-only build output."""
import argparse
import json
import hashlib
import pathlib
import shutil
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument('--nutrition', action='store_true')
parser.add_argument('--build-only', action='store_true')
args = parser.parse_args()
report_name = 'mac-nutrition-app' if args.nutrition else 'mac-app-integration'
repo = pathlib.Path(__file__).resolve().parents[2]
build = repo / '.build/mac-check'
reports = repo / 'docs/research/pi-apple-host-results'
reports.mkdir(parents=True, exist_ok=True)

def normal_history():
    directory = pathlib.Path.home() / 'Library/Application Support/Banana Pi/PiAssistant'
    return {str(path.relative_to(directory)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in directory.rglob('*') if path.is_file()}

def normal_preferences():
    values = {}
    for key in ['assistant.selection', 'assistant.draft']:
        result = subprocess.run(['defaults', 'read', 'com.boris.banana.mac.pi-development', key],
                                capture_output=True, timeout=10)
        values[key] = result.stdout if result.returncode == 0 else None
    return values

try:
    with (repo / '.build/pi-mac-app-build.log').open('w') as log:
        result = subprocess.run(['xcodebuild', '-project', 'Banana.xcodeproj', '-scheme', 'BananaMacPi',
                                 '-configuration', 'PiDevelopment', '-destination', 'platform=macOS',
                                 '-derivedDataPath', str(build), 'CODE_SIGNING_ALLOWED=NO', 'build'],
                                cwd=repo, stdout=log, stderr=subprocess.STDOUT, timeout=600)
    print('Mac Pi build exit:', result.returncode, flush=True)
    if result.returncode:
        raise SystemExit(result.returncode)
    if args.build_only:
        (reports / (report_name + '.compile.json')).write_text(json.dumps({'passed': True, 'scope': 'Mac Pi compile only'}, indent=2) + '\n')
        print('Mac Pi compile check passed', flush=True)
        raise SystemExit(0)
    executable = build / 'Build/Products/PiDevelopment/Banana Pi.app/Contents/MacOS/Banana Pi'
    history_before = normal_history()
    preferences_before = normal_preferences()
    started = time.time()
    with (reports / (report_name + '.console.txt')).open('w') as log:
        result = subprocess.run([str(executable), '--assistant-real-test', '--assistant-verify', '--assistant-headless',
                                 '--disable-icloud', '--ui-preview', '-onboardingCompleted', 'YES',
                                 *(['--assistant-nutrition-verify'] if args.nutrition else [])],
                                cwd=repo, stdout=log, stderr=subprocess.STDOUT, timeout=300)
    report = pathlib.Path.home() / 'Library/Application Support/Banana Pi Verification/PiVerification/pi-app-integration.json'
    if not report.exists() or report.stat().st_mtime < started:
        raise RuntimeError('The Mac app did not write a fresh verification report')
    data = json.loads(report.read_text())
    data['normalHistoryUnchanged'] = normal_history() == history_before
    data['normalSelectionAndDraftUnchanged'] = normal_preferences() == preferences_before
    if not data['normalHistoryUnchanged'] or not data['normalSelectionAndDraftUnchanged']:
        data['passed'] = False
        data['error'] = 'Verification modified normal Assistant data or preferences'
    (reports / (report_name + '.json')).write_text(json.dumps(data, indent=2) + '\n')
    print(json.dumps({key: value for key, value in data.items() if key != 'messages'}, indent=2), flush=True)
    if result.returncode or not data.get('passed'):
        raise SystemExit(result.returncode or 1)
finally:
    shutil.rmtree(build, ignore_errors=True)
