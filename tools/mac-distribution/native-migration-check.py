#!/usr/bin/env python3
"""Check macOS container migration with disposable, background-only fixture apps.
No application windows, production data, or production identities are used.
"""
import argparse
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import uuid

SOURCE = r'''
import Foundation
let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
let file = support.appendingPathComponent("MigrationFixture/data.txt")
let value = (try? String(contentsOf: file, encoding: .utf8)) ?? "missing"
let output: [String: Any] = ["data": value, "sandboxed": NSHomeDirectory().contains("/Library/Containers/"), "preference": UserDefaults.standard.string(forKey: "migrationFixtureValue") ?? "missing"]
let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
FileHandle.standardOutput.write(data)
'''


def run(*args):
    return subprocess.run([str(a) for a in args], capture_output=True, check=True, timeout=60)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--identity-file', type=Path, required=True)
    p.add_argument('--out', type=Path, required=True)
    a = p.parse_args()
    identity = a.identity_file.read_text().strip()
    results = []
    with tempfile.TemporaryDirectory(prefix='banana-native-migration-') as tmp:
        tmp = Path(tmp)
        source = tmp / 'probe.swift'; source.write_text(SOURCE)
        executable = tmp / 'probe'
        run('xcrun', 'swiftc', source, '-o', executable)
        entitlements = tmp / 'sandbox.plist'
        entitlements.write_bytes(plistlib.dumps({'com.apple.security.app-sandbox': True}))
        for existing_container in [False, True]:
            identifier = 'org.example.banana.migration-probe.' + uuid.uuid4().hex
            legacy = Path.home() / 'Library/Application Support' / identifier
            legacy.mkdir()
            (legacy / 'data.txt').write_text('retained legacy data')
            app = tmp / (identifier + '.app')
            contents = app / 'Contents'; (contents / 'MacOS').mkdir(parents=True)
            (contents / 'Resources').mkdir()
            shutil.copyfile(executable, contents / 'MacOS/probe')
            (contents / 'MacOS/probe').chmod(0o755)
            (contents / 'Info.plist').write_bytes(plistlib.dumps({
                'CFBundleIdentifier': identifier, 'CFBundleExecutable': 'probe',
                'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1',
                'LSBackgroundOnly': True,
            }))
            def sign():
                run('codesign', '--force', '--sign', identity, '--options', 'runtime',
                    '--entitlements', entitlements, app)
            if existing_container:
                sign()
                initial = json.loads(run(contents / 'MacOS/probe').stdout)
                assert initial['sandboxed'] and initial['data'] == 'missing', initial
            (contents / 'Resources/container-migration.plist').write_bytes(plistlib.dumps({
                'Move': [['${ApplicationSupport}/' + identifier + '/data.txt',
                          '${ApplicationSupport}/MigrationFixture/data.txt']]
            }))
            sign()
            first = json.loads(run(contents / 'MacOS/probe').stdout)
            (legacy / 'data.txt').write_text('later local data')
            second = json.loads(run(contents / 'MacOS/probe').stdout)
            preference_path = Path.home() / 'Library/Containers' / identifier / 'Data/Library/Preferences' / identifier
            run('defaults', 'write', preference_path, 'migrationFixtureValue', '-string', 'preserved preference')
            preference = json.loads(run(contents / 'MacOS/probe').stdout)
            assert preference['preference'] == 'preserved preference', preference
            results.append({'existingContainer': existing_container, 'first': first, 'second': second, 'preferenceImport': preference['preference']})
            # Only this invocation's synthetic source fixture is removed. Containers remain
            # tiny retained evidence; never erase a user's existing app container.
            shutil.rmtree(legacy)
    a.out.parent.mkdir(parents=True, exist_ok=True)
    a.out.write_text(json.dumps(results, indent=2) + '\n')
    print(json.dumps(results))
    assert results[0]['first']['data'] == 'retained legacy data'
    assert results[0]['second']['data'] == 'retained legacy data'
    assert results[1]['first']['data'] == 'missing'


if __name__ == '__main__':
    main()
