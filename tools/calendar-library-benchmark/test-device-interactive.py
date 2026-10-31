#!/usr/bin/env python3
"""Real touch correctness checks against the isolated physical-device prototype, not a UI latency gate."""
import argparse
import datetime
import hashlib
import json
import os
import signal
from pathlib import Path
import plistlib
import subprocess


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--device', required=True)
    p.add_argument('--fixture', choices=['uniform-v1', 'varied-v1'], default='uniform-v1')
    p.add_argument('--seed', type=int, default=20261009)
    p.add_argument('--out', required=True, type=Path)
    p.add_argument('--density', type=int, default=100)
    p.add_argument('--ablation', choices=['tile-prefetch-budgeted', 'tile-prefetch-queue-two', 'tile-prefetch-queue-two-cancel', 'tile-prefetch-native-text', 'tile-prefetch-async-lazy', 'tile-prefetch-async-surface', 'tile-prefetch-async-surface-lazy'], default='tile-prefetch-budgeted')
    p.add_argument('--async-workers', type=int, choices=[0, 1, 2], default=0)
    p.add_argument('--presentation-policy', choices=['system', 'immediate', 'prefer120'])
    p.add_argument('--team', default=os.environ.get('DEVELOPMENT_TEAM'), help='Apple team id; defaults to DEVELOPMENT_TEAM from the environment (Config/Local.xcconfig has it)')
    p.add_argument('--skip-build', action='store_true', help='Use the explicitly retained device test build')
    p.add_argument('--memo-raster-text', action='store_true')
    a = p.parse_args()
    if not a.team: p.error('--team or DEVELOPMENT_TEAM is required')
    if not 1 <= a.density <= 1000: p.error('Density must be 1...1000')
    root = Path(__file__).resolve().parents[2]
    project = Path(__file__).resolve().parent / 'CalendarLibraryBenchmark.xcodeproj'
    dd = root / '.build/calendar-library-touch-dd'
    a.out = a.out.resolve()
    a.out.mkdir(parents=True, exist_ok=False)
    bundle = 'com.boris.banana.calendar-library-benchmark'
    status = dict(scope='Physical touch correctness; gesture wall clock is not input/display latency',
                  timestamp=datetime.datetime.now().astimezone().isoformat(), device=a.device,
                  fixture=a.fixture, seed=str(a.seed), memoRasterText=a.memo_raster_text, density=a.density, ablation=a.ablation, asyncWorkers=a.async_workers, presentationPolicy=a.presentation_policy, status='unmeasured')
    def save():
        (a.out / 'summary.json').write_text(json.dumps(status, indent=2) + '\n')
    save()
    def call(name, command, timeout=180):
        with (a.out / (name + '.log')).open('w') as log:
            process = subprocess.Popen(command, cwd=root, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            try:
                code = process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGINT)
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGTERM)
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL); process.wait()
                status.update(status='unmeasured-timeout', stage=name); save(); return False
        if code:
            status.update(status='failed', stage=name, exitCode=code); save(); return False
        return True
    build_args = ['-project', str(project), '-scheme', 'CalendarLibraryBenchmarkUITests',
                  '-configuration', 'Release', '-destination', 'platform=iOS,id=' + a.device,
                  '-derivedDataPath', str(dd), 'ARCHS=arm64', 'ONLY_ACTIVE_ARCH=YES',
                  'CODE_SIGNING_ALLOWED=YES', 'CODE_SIGN_STYLE=Automatic', 'DEVELOPMENT_TEAM=' + a.team]
    if not a.skip_build:
        if not call('generate', ['xcodegen', 'generate', '--spec', str(project.parent / 'project.yml')]): return 1
        if not call('build', ['xcodebuild', 'build-for-testing', *build_args], timeout=600): return 1
    app = dd / 'Build/Products/Release-iphoneos/CalendarLibraryBenchmark.app'
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != bundle: raise ValueError('Refusing non-benchmark bundle')
    if a.memo_raster_text and not info.get('CalendarBenchmarkRasterTextMemo'):
        status.update(status='unmeasured-unsupported-text-memo'); save(); return 1
    if a.fixture not in info.get('CalendarBenchmarkFixtures', []):
        status.update(status='unmeasured-unsupported-fixture'); save(); return 1
    if a.presentation_policy and a.presentation_policy not in info.get('CalendarBenchmarkPresentationPolicies', []):
        status.update(status='unmeasured-unsupported-presentation-policy'); save(); return 1
    status['binarySHA256'] = hashlib.sha256((app / info['CFBundleExecutable']).read_bytes()).hexdigest()
    status['git'] = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
    status['dirty'] = subprocess.check_output(['git', 'status', '--porcelain'], cwd=root, text=True)
    save()
    if not call('install', ['xcrun', 'devicectl', 'device', 'install', 'app', '--device', a.device, str(app)]): return 1
    if not call('launch', ['xcrun', 'devicectl', 'device', 'process', 'launch', '--device', a.device,
                          '--json-output', str(a.out / 'launch.json'), '--terminate-existing', bundle, '--candidate', 'native', '--mode', 'week',
                          '--days', '365', '--density', str(a.density), '--renderer', 'tiles',
                          '--fixture', a.fixture, '--seed', str(a.seed),
                          '--ablation', a.ablation, '--interactive', '--async-workers', str(a.async_workers),
                          *(['--presentation-policy', a.presentation_policy] if a.presentation_policy else []),
                          *(['--memo-raster-text'] if a.memo_raster_text else [])]): return 1
    if not call('test', ['xcodebuild', 'test-without-building', *build_args,
                        '-resultBundlePath', str(a.out / 'ui.xcresult'), '-parallel-testing-enabled', 'NO',
                        '-collect-test-diagnostics', 'never'], timeout=300): return 1
    exported = subprocess.run(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary',
                               '--path', str(a.out / 'ui.xcresult'), '--format', 'json'],
                              capture_output=True, text=True, timeout=30)
    (a.out / 'test-summary.json').write_text(exported.stdout)
    (a.out / 'test-summary-export.log').write_text(exported.stderr)
    if exported.returncode:
        status.update(status='unmeasured-summary-export'); save(); return 1
    summary = json.loads(exported.stdout)
    if summary.get('passedTests') != 1 or summary.get('totalTestCount') != 1 or summary.get('skippedTests') != 0:
        status.update(status='failed-test-coverage'); save(); return 1
    status.update(status='passed-correctness', latencyAcceptance='unmeasured'); save()
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
