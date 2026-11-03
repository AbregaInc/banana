#!/usr/bin/env python3
"""Run the Pi host proof on one explicitly selected, unlocked physical device."""
import argparse
import json
import pathlib
import subprocess
import uuid

parser = argparse.ArgumentParser()
parser.add_argument('device')
parser.add_argument('label')
parser.add_argument('--bundle', default='com.boris.banana.pi-host-proof')
parser.add_argument('--modes', nargs='+', default=['memory', 'persistent-first', 'persistent-reopen', 'crash-first', 'crash-reopen', 'host-conformance'],
                    choices=['memory', 'persistent-first', 'persistent-reopen', 'crash-first', 'crash-reopen', 'host-conformance',
                             'provider-conformance', 'foundation-text', 'foundation-tool', 'foundation-reopen',
                             'foundation-crash-first', 'foundation-crash-reopen', 'lifecycle-first', 'lifecycle-reopen', 'lifecycle-conformance'])
args = parser.parse_args()
if not args.label.replace('-', '').isalnum():
    parser.error('label must contain only letters, digits, and hyphens')
repo = pathlib.Path(__file__).resolve().parents[2]
reports = repo / 'docs/research/pi-apple-host-results'
reports.mkdir(parents=True, exist_ok=True)
group = 'proof-' + uuid.uuid4().hex[:12]

def run(command):
    return subprocess.run(command, text=True, capture_output=True, timeout=110)

def copy(source, destination):
    result = run(['xcrun', 'devicectl', 'device', 'copy', 'from', '--device', args.device,
                  '--domain-type', 'appDataContainer', '--domain-identifier', args.bundle,
                  '--source', source, '--destination', str(destination), '--timeout', '45'])
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)

for mode in args.modes:
    result = run(['xcrun', 'devicectl', 'device', 'process', 'launch', '--device', args.device,
                  '--console', '--timeout', '100', args.bundle,
                  '--mode', mode, '--case', group, '--headless'])
    console = result.stdout + result.stderr
    (reports / f'{args.label}-{mode}.console.txt').write_text(console)
    if mode in ['crash-first', 'foundation-crash-first']:
        # CoreDevice sometimes reports exit 0 for this native exit(42). Verify the
        # exact interruption point, saved effect and subsequent recovery instead.
        if (result.returncode not in [0, 42] or 'Exiting process during native tool, after Pi committed execution intent' not in console
                or 'PI_PROOF_' in console or 'The app terminated' not in console):
            raise RuntimeError('Expected abrupt exit at the native effect boundary, got:\n' + console)
        foundation = mode.startswith('foundation-')
        marker = reports / f'{args.label}-{"foundation-" if foundation else ""}effect.txt'
        copy(f'Documents/{group}-{"persist" if foundation else "crash"}.sqlite.effect', marker)
        if marker.read_text() != 'native tool effect happened\n':
            raise RuntimeError('The native effect was not recorded before interruption')
        print(f'{args.label}: interruption after native effect confirmed', flush=True)
        continue
    if result.returncode or f'PI_PROOF_PASS {mode} ' not in console:
        raise RuntimeError(console)
    destination = reports / f'{args.label}-{mode}.json'
    copy(f'Documents/{group}-{mode}.json', destination)
    report = json.loads(destination.read_text())
    detail = json.loads(report['result'])
    if mode in ['host-conformance', 'provider-conformance', 'lifecycle-conformance']:
        if not report['passed'] or not detail['passed'] or detail['failed']:
            raise RuntimeError(f'Host conformance failed: {report}')
        print(f'{args.label}: PASS {detail["total"]} {mode} checks', flush=True)
        continue
    if mode.startswith('lifecycle-'):
        if not report['passed'] or not detail['passed']:
            raise RuntimeError(f'Lifecycle proof failed: {report}')
        print(f'{args.label}: PASS {mode}: {detail["armCalls"]} arm phases, {detail["deliverCalls"]} deliveries', flush=True)
        continue
    if mode.startswith('foundation-'):
        if not report['passed'] or not detail['passed']:
            raise RuntimeError(f'Foundation Models proof failed: {report}')
        print(f'{args.label}: PASS {mode}: {detail["modelCalls"]} local generations, {detail["toolCalls"]} native tool calls', flush=True)
        continue
    if not report['passed'] or not detail['passed'] or not detail['deduplicated']:
        raise RuntimeError(f'Failed assertions: {report}')
    if detail['calls'] != (0 if mode.endswith('reopen') else 1):
        raise RuntimeError(f'Unexpected repeated tool execution: {report}')
    if mode == 'crash-reopen' and not detail['interrupted']:
        raise RuntimeError(f'Unsafe tool was not reported interrupted: {report}')
    print(f'{args.label}: PASS {mode} ({report["platform"]}, OS {report["os"]})', flush=True)
