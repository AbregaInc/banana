#!/usr/bin/env python3
"""Compile the actual guide and test windowless geometry, status and rendering contracts."""
import argparse, hashlib, json, pathlib, subprocess
root = pathlib.Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser()
p.add_argument('--out', type=pathlib.Path, required=True)
a = p.parse_args()
a.out.mkdir(parents=True, exist_ok=False)
sources = ['Banana/Model/SystemSettingsLink.swift', 'Banana/Views/MacPermissionGuide.swift', 'tools/mac-permission-guide-tests/main.swift']
report = {'sources': {s: hashlib.sha256((root / s).read_bytes()).hexdigest() for s in sources}, 'scope': 'Windowless geometry, state and rendering; native Settings lifecycle and physical performance unmeasured'}
binary = (a.out / 'checks').resolve()
with (a.out / 'build.log').open('w') as log:
    build = subprocess.run([str(root / 'tools/agents/xcode-lock.sh'), 'swiftc', '-O', *sources, '-o', str(binary)], cwd=root, stdout=log, stderr=subprocess.STDOUT)
report['buildExit'] = code = build.returncode
if code == 0:
    with (a.out / 'run.log').open('w') as log:
        run = subprocess.run([str(binary), str((a.out / 'guide.png').resolve())], cwd=root, stdout=log, stderr=subprocess.STDOUT, timeout=30)
    report['runExit'] = code = run.returncode
(a.out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report))
raise SystemExit(code)
