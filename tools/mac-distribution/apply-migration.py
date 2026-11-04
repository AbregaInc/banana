#!/usr/bin/env python3
"""Apply a chosen local snapshot to an existing sandbox while Banana is stopped.

Both snapshots and displaced sandbox files are retained. No local source is edited.
The transaction journal also records recovery paths if the process is interrupted.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import subprocess

spec = importlib.util.spec_from_file_location('migration', Path(__file__).with_name('migration.py'))
migration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(migration)


def replace_roots(source, target, transaction, names, expected, before_commit, commit, rollback):
    if transaction.exists():
        raise ValueError('Preserve existing transactions; use a new directory')
    transaction.mkdir(mode=0o700)
    staged = transaction / 'staged'
    migration.snapshot(source, staged, names)
    staged_inventory = migration.inventory(staged, names)
    displaced = transaction / 'displaced'
    displaced.mkdir(mode=0o700)
    if migration.inventory(target, names) != expected:
        raise RuntimeError('Sandbox changed since backup; take new snapshots')
    before_commit()
    moved_old, moved_new = [], []
    journal = {'status': 'prepared', 'target': str(target), 'names': names}
    def record(status):
        journal.update(status=status, displaced=moved_old, installed=moved_new)
        (transaction / 'journal.json').write_text(json.dumps(journal, indent=2) + '\n')
    record('applying')
    try:
        for name in names:
            old, new = target / name, staged / name
            if old.exists():
                old.rename(displaced / name)
                moved_old.append(name)
                record('applying')
            if new.exists():
                new.rename(old)
                moved_new.append(name)
                record('applying')
        if migration.inventory(target, names) != staged_inventory:
            raise RuntimeError('Applied data does not match chosen snapshot')
        commit()
        record('complete')
    except BaseException:
        # Keep attempted new data too, rather than deleting any copy on failure.
        for name in reversed(moved_new):
            (target / name).rename(staged / name)
        for name in reversed(moved_old):
            (displaced / name).rename(target / name)
        rollback()
        record('rolled-back')
        raise


def export_preferences(domain):
    result = subprocess.run(['defaults', 'export', str(domain), '-'], capture_output=True, check=True)
    return plistlib.loads(result.stdout)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle-id', required=True)
    parser.add_argument('--snapshot', type=Path, required=True)
    args = parser.parse_args()
    if Path(args.bundle_id).name != args.bundle_id or args.bundle_id in ('', '.', '..'):
        parser.error('Invalid bundle identifier')
    migration.require_stopped()
    backup = args.snapshot.resolve()
    manifest = json.loads((backup / 'manifest.json').read_text())
    if manifest['selectedSource'] != 'local':
        parser.error('This operation requires an explicitly selected local source')
    libraries = {'local': Path.home() / 'Library',
                 'sandbox': Path.home() / 'Library/Containers' / args.bundle_id / 'Data/Library'}
    names = migration.roots()
    for kind, library in libraries.items():
        if migration.inventory(library / 'Application Support', names) != manifest['stores'][kind]['source']:
            raise RuntimeError('Live store changed since backup: ' + kind)
        if migration.inventory(backup / kind / 'Application Support', names) != manifest['stores'][kind]['snapshot']:
            raise RuntimeError('Snapshot changed: ' + kind)
        preference = backup / kind / 'preferences.plist'
        if not preference.exists():
            raise RuntimeError('This migration requires both preference exports')
        domain = args.bundle_id if kind == 'local' else library / 'Preferences' / args.bundle_id
        if export_preferences(domain) != plistlib.loads(preference.read_bytes()):
            raise RuntimeError('Preferences changed since backup: ' + kind)
    domain = libraries['sandbox'] / 'Preferences' / args.bundle_id
    def restore(kind):
        subprocess.run(['defaults', 'import', str(domain), str(backup / kind / 'preferences.plist')],
                       capture_output=True, check=True)
        if export_preferences(domain) != plistlib.loads((backup / kind / 'preferences.plist').read_bytes()):
            raise RuntimeError('Preference import verification failed')
    replace_roots(backup / 'local/Application Support', libraries['sandbox'] / 'Application Support',
                  backup / 'apply-transaction', names, manifest['stores']['sandbox']['source'],
                  migration.require_stopped, lambda: restore('local'), lambda: restore('sandbox'))
    print('Local snapshot applied and verified. Both backups and displaced sandbox files retained.')


if __name__ == '__main__':
    main()
