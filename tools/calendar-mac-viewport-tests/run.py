#!/usr/bin/env python3
"""Compile the actual AppKit adapter and check its layout contract without opening windows."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--out', type=Path, required=True)
args = parser.parse_args()
args.out.mkdir(parents=True, exist_ok=False)
sources = [root / 'Banana/Views/CalendarViewportEnvironment.swift', root / 'Banana/Views/CalendarMacCollectionView.swift', Path(__file__).with_name('main.swift')]
result = {'sources': {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}}
command = ['swiftc', '-O', *map(str, sources), '-o', str(args.out / 'checks')]
result['command'] = command
with (args.out / 'build.log').open('w') as log:
    built = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
result['buildExit'] = built.returncode
code = built.returncode
if code == 0:
    with (args.out / 'run.log').open('w') as log:
        run = subprocess.run([str((args.out / 'checks').resolve())], stdout=log, stderr=subprocess.STDOUT)
    code = run.returncode
    result['runExit'] = code
result['scope'] = 'AppKit layout contract only; no cell lifecycle, window interaction or timing acceptance'
(args.out / 'report.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result))
raise SystemExit(code)
