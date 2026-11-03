#!/usr/bin/env python3
"""Controlled closed-store iPad -> Mac -> iPad handoff; no concurrent writer or sync protocol."""
import argparse
import hashlib
import json
import pathlib
import subprocess
import tempfile
import uuid

parser = argparse.ArgumentParser()
parser.add_argument('device')
parser.add_argument('--label', default='ipad')
parser.add_argument('--bundle', default='com.boris.banana.pi-host-proof')
args = parser.parse_args()
if not args.label.replace('-', '').isalnum():
    parser.error('label must contain only letters, digits and hyphens')
repo = pathlib.Path(__file__).resolve().parents[2]
sources = pathlib.Path(__file__).resolve().parent
reports = repo / 'docs/research/pi-apple-host-results'
reports.mkdir(parents=True, exist_ok=True)
executable = repo / '.build/mac-check/pi-host-proof'
executable.parent.mkdir(parents=True, exist_ok=True)
source_group = 'handoff-source-' + uuid.uuid4().hex[:12]
return_group = 'handoff-return-' + uuid.uuid4().hex[:12]
log = []

def run(command, timeout=110):
    result = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
    log.append(result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return result

def transfer(direction, source, destination):
    run(['xcrun', 'devicectl', 'device', 'copy', direction, '--device', args.device,
         '--domain-type', 'appDataContainer', '--domain-identifier', args.bundle,
         '--source', str(source), '--destination', str(destination), '--timeout', '45'])

def device_mode(mode, group):
    result = run(['xcrun', 'devicectl', 'device', 'process', 'launch', '--device', args.device,
                  '--console', '--timeout', '100', args.bundle, '--mode', mode, '--case', group, '--headless'])
    (reports / f'{args.label}-{mode}.console.txt').write_text(result.stdout + result.stderr)
    if f'PI_PROOF_PASS {mode} ' not in result.stdout:
        raise RuntimeError(result.stdout + result.stderr)
    destination = reports / f'{args.label}-{mode}.json'
    transfer('from', f'Documents/{group}-{mode}.json', destination)
    report = json.loads(destination.read_text())
    detail = json.loads(report['result'])
    assert report['passed'] and detail['passed'], report
    return detail

def mac_mode(mode, database):
    result = run([str(executable), str(repo / '.build/sim/pi-host-proof-sources'), mode, str(database)])
    (reports / f'mac-{mode}.console.txt').write_text(result.stdout + result.stderr)
    detail = json.loads(result.stdout.strip().splitlines()[-1])
    (reports / f'mac-{mode}.json').write_text(json.dumps(detail, indent=2) + '\n')
    assert detail['passed'], detail
    return detail

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

try:
    run(['swiftc', str(repo / 'Banana/Pi/AppleRuntimeHost.swift'), str(repo / 'Banana/Pi/AppleFoundationModel.swift'), str(sources / 'ProofHooks.swift'), str(sources / 'MacRunner.swift'),
         '-o', str(executable), '-framework', 'JavaScriptCore', '-framework', 'Security', '-framework', 'FoundationModels', '-lsqlite3'])
    with tempfile.TemporaryDirectory(prefix='banana-pi-handoff-') as directory:
        database = pathlib.Path(directory) / 'transferred.sqlite'
        first = device_mode('handoff-first', source_group)
        assert first['armCalls'] == 1 and first['deliverCalls'] == 0
        # device_mode waited for process exit and the host asserted zero open resources.
        transfer('from', f'Documents/{source_group}-persist.sqlite', database)
        source_sha = sha(database)
        viewer = mac_mode('handoff-viewer', database)
        assert viewer['task'] == first['task'] and sha(database) == source_sha
        delivered = mac_mode('handoff-resume', database)
        assert delivered['task']['id'] == first['task']['id']
        assert delivered['armCalls'] == 0 and delivered['deliverCalls'] == 1
        completed_sha = sha(database)
        # The Mac writer has exited. Import to a new path so the source snapshot stays auditable.
        transfer('to', database, f'Documents/{return_group}-persist.sqlite')
        returned = device_mode('handoff-completed', return_group)
        assert returned['task'] == delivered['task']
        assert returned['armCalls'] == returned['deliverCalls'] == 0
        roundtrip = pathlib.Path(directory) / 'returned.sqlite'
        transfer('from', f'Documents/{return_group}-persist.sqlite', roundtrip)
        assert sha(roundtrip) == completed_sha
        result = {'passed': True, 'source': args.label, 'destination': 'mac', 'returnedTo': args.label,
                  'taskId': first['task']['id'], 'sourceSha256': source_sha, 'completedSha256': completed_sha,
                  'sourceArmCalls': first['armCalls'], 'sourceDeliverCalls': first['deliverCalls'],
                  'destinationArmCalls': delivered['armCalls'], 'destinationDeliverCalls': delivered['deliverCalls'],
                  'returnArmCalls': returned['armCalls'], 'returnDeliverCalls': returned['deliverCalls'],
                  'readOnlyViewsPreservedBytes': True, 'ownership': 'orchestrated closed-store transfer; no automatic fencing or synchronization'}
        (reports / f'{args.label}-mac-handoff.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result, indent=2), flush=True)
finally:
    executable.unlink(missing_ok=True)
    (reports / f'{args.label}-mac-handoff.console.txt').write_text('\n'.join(log))
