#!/usr/bin/env python3
"""Retain a checked archive's symbols before replacing an installed Mac build's archive."""
import argparse
from pathlib import Path
import plistlib
import shutil
import subprocess


def uuids(path):
    result = subprocess.run(['dwarfdump', '--uuid', str(path)], capture_output=True,
                            text=True, check=True, timeout=30)
    return {line.split()[1].lower() for line in result.stdout.splitlines()
            if line.startswith('UUID:')}


def executable(app):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    return app / 'Contents/MacOS' / info['CFBundleExecutable']


def preserve(archive, installed_root, output, read_uuids=uuids):
    apps = list((archive / 'Products/Applications').glob('*.app'))
    if len(apps) != 1:
        return []
    app = apps[0]
    installed = installed_root / app.name
    if not installed.exists():
        return []
    wanted = read_uuids(executable(installed))
    if not wanted or wanted != read_uuids(executable(app)):
        return []  # A different candidate is not the installed app's symbol source.
    symbols = {p: read_uuids(p) for p in (archive / 'dSYMs').glob('*.dSYM')}
    if sum(identity == wanted for identity in symbols.values()) != 1:
        raise RuntimeError('Installed Mac build matches archive but matching symbols are missing; keep the archive')
    retained = []
    # Keep embedded frameworks and update helpers with their matching main executable too.
    for source, identity in symbols.items():
        if not identity:
            raise RuntimeError('Archive symbol UUID is missing; keep the archive')
        destination = output / sorted(wanted)[0] / source.name
        if destination.exists():
            if read_uuids(destination) != identity:
                raise RuntimeError('Retained symbols have a different UUID; keep the archive')
        else:
            destination.parent.mkdir(parents=True, exist_ok=True)
            try:
                shutil.copytree(source, destination)
                if read_uuids(destination) != identity:
                    raise RuntimeError('Copied symbols failed UUID verification; keep the archive')
            except BaseException:
                shutil.rmtree(destination, ignore_errors=True)
                raise
        retained.append(destination)
    return retained


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path)
    parser.add_argument('--installed-root', type=Path, default=Path('/Applications'))
    parser.add_argument('--out', type=Path, default=Path('.build/dsyms'))
    args = parser.parse_args()
    retained = preserve(args.archive, args.installed_root, args.out)
    print('Retained installed Mac symbol bundles:', len(retained))
