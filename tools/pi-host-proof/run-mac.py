#!/usr/bin/env python3
"""Run checks in actual JavaScriptCore; remove the temporary Mac binary and databases."""
import argparse
import json
import pathlib
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--mode', default='host-conformance', choices=['workspace-conformance', 'nutrition-conformance', 'host-conformance', 'provider-conformance', 'foundation-text', 'foundation-tool', 'foundation-roundtrip', 'foundation-interruption', 'lifecycle-roundtrip', 'lifecycle-conformance'])
args = parser.parse_args()
repo = pathlib.Path(__file__).resolve().parents[2]
sources = pathlib.Path(__file__).resolve().parent
output = repo / '.build/mac-check'
output.mkdir(parents=True, exist_ok=True)
executable = output / 'pi-host-proof'
reports = repo / 'docs/research/pi-apple-host-results'
reports.mkdir(parents=True, exist_ok=True)
try:
    subprocess.run(['swiftc', str(repo / 'Banana/Pi/AppleRuntimeHost.swift'), str(repo / 'Banana/Pi/AppleFoundationModel.swift'), str(sources / 'ProofHooks.swift'), str(sources / 'MacRunner.swift'),
                    '-o', str(executable), '-framework', 'JavaScriptCore', '-framework', 'Security', '-framework', 'FoundationModels', '-lsqlite3'], check=True)
    with tempfile.TemporaryDirectory(prefix='banana-pi-shims-') as directory:
        modes = (['foundation-tool', 'foundation-reopen'] if args.mode == 'foundation-roundtrip' else
                 ['foundation-crash-first', 'foundation-crash-reopen'] if args.mode == 'foundation-interruption' else
                 ['lifecycle-first', 'lifecycle-reopen'] if args.mode == 'lifecycle-roundtrip' else [args.mode])
        for mode in modes:
            result = subprocess.run([str(executable), str(repo / '.build/sim/pi-host-proof-sources'),
                                     mode, str(pathlib.Path(directory) / 'host.sqlite')],
                                    text=True, capture_output=True, timeout=100)
            (reports / f'mac-{mode}.console.txt').write_text(result.stdout + result.stderr)
            if mode == 'foundation-crash-first':
                effect = pathlib.Path(directory) / 'host.sqlite.effect'
                if (result.returncode != 42 or 'Exiting process during native tool' not in result.stdout
                        or not effect.exists() or effect.read_text() != 'native tool effect happened\n'):
                    raise SystemExit(f'Expected interruption after native effect: {result.stdout}{result.stderr}')
                (reports / 'mac-foundation-effect.txt').write_text(effect.read_text())
                print('Mac: native effect confirmed before abrupt exit 42', flush=True)
                continue
            lines = result.stdout.strip().splitlines()
            if not lines:
                raise SystemExit(f'No result for {mode}: {result.stderr}')
            try:
                report = json.loads(lines[-1])
            except json.JSONDecodeError:
                raise SystemExit(result.stdout + result.stderr)
            (reports / f'mac-{mode}.json').write_text(json.dumps(report, indent=2) + '\n')
            print(json.dumps({key: value for key, value in report.items() if key != 'results'}, indent=2), flush=True)
            if result.returncode or not report.get('passed'):
                raise SystemExit(result.returncode or 1)
finally:
    executable.unlink(missing_ok=True)
