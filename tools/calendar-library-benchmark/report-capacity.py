#!/usr/bin/env python3
"""Aggregate retained physical component runs without certifying UI capacity."""
import argparse
import hashlib
import json
import math
from collections import defaultdict
from pathlib import Path


def aggregate(directories):
    groups = defaultdict(list)
    invalid = []
    sources = []
    seen = set()
    for directory in directories:
        directory = Path(directory)
        if directory.resolve() in seen:
            raise ValueError('Duplicate run directory')
        seen.add(directory.resolve())
        env = json.loads((directory / 'environment.json').read_text())
        summary_path = directory / 'summary.json'
        sources.append({'path': str(summary_path), 'sha256': hashlib.sha256(summary_path.read_bytes()).hexdigest()})
        for row in json.loads(summary_path.read_text()):
            if row.get('status') != 'measured':
                invalid.append({'source': str(directory), 'scenario': row['scenario'], 'status': row.get('status')})
                continue
            raw = json.loads((directory / (row['scenario'] + '.json')).read_text())
            phases, foreground = row['phases'], row.get('foregroundPhases', {})
            required = {'coldMount', 'page', 'uncachedPage', 'memoryPressurePage', 'resize',
                        'forwardPage', 'returnPage', 'rapidForwardPage', 'rapidReturnPage', 'scrollOffset'}
            if not required.issubset(phases) or len(foreground) != 8:
                raise ValueError('Incomplete capacity phases: ' + row['scenario'])
            fixture = raw['fixture']
            if fixture['profile'] != 'varied-v1' or fixture['calendarCount'] != 12:
                raise ValueError('Capacity requires varied multi-calendar fixture')
            if raw['retainedEvents'] != raw['days'] * raw['eventsPerDay']:
                raise ValueError('Incorrect retained history')
            key = (env['device'], env['binarySHA256'], env['variant'], raw['days'],
                   raw['eventsPerDay'], tuple(fixture['hiddenCalendars']), env['accessibilityClient'])
            sync = max(v['maxMS'] for k, v in phases.items() if k != 'scrollOffset')
            response = max(v['responseMS']['maxMS'] for v in foreground.values())
            run = {
                'source': str(directory / (row['scenario'] + '.json')),
                'seed': str(fixture['seed']), 'checksum': fixture['contentChecksum'],
                'retainedEvents': raw['retainedEvents'], 'peakDailyEvents': fixture['maximumDailyEvents'],
                'sevenDayBlockEvents': fixture['sevenDayBlockEvents'],
                'synchronousMaxMS': sync, 'foregroundResponseMaxMS': response,
                'foregroundMainSectionMaxMS': max(v['maxMainSectionMS']['maxMS'] for v in foreground.values()),
                'scrollP95MS': phases['scrollOffset']['p95MS'],
                'scrollMaxMS': phases['scrollOffset']['maxMS'],
                'thermalState': raw['thermalStateAtCompletion'],
                'lowPowerMode': raw['lowPowerModeAtCompletion'],
            }
            if any(not math.isfinite(v) or v < 0 for k, v in run.items() if k.endswith('MS')):
                raise ValueError('Invalid timing sample')
            groups[key].append(run)
    output = []
    for key, runs in sorted(groups.items()):
        seeds = {seed: sum(r['seed'] == seed for r in runs) for seed in sorted({r['seed'] for r in runs})}
        confirmed = len(seeds) >= 2 and min(seeds.values()) >= 3
        def maximum(field):
            return max(r[field] for r in runs)
        ui = max(maximum('synchronousMaxMS'), maximum('foregroundResponseMaxMS'))
        output.append({
            'device': key[0], 'binarySHA256': key[1], 'variant': key[2], 'days': key[3],
            'averageEventsPerDay': key[4], 'hiddenCalendars': key[5], 'accessibilityClient': key[6],
            'repeatsBySeed': seeds, 'minimumRepeatCoverage': confirmed,
            'maximumComponentResponseMS': ui,
            'componentResponseWithin100MS': ui <= 100,
            'allSynchronousWorkWithin8_3MS': maximum('synchronousMaxMS') <= 8.3 and maximum('scrollMaxMS') <= 8.3,
            'foregroundMainSectionsWithin8_3MS': maximum('foregroundMainSectionMaxMS') <= 8.3,
            'scrollComponentsWithin10_20MS': maximum('scrollP95MS') < 10 and maximum('scrollMaxMS') <= 20,
            'runs': runs,
        })
    return {'schemaVersion': 1, 'scope': 'Component boundaries only; full input/display/UI capacity unmeasured',
            'acceptance': 'unmeasured', 'sources': sources, 'invalidOrIncompleteRuns': invalid, 'groups': output}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directories', type=Path, nargs='+')
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    result = aggregate(args.directories)
    with args.out.open('x') as file:
        json.dump(result, file, indent=2)
        file.write('\n')
    for group in result['groups']:
        print(group['device'], group['days'], group['averageEventsPerDay'],
              round(group['maximumComponentResponseMS'], 2), group['componentResponseWithin100MS'],
              group['repeatsBySeed'])
    return 2  # No component report can certify full UI acceptance.


if __name__ == '__main__':
    raise SystemExit(main())
