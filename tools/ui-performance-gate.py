#!/usr/bin/env python3
"""Evaluate device timing samples against docs/performance/ui-performance-contract.md.

Input JSON: {"environment": {"device": "...", "os": "...", "build": "...",
"physicalDevice": true, "refreshHz": 120, "measurementMethod": "..."},
"scenarios": [{"name": "notes typing", "kind": "direct", "cache": "cold",
"samplesMS": [4.2, 5.1]}]}. Kinds: frame, direct, ui. Durations must be measured
frame work or input-to-visible-response timings, not XCTest gesture wall time or
CADisplayLink callback gaps. This tool evaluates supplied evidence; it does not collect it.
"""
import argparse
import json
import math
import pathlib


def evaluate(report):
    environment = report.get('environment', {})
    required = ('device', 'os', 'build', 'measurementMethod')
    if any(not isinstance(environment.get(k), str) or not environment[k].strip() for k in required):
        raise ValueError('environment must identify device, os, build and measurementMethod')
    refresh = environment.get('refreshHz')
    if isinstance(refresh, bool) or not isinstance(refresh, (int, float)) or not math.isfinite(refresh) or refresh <= 0:
        raise ValueError('refreshHz must be a positive finite number')
    if not isinstance(environment.get('physicalDevice'), bool):
        raise ValueError('physicalDevice must be an explicit boolean')
    eligible = environment['physicalDevice'] and refresh >= 120
    scenarios = report.get('scenarios')
    if not isinstance(scenarios, list) or not scenarios:
        raise ValueError('at least one measured scenario is required')
    results = []
    seen = set()
    for scenario in scenarios:
        kind = scenario.get('kind')
        if kind not in ('frame', 'direct', 'ui'):
            raise ValueError('scenario kind must be frame, direct or ui')
        if not scenario.get('name') or scenario.get('cache') not in ('cold', 'warm', 'mixed'):
            raise ValueError('each scenario needs a name and cold/warm/mixed cache state')
        samples = scenario.get('samplesMS')
        if not isinstance(samples, list) or not samples or any(
            isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v) or v < 0
            for v in samples
        ):
            raise ValueError('samplesMS must contain finite, nonnegative durations; missing data cannot pass')
        ordered = sorted(samples)
        percentile = lambda p: ordered[max(0, math.ceil(len(ordered) * p) - 1)]
        limit = {'frame': 8.3, 'direct': 20, 'ui': 100}[kind]
        violations = [{'sample': i, 'ms': value} for i, value in enumerate(samples) if value > limit]
        p95 = percentile(.95)
        target_met = p95 <= 8.3 if kind == 'frame' else p95 < 10 if kind == 'direct' else p95 <= 50
        results.append(dict(name=scenario['name'], kind=kind, cache=scenario['cache'],
                            count=len(samples), p50MS=percentile(.5), p95MS=p95, p99MS=percentile(.99),
                            maxMS=ordered[-1], limitMS=limit, violations=violations,
                            targetMet=target_met, preferred32MSMet=p95 <= 32 if kind == 'ui' else None,
                            passed=not violations and (target_met if kind == 'direct' else True)))
        seen.add((kind, scenario['cache']))
    # Cold and warm interactive response plus sustained frame evidence are required. Mixed
    # samples are retained, but cannot substitute for explicitly identified cold/warm checks.
    missing = [f'{kind}:{cache}' for kind in ('direct', 'ui') for cache in ('cold', 'warm')
               if (kind, cache) not in seen]
    if not any(kind == 'frame' for kind, _ in seen):
        missing.append('frame')
    failed = any(not item['passed'] for item in results)
    status = 'fail' if failed else 'unmeasured' if missing or not eligible else 'pass'
    return dict(status=status, acceptanceEligible=eligible, missingCoverage=missing,
                environment=environment, scenarios=results)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=pathlib.Path)
    parser.add_argument('--out', type=pathlib.Path)
    args = parser.parse_args()
    try:
        result = evaluate(json.loads(args.input.read_text()))
    except (OSError, ValueError, TypeError, AttributeError) as error:
        parser.error(str(error))
    output = json.dumps(result, indent=2) + '\n'
    if args.out:
        args.out.write_text(output)
    print(output, end='')
    return {'pass': 0, 'fail': 1, 'unmeasured': 2}[result['status']]


if __name__ == '__main__':
    raise SystemExit(main())
