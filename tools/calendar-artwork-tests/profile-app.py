#!/usr/bin/env python3
"""Collect real-app preparation diagnostics on an explicitly selected fixture Simulator.

Successful collection is not UI acceptance. Never feed these API timings to the frame/input gate.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
from performance_host import HostMonitor


def run(*args, check=True):
    return subprocess.run(args, check=check, text=True, capture_output=True, timeout=300)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True)
    parser.add_argument('--app', type=Path, default=ROOT / '.build/stress-dd/Build/Products/Release-iphonesimulator/Banana.app')
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--trials', type=int, default=3)
    parser.add_argument('--fixture', choices=['legacy', 'varied-v1'], default='legacy')
    parser.add_argument('--density', type=int, default=100)
    parser.add_argument('--mode', choices=['both', 'day', 'week'], default='both')
    parser.add_argument('--day-viewport', choices=['reference', 'native'], default='reference')
    args = parser.parse_args()
    if not 1 <= args.trials <= 10:
        parser.error('trials must be in 1...10')
    devices = json.loads(run('xcrun', 'simctl', 'list', 'devices', 'available', '-j').stdout)['devices']
    matches = [{'runtime': runtime, **d} for runtime, group in devices.items() for d in group if d['udid'] == args.device]
    if len(matches) != 1:
        parser.error('requires an available Simulator, never a physical device')
    if not 1 <= args.density <= 1000 or (args.fixture == 'legacy' and args.density != 100):
        parser.error('density overrides require varied-v1 and 1...1000')
    args.out.mkdir(parents=True, exist_ok=False)
    info = plistlib.load((args.app / 'Info.plist').open('rb'))
    bundle = info['CFBundleIdentifier']
    binary_hash = hashlib.sha256((args.app / info['CFBundleExecutable']).read_bytes()).hexdigest()
    run('xcrun', 'simctl', 'boot', args.device, check=False)
    run('xcrun', 'simctl', 'bootstatus', args.device, '-b')
    run('xcrun', 'simctl', 'install', args.device, str(args.app))
    container = Path(run('xcrun', 'simctl', 'get_app_container', args.device, bundle, 'data').stdout.strip())
    (args.out / 'identity.json').write_text(json.dumps({'binarySHA256': binary_hash, 'device': matches[0],
        'dayViewport': args.day_viewport, 'mode': args.mode, 'fixture': args.fixture, 'density': args.density,
        'xcode': run('xcodebuild', '-version').stdout.strip(),
        'collectorSHA256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        'scope': 'Main-actor preparation API, not frames or input-to-visible latency'}, indent=2) + '\n')
    for trial in range(args.trials):
        modes = (['day', 'week'] if trial % 2 == 0 else ['week', 'day']) if args.mode == 'both' else [args.mode]
        for mode in modes:
            case = args.out / f'{trial}-{mode}'
            case.mkdir()
            idle = container / 'Documents/scale-idle.json'
            model = container / 'Documents/scale-stress.json'
            run('xcrun', 'simctl', 'terminate', args.device, bundle, check=False)
            idle.unlink(missing_ok=True)
            model.unlink(missing_ok=True)
            command = ['xcrun', 'simctl', 'launch', args.device, bundle, '--plan', '--stress-days', '30',
                '--stress-measure', '--disable-icloud', '--mail-fresh', '-onboardingCompleted', 'YES',
                '-planMode', mode, '-mobileWeekLayout', 'calendar', '-mobileWeekHourHeight', '56',
                '-mobileDayScrollOffset', '560', '--calendar-prepared-artwork', '--calendar-artwork-profile',
                '--stress-idle-seconds', '1']
            fixture_report = container / 'Documents/scale-calendar-fixture.json'
            fixture_report.unlink(missing_ok=True)
            if args.fixture == 'varied-v1':
                command += ['--stress-calendar-fixture', args.fixture, '--stress-events-per-day', str(args.density)]
            if mode == 'day' and args.day_viewport == 'reference':
                command.append('--calendar-reference-day')
            (case / 'command.json').write_text(json.dumps(command, indent=2) + '\n')
            try:
                with HostMonitor(case / 'host.json'):
                    launch = run(*command)
                    (case / 'launch.txt').write_text(launch.stdout + launch.stderr)
                    pid = launch.stdout.strip().rsplit(': ', 1)[-1]
                    deadline = time.monotonic() + 180
                    rss = []
                    while not idle.exists() and time.monotonic() < deadline:
                        result = run('ps', '-p', pid, '-o', 'rss=', check=False)
                        if result.stdout.strip().isdigit():
                            rss.append(int(result.stdout.strip()) / 1024)
                        time.sleep(0.25)
                    (case / 'rss.json').write_text(json.dumps(rss) + '\n')
                    if not idle.exists() or not model.exists():
                        raise RuntimeError('Missing app report; collection is incomplete')
                    (case / 'idle.json').write_bytes(idle.read_bytes())
                    (case / 'model.json').write_bytes(model.read_bytes())
                    if args.fixture == 'varied-v1':
                        fixture = json.loads(fixture_report.read_text())
                        if (not fixture.get('installedContentChecksum')
                                or fixture['profile'] != args.fixture or fixture['retainedEvents'] != 30 * args.density
                                or len(fixture['installedCalendarCounts']) != 12
                                or sum(fixture['installedCalendarCounts'].values()) != 30 * args.density):
                            raise RuntimeError('Wrong varied workload; retain run')
                        (case / 'fixture.json').write_bytes(fixture_report.read_bytes())
                    report = json.loads(idle.read_text())
                    artwork = report.get('calendarArtwork', {})
                    samples = artwork.get('samplesMS', [])
                    if not (artwork.get('recordingEnabled') and artwork.get('preparedPolicyEnabled')
                            and artwork.get('renders', 0) > 0 and samples
                            and artwork.get('renderAttempts') == len(samples)
                            and artwork.get('droppedSamples') == 0 and artwork.get('pendingJobs') == 0):
                        raise RuntimeError('Renderer was not exercised completely; retain this run')
                    if (artwork['retainedPixelBytes'] > artwork['pixelByteLimit']
                            or artwork['consumerPixelBytes'] > artwork['consumerPixelLimit']):
                        raise RuntimeError('Prepared image ownership exceeded its bound')
                    values = sorted(samples)
                    summary = {'samples': len(values), 'firstMS': samples[0],
                        'p50MS': values[len(values)//2], 'p95MS': values[int((len(values)-1)*0.95)],
                        'maximumMS': artwork['maximumMS'], 'over8_3MS': sum(x > 8.3 for x in samples),
                        'peakRSSMB': max(rss) if rss else None, 'redrawProbePassed': report['passed'],
                        'scope': artwork['scope']}
                    (case / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
                    print(f'{trial}-{mode}: collected {len(values)} preparations; first={samples[0]:.3f} ms, max={artwork["maximumMS"]:.3f} ms', flush=True)
                    if not report['passed']:
                        raise RuntimeError('App redraw probe failed; retain this run')
            finally:
                run('xcrun', 'simctl', 'terminate', args.device, bundle, check=False)


if __name__ == '__main__':
    main()
