#!/usr/bin/env python3
"""The calendar preparation comparison on a physical device: the same launch the Simulator
collector (tools/calendar-artwork-tests/profile-app.py) uses, run through devicectl against the
isolated review app, old Day host versus native, in alternating order. Reads the app's own
`scale-idle.json` report (main-actor cache-miss preparation samples) back from the device.

    python3 tools/physical-stress-tests/profile-device-preparation.py --device UDID --out DIR [--rounds 2]

Each round launches reference, native, native, reference. A report that does not change
between launches is treated as missing and the run is retained as failed. Component
measurement only: not frames, not input-to-visible latency.
"""
import argparse, hashlib, json, subprocess, sys, time
from pathlib import Path

BUNDLE = 'com.boris.banana.stressreview'
BASE = ['--plan', '--stress-days', '30', '--stress-measure', '--disable-icloud', '--mail-fresh',
        '-onboardingCompleted', 'YES', '-planMode', 'day', '-mobileWeekLayout', 'calendar',
        '-mobileWeekHourHeight', '56', '-mobileDayScrollOffset', '560', '--calendar-prepared-artwork',
        '--calendar-artwork-profile', '--stress-idle-seconds', '1', '--stress-actionable-calendar']


def run(args, timeout=120):
    return subprocess.run(args, text=True, capture_output=True, timeout=timeout)


def pull(device, name, dest):
    r = run(['xcrun', 'devicectl', 'device', 'copy', 'from', '--device', device, '--domain-type', 'appDataContainer',
             '--domain-identifier', BUNDLE, '--source', f'Documents/{name}', '--destination', str(dest)])
    return r.returncode == 0 and dest.exists()


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--device', required=True); p.add_argument('--out', required=True, type=Path)
    p.add_argument('--rounds', type=int, default=2); p.add_argument('--settle', type=float, default=25)
    a = p.parse_args()
    a.out.mkdir(parents=True, exist_ok=False)
    order = ['reference', 'native', 'native', 'reference'] * a.rounds
    results, last_hash = [], None
    for index, viewport in enumerate(order, 1):
        case = a.out / f'{index}-{viewport}'; case.mkdir()
        args = BASE + (['--calendar-reference-day'] if viewport == 'reference' else [])
        launch = ['xcrun', 'devicectl', 'device', 'process', 'launch', '--terminate-existing', '--device', a.device,
                  '--json-output', str(case / 'launch.json'), BUNDLE, '--', *args]
        (case / 'command.json').write_text(json.dumps(launch, indent=2) + '\n')
        r = run(launch, timeout=90)
        (case / 'launch.log').write_text(r.stdout + r.stderr)
        entry = {'index': index, 'viewport': viewport, 'launchExit': r.returncode}
        if r.returncode == 0:
            time.sleep(a.settle)
            ok = pull(a.device, 'scale-idle.json', case / 'idle.json')
            pull(a.device, 'scale-stress.json', case / 'model.json')
            run(['xcrun', 'devicectl', 'device', 'process', 'launch', '--terminate-existing', '--device', a.device,
                 BUNDLE, '--', '--plan', '--stress-days', '1', '--disable-icloud', '--stress-actionable-calendar'], timeout=60)
            if ok:
                data = (case / 'idle.json').read_bytes(); h = hashlib.sha256(data).hexdigest()
                if h == last_hash:
                    entry['status'] = 'stale-report'
                else:
                    last_hash = h
                    report = json.loads(data); artwork = report.get('calendarArtwork', {})
                    samples = artwork.get('samplesMS', [])
                    complete = (artwork.get('recordingEnabled') and artwork.get('preparedPolicyEnabled') and samples
                                and artwork.get('renderAttempts') == len(samples) and artwork.get('droppedSamples') == 0
                                and artwork.get('pendingJobs') == 0)
                    entry.update(status='collected' if complete else 'incomplete-report',
                                 samples=len(samples), totalMS=sum(samples), firstMS=samples[0] if samples else None,
                                 maximumMS=artwork.get('maximumMS'), renders=artwork.get('renders'),
                                 consumerPixelBytes=artwork.get('consumerPixelBytes'), redrawProbePassed=report.get('passed'))
            else:
                entry['status'] = 'no-report'
        else:
            entry['status'] = 'launch-failed'
        results.append(entry)
        (a.out / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        print(json.dumps(entry), flush=True)
    good = [r for r in results if r.get('status') == 'collected']
    for viewport in ('reference', 'native'):
        rows = [r for r in good if r['viewport'] == viewport]
        if rows:
            print(f"{viewport}: runs {len(rows)}, total preparation ms {[round(r['totalMS'], 3) for r in rows]}, "
                  f"mean {sum(r['totalMS'] for r in rows)/len(rows):.3f}, renders {[r['renders'] for r in rows]}")
    # terminate the app at the end
    run(['xcrun', 'devicectl', 'device', 'process', 'launch', '--terminate-existing', '--device', a.device, BUNDLE, '--',
         '--plan', '--stress-days', '1', '--disable-icloud', '--stress-actionable-calendar'], timeout=60)


if __name__ == '__main__':
    main()
