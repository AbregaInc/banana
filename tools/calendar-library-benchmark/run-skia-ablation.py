#!/usr/bin/env python3
"""Retained color/path/recording ablations; existing full workloads and pixel gate."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from performance_host import HostMonitor
root = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('raster', root/'run-skia-raster.py')
raster = importlib.util.module_from_spec(spec)
spec.loader.exec_module(raster)
VARIANTS = {
    'unmanaged': (False, False, False, ['--legacy-unmanaged-colors']),
    'managed': (True, False, False, []),
    'paths': (True, True, False, ['--cg-paths']),
    'pictures': (True, True, True, ['--cg-paths', '--reuse-pictures']),
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True, type=Path)
    parser.add_argument('--out', required=True, type=Path)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=False)
    sources = [*root.glob('Shared/*.swift'), *root.glob('SkiaTests/*'), root/'run-skia-raster.py', Path(__file__)]
    (args.out/'environment.json').write_text(json.dumps({
        'binarySHA256': hashlib.sha256(args.binary.read_bytes()).hexdigest(),
        'sources': {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources if p.is_file()},
        'os': subprocess.check_output(['sw_vers'], text=True),
        'scope': 'Isolated Mac raster components; unchanged fixture and native pixel oracle; no UI acceptance'
    }, indent=2)+'\n')
    rows = []
    for seed in [20261009, 20261010]:
        for density in [1, 100, 300]:
            for trial in range(3):
                reverse = (seed+trial) % 2 == 1
                variants = list(VARIANTS)
                if reverse: variants.reverse()
                for variant in variants:
                    managed, paths, reuse, flags = VARIANTS[variant]
                    name = f'{seed}-{density}-{trial}-{variant}'
                    destination = args.out/name
                    command = ['/usr/bin/time', '-l', str(args.binary.resolve()), '--fixture', 'varied-v1',
                        '--mode', 'week', '--days', '365', '--density', str(density), '--seed', str(seed), '--out', str(destination), *flags]
                    if reverse: command.append('--reverse')
                    with HostMonitor(args.out/(name+'-host.json')) as host, (args.out/(name+'.log')).open('w') as log:
                        try: code = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=180).returncode
                        except subprocess.TimeoutExpired: code = 124
                    status = 'unmeasured'
                    report = destination/'report.json'
                    if code == 0 and report.exists():
                        status = raster.validate(json.loads(report.read_text()), seed, density, reverse, managed, paths, reuse)
                    rows.append({'name': name, 'variant': variant, 'command': command, 'exitCode': code,
                        'status': status, 'hostMonitor': host.report()})
                    (args.out/'summary.json').write_text(json.dumps(rows, indent=2)+'\n')
                    print(name, status, flush=True)
    return 1 if any(r['status'] == 'pixel-mismatch' for r in rows) else 2


if __name__ == '__main__':
    raise SystemExit(main())
