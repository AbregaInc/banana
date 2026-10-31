#!/usr/bin/env python3
"""Check production calendar read/ownership windows against the travel horizon, without accounts."""
import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--out', required=True, type=Path)
args = parser.parse_args()
args.out.mkdir(parents=True, exist_ok=False)

sources = {name: (root / 'Banana/Model' / name).read_text() for name in
           ['OccurrenceStore.swift', 'GoogleCalendarService.swift', 'CalendarWriteBack.swift']}
days = int(re.search(r'static let writeBackTravelHorizonDays = (\d+)', sources['OccurrenceStore.swift'])[1])
assert 'var horizonDays = OccurrenceStore.writeBackTravelHorizonDays' in sources['OccurrenceStore.swift']

def method(source, name):
    start = source.index('    private static func ' + name + '(')
    brace = source.index('{', start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end].replace('private static func', 'static func', 1)

program = 'import Foundation\nenum OccurrenceStore { static let writeBackTravelHorizonDays = ' + str(days) + ' }\nenum Windows {\n'
program += method(sources['GoogleCalendarService.swift'], 'coreWindow') + '\n'
program += method(sources['CalendarWriteBack.swift'], 'ownershipWindow') + '\n}\n'
program += r'''
var failures: [String] = []
func check(_ condition: Bool, _ message: String) {
    if !condition { failures.append(message) }
}
var checks = 0
for zone in ["UTC", "America/New_York", "Europe/London", "Australia/Lord_Howe"] {
    NSTimeZone.default = TimeZone(identifier: zone)!
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    for (month, day) in [(1, 1), (3, 1), (10, 21), (11, 1)] {
        let now = calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 23, minute: 59))!
        let today = calendar.startOfDay(for: now)
        let plannedEnd = calendar.date(byAdding: .day, value: OccurrenceStore.writeBackTravelHorizonDays, to: today)!
        let read = Windows.coreWindow(now: now)
        let owned = Windows.ownershipWindow(now: now)
        check(read.start <= owned.0 && read.end > owned.1, "Shared read must cover ownership cleanup: \(zone)")
        check(owned.0 < today && owned.1 > plannedEnd, "Reconciliation must cover all planned travel: \(zone)")
        check(calendar.dateComponents([.day], from: today, to: plannedEnd).day == 90, "Ninety local days, including DST")
        if month == 10 && day == 21 {
            let appointment = calendar.date(from: DateComponents(year: 2026, month: 12, day: 15, hour: 14))!
            let expectedEnd = calendar.date(from: DateComponents(year: 2027, month: 1, day: 19))!
            check(plannedEnd == expectedEnd && appointment < plannedEnd, "December appointment is planned")
            check(read.start < appointment && read.end > appointment, "December appointment uses the shared read")
        }
        checks += 1
    }
}
if !failures.isEmpty {
    for failure in failures { print("FAIL: " + failure) }
    exit(1)
}
print("Passed \(checks) production-window checks across four timezones, including December and DST.")
'''
(args.out / 'main.swift').write_text(program)
command = ['swiftc', '-O', str(args.out/'main.swift'), '-o', str(args.out/'checks')]
with (args.out/'build.log').open('w') as log:
    result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
if result.returncode == 0:
    with (args.out/'run.log').open('w') as log:
        result = subprocess.run([str((args.out/'checks').resolve())], stdout=log, stderr=subprocess.STDOUT)
(args.out/'status.json').write_text(json.dumps({'exitCode': result.returncode, 'horizonDays': days,
    'sourceSHA256': {name: hashlib.sha256(text.encode()).hexdigest() for name, text in sources.items()},
    'scope': 'Production date-window correctness only; no live provider, routing or UI performance claim.'}, indent=2))
raise SystemExit(result.returncode)
