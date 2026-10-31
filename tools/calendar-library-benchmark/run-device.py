#!/usr/bin/env python3
"""Physical-device component matrix. Programmatic offsets do not prove input/display latency."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import time
import uuid
from report import summarize
from fixture_policy import matches_fixture


def cases(matrix='cache', densities=(100, 300), trials=3, selected_variant=None):
    result = []
    for trial in range(trials):
        for density in densities:
            variants = ['tile-prefetch', 'tile-prefetch-lookahead', 'tile-prefetch-budgeted']
            if matrix == 'accessibility-cache': variants = ['tile-prefetch-budgeted', 'tile-prefetch-ax-cache']
            if matrix == 'accessibility-lazy': variants = ['tile-prefetch-ax-cache', 'tile-prefetch-ax-lazy']
            if matrix == 'foreground-surface-accessibility': variants = ['tile-prefetch-async-surface', 'tile-prefetch-async-surface-lazy']
            if matrix == 'foreground-surface': variants = ['tile-prefetch-async-two', 'tile-prefetch-async-surface']
            if matrix == 'foreground-accessibility': variants = ['tile-prefetch-async-two', 'tile-prefetch-async-lazy']
            if matrix == 'foreground': variants = ['tile-prefetch-budgeted', 'tile-prefetch-async-one', 'tile-prefetch-async-two']
            if matrix == 'queue-cancel': variants = ['tile-prefetch-queue-two', 'tile-prefetch-queue-two-cancel']
            if matrix == 'queue': variants = ['tile-prefetch-budgeted', 'tile-prefetch-queue-one', 'tile-prefetch-queue-two']
            if matrix == 'native-text': variants = ['tile-prefetch-budgeted', 'tile-prefetch-native-text']
            if selected_variant is not None: variants = [selected_variant]
            if trial % 2: variants.reverse()
            for variant in variants:
                result.append((f'native-week-365d-{density}perday-{trial}-{variant}', density, variant))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True)
    parser.add_argument('--fixture', choices=['uniform-v1', 'varied-v1'], default='uniform-v1')
    parser.add_argument('--seed', type=int, default=20261009)
    parser.add_argument('--hidden-calendars', default='')
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--matrix', choices=['cache', 'accessibility-cache', 'accessibility-lazy', 'native-text', 'queue', 'queue-cancel', 'foreground', 'foreground-accessibility', 'foreground-surface', 'foreground-surface-accessibility'], default='cache')
    parser.add_argument('--navigation-stress', action='store_true', help='Append forward/return and 32 ms rapid paging coverage')
    parser.add_argument('--foreground-navigation', action='store_true', help='Append synchronous/async foreground paging sections and request-to-publication latency')
    parser.add_argument('--exercise-accessibility', action='store_true', help='Include complete accessibility enumeration inside every timed phase')
    parser.add_argument('--batch-event-fills', action='store_true', help='Experimental fill batching; acceptance remains subject to tail latency')
    parser.add_argument('--memo-raster-text', action='store_true')
    parser.add_argument('--densities', type=int, nargs='+', default=[100, 300])
    parser.add_argument('--trials', type=int, default=3)
    parser.add_argument('--days', type=int, default=365)
    parser.add_argument('--variant', choices=['tile-prefetch-budgeted', 'tile-prefetch-async-one', 'tile-prefetch-async-two', 'tile-prefetch-async-surface', 'tile-prefetch-async-surface-lazy'])
    args = parser.parse_args()
    if not all(1 <= n <= 1000 for n in args.densities) or not 1 <= args.trials <= 10 or not 30 <= args.days <= 3650:
        parser.error('Density must be 1...1000, trials 1...10 and days 30...3650')
    if args.memo_raster_text and args.matrix == 'native-text': parser.error('Text memo targets prepared glyphs, not native CTLine')
    if args.matrix in ('foreground', 'foreground-accessibility', 'foreground-surface', 'foreground-surface-accessibility') and not args.foreground_navigation:
        parser.error('--matrix foreground requires --foreground-navigation')
    if args.foreground_navigation and args.days < 210:
        parser.error('Foreground scenarios visit through day 189; retain at least 210 days to avoid empty out-of-history pages')
    bundle = 'com.boris.banana.calendar-library-benchmark'
    info = plistlib.loads((args.app / 'Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != bundle:
        parser.error('Only the isolated calendar benchmark bundle can be installed')
    args.out.mkdir(parents=True, exist_ok=False)

    def call(label, *command, timeout=60):
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            result = subprocess.CompletedProcess(command, 124, '', 'Command timed out')
        (args.out / (label + '.log')).write_text(result.stdout + result.stderr)
        return result

    metadata = dict(timestamp=datetime.datetime.now().astimezone().isoformat(), device=args.device,
                    app=str(args.app.resolve()), binarySHA256=hashlib.sha256(
                        (args.app / info['CFBundleExecutable']).read_bytes()).hexdigest(),
                    git=subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
                    dirty=subprocess.check_output(['git', 'status', '--porcelain'], text=True),
                    sceneManifest=info.get('UIApplicationSceneManifest'),
                    minimumFrameDurationDisabled=info.get('CADisableMinimumFrameDurationOnPhone', False),
                    scope='Physical device synchronous renderer work; input/display acceptance unmeasured', batchEventFills=args.batch_event_fills, memoRasterText=args.memo_raster_text,
                    fixture=args.fixture, seed=str(args.seed), hiddenCalendars=args.hidden_calendars, matrix=args.matrix, variant=args.variant, days=args.days, trials=args.trials, densities=args.densities, alternatingOrder=True,
                    navigationStress=args.navigation_stress, foregroundNavigation=args.foreground_navigation, accessibilityClient='all' if args.exercise_accessibility else 'none')
    (args.out / 'environment.json').write_text(json.dumps(metadata, indent=2) + '\n')
    matrix = cases(args.matrix, args.densities, args.trials, args.variant)
    matrix = [(name.replace('365d-', f'{args.days}d-'), density, variant) for name, density, variant in matrix]
    rows = [dict(scenario=name, status='unmeasured-not-started') for name, _, _ in matrix]
    def save():
        (args.out / 'summary.json').write_text(json.dumps(rows, indent=2)+'\n')
    save()  # Preserve every planned case even if installation or the runner is interrupted.
    installed = call('install', 'xcrun', 'devicectl', 'device', 'install', 'app', '--device', args.device,
                     str(args.app.resolve()))
    missing_results = 0
    for index, (name, density, variant) in enumerate(matrix):
        print('Measuring ' + name, flush=True)
        destination = args.out / (name + '.json')
        filename = 'result-' + str(uuid.uuid4()) + '.json'
        rows[index]['status'] = 'running-unmeasured'
        save()
        try:
            if installed.returncode:
                row = dict(scenario=name, status='blocked-install', exitCode=installed.returncode)
            elif missing_results >= 3:
                row = dict(scenario=name, status='blocked-repeated-launch-failure',
                           reason='Three consecutive cases produced no report; remaining coverage is unmeasured')
            else:
                started = time.monotonic()
                launched = call(name + '-launch', 'xcrun', 'devicectl', 'device', 'process', 'launch',
                                '--device', args.device, '--terminate-existing', bundle,
                                '--candidate', 'native', '--mode', 'week', '--days', str(args.days), '--density',
                                str(density), '--renderer', 'tiles', '--ablation', variant, '--output', filename,
                                '--fixture', args.fixture, '--seed', str(args.seed), '--hidden-calendars', args.hidden_calendars,
                                *(['--navigation-stress'] if args.navigation_stress else []),
                                *(['--exercise-accessibility'] if args.exercise_accessibility else []),
                                *(['--foreground-navigation'] if args.foreground_navigation else []),
                                *(['--batch-event-fills'] if args.batch_event_fills else []),
                                *(['--memo-raster-text'] if args.memo_raster_text else []))
                attempts = 0
                while launched.returncode == 0 and time.monotonic() - started < 90:
                    time.sleep(1)
                    attempts += 1
                    copied = call(name + f'-copy-{attempts}', 'xcrun', 'devicectl', 'device', 'copy', 'from',
                                  '--device', args.device, '--source', 'Documents/' + filename,
                                  '--domain-type', 'appDataContainer', '--domain-identifier', bundle,
                                  '--destination', str(destination.resolve()), timeout=20)
                    if copied.returncode == 0 and destination.exists(): break
                if destination.exists():
                    missing_results = 0
                    data = json.loads(destination.read_text())
                    row = dict(scenario=name, **summarize(data))
                    if any(data.get(key) != value for key, value in dict(candidate='native', mode='week',
                            days=args.days, eventsPerDay=density, retainedEvents=args.days*density).items()):
                        row['status'] = 'invalid-workload'
                    if not matches_fixture(data, args.fixture, args.seed, args.hidden_calendars):
                        row['status'] = 'invalid-fixture'
                    protocol = data.get('foregroundProtocol', {})
                    if protocol.get('version') != 1 or protocol.get('idleTimerDisabledDuringRun') is not True or protocol.get('activeAtCompletion') is not True or protocol.get('transitions') != []:
                        row['status'] = 'invalid-foreground-lifecycle'
                    if bool(data.get('memoRasterText')) != args.memo_raster_text: row['status'] = 'invalid-text-memo-policy'
                    if bool(data.get('batchEventFills')) != args.batch_event_fills: row['status'] = 'invalid-fill-policy'
                    if data.get('optimizations') != dict(renderer='tiles', ablation=variant):
                        row['status'] = 'invalid-policy'
                    if bool(data.get('navigationStress')) != args.navigation_stress:
                        row['status'] = 'invalid-navigation-policy'
                    if bool(data.get('foregroundNavigation')) != args.foreground_navigation:
                        row['status'] = 'invalid-foreground-policy'
                    if (data.get('accessibilityClient') == 'all') != args.exercise_accessibility:
                        row['status'] = 'invalid-accessibility-client'
                else:
                    missing_results += 1
                    row = dict(scenario=name, status='failed-or-timeout', launchExit=launched.returncode,
                               elapsedSeconds=time.monotonic()-started)
        except KeyboardInterrupt:
            rows[index] = dict(scenario=name, status='interrupted-unmeasured')
            save()
            return 2
        if not destination.exists(): destination.write_text(json.dumps(row, indent=2)+'\n')
        rows[index] = row
        save()
    return 1 if any(r['status'] != 'measured' or r.get('acceptance') == 'fail' for r in rows) else 2


if __name__ == '__main__':
    raise SystemExit(main())
