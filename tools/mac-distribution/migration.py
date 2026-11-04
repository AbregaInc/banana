#!/usr/bin/env python3
"""Prepare verified, private snapshots before a local-to-sandbox migration.

Never changes a live store. Stops if Banana is running, a source changes during
copy, a symlink would escape the source, or a staged SQLite database is invalid.
The chosen snapshot can be reviewed before the installation changes any live data.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import sqlite3
import subprocess

ROOTS_FILE = Path(__file__).with_name('app-support-roots.json')


def roots():
    names = json.loads(ROOTS_FILE.read_text())
    if len(names) != len(set(names)) or any(Path(n).name != n or n in ('', '.', '..') for n in names):
        raise ValueError('Migration roots must be unique, explicit basenames')
    return names


def digest(path):
    with path.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def inventory(source, names):
    result = {}
    for name in names:
        path = source / name
        if path.is_symlink():
            raise ValueError('Refusing a symlink in migration input: ' + name)
        if not path.exists():
            continue
        for file in ([path] if path.is_file() else sorted(path.rglob('*'))):
            if file.is_symlink():
                raise ValueError('Refusing a symlink in migration input: ' + str(file.relative_to(source)))
            if file.is_file():
                result[str(file.relative_to(source))] = {'bytes': file.stat().st_size, 'sha256': digest(file)}
    return result


def snapshot(source, destination, names):
    if destination.exists():
        raise ValueError('Existing snapshots are preserved; choose a new directory')
    before = inventory(source, names)
    destination.mkdir(parents=True, mode=0o700)
    for name in names:
        path = source / name
        if not path.exists():
            continue
        if path.is_dir():
            shutil.copytree(path, destination / name)
        else:
            shutil.copy2(path, destination / name)
    if inventory(source, names) != before or inventory(destination, names) != before:
        raise RuntimeError('Store changed during snapshot or copy verification failed; do not migrate')
    for db in destination.rglob('*.sqlite'):
        connection = sqlite3.connect(db.resolve().as_uri() + '?mode=ro', uri=True)
        try:
            if connection.execute('PRAGMA quick_check').fetchall() != [('ok',)]:
                raise RuntimeError('Invalid SQLite snapshot: ' + str(db.relative_to(destination)))
        finally:
            connection.close()
    return {'source': before, 'snapshot': inventory(destination, names)}


def require_stopped():
    for name in ['Banana', 'BananaMac']:
        result = subprocess.run(['pgrep', '-x', name], capture_output=True)
        if result.returncode == 0:
            raise RuntimeError('Quit Banana before taking a migration snapshot')
        if result.returncode != 1:
            raise RuntimeError('Could not verify that Banana is stopped')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle-id', required=True)
    parser.add_argument('--source', choices=['local', 'sandbox'], required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    if '/' in args.bundle_id or args.bundle_id in ('', '.', '..'):
        parser.error('Invalid bundle identifier')
    require_stopped()
    if args.out.exists():
        parser.error('Snapshot output already exists')
    args.out.mkdir(parents=True, mode=0o700)
    subprocess.run(['tmutil', 'addexclusion', str(args.out.resolve())], check=True, capture_output=True)
    libraries = {
        'local': Path.home() / 'Library',
        'sandbox': Path.home() / 'Library/Containers' / args.bundle_id / 'Data/Library',
    }
    report = {'selectedSource': args.source, 'stores': {}}
    for kind, library in libraries.items():
        support = library / 'Application Support'
        files = snapshot(support, args.out / kind / 'Application Support', roots())
        domain = args.bundle_id if kind == 'local' else str(library / 'Preferences' / args.bundle_id)
        pref = subprocess.run(['defaults', 'export', domain, '-'], capture_output=True)
        if pref.returncode == 0:
            plistlib.loads(pref.stdout)
            (args.out / kind / 'preferences.plist').write_bytes(pref.stdout)
        elif (library / 'Preferences' / (args.bundle_id + '.plist')).exists():
            raise RuntimeError('Could not export existing preferences; snapshot is incomplete')
        report['stores'][kind] = files
    require_stopped()
    (args.out / 'manifest.json').write_text(json.dumps(report, indent=2) + '\n')
    print('Verified snapshots prepared. Live data is unchanged.')


if __name__ == '__main__':
    main()
