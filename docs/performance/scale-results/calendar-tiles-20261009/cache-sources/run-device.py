#!/usr/bin/env python3
"""Physical-device component matrix. Programmatic offsets do not prove input/display latency."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import time
import uuid
from report import summarize


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    bundle = 'com.boris.banana.calendar-library-benchmark'
    info = plistlib.loads((args.app / 'Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != bundle:
        parser.error('Only the isolated calendar benchmark bundle can be installed')
    args.out.mkdir(parents=True, exist_ok=False)

    def call(label, *command, timeout=60):
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            result = subprocess.CompletedProcess(command, 124, '', 'Command timed out')
        (args.out / (label + '.log')).write_text(result.stdout + result.stderr)
        return result

    metadata = dict(timestamp=datetime.datetime.now().astimezone().isoformat(), device=args.device,
                    app=str(args.app.resolve()), binarySHA256=hashlib.sha256(
                        (args.app / info['CFBundleExecutable']).read_bytes()).hexdigest(),
                    git=subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
                    dirty=subprocess.check_output(['git', 'status', '--porcelain'], text=True),
                    scope='Physical device synchronous renderer work; input/display acceptance unmeasured',
                    matrix='Three alternating-order trials, two densities, tile cache policy ablations')
    (args.out / 'environment.json').write_text(json.dumps(metadata, indent=2) + '\n')
    installed = call('install', 'xcrun', 'devicectl', 'device', 'install', 'app', '--device', args.device,
                     str(args.app.resolve()))
    rows = []
    for trial in range(3):
        for density in [100, 300]:
            variants = ['tile-prefetch', 'tile-prefetch-lookahead', 'tile-prefetch-budgeted']
            if trial % 2: variants.reverse()
            for variant in variants:
                name = f'native-week-365d-{density}perday-{trial}-{variant}'
                print('Measuring ' + name, flush=True)
                destination = args.out / (name + '.json')
                filename = 'result-' + str(uuid.uuid4()) + '.json'
                if installed.returncode:
                    row = dict(scenario=name, status='blocked-install', exitCode=installed.returncode)
                else:
                    started = time.monotonic()
                    launched = call(name + '-launch', 'xcrun', 'devicectl', 'device', 'process', 'launch',
                                    '--device', args.device, '--terminate-existing', bundle,
                                    '--candidate', 'native', '--mode', 'week', '--days', '365', '--density',
                                    str(density), '--renderer', 'tiles', '--ablation', variant, '--output', filename)
                    attempts = 0
                    while launched.returncode == 0 and time.monotonic() - started < 90:
                        time.sleep(1)
                        attempts += 1
                        copied = call(name + f'-copy-{attempts}', 'xcrun', 'devicectl', 'device', 'copy', 'from',
                                      '--device', args.device, '--source', 'Documents/' + filename,
                                      '--domain-type', 'appDataContainer', '--domain-identifier', bundle,
                                      '--destination', str(destination.resolve()), timeout=20)
                        if copied.returncode == 0 and destination.exists(): break
                    if destination.exists():
                        data = json.loads(destination.read_text())
                        row = dict(scenario=name, **summarize(data))
                        if data.get('optimizations') != dict(renderer='tiles', ablation=variant):
                            row['status'] = 'invalid-policy'
                    else:
                        row = dict(scenario=name, status='failed-or-timeout', launchExit=launched.returncode,
                                   elapsedSeconds=time.monotonic()-started)
                if not destination.exists(): destination.write_text(json.dumps(row, indent=2)+'\n')
                rows.append(row)
                (args.out / 'summary.json').write_text(json.dumps(rows, indent=2)+'\n')
    return 1 if any(r['status'] != 'measured' or r.get('acceptance') == 'fail' for r in rows) else 2


if __name__ == '__main__':
    raise SystemExit(main())
