#!/usr/bin/env python3
"""Compile actual Calendar search query routing; no account, device, or UI access."""
import argparse, hashlib, json, shutil, subprocess
from pathlib import Path
root = Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--out', required=True, type=Path)
a = p.parse_args()
a.out.mkdir(parents=True, exist_ok=False)
source = root / 'Banana/Model/CalendarSearchQuery.swift'
shutil.copy2(source, a.out / source.name)
shutil.copy2(Path(__file__).with_name('main.swift'), a.out / 'Checks.swift')
cmd = ['swiftc', '-O', str(a.out/source.name), str(root/'Banana/Model/LiveFilter.swift'), str(a.out/'Checks.swift'), '-o', str(a.out/'checks')]
with (a.out/'build.log').open('w') as log:
    result = subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT)
if result.returncode == 0:
    with (a.out/'run.log').open('w') as log:
        result = subprocess.run([str((a.out/'checks').resolve())], stdout=log, stderr=subprocess.STDOUT)
(a.out/'status.json').write_text(json.dumps({'command': cmd, 'exitCode': result.returncode,
    'sourceSHA256': hashlib.sha256(source.read_bytes()).hexdigest(),
    'scope': 'Query URL correctness only; provider, UI and timing acceptance remain unmeasured'}, indent=2))
raise SystemExit(result.returncode)
