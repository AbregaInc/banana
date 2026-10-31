#!/usr/bin/env python3
"""Record native Mac UI work while real UI interactions run in another client.

Commit work is a lower bound on frame work, NOT input-to-visible latency. A slow commit
fails the frame budget; fast commits alone never certify UI acceptance. No baseline updates.
Raw traces contain process environment metadata: keep them local, share the summary only.
"""
import argparse
import datetime
import hashlib
import json
import math
from pathlib import Path
import platform
import subprocess
import sys
import xml.etree.ElementTree as ET


def table_rows(path):
    root = ET.parse(path).getroot()
    refs = {e.get('id'): e for e in root.iter() if e.get('id')}
    def resolve(element):
        return resolve(refs[element.get('ref')]) if element.get('ref') else element
    return [[resolve(e) for e in row] for row in root.findall('.//row')]


def distribution(rows, limit):
    samples = [{'startMS': float(r[0].text) / 1e6, 'durationMS': float(r[1].text) / 1e6}
               for r in rows]
    return sample_distribution(samples, limit)


def sample_distribution(samples, limit):
    ordered = sorted(s['durationMS'] for s in samples)
    percentile = lambda p: ordered[max(0, math.ceil(len(ordered) * p) - 1)] if ordered else None
    return dict(count=len(samples), p50MS=percentile(.5), p95MS=percentile(.95),
                p99MS=percentile(.99), maxMS=max(ordered) if ordered else None,
                budgetMS=limit, violations=[s for s in samples if s['durationMS'] > limit], samples=samples)


def nonwaiting_busy(rows):
    """Exclude explicit nested run-loop waiting, preserving all other elapsed time.

    A native button can track mouse-down for 100 ms in a nested loop while still
    drawing and handling events. Its parent Busy span is not 100 ms of CPU work.
    This metric remains wall time, including preemption/synchronous blocking.
    """
    def union(intervals):
        merged = []
        for start, end in sorted(intervals):
            if merged and start <= merged[-1][1]:
                merged[-1] = (merged[-1][0], max(merged[-1][1], end))
            else: merged.append((start, end))
        return merged
    busy, waiting = [], []
    for row in rows:
        if len(row) < 8 or row[7].text != '1': continue
        interval = (int(row[0].text), int(row[0].text) + int(row[1].text))
        if row[2].text == 'Busy': busy.append(interval)
        elif row[2].text == 'Waiting For Events': waiting.append(interval)
    busy, waiting = union(busy), union(waiting)
    samples, cursor = [], 0
    def add(start, end):
        if end > start: samples.append(dict(startMS=start/1e6, durationMS=(end-start)/1e6))
    for start, end in busy:
        while cursor < len(waiting) and waiting[cursor][1] <= start: cursor += 1
        index = cursor
        while index < len(waiting) and waiting[index][0] < end:
            add(start, min(end, waiting[index][0]))
            start = max(start, waiting[index][1]); index += 1
        add(start, end)
    return sample_distribution(samples, 8.3)


def summarize(commits, runloops, recording_ok):
    commit_rows = table_rows(commits)
    main_commits = [r for r in commit_rows if 'Main Thread' in r[3].get('fmt', '')]
    loop_rows = table_rows(runloops)
    busy = [r for r in loop_rows if r[2].text == 'Busy' and r[7].text == '1']
    result = dict(scope='Native main-thread commit work and run-loop busy intervals; not input-to-visible or GPU/display delivery',
                  recordingComplete=recording_ok, commits=distribution(main_commits, 8.3),
                  mainRunLoopBusy=distribution(busy, 8.3),
                  mainRunLoopWithoutNestedWaits=nonwaiting_busy(loop_rows),
                  runLoopScope='Inclusive parent Busy spans can contain nested event-tracking waits. The additional metric excludes explicit run-loop waits only; neither measures CPU execution or input latency.',
                  missingEvidence=['input-to-visible latency', 'GPU/display delivery', 'refresh-rate correlation'])
    result['status'] = 'fail' if (result['commits']['violations'] or result['mainRunLoopWithoutNestedWaits']['violations']) else 'unmeasured'
    return result


def main():
    from performance_host import HostMonitor
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--pid', type=int, required=True)
    p.add_argument('--time-profiler', action='store_true', help='Add diagnostic CPU samples; compare timings only with matched instrumentation')
    p.add_argument('--seconds', type=int, default=60)
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--scenario', required=True, help='Interaction recipe, workload and cache state')
    p.add_argument('--workload-pid', type=int,
                   help='Known UI-test runner process tree; retained separately from unrelated developer workloads')
    a = p.parse_args()
    if not 1 <= a.seconds <= 600: p.error('seconds must be 1...600')
    if a.workload_pid is not None and a.workload_pid <= 0: p.error('workload-pid must be positive')
    a.out.mkdir(parents=True, exist_ok=False)
    trace = a.out / 'interactions.trace'
    environment = dict(timestamp=datetime.datetime.now().astimezone().isoformat(), platform=platform.platform(), pid=a.pid,
                       git=subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
                       dirty=subprocess.check_output(['git', 'status', '--porcelain'], text=True),
                       load=subprocess.check_output(['uptime'], text=True).strip(), scenario=a.scenario,
                       timeProfiler=a.time_profiler, workloadPID=a.workload_pid)
    executable = Path(subprocess.check_output(['ps', '-p', str(a.pid), '-o', 'comm='], text=True).strip())
    environment['executable'] = str(executable)
    environment['binarySHA256'] = hashlib.sha256(executable.read_bytes()).hexdigest() if executable.is_file() else None
    (a.out / 'environment.json').write_text(json.dumps(environment, indent=2)+'\n')
    command = ['xcrun', 'xctrace', 'record', '--template', 'Logging', '--instrument', 'Core Animation Commits',
               '--instrument', 'Run Loops', '--attach', str(a.pid), '--time-limit', f'{a.seconds}s',
               '--output', str(trace), '--no-prompt']
    if a.time_profiler: command += ['--instrument', 'Time Profiler']
    try:
        with HostMonitor(a.out / 'host-monitor.json', workload_pid=a.workload_pid) as host, (a.out / 'record.log').open('w') as log:
            result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=a.seconds+90)
    except subprocess.TimeoutExpired:
        (a.out / 'summary.json').write_text(json.dumps(dict(status='unmeasured', reason='Recorder timed out'))+'\n')
        return 2
    paths = []
    for schema in ['coreanimation-commit-interval', 'runloop-intervals'] + (['time-profile'] if a.time_profiler else []):
        path = a.out / f'{schema}.xml'
        export = subprocess.run(['xcrun', 'xctrace', 'export', '--input', str(trace), '--xpath',
                                 f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]', '--output', str(path)],
                                capture_output=True, text=True, timeout=60)
        (a.out / f'{schema}-export.log').write_text(export.stdout+export.stderr)
        if export.returncode:
            (a.out / 'summary.json').write_text(json.dumps(dict(status='unmeasured', reason='Trace export failed'))+'\n')
            return 2
        paths.append(path)
    report = summarize(*paths[:2], recording_ok=result.returncode == 0)
    report['hostMonitor'] = host.report()
    if not report['hostMonitor']['clean']:
        report['status'] = 'fail'
        report['missingEvidence'].append('Clean host comparison; competing developer work or incomplete monitoring')
    process_check = subprocess.run(['ps', '-p', str(a.pid), '-o', 'comm='], capture_output=True, text=True)
    report['previewStillRunning'] = process_check.returncode == 0 and process_check.stdout.strip() == str(executable)
    if not report['previewStillRunning']:
        report['status'] = 'fail'
        report['missingEvidence'].append('Preview exited during recording; interaction scenario incomplete')
    (a.out / 'summary.json').write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps({k: v for k, v in report.items() if k not in ['commits', 'mainRunLoopBusy', 'mainRunLoopWithoutNestedWaits']}))
    return 1 if report['status'] == 'fail' else 2

if __name__ == '__main__':
    sys.exit(main())
