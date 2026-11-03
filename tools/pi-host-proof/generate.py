#!/usr/bin/env python3
"""Bundle reviewed, unchanged Pi source and the Apple host compatibility layer."""
import pathlib
import subprocess
import sys
import shutil
import json
import hashlib

repo = pathlib.Path(__file__).resolve().parents[2]
upstream = pathlib.Path(sys.argv[1]).resolve()
expected_commit = 'ede2c9b468d8e061c557d16957513715e6d49cd6'
commit = subprocess.check_output(['git', '-C', str(upstream), 'rev-parse', 'HEAD'], text=True).strip()
if commit != expected_commit:
    raise SystemExit(f'Expected reviewed upstream commit {expected_commit}; found {commit}. Review the host before upgrading.')
subprocess.run(['git', '-C', str(upstream), 'diff', '--exit-code', 'HEAD', '--',
                'packages/durable', 'packages/ai', 'packages/chord', 'packages/telemetry'], check=True)
output = repo / '.build/sim/pi-host-proof-sources'
subprocess.run(['node', str(repo / 'tools/pi-host-proof/runtime/build.mjs'), str(upstream), str(output)], check=True, cwd=repo)
resources = repo / 'Banana/Pi/Resources'
resources.mkdir(parents=True, exist_ok=True)
for source, destination in [('bootstrap.js', 'pi-bootstrap.js'), ('app.js', 'pi-agent.js')]:
    shutil.copyfile(output / source, resources / destination)
manifest = {'upstream': 'https://github.com/earendil-works/pi', 'commit': expected_commit,
            'files': {name: hashlib.sha256((resources / name).read_bytes()).hexdigest() for name in ['pi-bootstrap.js', 'pi-agent.js']}}
(resources / 'pi-runtime-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
# Notices follow the packages actually included by esbuild, including transitive dependencies.
packages = {}
inputs = {}
for metadata in ['app-metafile.json', 'bootstrap-metafile.json']:
    inputs.update(json.loads((output / metadata).read_text())['inputs'])
for name in inputs:
    parent = (repo / name).resolve().parent
    while parent != parent.parent:
        metadata = parent / 'package.json'
        if metadata.exists():
            package = json.loads(metadata.read_text())
            if package.get('name'):
                packages[package['name']] = (parent, package)
            break
        parent = parent.parent
notices = ['Banana Pi runtime: third-party notices\n', 'Reviewed upstream commit: ' + expected_commit + '\n']
for name, (root, package) in sorted(packages.items()):
    notices.append('\n' + name + ' ' + package.get('version', '') + '\n')
    license_files = [path for path in root.iterdir() if path.is_file() and path.name.lower() in ['license', 'license.md', 'license.txt', 'licence']]
    if name.startswith('@earendil-works/') and not license_files:
        license_files = [upstream / 'LICENSE']
    for path in license_files:
        notices.append(path.read_text(errors='replace') + '\n')
(resources / 'pi-notices.txt').write_text('\n'.join(notices))
print(output)
