#!/usr/bin/env python3
"""Exercise the actual DayData initializer without starting the app/service graph.

The occurrence adapter is deliberately minimal; real UI coverage remains separate.
Extracted production code and compiler output are retained with every result.
"""
import argparse
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source', type=Path, default=ROOT / 'Banana/Views/WeekView.swift')
parser.add_argument('--out', type=Path, required=True)
args = parser.parse_args()
args.out.mkdir(parents=True, exist_ok=False)
source = args.source.read_text()
snapshot = source.split('    struct DayData: Identifiable, Equatable {', 1)[1].split(
    '    private typealias GridPlacement', 1)[0]
allocator = source.split('enum CalendarLaneAllocator {', 1)[1].split('private struct Stripes:', 1)[0]
stubs = '''import Foundation
enum Behavior { case event, block }
struct Occurrence: Equatable {
    let id: String
    let start: Date
    let resolvedEnd: Date
    var hasScheduledTime = true
    var behavior = Behavior.event
}
'''
generated = stubs + 'enum CalendarLaneAllocator {' + allocator
generated += '\nstruct WeekView { static let reuseGridLayouts = true\n'
generated += '    struct DayData: Identifiable, Equatable {' + snapshot + '\n}\n'
generated += (Path(__file__).parent / 'main.swift').read_text()
swift = args.out / 'main.swift'
swift.write_text(generated)
binary = args.out / 'checks'
command = ['swiftc', '-O', str(ROOT / 'Banana/Model/CalendarLanePlan.swift'),
           str(ROOT / 'Banana/Model/TimeRangeIndex.swift'), str(swift), '-o', str(binary)]
with (args.out / 'build.log').open('w') as log:
    build = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
result = {'command': command, 'buildExit': build.returncode, 'source': str(args.source)}
if build.returncode == 0:
    with (args.out / 'run.log').open('w') as log:
        run = subprocess.run([str(binary.resolve()), str((args.out / 'report.json').resolve())],
                             stdout=log, stderr=subprocess.STDOUT)
    result['runExit'] = run.returncode
(args.out / 'command.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result))
raise SystemExit(build.returncode or result.get('runExit', 2))
