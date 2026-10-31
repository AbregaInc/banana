#!/usr/bin/env python3
"""Native controller race checks on an isolated Simulator or physical-device prototype."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import time
import uuid


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--device', required=True)
    p.add_argument('--simulator', action='store_true')
    p.add_argument('--app', type=Path, required=True)
    p.add_argument('--out', type=Path, required=True)
    a = p.parse_args()
    bundle = 'com.boris.banana.calendar-library-benchmark'
    info = plistlib.loads((a.app / 'Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != bundle: p.error('Only the isolated benchmark can be installed')
    a.out.mkdir(parents=True, exist_ok=False)
    (a.out / 'environment.json').write_text(json.dumps(dict(device=a.device, simulator=a.simulator,
        binarySHA256=hashlib.sha256((a.app / info['CFBundleExecutable']).read_bytes()).hexdigest(),
        scope='Programmatic controller correctness, not touch/display performance'), indent=2) + '\n')
    rows = [dict(density=density, ablation=variant, status='unmeasured-not-started')
            for density in [100,300] for variant in ['tile-prefetch-budgeted','tile-prefetch-async-lazy','tile-prefetch-async-surface','tile-prefetch-async-surface-lazy']]
    def save(): (a.out / 'summary.json').write_text(json.dumps(rows, indent=2) + '\n')
    def call(label, args):
        try: result = subprocess.run(args, capture_output=True, text=True, timeout=60)
        except subprocess.TimeoutExpired: result = subprocess.CompletedProcess(args, 124, '', 'Timed out')
        (a.out / (label + '.log')).write_text(result.stdout + result.stderr)
        return result
    save()
    command = ['xcrun','simctl','install',a.device,str(a.app.resolve())] if a.simulator else [
        'xcrun','devicectl','device','install','app','--device',a.device,str(a.app.resolve())]
    if call('install', command).returncode:
        for row in rows: row['status'] = 'unmeasured-install-failed'
        save(); return 2
    for row in rows:
        name = f"{row['density']}-{row['ablation']}"
        filename = 'navigation-' + str(uuid.uuid4()) + '.json'
        destination = a.out / (name + '.json')
        args = ['--candidate','native','--mode','week','--days','365','--density',str(row['density']),
                '--renderer','tiles','--ablation',row['ablation'],'--async-workers','2',
                '--check','navigation','--output',filename]
        row['status'] = 'running-unmeasured'; save()
        try:
            if a.simulator:
                call(name+'-terminate', ['xcrun','simctl','terminate',a.device,bundle])
                launch = call(name+'-launch', ['xcrun','simctl','launch',a.device,bundle,*args])
                container = call(name+'-container', ['xcrun','simctl','get_app_container',a.device,bundle,'data'])
                source = Path(container.stdout.strip()) / 'Documents' / filename if not container.returncode else None
            else:
                launch = call(name+'-launch', ['xcrun','devicectl','device','process','launch','--device',a.device,
                                               '--terminate-existing',bundle,*args])
                source = None
            began = time.monotonic(); attempt = 0
            while launch.returncode == 0 and time.monotonic() - began < 90:
                time.sleep(1); attempt += 1
                if a.simulator and source is not None and source.exists():
                    destination.write_bytes(source.read_bytes()); break
                elif not a.simulator:
                    copied = call(name+f'-copy-{attempt}', ['xcrun','devicectl','device','copy','from',
                        '--device',a.device,'--source','Documents/'+filename,'--domain-type','appDataContainer',
                        '--domain-identifier',bundle,'--destination',str(destination.resolve())])
                    if copied.returncode == 0 and destination.exists(): break
            if not destination.exists(): row['status'] = 'unmeasured-no-report'
            else:
                result = json.loads(destination.read_text())
                row['status'] = 'passed' if result.get('status') == 'passed' and result.get('checks') == 44 \
                    and result.get('failures') == [] and result.get('eventsPerDay') == row['density'] else 'failed'
        except KeyboardInterrupt:
            row['status'] = 'interrupted-unmeasured'; save(); return 2
        save()
    return 0 if all(row['status'] == 'passed' for row in rows) else 1


if __name__ == '__main__':
    raise SystemExit(main())
