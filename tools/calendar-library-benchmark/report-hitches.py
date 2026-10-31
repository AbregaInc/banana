#!/usr/bin/env python3
"""Summarize exported Animation Hitches tables without claiming input/display acceptance."""
import argparse
from collections import Counter
import json
import math
from pathlib import Path
import xml.etree.ElementTree as ET


def table(path):
    root = ET.parse(path).getroot()
    refs = {node.get('id'): node for node in root.iter() if node.get('id')}
    def resolve(node):
        return refs[node.get('ref')] if node.get('ref') else node
    schema = root.find('.//schema')
    if schema is None: raise ValueError('Missing schema: ' + str(path))
    columns = [col.findtext('mnemonic') for col in schema.findall('col')]
    result = []
    for row in root.findall('.//row'):
        if len(row) != len(columns): raise ValueError('Wrong column count: ' + str(path))
        record = dict(zip(columns, [resolve(node) for node in row]))
        process = record.get('process')
        if process is not None:
            pid = process.find('pid')
            record['resolvedPID'] = int(resolve(pid).text) if pid is not None else None
        result.append(record)
    return result


def stats(samples):
    values = sorted(samples)
    if not values: raise ValueError('Empty timing coverage')
    return dict(count=len(values), p50MS=values[math.ceil(len(values)*.5)-1],
        p95MS=values[math.ceil(len(values)*.95)-1], p99MS=values[math.ceil(len(values)*.99)-1],
        maxMS=values[-1], over8_3MS=sum(value > 8.3 for value in values))


def overlapping_duration(start, duration, intervals):
    """Union of explicit waits intersecting this interval; never double-subtract."""
    end = start + duration
    clipped = sorted((max(start, a), min(end, b)) for a, b in intervals if a < end and b > start)
    covered, tail = 0, start
    for a, b in clipped:
        covered += max(0, b - max(tail, a))
        tail = max(tail, b)
    return covered


def summarize(directory, pid):
    def read(schema): return table(directory / (schema + '.xml'))
    def key(row):
        return tuple(row[name].text for name in ['display','swap-id','surface-id'])
    updates = [r for r in read('hitches-updates') if r.get('resolvedPID') == pid]
    if not updates: raise ValueError('No updates attributed to requested process')
    keys = {key(row) for row in updates}
    renders = [r for r in read('hitches-renders') if key(r) in keys]
    lifetimes = [r for r in read('hitches-frame-lifetimes') if key(r) in keys]
    if {key(r) for r in renders} != keys or {key(r) for r in lifetimes} != keys:
        raise ValueError('Incomplete app-associated render/lifetime coverage')
    hitches = [r for r in read('hitches') if r.get('resolvedPID') == pid]
    vsyncs = sorted({int(r['timestamp'].text) for r in read('display-vsyncs-interval')})
    if len(vsyncs) < 2: raise ValueError('Missing variable-refresh evidence')
    gaps = [(b-a)/1e6 for a,b in zip(vsyncs,vsyncs[1:])]
    timings = {}
    groups = [('appUpdates',updates),('associatedRenders',renders),('associatedFrameLifetimes',lifetimes)]
    if (directory / 'hitches-gpu.xml').exists():
        gpu = [r for r in read('hitches-gpu') if key(r) in keys]
        if {key(r) for r in gpu} != keys: raise ValueError('Incomplete app-associated GPU coverage')
        groups.append(('associatedGPU',gpu))
    for label, rows in groups:
        raw = [dict(startNS=int(r['start'].text), durationMS=int(r['duration'].text)/1e6,
                    display=r['display'].text, swapID=int(r['swap-id'].text), surfaceID=int(r['surface-id'].text)) for r in rows]
        timings[label] = dict(stats=stats([r['durationMS'] for r in raw]), samples=raw)
    wait_diagnostic = None
    if (directory / 'hitches-framewait.xml').exists():
        waits = {}
        for row in read('hitches-framewait'):
            if key(row) in keys:
                start = int(row['start'].text)
                waits.setdefault(key(row), []).append((start, start + int(row['duration'].text)))
        samples = []
        for row in renders:
            start, duration = int(row['start'].text), int(row['duration'].text)
            overlap = overlapping_duration(start, duration, waits.get(key(row), []))
            samples.append(dict(startNS=start, renderMS=duration/1e6,
                overlappingWaitMS=overlap/1e6, excludingExplicitWaitMS=(duration-overlap)/1e6,
                hasWaitRecord=key(row) in waits, display=row['display'].text,
                swapID=int(row['swap-id'].text), surfaceID=int(row['surface-id'].text)))
        wait_diagnostic = dict(scope='Interval intersection only, not CPU execution or input latency. Does not replace the unchanged inclusive interval gate.',
            rendersWithWaitRecord=sum(row['hasWaitRecord'] for row in samples),
            stats=stats([row['excludingExplicitWaitMS'] for row in samples]), samples=samples)
    return dict(status='analyzed-partial-evidence', pid=pid,
        scope='App-attributed update intervals and matching compositor work; not HID-to-visible latency or complete UI acceptance',
        attributionLimit='Render intervals may overlap GPU work and extend beyond its completion. Their entire duration is not proven CPU execution; GPU subtraction does not establish CPU cost. Interval budget failures remain conservative and unchanged.',
        measuredWorkBudget='fail' if any(timings[label]['stats']['over8_3MS'] for label in ['appUpdates','associatedRenders','associatedGPU'] if label in timings) else 'within-measured-intervals-only',
        appHitchRows=len(hitches), timings=timings,
        renderWaitDiagnostic=wait_diagnostic,
        displayCadence=dict(scope='Display-wide VSync intervals, not app frame/input latency',
            count=len(vsyncs), firstNS=vsyncs[0], lastNS=vsyncs[-1],
            roundedGapHistogramMS=dict(sorted(Counter(round(gap,2) for gap in gaps).items()))),
        limitations=['Frame lifetimes span a pipelined render loop and are not single-frame work or input latency.',
                    'No app-attributed HID timestamp or CPU-to-display rows; direct-input acceptance remains unmeasured.',
                    'Variable cadence must not be treated as automatic missed 120 Hz deadlines.',
                    'Retain capture status, workload, binary identity and actual touch overlap separately.'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--pid', type=int, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    if args.out.exists(): parser.error('Refusing to replace an existing analysis')
    try: result = summarize(args.directory, args.pid)
    except (ValueError, KeyError, OSError, ET.ParseError) as error:
        result = dict(status='invalid-unmeasured', reason=str(error))
    args.out.write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps({key:value for key,value in result.items() if key not in ['timings','displayCadence','renderWaitDiagnostic']},indent=2))
    return 1 if result.get('measuredWorkBudget') == 'fail' else 2


if __name__ == '__main__':
    raise SystemExit(main())
