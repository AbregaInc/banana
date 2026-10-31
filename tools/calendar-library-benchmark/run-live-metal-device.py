#!/usr/bin/env python3
"""Run the isolated physical-device Metal preview. Build first; retains failures."""
import argparse
import hashlib
import importlib.util
import json
import plistlib
from pathlib import Path
import subprocess
import time


def capture_configuration_path(products, output):
    run_id = hashlib.sha256(str(output.resolve()).encode()).hexdigest()[:16]
    return products/('live-capture-'+run_id+'.xctestrun')


def valid_test_coverage(summary, tree, scenario, device):
    expected = 'LiveTests/' + ('testScrollPagingAndEviction()' if scenario == 'scroll'
                              else 'testPixelsAfterPagingAndEviction()')
    def cases(nodes):
        for node in nodes:
            if node.get('nodeType') == 'Test Case':
                yield node
            yield from cases(node.get('children', []))
    actual = list(cases(tree.get('testNodes', [])))
    return (summary.get('totalTestCount') == 1 and summary.get('passedTests') == 1
            and summary.get('failedTests') == 0 and summary.get('skippedTests') == 0
            and summary.get('expectedFailures') == 0 and summary.get('result') == 'Passed'
            and len(actual) == 1 and actual[0].get('nodeIdentifier') == expected
            and actual[0].get('result') == 'Passed'
            and [d.get('deviceId') for d in tree.get('devices', [])] == [device])


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--device', required=True)
    p.add_argument('--density', type=int, required=True)
    p.add_argument('--scenario', choices=['scroll', 'pixels'], default='scroll')
    p.add_argument('--seed', type=int, default=20261009)
    p.add_argument('--max-inflight', type=int, choices=[1, 2], default=2)
    p.add_argument('--metal-display-link', action='store_true')
    p.add_argument('--release-on-gpu-completion', action='store_true')
    p.add_argument('--native-surfaces', action='store_true')
    p.add_argument('--presentation-policy', choices=['system','immediate','prefer120','both'], default='system')
    p.add_argument('--memo-text', action='store_true')
    p.add_argument('--capture-format', choices=['screenshots', 'screenRecording'])
    p.add_argument('--derived-data', type=Path, required=True)
    p.add_argument('--out', type=Path, required=True)
    a = p.parse_args(); a.out.mkdir(parents=True, exist_ok=False)
    root = Path(__file__).resolve().parents[2]
    app = a.derived_data.resolve()/'Build/Products/Release-iphoneos/CalendarMetalLive.app'
    binary = app/'CalendarMetalLive'
    bundle = 'com.boris.banana.calendar-metal-review'
    state = dict(status='started', device=a.device, density=a.density, scenario=a.scenario, seed=a.seed, maxInFlight=a.max_inflight, metalDisplayLink=a.metal_display_link, releaseOnGPUCompletion=a.release_on_gpu_completion, nativeSurfaces=a.native_surfaces, memoText=a.memo_text, presentationPolicy=a.presentation_policy,
                 binarySHA256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                 captureFormat=a.capture_format or 'scheme-default-screenRecording',
                 git=subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
                 commands=[], acceptance='unmeasured')
    def save():
        (a.out/'status.json').write_text(json.dumps(state, indent=2)+'\n')
    def run(name, command, timeout=180):
        state['commands'].append(command); save()
        with (a.out/(name+'.log')).open('w') as log:
            try:
                code = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=timeout).returncode
            except subprocess.TimeoutExpired:
                code = 124
        if code:
            state.update(status='failed-'+name, exitCode=code); save()
        return code == 0
    save()
    if not run('install', ['xcrun','devicectl','device','install','app','--device',a.device,str(app)]): return 2
    started = int(time.time())
    if not run('launch', ['xcrun','devicectl','device','process','launch','--device',a.device,
                         '--json-output',str(a.out/'launch.json'),'--terminate-existing',bundle,
                         '--fixture','varied-v1','--mode','week','--days','365','--density',str(a.density),
                         '--seed',str(a.seed),'--max-inflight',str(a.max_inflight),
                         *(['--metal-display-link'] if a.metal_display_link else []),
                         *(['--release-on-gpu-completion'] if a.release_on_gpu_completion else []),
                         *(['--native-surfaces'] if a.native_surfaces else []),
                         *(['--memo-text'] if a.memo_text else []),
                         *(['--presentation-policy',a.presentation_policy] if a.presentation_policy != 'system' else [])]): return 2
    test_selection = ['-project',str(root/'tools/calendar-library-benchmark/SkiaLive/CalendarMetalLive.xcodeproj'),
                      '-scheme','CalendarMetalLiveUITests','-configuration','Release',
                      '-derivedDataPath',str(a.derived_data.resolve())]
    if a.capture_format:
        products = a.derived_data.resolve()/'Build/Products'
        original = list(products.glob('CalendarMetalLiveUITests_iphoneos*.xctestrun'))
        if len(original) != 1: raise ValueError('Expected one generated device test configuration')
        config = plistlib.loads(original[0].read_bytes())
        config['CalendarMetalLiveUITests']['PreferredScreenCaptureFormat'] = a.capture_format
        custom = capture_configuration_path(products, a.out)
        with custom.open('xb') as output: output.write(plistlib.dumps(config))
        (a.out/'test-configuration.plist').write_bytes(plistlib.dumps(config))
        test_selection = ['-xctestrun',str(custom)]
    succeeded = run('test', ['xcodebuild','test-without-building',*test_selection,
                             '-only-testing:CalendarMetalLiveUITests/LiveTests/'+('testScrollPagingAndEviction' if a.scenario == 'scroll' else 'testPixelsAfterPagingAndEviction'),
                             '-destination','platform=iOS,id='+a.device,
                             '-resultBundlePath',str(a.out/'ui.xcresult'),'-parallel-testing-enabled','NO',
                             '-collect-test-diagnostics','never'], 180)
    coverage = {}
    for section in ('summary', 'tests'):
        command = ['xcrun','xcresulttool','get','test-results',section,
                   '--path',str(a.out/'ui.xcresult'),'--format','json']
        state['commands'].append(command); save()
        result = subprocess.run(command, capture_output=True, text=True, timeout=30)
        (a.out/('test-'+section+'.json')).write_text(result.stdout)
        (a.out/('test-'+section+'-stderr.log')).write_text(result.stderr)
        try: coverage[section] = json.loads(result.stdout) if result.returncode == 0 else {}
        except json.JSONDecodeError: coverage[section] = {}
    state['verifiedTestCoverage'] = valid_test_coverage(coverage['summary'], coverage['tests'], a.scenario, a.device)
    succeeded = succeeded and state['verifiedTestCoverage']
    state['functionalStatus'] = 'pass' if succeeded else 'fail-or-unmeasured'
    save()
    run('attachments', ['xcrun','xcresulttool','export','attachments','--path',str(a.out/'ui.xcresult'),
                        '--output-path',str(a.out/'attachments')])
    if not run('copy', ['xcrun','devicectl','device','copy','from','--device',a.device,'--source','Documents',
                       '--destination',str(a.out/'documents'),'--domain-type','appDataContainer','--domain-identifier',bundle]): return 2
    files = [f for f in (a.out/'documents').glob('calendar-live-*.jsonl') if int(f.stem.split('-')[-1]) >= started]
    if len(files) != 1:
        state.update(status='unmeasured-log-identity'); save(); return 2
    rows = [json.loads(line) for line in files[0].read_text().splitlines()]
    fixture = next((r for r in rows if r['kind']=='fixture'), {})
    policy = next((r for r in rows if r['kind']=='policy'), {})
    native_policy = next((r['value'] for r in rows if r['kind']=='nativePresentationPolicy'), 'system')
    if (fixture.get('profile') != 'varied-v1' or fixture.get('retainedEvents') != 365*a.density
            or fixture.get('seed') != str(a.seed) or fixture.get('calendarCount') != 12
            or policy.get('maxInFlight') != a.max_inflight
            or bool(policy.get('metalDisplayLink', False)) != a.metal_display_link
            or bool(policy.get('releaseOnGPUCompletion', False)) != a.release_on_gpu_completion
            or bool(policy.get('nativeSurfaces', False)) != a.native_surfaces
            or bool(policy.get('memoText', False)) != a.memo_text
            or native_policy != a.presentation_policy):
        state.update(status='unmeasured-workload-mismatch'); save(); return 2
    spec = importlib.util.spec_from_file_location('report', Path(__file__).with_name('report-live-metal.py'))
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    report = module.report(rows)
    (a.out/'presentation-summary.json').write_text(json.dumps(report, indent=2)+'\n')
    state.update(status='functional-pass' if succeeded else 'functional-fail', acceptance=report['acceptance'], log=str(files[0]))
    save(); print(json.dumps({k: report[k] for k in ('frames','presentedFrames','cpuEncodeMS','scrollCallbackToPresentedMS','coldPageMS','cachedPageMS')},indent=2))
    return 1 if report['acceptance']=='failed' else 2


if __name__=='__main__':
    raise SystemExit(main())
