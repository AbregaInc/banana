#!/usr/bin/env python3
"""Compare native viewport lookups using real AppKit and stock iOS Simulator types."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--out', type=Path, required=True)
options = parser.parse_args()
out = options.out.resolve()
out.mkdir(parents=True, exist_ok=False)
views = root / 'Banana/Views'
main = Path(__file__).with_name('main.swift')
sources = [views / name for name in ('CalendarMacCollectionView.swift', 'CalendarDayCollectionView.swift',
                                    'CalendarViewportEnvironment.swift')]


def declaration(source, kind, name):
    text = source.read_text()
    start = text.index(f'{kind} {name} {{')
    return text[start:text.index('\n}', start) + 2]


rows = out / 'Rows.swift'
rows.write_text('\n'.join(['import SwiftUI', '#if os(macOS)',
                           declaration(sources[0], 'struct', 'CalendarMacViewportItem'),
                           'typealias Row = CalendarMacViewportItem', '#else',
                           declaration(sources[1], 'struct', 'CalendarViewportItem'),
                           declaration(sources[1], 'struct', 'CalendarViewportMove'),
                           'typealias Row = CalendarViewportItem', '#endif',
                           declaration(sources[2], 'enum', 'CalendarViewportAttributes')]))
(out / 'sources.json').write_text(json.dumps({str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
                                             for p in [*sources, main]}, indent=2) + '\n')
sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
for platform in ('mac', 'ios'):
    flags = [] if platform == 'mac' else ['-sdk', sdk, '-target', 'arm64-apple-ios18.0-simulator']
    binary = out / platform
    subprocess.run([root / 'tools/agents/xcode-lock.sh', '-l', 'build', 'swiftc', '-O',
                    '-whole-module-optimization', *flags, rows, main, '-o', binary], check=True, cwd=root)
    command = [binary] if platform == 'mac' else [
        root / 'tools/simulator-run.sh', 'pad', 'stock', out / 'prep', '--', 'zsh', '-c',
        '. tools/config.sh; exec xcrun simctl spawn "$BANANA_SIM_PAD" "$1"', 'query', binary]
    with (out / (platform + '.jsonl')).open('w') as output:
        subprocess.run(command, check=True, stdout=output, cwd=root)
