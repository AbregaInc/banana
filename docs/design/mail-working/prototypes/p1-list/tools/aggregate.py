#!/usr/bin/env python3
"""Aggregate results/<platform>/*.json into one row per (platform, host, variant, scenario):
passes/runs, median [min-max] of the deciding number, extra numbers, load range.
usage: aggregate.py [ios|mac] [--md]"""
import json, glob, sys, statistics, collections, os
plat = sys.argv[1] if len(sys.argv) > 1 else 'ios'
root = os.path.join(os.path.dirname(__file__), '..', 'results', plat)
groups = collections.defaultdict(list)
for f in sorted(glob.glob(root + '/*.json')):
    d = json.load(open(f))
    if d['scenario'] == 'debug': continue
    groups[(d['host'], d['variant'], d['scenario'])].append(d)

def load1(d):
    try: return float(d['load']['uptime'].replace(',', ' ').split()[0])
    except Exception: return None

def rng(v, fmt='%.2f'):
    v = [x for x in v if x is not None]
    if not v: return 'n/a'
    if len(v) == 1: return fmt % v[0]
    return (fmt + ' [' + fmt + '-' + fmt + ']') % (statistics.median(v), min(v), max(v))

order = {'prepend': 0, 'rebuild': 1, 'slide': 2, 'heldkey': 3, 'heldkey-still': 4, 'idle': 5}
rows = []
for (host, var, sc), ds in sorted(groups.items(), key=lambda kv: (kv[0][0], kv[0][1], order.get(kv[0][2], 9))):
    S = [d['summary'] for d in ds]
    n = len(ds); ok = sum(d['pass'] for d in ds)
    if sc == 'heldkey':   # the container may re-evaluate once per window re-centre (one publish); anything beyond is per-move
        ok = sum(1 for d in ds if d['summary']['containerDelta'] - d['summary']['windowRecentres'] <= 0 and d['summary']['hitchesPer10s'] <= 3 and d['summary']['rowBodyPerMove'] <= 1.5)
    if sc == 'prepend' and all('error' in r for d in ds for r in d['detail']['reps']):
        dec = 'marked row never reached the screen (this API cannot scroll the host)'; extra = ''
    elif sc == 'prepend':
        dec = rng([s['decidingNumber'] for s in S]) + ' pt'
        extra = 'frames displaced/insert (worst rep): ' + str([max((r.get('framesDisplaced') or 0) for r in d['detail']['reps'] if 'framesDisplaced' in r) if any('framesDisplaced' in r for r in d['detail']['reps']) else None for d in ds])
    elif sc == 'rebuild':
        dec = rng([s['decidingNumber'] for s in S]) + ' pt (first frame row is on screen)'
        extra = 'blank-list frames ' + str([s.get('maxBlankListFrames') for s in S]) + ', frames before host ' + str([s.get('maxFramesBeforeHost') for s in S])
    elif sc == 'slide':
        dec = rng([s['decidingNumber'] for s in S], '%.0f') + ' jump frames'
        extra = 'worst error ' + rng([s['worstError'] for s in S], '%.1f') + ' pt, re-centres ' + str([s['windowRecentres'] for s in S]) + ', compared ' + str([s['framesCompared'] for s in S])
    elif sc in ('heldkey', 'heldkey-still'):
        dec = 'container +' + rng([s['containerDelta'] for s in S], '%.0f') + ' (re-centres: ' + rng([s['windowRecentres'] for s in S], '%.0f') + ')' if sc == 'heldkey' else 'container +' + rng([s['containerDelta'] for s in S], '%.0f')
        extra = ('hitches/10s ' + rng([s['hitchesPer10s'] for s in S]) + ', rows/move ' + rng([s['rowBodyPerMove'] for s in S]) +
                 ', marks/move ' + rng([s['markBodyPerMove'] for s in S]) + ', turn p95 ms ' + rng([s['turnMsP95'] for s in S]) +
                 ', call p95 ms ' + rng([s['moveCallMsP95'] for s in S]))
    elif sc == 'idle':
        dec = 'bodies +' + rng([s['decidingNumber'] for s in S], '%.0f')
        extra = 'cpu s/20 s ' + rng([s['cpuSecondsIn20s'] for s in S])
    else:
        dec = str([s.get('decidingNumber') for s in S]); extra = ''
    l = [load1(d) for d in ds]
    ds_sorted = sorted(ds, key=lambda d: d['run'])
    per_run = ' / '.join(('%.0f' % load1(d)) if load1(d) is not None else '?' for d in ds_sorted)
    rows.append((host, var, sc, plat, '%d/%d' % (ok, n), dec, extra, per_run))

MAIN = {('native', '-'), ('list', 'reader'), ('lazy', 'positionY'), ('lazy', 'id')}
if '--main' in sys.argv: rows = [r for r in rows if (r[0], r[1]) in MAIN]
if '--variants' in sys.argv: rows = [r for r in rows if (r[0], r[1]) not in MAIN or r[2] in ('prepend', 'rebuild', 'slide') and (r[0], r[1]) not in MAIN]
if '--md' in sys.argv:
    print('| host | variant | scenario | platform | pass | deciding number: median [range] | other numbers | load (1-min avg at launch, run 1 / 2 / 3) |')
    print('|---|---|---|---|---|---|---|---|')
    for r in rows: print('| ' + ' | '.join(r) + ' |')
else:
    for r in rows: print(' | '.join(r))
