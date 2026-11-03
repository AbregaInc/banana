#!/usr/bin/env python3
"""Show measured tradeoffs without inventing an overall model ranking."""
import argparse,json,pathlib
p=argparse.ArgumentParser();p.add_argument('reports',nargs='+',type=pathlib.Path);a=p.parse_args()
print('| Model | Engine | Contracts | Warm median ms | First request ms | Load s | GPU peak MB | Timing clean? |')
print('|---|---|---:|---:|---:|---:|---:|---|')
for path in a.reports:
 d=json.loads(path.read_text());s=d['summary']
 print(f"| {d['checkpoint']['repo']} | {d['engine']} | {s['passes']}/{s['total']} | {s['warmMedianMilliseconds']} | {s['firstRequestMilliseconds']} | {d.get('loadSeconds')} | {s['gpuPeakMB']} | {d['cleanPerformanceRun']} |")
print('\nDevelopment smoke contracts only. GPU/RSS counters are not a certified total app footprint. Inspect raw failures and run the real-app promotion gate.')
