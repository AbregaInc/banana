#!/usr/bin/env python3
"""Compare serial/concurrent pixels on a physical device; does not measure UI latency."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import time
import uuid
from fixture_policy import matches_fixture


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True)
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--out', required=True, type=Path)
    parser.add_argument('--fixture', choices=['uniform-v1', 'varied-v1'], default='varied-v1')
    parser.add_argument('--seed', type=int, default=20261009)
    parser.add_argument('--memo-raster-text', action='store_true')
    args = parser.parse_args()
    bundle = 'com.boris.banana.calendar-library-benchmark'
    info = plistlib.loads((args.app / 'Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != bundle or args.fixture not in info.get('CalendarBenchmarkFixtures', []):
        parser.error('Requires an isolated benchmark build supporting the requested fixture')
    args.out.mkdir(parents=True, exist_ok=False)
    cases = [dict(density=density, pixelBuffer=surface, batchEventFills=batch,
                  status='unmeasured-not-started')
             for density in [100, 300] for surface in [False, True] for batch in [False, True]]
    metadata = dict(device=args.device, fixture=args.fixture, seed=str(args.seed),
                    binarySHA256=hashlib.sha256((args.app / info['CFBundleExecutable']).read_bytes()).hexdigest(),
                    scope='Physical-device offscreen concurrent pixels; UI/frame/input latency unmeasured', memoRasterText=args.memo_raster_text,
                    cases=cases, status='unmeasured')
    def save():
        (args.out / 'status.json').write_text(json.dumps(metadata, indent=2) + '\n')
    def run(command, required=True):
        result = subprocess.run(command, capture_output=True, text=True, timeout=60)
        with (args.out / 'commands.log').open('a') as log:
            log.write(json.dumps(command) + '\n' + result.stdout + result.stderr + '\n')
        if required: result.check_returncode()
        return result
    save()
    try:
        run(['xcrun', 'devicectl', 'device', 'install', 'app', '--device', args.device, str(args.app.resolve())])
        for index, case in enumerate(cases):
            case['status'] = 'running'; save()
            filename = 'pixels-' + str(uuid.uuid4()) + '.json'
            destination = args.out / f'{index:02d}-pixels.json'
            run(['xcrun', 'devicectl', 'device', 'process', 'launch', '--device', args.device,
                 '--terminate-existing', bundle, '--candidate', 'native', '--mode', 'week',
                 '--days', '365', '--density', str(case['density']), '--fixture', args.fixture,
                 '--seed', str(args.seed), '--renderer', 'tiles', '--ablation',
                 'tile-prefetch-async-surface' if case['pixelBuffer'] else 'tile-prefetch-async-two',
                 '--check', 'raster-pixels', '--output', filename,
                 *(['--batch-event-fills'] if case['batchEventFills'] else []),
                 *(['--memo-raster-text'] if args.memo_raster_text else [])])
            deadline = time.monotonic() + 90
            while time.monotonic() < deadline:
                time.sleep(1)
                copied = run(['xcrun', 'devicectl', 'device', 'copy', 'from', '--device', args.device,
                              '--source', 'Documents/' + filename, '--domain-type', 'appDataContainer',
                              '--domain-identifier', bundle, '--destination', str(destination.resolve())], False)
                if copied.returncode == 0 and destination.exists(): break
            report = json.loads(destination.read_text())
            valid = (matches_fixture(report, args.fixture, args.seed) and report.get('checks') == 96
                     and bool(report.get('memoRasterText')) == args.memo_raster_text
                     and report.get('pixelBuffer') == case['pixelBuffer']
                     and report.get('batchEventFills') == case['batchEventFills']
                     and report['fixture'].get('retainedEvents') == 365 * case['density']
                     and report['fixture'].get('meanDailyEvents') == case['density'])
            case.update(status='passed' if valid and report.get('status') == 'passed'
                        and report.get('failures') == [] else 'failed', checks=report.get('checks'))
            save(); print(index, case['status'], flush=True)
            if case['status'] != 'passed': raise RuntimeError('Concurrent pixel check failed')
        metadata['status'] = 'passed'
    except (Exception, KeyboardInterrupt) as error:
        metadata.update(status='failed-or-incomplete', error=str(error))
        for case in cases:
            if case['status'] == 'running': case['status'] = 'unmeasured-incomplete'
        return 1
    finally:
        save()
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
