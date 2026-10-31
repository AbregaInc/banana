#!/usr/bin/env python3
"""Diagnostic Metal presentation report. Never certifies hardware input latency."""
import argparse
import json
import math
from pathlib import Path


def stats(samples):
    values = sorted(samples)
    return ({'count': len(values), 'p50': values[math.ceil(.50*len(values))-1],
             'p95': values[math.ceil(.95*len(values))-1],
             'p99': values[math.ceil(.99*len(values))-1], 'max': values[-1]}
            if values else {'count': 0})


def report(rows):
    frames = [r for r in rows if r['kind'] == 'frame']
    valid = [r for r in frames if r.get('ok') == 1 and
             0 < r['requested'] <= r['began'] <= r['encoded'] <= r['presented']]
    invalid = [r for r in frames if r not in valid]
    direct = [(r['presented']-r['input'])*1000 for r in valid
              if 0 < r.get('input', 0) <= r['requested']]
    encode = [(r['encoded']-r['began'])*1000 for r in frames if r['encoded'] >= r['began'] > 0]
    requests = [r for r in rows if r['kind'] == 'pageRequest']
    page_samples, unmatched, ready_samples = [], [], []
    for i, request in enumerate(requests):
        end = requests[i+1]['time'] if i+1 < len(requests) else float('inf')
        ready = [r for r in rows if r['kind'] == 'pageReady' and r['date'] == request['date']
                 and request['time'] <= r['time'] < end]
        if ready:
            ready_samples.append({'cached': request['cached'], 'ms': (ready[0]['time']-request['time'])*1000})
        # Only the page publication frame measures this request. A subsequent
        # scroll must not turn a missing page timestamp into a fabricated delay.
        candidates = [r for r in frames if r['date'] == request['date'] and
                      request['time'] <= r['requested'] < end]
        first = min(candidates, key=lambda r: r['requested']) if candidates else None
        matches = [first] if first in valid and first['presented'] < end else []
        if matches:
            page_samples.append({'cached': request['cached'], 'request': request['time'],
                                 'ms': (min(r['presented'] for r in matches)-request['time'])*1000})
        else:
            unmatched.append(request)
    violations = {'encodeOver8_3': [v for v in encode if v > 8.3],
                  'scrollCallbackOver20': [(r['presented']-r['input'])*1000 for r in valid
                      if r.get('inputKind') == 'scroll' and 0 < r.get('input', 0) <= r['requested']
                      and (r['presented']-r['input'])*1000 > 20],
                  'pageOver100': [v for v in page_samples if v['ms'] > 100]}
    violations['pageReadyLowerBoundOver100'] = [v for v in ready_samples if v['ms'] > 100]
    scroll = [(r['presented']-r['input'])*1000 for r in valid
              if r.get('inputKind') == 'scroll' and 0 < r.get('input', 0) <= r['requested']]
    if scroll and stats(scroll)['p95'] >= 10:
        violations['scrollCallbackP95AtLeast10'] = stats(scroll)['p95']
    failed = any(violations.values())
    memory = [r for r in rows if r['kind'] == 'memory']
    by_request = {r['requested']: r for r in frames}
    gpu_response = [(r['completed']-by_request[r['requested']]['began'])*1000
                    for r in rows if r['kind'] == 'gpuCompleted' and r['ok'] == 1
                    and r['requested'] in by_request and r['completed'] >= by_request[r['requested']]['began']]
    return {'scope': 'Diagnostic: CPU encode, scroll/button callback-to-presentation, page request-to-presentation. '
                     'Not complete frame work or hardware input-to-visible acceptance; callback coverage incomplete.',
            'acceptance': 'failed' if failed else 'unmeasured',
            'fixture': [r for r in rows if r['kind'] == 'fixture'],
            'platform': [r for r in rows if r['kind'] in ('platform', 'display')],
            'policy': [r for r in rows if r['kind'] == 'policy'],
            'memory': {'samples': len(memory),
                       'peakRSS': max((r['peakRSS'] for r in memory), default=None),
                       'sampledMaxFootprint': max((r['footprint'] for r in memory), default=None),
                       'thermalStates': sorted(set(r['thermalState'] for r in memory)),
                       'lowPowerObserved': any(r['lowPower'] for r in memory)},
            'frames': len(frames), 'presentedFrames': len(valid), 'unpresentedOrInvalid': invalid,
            'coalescedRequests': sum(r['kind'] == 'coalesced' for r in rows),
            'cpuEncodeMS': stats(encode), 'callbackToPresentedMS': stats(direct), 'scrollCallbackToPresentedMS': stats(scroll),
            'encodeStartToGPUCompletionCallbackMS': stats(gpu_response),
            'coldPageMS': stats([v['ms'] for v in page_samples if not v['cached']]),
            'cachedPageMS': stats([v['ms'] for v in page_samples if v['cached']]),
            'pageReadyColdMS': stats([v['ms'] for v in ready_samples if not v['cached']]),
            'pageReadyCachedMS': stats([v['ms'] for v in ready_samples if v['cached']]),
            'nativeSurfacePublishAPIMS': stats([r['durationMS'] for r in rows if r['kind'] == 'nativeSurfacePublish']),
            'nativeScrollCallbacks': sum(r['kind'] == 'nativeScroll' for r in rows),
            'pageSamples': page_samples, 'unmatchedPageRequests': unmatched,
            'violations': violations}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('log', type=Path)
    parser.add_argument('--out', required=True, type=Path)
    args = parser.parse_args()
    result = report([json.loads(line) for line in args.log.read_text().splitlines()])
    with args.out.open('x') as output:
        json.dump(result, output, indent=2); output.write('\n')
    print(json.dumps({k: result[k] for k in ('acceptance', 'frames', 'presentedFrames', 'cpuEncodeMS',
                                            'callbackToPresentedMS', 'coldPageMS', 'cachedPageMS')}, indent=2))
    return 1 if result['acceptance'] == 'failed' else 2


if __name__ == '__main__':
    raise SystemExit(main())
