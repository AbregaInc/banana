#!/usr/bin/env python3
"""Capture a bounded real-device scroll trace of the integrated review Calendar."""
import argparse
import json
import plistlib
import re
from pathlib import Path
import subprocess
import sys
import time
from urllib.parse import unquote


def physical_device(value):
    if not re.fullmatch(r"(?:[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}|[0-9A-Fa-f]{40})", value):
        raise argparse.ArgumentTypeError("Use the physical test-device UDID, not a Simulator UUID")
    return value


def oriented_xctestrun(source: Path, orientation: str) -> Path:
    """A copy of the test plan beside the original (so __TESTROOT__ still resolves) that hands the
    runner STRESS_ORIENTATION; the test rotates to it and fails rather than measure the wrong way up."""
    plan = plistlib.loads(source.read_bytes())

    def visit(node):
        if isinstance(node, dict):
            for key in ('EnvironmentVariables', 'TestingEnvironmentVariables'):
                if isinstance(node.get(key), dict):
                    node[key]['STRESS_ORIENTATION'] = orientation
            for value in node.values():
                visit(value)
        elif isinstance(node, list):
            for value in node:
                visit(value)

    visit(plan)
    target = source.with_name(f'{source.stem}-{orientation}.xctestrun')
    target.write_bytes(plistlib.dumps(plan))
    return target


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--device', required=True, type=physical_device, help='UDID of the physical test device you have authorized for this run')
    p.add_argument('--instruments-device', required=True, help='Exact name/version from xctrace list devices; retained separately from the XCTest UDID')
    p.add_argument('--xctestrun', required=True, type=Path)
    p.add_argument('--mode', choices=['Day', 'Week'], required=True)
    p.add_argument('--template', choices=['Animation Hitches', 'Time Profiler'], default='Animation Hitches')
    p.add_argument('--cell-host-policy', choices=['clear', 'preserve', 'prefetch'], default='clear',
                   help='preserve = keep the hosting content view across reuse; prefetch = UIKit cell prefetching on')
    p.add_argument('--viewport', choices=['native', 'reference'], default='native',
                   help='reference = the pre-virtualization Day/Week host via the DEBUG reference flags; the matched comparison')
    p.add_argument('--density', type=int, choices=[1, 10, 30, 100], default=100,
                   help='Supplementary capacity probe; 100/day remains the acceptance workload')
    p.add_argument('--orientation', choices=['portrait', 'landscape'], default='portrait',
                   help='The test rotates the device to this orientation and fails if it does not comply; recorded with the trace')
    p.add_argument('--out', required=True, type=Path)
    a = p.parse_args()
    if a.density != 100 and a.cell_host_policy != 'clear':
        p.error('Capacity probes use the default clear policy to isolate density')
    if a.viewport == 'reference' and (a.density != 100 or a.cell_host_policy != 'clear'):
        p.error('The reference comparison uses the acceptance workload and the default cell policy')
    a.out.mkdir(parents=True, exist_ok=False)
    root = Path(__file__).resolve().parents[2]
    benchmark = root / 'tools/calendar-library-benchmark'
    state = {'status': 'unmeasured', 'mode': a.mode, 'template': a.template, 'cellHostPolicy': a.cell_host_policy, 'viewport': a.viewport, 'eventsPerDay': a.density, 'orientation': a.orientation, 'device': a.device, 'instrumentsDevice': a.instruments_device,
             'scope': 'Partial Instruments trace of integrated app scrolling; no input-to-visible acceptance',
             'commands': []}

    def save():
        (a.out / 'status.json').write_text(json.dumps(state, indent=2) + '\n')

    def command(args, log, timeout=180):
        state['commands'].append(args); save()
        with (a.out / log).open('w') as f:
            return subprocess.run(args, stdout=f, stderr=subprocess.STDOUT, timeout=timeout).returncode

    code = command(['xcrun', 'xctrace', 'list', 'devices'], 'instruments-devices.log', 30)
    expected = f'{a.instruments_device} ({a.device})'
    if code or expected not in (a.out / 'instruments-devices.log').read_text().splitlines():
        state.update(status='failed-or-incomplete', error='Instruments name must map to the authorized test-device UDID')
        save()
        return 2

    variant = {'preserve': 'PreservedHost', 'prefetch': 'Prefetch'}.get(a.cell_host_policy, '')
    if a.density != 100:
        variant = f'Density{a.density}'
    if a.viewport == 'reference':
        variant = 'Reference'
    test_name = f'PhysicalStressUITests/ScaleStressUITests/testPhysical{a.mode}{variant}ScrollTrace'
    xctestrun = oriented_xctestrun(a.xctestrun, a.orientation)
    state['xctestrun'] = str(xctestrun); save()
    args = ['xcodebuild', 'test-without-building', '-xctestrun', str(xctestrun),
            '-destination', f'platform=iOS,id={a.device}', '-resultBundlePath', str(a.out / 'ui.xcresult'),
            '-parallel-testing-enabled', 'NO', '-collect-test-diagnostics', 'never', '-only-testing:' + test_name]
    state['commands'].append(args); save()
    with (a.out / 'test.log').open('w') as log:
        test = subprocess.Popen(args, stdout=log, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 120
            while test.poll() is None and time.monotonic() < deadline:
                if 'Swipe up' in (a.out / 'test.log').read_text(errors='replace'):
                    break
                time.sleep(.5)
            else:
                raise RuntimeError('No observed scroll window before test ended or deadline')
            processes = a.out / 'processes.json'
            result = command(['xcrun', 'devicectl', 'device', 'info', 'processes', '--device', a.device,
                              '--json-output', str(processes)], 'processes.log', 30)
            if result:
                raise RuntimeError(f'Process lookup failed: {result}')
            matches = [r for r in json.loads(processes.read_text())['result']['runningProcesses']
                       if '/Banana Stress Review.app/' in unquote(r.get('executable', ''))]
            if len(matches) != 1:
                raise RuntimeError(f'Expected exactly one isolated review process, found {len(matches)}')
            state['process'] = matches[0]; save()
            trace = a.out / 'trace'
            state['profileExit'] = command([sys.executable, str(benchmark / 'profile-device.py'),
                '--device', a.instruments_device, '--pid', str(matches[0]['processIdentifier']), '--out', str(trace),
                '--seconds', '8', '--template', a.template], 'profile.log', 240)
            state['testExit'] = test.wait(timeout=180); save()
            if state['profileExit'] != 0 or state['testExit'] != 0:
                raise RuntimeError('Trace or interaction test failed; retained partial evidence')
            code = command(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary',
                            '--path', str(a.out / 'ui.xcresult')], 'test-summary.json', 30)
            summary = json.loads((a.out / 'test-summary.json').read_text()) if code == 0 else {}
            devices = summary.get('devicesAndConfigurations', [])
            if (summary.get('totalTestCount') != 1 or summary.get('passedTests') != 1
                    or summary.get('failedTests') != 0 or summary.get('skippedTests') != 0
                    or len(devices) != 1 or devices[0].get('device', {}).get('deviceId') != a.device):
                raise RuntimeError('Expected one passing, unskipped test on the selected physical device')
            if a.template == 'Time Profiler':
                code = command(['xcrun', 'xctrace', 'export', '--input', str(trace / 'touch.trace'),
                                '--toc', '--output', str(trace / 'toc.xml')], 'toc-export.log', 150)
                if code:
                    raise RuntimeError(f'CPU trace table-of-contents export failed: {code}')
                state['status'] = 'captured-cpu-trace-unvalidated'
                save()
                return 0
            schemas = ['hitches-updates', 'hitches-renders', 'hitches-gpu', 'hitches-frame-lifetimes',
                       'hitches', 'display-vsyncs-interval', 'device-display-info',
                       'displayed-surfaces-interval', 'display-surface-swap']
            for schema in schemas:
                code = command(['xcrun', 'xctrace', 'export', '--input', str(trace / 'touch.trace'),
                    '--xpath', f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]',
                    '--output', str(trace / (schema + '.xml'))], schema + '-export.log', 150)
                if code:
                    raise RuntimeError(f'Export failed: {schema} ({code})')
            state['analysisExit'] = command([sys.executable, str(benchmark / 'report-hitches.py'),
                '--directory', str(trace), '--pid', str(matches[0]['processIdentifier']),
                '--out', str(trace / 'analysis.json')], 'analysis.log')
            state['status'] = 'captured-partial-evidence'
            save()
            return state['analysisExit']
        except (RuntimeError, subprocess.TimeoutExpired, KeyError, ValueError, OSError) as error:
            state.update(status='failed-or-incomplete', error=str(error)); save()
            return 2
        finally:
            if test.poll() is None:
                test.terminate()
                try:
                    test.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    test.kill(); test.wait()
            state['testExit'] = test.returncode; save()


if __name__ == '__main__':
    raise SystemExit(main())
