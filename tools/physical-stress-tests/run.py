#!/usr/bin/env python3
"""Launch isolation checks; no app launch or performance claim."""
import argparse
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--out', type=Path, required=True)
args = parser.parse_args()
args.out.mkdir(parents=True, exist_ok=False)
root = Path(__file__).resolve().parents[2]
sources = ['Banana/Model/PhysicalStressReview.swift', 'tools/physical-stress-tests/main.swift']
results = []
for name, flags, accepted in [
    ('ordinary', [], True),
    ('physical-review', ['-D', 'DEBUG', '-D', 'STRESS_DEVICE_AUDIT'], True),
    ('missing-debug', ['-D', 'STRESS_DEVICE_AUDIT'], False),
]:
    binary = (args.out / name).resolve()
    command = ['swiftc', '-O', *flags, *sources, '-o', str(binary)]
    run = subprocess.run(command, cwd=root, text=True, stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT, timeout=120)
    (args.out / f'{name}-build.log').write_text(run.stdout)
    result = dict(name=name, command=command, compileExit=run.returncode)
    results.append(result)
    (args.out / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    if accepted:
        assert run.returncode == 0, run.stdout
        check = subprocess.run([str(binary)], text=True, capture_output=True, timeout=30)
        result.update(testExit=check.returncode, output=check.stdout + check.stderr)
        (args.out / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        assert check.returncode == 0 and '43 checks passed' in check.stdout, result
    else:
        assert run.returncode != 0 and 'STRESS_DEVICE_AUDIT requires DEBUG' in run.stdout, result
    (args.out / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
print('43 launch-policy checks passed in both configurations; missing DEBUG rejected')
